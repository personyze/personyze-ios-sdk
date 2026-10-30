import Foundation
import Testing
@testable import Personyze

/// The REST client over the real URLSession transport and a local server, in real time. Serialized:
/// the deadline tests measure time.
@Suite(.serialized) struct RestClientTests
{	static let key = "0123456789abcdef0123456789abcdef01234567"
	/// For a test that expects an answer, not a timeout: an iOS Simulator starting cold failed the
	/// first such test once at 2 s. Answered, they take milliseconds.
	static let answerBudgetMs: Int64 = 10_000

	private func rest(_ base: String, retries: Int = 1, online: Bool = true) -> RestClient
	{	RestClient(
			transport: URLSessionTransport(isOnline: { online }),
			apiKey: RestClientTests.key,
			baseUrl: base,
			retries: retries,
			monotonicMs: Clocks.monotonicMs,
			userAgent: "personyze-ios/test"
		)
	}

	@Test func basicAuthWithoutTrailingNewline() async throws
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(body: "{}"))
		let r = await rest(server.baseUrl).call("POST", "tracker-v1", body: #"{"a":1}"#, budgetMs: RestClientTests.answerBudgetMs)
		#expect(r == .ok(body: "{}", dateMs: nil))
		let request = try #require(server.takeRequest())
		#expect(request.method == "POST")
		#expect(request.target == "/rest/tracker-v1")
		let auth = try #require(request.headers["authorization"])
		#expect(auth == "Basic " + Data("api:\(RestClientTests.key)".utf8).base64EncodedString())
		#expect(!auth.contains("\n"))
		#expect(request.headers["content-type"]?.hasPrefix("application/json") == true)
		#expect(request.headers["user-agent"] == "personyze-ios/test")
		#expect(request.body == #"{"a":1}"#)
	}

	/// The server's clock comes with every answer: a device clock 90 minutes off would otherwise
	/// open a new session on every request.
	@Test func dateHeaderIsRead() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(headers: ["Date": "Sun, 06 Nov 1994 08:49:37 GMT"], body: "{}"))
		#expect(await rest(server.baseUrl).call("GET", "x", body: nil, budgetMs: RestClientTests.answerBudgetMs) == .ok(body: "{}", dateMs: 784_111_777_000))
	}

	/// 1.x Android (Volley) decoded a body without a charset as ISO-8859-1.
	@Test func bodyWithoutCharsetIsUtf8() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(headers: ["Content-Type": "application/json"], body: #"{"t":"שלום"}"#))
		#expect(await rest(server.baseUrl).call("GET", "x", body: nil, budgetMs: RestClientTests.answerBudgetMs) == .ok(body: #"{"t":"שלום"}"#, dateMs: nil))
	}

	@Test func statusMapping() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(status: 400, body: "No Product ID specified"))
		#expect(await rest(server.baseUrl).call("POST", "tracker-v1", body: "{}", budgetMs: RestClientTests.answerBudgetMs).error == .badRequest(status: 400, text: "No Product ID specified"))

		server.enqueue(.init(status: 401, body: "Invalid API key"))
		#expect(await rest(server.baseUrl).call("POST", "tracker-v1", body: "{}", budgetMs: RestClientTests.answerBudgetMs).error == .auth(message: "Personyze rejected the API key (HTTP 401). Check it in Settings > Integrations > Full-featured API."))

		server.enqueue(.init(status: 404))
		#expect(await rest(server.baseUrl).call("GET", "x", body: nil, budgetMs: RestClientTests.answerBudgetMs).error == .badRequest(status: 404, text: ""))

		// A redirect is not followed: the base URL is wrong.
		server.enqueue(.init(status: 301, headers: ["Location": "https://elsewhere.invalid/"]))
		#expect(await rest(server.baseUrl).call("GET", "x", body: nil, budgetMs: RestClientTests.answerBudgetMs).error == .badRequest(status: 301, text: ""))
		#expect(server.requestCount == 4)
	}

	/// 429 is the account's state: not retried, and nothing was logged.
	@Test func throttledIsNotRetried() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(status: 429, body: "Tracking is paused on this account"))
		let r = await rest(server.baseUrl).call("POST", "tracker-v1", body: "{}", budgetMs: RestClientTests.answerBudgetMs)
		#expect(r.kind == .rateLimited)
		#expect(r.maybeDelivered == false)
		#expect(server.requestCount == 1)
	}

	@Test func fiveHundredIsRetriedOnce() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(status: 503))
		server.enqueue(.init(body: "ok"))
		#expect(await rest(server.baseUrl).call("POST", "tracker-v1", body: "{}", budgetMs: RestClientTests.answerBudgetMs) == .ok(body: "ok", dateMs: nil))
		#expect(server.requestCount == 2)

		server.enqueue(.init(status: 500))
		server.enqueue(.init(status: 500))
		server.enqueue(.init(body: "never"))
		let r = await rest(server.baseUrl).call("POST", "tracker-v1", body: "{}", budgetMs: RestClientTests.answerBudgetMs)
		#expect(r.kind == .server)
		#expect(r.maybeDelivered == true)
		#expect(server.requestCount == 4)
	}

	@Test func noRetryWhenRetriesIsZero() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(status: 500))
		_ = await rest(server.baseUrl, retries: 0).call("POST", "tracker-v1", body: "{}", budgetMs: RestClientTests.answerBudgetMs)
		#expect(server.requestCount == 1)
	}

	/// The budget covers the whole body: one arriving a byte every 30 ms fails at the deadline, not
	/// after it (SPEC section 5 - Python's urllib took 3.7 s with timeout=1).
	@Test func trickledBodyFailsAtTheDeadline() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(body: String(repeating: "x", count: 200), bytePauseMs: 30))
		let started = Clocks.monotonicMs()
		let r = await rest(server.baseUrl).call("POST", "tracker-v1", body: "{}", budgetMs: 800)
		let took = Clocks.monotonicMs() - started
		#expect(took < 1500, "took \(took) ms")
		#expect(r.kind == .timeout)
		#expect(r.maybeDelivered == true)
	}

	/// Refused before anything was sent: safe to keep the events for later.
	@Test func refusedConnectionWasNotSent() async
	{	let r = await rest("http://127.0.0.1:\(TestServer.unusedPort())").call("POST", "tracker-v1", body: "{}", budgetMs: RestClientTests.answerBudgetMs)
		#expect(r.kind == .connection)
		#expect(r.maybeDelivered == false)
	}

	/// The connection broke after the request went out: maybe delivered, retried at most once.
	@Test func brokenAfterSendingIsMaybeDelivered() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(dropConnection: true))
		server.enqueue(.init(dropConnection: true))
		server.enqueue(.init(body: "never"))
		let r = await rest(server.baseUrl).call("POST", "tracker-v1", body: "{}", budgetMs: RestClientTests.answerBudgetMs)
		#expect(r.maybeDelivered == true)
		#expect(server.requestCount <= 2)
	}

	@Test func offlineSendsNothing() async
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		let r = await rest(server.baseUrl, online: false).call("POST", "tracker-v1", body: "{}", budgetMs: 1000)
		#expect(r.kind == .offline)
		#expect(r.maybeDelivered == false)
		#expect(server.requestCount == 0)
	}

	/// A server message that echoes the key never carries it into a log.
	@Test func echoedKeyIsRedacted() async throws
	{	let server = TestServer()
		defer
		{	server.stop()
		}
		server.enqueue(.init(status: 400, body: "bad key \(RestClientTests.key.uppercased()) here"))
		let error = try #require(await rest(server.baseUrl).call("GET", "x", body: nil, budgetMs: RestClientTests.answerBudgetMs).error)
		#expect(!error.message.lowercased().contains(RestClientTests.key))
		#expect(error.message.contains("***"))
	}
}

private extension RestResult
{	var error: PersonyzeError?
	{	if case .failed(let error, _) = self
		{	return error
		}
		return nil
	}

	var kind: PersonyzeError.TransportKind?
	{	if case .transport(let kind, _, _)? = error
		{	return kind
		}
		return nil
	}

	var maybeDelivered: Bool?
	{	if case .failed(_, let maybeDelivered) = self
		{	return maybeDelivered
		}
		return nil
	}
}

import Foundation

enum RestResult: Sendable, Equatable
{	case ok(body: String, dateMs: Int64?)

	/// `maybeDelivered`: whether any attempt may have reached the server. When false, nothing was
	/// logged and the commands may be kept for later.
	case failed(PersonyzeError, maybeDelivered: Bool)
}

/// Personyze's `/rest`, with the failure rules every port shares (SPEC sections 1 and 5):
///
/// - one deadline for the whole call, every attempt included;
/// - at most one retry, only for a connection failure, a timeout or a 5xx, only while at least a
///   tenth of the budget is left - so a genuine timeout, having used the budget, is not retried;
/// - 401 is an auth error and 429 a throttle, neither retried; any other 4xx (a 3xx too, since
///   redirects are not followed) is a bad request carrying the server's plain-text reason.
final class RestClient: Sendable
{	private let transport: any Transport
	private let apiKey: String
	private let root: String
	private let retries: Int
	private let monotonicMs: @Sendable () -> Int64
	private let headers: [String: String]

	init
	(	transport: any Transport,
		apiKey: String,
		baseUrl: String,
		retries: Int,
		monotonicMs: @escaping @Sendable () -> Int64,
		userAgent: String
	)
	{	self.transport = transport
		self.apiKey = apiKey
		self.root = baseUrl + "/rest/"
		self.retries = max(retries, 0)
		self.monotonicMs = monotonicMs
		// Base64 without line breaks: 1.x Android ended the header value with a newline.
		self.headers = [
			"Authorization": "Basic " + Data("api:\(apiKey)".utf8).base64EncodedString(),
			"Accept": "application/json",
			"User-Agent": userAgent,
		]
	}

	func call(_ method: String, _ path: String, body: String?, budgetMs: Int64) async -> RestResult
	{	guard let url = URL(string: root + path) else
		{	return .failed(.invalid(message: "Personyze: not a URL: " + redact(root + path)), maybeDelivered: false)
		}
		let deadline = monotonicMs() + budgetMs
		var maybeDelivered = false
		var lastError: PersonyzeError?
		attempts: for attempt in 0 ... retries
		{	let remaining = deadline - monotonicMs()
			if remaining <= 0 || attempt > 0 && remaining < budgetMs/10
			{	break
			}
			switch await transport.execute(HttpRequest(method: method, url: url, headers: headers, body: body), timeoutMs: remaining)
			{	case .answered(let status, let responseBody, let dateMs):
					if status == 200
					{	return .ok(body: responseBody, dateMs: dateMs)
					}
					let text = redact(responseBody.trimmingCharacters(in: .whitespacesAndNewlines))
					if status == 401
					{	return .failed(.auth(message: "Personyze rejected the API key (HTTP 401). Check it in Settings > Integrations > Full-featured API."), maybeDelivered: false)
					}
					if status == 429
					{	return .failed(.transport(kind: .rateLimited, status: 429, message: "Personyze declined the call (HTTP 429): " + text.prefix(200)), maybeDelivered: false)
					}
					if status < 500
					{	return .failed(.badRequest(status: status, text: String(text.prefix(1000))), maybeDelivered: maybeDelivered)
					}
					maybeDelivered = true
					lastError = .transport(kind: .server, status: status, message: "Personyze answered HTTP \(status): " + text.prefix(200))
				case .failed(let sent, let timedOut, let offline, let reason):
					if sent
					{	maybeDelivered = true
					}
					if offline
					{	lastError = .transport(kind: .offline, status: nil, message: "No network")
						break attempts
					}
					else if timedOut
					{	lastError = .transport(kind: .timeout, status: nil, message: "Personyze did not answer within \(budgetMs)ms")
					}
					else if !sent
					{	lastError = .transport(kind: .connection, status: nil, message: "Could not reach Personyze: " + redact(reason))
					}
					else
					{	lastError = .transport(kind: .server, status: nil, message: "The connection to Personyze broke: " + redact(reason))
					}
			}
		}
		return .failed(lastError ?? .transport(kind: .timeout, status: nil, message: "Personyze did not answer within \(budgetMs)ms"), maybeDelivered: maybeDelivered)
	}

	/// A server message that echoes the key must not carry it into a log (SPEC section 2).
	private func redact(_ text: String) -> String
	{	apiKey.count >= 8 ? text.replacingOccurrences(of: apiKey, with: "***", options: .caseInsensitive) : text
	}
}

enum Clocks
{	/// Wall clock, ms since the epoch.
	static func nowMs() -> Int64
	{	Int64((Date().timeIntervalSince1970*1000).rounded(.down))
	}

	/// A clock that never jumps, for deadlines.
	static func monotonicMs() -> Int64
	{	Int64(DispatchTime.now().uptimeNanoseconds/1_000_000)
	}
}

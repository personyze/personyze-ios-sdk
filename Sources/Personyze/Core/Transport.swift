import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HttpRequest: Sendable
{	var method: String
	var url: URL
	var headers: [String: String]
	var body: String?
}

enum HttpOutcome: Sendable, Equatable
{	/// Any HTTP status. `dateMs` is the server's `Date` header.
	case answered(status: Int, body: String, dateMs: Int64?)

	/// No response. `sent`: whether the request may have reached the server - false for a failed
	/// name lookup, connect or TLS handshake, and for a device with no network.
	case failed(sent: Bool, timedOut: Bool, offline: Bool, reason: String)
}

protocol Transport: Sendable
{	/// One HTTP exchange within `timeoutMs`, covering everything it waits for. Answers any status;
	/// fails only when there was no response at all.
	func execute(_ request: HttpRequest, timeoutMs: Int64) async -> HttpOutcome
}

/// URLSession, held to one deadline for the whole exchange.
///
/// URLSession has no such deadline of its own. A request's `timeoutInterval` bounds the wait between
/// packets, so a body trickling in a byte at a time never trips it (SPEC section 5), and the
/// session's `timeoutIntervalForResource` is one value for every task. So the task is cancelled
/// when the deadline passes.
///
/// Whether a failed request may have reached the server decides whether its events are kept or
/// dropped (SPEC section 11). Where URLSession reports task metrics (Apple's platforms), a request
/// none of whose transactions began sending was not sent. Elsewhere the error tells: a failed name
/// lookup, connect or TLS handshake sent nothing, and anything else may have.
///
/// Redirects are not followed: a 3xx means the base URL is wrong, and is answered as it came. The
/// session is ephemeral - no cookies, no cache, no stored credentials.
final class URLSessionTransport: Transport
{	private let session: URLSession
	private let isOnline: @Sendable () -> Bool

	init(isOnline: @escaping @Sendable () -> Bool = { true })
	{	let config = URLSessionConfiguration.ephemeral
		config.httpShouldSetCookies = false
		config.httpCookieAcceptPolicy = .never
		config.urlCache = nil
		config.requestCachePolicy = .reloadIgnoringLocalCacheData
		session = URLSession(configuration: config, delegate: Exchanges(), delegateQueue: nil)
		self.isOnline = isOnline
	}

	deinit
	{	session.finishTasksAndInvalidate()
	}

	func execute(_ request: HttpRequest, timeoutMs: Int64) async -> HttpOutcome
	{	if !isOnline()
		{	return .failed(sent: false, timedOut: false, offline: true, reason: "No network")
		}
		let budgetMs = Int(max(timeoutMs, 1))
		var urlRequest = URLRequest(url: request.url)
		urlRequest.httpMethod = request.method
		// Past the deadline, so that the deadline is what fires.
		urlRequest.timeoutInterval = Double(budgetMs)/1000 + 1
		for (name, value) in request.headers
		{	urlRequest.setValue(value, forHTTPHeaderField: name)
		}
		if let body = request.body
		{	urlRequest.httpBody = Data(body.utf8)
			urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
		}
		guard let exchanges = session.delegate as? Exchanges else
		{	return .failed(sent: false, timedOut: false, offline: false, reason: "The session is closed")
		}
		let exchange = Exchange(session.dataTask(with: urlRequest))
		return await withCheckedContinuation { continuation in
			exchange.begin(continuation)
			exchanges.add(exchange)
			exchange.task.resume()
			DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(budgetMs)) {
				exchange.deadlinePassed()
			}
			// A cancelled task answers at once; this is for one that never does.
			DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(budgetMs + 1000)) {
				exchange.giveUp()
			}
		}
	}
}

/// One request in flight, fed by the session's delegate and answered once.
private final class Exchange: @unchecked Sendable
{	/// Errors that mean the request never went out.
	private static let notSent: [URLError.Code] = [
		.cannotFindHost,
		.dnsLookupFailed,
		.cannotConnectToHost,
		.notConnectedToInternet,
		.dataNotAllowed,
		.internationalRoamingOff,
		.callIsActive,
		.secureConnectionFailed,
		.serverCertificateHasBadDate,
		.serverCertificateUntrusted,
		.serverCertificateHasUnknownRoot,
		.serverCertificateNotYetValid,
		.clientCertificateRejected,
		.clientCertificateRequired,
		.appTransportSecurityRequiresSecureConnection,
		.badURL,
		.unsupportedURL,
	]

	let task: URLSessionDataTask
	private let lock = NSLock()
	private var continuation: CheckedContinuation<HttpOutcome, Never>?
	private var status: Int?
	private var dateMs: Int64?
	private var body = Data()
	private var sentByMetrics: Bool?
	private var timedOut = false

	init(_ task: URLSessionDataTask)
	{	self.task = task
	}

	func begin(_ continuation: CheckedContinuation<HttpOutcome, Never>)
	{	lock.locked
		{	self.continuation = continuation
		}
	}

	func received(_ response: URLResponse)
	{	guard let http = response as? HTTPURLResponse else
		{	return
		}
		lock.locked
		{	status = http.statusCode
			dateMs = (http.value(forHTTPHeaderField: "Date")).flatMap(HttpDate.parseMs)
		}
	}

	func append(_ data: Data)
	{	lock.locked
		{	body.append(data)
		}
	}

	func metrics(sent: Bool)
	{	lock.locked
		{	sentByMetrics = sent
		}
	}

	func completed(_ error: (any Error)?)
	{	let outcome: HttpOutcome = lock.locked
		{	if error == nil, let status
			{	return .answered(status: status, body: String(decoding: body, as: UTF8.self), dateMs: dateMs)
			}
			let code = (error as? URLError)?.code
			let offline = !timedOut && (code == .notConnectedToInternet || code == .dataNotAllowed)
			// Headers came back: it was sent. Cancelled at the deadline: it may have been.
			let sent = status != nil || (sentByMetrics ?? (timedOut || code.map { !Exchange.notSent.contains($0) } ?? true))
			return .failed(sent: sent, timedOut: timedOut || code == .timedOut, offline: offline, reason: error.map { "\($0)" } ?? "no response")
		}
		finish(outcome)
	}

	func deadlinePassed()
	{	let pending = lock.locked
		{	if continuation != nil
			{	timedOut = true
			}
			return continuation != nil
		}
		if pending
		{	task.cancel()
		}
	}

	func giveUp()
	{	let sent = lock.locked
		{	sentByMetrics ?? true
		}
		finish(.failed(sent: sent, timedOut: true, offline: false, reason: "cancelled at the deadline"))
	}

	private func finish(_ outcome: HttpOutcome)
	{	let c = lock.locked
		{	let c = continuation
			continuation = nil
			return c
		}
		c?.resume(returning: outcome)
	}
}

/// The session's delegate: routes each task's events to its exchange.
private final class Exchanges: NSObject, URLSessionDataDelegate, @unchecked Sendable
{	private let lock = NSLock()
	private var byTask: [Int: Exchange] = [:]

	func add(_ exchange: Exchange)
	{	lock.locked
		{	byTask[exchange.task.taskIdentifier] = exchange
		}
	}

	private func get(_ task: URLSessionTask) -> Exchange?
	{	lock.locked
		{	byTask[task.taskIdentifier]
		}
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
	{	get(dataTask)?.received(response)
		completionHandler(.allow)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
	{	get(dataTask)?.append(data)
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
	{	completionHandler(nil)
	}

	#if !canImport(FoundationNetworking)
	func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics)
	{	get(task)?.metrics(sent: metrics.transactionMetrics.contains { $0.requestStartDate != nil })
	}
	#endif

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?)
	{	let exchange = lock.locked
		{	byTask.removeValue(forKey: task.taskIdentifier)
		}
		exchange?.completed(error)
	}
}

/// The `Date` header: IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the only form HTTP/1.1
/// servers send. Parsed by hand: `DateFormatter` is not safe to share across threads on Linux.
enum HttpDate
{	private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

	static func parseMs(_ text: String) -> Int64?
	{	let parts = text.split(separator: " ")
		guard parts.count == 6, parts[5] == "GMT", let day = Int(parts[1]), let year = Int(parts[3]), let month = months.firstIndex(of: String(parts[2])) else
		{	return nil
		}
		let hms = parts[4].split(separator: ":")
		guard hms.count == 3, let h = Int(hms[0]), let m = Int(hms[1]), let s = Int(hms[2]) else
		{	return nil
		}
		guard (1 ... 31).contains(day), (0 ... 23).contains(h), (0 ... 59).contains(m), (0 ... 60).contains(s) else
		{	return nil
		}
		let days = daysFromCivil(year, month + 1, day)
		return (Int64(days)*86400 + Int64(h*3600 + m*60 + s))*1000
	}

	/// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
	private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int
	{	let y = month <= 2 ? year - 1 : year
		let era = (y >= 0 ? y : y - 399)/400
		let yoe = y - era*400
		let doy = (153*(month + (month > 2 ? -3 : 9)) + 2)/5 + day - 1
		let doe = yoe*365 + yoe/4 - yoe/100 + doy
		return era*146097 + doe - 719468
	}
}

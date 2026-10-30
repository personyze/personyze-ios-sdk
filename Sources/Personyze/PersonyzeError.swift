import Foundation

/// Why a call to Personyze did not do what it was asked.
///
/// The SDK never throws these at the app for anything the server answers: a failed decision answers
/// an empty result carrying the error, and every failure - decisions, events, metadata,
/// notifications - reaches the error handler. On a server a bad key answers 500 for one page; in an
/// app that throws it, every installed copy would crash until an update ships (SPEC section 11).
///
/// No message ever contains the API key.
public enum PersonyzeError: Error, Sendable, Equatable
{	/// Personyze rejected the API key (HTTP 401). Check it in Settings > Integrations.
	case auth(message: String)

	/// Personyze refused the request (HTTP 400, or another 4xx but 401 and 429). `text` is the
	/// server's plain-text reason, such as `No Product ID specified`. Retrying cannot help.
	case badRequest(status: Int, text: String)

	/// The request did not get an answer to act on: no network, a timeout, a server error, a
	/// throttled account, or a body that was not the expected JSON. `status` is the HTTP status
	/// when there was one.
	case transport(kind: TransportKind, status: Int?, message: String)

	/// Events that were dropped rather than sent. `commands` are the wire commands, so the app can
	/// log what was lost.
	indirect case delivery(reason: DeliveryReason, commands: [[String]], message: String, cause: PersonyzeError?)

	/// The SDK refused an input before sending it, such as a blank product id. The call was ignored;
	/// nothing went over the network.
	case invalid(message: String)

	public enum TransportKind: Sendable, Equatable
	{	/// The device has no network; the events are kept and sent later.
		case offline
		/// Name lookup, connect or TLS failed before anything was sent.
		case connection
		/// The call's time budget ran out.
		case timeout
		/// HTTP 5xx, or the connection broke after the request went out.
		case server
		/// HTTP 429: the account's tracking is paused (its plan's page views are used up, or it
		/// awaits an upgrade). The SDK backs off for 10 minutes.
		case rateLimited
		/// HTTP 200 whose body was not the JSON Personyze sends.
		case malformedResponse
	}

	public enum DeliveryReason: Sendable, Equatable
	{	/// The request may or may not have reached Personyze (a timeout or error after it was sent).
		/// Sending it again could count a purchase twice, so it is not resent.
		case ambiguous
		/// The app was stopped while the request was in flight - the same doubt as `ambiguous`.
		case interrupted
		/// The events waited longer than a day for a network.
		case expired
		/// The events belonged to a visitor who is no longer the current one.
		case otherVisitor
		/// An action report belonged to a session that has ended.
		case otherSession
		/// Too many events were waiting; the oldest were dropped.
		case overflow
		/// Personyze refused the request (`cause` says why).
		case refused
	}

	public var message: String
	{	switch self
		{	case .auth(let message):
				return message
			case .badRequest(let status, let text):
				let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
				return trimmed.isEmpty ? "Personyze refused the request (HTTP \(status))" : "Personyze refused the request (HTTP \(status)): \(trimmed)"
			case .transport(_, _, let message):
				return message
			case .delivery(_, _, let message, _):
				return message
			case .invalid(let message):
				return message
		}
	}
}

extension PersonyzeError: CustomStringConvertible, LocalizedError
{	public var description: String
	{	message
	}

	public var errorDescription: String?
	{	message
	}
}

/// Where a failure happened, for the error handler.
public struct PersonyzeErrorContext: Sendable, Equatable
{	/// The SDK operation: `navigate`, `refresh`, `flush`, `metadata`, `notifications`, `verdict`, `track`.
	public let operation: String
	/// How many events were kept to send later.
	public let deferred: Int
	/// How many events were dropped.
	public let dropped: Int

	init(operation: String, deferred: Int = 0, dropped: Int = 0)
	{	self.operation = operation
		self.deferred = deferred
		self.dropped = dropped
	}
}

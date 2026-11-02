import Foundation

/// Where push stands on this install (SPEC section 11) - what a screen of the app's, or a support
/// case, can show when notifications do not arrive at once:
///
/// - no `token`: iOS has not given one, or the app has not passed it on (`Personyze.setPushToken`)
///   - the notifications come when the app checks;
/// - a token, no `registeredVisitorId`: not registered with Personyze yet - that happens after the
///   app's first request (a navigation, events or a refresh), and again after a login or logout; or
///   the notifications are off;
/// - registered, not `pushed`: the account has no Apple push key in the Personyze panel
///   (Integrations > App push) - registered all the same, so a key added later reaches this device;
/// - `pushed`: a campaign's notification reaches this device at once.
public struct PersonyzePushStatus: Sendable, Equatable, CustomStringConvertible
{	/// The token passed on, as hex, or nil.
	public let token: String?
	/// The visitor Personyze has this device registered for, or nil.
	public let registeredVisitorId: Int?
	/// When it was last registered, ms since the epoch; 0 for never.
	public let registeredAtMs: Int64
	/// Whether Personyze pushes to this device: the account has its key for the platform.
	public let pushed: Bool

	/// The token cut short: enough to tell two devices apart in a log.
	public var description: String
	{	"PersonyzePushStatus(token: \(token.map { String($0.prefix(10)) + "… (\($0.count))" } ?? "nil"), registeredVisitorId: \(registeredVisitorId.map(String.init) ?? "nil"), registeredAtMs: \(registeredAtMs), pushed: \(pushed))"
	}
}

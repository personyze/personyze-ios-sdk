import Foundation

/// What the engine needs from the device, so the engine itself runs anywhere Swift does, tests
/// included.
protocol Platform: Sendable
{	/// Wall clock, ms since the epoch.
	func nowMs() -> Int64

	/// A clock that never jumps, for deadlines.
	func monotonicMs() -> Int64

	func deviceContext() -> DeviceContext

	/// Whether a notification could be shown now: enabled in the config and allowed by the user.
	/// Sent as `noti_enabled`: true makes push campaigns queue messages for the visitor, which is
	/// pointless where they cannot appear.
	func notificationsShowable() -> Bool

	func isOnline() -> Bool

	/// Have queued events sent later, when the network is back - a background task on iOS.
	func scheduleOutboxFlush()

	/// The app as a push service knows it, or nil where there is no push.
	func pushApp() -> PushApp?

	func log(_ message: String)
}

/// The app a device token is for (SPEC section 11): what `PUT push_token` sends with it.
struct PushApp: Sendable, Equatable
{	/// "ios" or "android".
	var platform: String
	/// The bundle id - the topic Apple pushes it under.
	var appId: String
	/// A development build, whose token only Apple's sandbox serves.
	var sandbox: Bool
}

/// Shows the notifications a "Web Push Send" action queues - the user notification center on
/// iOS, nothing where there is none.
protocol NotificationPresenter: Sendable
{	/// Whether the user allows notifications now.
	func canShow() async -> Bool

	/// Post it. False when it could not be posted.
	func show(_ notification: PersonyzeNotification) async -> Bool

	/// Check for notifications periodically in the background, about every `everySeconds`, or stop.
	func schedulePolling(_ enabled: Bool, everySeconds: Int)
}

/// Where no notification can be shown.
struct NoNotifications: NotificationPresenter
{	func canShow() async -> Bool
	{	false
	}

	func show(_ notification: PersonyzeNotification) async -> Bool
	{	false
	}

	func schedulePolling(_ enabled: Bool, everySeconds: Int)
	{
	}
}

/// A 1.x install's state, read once from its `UserDefaults`.
struct LegacyState: Sendable
{	/// The visitor the stored session belongs to (its field 1). 1.x sent
	/// `identifierForVendor.hashValue` as `user_id`, which Swift reseeds on every launch, so the
	/// session string is the only place its visitor survived.
	var visitorId: Int32?
	var session: String?
	/// As 1.x stored them: oldest first.
	var pastSessionsOldestFirst: [Int64]
	var blocked: [Int: Int]
	var newSession: Bool
	var notiLastCheckMs: Int64
	/// Whether the state is the current API key's. 1.x fingerprinted the key with `hashValue`
	/// too, so its own check failed on every launch; a source that cannot tell answers true.
	var sameAccount: Bool
}

protocol LegacySource: Sendable
{	func read() -> LegacyState?

	/// Delete the 1.x state once the new state is written.
	func delete()
}

#if os(iOS)
import BackgroundTasks
import Foundation
import Network
import UIKit
import UserNotifications

extension ClientEnvironment
{	/// iOS: the device from UIKit, the network from `NWPathMonitor`, notifications from the user
	/// notification center, 1.x's state from `UserDefaults`.
	static func ios(config: PersonyzeConfig, notifications: Locked<Bool>) -> ClientEnvironment
	{	let network = NetworkWatch.shared
		return ClientEnvironment(
			platform: IOSPlatform(notifications: notifications, network: network),
			store: FileStore(dir: storageDirectory(.applicationSupportDirectory, config.storageName, excludeFromBackup: true)),
			cacheStore: FileStore(dir: storageDirectory(.cachesDirectory, config.storageName, excludeFromBackup: false)),
			transport: URLSessionTransport(isOnline: { network.isOnline }),
			legacy: LegacyDefaults(suiteName: nil, cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first),
			presenter: UserNotificationPresenter()
		)
	}
}

/// Run on the main actor: at once when already there - so a client created as the app starts
/// sees UIKit before its first request - else soon.
func onMain(_ body: @escaping @MainActor @Sendable () -> Void)
{	if Thread.isMainThread
	{	MainActor.assumeIsolated(body)
	}
	else
	{	Task { @MainActor in
			body()
		}
	}
}

/// The device as UIKit describes it. UIKit may be read on the main thread only, and the engine asks
/// from any thread, so what it says is kept here and read again whenever the app becomes active.
final class IOSPlatform: Platform, @unchecked Sendable
{	private let notifications: Locked<Bool>
	private let network: NetworkWatch
	private let device = Locked(DeviceSnapshot.unknown)
	private let notificationsAllowed = Locked(false)
	private let observer = Locked<NSObjectProtocol?>(nil)

	init(notifications: Locked<Bool>, network: NetworkWatch)
	{	self.notifications = notifications
		self.network = network
		refresh()
		observer.value = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
			self?.refresh()
		}
	}

	deinit
	{	if let observer = observer.value
		{	NotificationCenter.default.removeObserver(observer)
		}
	}

	/// Read UIKit and the notification settings again.
	func refresh()
	{	let device = device
		onMain
		{	device.withLock
			{	$0 = DeviceSnapshot.read(keepingScreen: $0.screen)
			}
		}
		let allowed = notificationsAllowed
		Task {
			allowed.value = await UserNotificationPresenter.allowed()
		}
	}

	func nowMs() -> Int64
	{	Clocks.nowMs()
	}

	func monotonicMs() -> Int64
	{	Clocks.monotonicMs()
	}

	func deviceContext() -> DeviceContext
	{	let d = device.value
		return DeviceContext(
			platform: d.platform,
			timeZone: Double(TimeZone.autoupdatingCurrent.secondsFromGMT())/3600,
			languages: Locale.preferredLanguages.prefix(3).joined(separator: ","),
			screen: d.screen,
			os: d.os,
			deviceType: d.deviceType
		)
	}

	func notificationsShowable() -> Bool
	{	notifications.value && notificationsAllowed.value
	}

	func isOnline() -> Bool
	{	network.isOnline
	}

	/// No network now: send when it returns, and failing that when iOS next runs the app's
	/// background refresh.
	func scheduleOutboxFlush()
	{	network.flushWhenOnline()
		BackgroundRefresh.schedule(after: 60)
	}

	func log(_ message: String)
	{	Log.write(message)
	}
}

/// What UIKit says about the device, kept for the engine's threads.
struct DeviceSnapshot: Sendable
{	var platform: String
	var os: String
	var screen: String
	var deviceType: String

	/// Before the first read on the main thread.
	static var unknown: DeviceSnapshot
	{	let v = ProcessInfo.processInfo.operatingSystemVersion
		return DeviceSnapshot(platform: "iOS", os: "iOS/\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", screen: "", deviceType: "phone")
	}

	/// `platform` and `os` as 1.x sent them (`iOS`, `iPadOS`), and its rule for `device_type`, so
	/// segments do not move. The screen in portrait points, as Safari's `screen.width` and
	/// `screen.height` give it on the same phone - 1.x sent the bounds of the moment, as
	/// `390.0x844.0`. Read from a connected scene (`UIScreen.main` is deprecated): before the first
	/// one connects, the last known screen stays.
	@MainActor
	static func read(keepingScreen known: String) -> DeviceSnapshot
	{	let d = UIDevice.current
		var screen = known
		if let s = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.screen, s.nativeScale > 0
		{	let size = s.nativeBounds.size
			screen = "\(Int((size.width/s.nativeScale).rounded()))x\(Int((size.height/s.nativeScale).rounded()))"
		}
		let deviceType: String
		switch d.userInterfaceIdiom
		{	case .phone:
				deviceType = "phone"
			case .pad:
				deviceType = "tablet"
			default:
				deviceType = "regular"
		}
		return DeviceSnapshot(platform: d.systemName, os: "\(d.systemName)/\(d.systemVersion)", screen: screen, deviceType: deviceType)
	}
}

/// Whether the device has a network, from `NWPathMonitor`, and a send of the queued events when it
/// comes back - what WorkManager's network constraint does on Android, while the app runs.
final class NetworkWatch: @unchecked Sendable
{	static let shared = NetworkWatch()

	private let monitor = NWPathMonitor()
	private let state = Locked((online: true, flushPending: false))

	private init()
	{	monitor.pathUpdateHandler = { [weak self] path in
			self?.update(online: path.status == .satisfied)
		}
		monitor.start(queue: DispatchQueue(label: "com.personyze.network"))
	}

	var isOnline: Bool
	{	state.value.online
	}

	func flushWhenOnline()
	{	state.withLock
		{	$0.flushPending = true
		}
	}

	private func update(online: Bool)
	{	let flush = state.withLock
		{	s -> Bool in
			let back = online && !s.online
			s.online = online
			if back && s.flushPending
			{	s.flushPending = false
				return true
			}
			return false
		}
		if flush, let client = Personyze.client
		{	Task {
				_ = await client.flushInBackground()
			}
		}
	}
}

/// One background app refresh task for both background jobs - sending queued events, checking for
/// a notification. iOS runs it when it sees fit, and only for an app that declares it: the
/// identifier in `BGTaskSchedulerPermittedIdentifiers` and `fetch` in `UIBackgroundModes`. Without
/// them both jobs happen while the app runs; registering an undeclared identifier would stop the
/// app, so the declaration is looked up first.
enum BackgroundRefresh
{	static let identifier = "com.personyze.sdk.refresh"

	private static let state = Locked((registered: false, pending: nil as Date?))

	static func registerIfDeclared()
	{	let declared = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])?.contains(identifier) ?? false
		if !declared
		{	return
		}
		let first = state.withLock
		{	s -> Bool in
			defer
			{	s.registered = true
			}
			return !s.registered
		}
		if first
		{	BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
				run(BackgroundTaskBox(task))
			}
		}
	}

	/// Ask iOS to run the task no sooner than `seconds` from now. An earlier request still pending
	/// stays: one task does both jobs.
	static func schedule(after seconds: TimeInterval)
	{	let date = Date(timeIntervalSinceNow: seconds)
		let submit = state.withLock
		{	s -> Bool in
			if !s.registered
			{	return false
			}
			if let pending = s.pending, pending > Date(), pending <= date
			{	return false
			}
			s.pending = date
			return true
		}
		if !submit
		{	return
		}
		let request = BGAppRefreshTaskRequest(identifier: identifier)
		request.earliestBeginDate = date
		do
		{	try BGTaskScheduler.shared.submit(request)
		}
		catch
		{	Log.write("Personyze: background refresh not scheduled: \(error)")
		}
	}

	/// The API key is never stored, so this works only in a process where the app called
	/// `Personyze.initialize` - which a launch for background refresh does, as any launch.
	private static func run(_ box: BackgroundTaskBox)
	{	state.withLock
		{	$0.pending = nil
		}
		let work = Task {
			var sent = true
			if let client = Personyze.client
			{	sent = await client.flushInBackground()
				if client.notificationsWanted
				{	_ = await client.checkNotifications(force: false)
					schedule(after: 15*60)
				}
				if !sent
				{	schedule(after: 15*60)
				}
			}
			box.complete(sent)
		}
		box.task.expirationHandler = {
			work.cancel()
			box.complete(false)
		}
	}
}

/// A background task, completed once - by its work or by its expiry, whichever comes first.
private final class BackgroundTaskBox: @unchecked Sendable
{	let task: BGTask
	private let done = Locked(false)

	init(_ task: BGTask)
	{	self.task = task
	}

	func complete(_ success: Bool)
	{	let first = done.withLock
		{	d -> Bool in
			defer
			{	d = true
			}
			return !d
		}
		if first
		{	task.setTaskCompleted(success: success)
		}
	}
}

/// The app's foreground and background, for the current client. Queued events go out as the app
/// leaves, under a background task that keeps the process running for them; and when it becomes
/// active, with a check for a notification.
@MainActor
enum AppLifecycle
{	private static var installed = false

	static func install()
	{	if installed
		{	return
		}
		installed = true
		let center = NotificationCenter.default
		_ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated
			{	didEnterBackground()
			}
		}
		_ = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
			MainActor.assumeIsolated
			{	didBecomeActive()
			}
		}
	}

	private static func didEnterBackground()
	{	guard let client = Personyze.client, client.engine.hasPending() else
		{	return
		}
		let handle = BackgroundTaskHandle()
		handle.begin()
		Task { @MainActor in
			_ = await client.flushInBackground()
			if client.engine.hasPending()
			{	BackgroundRefresh.schedule(after: 60)
			}
			handle.end()
		}
	}

	private static func didBecomeActive()
	{	guard let client = Personyze.client else
		{	return
		}
		Task {
			_ = await client.flushInBackground()
			if client.notificationsWanted
			{	_ = await client.checkNotifications(force: false)
			}
		}
	}
}

/// `UIApplication.beginBackgroundTask`: a few seconds more to run after the app leaves the
/// foreground, ended when the work is done or the time is up.
@MainActor
private final class BackgroundTaskHandle
{	private var id = UIBackgroundTaskIdentifier.invalid

	func begin()
	{	id = UIApplication.shared.beginBackgroundTask(withName: "Personyze") { [weak self] in
			MainActor.assumeIsolated
			{	self?.end()
			}
		}
	}

	func end()
	{	if id != .invalid
		{	UIApplication.shared.endBackgroundTask(id)
			id = .invalid
		}
	}
}
#endif

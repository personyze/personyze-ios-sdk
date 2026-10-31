import Foundation
#if canImport(os)
import os
#endif

/// What a client is built from besides its config: the device, the disk, the network,
/// notifications. iOS has its own; tests have fakes; `system` serves macOS and Linux.
struct ClientEnvironment: Sendable
{	var platform: any Platform
	var store: any Store
	var cacheStore: any Store
	var transport: any Transport
	var legacy: (any LegacySource)?
	var presenter: any NotificationPresenter

	/// The environment for this OS.
	static func current(config: PersonyzeConfig, notifications: Locked<Bool>) -> ClientEnvironment
	{	#if os(iOS)
		return ios(config: config, notifications: notifications)
		#else
		return system(config: config)
		#endif
	}

	/// Foundation only: no screen, no notifications, always online.
	static func system(config: PersonyzeConfig) -> ClientEnvironment
	{	let platform = SystemPlatform()
		return ClientEnvironment(
			platform: platform,
			store: FileStore(dir: storageDirectory(.applicationSupportDirectory, config.storageName, excludeFromBackup: true)),
			cacheStore: FileStore(dir: storageDirectory(.cachesDirectory, config.storageName, excludeFromBackup: false)),
			transport: URLSessionTransport(),
			legacy: nil,
			presenter: NoNotifications()
		)
	}

	/// `<base>/Personyze/<storage name>`. On a Mac the app's bundle id goes between, since apps
	/// outside the sandbox share one Application Support folder. Excluded from backup when asked:
	/// restored onto another device, the install's anonymous id would make two devices one
	/// visitor (SPEC section 11).
	static func storageDirectory(_ base: FileManager.SearchPathDirectory, _ storageName: String, excludeFromBackup: Bool) -> URL
	{	let fm = FileManager.default
		var dir = fm.urls(for: base, in: .userDomainMask).first ?? fm.temporaryDirectory
		dir.appendPathComponent("Personyze", isDirectory: true)
		#if os(macOS)
		dir.appendPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
		#endif
		dir.appendPathComponent(storageName, isDirectory: true)
		try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
		#if canImport(Darwin)
		if excludeFromBackup
		{	var values = URLResourceValues()
			values.isExcludedFromBackup = true
			try? dir.setResourceValues(values)
		}
		#endif
		return dir
	}
}

/// The device as Foundation sees it - enough for macOS and Linux. iOS has its own, with the
/// screen and the device type.
struct SystemPlatform: Platform
{	func nowMs() -> Int64
	{	Clocks.nowMs()
	}

	func monotonicMs() -> Int64
	{	Clocks.monotonicMs()
	}

	func deviceContext() -> DeviceContext
	{	let v = ProcessInfo.processInfo.operatingSystemVersion
		return DeviceContext(
			platform: SystemPlatform.osName,
			timeZone: Double(TimeZone.current.secondsFromGMT())/3600,
			languages: Locale.preferredLanguages.joined(separator: ","),
			screen: "",
			os: "\(SystemPlatform.osName)/\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
			deviceType: "regular"
		)
	}

	func notificationsShowable() -> Bool
	{	false
	}

	func isOnline() -> Bool
	{	true
	}

	func scheduleOutboxFlush()
	{
	}

	/// No push here: no device token to register.
	func pushApp() -> PushApp?
	{	nil
	}

	func log(_ message: String)
	{	Log.write(message)
	}

	private static var osName: String
	{	#if os(macOS)
		return "macOS"
		#elseif os(iOS)
		return "iOS"
		#elseif os(tvOS)
		return "tvOS"
		#elseif os(watchOS)
		return "watchOS"
		#elseif os(visionOS)
		return "visionOS"
		#elseif os(Linux)
		return "Linux"
		#else
		return "unknown"
		#endif
	}
}

/// The SDK's own log: the unified log on Apple's platforms, standard error elsewhere.
enum Log
{	#if canImport(os)
	private static let logger = Logger(subsystem: "com.personyze.sdk", category: "Personyze")
	#endif

	static func write(_ message: String)
	{	#if canImport(os)
		logger.log("\(message, privacy: .public)")
		#else
		FileHandle.standardError.write(Data((message + "\n").utf8))
		#endif
	}
}

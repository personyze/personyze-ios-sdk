import Foundation

/// How the SDK talks to Personyze:
///
/// ```swift
/// Personyze.initialize(PersonyzeConfig(apiKey: "YOUR_API_KEY") { $0.notifications = true })
/// ```
///
/// The API key is a secret with account-wide access. The SDK never logs it and never stores it,
/// which is why `Personyze.initialize` belongs where the app starts (`App.init` or
/// `application(_:didFinishLaunchingWithOptions:)`): a background task finds the key only in a
/// process the app initialized.
public struct PersonyzeConfig: Sendable, CustomStringConvertible
{	public static let defaultBaseUrl = "https://app.personyze.com"
	public static let defaultAssetsUrl = "https://counter.personyze.com/"

	let apiKey: String

	/// Where `/rest` lives. Only https is accepted: the key goes in every request.
	public var baseUrl = PersonyzeConfig.defaultBaseUrl

	/// Where Personyze's web view library and helper scripts are served, and the origin rendered
	/// actions run under.
	public var assetsUrl = PersonyzeConfig.defaultAssetsUrl

	/// Seconds for one decision - every attempt, the retry included: name lookup, connect, TLS,
	/// the whole answer. A slower answer is a failure, and the app renders its default.
	public var timeout: TimeInterval = 5

	/// Seconds for what no screen waits for: queued events, templates, notifications.
	public var backgroundTimeout: TimeInterval = 10

	/// 0 or 1. One retry, only for a connection failure, a timeout or a 5xx, and only inside the
	/// time budget.
	public var retries = 1

	/// Receive notifications from "Web Push Send" actions: a check every 15 minutes, in the
	/// background too. The app asks the user's permission itself.
	public var notifications = false

	/// Seconds queued events wait for more before going out by themselves; nil means only with the
	/// next navigation, `flush()` or the app going to the background.
	public var autoFlushDelay: TimeInterval? = 3

	/// Keeps a separate visitor and state under this name - a second account, or a test. Letters,
	/// digits, `-` and `_`.
	public var storageName = "default"

	/// Every failure the SDK absorbs. Called on a background queue.
	public var onError: (@Sendable (PersonyzeError, PersonyzeErrorContext) -> Void)?

	public init(apiKey: String, _ configure: (inout PersonyzeConfig) -> Void = { _ in })
	{	self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
		configure(&self)
	}

	/// What is wrong with this config, or nil. `Personyze.initialize` stops the app on it: each is
	/// a mistake in the app's code, seen on its first run.
	var problem: String?
	{	if apiKey.isEmpty
		{	return "Personyze: the API key is empty"
		}
		if !baseUrl.hasPrefix("https://")
		{	return "Personyze: baseUrl must be https:// - the API key is sent with every request (got \(baseUrl))"
		}
		if !assetsUrl.hasPrefix("https://")
		{	return "Personyze: assetsUrl must be https:// (got \(assetsUrl))"
		}
		if !(timeout > 0) || !(backgroundTimeout > 0)
		{	return "Personyze: timeouts must be positive"
		}
		if !(0 ... 1).contains(retries)
		{	return "Personyze: retries must be 0 or 1"
		}
		let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
		if storageName.isEmpty || storageName.count > 64 || !storageName.allSatisfy(allowed.contains)
		{	return "Personyze: storageName may hold letters, digits, '-' and '_' only"
		}
		return nil
	}

	/// Same settings, so initializing again changes nothing. `onError` is not compared.
	func sameAs(_ other: PersonyzeConfig) -> Bool
	{	apiKey == other.apiKey && baseUrl == other.baseUrl && assetsUrl == other.assetsUrl && timeout == other.timeout &&
			backgroundTimeout == other.backgroundTimeout && retries == other.retries && notifications == other.notifications &&
			autoFlushDelay == other.autoFlushDelay && storageName == other.storageName
	}

	var engineConfig: EngineConfig
	{	EngineConfig(
			apiKey: apiKey,
			baseUrl: baseUrl.hasSuffix("/") ? String(baseUrl.reversed().drop { $0 == "/" }.reversed()) : baseUrl,
			assetsUrl: assetsUrl.hasSuffix("/") ? assetsUrl : assetsUrl + "/",
			timeoutMs: Int64(timeout*1000),
			backgroundTimeoutMs: Int64(backgroundTimeout*1000),
			retries: retries,
			autoFlushDelayMs: autoFlushDelay.map { Int64($0*1000) },
			userAgent: "personyze-ios/\(Personyze.sdkVersion)"
		)
	}

	public var description: String
	{	"PersonyzeConfig(apiKey: ***, baseUrl: \(baseUrl), timeout: \(timeout), notifications: \(notifications), storageName: \(storageName))"
	}
}

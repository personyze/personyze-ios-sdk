import Foundation
import Testing
@testable import Personyze

let testKey = "0123456789ABCDEF0123456789ABCDEF01234567"
let testBase = "https://app.personyze.com"
let testAssets = "https://counter.personyze.com/"
/// A fixed moment (2025-10-23 12:00 UTC), in ms.
let t0: Int64 = 1_761_220_800_000

/// A platform whose wall clock stands still until a test moves it, as the Android tests' virtual
/// clock did - a session opened late in a slow first test still starts at `t0` (an iOS Simulator
/// starting cold took over a second, and `past_sessions` read one second on). The monotonic clock
/// is real: Swift has no virtual one, so the budgets here are short instead.
final class FakePlatform: Platform, @unchecked Sendable
{	private let lock = NSLock()
	private var wall = t0
	private var isOnlineNow = true
	private var showableNow = false
	private var outboxScheduledCount = 0

	var device = DeviceContext(platform: "iOS", timeZone: 3, languages: "en-US,he-IL", screen: "390x844", os: "iOS/17.2", deviceType: "phone")

	/// Move the wall clock (not the monotonic one).
	func advanceWall(_ ms: Int64)
	{	lock.locked
		{	wall += ms
		}
	}

	var outboxScheduled: Int
	{	lock.locked
		{	outboxScheduledCount
		}
	}

	func nowMs() -> Int64
	{	lock.locked
		{	wall
		}
	}

	func monotonicMs() -> Int64
	{	Clocks.monotonicMs()
	}

	func deviceContext() -> DeviceContext
	{	device
	}

	func notificationsShowable() -> Bool
	{	lock.locked
		{	showableNow
		}
	}

	func isOnline() -> Bool
	{	lock.locked
		{	isOnlineNow
		}
	}

	func scheduleOutboxFlush()
	{	lock.locked
		{	outboxScheduledCount += 1
		}
	}

	func log(_ message: String)
	{
	}
}

typealias Step = @Sendable (HttpRequest) async -> HttpOutcome

/// Answers by URL: each route has a queue of steps, the last one repeating. A request no route
/// expects fails the test.
final class FakeTransport: Transport, @unchecked Sendable
{	private let lock = NSLock()
	private var routes: [(path: String, steps: [Step])] = []
	private var recorded: [HttpRequest] = []

	@discardableResult
	func on(_ pathContains: String, _ steps: Step...) -> FakeTransport
	{	lock.locked
		{	if let i = routes.firstIndex(where: { $0.path == pathContains })
			{	routes[i].steps += steps
			}
			else
			{	routes.append((pathContains, steps))
			}
		}
		return self
	}

	@discardableResult
	func tracker(_ steps: Step...) -> FakeTransport
	{	lock.locked
		{	routes.append(("/rest/tracker-v1", steps))
		}
		return self
	}

	var requests: [HttpRequest]
	{	lock.locked
		{	recorded
		}
	}

	func trackerRequests() -> [HttpRequest]
	{	requests.filter { $0.url.absoluteString.hasSuffix("/rest/tracker-v1") }
	}

	func bodies() -> [JSON]
	{	trackerRequests().map { JSON.parse($0.body ?? "") ?? .null }
	}

	func execute(_ request: HttpRequest, timeoutMs: Int64) async -> HttpOutcome
	{	let url = request.url.absoluteString
		let step = lock.locked
		{	() -> Step? in
			recorded.append(request)
			guard let i = routes.firstIndex(where: { url.contains($0.path) }) else
			{	return nil
			}
			return routes[i].steps.count > 1 ? routes[i].steps.removeFirst() : routes[i].steps.first
		}
		guard let step else
		{	Issue.record("unexpected request \(request.method) \(url)")
			return .failed(sent: false, timedOut: false, offline: false, reason: "unexpected")
		}
		// The transport's own deadline, as URLSessionTransport keeps it.
		return await withTaskGroup(of: HttpOutcome?.self) { group in
			group.addTask {
				await step(request)
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 0))*1_000_000)
				return nil
			}
			let first = await group.next() ?? nil
			group.cancelAll()
			return first ?? .failed(sent: true, timedOut: true, offline: false, reason: "timeout")
		}
	}
}

func pause(_ ms: Int64) async
{	try? await Task.sleep(nanoseconds: UInt64(ms)*1_000_000)
}

func ok(_ body: String, delayMs: Int64 = 0, dateMs: Int64? = nil) -> Step
{	{ _ in
		await pause(delayMs)
		return .answered(status: 200, body: body, dateMs: dateMs)
	}
}

func status(_ code: Int, _ body: String = "", delayMs: Int64 = 0) -> Step
{	{ _ in
		await pause(delayMs)
		return .answered(status: code, body: body, dateMs: nil)
	}
}

func fail(sent: Bool, timedOut: Bool = false, delayMs: Int64 = 0) -> Step
{	{ _ in
		await pause(delayMs)
		return .failed(sent: sent, timedOut: timedOut, offline: false, reason: sent ? "reset" : "refused")
	}
}

/// A session string as the tracker builds it: start, visitor, visit, counter, last session, testing, hosts, social.
func session(_ startSec: Int64, _ visitor: Int64, counter: Int = 1) -> String
{	"\(startSec) \(visitor) 77 \(counter) \(startSec) 0 491,492 0"
}

func trackerAnswer
(	_ session: String?,
	cacheVersion: Int = 5,
	conditions: [Int] = [],
	actions: String = "[]",
	dismissActions: [Int] = [],
	dismissConditions: [Int] = []
) -> String
{	let sid = session.map { "\"\($0)\"" } ?? "null"
	let conditionsJson = conditions.map { "{\"id\":\($0)}" }.joined(separator: ",")
	return "{\"session_id\":\(sid),\"cache_version\":\(cacheVersion),\"conditions\":[\(conditionsJson)],\"actions\":\(actions),\"dismiss_conditions\":\(dismissConditions),\"dismiss_actions\":\(dismissActions)}"
}

/// Answers like `tracker_v1.ts` does as far as sessions go: a request with no session, or with
/// `new_session`, opens one (start = now, counter + 1); a valid session is kept, and its field 1 -
/// not `user_id` - is the visitor (SPEC section 3).
final class FakeTracker: @unchecked Sendable
{	private let lock = NSLock()
	private let nowSec: @Sendable () -> Int64
	private var counters: [Int64: Int] = [:]
	private var seenBodies: [JSON] = []
	private var settings = Settings()

	struct Settings
	{	var cacheVersion = 5
		var conditions: [Int] = []
		var actions = "[]"
		/// As the real tracker: new actions only for a request with a navigation (SPEC section 4).
		var actionsOnlyWithNavigate = true
		var dismissActions: [Int] = []
	}

	init(nowSec: @escaping @Sendable () -> Int64)
	{	self.nowSec = nowSec
	}

	func configure(_ change: (inout Settings) -> Void)
	{	lock.locked
		{	change(&settings)
		}
	}

	var seen: [JSON]
	{	lock.locked
		{	seenBodies
		}
	}

	func step() -> Step
	{	{ [self] request in
			let body = JSON.parse(request.body ?? "") ?? .null
			let answer = lock.locked
			{	() -> String in
				seenBodies.append(body)
				let sid = body.str("session_id")
				let user: UserId
				if case .int(let n)? = body["user_id"]
				{	user = .number(n)
				}
				else
				{	user = .text(body.str("user_id") ?? "")
				}
				let visitor = Session.visitor(sid) ?? Int64(Session.serverUserId(user) ?? 0)
				let current: String
				if sid == nil || body.bool("new_session")
				{	let counter = (counters[visitor] ?? 0) + 1
					counters[visitor] = counter
					current = session(nowSec(), visitor, counter: counter)
				}
				else
				{	current = sid!
				}
				let navigated = body.commands().contains { $0.first == "Navigate" }
				let actions = navigated || !settings.actionsOnlyWithNavigate ? settings.actions : "[]"
				return trackerAnswer(current, cacheVersion: settings.cacheVersion, conditions: settings.conditions, actions: actions, dismissActions: settings.dismissActions)
			}
			return .answered(status: 200, body: answer, dateMs: nil)
		}
	}
}

extension JSON
{	func str(_ name: String) -> String?
	{	if case .string(let s)? = self[name]
		{	return s
		}
		return nil
	}

	func bool(_ name: String) -> Bool
	{	self[name] == .bool(true)
	}

	func commands() -> [[String?]]
	{	(self["commands"]?.arrayValue ?? []).map { cmd in
			(cmd.arrayValue ?? []).map { arg in
				if case .string(let s) = arg
				{	return s
				}
				return nil
			}
		}
	}
}

final class ErrorLog: @unchecked Sendable
{	private let lock = NSLock()
	private var entries: [(error: PersonyzeError, context: PersonyzeErrorContext)] = []

	func add(_ error: PersonyzeError, _ context: PersonyzeErrorContext)
	{	lock.locked
		{	entries.append((error, context))
		}
	}

	/// Filled asynchronously: read after `engine.idle()`.
	var all: [(error: PersonyzeError, context: PersonyzeErrorContext)]
	{	lock.locked
		{	entries
		}
	}
}

final class FakeLegacy: LegacySource, @unchecked Sendable
{	private let lock = NSLock()
	private let state: LegacyState
	private var wasDeleted = false

	init(_ state: LegacyState)
	{	self.state = state
	}

	var deleted: Bool
	{	lock.locked
		{	wasDeleted
		}
	}

	func read() -> LegacyState?
	{	state
	}

	func delete()
	{	lock.locked
		{	wasDeleted = true
		}
	}
}

struct Harness
{	let engine: Engine
	let transport: FakeTransport
	let platform: FakePlatform
	let store: MemoryStore
	let cache: MemoryStore
	let errors: ErrorLog
	let tracker: FakeTracker

	/// With no `transport`, every tracker request goes to a `FakeTracker` on `platform`'s clock.
	/// `setUp` runs before the engine starts loading - which it does at once, not when a virtual
	/// clock is advanced as in the Android tests.
	init
	(	transport: FakeTransport? = nil,
		store: MemoryStore = MemoryStore(),
		cache: MemoryStore = MemoryStore(),
		legacy: (any LegacySource)? = nil,
		autoFlushMs: Int64? = nil,
		timeoutMs: Int64 = 5000,
		apiKey: String = testKey,
		platform: FakePlatform = FakePlatform(),
		setUp: (FakeTransport, FakeTracker) -> Void = { _, _ in }
	)
	{	let errors = ErrorLog()
		let tracker = FakeTracker { [platform] in platform.nowMs()/1000 }
		let transport = transport ?? FakeTransport().tracker(tracker.step())
		setUp(transport, tracker)
		self.engine = Engine(
			config: EngineConfig(
				apiKey: apiKey,
				baseUrl: testBase,
				assetsUrl: testAssets,
				timeoutMs: timeoutMs,
				backgroundTimeoutMs: 10_000,
				retries: 1,
				autoFlushDelayMs: autoFlushMs,
				userAgent: "personyze-ios/test"
			),
			platform: platform,
			store: store,
			cacheStore: cache,
			transport: transport,
			legacy: legacy,
			onError: { error, context in errors.add(error, context) },
			owner: { nil }
		)
		self.transport = transport
		self.platform = platform
		self.store = store
		self.cache = cache
		self.errors = errors
		self.tracker = tracker
	}
}

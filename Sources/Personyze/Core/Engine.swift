import Foundation

struct EngineConfig: Sendable
{	var apiKey: String
	var baseUrl: String
	var assetsUrl: String
	var timeoutMs: Int64
	var backgroundTimeoutMs: Int64
	var retries: Int
	/// Nil: queued events wait for a navigation, `flush()` or the app leaving the foreground.
	var autoFlushDelayMs: Int64?
	var userAgent: String
}

/// The client's state machine. Foundation only - no UIKit - so all of it runs in tests on Linux.
/// A port of the Android SDK's `Engine.kt`; where the two differ, the difference is noted.
///
/// **Threads.** Event calls come from any thread, the main one included, and only append to the
/// queue under `lock` (short sections, no network). One tracker round trip at a time (`wire`):
/// each request carries the session the previous response returned, so two in flight would fork
/// it. Template fetches (`meta`) run outside `wire`. `lock` is not reentrant, unlike Kotlin's
/// `synchronized`: nothing that takes it is called while holding it, and the `...Locked` methods
/// expect it held.
///
/// **What makes a request** (SPEC section 3): the visitor (`user_id`) is the app's user id or the
/// install's anonymous id; a stored session of another visitor is no session; `new_session` is
/// computed - a forced new session, no session, or one older than 90 minutes - never constant.
///
/// **What survives** a failure or the app being killed (SPEC section 5 - the endpoint is not
/// idempotent, and a purchase counted twice is worse than one missing): queued events are on disk.
/// A request that surely never left the device (no network, name lookup, connect, TLS) keeps its
/// events for later, except a navigation - a page view sent hours late is a wrong page view. A
/// request that may have arrived is not sent again beyond the one retry inside the budget, and the
/// failure reaches the error handler with the commands lost.
final class Engine: @unchecked Sendable
{	static let stateFile = "state.json"
	static let outboxFile = "outbox.json"
	static let visitorFile = "visitor"
	static let metadataFile = "metadata.json"

	/// Anonymous ids below this are reserved (SPEC section 10.1).
	static let minAnonymousId: Int32 = 500_000_000
	/// The web tag keeps 12 (`WConf::$n_remember_past_sessions_time`). 1.x kept 2, oldest first,
	/// which the rule engine read as no recent sessions at all.
	static let pastSessionsKept = 12
	static let throttleMs: Int64 = 10*60_000
	static let maxAgeMs: Int64 = 24*3600_000
	static let maxPending = 1000
	static let maxPendingChars = 200_000
	static let bodyOverhead = 1000
	static let metadataChunk = 200
	static let notificationIntervalMs: Int64 = 15*60_000
	static let deliveredKept = 20
	/// Notification reports not sent yet, kept until they are; the oldest go first past this.
	static let reportsKept = 10
	/// A check as the app comes to the front, at most this often.
	static let foregroundCheckMs: Int64 = 60_000
	/// A background check where Personyze pushes to the device.
	static let pushedCheckMs: Int64 = 6*3600_000
	/// A device registered for push is registered again after this, so Personyze keeps it.
	static let pushRegisterAgainMs: Int64 = 7*24*3600_000
	static let clockSkewMs: Int64 = 60_000
	static let maxSafeInteger: Int64 = 9_007_199_254_740_991

	private let config: EngineConfig
	private let platform: any Platform
	private let store: any Store
	private let cacheStore: any Store
	private let legacy: (any LegacySource)?
	private let onError: @Sendable (PersonyzeError, PersonyzeErrorContext) -> Void
	private let owner: @Sendable () -> (any ActionReporter)?
	private let rest: RestClient
	private let apiKeyFp: String

	private let lock = NSLock()
	private let persistLock = NSLock()
	private let metaPersistLock = NSLock()
	private let signalLock = NSLock()
	private let wire = AsyncMutex()
	private let meta = AsyncMutex()
	/// One pass over the notification reports at a time, so none goes twice.
	private let reportWire = AsyncMutex()
	/// One push registration at a time.
	private let pushWire = AsyncMutex()
	private let loaded = Latch()
	private let tasks = TaskSet()
	/// Saves, off the caller's thread, in order.
	private let io = DispatchQueue(label: "com.personyze.engine.io")
	/// The error handler, called in order.
	private let callbacks = DispatchQueue(label: "com.personyze.engine.callbacks")

	// Guarded by `lock`.
	private var isLoaded = false
	private var deferredOps: [() -> Void] = []
	private var state = PersistedState()
	private var pending: [PendingItem] = []
	private var seq: Int64 = 1
	private var installVisitor: Int32 = 0
	private var metadata = MetadataFile(apiKeyFp: nil)
	private var autoFlushTask: Task<Void, Never>?

	// Guarded by `signalLock`.
	private var persistScheduled = false

	let result = StateCell(PersonyzeResult.empty)
	let visitor = StateCell(PersonyzeVisitor(userId: nil, visitorId: nil, sessionId: nil))
	let push = StateCell(PersonyzePushStatus(token: nil, registeredVisitorId: nil, registeredAtMs: 0, pushed: false))

	init
	(	config: EngineConfig,
		platform: any Platform,
		store: any Store,
		cacheStore: any Store,
		transport: any Transport,
		legacy: (any LegacySource)?,
		onError: @escaping @Sendable (PersonyzeError, PersonyzeErrorContext) -> Void,
		owner: @escaping @Sendable () -> (any ActionReporter)?
	)
	{	self.config = config
		self.platform = platform
		self.store = store
		self.cacheStore = cacheStore
		self.legacy = legacy
		self.onError = onError
		self.owner = owner
		rest = RestClient(
			transport: transport,
			apiKey: config.apiKey,
			baseUrl: config.baseUrl,
			retries: config.retries,
			monotonicMs: { [platform] in platform.monotonicMs() },
			userAgent: config.userAgent
		)
		apiKeyFp = String(SHA256.hex(config.apiKey).prefix(16))
		tasks.run { [self] in
			load()
		}
	}

	// MARK: - load

	private func load()
	{	let storedVisitor = store.read(Engine.visitorFile).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 == 0 ? nil : $0 }
		var st: PersistedState?
		if let text = store.read(Engine.stateFile)
		{	st = StateCoding.decode(PersistedState.self, text)
			if st == nil
			{	platform.log("Personyze: state.json is corrupt, starting over (kept as state.json.corrupt)")
				store.quarantine(Engine.stateFile)
			}
		}
		var outbox = store.read(Engine.outboxFile).flatMap { StateCoding.decode(OutboxFile.self, $0)?.items } ?? []
		var installId = storedVisitor
		var migrated = false
		if st == nil, let old = legacy?.read()
		{	// The 1.x visitor is kept: it is the visitor's history and A/B arms.
			if installId == nil, let id = old.visitorId, id != 0
			{	installId = id
			}
			var fresh = PersistedState(apiKeyFp: apiKeyFp)
			if old.sameAccount
			{	fresh.session = old.session
				fresh.pastSessions = Array(old.pastSessionsOldestFirst.reversed().prefix(Engine.pastSessionsKept))
				fresh.blocked = old.blocked
				fresh.epoch = old.newSession ? 1 : 0
			}
			fresh.notifications = PersistedNotifications(lastCheckMs: old.notiLastCheckMs, primeOnNextPoll: old.notiLastCheckMs > 0)
			st = fresh
			migrated = true
		}
		let visitorId = installId ?? Engine.newAnonymousId()
		if visitorId != storedVisitor
		{	store.write(Engine.visitorFile, String(visitorId), sync: true)
		}
		var loadedState = st ?? PersistedState(apiKeyFp: apiKeyFp)
		if let fp = loadedState.apiKeyFp, fp != apiKeyFp
		{	// Another account: its session, history and queue mean nothing here.
			loadedState = PersistedState(apiKeyFp: apiKeyFp, userId: loadedState.userId)
			outbox = []
		}
		loadedState.apiKeyFp = apiKeyFp
		let cacheVersion = loadedState.cacheVersion
		let cached = cacheStore.read(Engine.metadataFile).flatMap { StateCoding.decode(MetadataFile.self, $0) }
		let md = cached.flatMap { $0.apiKeyFp == apiKeyFp && $0.cacheVersion == cacheVersion ? $0 : nil } ?? MetadataFile(apiKeyFp: apiKeyFp, cacheVersion: cacheVersion)
		let interrupted = outbox.filter { $0.inflight }
		let kept = outbox.filter { !$0.inflight && !$0.navigate }
		lock.locked
		{	state = loadedState
			metadata = md
			installVisitor = visitorId
			pending = kept
			seq = (kept.map { $0.seq }.max() ?? 0) + 1
			markLoadedLocked()
		}
		if migrated || !interrupted.isEmpty
		{	persistNow()
		}
		if migrated
		{	legacy?.delete()
		}
		if !interrupted.isEmpty
		{	report(
				.delivery(
					reason: .interrupted,
					commands: interrupted.map { $0.wireCommand },
					message: "The app stopped while \(interrupted.count) events were being sent; they may or may not have arrived, and are not sent again",
					cause: nil
				),
				PersonyzeErrorContext(operation: "flush", dropped: interrupted.count)
			)
		}
		if needsMetadata()
		{	fetchMetadataInBackground()
		}
		lock.locked
		{	if !pending.isEmpty
			{	scheduleAutoFlushLocked()
			}
		}
	}

	private func markLoadedLocked()
	{	isLoaded = true
		let ops = deferredOps
		deferredOps = []
		for op in ops
		{	op()
		}
		emitLocked()
		loaded.open()
	}

	/// Run `op` under the lock now, or - before the stored state is loaded - right after loading,
	/// in call order. Events queued during startup are tagged with the visitor the app set, not the
	/// one on disk before it.
	private func mutate(_ op: @escaping () -> Void)
	{	lock.locked
		{	if isLoaded
			{	op()
			}
			else
			{	deferredOps.append(op)
			}
		}
	}

	// MARK: - events

	/// `build` throws what `Commands` refuses. A plain `throws`: Swift does not infer a closure's
	/// typed throws from its body, so a typed parameter would not take `{ try Commands.x(...) }`.
	func enqueue(raw: Bool = false, _ build: () throws -> Command)
	{	let cmd: Command
		do
		{	cmd = try build()
		}
		catch
		{	report((error as? PersonyzeError) ?? .invalid(message: "Personyze: \(error)"), PersonyzeErrorContext(operation: "track", dropped: 1))
			return
		}
		mutate { [self] in
			addLocked(cmd, raw: raw)
			persistSoon()
			scheduleAutoFlushLocked()
		}
	}

	@discardableResult
	private func addLocked(_ cmd: Command, raw: Bool, navigate: Bool = false) -> PendingItem?
	{	if Commands.isActionStatus(cmd) && !acceptStatusLocked(cmd)
		{	return nil
		}
		let user = currentUserLocked()
		let item = PendingItem(
			cmd: cmd,
			user: user,
			epoch: state.epoch,
			sessionStart: Session.isSessionOf(state.session, user) ? Session.startTime(state.session) : 0,
			queuedAtMs: platform.nowMs(),
			raw: raw,
			navigate: navigate,
			seq: seq
		)
		seq += 1
		pending.append(item)
		enforceCapLocked()
		return item
	}

	/// An action is reported once per page for each status, and `executed` not after any other
	/// (the 1.x rule). Remembered on disk, so the screen a restarted app restores is not counted
	/// again. A close also takes the action out of the result, and with N > 0 blocks it for N
	/// sessions - Personyze keeps no such state for an app; the SDK does.
	private func acceptStatusLocked(_ cmd: Command) -> Bool
	{	guard let actionId = cmd[1].flatMap({ Int($0) }), let status = cmd[2] else
		{	return true
		}
		let reported = state.pageReports[actionId] ?? []
		// `dont-show` once per page too: a server answering the blocked action again would otherwise
		// be answered with another report, and that with the action again, without end.
		if status == "executed" && reported.contains(where: { $0 != "dont-show" }) || reported.contains(status)
		{	return false
		}
		state.pageReports[actionId] = reported + [status]
		if status == "close"
		{	let sessions = cmd.count > 3 ? Int(cmd[3]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0 : 0
			if sessions > 0
			{	state.blocked[actionId] = sessions
			}
			if var r = state.result, r.actions.contains(where: { $0.id == actionId })
			{	r.actions.removeAll { $0.id == actionId }
				state.result = r
				emitLocked()
			}
		}
		return true
	}

	private func enforceCapLocked()
	{	var total = pending.reduce(0) { $0 + Commands.jsonLength($1.cmd) }
		var dropped: [PendingItem] = []
		while pending.count > Engine.maxPending || total > Engine.maxPendingChars
		{	guard let i = pending.firstIndex(where: { !$0.navigate && !$0.inflight }) else
			{	break
			}
			let item = pending.remove(at: i)
			total -= Commands.jsonLength(item.cmd)
			dropped.append(item)
		}
		if !dropped.isEmpty
		{	report(
				.delivery(
					reason: .overflow,
					commands: dropped.map { $0.wireCommand },
					message: "Too many events waiting to be sent; the oldest \(dropped.count) were dropped",
					cause: nil
				),
				PersonyzeErrorContext(operation: "track", dropped: dropped.count)
			)
		}
	}

	private func scheduleAutoFlushLocked()
	{	guard let delayMs = config.autoFlushDelayMs else
		{	return
		}
		autoFlushTask?.cancel()
		autoFlushTask = tasks.run { [self] in
			do
			{	try await Task.sleep(nanoseconds: UInt64(max(delayMs, 0))*1_000_000)
			}
			catch
			{	return
			}
			_ = await flushLive(budgetMs: config.backgroundTimeoutMs, operation: "flush")
		}
	}

	// MARK: - decisions

	/// `events` run after the navigation is queued and before it is sent, so they go in its
	/// request, attributed to the new screen.
	func navigate(_ document: String, events: (() -> Void)?) async -> PersonyzeResult
	{	let ticket = beginNavigation(document)
		events?()
		return await finishNavigation(ticket)
	}

	/// The synchronous half of a navigation: queue it, so that the events the app reports next go
	/// into its request. Split from `finishNavigation` so that the app's events closure runs on the
	/// app's own thread or actor, between the two - not inside an async function of the engine,
	/// where a closure touching main-actor state would not compile under Swift 6.
	func beginNavigation(_ document: String) -> NavigationTicket
	{	let navCmd: Command
		do
		{	navCmd = try Commands.navigate(document)
		}
		catch
		{	return NavigationTicket(error: error)
		}
		let ticket = NavigationTicket(error: nil)
		mutate { [self] in
			if throttledLocked()
			{	ticket.throttled = true
			}
			else
			{	state.pageReports = [:]
				ticket.item = addLocked(navCmd, raw: false, navigate: true)
			}
		}
		return ticket
	}

	func finishNavigation(_ ticket: NavigationTicket) async -> PersonyzeResult
	{	if let error = ticket.error
		{	report(error, PersonyzeErrorContext(operation: "navigate"))
			return .failed(error)
		}
		// Loaded means the queued operations ran: the ticket is filled.
		await loaded.wait()
		let deadline = platform.monotonicMs() + config.timeoutMs
		persistSoon()
		let queued = lock.locked
		{	ticket.item
		}
		guard let navItem = queued else
		{	return failNavigation(.transport(kind: .rateLimited, status: 429, message: "Personyze paused this account's tracking (HTTP 429); not asking again for a few minutes"), navSeq: nil)
		}
		let drained = await underWire(deadline) { [self] in
			await drain(deadline: deadline, live: false, operation: "navigate", navSeq: navItem.seq)
		}
		guard let drained else
		{	let error = PersonyzeError.transport(kind: .timeout, status: nil, message: "Personyze did not answer within \(config.timeoutMs)ms (an earlier request was still in flight)")
			report(error, PersonyzeErrorContext(operation: "navigate"))
			return failNavigation(error, navSeq: navItem.seq)
		}
		if !drained.navigateDone
		{	return failNavigation(drained.navigateError ?? .transport(kind: .timeout, status: nil, message: "Personyze did not answer within \(config.timeoutMs)ms"), navSeq: navItem.seq)
		}
		await waitAtMost(max(deadline - platform.monotonicMs(), 1), for: fetchMetadataInBackground())
		return result.value
	}

	/// No decision for this screen: an empty one (SPEC section 8 - the last screen's actions are not
	/// this one's), and the navigation is not kept for later.
	private func failNavigation(_ error: PersonyzeError, navSeq: Int64?) -> PersonyzeResult
	{	lock.locked
		{	if let navSeq
			{	pending.removeAll { $0.seq == navSeq }
			}
			state.result = nil
			result.set(.failed(error))
		}
		persistSoon()
		return .failed(error)
	}

	func refresh() async -> PersonyzeResult
	{	await loaded.wait()
		let needed = lock.locked
		{	pending.contains { !$0.navigate } || state.result == nil
		}
		if !needed
		{	return result.value
		}
		let deadline = platform.monotonicMs() + config.timeoutMs
		let outcome = await underWire(deadline) { [self] () -> Outcome in
			let drained = await drain(deadline: deadline, live: false, operation: "refresh", navSeq: nil)
			let (empty, user, epoch) = lock.locked
			{	(state.result == nil && !throttledLocked(), currentUserLocked(), state.epoch)
			}
			if drained.error == nil && !drained.sentAny && empty
			{	// Nothing queued and no decision yet: ask for the visitor's current state (1.x did the same).
				return Outcome(error: await sendBatch(Batch(items: [], user: user, epoch: epoch), deadline: deadline, operation: "refresh"))
			}
			return Outcome(error: drained.error)
		}
		let error = outcome.map { $0.error } ?? .transport(kind: .timeout, status: nil, message: "Personyze did not answer within \(config.timeoutMs)ms (an earlier request was still in flight)")
		await waitAtMost(max(deadline - platform.monotonicMs(), 1), for: fetchMetadataInBackground())
		let current = result.value
		return error == nil ? current : current.with(error: error)
	}

	/// Send what is queued, now.
	func flush() async
	{	await loaded.wait()
		let deadline = platform.monotonicMs() + config.backgroundTimeoutMs
		_ = await underWire(deadline) { [self] in
			await drain(deadline: deadline, live: false, operation: "flush", navSeq: nil)
		}
	}

	/// Send what is queued if it can go into the live session - otherwise it waits for the next
	/// navigation, which opens the new session with a page. Events sent alone into a new session
	/// would log a visit with no page. Answers false when events stayed for lack of a network.
	func flushLive(budgetMs: Int64, operation: String) async -> Bool
	{	await loaded.wait()
		let deadline = platform.monotonicMs() + budgetMs
		let drained = await underWire(deadline) { [self] in
			await drain(deadline: deadline, live: true, operation: operation, navSeq: nil)
		}
		return drained.map { !$0.keptForLater } ?? false
	}

	private struct Outcome: Sendable
	{	let error: PersonyzeError?
	}

	/// Run `block` holding `wire`, in a task of the engine's own: a caller cancelled mid-request
	/// (its screen closed) must not abandon a request half done - its events would stay marked in
	/// flight. Nil when `wire` was not free before `deadline`.
	private func underWire<T: Sendable>(_ deadline: Int64, _ block: @escaping @Sendable () async -> T) async -> T?
	{	await tasks.run { [self] () -> T? in
			guard await wire.lock(timeoutMs: max(deadline - platform.monotonicMs(), 1)) else
			{	return nil
			}
			let value = await block()
			wire.unlock()
			return value
		}.value
	}

	func hasPending() -> Bool
	{	lock.locked
		{	pending.contains { !$0.navigate }
		}
	}

	private struct Batch: Sendable
	{	let items: [PendingItem]
		let user: UserId
		let epoch: Int

		var hasNavigate: Bool
		{	items.contains { $0.navigate }
		}
	}

	private struct Drained: Sendable
	{	var navigateDone = false
		var navigateError: PersonyzeError?
		var error: PersonyzeError?
		var sentAny = false
		var keptForLater = false
	}

	/// Send the queue in order, a batch per request, until it is empty or a request fails. Called
	/// holding `wire`.
	private func drain(deadline: Int64, live: Bool, operation: String, navSeq: Int64?) async -> Drained
	{	var drained = Drained()
		while true
		{	let next = lock.locked
			{	takeBatchLocked(live: live, operation: operation, navSeq: navSeq)
			}
			guard let batch = next else
			{	break
			}
			persistNow()
			let error = await sendBatch(batch, deadline: deadline, operation: operation)
			drained.sentAny = true
			let hadNavigation = navSeq != nil && batch.items.contains { $0.seq == navSeq }
			if hadNavigation
			{	drained.navigateDone = error == nil
				drained.navigateError = error
			}
			if let error
			{	drained.error = error
				if navSeq != nil && drained.navigateError == nil
				{	drained.navigateError = error
				}
				drained.keptForLater = lock.locked
				{	pending.contains { !$0.navigate && !$0.inflight }
				}
				break
			}
			if hadNavigation
			{	// The screen waits for this answer, not for the rest of the queue.
				lock.locked
				{	if pending.contains(where: { !$0.navigate })
					{	scheduleAutoFlushLocked()
					}
				}
				break
			}
		}
		return drained
	}

	/// The next request's commands: from the front of the queue, all for one visitor and epoch,
	/// at most `Commands.maxBody` characters; a `track()` command alone. Marked in flight. Drops
	/// first what may no longer be sent (SPEC section 5's replay rules, applied to a queue that can
	/// outlive the app):
	///
	/// - events of a visitor who is no longer current, unless that visitor's session is still the
	///   live one - sending them would open a session for a visitor who left;
	/// - action reports outside the session they were made in: "executed" counted in a session that
	///   never showed the action;
	/// - anything a day old.
	private func takeBatchLocked(live: Bool, operation: String, navSeq: Int64?) -> Batch?
	{	if throttledLocked()
		{	return nil
		}
		let now = platform.nowMs()
		let serverNow = now + state.clockOffsetMs
		let current = currentUserLocked()
		var drops: [(reason: PersonyzeError.DeliveryReason, items: [PendingItem])] = []
		pending.removeAll { item in
			if item.inflight || item.navigate
			{	return false
			}
			let ownSession = state.session != nil && Session.isSessionOf(state.session, item.user)
			let liveOwnSession = ownSession && !Session.isExpired(state.session, serverNowMs: serverNow) && item.epoch == state.sentEpoch
			let reason: PersonyzeError.DeliveryReason
			if item.user != current && !liveOwnSession
			{	reason = .otherVisitor
			}
			else if Commands.isActionStatus(item.cmd) && item.cmd[2] != "dont-show" && item.sessionStart != 0 && (!liveOwnSession || Session.startTime(state.session) != item.sessionStart)
			{	reason = .otherSession
			}
			else if now - item.queuedAtMs > Engine.maxAgeMs
			{	reason = .expired
			}
			else
			{	return false
			}
			if let i = drops.firstIndex(where: { $0.reason == reason })
			{	drops[i].items.append(item)
			}
			else
			{	drops.append((reason, [item]))
			}
			return true
		}
		for (reason, items) in drops
		{	report(
				.delivery(
					reason: reason,
					commands: items.map { $0.wireCommand },
					message: "\(items.count) queued events can no longer be sent (\(Engine.words(reason)))",
					cause: nil
				),
				PersonyzeErrorContext(operation: operation, dropped: items.count)
			)
		}
		guard let first = pending.first(where: { !$0.inflight }) else
		{	return nil
		}
		if first.navigate && first.seq != navSeq
		{	return nil	// another caller's navigation, waiting for its turn: it sends from here on
		}
		if live
		{	let liveSession = state.session != nil && Session.isSessionOf(state.session, first.user) &&
				!Session.isExpired(state.session, serverNowMs: serverNow) && first.epoch == state.sentEpoch
			if !liveSession
			{	return nil
			}
		}
		var items: [PendingItem] = []
		var size = Engine.bodyOverhead
		for item in pending
		{	if item.inflight
			{	continue
			}
			if item.navigate && item.seq != navSeq
			{	break
			}
			if item.user != first.user || item.epoch != first.epoch || item.raw != first.raw || (first.raw && !items.isEmpty)
			{	break
			}
			let len = Commands.jsonLength(item.cmd) + 1
			if !items.isEmpty && size + len > Commands.maxBody
			{	break
			}
			// The events after a navigation go in its request, attributed to the new screen.
			items.append(item)
			size += len
		}
		let ids = Set(items.map { $0.seq })
		for i in pending.indices where ids.contains(pending[i].seq)
		{	pending[i].inflight = true
		}
		return Batch(items: items.map { $0.inflightCopy }, user: first.user, epoch: first.epoch)
	}

	private struct Sent: Sendable
	{	let body: String
		let session: String?
		let newSession: Bool
	}

	/// One tracker request. Answers nil on success, else the error (already reported).
	private func sendBatch(_ batch: Batch, deadline: Int64, operation: String) async -> PersonyzeError?
	{	let device = platform.deviceContext()
		let showable = platform.notificationsShowable()
		let sent = lock.locked
		{	() -> Sent in
			var session = state.session
			if !Session.isSessionOf(session, batch.user)
			{	session = nil
			}
			let serverNow = platform.nowMs() + state.clockOffsetMs
			let newSession = batch.epoch > state.sentEpoch || session == nil || Session.isExpired(session, serverNowMs: serverNow)
			// Newest first, the current session included - as the web tag sends them (stat-track-lib
			// `get_ps`) and as the rule engine counts them (`pastSessionsCount` reads from the front).
			let past = newSession ? Array(([serverNow/1000] + state.pastSessions).prefix(Engine.pastSessionsKept)) : state.pastSessions
			let body = Wire.requestBody(
				userId: batch.user,
				sessionId: session,
				newSession: newSession,
				pastSessions: past,
				device: device,
				notiEnabled: showable,
				commands: batch.items.map { $0.cmd }
			)
			return Sent(body: body, session: session, newSession: newSession)
		}
		let remaining = deadline - platform.monotonicMs()
		let outcome: RestResult
		if remaining <= 0
		{	outcome = .failed(.transport(kind: .timeout, status: nil, message: "Personyze did not answer within the time budget"), maybeDelivered: false)
		}
		else
		{	outcome = await rest.call("POST", Endpoints.tracker, body: sent.body, budgetMs: remaining)
		}
		switch outcome
		{	case .ok(let body, let dateMs):
				guard let response = Wire.parseResponse(body) else
				{	let error = PersonyzeError.transport(kind: .malformedResponse, status: 200, message: "Personyze answered something that is not the tracker's JSON")
					dropBatch(batch, error, reason: .ambiguous, operation: operation)
					return error
				}
				applyResponse(batch, sent, response, dateMs: dateMs)
				return nil
			case .failed(let error, let maybeDelivered):
				switch error
				{	case .transport(.rateLimited, _, _):
						lock.locked
						{	state.throttledUntilMs = platform.nowMs() + Engine.throttleMs
						}
						dropBatch(batch, error, reason: .refused, operation: operation)
					case .auth, .badRequest:
						dropBatch(batch, error, reason: .refused, operation: operation)
					default:
						if maybeDelivered
						{	dropBatch(batch, error, reason: .ambiguous, operation: operation)
						}
						else
						{	keepBatch(batch, error, operation: operation)
						}
				}
				return error
		}
	}

	private func applyResponse(_ batch: Batch, _ sent: Sent, _ response: Wire.TrackerResponse, dateMs: Int64?)
	{	lock.locked
		{	var st = state
			if let dateMs
			{	let offset = dateMs - platform.nowMs()
				st.clockOffsetMs = abs(offset) > Engine.clockSkewMs ? offset : 0
			}
			// Always the newest (SPEC section 3, rule 2) - 1.x kept the first of each session.
			let session = response.sessionId ?? sent.session
			if session != nil && Session.startTime(session) != Session.startTime(sent.session)
			{	let start = Session.startTime(session)
				st.blocked = st.blocked.compactMapValues { $0 > 1 ? $0 - 1 : nil }
				st.pastSessions = Array(([start] + st.pastSessions.filter { $0 != start }).prefix(Engine.pastSessionsKept))
				if !batch.hasNavigate
				{	st.pageReports = [:]
				}
			}
			st.session = session
			st.sentEpoch = max(st.sentEpoch, batch.epoch)
			if response.cacheVersion > 0 && response.cacheVersion != st.cacheVersion
			{	metadata = MetadataFile(apiKeyFp: apiKeyFp, cacheVersion: response.cacheVersion)
				st.cacheVersion = response.cacheVersion
				cacheStore.delete(Engine.metadataFile)
			}
			let blocked = st.blocked
			let blockedHit = response.actions.filter { blocked[$0.id] != nil }.map { $0.id }
			let decided = response.actions.filter { blocked[$0.id] == nil }
			if batch.user == currentUserLocked()
			{	if let prev = st.result, !batch.hasNavigate
				{	// Merge, as 1.x: what is new is added, what Personyze dismissed is removed.
					let conditions = (prev.conditions + response.conditions.filter { !prev.conditions.contains($0) }).filter { !response.dismissConditions.contains($0) }
					let known = Set(prev.actions.map { $0.id })
					let added = decided.filter { !known.contains($0.id) }.map { PersistedAction(id: $0.id, data: $0.data) }
					let actions = (prev.actions + added).filter { !response.dismissActions.contains($0.id) }
					st.result = PersistedResult(
						conditions: conditions.uniqued(),
						actions: actions.uniqued { $0.id },
						dismissedConditions: response.dismissConditions,
						dismissedActions: response.dismissActions,
						sessionId: session,
						cacheVersion: st.cacheVersion,
						raw: response.raw
					)
				}
				else
				{	st.result = PersistedResult(
						conditions: response.conditions.uniqued(),
						actions: decided.uniqued { $0.id }.map { PersistedAction(id: $0.id, data: $0.data) },
						sessionId: session,
						cacheVersion: st.cacheVersion,
						raw: response.raw
					)
				}
			}
			state = st
			let ids = Set(batch.items.map { $0.seq })
			pending.removeAll { ids.contains($0.seq) }
			for id in blockedHit
			{	if let cmd = try? Commands.actionStatus(id, "dont-show")
				{	addLocked(cmd, raw: false)
				}
			}
			if !blockedHit.isEmpty
			{	scheduleAutoFlushLocked()
			}
			emitLocked()
		}
		persistSoon()
		if needsMetadata()
		{	fetchMetadataInBackground()
		}
		// The visitor may be new to Personyze, or another: the device registered for them.
		let hasToken = lock.locked
		{	state.push.token != nil
		}
		if hasToken
		{	tasks.run { [self] in
				await registerPush()
			}
		}
	}

	/// Nothing reached Personyze: the events stay queued for when it can, a navigation does not.
	private func keepBatch(_ batch: Batch, _ error: PersonyzeError, operation: String)
	{	let kept = lock.locked
		{	() -> Int in
			let ids = Set(batch.items.map { $0.seq })
			pending.removeAll { ids.contains($0.seq) && $0.navigate }
			var kept = 0
			for i in pending.indices where ids.contains(pending[i].seq)
			{	pending[i].inflight = false
				kept += 1
			}
			return kept
		}
		persistSoon()
		if kept > 0
		{	platform.scheduleOutboxFlush()
		}
		report(error, PersonyzeErrorContext(operation: operation, deferred: kept))
	}

	private func dropBatch(_ batch: Batch, _ error: PersonyzeError, reason: PersonyzeError.DeliveryReason, operation: String)
	{	lock.locked
		{	let ids = Set(batch.items.map { $0.seq })
			pending.removeAll { ids.contains($0.seq) }
		}
		persistSoon()
		let commands = batch.items.filter { !$0.navigate }.map { $0.wireCommand }
		if commands.isEmpty
		{	report(error, PersonyzeErrorContext(operation: operation))
		}
		else
		{	let message = reason == .ambiguous
				? "\(commands.count) events may or may not have reached Personyze, and are not sent again: \(error.message)"
				: "\(commands.count) events were refused: \(error.message)"
			report(.delivery(reason: reason, commands: commands, message: message, cause: error), PersonyzeErrorContext(operation: operation, dropped: commands.count))
		}
	}

	private func throttledLocked() -> Bool
	{	platform.nowMs() < state.throttledUntilMs
	}

	// MARK: - visitor

	/// A number as the server's JavaScript can hold it: past 2^53 a JSON number arrives rounded, so
	/// it goes as text, which is hashed exactly.
	static func userId(_ n: Int64) -> UserId
	{	n > maxSafeInteger || n < -maxSafeInteger ? .text(String(n)) : .number(n)
	}

	func setUserId(_ userId: UserId?)
	{	mutate { [self] in
			if userId != state.userId
			{	state.userId = userId
				emitLocked()
				persistSoon()
				// The previous visitor's queued events go out under their own session first.
				scheduleAutoFlushLocked()
			}
		}
	}

	func startNewSession()
	{	mutate { [self] in
			state.epoch += 1
			state.result = nil
			state.pageReports = [:]
			emitLocked()
			persistSoon()
			scheduleAutoFlushLocked()
		}
	}

	func clearCache() async
	{	await loaded.wait()
		lock.locked
		{	metadata = MetadataFile(apiKeyFp: apiKeyFp, cacheVersion: state.cacheVersion)
			emitLocked()
		}
		cacheStore.delete(Engine.metadataFile)
		await fetchMetadata(budgetMs: config.backgroundTimeoutMs)
	}

	func reset() async
	{	await loaded.wait()
		// The forgotten visitor's notifications reach this device no more; the new visitor registers it again.
		let push = lock.locked
		{	state.push
		}
		if let token = push.token, push.registered != nil
		{	_ = await rest.call("PUT", Endpoints.pushToken, body: JSON.serialize(orderedObject: [("token", .string(token)), ("enabled", .bool(false))]), budgetMs: config.backgroundTimeoutMs)
		}
		await wire.withLock
		{	await meta.withLock
			{	let visitorId = lock.locked
				{	() -> Int32 in
					installVisitor = Engine.newAnonymousId()
					state = PersistedState(apiKeyFp: apiKeyFp)
					state.push.token = push.token
					pending.removeAll()
					metadata = MetadataFile(apiKeyFp: apiKeyFp)
					emitLocked()
					return installVisitor
				}
				store.clear()
				cacheStore.clear()
				store.write(Engine.visitorFile, String(visitorId), sync: true)
				persistNow()
			}
		}
	}

	private static func newAnonymousId() -> Int32
	{	Int32.random(in: minAnonymousId ..< Int32.max)
	}

	private func currentUserLocked() -> UserId
	{	state.userId ?? .number(Int64(installVisitor))
	}

	// MARK: - metadata

	private enum TemplateKind: String
	{	case conditions = "c"
		case actions = "a"
		case placeholders = "p"
	}

	private func needsMetadata() -> Bool
	{	lock.locked
		{	let m = missingLocked()
			return !m.conditions.isEmpty || !m.actions.isEmpty || !m.placeholders.isEmpty
		}
	}

	private func missingLocked() -> (conditions: [Int], actions: [Int], placeholders: [Int])
	{	guard let r = state.result else
		{	return ([], [], [])
		}
		let skip = Set(metadata.missing)
		let conditions = r.conditions.filter { metadata.conditions[$0] == nil && !skip.contains("c\($0)") }
		let actions = r.actions.map { $0.id }.filter { metadata.actions[$0] == nil && !skip.contains("a\($0)") }
		let placeholders = r.actions.compactMap { metadata.actions[$0.id] }.flatMap { Wire.intList($0["placeholders"]) }.uniqued()
			.filter { metadata.placeholders[$0] == nil && !skip.contains("p\($0)") }
		return (conditions, actions, placeholders)
	}

	@discardableResult
	private func fetchMetadataInBackground() -> Task<Void, Never>
	{	tasks.run { [self] in
			await fetchMetadata(budgetMs: config.backgroundTimeoutMs)
		}
	}

	/// The campaign names, action templates and placeholders the current result needs and the cache
	/// lacks - after a cache clear too (1.x Android skipped the placeholders then). Per account
	/// version, the same for every visitor (SPEC section 10), so cached; ids the server does not
	/// return are not asked for again until the version changes.
	private func fetchMetadata(budgetMs: Int64) async
	{	await meta.withLock
		{	let deadline = platform.monotonicMs() + budgetMs
			let (missing, version) = lock.locked
			{	(missingLocked(), metadata.cacheVersion)
			}
			var ok = await fetchRows(.conditions, missing.conditions, deadline: deadline, version: version) { Endpoints.conditions($0) }
			if ok && !missing.actions.isEmpty
			{	let withOrder = lock.locked
				{	metadata.placeholderOrder
				}
				ok = await fetchRows(.actions, missing.actions, deadline: deadline, version: version, refusedWithOrder: withOrder) { Endpoints.actions($0, withOrder: withOrder) }
				if !ok && withOrder && lock.locked({ !metadata.placeholderOrder })
				{	ok = await fetchRows(.actions, missing.actions, deadline: deadline, version: version) { Endpoints.actions($0, withOrder: false) }
				}
			}
			if ok
			{	let placeholders = lock.locked
				{	missingLocked().placeholders
				}
				_ = await fetchRows(.placeholders, placeholders, deadline: deadline, version: version) { Endpoints.placeholders($0) }
			}
			saveMetadata()
			lock.locked
			{	emitLocked()
			}
		}
	}

	private func fetchRows
	(	_ kind: TemplateKind,
		_ ids: [Int],
		deadline: Int64,
		version: Int,
		refusedWithOrder: Bool = false,
		_ path: ([Int]) -> String
	) async -> Bool
	{	for start in stride(from: 0, to: ids.count, by: Engine.metadataChunk)
		{	let chunk = Array(ids[start ..< min(start + Engine.metadataChunk, ids.count)])
			let remaining = deadline - platform.monotonicMs()
			if remaining <= 0
			{	return false
			}
			switch await rest.call("GET", path(chunk), body: nil, budgetMs: remaining)
			{	case .ok(let body, _):
					guard let rows = Wire.parseRows(body) else
					{	report(.transport(kind: .malformedResponse, status: 200, message: "Personyze answered the \(Engine.words(kind)) templates with something that is not a list"), PersonyzeErrorContext(operation: "metadata"))
						return false
					}
					let current = lock.locked
					{	() -> Bool in
						if metadata.cacheVersion != version
						{	return false	// the account changed version meanwhile; these rows are stale
						}
						var got: [Int: [String: JSON]] = [:]
						for row in rows
						{	if let id = Wire.int(row["id"])
							{	got[id] = row
							}
						}
						switch kind
						{	case .conditions:
								metadata.conditions.merge(got) { $1 }
							case .actions:
								metadata.actions.merge(got) { $1 }
							case .placeholders:
								metadata.placeholders.merge(got) { $1 }
						}
						let absent = chunk.filter { got[$0] == nil }.map { kind.rawValue + String($0) }
						if !absent.isEmpty
						{	metadata.missing = (metadata.missing + absent).uniqued()
						}
						return true
					}
					if !current
					{	return false
					}
				case .failed(let error, _):
					if refusedWithOrder, case .badRequest(400, _) = error
					{	// A server older than `placeholder_order` (SPEC section 10).
						lock.locked
						{	metadata.placeholderOrder = false
						}
						return false
					}
					report(error, PersonyzeErrorContext(operation: "metadata"))
					return false
			}
		}
		return true
	}

	// MARK: - notifications

	/// Fetch the visitor's queued notification. Answers it when it is to be shown - not shown
	/// before to this visitor - and marks it shown first, so a crash while posting cannot repeat it.
	///
	/// How often (SPEC section 11): `force` at once; as the app comes to the front (`foreground`)
	/// once a minute at most - the visitor is there to see it; otherwise, in the background, every
	/// 15 minutes, or every 6 hours when Personyze pushes to the device - the check is then only the
	/// fallback for a push that did not go.
	func pollNotification(force: Bool, foreground: Bool = false) async -> PersonyzeNotification?
	{	await loaded.wait()
		let now = platform.nowMs()
		let request = lock.locked
		{	() -> (path: String, visitor: String)? in
			let n = state.notifications
			let interval = force ? 0 : foreground ? Engine.foregroundCheckMs : state.push.active ? Engine.pushedCheckMs : Engine.notificationIntervalMs - 60_000
			if now < n.lastCheckMs + interval
			{	return nil
			}
			// No request yet, no visitor on the server, nothing queued for one.
			guard state.session != nil, let expected = Session.serverUserId(currentUserLocked()) else
			{	return nil
			}
			state.notifications.lastCheckMs = now
			return (Endpoints.notification(expected), String(expected))
		}
		guard let request else
		{	return nil
		}
		persistSoon()
		let body: String
		switch await rest.call("GET", request.path, body: nil, budgetMs: config.backgroundTimeoutMs)
		{	case .ok(let text, _):
				body = text
			case .failed(let error, _):
				report(error, PersonyzeErrorContext(operation: "notifications"))
				return nil
		}
		guard let notification = NotificationPoll.parse(body) else
		{	return nil
		}
		let show = lock.locked
		{	() -> Bool in
			var n = state.notifications
			if n.delivered.first(where: { $0.visitor == request.visitor })?.messageId == notification.messageId
			{	return false
			}
			let prime = n.primeOnNextPoll
			n.delivered.removeAll { $0.visitor == request.visitor }
			n.delivered.append(PersistedNotifications.Delivered(visitor: request.visitor, messageId: notification.messageId))
			n.delivered = Array(n.delivered.suffix(Engine.deliveredKept))
			n.primeOnNextPoll = false
			state.notifications = n
			return !prime
		}
		persistNow()
		return show ? notification : nil
	}

	/// How long the background may wait before it checks again, in seconds: longer when Personyze
	/// pushes to the device.
	func backgroundCheckSeconds() -> Int
	{	let active = lock.locked
		{	state.push.active
		}
		return Int((active ? Engine.pushedCheckMs : Engine.notificationIntervalMs)/1000)
	}

	/// The token Apple's push service gave the install, as the app passes it on (nil: none any
	/// more). Registered as soon as there is a visitor to register it for.
	func setPushToken(_ token: String?)
	{	mutate { [self] in
			if token != state.push.token
			{	state.push.token = token
				emitPushLocked()
				persistSoon()
			}
		}
		tasks.run { [self] in
			await registerPush()
		}
	}

	/// Tell Personyze which device this visitor's notifications can be pushed to (SPEC section 11,
	/// `PUT push_token`) - when there is something new to tell: a token, a visitor (a login, a
	/// logout, a reset), or a week since the last time. Where the notifications cannot be shown
	/// any more (turned off in the app or by the user), the device is taken off instead. Best
	/// effort: what fails is tried again at the next chance - a response, a check, the app's
	/// return to the front.
	func registerPush() async
	{	await loaded.wait()
		guard let app = platform.pushApp() else
		{	return
		}
		await pushWire.withLock
		{	let now = platform.nowMs()
			let showable = platform.notificationsShowable()
			let job = lock.locked
			{	() -> (body: String, signature: String?)? in
				let p = state.push
				guard let token = p.token else
				{	return nil
				}
				if !showable
				{	return p.registered == nil ? nil : (JSON.serialize(orderedObject: [("token", .string(token)), ("enabled", .bool(false))]), nil)
				}
				guard state.session != nil, let visitor = Session.serverUserId(currentUserLocked()) else
				{	return nil
				}
				let signature = "\(visitor) \(token)"
				if p.registered == signature && now < p.registeredAtMs + Engine.pushRegisterAgainMs
				{	return nil
				}
				let body = JSON.serialize(
					orderedObject: [
						("user_id", .int(Int64(visitor))),
						("token", .string(token)),
						("platform", .string(app.platform)),
						("app_id", .string(app.appId)),
						("sandbox", .bool(app.sandbox)),
						("enabled", .bool(true)),
					]
				)
				return (body, signature)
			}
			guard let job else
			{	return
			}
			switch await rest.call("PUT", Endpoints.pushToken, body: job.body, budgetMs: config.backgroundTimeoutMs)
			{	case .ok(let text, _):
					let active = job.signature != nil && Wire.bool(JSON.parse(text)?["push"])
					lock.locked
					{	state.push.registered = job.signature
						state.push.registeredAtMs = now
						state.push.active = active
						emitPushLocked()
					}
					persistSoon()
				case .failed(let error, _):
					platform.log("Personyze: the device could not be registered for push now: \(error.message)")
			}
		}
	}

	/// Report a notification shown, or tapped (SPEC section 11): fetch the address `GET
	/// current_notification` answered with it. Written down first and taken off once the server has
	/// had it, so a report the network or the process lost goes with the next notification check
	/// (`sendNotificationReports`). An empty address, or one that is not https, is nothing to report.
	func reportNotification(_ address: String) async
	{	guard Engine.reportUrl(address) != nil else
		{	return
		}
		await loaded.wait()
		lock.locked
		{	var reports = state.notifications.reports.filter { $0 != address }
			reports.append(address)
			state.notifications.reports = Array(reports.suffix(Engine.reportsKept))
		}
		persistNow()
		await sendNotificationReports()
	}

	/// Send the notification reports not sent yet, oldest first, within the background budget.
	/// Stops at the first that does not reach the server; the rest wait for the next check.
	func sendNotificationReports() async
	{	await loaded.wait()
		await reportWire.withLock
		{	let addresses = lock.locked
			{	state.notifications.reports
			}
			if addresses.isEmpty
			{	return
			}
			let deadline = platform.monotonicMs() + config.backgroundTimeoutMs
			var sent: Set<String> = []
			for address in addresses
			{	let remaining = deadline - platform.monotonicMs()
				if remaining <= 0
				{	break
				}
				if let url = Engine.reportUrl(address), !(await rest.ping(url, budgetMs: remaining))
				{	platform.log("Personyze: could not report the notification; trying again at the next check")
					break
				}
				sent.insert(address)
			}
			if !sent.isEmpty
			{	lock.locked
				{	state.notifications.reports.removeAll { sent.contains($0) }
				}
				persistNow()
			}
		}
	}

	/// A report's address as the server gave it, when it is one to fetch: https only.
	static func reportUrl(_ address: String) -> URL?
	{	guard !address.isEmpty, let url = URL(string: address), url.scheme?.lowercased() == "https", url.host != nil else
		{	return nil
		}
		return url
	}

	/// Tell the server the message was delivered, so it leaves the queue. Best effort.
	func ackNotification(_ messageId: Int64) async
	{	let path = lock.locked
		{	Session.serverUserId(currentUserLocked()).map { Endpoints.notification($0, messageId: messageId) }
		}
		guard let path else
		{	return
		}
		if case .failed(let error, _) = await rest.call("DELETE", path, body: nil, budgetMs: config.backgroundTimeoutMs)
		{	platform.log("Personyze: could not remove the delivered notification from the queue: \(error.message)")
		}
	}

	func verdict(_ conditionId: Int) async -> Result<PersonyzeVerdict, PersonyzeError>
	{	switch await rest.call("GET", Endpoints.verdict(conditionId), body: nil, budgetMs: config.backgroundTimeoutMs)
		{	case .ok(let body, _):
				guard let verdict = VerdictParser.parse(body) else
				{	return .failure(.transport(kind: .malformedResponse, status: 200, message: "Personyze answered the verdict with something unexpected"))
				}
				return .success(verdict)
			case .failed(let error, _):
				report(error, PersonyzeErrorContext(operation: "verdict"))
				return .failure(error)
		}
	}

	// MARK: - state and output

	private func emitPushLocked()
	{	let p = state.push
		push.set(PersonyzePushStatus(token: p.token, registeredVisitorId: p.registeredVisitorId, registeredAtMs: p.registeredAtMs, pushed: p.active))
	}

	private func emitLocked()
	{	emitPushLocked()
		result.set(buildResultLocked())
		visitor.set(
			PersonyzeVisitor(
				userId: state.userId?.text,
				visitorId: Session.serverUserId(currentUserLocked()).map { Int($0) },
				sessionId: state.session
			)
		)
	}

	private func buildResultLocked() -> PersonyzeResult
	{	guard let r = state.result else
		{	return .empty
		}
		let reporter = owner()
		return PersonyzeResult(
			actions: r.actions.map { a in
				var action = action(a)
				action.owner = reporter
				return action
			},
			conditions: r.conditions.map { id in PersonyzeCondition(id: id, name: metadata.conditions[id].map { Wire.text($0["name"]) }) },
			dismissedActions: r.dismissedActions,
			dismissedConditions: r.dismissedConditions,
			sessionId: r.sessionId,
			cacheVersion: r.cacheVersion,
			rawJson: r.raw,
			error: nil
		)
	}

	private func action(_ a: PersistedAction) -> PersonyzeAction
	{	guard let row = metadata.actions[a.id] else
		{	return PersonyzeAction(id: a.id, data: a.data ?? [:], cacheVersion: metadata.cacheVersion, assetsUrl: config.assetsUrl)
		}
		let placeholders = Wire.intList(row["placeholders"]).compactMap { id in
			metadata.placeholders[id].map { p in
				PersonyzePlaceholder(id: id, name: Wire.text(p["name"]), htmlId: Wire.text(p["html_id"]), unitsCountMax: Wire.int(p["units_count_max"]) ?? 0)
			}
		}
		let contentType = Wire.text(row["content_type"])
		return PersonyzeAction(
			id: a.id,
			data: a.data ?? [:],
			name: Wire.text(row["name"]),
			contentType: contentType.isEmpty ? nil : contentType,
			placeholders: placeholders,
			placeholderOrder: Wire.int(row["placeholder_order"]),
			libs: HtmlDocument.libs(of: Wire.text(row["libs_app"])),
			contentParam: Wire.text(row["content_param"]),
			contentBegin: Wire.text(row["content_begin"]),
			contentEnd: Wire.text(row["content_end"]),
			cacheVersion: metadata.cacheVersion,
			isLoaded: true,
			assetsUrl: config.assetsUrl
		)
	}

	/// A save soon, off the caller's thread. Several changes before it runs make one save.
	private func persistSoon()
	{	let schedule = signalLock.locked
		{	() -> Bool in
			if persistScheduled
			{	return false
			}
			persistScheduled = true
			return true
		}
		if schedule
		{	io.async { [self] in
				signalLock.locked
				{	persistScheduled = false
				}
				persistNow()
			}
		}
	}

	/// Snapshots are taken and written in the same order, so an older one never overwrites a newer.
	private func persistNow()
	{	persistLock.locked
		{	let (st, ob) = lock.locked
			{	(StateCoding.encode(state), StateCoding.encode(OutboxFile(items: pending.filter { !$0.navigate })))
			}
			guard let st, let ob else
			{	platform.log("Personyze: could not encode the state")
				return
			}
			store.write(Engine.stateFile, st)
			store.write(Engine.outboxFile, ob)
		}
	}

	private func saveMetadata()
	{	metaPersistLock.locked
		{	let text = lock.locked
			{	StateCoding.encode(metadata)
			}
			if let text
			{	cacheStore.write(Engine.metadataFile, text)
			}
		}
	}

	func reportInvalid(_ message: String, operation: String)
	{	report(.invalid(message: message), PersonyzeErrorContext(operation: operation))
	}

	private func report(_ error: PersonyzeError, _ context: PersonyzeErrorContext)
	{	platform.log("Personyze: \(context.operation): \(error.message)")
		let onError = onError
		callbacks.async {
			onError(error, context)
		}
	}

	/// Returns once nothing is in flight: requests, template fetches, the delayed send, saves,
	/// error reports. For tests, and for a background task that must finish its work.
	func idle() async
	{	await tasks.idle()
		await Engine.barrier(io)
		await Engine.barrier(callbacks)
		await tasks.idle()
	}

	private static func barrier(_ queue: DispatchQueue) async
	{	await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			queue.async {
				continuation.resume()
			}
		}
	}

	/// Stops the engine's tasks; a request in flight is abandoned.
	func close()
	{	tasks.cancelAll()
	}

	/// A redacted dump of the state, for a support case or a test screen.
	func diagnostics() -> String
	{	lock.locked
		{	var s = ""
			s += "installVisitor=\(installVisitor)\n"
			s += "userId=\(state.userId?.text ?? "nil")\n"
			s += "session=\(state.session ?? "nil")\n"
			s += "  start=\(Session.startTime(state.session)) visitor=\(Session.visitor(state.session).map { String($0) } ?? "nil") counter=\(Session.counter(state.session).map { String($0) } ?? "nil")\n"
			s += "epoch=\(state.epoch) sentEpoch=\(state.sentEpoch) clockOffsetMs=\(state.clockOffsetMs)\n"
			s += "pastSessions=\(state.pastSessions)\n"
			s += "blocked=\(Engine.format(state.blocked))\n"
			s += "cacheVersion=\(state.cacheVersion) templates: \(metadata.conditions.count) campaigns, \(metadata.actions.count) actions, \(metadata.placeholders.count) placeholders, \(metadata.missing.count) missing\n"
			s += "pageReports=\(Engine.format(state.pageReports))\n"
			s += "notifications=lastCheckMs=\(state.notifications.lastCheckMs) delivered=\(state.notifications.delivered.map { "\($0.visitor):\($0.messageId)" })\n"
			s += "push=\(push.value)\n"
			s += "throttledUntilMs=\(state.throttledUntilMs)\n"
			s += "queue (\(pending.count)):\n"
			for item in pending
			{	s += "  \(item.cmd.map { $0 ?? "nil" }) user=\(item.user.text) epoch=\(item.epoch)\(item.inflight ? " inflight" : "")\n"
			}
			return s
		}
	}

	/// `{88=5}`, keys in order.
	private static func format<V>(_ map: [Int: V]) -> String
	{	"{" + map.keys.sorted().map { "\($0)=\(map[$0]!)" }.joined(separator: ", ") + "}"
	}

	private static func words(_ reason: PersonyzeError.DeliveryReason) -> String
	{	switch reason
		{	case .ambiguous:
				return "ambiguous"
			case .interrupted:
				return "interrupted"
			case .expired:
				return "expired"
			case .otherVisitor:
				return "other visitor"
			case .otherSession:
				return "other session"
			case .overflow:
				return "overflow"
			case .refused:
				return "refused"
		}
	}

	private static func words(_ kind: TemplateKind) -> String
	{	switch kind
		{	case .conditions:
				return "campaign"
			case .actions:
				return "action"
			case .placeholders:
				return "placeholder"
		}
	}
}

/// A navigation queued by `Engine.beginNavigation` and not yet sent. Filled under the engine's
/// lock, after the stored state loads if it had not yet.
final class NavigationTicket: @unchecked Sendable
{	let error: PersonyzeError?
	var item: PendingItem?
	var throttled = false

	init(error: PersonyzeError?)
	{	self.error = error
	}
}

private extension PendingItem
{	/// The command as the error handler reports it: no nil arguments.
	var wireCommand: [String]
	{	cmd.map { $0 ?? "" }
	}

	var inflightCopy: PendingItem
	{	var copy = self
		copy.inflight = true
		return copy
	}
}

private extension Array
{	/// The first of each key, in order (Kotlin's `distinctBy`).
	func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element]
	{	var seen = Set<Key>()
		return filter { seen.insert(key($0)).inserted }
	}
}

private extension Array where Element: Hashable
{	func uniqued() -> [Element]
	{	uniqued { $0 }
	}
}

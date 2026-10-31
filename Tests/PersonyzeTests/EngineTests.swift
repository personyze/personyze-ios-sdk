import Foundation
import Testing
@testable import Personyze

/// The Android SDK's `EngineTest`, test for test. Serialized: a few measure real time.
@Suite(.serialized) struct EngineTests
{	// MARK: - SPEC section 3

	@Test func firstNavigateOpensTheSession() async throws
	{	let h = Harness()
		let r = await h.engine.navigate("Home", events: nil)
		#expect(h.transport.bodies().count == 1)
		let b = try #require(h.transport.bodies().first)
		#expect(b.str("session_id") == nil)
		#expect(b.bool("new_session"))
		guard case .int(let userId)? = b["user_id"] else
		{	Issue.record("user_id is not a number")
			return
		}
		#expect(userId >= 500_000_000, "anonymous ids are >= 500,000,000")
		#expect(b.commands() == [nav("Home")])
		#expect(b.str("platform") == "iOS")
		#expect(b.str("os") == "iOS/17.2")
		#expect(b.str("device_type") == "phone")
		#expect(b.str("languages") == "en-US,he-IL")
		#expect(b.str("screen") == "390x844")
		#expect(h.transport.trackerRequests()[0].body?.contains("\"time_zone\":3.0") == true)
		#expect(!b.bool("noti_enabled"))
		// The session being opened, as the web tag counts it (newest first, current included).
		#expect(b.str("past_sessions") == "\(t0/1000)")
		#expect(Session.visitor(r.sessionId) == userId)
		#expect(h.engine.visitor.value.sessionId == r.sessionId)
	}

	/// Conformance step 7: three decisions in a row keep one session (counter stays 1).
	@Test func threeNavigatesKeepOneSession() async
	{	let h = Harness()
		var counters: [Int?] = []
		for i in 1 ... 3
		{	counters.append(Session.counter(await h.engine.navigate("Page\(i)", events: nil).sessionId))
		}
		#expect(counters == [1, 1, 1])
		let bodies = h.transport.bodies()
		#expect(bodies.map { $0.bool("new_session") } == [true, false, false])
		#expect(bodies[1].str("session_id") == bodies[2].str("session_id"))
		#expect(bodies[2].str("past_sessions") == "\(t0/1000)")
	}

	@Test func sessionExpiresAfterNinetyMinutes() async
	{	let h = Harness()
		_ = await h.engine.navigate("A", events: nil)
		h.platform.advanceWall(Session.ttlMs - Session.expiryMarginMs)
		let r = await h.engine.navigate("B", events: nil)
		#expect(h.transport.bodies()[1].bool("new_session"))
		#expect(Session.counter(r.sessionId) == 2)
		// The new session's start first, then the previous one.
		let newStart = Session.startTime(r.sessionId)
		_ = await h.engine.navigate("C", events: nil)
		#expect(h.transport.bodies()[2].str("past_sessions") == "\(newStart),\(t0/1000)")
	}

	/// Conformance step 4: a corrupt stored session with new_session recovers instead of failing.
	@Test func corruptStoredSessionStartsOver() async
	{	let store = MemoryStore()
		store.write(Engine.stateFile, "{\"v\":1,\"apiKeyFp\":\"\(SHA256.hex(testKey).prefix(16))\",\"session\":\"garbage\"}")
		let h = Harness(store: store)
		let r = await h.engine.navigate("Home", events: nil)
		let b = h.transport.bodies()[0]
		#expect(b.str("session_id") == "garbage")
		#expect(b.bool("new_session"))
		#expect(r.sessionId != nil)
		#expect(!r.failed)
	}

	@Test func corruptStateFileIsQuarantined() async
	{	let store = MemoryStore()
		store.write(Engine.stateFile, "{not json")
		let h = Harness(store: store)
		_ = await h.engine.navigate("Home", events: nil)
		#expect(store.read("state.json.corrupt") == "{not json")
	}

	/// Conformance step 8: one device, visitor A then visitor B - B is not answered as A.
	@Test func visitorSwitchDropsTheOtherVisitorsSession() async
	{	let h = Harness()
		h.engine.setUserId(.text("alice@example.com"))
		let a = await h.engine.navigate("Home", events: nil)
		#expect(Session.visitor(a.sessionId) == Session.serverUserId(.text("alice@example.com")).map { Int64($0) })
		h.engine.setUserId(.number(777))
		let b = await h.engine.navigate("Home", events: nil)
		let body = h.transport.bodies()[1]
		#expect(body.str("session_id") == nil, "A's session is not sent for B")
		#expect(body.bool("new_session"))
		#expect(body["user_id"] == .int(777))
		#expect(Session.visitor(b.sessionId) == 777)
		#expect(h.engine.visitor.value.visitorId == 777)
	}

	@Test func logoutReturnsToTheInstallVisitor() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		let install = h.transport.bodies()[0]["user_id"]
		h.engine.setUserId(.text("bob"))
		_ = await h.engine.navigate("Home", events: nil)
		h.engine.setUserId(nil)
		_ = await h.engine.navigate("Home", events: nil)
		#expect(h.transport.bodies().map { $0["user_id"] } == [install, .string("bob"), install])
	}

	@Test func bigUserIdGoesAsText() async
	{	let h = Harness()
		h.engine.setUserId(Engine.userId(9_007_199_254_740_993))
		_ = await h.engine.navigate("Home", events: nil)
		#expect(h.transport.bodies()[0]["user_id"] == .string("9007199254740993"))
		#expect(Engine.userId(9_007_199_254_740_991) == .number(9_007_199_254_740_991))
		#expect(Engine.userId(Int64.min) == .text("-9223372036854775808"))
	}

	@Test func startNewSessionForcesOneAfterTheQueuedEvents() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }
		h.engine.startNewSession()
		#expect(h.engine.result.value.isEmpty)
		_ = await h.engine.navigate("Home", events: nil)
		let bodies = h.transport.bodies()
		#expect(bodies.count == 3)
		// The event first, in the old session; then the navigation, opening a new one.
		#expect(bodies[1].commands() == [["Product Viewed", "A1"]])
		#expect(!bodies[1].bool("new_session"))
		#expect(bodies[2].bool("new_session"))
		#expect(bodies[1].str("session_id") == bodies[2].str("session_id"))
	}

	// MARK: - requests

	@Test func eventsGoInTheNavigationsRequest() async
	{	let h = Harness()
		h.engine.enqueue { try Commands.profile([("email", "a@b.c")]) }
		_ = await h.engine.navigate("Product") { h.engine.enqueue { try Commands.product("Product Viewed", "A1000", actionId: nil, quantity: nil) } }
		#expect(h.transport.bodies().count == 1)
		#expect(h.transport.bodies().first?.commands() == [["User profile", "email", "a@b.c"], nav("Product"), ["Product Viewed", "A1000"]])
		#expect(!h.engine.hasPending())
	}

	@Test func rawTrackGoesAlone() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }
		h.engine.enqueue(raw: true) { try Commands.raw(["custom thing", "1"]) }
		h.engine.enqueue { try Commands.product("Product Viewed", "A2", actionId: nil, quantity: nil) }
		await h.engine.flush()
		#expect(h.transport.bodies().dropFirst().map { $0.commands() } == [[["Product Viewed", "A1"]], [["custom thing", "1"]], [["Product Viewed", "A2"]]])
	}

	@Test func bigQueueIsSplitInOrder() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		for i in 1 ... 30
		{	h.engine.enqueue { try Commands.profile([("f\(i)", String(repeating: "x", count: 4000))]) }
		}
		await h.engine.flush()
		let sent = h.transport.trackerRequests().dropFirst()
		#expect(sent.count >= 3)
		#expect(sent.allSatisfy { ($0.body?.utf8.count ?? 0) <= Commands.maxBody })
		#expect(h.transport.bodies().dropFirst().flatMap { $0.commands() }.map { $0[1] } == (1 ... 30).map { "f\($0)" })
	}

	@Test func invalidInputIsReportedNotSent() async
	{	let h = Harness()
		h.engine.enqueue { try Commands.product("Product Viewed", " ", actionId: nil, quantity: nil) }
		h.engine.enqueue { try Commands.promotion("promotion viewed", "P", actionId: 0) }
		await h.engine.idle()
		#expect(!h.engine.hasPending())
		#expect(h.errors.all.filter { $0.error.isInvalid }.count == 2)
		#expect(h.errors.all.allSatisfy { $0.context.dropped == 1 })
		let r = await h.engine.navigate("", events: nil)
		#expect(r.error?.isInvalid == true)
		#expect(h.transport.requests.isEmpty)
	}

	// MARK: - failing (SPEC section 5)

	@Test func serverErrorFailsOpenAfterOneRetry() async
	{	let h = Harness(transport: FakeTransport().tracker(status(500), status(503)))
		let r = await h.engine.navigate("Home", events: nil)
		#expect(r.failed)
		#expect(r.isEmpty)
		#expect(r.error?.transportKind == .server)
		#expect(h.transport.requests.count == 2)
		await h.engine.idle()
		#expect(h.errors.all.count == 1)
	}

	@Test func authErrorIsNotRetriedAndNotThrown() async
	{	let h = Harness(transport: FakeTransport().tracker(status(401, "Invalid API key")))
		let r = await h.engine.navigate("Home", events: nil)
		#expect(r.error?.isAuth == true)
		#expect(h.transport.requests.count == 1)
	}

	@Test func badRequestDropsTheBatch() async
	{	let h = Harness(transport: FakeTransport().tracker(status(400, "No Product ID specified")))
		h.engine.enqueue { try Commands.raw(["Product Viewed", ""]) }
		await h.engine.flush()
		await h.engine.idle()
		#expect(!h.engine.hasPending())
		let errors = h.errors.all
		#expect(errors.count == 1)
		#expect(errors.first?.error.deliveryReason == .refused)
		#expect(errors.first?.context.dropped == 1)
		#expect(errors.first?.error.deliveryCause == .badRequest(status: 400, text: "No Product ID specified"))
	}

	/// 429: fail open, no retry, and no request at all for the next 10 minutes.
	@Test func throttledAccountBacksOff() async
	{	let h = Harness(transport: FakeTransport().tracker(status(429, "Tracking is paused on this account")))
		#expect(await h.engine.navigate("Home", events: nil).error?.transportKind == .rateLimited)
		#expect(await h.engine.navigate("Home", events: nil).error?.transportKind == .rateLimited)
		#expect(h.transport.requests.count == 1)
		h.platform.advanceWall(Engine.throttleMs)
		_ = await h.engine.navigate("Home", events: nil)
		#expect(h.transport.requests.count == 2)
	}

	/// Never sent (no network, refused): the events wait for later, the navigation does not.
	@Test func notSentKeepsTheEventsButNotTheNavigation() async
	{	let platform = FakePlatform()
		let tracker = FakeTracker { platform.nowMs()/1000 }
		let h = Harness(transport: FakeTransport().tracker(fail(sent: false), fail(sent: false), tracker.step()), platform: platform)
		let r = await h.engine.navigate("Home") { h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) } }
		#expect(r.error?.transportKind == .connection)
		#expect(h.engine.hasPending())
		#expect(h.platform.outboxScheduled == 1)
		await h.engine.idle()
		#expect(h.errors.all.count == 1)
		#expect(h.errors.all.first?.context.deferred == 1)
		_ = await h.engine.navigate("Next", events: nil)
		#expect(h.transport.bodies().last?.commands() == [["Product Viewed", "A1"], nav("Next")])
	}

	@Test func offlineKeepsTheEvents() async
	{	let h = Harness(transport: FakeTransport().tracker({ _ in .failed(sent: false, timedOut: false, offline: true, reason: "offline") }))
		h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }
		await h.engine.flush()
		#expect(h.engine.hasPending())
		#expect(h.transport.requests.count == 1)
	}

	/// Maybe delivered: not sent again (a purchase counted twice is worse than one missing).
	@Test func ambiguousFailureDropsAndReportsTheEvents() async
	{	let h = Harness(transport: FakeTransport().tracker(fail(sent: true), fail(sent: true)))
		h.engine.enqueue { try Commands.product("Product Purchased", "A1", actionId: 88, quantity: 1) }
		await h.engine.flush()
		await h.engine.idle()
		#expect(!h.engine.hasPending())
		#expect(h.transport.requests.count == 2)
		let errors = h.errors.all
		#expect(errors.count == 1)
		#expect(errors.first?.error.deliveryReason == .ambiguous)
		#expect(errors.first?.error.deliveryCommands == [["Product Purchased", "A1", "action_id", "88", "quantity", "1"]])
	}

	@Test func slowAnswerFailsAtTheBudget() async
	{	let h = Harness(transport: FakeTransport().tracker(ok(trackerAnswer(session(1, 1)), delayMs: 10_000)), timeoutMs: 400)
		let started = Clocks.monotonicMs()
		let r = await h.engine.navigate("Home", events: nil)
		let took = Clocks.monotonicMs() - started
		#expect(r.error?.transportKind == .timeout)
		#expect(took < 1500, "took \(took) ms")
	}

	@Test func malformedAnswerFailsOpen() async
	{	let h = Harness(transport: FakeTransport().tracker(ok("<html>oops</html>")))
		let r = await h.engine.navigate("Home", events: nil)
		#expect(r.error?.transportKind == .malformedResponse)
	}

	/// A request in flight when the app died may have arrived: dropped at the next start, reported.
	@Test func inflightAtStartupIsDropped() async throws
	{	let store = MemoryStore()
		let item = PendingItem(cmd: ["Product Purchased", "A1"], user: .number(500_000_001), epoch: 0, sessionStart: 0, queuedAtMs: t0, inflight: true, seq: 1)
		let kept = PendingItem(cmd: ["Product Viewed", "A2"], user: .number(500_000_001), epoch: 0, sessionStart: 0, queuedAtMs: t0, seq: 2)
		store.write(Engine.outboxFile, try #require(StateCoding.encode(OutboxFile(items: [item, kept]))))
		let h = Harness(store: store)
		await h.engine.idle()
		#expect(h.errors.all.map { $0.error.deliveryReason } == [.interrupted])
		#expect(h.engine.diagnostics().contains("Product Viewed"))
		#expect(!h.engine.diagnostics().contains("Product Purchased"))
	}

	/// A screen closed mid-request: the request still completes and its events are not stranded.
	@Test func cancelledCallerDoesNotStrandEvents() async
	{	let platform = FakePlatform()
		let tracker = FakeTracker { platform.nowMs()/1000 }
		let answer = tracker.step()
		let slow: Step = { request in
			await pause(300)
			return await answer(request)
		}
		let h = Harness(transport: FakeTransport().tracker(slow), platform: platform)
		let engine = h.engine
		let caller = Task {
			_ = await engine.navigate("Home") { engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) } }
		}
		await pause(100)
		caller.cancel()
		await caller.value
		await h.engine.idle()
		#expect(!h.engine.hasPending())
		#expect(h.engine.visitor.value.sessionId != nil)
	}

	@Test func eventsOfAVisitorWhoLeftAreDroppedWithoutALiveSession() async
	{	let h = Harness()
		h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }	// anonymous, no session yet
		h.engine.setUserId(.text("carol"))
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.idle()
		#expect(h.transport.bodies().map { $0.commands() } == [[nav("Home")]])
		#expect(h.errors.all.map { $0.error.deliveryReason } == [.otherVisitor])
	}

	@Test func previousVisitorsEventsGoUnderTheirOwnLiveSession() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		let anonymous = h.transport.bodies()[0]["user_id"]
		h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }
		h.engine.setUserId(.text("dave"))
		_ = await h.engine.navigate("Account", events: nil)
		let bodies = h.transport.bodies()
		#expect(bodies[1]["user_id"] == anonymous)
		#expect(bodies[1].commands() == [["Product Viewed", "A1"]])
		#expect(!bodies[1].bool("new_session"))
		#expect(bodies[2].str("user_id") == "dave")
		#expect(bodies[2].bool("new_session"))
	}

	@Test func actionReportOfAnEndedSessionIsDropped() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		h.engine.enqueue { try Commands.actionStatus(88, "executed") }
		h.platform.advanceWall(Session.ttlMs)
		_ = await h.engine.navigate("Later", events: nil)
		await h.engine.idle()
		#expect(h.transport.bodies().last?.commands() == [nav("Later")])
		#expect(h.errors.all.map { $0.error.deliveryReason } == [.otherSession])
	}

	@Test func queueIsCapped() async
	{	let h = Harness()
		for i in 0 ..< Engine.maxPending + 5
		{	h.engine.enqueue { try Commands.product("Product Viewed", "A\(i)", actionId: nil, quantity: nil) }
		}
		await h.engine.idle()
		#expect(h.errors.all.contains { $0.error.deliveryReason == .overflow })
	}

	// MARK: - auto flush

	@Test func autoFlushSendsIntoTheLiveSession() async
	{	let h = Harness(autoFlushMs: 400)
		_ = await h.engine.navigate("Home", events: nil)
		h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }
		await pause(200)
		#expect(h.transport.requests.count == 1)
		await pause(600)
		#expect(h.transport.requests.count == 2)
		#expect(h.transport.bodies().count == 2 && !h.transport.bodies()[1].bool("new_session"))
	}

	/// Events alone would open a session with a visit of no page: they wait for the navigation.
	@Test func autoFlushWaitsWithoutALiveSession() async
	{	let h = Harness(autoFlushMs: 100)
		h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }
		await pause(400)
		#expect(h.transport.requests.isEmpty)
		#expect(await h.engine.flushLive(budgetMs: 10_000, operation: "flush"))
		#expect(h.transport.requests.isEmpty)
	}

	// MARK: - decisions and reports

	@Test func navigationReplacesOtherRequestsMerge() async
	{	let h = Harness()
		h.tracker.configure
		{	$0.conditions = [1]
			$0.actionsOnlyWithNavigate = false
			$0.actions = #"[{"id":88,"data":{"data":"x"}},{"id":89}]"#
		}
		h.transport.on("/rest/conditions/", ok(#"[{"id":1,"name":"C1"},{"id":2,"name":"C2"}]"#))
		h.transport.on("/rest/actions/", ok("[]"))
		let first = await h.engine.navigate("Home", events: nil)
		#expect(first.actions.map { $0.id } == [88, 89])
		h.tracker.configure
		{	$0.conditions = [2]
			$0.actions = #"[{"id":90}]"#
			$0.dismissActions = [89]
		}
		h.engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }
		let merged = await h.engine.refresh()
		#expect(merged.actions.map { $0.id } == [88, 90])
		#expect(merged.conditions.map { $0.id } == [1, 2])
		#expect(merged.dismissedActions == [89])
		h.tracker.configure
		{	$0.actions = "[]"
		}
		#expect(await h.engine.navigate("Other", events: nil).actions.isEmpty)
	}

	@Test func refreshWithNothingQueuedAnswersTheCurrentDecision() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		_ = await h.engine.refresh()
		#expect(h.transport.requests.count == 1)
	}

	@Test func executedOncePerPage() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		h.engine.enqueue { try Commands.actionStatus(88, "executed") }
		h.engine.enqueue { try Commands.actionStatus(88, "executed") }
		h.engine.enqueue { try Commands.actionStatus(88, "target") }
		h.engine.enqueue { try Commands.actionStatus(88, "target") }
		await h.engine.flush()
		#expect(h.transport.bodies()[1].commands() == [["Action Status", "88", "executed", ""], ["Action Status", "88", "target", ""]])
		_ = await h.engine.navigate("Again", events: nil)
		h.engine.enqueue { try Commands.actionStatus(88, "executed") }
		await h.engine.flush()
		#expect(h.transport.bodies()[3].commands() == [["Action Status", "88", "executed", ""]])
	}

	/// "Don't show for N sessions" is the SDK's: the action is dropped from answers, reported
	/// `dont-show`, until N new sessions have started.
	@Test func closedActionIsBlockedForSessions() async
	{	let h = Harness()
		h.tracker.configure
		{	$0.actions = #"[{"id":88}]"#
		}
		h.transport.on("/rest/actions/", ok("[]"))
		#expect(await h.engine.navigate("Home", events: nil).has(88))
		h.engine.enqueue { try Commands.actionStatus(88, "close", "1") }
		#expect(!h.engine.result.value.has(88), "a close takes it off the screen at once")
		#expect(!(await h.engine.navigate("Home", events: nil).has(88)))
		await h.engine.flush()
		#expect(h.transport.bodies().last?.commands().last == ["Action Status", "88", "dont-show", ""])
		h.platform.advanceWall(Session.ttlMs)
		#expect(await h.engine.navigate("Home", events: nil).has(88), "one new session later it is back")
		#expect(h.tracker.seen.filter { $0.commands().contains(where: isNavigate) }.count == 3)
	}

	/// A server that answered the blocked action to every request got a `dont-show` for each, and
	/// answered that with the action again - an endless loop (found by the Android test, as an out
	/// of memory).
	@Test func blockedActionIsReportedOncePerPage() async
	{	let h = Harness()
		h.tracker.configure
		{	$0.actions = #"[{"id":88}]"#
			$0.actionsOnlyWithNavigate = false
		}
		h.transport.on("/rest/actions/", ok("[]"))
		_ = await h.engine.navigate("Home", events: nil)
		h.engine.enqueue { try Commands.actionStatus(88, "close", "3") }
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.flush()
		await h.engine.flush()
		let dontShow = h.transport.bodies().flatMap { $0.commands() }.filter { $0.count > 2 && $0[2] == "dont-show" }.count
		#expect(dontShow == 1)
	}

	@Test func blockedActionsSurviveARestart() async
	{	let store = MemoryStore()
		let first = Harness(transport: FakeTransport(), store: store)
		first.engine.enqueue { try Commands.actionStatus(88, "close", "5") }
		await first.engine.idle()
		let h = Harness(store: store)
		await h.engine.idle()
		#expect(h.engine.diagnostics().contains("blocked={88=5}"))
	}

	// MARK: - metadata

	@Test func templatesLoadAfterTheDecision() async throws
	{	let h = Harness()
		h.tracker.configure
		{	$0.conditions = [7]
			$0.actions = #"[{"id":88,"data":{"data":"<b>Hi</b>"}}]"#
		}
		h.transport.on("/rest/conditions/columns/id,name/where/id:7", ok(#"[{"id":7,"name":"Shoppers"}]"#))
		h.transport.on("/rest/actions/columns/", ok(#"[{"id":88,"name":"Banner","content_type":"text/html","content_param":"data","content_begin":"<div>","content_end":"</div>","libs_app":"timer","placeholders":[635],"placeholder_order":2}]"#))
		h.transport.on("/rest/placeholders/columns/id,name,html_id,units_count_max/where/id:635", ok(#"[{"id":635,"name":"Home banner","html_id":".app-home","units_count_max":1}]"#))
		let r = await h.engine.navigate("Home", events: nil)
		let a = try #require(r.action(88))
		#expect(a.isLoaded)
		#expect(a.content == "<div><b>Hi</b></div>")
		#expect(a.libs == ["timer"])
		#expect(a.placeholderOrder == 2)
		#expect(r.conditions.map { $0.name } == ["Shoppers"])
		#expect(r.actions(in: "Home banner").map { $0.id } == [88])
		#expect(r.actions(in: ".app-home").map { $0.id } == [88])
		#expect(r.actions(inPlaceholder: 635).map { $0.id } == [88])
		// Cached: the next decision asks for nothing more.
		let before = h.transport.requests.count
		_ = await h.engine.navigate("Again", events: nil)
		#expect(h.transport.requests.count == before + 1)
	}

	@Test func oldServerWithoutPlaceholderOrder() async
	{	let h = Harness()
		h.tracker.configure
		{	$0.actions = #"[{"id":88}]"#
		}
		h.transport.on("placeholder_order", status(400, "Unknown column placeholder_order"))
		h.transport.on("/rest/actions/columns/", ok(#"[{"id":88,"name":"B","content_type":"text/html","content_param":"","content_begin":"x","content_end":"","libs_app":null,"placeholders":[]}]"#))
		let r = await h.engine.navigate("Home", events: nil)
		#expect(r.action(88)?.isLoaded == true)
		#expect(r.action(88)?.placeholderOrder == nil)
	}

	@Test func newCacheVersionReloadsTemplates() async
	{	let h = Harness()
		h.tracker.configure
		{	$0.actions = #"[{"id":88}]"#
		}
		h.transport.on(
			"/rest/actions/",
			ok(#"[{"id":88,"name":"v5","content_type":"text/plain","placeholders":[]}]"#),
			ok(#"[{"id":88,"name":"v6","content_type":"text/plain","placeholders":[]}]"#)
		)
		#expect(await h.engine.navigate("Home", events: nil).action(88)?.name == "v5")
		h.tracker.configure
		{	$0.cacheVersion = 6
		}
		#expect(await h.engine.navigate("Home", events: nil).action(88)?.name == "v6")
	}

	/// 1.x Android never fetched the placeholders right after a cache clear.
	@Test func clearCacheReloadsPlaceholdersToo() async
	{	let h = Harness()
		h.tracker.configure
		{	$0.actions = #"[{"id":88}]"#
		}
		h.transport.on("/rest/actions/", ok(#"[{"id":88,"name":"B","content_type":"text/html","placeholders":[635]}]"#))
		h.transport.on("/rest/placeholders/", ok(#"[{"id":635,"name":"P","html_id":"p","units_count_max":0}]"#))
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.clearCache()
		#expect(h.transport.requests.filter { $0.url.absoluteString.contains("/rest/placeholders/") }.count == 2)
		#expect(h.engine.result.value.action(88)?.placeholders.map { $0.name } == ["P"])
	}

	@Test func idsTheServerDoesNotKnowAreNotAskedAgain() async
	{	let h = Harness()
		h.tracker.configure
		{	$0.actions = #"[{"id":88}]"#
		}
		h.transport.on("/rest/actions/", ok("[]"))
		_ = await h.engine.navigate("Home", events: nil)
		_ = await h.engine.navigate("Home", events: nil)
		#expect(h.transport.requests.filter { $0.url.absoluteString.contains("/rest/actions/") }.count == 1)
		#expect(h.engine.result.value.action(88)?.isLoaded == false)
	}

	// MARK: - persistence

	@Test func stateSurvivesARestart() async
	{	let store = MemoryStore()
		let h1 = Harness(store: store)
		h1.tracker.configure
		{	$0.actions = #"[{"id":88,"data":{"k":"v"}}]"#
		}
		h1.transport.on("/rest/actions/", ok("[]"))
		let r1 = await h1.engine.navigate("Home", events: nil)
		await h1.engine.idle()
		// A new cache directory: the templates are fetched again as it loads.
		let h2 = Harness(store: store) { transport, _ in
			transport.on("/rest/actions/", ok("[]"))
		}
		await h2.engine.idle()
		#expect(h2.engine.visitor.value.sessionId == r1.sessionId)
		#expect(h2.engine.result.value.data(for: 88) == ["k": "v"])
		_ = await h2.engine.navigate("Next", events: nil)
		#expect(h2.transport.bodies().count == 1)
		#expect(h2.transport.bodies().first?.str("session_id") == r1.sessionId)
		#expect(h2.transport.bodies().first?["user_id"] == h1.transport.bodies().first?["user_id"])
		#expect(!h1.tracker.seen.isEmpty)
	}

	@Test func anotherKeyIsAnotherAccount() async
	{	let store = MemoryStore()
		let h1 = Harness(store: store)
		_ = await h1.engine.navigate("Home", events: nil)
		await h1.engine.idle()
		let h2 = Harness(store: store, apiKey: "FFFF" + testKey.dropFirst(4))
		_ = await h2.engine.navigate("Home", events: nil)
		let b = h2.transport.bodies()[0]
		#expect(b.str("session_id") == nil)
		#expect(b["user_id"] == h1.transport.bodies()[0]["user_id"])
	}

	@Test func oneXStateIsMigrated() async
	{	let legacy = FakeLegacy(
			LegacyState(
				visitorId: -123456,
				session: session(t0/1000 - 60, -123456, counter: 4),
				pastSessionsOldestFirst: [100, 200, 300],
				blocked: [88: 2],
				newSession: false,
				notiLastCheckMs: t0 - 1000,
				sameAccount: true
			)
		)
		let h = Harness(legacy: legacy)
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.idle()
		let b = h.transport.bodies()[0]
		#expect(b["user_id"] == .int(-123456))
		#expect(b.str("session_id") == session(t0/1000 - 60, -123456, counter: 4))
		#expect(!b.bool("new_session"))
		#expect(b.str("past_sessions") == "300,200,100")
		#expect(legacy.deleted)
		#expect(h.engine.diagnostics().contains("blocked={88=2}"))
	}

	@Test func oneXStateOfAnotherAccountKeepsOnlyTheVisitor() async
	{	let legacy = FakeLegacy(
			LegacyState(
				visitorId: 4242,
				session: "1 4242 7 1",
				pastSessionsOldestFirst: [100],
				blocked: [88: 2],
				newSession: true,
				notiLastCheckMs: 0,
				sameAccount: false
			)
		)
		let h = Harness(legacy: legacy)
		_ = await h.engine.navigate("Home", events: nil)
		let b = h.transport.bodies()[0]
		#expect(b["user_id"] == .int(4242))
		#expect(b.str("session_id") == nil)
	}

	// MARK: - clock

	/// A device clock 3 hours fast would find every session expired and open a new one on every
	/// request; the Date header fixes it.
	@Test func deviceClockSkewIsCorrected() async
	{	let platform = FakePlatform()
		let server: @Sendable () -> Int64 = { platform.nowMs() - 3*3600_000 }
		let tracker = FakeTracker { server()/1000 }
		let answer = tracker.step()
		let step: Step = { request in
			let outcome = await answer(request)
			guard case .answered(let status, let body, _) = outcome else
			{	return outcome
			}
			return .answered(status: status, body: body, dateMs: server())
		}
		let h = Harness(transport: FakeTransport().tracker(step), platform: platform)
		_ = await h.engine.navigate("A", events: nil)
		_ = await h.engine.navigate("B", events: nil)
		#expect(!h.transport.bodies()[1].bool("new_session"))
	}

	// MARK: - notifications

	@Test func notificationIsShownOncePerMessage() async throws
	{	let h = Harness()
		h.transport.on("/rest/current_notification/", ok(#"{"message_id":5,"title":"T","body":"B","actions":[]}"#))
		#expect(await h.engine.pollNotification(force: true) == nil, "no session yet")
		_ = await h.engine.navigate("Home", events: nil)
		let visitor = try #require(h.engine.visitor.value.visitorId)
		let n = await h.engine.pollNotification(force: true)
		#expect(n?.messageId == 5)
		let url = h.transport.requests.last?.url.absoluteString ?? ""
		#expect(url.hasSuffix("/rest/current_notification/where/user_id=\(visitor)"), "\(url)")
		#expect(await h.engine.pollNotification(force: true) == nil, "the queue still holds it; not shown twice")
		#expect(await h.engine.pollNotification(force: false) == nil, "throttled to 15 minutes")
	}

	@Test func firstNotificationAfterTheOneXUpgradeIsTakenAsShown() async
	{	let legacy = FakeLegacy(
			LegacyState(
				visitorId: 4242,
				session: session(t0/1000 - 60, 4242),
				pastSessionsOldestFirst: [],
				blocked: [:],
				newSession: false,
				notiLastCheckMs: t0 - 1000,
				sameAccount: true
			)
		)
		let h = Harness(legacy: legacy)
		h.transport.on("/rest/current_notification/", ok(#"{"message_id":5,"title":"T","body":"B"}"#), ok(#"{"message_id":6,"title":"T","body":"B"}"#))
		#expect(await h.engine.pollNotification(force: true) == nil)
		#expect(await h.engine.pollNotification(force: true)?.messageId == 6)
	}

	/// A report goes to the address the server gave, as it is, and without the API key: the key
	/// goes to `/rest` only.
	@Test func notificationReportGoesWithoutTheKey() async throws
	{	let h = Harness()
		h.transport.on("/white/", ok(""))
		await h.engine.reportNotification("https://pic.test/white/k=d57hr0hy9dp2/u=7/extra=1?p=p%2F1")
		let request = try #require(h.transport.requests.last)
		#expect(request.method == "GET")
		#expect(request.url.absoluteString == "https://pic.test/white/k=d57hr0hy9dp2/u=7/extra=1?p=p%2F1")
		#expect(request.headers["Authorization"] == nil)
		#expect(request.headers["User-Agent"] == "personyze-ios/test")
		await h.engine.sendNotificationReports()
		#expect(h.transport.requests.count == 1, "sent, so not kept")
	}

	@Test func nothingToReportWithIsNotSent() async
	{	let h = Harness()
		await h.engine.reportNotification("")
		await h.engine.reportNotification("http://pic.test/white/k=d57hr0hy9dp2/u=7")
		await h.engine.reportNotification("javascript:alert(1)")
		#expect(h.transport.requests.isEmpty)
	}

	/// A report the server did not get is kept - on disk, so a new process sends it too - and goes
	/// with the next check. Any answer below 500 is the server's: a 4xx is not sent again.
	@Test func aReportThatCannotGoNowGoesWithTheNextCheck() async
	{	let store = MemoryStore()
		let first = Harness(store: store)
		first.transport.on("/white/", fail(sent: false))
		await first.engine.reportNotification("https://pic.test/white/k=d57hr0hy9dp2/u=7")
		#expect(first.transport.requests.count == 2, "tried, and retried once")
		#expect(first.errors.all.isEmpty, "a report is not an error the app hears of")

		let second = Harness(store: store)
		second.transport.on("/white/", status(404))
		await second.engine.sendNotificationReports()
		#expect(second.transport.requests.map { $0.url.absoluteString } == ["https://pic.test/white/k=d57hr0hy9dp2/u=7"])
		await second.engine.sendNotificationReports()
		#expect(second.transport.requests.count == 1)
	}

	// MARK: - push (SPEC section 11)

	private func pushHarness(answer: String = #"{"push":true}"#) -> Harness
	{	let h = Harness()
		h.platform.app = PushApp(platform: "ios", appId: "com.shop.app", sandbox: true)
		h.platform.showable = true
		h.transport.on("/rest/push_token", ok(answer))
		return h
	}

	private func pushBodies(_ h: Harness) -> [JSON]
	{	h.transport.requests.filter { $0.url.absoluteString.hasSuffix("/rest/push_token") }.map { JSON.parse($0.body ?? "") ?? .null }
	}

	/// Registered once there is a visitor on the server, with the app - and again only when there is
	/// something new to say, or a week on.
	@Test func pushTokenIsRegisteredForTheVisitor() async throws
	{	let h = pushHarness()
		h.engine.setPushToken("a1b2c3")
		await h.engine.idle()
		#expect(pushBodies(h).isEmpty, "no visitor yet")
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.idle()
		let visitor = try #require(h.engine.visitor.value.visitorId)
		#expect(pushBodies(h) == [.object(["user_id": .int(Int64(visitor)), "token": .string("a1b2c3"), "platform": .string("ios"), "app_id": .string("com.shop.app"), "sandbox": .bool(true), "enabled": .bool(true)])])
		#expect(h.transport.requests.last?.method == "PUT")
		#expect(h.engine.backgroundCheckSeconds() == 6*3600, "pushed: the background checks are few")
		await h.engine.registerPush()
		#expect(pushBodies(h).count == 1, "nothing new to say")
		h.platform.advanceWall(8*24*3600_000)
		await h.engine.registerPush()
		#expect(pushBodies(h).count == 2, "a week on")
	}

	/// Without a key for the platform the device is still registered - a key added later finds it -
	/// and the app goes on checking every 15 minutes.
	@Test func withoutAKeyTheChecksStayAsTheyWere() async
	{	let h = pushHarness(answer: #"{"push":false}"#)
		h.engine.setPushToken("a1b2c3")
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.idle()
		#expect(pushBodies(h).count == 1)
		#expect(h.engine.backgroundCheckSeconds() == 15*60)
	}

	@Test func notificationsTurnedOffTakeTheDeviceOff() async
	{	let h = pushHarness()
		h.engine.setPushToken("a1b2c3")
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.idle()
		h.platform.showable = false
		await h.engine.registerPush()
		#expect(pushBodies(h).last == .object(["token": .string("a1b2c3"), "enabled": .bool(false)]))
		#expect(h.engine.backgroundCheckSeconds() == 15*60)
		await h.engine.registerPush()
		#expect(pushBodies(h).count == 2, "off once")
	}

	/// The forgotten visitor's notifications reach the device no more; the new visitor registers it.
	@Test func resetTakesTheOldVisitorOffAndKeepsTheToken() async throws
	{	let h = pushHarness()
		h.engine.setPushToken("a1b2c3")
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.idle()
		let before = try #require(h.engine.visitor.value.visitorId)
		await h.engine.reset()
		#expect(pushBodies(h).last == .object(["token": .string("a1b2c3"), "enabled": .bool(false)]))
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.idle()
		let after = try #require(h.engine.visitor.value.visitorId)
		#expect(before != after)
		#expect(pushBodies(h).last?["user_id"] == .int(Int64(after)))
		#expect(pushBodies(h).count == 3)
	}

	/// No push where the platform has none (macOS, Linux) - and none without a token.
	@Test func noPushWithoutAnApp() async
	{	let h = Harness()
		h.platform.showable = true
		h.engine.setPushToken("a1b2c3")
		_ = await h.engine.navigate("Home", events: nil)
		await h.engine.idle()
		#expect(pushBodies(h).isEmpty)
	}

	/// As the app comes to the front the visitor is there to see one: checked, but once a minute at most.
	@Test func foregroundChecksAreOnceAMinute() async
	{	let h = Harness()
		h.transport.on("/rest/current_notification/", ok("null"))
		_ = await h.engine.navigate("Home", events: nil)
		let checks = { h.transport.requests.filter { $0.url.absoluteString.contains("/current_notification/") }.count }
		_ = await h.engine.pollNotification(force: false, foreground: true)
		_ = await h.engine.pollNotification(force: false, foreground: true)
		#expect(checks() == 1)
		h.platform.advanceWall(61_000)
		_ = await h.engine.pollNotification(force: false, foreground: true)
		#expect(checks() == 2)
		_ = await h.engine.pollNotification(force: false)
		#expect(checks() == 2, "the background's 15 minutes")
	}

	@Test func resetIsANewVisitor() async
	{	let h = Harness()
		_ = await h.engine.navigate("Home", events: nil)
		let before = h.transport.bodies()[0]["user_id"]
		await h.engine.reset()
		_ = await h.engine.navigate("Home", events: nil)
		let after = h.transport.bodies()[1]
		#expect(before != after["user_id"])
		#expect(after.str("session_id") == nil)
	}

	// MARK: - not in the Android tests

	/// The result and visitor are observable, as Kotlin's `StateFlow`: the current value first.
	@Test func resultIsObservable() async
	{	let h = Harness()
		h.tracker.configure
		{	$0.actions = #"[{"id":88}]"#
		}
		h.transport.on("/rest/actions/", ok("[]"))
		var updates = h.engine.result.stream().makeAsyncIterator()
		#expect(await updates.next() == .empty)
		_ = await h.engine.navigate("Home", events: nil)
		var latest = await updates.next()
		while latest?.has(88) != true
		{	latest = await updates.next()
		}
		#expect(latest?.sessionId != nil)
	}

	/// Events queued before the stored state loads go out under the visitor the app set by then.
	@Test func eventsBeforeLoadingTakeTheVisitorSetMeanwhile() async
	{	let slowStore = SlowStore(MemoryStore())
		let engine = Engine(
			config: EngineConfig(apiKey: testKey, baseUrl: testBase, assetsUrl: testAssets, timeoutMs: 5000, backgroundTimeoutMs: 10_000, retries: 1, autoFlushDelayMs: nil, userAgent: "t"),
			platform: FakePlatform(),
			store: slowStore,
			cacheStore: MemoryStore(),
			transport: FakeTransport(),
			legacy: nil,
			onError: { _, _ in },
			owner: { nil }
		)
		engine.enqueue { try Commands.product("Product Viewed", "A1", actionId: nil, quantity: nil) }
		engine.setUserId(.text("erin"))
		engine.enqueue { try Commands.product("Product Viewed", "A2", actionId: nil, quantity: nil) }
		slowStore.release()
		await engine.idle()
		let diagnostics = engine.diagnostics()
		#expect(diagnostics.contains("[\"Product Viewed\", \"A1\"] user=") && !diagnostics.contains("A1\"] user=erin"))
		#expect(diagnostics.contains("[\"Product Viewed\", \"A2\"] user=erin"))
	}
}

/// A store whose first read waits for `release()` - an engine still loading.
private final class SlowStore: Store, @unchecked Sendable
{	private let inner: MemoryStore
	private let gate = DispatchSemaphore(value: 0)
	private let lock = NSLock()
	private var released = false

	init(_ inner: MemoryStore)
	{	self.inner = inner
	}

	func release()
	{	gate.signal()
	}

	func read(_ name: String) -> String?
	{	let wait = lock.locked
		{	() -> Bool in
			defer
			{	released = true
			}
			return !released
		}
		if wait
		{	gate.wait()
		}
		return inner.read(name)
	}

	func write(_ name: String, _ text: String, sync: Bool)
	{	inner.write(name, text, sync: sync)
	}

	func delete(_ name: String)
	{	inner.delete(name)
	}

	func quarantine(_ name: String)
	{	inner.quarantine(name)
	}

	func clear()
	{	inner.clear()
	}
}

private func nav(_ doc: String) -> [String?]
{	["Navigate", "urn:personyze:doc:\(doc)"]
}

private func isNavigate(_ cmd: [String?]) -> Bool
{	cmd.first.flatMap { $0 } == "Navigate"
}

extension PersonyzeError
{	var transportKind: TransportKind?
	{	if case .transport(let kind, _, _) = self
		{	return kind
		}
		return nil
	}

	var deliveryReason: DeliveryReason?
	{	if case .delivery(let reason, _, _, _) = self
		{	return reason
		}
		return nil
	}

	var deliveryCommands: [[String]]?
	{	if case .delivery(_, let commands, _, _) = self
		{	return commands
		}
		return nil
	}

	var deliveryCause: PersonyzeError?
	{	if case .delivery(_, _, _, let cause) = self
		{	return cause
		}
		return nil
	}

	var isInvalid: Bool
	{	if case .invalid = self
		{	return true
		}
		return false
	}

	var isAuth: Bool
	{	if case .auth = self
		{	return true
		}
		return false
	}
}

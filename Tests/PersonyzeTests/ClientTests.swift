import Foundation
import Testing
@testable import Personyze

/// The public client over the engine: what each call sends, and the shared `Personyze` entry point.
struct ClientTests
{	@Test func everyEventIsTheCommandTheOtherSDKsSend() async
	{	let h = ClientHarness()
		_ = await h.client.navigate("Home")
		let c = h.client
		c.setProfile("email", "a@b.c")
		c.setProfile(["b": "2", "a": nil])
		c.productViewed("P1")
		c.productAddedToCart("P1", actionId: 88, quantity: 2)
		c.productLiked("P1")
		c.productPurchased("P1", quantity: 3)
		c.productUnliked("P1")
		c.productRemovedFromCart("P1")
		c.productsPurchased()
		c.productsUnliked()
		c.productsRemovedFromCart()
		c.articleViewed("A1", actionId: 5)
		c.articleLiked("A1")
		c.articleCommented("A1")
		c.articleUnliked("A1")
		c.articleGoal("A1")
		c.articlesUnliked()
		c.promotionViewed(" PR ", actionId: 7)
		c.promotionClicked("PR", actionId: 7)
		c.codeRevealed("PR", actionId: 7)
		c.couponUsed("SAVE10")
		c.reportExecuted(88)
		c.reportEngaged(88)
		c.reportClosed(89, dontShowForSessions: 2)
		c.reportProductClicked(90, productId: "P1")
		c.reportArticleClicked(91, articleId: "A1")
		c.reportError(92, message: "broken")
		c.report(PersonyzeClick(actionId: 93, kind: .close, href: "", arg: "x"))
		c.track(["custom thing", "1"])
		await c.flush()
		let expected: [[String?]] = [
			["User profile", "email", "a@b.c"],
			["User profile", "a", nil, "b", "2"],
			["Product Viewed", "P1"],
			["Product Added to cart", "P1", "action_id", "88", "quantity", "2"],
			["Product Liked", "P1"],
			["Product Purchased", "P1", "quantity", "3"],
			["Product Unliked", "P1"],
			["Product Removed from cart", "P1"],
			["Products Purchased"],
			["Products Unliked"],
			["Products Removed from cart"],
			["Article Viewed", "A1", "action_id", "5"],
			["Article Liked", "A1"],
			["Article Commented", "A1"],
			["Article Unliked", "A1"],
			["Article Goal", "A1"],
			["Articles Unliked"],
			["promotion viewed", "PR", "action_id", "7"],
			["promotion clicked", "PR", "action_id", "7"],
			["code revealed", "PR", "action_id", "7"],
			["coupon used", "SAVE10"],
			["Action Status", "88", "executed", ""],
			["Action Status", "88", "target", ""],
			["Action Status", "89", "close", "2"],
			["Action Status", "90", "product", "P1"],
			["Action Status", "91", "article", "A1"],
			["Action Status", "92", "error", "broken"],
			["Action Status", "93", "close", "0"],
		]
		let bodies = h.transport.bodies()
		#expect(bodies.count == 3)
		#expect(bodies.count == 3 && bodies[1].commands() == expected)
		// `track()` goes in a request of its own.
		#expect(bodies.last?.commands() == [["custom thing", "1"]])
	}

	@Test func invalidCallsAreReportedNotSent() async
	{	let h = ClientHarness()
		h.client.setUserId("  ")
		h.client.reportProductClicked(88, productId: " ")
		h.client.promotionViewed("P", actionId: 0)
		h.client.track([])
		await h.client.engine.idle()
		let errors = h.errors.all
		#expect(errors.map { $0.context.operation } == ["setUserId", "track", "track"])
		#expect(errors.allSatisfy { $0.error.isInvalid })
		#expect(!h.client.engine.hasPending())
		#expect(h.client.visitor.userId == nil)
	}

	@Test func numericUserIdsGoAsNumbersUntilJavaScriptWouldRoundThem() async
	{	let h = ClientHarness()
		h.client.setUserId(42)
		_ = await h.client.navigate("Home")
		h.client.setUserId(Int.max)
		_ = await h.client.navigate("Home")
		#expect(h.transport.bodies().map { $0["user_id"] } == [.int(42), .string("9223372036854775807")])
		#expect(h.client.visitor.userId == "9223372036854775807")
	}

	/// The events closure runs on the caller's actor, so it may touch the screen's state - the
	/// point of `navigate` being `nonisolated(nonsending)`. Without it this test would not compile.
	@MainActor @Test func eventsRunOnTheCallersActor() async
	{	let h = ClientHarness()
		let screen = Screen()
		let result = await h.client.navigate("Product") { events in
			if #available(macOS 14, iOS 17, *)
			{	MainActor.assertIsolated()
			}
			screen.opened += 1
			events.productViewed(screen.productId)
		}
		#expect(!result.failed)
		#expect(screen.opened == 1)
		#expect(h.transport.bodies().first?.commands() == [["Navigate", "urn:personyze:doc:Product"], ["Product Viewed", "A1000"]])
	}

	@Test func anActionReportsToItsClient() async throws
	{	let h = ClientHarness
		{	transport, tracker in
			tracker.configure
			{	$0.actions = #"[{"id":88}]"#
			}
			transport.on("/rest/actions/", ok("[]"))
		}
		let action = try #require(await h.client.navigate("Home").action(88))
		action.reportExecuted()
		action.reportClosed(dontShowForSessions: 1)
		await h.client.flush()
		#expect(h.transport.bodies().last?.commands() == [["Action Status", "88", "executed", ""], ["Action Status", "88", "close", "1"]])
	}

	@Test func notificationIsShownThenRemovedFromTheQueue() async throws
	{	let presenter = FakePresenter(allowed: true)
		let h = ClientHarness(presenter: presenter)
		{	transport, _ in
			transport.on("/rest/current_notification/") { request in
				request.method == "DELETE" ? .answered(status: 200, body: "{}", dateMs: nil) : .answered(status: 200, body: #"{"message_id":5,"title":"T","body":"B"}"#, dateMs: nil)
			}
		}
		_ = await h.client.navigate("Home")
		let n = await h.client.checkNotifications()
		#expect(n?.messageId == 5)
		#expect(presenter.shown == [5])
		#expect(h.transport.requests.last?.method == "DELETE")
	}

	@Test func notificationsTheUserRefusedAreNotFetched() async
	{	let h = ClientHarness(presenter: FakePresenter(allowed: false))
		_ = await h.client.navigate("Home")
		#expect(await h.client.checkNotifications() == nil)
		#expect(h.transport.requests.count == 1)
	}

	@Test func notificationSwitchReachesThePresenter()
	{	let presenter = FakePresenter(allowed: true)
		let h = ClientHarness(presenter: presenter)
		h.client.setNotificationsEnabled(true)
		h.client.setNotificationsEnabled(false)
		#expect(presenter.polling == [false, true, false])
	}
}

/// `Personyze`, the shared entry point. Serialized: it is one client per process.
@Suite(.serialized) struct PersonyzeEntryPointTests
{	@Test func beforeInitializeNothingHappensAndNothingCrashes() async
	{	Personyze.shutdown()
		#expect(!Personyze.isInitialized)
		Personyze.productViewed("A1")
		Personyze.setUserId("bob")
		#expect(await Personyze.navigate("Home").error?.isInvalid == true)
		#expect(await Personyze.refresh().error?.isInvalid == true)
		#expect(Personyze.result == .empty)
		if case .failure(let error) = await Personyze.verdict(1)
		{	#expect(error.isInvalid)
		}
		else
		{	Issue.record("a verdict without a client")
		}
	}

	@Test func initializingAgainKeepsOrReplacesTheClient() async
	{	Personyze.shutdown()
		defer
		{	Personyze.shutdown()
		}
		let environment = fakeEnvironment()
		let first = Personyze.initialize(PersonyzeConfig(apiKey: testKey), environment: environment)
		let same = Personyze.initialize(PersonyzeConfig(apiKey: testKey) { $0.onError = { _, _ in } }, environment: environment)
		#expect(first === same)
		let other = Personyze.initialize(PersonyzeConfig(apiKey: testKey) { $0.storageName = "second" }, environment: environment)
		#expect(other !== first)
		#expect(Personyze.client === other)
	}

	@Test func callsGoToTheClient() async
	{	Personyze.shutdown()
		defer
		{	Personyze.shutdown()
		}
		let platform = FakePlatform()
		let tracker = FakeTracker { platform.nowMs()/1000 }
		let transport = FakeTransport().tracker(tracker.step())
		Personyze.initialize(PersonyzeConfig(apiKey: testKey) { $0.autoFlushDelay = nil }, environment: fakeEnvironment(platform: platform, transport: transport))
		Personyze.setProfile("email", "a@b.c")
		let result = await Personyze.navigate("Home") { $0.productViewed("A1") }
		#expect(result.sessionId != nil)
		#expect(Personyze.visitor.sessionId == result.sessionId)
		#expect(transport.bodies().first?.commands() == [["User profile", "email", "a@b.c"], ["Navigate", "urn:personyze:doc:Home"], ["Product Viewed", "A1"]])
	}
}

struct ConfigTests
{	@Test func mistakesAreNamed()
	{	#expect(PersonyzeConfig(apiKey: testKey).problem == nil)
		#expect(PersonyzeConfig(apiKey: "  ").problem == "Personyze: the API key is empty")
		#expect(PersonyzeConfig(apiKey: testKey) { $0.baseUrl = "http://app.personyze.com" }.problem?.contains("https") == true)
		#expect(PersonyzeConfig(apiKey: testKey) { $0.retries = 2 }.problem != nil)
		#expect(PersonyzeConfig(apiKey: testKey) { $0.timeout = 0 }.problem != nil)
		#expect(PersonyzeConfig(apiKey: testKey) { $0.storageName = "a/b" }.problem != nil)
		#expect(PersonyzeConfig(apiKey: testKey) { $0.storageName = "second-account_2" }.problem == nil)
	}

	@Test func engineGetsMillisecondsAndNormalizedUrls()
	{	let e = PersonyzeConfig(apiKey: " \(testKey) ")
		{	$0.baseUrl = "https://eu.personyze.com//"
			$0.assetsUrl = "https://cdn.example.com"
			$0.timeout = 2.5
			$0.autoFlushDelay = nil
		}.engineConfig
		#expect(e.apiKey == testKey)
		#expect(e.baseUrl == "https://eu.personyze.com")
		#expect(e.assetsUrl == "https://cdn.example.com/")
		#expect(e.timeoutMs == 2500)
		#expect(e.backgroundTimeoutMs == 10_000)
		#expect(e.autoFlushDelayMs == nil)
		#expect(e.userAgent == "personyze-ios/\(Personyze.sdkVersion)")
	}

	@Test func theKeyIsNeverPrinted()
	{	#expect(!PersonyzeConfig(apiKey: testKey).description.contains(testKey))
	}

	@Test func clickArguments()
	{	#expect(PersonyzeClick(actionId: 1, kind: .close, href: "", arg: " 3 ").dontShowForSessions == 3)
		#expect(PersonyzeClick(actionId: 1, kind: .close, href: "", arg: "-2").dontShowForSessions == 0)
		#expect(PersonyzeClick(actionId: 1, kind: .product, href: "", arg: "3").dontShowForSessions == 0)
		#expect(PersonyzeClick(actionId: 1, kind: .product, href: "", arg: "P1").productId == "P1")
		#expect(PersonyzeClick.kind(of: "article") == .article)
		#expect(PersonyzeClick.kind(of: "unknown") == nil)
	}
}

/// A screen's state: not `Sendable`, so only code on its actor may touch it.
@MainActor private final class Screen
{	var opened = 0
	let productId = "A1000"
}

final class FakePresenter: NotificationPresenter, @unchecked Sendable
{	private let lock = NSLock()
	private let allowed: Bool
	private var shownIds: [Int64] = []
	private var pollingCalls: [Bool] = []

	init(allowed: Bool = false)
	{	self.allowed = allowed
	}

	var shown: [Int64]
	{	lock.locked
		{	shownIds
		}
	}

	var polling: [Bool]
	{	lock.locked
		{	pollingCalls
		}
	}

	func canShow() async -> Bool
	{	allowed
	}

	func show(_ notification: PersonyzeNotification) async -> Bool
	{	lock.locked
		{	shownIds.append(notification.messageId)
		}
		return true
	}

	func schedulePolling(_ enabled: Bool)
	{	lock.locked
		{	pollingCalls.append(enabled)
		}
	}
}

private func fakeEnvironment
(	platform: FakePlatform = FakePlatform(),
	transport: FakeTransport = FakeTransport(),
	presenter: FakePresenter = FakePresenter()
) -> (Locked<Bool>) -> ClientEnvironment
{	{ _ in
		ClientEnvironment(platform: platform, store: MemoryStore(), cacheStore: MemoryStore(), transport: transport, legacy: nil, presenter: presenter)
	}
}

struct ClientHarness
{	let client: PersonyzeClient
	let transport: FakeTransport
	let errors: ErrorLog

	init(presenter: FakePresenter = FakePresenter(), setUp: (FakeTransport, FakeTracker) -> Void = { _, _ in })
	{	let platform = FakePlatform()
		let tracker = FakeTracker { platform.nowMs()/1000 }
		let transport = FakeTransport().tracker(tracker.step())
		setUp(transport, tracker)
		let errors = ErrorLog()
		let config = PersonyzeConfig(apiKey: testKey)
		{	$0.autoFlushDelay = nil
			$0.onError = { error, context in errors.add(error, context) }
		}
		client = PersonyzeClient(config: config, environment: fakeEnvironment(platform: platform, transport: transport, presenter: presenter))
		self.transport = transport
		self.errors = errors
	}
}

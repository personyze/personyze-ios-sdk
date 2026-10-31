import Foundation
import Testing
@testable import Personyze
#if os(iOS)
@testable import PersonyzeNotificationService
import UIKit
import UserNotifications
import WebKit
#endif

#if canImport(Combine)
@MainActor struct PersonyzeModelTests
{	@Test func followsTheClient() async throws
	{	let h = ClientHarness
		{	transport, tracker in
			tracker.configure
			{	$0.actions = #"[{"id":88}]"#
			}
			transport.on("/rest/actions/", ok("[]"))
		}
		let model = PersonyzeModel(client: h.client)
		#expect(model.result == .empty)
		_ = await h.client.navigate("Home")
		try await waitUntil(seconds: 5)
		{	model.result.has(88) && model.visitor.sessionId != nil
		}
	}
}
#endif

#if os(iOS)
/// The action view on a real WebKit, with the real library from the assets origin when the network
/// has it: the page loads, measures itself, reports `executed`, and a close hides it.
@MainActor @Suite(.serialized) struct ActionViewTests
{	private func banner(_ reporter: FakeReporter, content: String = #"<div style="height:120px">Hi</div>"#) -> PersonyzeAction
	{	var action = PersonyzeAction(
			id: 88,
			data: ["data": content],
			name: "Banner",
			contentType: "text/html",
			placeholders: [],
			placeholderOrder: nil,
			libs: [],
			contentParam: "data",
			contentBegin: "",
			contentEnd: "",
			cacheVersion: 1,
			isLoaded: true,
			assetsUrl: PersonyzeConfig.defaultAssetsUrl
		)
		action.owner = reporter
		return action
	}

	private func onScreen(_ view: PersonyzeActionView) -> UIWindow
	{	let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
		window.addSubview(view)
		window.isHidden = false
		return window
	}

	@Test func measuresItsContentAndReportsExecuted() async throws
	{	let reporter = FakeReporter()
		let view = PersonyzeActionView(frame: CGRect(x: 0, y: 0, width: 320, height: 10))
		var posted: [CGFloat] = []
		view.onHeightChange = { posted.append($0) }
		let window = onScreen(view)
		view.render(banner(reporter))
		// The first page in the process waits for WebKit's content process to start.
		try await waitUntil(seconds: 30, "the page to load")
		{	reporter.executed == [88]
		}
		try await waitUntil(seconds: 10, "the content's height, intrinsic \(view.intrinsicContentSize.height), posted \(posted)")
		{	view.intrinsicContentSize.height >= 100
		}
		#expect(abs(view.intrinsicContentSize.height - 120) < 30, "height \(view.intrinsicContentSize.height)")
		// The same action again: nothing reloads, nothing is reported twice.
		view.render(banner(reporter))
		try await Task.sleep(nanoseconds: 500_000_000)
		#expect(reporter.executed == [88])
		withExtendedLifetime(window) {}
	}

	@Test func closeIsReportedAndHidesTheView() async throws
	{	let reporter = FakeReporter()
		let view = PersonyzeActionView(frame: CGRect(x: 0, y: 0, width: 320, height: 10))
		let window = onScreen(view)
		view.render(banner(reporter))
		try await waitUntil(seconds: 15)
		{	reporter.executed == [88]
		}
		_ = try await view.webView?.evaluateJavaScript("window.webkit.messageHandlers.personyze.postMessage({href: '', clicked: 'close', arg: '2'}); 1")
		try await waitUntil(seconds: 5)
		{	!reporter.clicks.isEmpty
		}
		#expect(reporter.clicks == [PersonyzeClick(actionId: 88, kind: .close, href: "", arg: "2")])
		#expect(view.isHidden)
		#expect(view.intrinsicContentSize.height == 0)
		withExtendedLifetime(window) {}
	}

	/// The page may not navigate itself away; a tap the app handles opens nothing.
	@Test func thePageStaysWhereItIs() async throws
	{	let reporter = FakeReporter()
		let view = PersonyzeActionView(frame: CGRect(x: 0, y: 0, width: 320, height: 10))
		var tapped: [PersonyzeClick] = []
		view.onClick = { click in
			tapped.append(click)
			return true
		}
		let window = onScreen(view)
		view.render(banner(reporter))
		try await waitUntil(seconds: 15)
		{	reporter.executed == [88]
		}
		let before = view.webView?.url
		_ = try await view.webView?.evaluateJavaScript("location.href = 'https://example.com/'; 1")
		try await Task.sleep(nanoseconds: 1_000_000_000)
		#expect(view.webView?.url == before)
		_ = try await view.webView?.evaluateJavaScript("window.webkit.messageHandlers.personyze.postMessage({href: 'https://shop.example.com/sale', clicked: 'target', arg: ''}); 1")
		try await waitUntil(seconds: 5)
		{	!tapped.isEmpty
		}
		#expect(tapped.map { $0.kind } == [.target])
		#expect(reporter.clicks.map { $0.href } == ["https://shop.example.com/sale"])
		#expect(!view.isHidden)
		withExtendedLifetime(window) {}
	}
}
#endif

/// Where an action's reports go in these tests.
final class FakeReporter: ActionReporter, @unchecked Sendable
{	private let lock = NSLock()
	private var executedIds: [Int] = []
	private var clickList: [PersonyzeClick] = []

	var executed: [Int]
	{	lock.locked
		{	executedIds
		}
	}

	var clicks: [PersonyzeClick]
	{	lock.locked
		{	clickList
		}
	}

	func reportExecuted(_ actionId: Int)
	{	lock.locked
		{	executedIds.append(actionId)
		}
	}

	func report(_ click: PersonyzeClick)
	{	lock.locked
		{	clickList.append(click)
		}
	}

	func reportEngaged(_ actionId: Int)
	{
	}

	func reportClosed(_ actionId: Int, dontShowForSessions: Int)
	{
	}

	func reportProductClicked(_ actionId: Int, productId: String)
	{
	}

	func reportArticleClicked(_ actionId: Int, articleId: String)
	{
	}

	func reportError(_ actionId: Int, message: String)
	{
	}
}

/// Polls `condition` until it holds; records an issue naming `what` and throws when it does not in
/// time. `what` is evaluated then, so it can show the state at the timeout.
@MainActor
func waitUntil(seconds: Double, _ what: @autoclosure () -> String = "a condition", _ condition: () -> Bool) async throws
{	let deadline = Date(timeIntervalSinceNow: seconds)
	while !condition()
	{	if Date() > deadline
		{	Issue.record("timed out after \(seconds) s waiting for \(what())")
			throw CancellationError()
		}
		try await Task.sleep(nanoseconds: 50_000_000)
	}
}

#if os(iOS)
/// A pushed notification's `personyze` object, as Apple delivers it and as the SDK posts its own:
/// one reader for both (`PersonyzePush.Message`).
struct PushedNotificationTests
{	@Test func readsThePushedMessage()
	{	let info: [String: Any] = [
			"message_id": 12,
			"tag": " https://shop/sale ",
			"image": "",
			"icon": "https://x/i.png",
			"actions": [["title": "Open", "icon": "", "action": "https://shop/a"], ["title": "", "icon": "", "action": "https://shop/b"]],
			"shown_url": "https://pic/white/k=a/u=7",
			"click_url": "https://pic/white/k=a/u=7/extra=1",
		]
		let m = PersonyzePush.Message(info)
		#expect(m.messageId == 12)
		#expect(m.url == "https://shop/sale")
		#expect(m.buttons.map { $0.url } == ["https://shop/a"], "a button without a title is no button")
		#expect(m.picture == "https://x/i.png", "no picture: the icon")
		#expect(m.clickUrl == "https://pic/white/k=a/u=7/extra=1")
	}

	/// The SDK's own notification carries the same object, so a tap reads them alike.
	@Test func theSdksOwnCarriesTheSameObject() throws
	{	let n = try #require(NotificationPoll.parse(#"{"message_id":5,"title":"T","body":"B","tag":"https://shop/x","actions":[{"title":"Go","icon":"","action":"https://shop/go"}],"click_url":"https://pic/c"}"#))
		let m = PersonyzePush.Message(UserNotificationPresenter.userInfo(n))
		#expect(m.messageId == 5)
		#expect(m.url == "https://shop/x")
		#expect(m.buttons.map { $0.title } == ["Go"])
		#expect(m.clickUrl == "https://pic/c")
	}

	/// The app's other pushes go through the extension untouched.
	@Test func anotherPushPassesUntouched() async
	{	let content = UNMutableNotificationContent()
		content.title = "Your order shipped"
		let request = UNNotificationRequest(identifier: "x", content: content, trigger: nil)
		#expect(!PersonyzeNotificationService.isPersonyze(request))
		let delivered = Locked<String?>(nil)
		PersonyzeNotificationService().didReceive(request) { c in
			delivered.value = c.title
		}
		#expect(delivered.value == "Your order shipped")
	}

	@Test func categoryNamesAreStable()
	{	#expect(PersonyzePush.fnv1a("Open\nLater") == PersonyzePush.fnv1a("Open\nLater"))
		#expect(PersonyzePush.fnv1a("") == "cbf29ce484222325")
	}
}
#endif

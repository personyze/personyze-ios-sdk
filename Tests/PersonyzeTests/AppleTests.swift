import Foundation
import Testing
@testable import Personyze
#if os(iOS)
import UIKit
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
		let window = onScreen(view)
		view.render(banner(reporter))
		try await waitUntil(seconds: 15)
		{	view.intrinsicContentSize.height >= 100
		}
		#expect(abs(view.intrinsicContentSize.height - 120) < 30, "height \(view.intrinsicContentSize.height)")
		try await waitUntil(seconds: 15)
		{	reporter.executed == [88]
		}
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

/// Polls `condition` until it holds; records an issue and throws when it does not in time.
@MainActor
func waitUntil(seconds: Double, _ condition: () -> Bool) async throws
{	let deadline = Date(timeIntervalSinceNow: seconds)
	while !condition()
	{	if Date() > deadline
		{	Issue.record("timed out after \(seconds) s")
			throw CancellationError()
		}
		try await Task.sleep(nanoseconds: 50_000_000)
	}
}

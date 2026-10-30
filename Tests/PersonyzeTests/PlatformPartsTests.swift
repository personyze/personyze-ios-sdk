import Foundation
import Testing
@testable import Personyze

/// The parts of the iOS layer that need no UIKit, so they are tested everywhere.
struct ActionViewMessageTests
{	/// What WebKit hands over: the library posts `{href, clicked, arg}` as an object.
	@Test func tapsAsWebKitHandsThemOver()
	{	#expect(ActionViewMessage.parse(["href": "https://shop/a", "clicked": "target", "arg": ""] as [String: Any]) == .click(kind: .target, href: "https://shop/a", arg: ""))
		#expect(ActionViewMessage.parse(["href": "", "clicked": "close", "arg": "3"] as [String: Any]) == .click(kind: .close, href: "", arg: "3"))
		#expect(ActionViewMessage.parse(["clicked": "product", "arg": "A1000"] as [String: Any]) == .click(kind: .product, href: "", arg: "A1000"))
		#expect(ActionViewMessage.parse(["clicked": "something new"] as [String: Any]) == nil)
		#expect(ActionViewMessage.parse(42) == nil)
	}

	@Test func heightFromOurScript()
	{	#expect(ActionViewMessage.parse(["height": 180.0] as [String: Any]) == .height(180))
		#expect(ActionViewMessage.parse(["height": 96] as [String: Any]) == .height(96))
		#expect(ActionViewMessage.parse(["height": "x"] as [String: Any]) == nil)
	}

	/// As the library posts on Android, should a version of it do so here.
	@Test func jsonTextIsReadToo()
	{	#expect(ActionViewMessage.parse(#"{"href":"","clicked":"article","arg":"B7"}"#) == .click(kind: .article, href: "", arg: "B7"))
		#expect(ActionViewMessage.parse(#"{"height":120}"#) == .height(120))
	}

	@Test func heightScriptPostsToWebKit()
	{	#expect(HtmlDocument.heightScript.contains("window.webkit.messageHandlers.personyze.postMessage({height:v})"))
		#expect(!HtmlDocument.heightScript.contains("personyze_message_handler"))
	}
}

struct SafeLinkTests
{	@Test func whatMayBeOpened()
	{	#expect(SafeLink.url("https://shop.example.com/sale", assetsUrl: testAssets)?.host == "shop.example.com")
		#expect(SafeLink.url(" myapp://product/1 ", assetsUrl: testAssets)?.scheme == "myapp")
		#expect(SafeLink.url("", assetsUrl: testAssets) == nil)
		#expect(SafeLink.url("javascript:alert(1)", assetsUrl: testAssets) == nil)
		#expect(SafeLink.url("file:///etc/passwd", assetsUrl: testAssets) == nil)
		#expect(SafeLink.url("data:text/html,x", assetsUrl: testAssets) == nil)
		#expect(SafeLink.url("relative/path", assetsUrl: testAssets) == nil)
	}

	/// `href="/"` written for the customer's site, resolved against the CDN serving the page.
	@Test func relativeLinksResolvedToTheAssetsOriginAreNotOpened()
	{	#expect(SafeLink.url("https://counter.personyze.com/", assetsUrl: testAssets) == nil)
		#expect(SafeLink.url("https://COUNTER.personyze.com/sale", assetsUrl: testAssets) == nil)
		#expect(SafeLink.url("https://counter.personyze.com/", assetsUrl: nil) != nil)
	}
}

/// 1.x's state as it wrote it to `UserDefaults`, in a suite of the test's own.
@Suite(.serialized) struct LegacyDefaultsTests
{	private func withSuite(_ body: (UserDefaults, LegacyDefaults) throws -> Void) rethrows
	{	let name = "personyze-test-\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: name)!
		defer
		{	defaults.removePersistentDomain(forName: name)
		}
		try body(defaults, LegacyDefaults(suiteName: name, cacheDirectory: nil))
	}

	@Test func nothingStoredIsNoState()
	{	withSuite
		{	_, legacy in
			#expect(legacy.read() == nil)
		}
	}

	@Test func readsWhat1xStored() throws
	{	try withSuite
		{	defaults, legacy in
			defaults.set("1761220740 -123456 77 4 1761220740 0 491 0", forKey: "Personyze User")
			defaults.set("100,200", forKey: "Personyze Past Sessions")
			defaults.set("88:2,89:0,x:1,90:1", forKey: "Personyze Blocked Actions")
			defaults.set(true, forKey: "Personyze New Session")
			let state = try #require(legacy.read())
			// The visitor is field 1 of the session: 1.x's user_id changed on every launch.
			#expect(state.visitorId == -123456)
			#expect(state.session == "1761220740 -123456 77 4 1761220740 0 491 0")
			#expect(state.pastSessionsOldestFirst == [100, 200])
			#expect(state.blocked == [88: 2, 90: 1])
			#expect(state.newSession)
			#expect(state.sameAccount)
			legacy.delete()
			#expect(legacy.read() == nil)
		}
	}

	@Test func aSessionWithoutAVisitorKeepsTheRest() throws
	{	try withSuite
		{	defaults, legacy in
			defaults.set("garbage", forKey: "Personyze User")
			let state = try #require(legacy.read())
			#expect(state.visitorId == nil)
			#expect(state.session == "garbage")
		}
	}

	@Test func deleteRemovesTheCacheFiles() throws
	{	let dir = FileManager.default.temporaryDirectory.appendingPathComponent("personyze-legacy-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		defer
		{	try? FileManager.default.removeItem(at: dir)
		}
		for name in ["Personyze Action 88.dat", "Personyze Action Data 88.dat", "Personyze Condition 7.dat", "Personyze Placeholder 635.dat", "the app's own.dat"]
		{	_ = FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
		}
		LegacyDefaults(suiteName: "personyze-test-\(UUID().uuidString)", cacheDirectory: dir).delete()
		#expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["the app's own.dat"])
	}
}

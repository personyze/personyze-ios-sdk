import Foundation
import Testing
@testable import Personyze

/// The Android SDK's `HtmlDocumentTest`, `NotificationPollTest` and `VerdictParserTest`, and what
/// the Swift port added beside them: SHA-256, the state files' decoding, the async primitives.
struct HtmlDocumentTests
{	private func action(contentType: String = "text/html", libs: [String] = ["timer", "survey"], loaded: Bool = true) -> PersonyzeAction
	{	PersonyzeAction(
			id: 88,
			data: ["data": "<b>Hi ${action_id}</b>"],
			name: "Banner",
			contentType: contentType,
			placeholders: [],
			placeholderOrder: nil,
			libs: libs,
			contentParam: "data",
			contentBegin: "<div>",
			contentEnd: "</div>",
			cacheVersion: 17,
			isLoaded: loaded,
			assetsUrl: testAssets
		)
	}

	@Test func contentIsBeginDataEndWithTheActionId()
	{	#expect(action().content == "<div><b>Hi 88</b></div>")
		#expect(action(loaded: false).content == nil)
	}

	/// 1.x's page, libraries from actions/default (actions/webkit 404s in production).
	@Test func documentLoadsLibrariesFromDefault() throws
	{	let doc = try #require(HtmlDocument.build(action(), assetsUrl: testAssets, extraHead: ""))
		#expect(doc.hasPrefix("<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"))
		#expect(doc.contains("<script src=\"https://counter.personyze.com/web-view.js?v=17\"></script>"))
		#expect(doc.contains("<script src=\"https://counter.personyze.com/actions/default/timer.js?v=17\"></script><script src=\"https://counter.personyze.com/actions/default/survey.js?v=17\"></script>"))
		#expect(doc.hasSuffix("<div><b>Hi 88</b></div><script>_S_T.new_elem(document.body, null)</script></body></html>"))
		#expect(!doc.contains("webkit"))
		#expect(action().contentHtmlDocument() == doc)
	}

	@Test func notHtmlHasNoDocument()
	{	#expect(HtmlDocument.build(action(contentType: "application/json"), assetsUrl: testAssets, extraHead: "") == nil)
		#expect(HtmlDocument.build(action(loaded: false), assetsUrl: testAssets, extraHead: "") == nil)
	}

	@Test func jsonContentAsRows()
	{	let a = PersonyzeAction(
			id: 9,
			data: ["data": #"[{"id":"A1","price":9.5,"tags":["x"],"n":null},"skip"]"#],
			name: "Feed",
			contentType: "application/json",
			placeholders: [],
			placeholderOrder: nil,
			libs: [],
			contentParam: "data",
			contentBegin: "",
			contentEnd: "",
			cacheVersion: 1,
			isLoaded: true,
			assetsUrl: testAssets
		)
		#expect(a.contentJsonArray() == [["id": "A1", "price": "9.5", "tags": #"["x"]"#, "n": "null"]])
		#expect(action().contentJsonArray() == nil)
	}

	@Test func libsSplitOnCommas()
	{	#expect(HtmlDocument.libs(of: " timer, ,survey ,") == ["timer", "survey"])
	}

	/// By `placeholder_order` (none is 999), then id, at most `units_count_max`.
	@Test func actionsInAPlaceholderAreOrderedAndCapped()
	{	let slot = PersonyzePlaceholder(id: 635, name: "Home banner", htmlId: ".app-home", unitsCountMax: 2)
		func a(_ id: Int, _ order: Int?) -> PersonyzeAction
		{	PersonyzeAction(
				id: id,
				data: [:],
				name: nil,
				contentType: "text/html",
				placeholders: [slot],
				placeholderOrder: order,
				libs: [],
				contentParam: "",
				contentBegin: "",
				contentEnd: "",
				cacheVersion: 1,
				isLoaded: true,
				assetsUrl: testAssets
			)
		}
		let r = PersonyzeResult(
			actions: [a(5, nil), a(4, 2), a(3, 2), a(9, 1)],
			conditions: [],
			dismissedActions: [],
			dismissedConditions: [],
			sessionId: nil,
			cacheVersion: 1,
			rawJson: nil,
			error: nil
		)
		#expect(r.actions(in: "Home banner").map { $0.id } == [9, 3])
		#expect(r.actions(in: "elsewhere").isEmpty)
		#expect(r.first(of: 1, 4, 5) == 4)
		#expect(r.first(of: 1, 2) == nil)
	}
}

struct NotificationPollTests
{	@Test func nullMeansNothingQueued()
	{	#expect(NotificationPoll.parse("null") == nil)
		#expect(NotificationPoll.parse("") == nil)
	}

	@Test func parsesTheQueuedMessage() throws
	{	let n = try #require(NotificationPoll.parse(#"{"message_id":"12","title":" Sale ","body":"50% off","badge":"","icon":"https://x/i.png","image":"","tag":"https://shop/sale","vibrate":"200, 100,x","silent":false,"renotify":1,"actions":[{"title":"Open","icon":"","action":"https://shop/a"},{"title":"","icon":"","action":"https://shop/b"},{"title":"Later","icon":null,"action":null}]}"#))
		#expect(n.messageId == 12)
		#expect(n.title == "Sale")
		#expect(n.url == "https://shop/sale")
		#expect(n.vibrate == [200, 100])
		#expect(!n.silent)
		#expect(n.renotify)
		#expect(n.buttons.map { $0.title } == ["Open"])
	}

	@Test func titleAndBodyAreRequired()
	{	#expect(NotificationPoll.parse(#"{"message_id":1,"title":"","body":"b"}"#) == nil)
		#expect(NotificationPoll.parse(#"{"message_id":1,"title":"t","body":" "}"#) == nil)
		#expect(NotificationPoll.parse(#"{"title":"t","body":"b"}"#) == nil)
	}
}

struct VerdictParserTests
{	@Test func parsesTheVerdict() throws
	{	let v = try #require(VerdictParser.parse(#"{"condition_id":273,"condition_name":"PHP SDK A/B test","has_winner":false,"winner_actiongroup_id":null,"message":"Not enough data","control_group_rotation":20,"max_duration_reached":false,"goals":[{"ab_goal":"clicks","title":"Clicks","lower_is_better":false,"best":{"actiongroup_id":147,"name":"A","rate":0.1},"compared_to":{"actiongroup_id":0,"name":"Control","rate":null},"significance_prc":null,"improvement_prc":1.5,"min_significance_prc":95,"min_improvement_prc":0,"reached":false,"summary":"","groups":[{"actiongroup_id":147,"name":"A","value":3,"denom":30,"rate":0.1}]}]}"#))
		#expect(v.conditionId == 273)
		#expect(v.winnerActiongroupId == nil)
		#expect(v.controlGroupRotation == 20)
		#expect(v.goals[0].best?.actiongroupId == 147)
		#expect(v.goals[0].comparedTo != nil && v.goals[0].comparedTo?.rate == nil)
		#expect(v.goals[0].improvementPrc == 1.5)
		#expect(v.goals[0].groups[0].denom == 30)
	}

	@Test func notAVerdictIsNil()
	{	#expect(VerdictParser.parse("[]") == nil)
		#expect(VerdictParser.parse(#"{"message":"x"}"#) == nil)
	}
}

struct SHA256Tests
{	/// FIPS 180-2 vectors, and one longer than a block.
	@Test func knownDigests()
	{	#expect(SHA256.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
		#expect(SHA256.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
		#expect(SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
		#expect(SHA256.hex(String(repeating: "a", count: 1000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
	}
}

struct EngineStateTests
{	/// A newer SDK reads an older file: missing keys take their defaults, unknown ones are ignored.
	@Test func olderAndNewerFilesDecode() throws
	{	let st = try #require(StateCoding.decode(PersistedState.self, #"{"session":"1 2 3 4","userId":"bob","futureKey":[1,2],"result":{"actions":[{"id":88}]}}"#))
		#expect(st.session == "1 2 3 4")
		#expect(st.userId == .text("bob"))
		#expect(st.epoch == 0)
		#expect(st.notifications == PersistedNotifications())
		#expect(st.result?.actions == [PersistedAction(id: 88, data: nil)])
		#expect(StateCoding.decode(PersistedState.self, #"{"userId":42}"#)?.userId == .number(42))
	}

	@Test func stateRoundTrips() throws
	{	var st = PersistedState(apiKeyFp: "abc", userId: .number(7))
		st.blocked = [88: 2]
		st.pageReports = [88: ["executed"]]
		st.pastSessions = [3, 2, 1]
		st.notifications.delivered = [PersistedNotifications.Delivered(visitor: "7", messageId: 5)]
		let text = try #require(StateCoding.encode(st))
		#expect(StateCoding.decode(PersistedState.self, text) == st)
	}

	@Test func metadataKeepsRowsRaw() throws
	{	var md = MetadataFile(apiKeyFp: "abc", cacheVersion: 5)
		md.actions[88] = ["id": .int(88), "unknown_column": .array([.string("x"), .null, .bool(true), .double(1.5)])]
		let text = try #require(StateCoding.encode(md))
		let back = try #require(StateCoding.decode(MetadataFile.self, text))
		#expect(back.actions[88] == md.actions[88])
		#expect(back.placeholderOrder)
	}
}

struct ConcurrencyTests
{	@Test func mutexWaiterGivesUpAtItsDeadline() async
	{	let mutex = AsyncMutex()
		await mutex.lock()
		let started = Clocks.monotonicMs()
		#expect(await mutex.lock(timeoutMs: 100) == false)
		#expect(Clocks.monotonicMs() - started >= 90)
		mutex.unlock()
		#expect(await mutex.lock(timeoutMs: 100))
		mutex.unlock()
	}

	@Test func mutexIsHandedOverInOrder() async
	{	let mutex = AsyncMutex()
		let order = OrderLog()
		await mutex.lock()
		let waiters = (1 ... 3).map { i in
			Task {
				await mutex.lock()
				order.add(i)
				mutex.unlock()
			}
		}
		await pause(50)	// lets every waiter queue up
		mutex.unlock()
		for waiter in waiters
		{	await waiter.value
		}
		#expect(order.all.sorted() == [1, 2, 3])
	}

	@Test func stateCellAnnouncesChangesOnly() async
	{	let cell = StateCell(1)
		var values = cell.stream().makeAsyncIterator()
		#expect(await values.next() == 1)
		cell.set(1)
		cell.set(2)
		#expect(await values.next() == 2)
	}
}

private final class OrderLog: @unchecked Sendable
{	private let lock = NSLock()
	private var items: [Int] = []

	func add(_ i: Int)
	{	lock.locked
		{	items.append(i)
		}
	}

	var all: [Int]
	{	lock.locked
		{	items
		}
	}
}

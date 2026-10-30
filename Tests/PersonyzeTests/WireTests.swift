import Foundation
import Testing
@testable import Personyze

struct WireTests
{	/// The field names the guide documents, in its order, nothing renamed (SPEC section 1).
	@Test func requestBodyHasTheGuidesFields()
	{	let body = Wire.requestBody(
			userId: .number(500123456),
			sessionId: nil,
			newSession: true,
			pastSessions: [1761220800, 1761000000],
			device: DeviceContext(platform: "iOS", timeZone: 5.5, languages: "en-US,he-IL", screen: "390x844", os: "iOS/17.2", deviceType: "phone"),
			notiEnabled: false,
			commands: [["Navigate", "urn:personyze:doc:Home"], ["User profile", "gender", nil]]
		)
		#expect(body == #"{"user_id":500123456,"session_id":null,"new_session":true,"past_sessions":"1761220800,1761000000","platform":"iOS","time_zone":5.5,"languages":"en-US,he-IL","screen":"390x844","os":"iOS/17.2","device_type":"phone","noti_enabled":false,"commands":[["Navigate","urn:personyze:doc:Home"],["User profile","gender",null]]}"#)
	}

	@Test func textUserIdStaysText()
	{	let body = Wire.requestBody(
			userId: .text("42"),
			sessionId: "1 42 7 1",
			newSession: false,
			pastSessions: [],
			device: DeviceContext(platform: "iOS", timeZone: 0, languages: "", screen: "", os: "", deviceType: "regular"),
			notiEnabled: true,
			commands: []
		)
		#expect(body.hasPrefix(#"{"user_id":"42","session_id":"1 42 7 1","new_session":false,"past_sessions":"","platform":"iOS","time_zone":0.0,"#))
	}

	@Test func stringsAreEscaped()
	{	#expect(JSON.string("a\"b\\c\nd\u{1}é😀").serialized == #""a\"b\\c\nd\u0001é😀""#)
	}

	@Test func responseIsReadLeniently() throws
	{	let r = try #require(Wire.parseResponse(#"{"session_id":"1 2 3 1","cache_version":"17","conditions":[{"id":42},{"id":"43"}],"actions":[{"id":88,"data":{"data":"x","n":5,"o":{"a":1}}},{"id":89}],"dismiss_conditions":[1],"dismiss_actions":["51"],"extra":true}"#))
		#expect(r.sessionId == "1 2 3 1")
		#expect(r.cacheVersion == 17)
		#expect(r.conditions == [42, 43])
		#expect(r.actions[0].data == ["data": "x", "n": "5", "o": #"{"a":1}"#])
		#expect(r.actions[1].data == nil)
		#expect(r.dismissActions == [51])
	}

	@Test func notTheTrackersJsonIsNil()
	{	#expect(Wire.parseResponse("<html>") == nil)
		#expect(Wire.parseResponse("[]") == nil)
		#expect(Wire.parseResponse(#"{"a":1}"#) == nil)
		#expect(Wire.parseResponse(#"{"session_id":"","actions":[]}"#)?.sessionId == nil)
		#expect(Wire.parseResponse(#"{"session_id":null}"#) != nil)
	}

	@Test func numbersAndBooleansAreReadAsTheyCome()
	{	#expect(JSON.parse("true") == .bool(true))
		#expect(JSON.parse("1") == .int(1))
		#expect(JSON.parse("9.5") == .double(9.5))
		#expect(Wire.int(JSON.parse("42.0")) == 42)
		#expect(Wire.int(JSON.parse("4294967296")) == nil)
		#expect(Wire.int(JSON.parse("true")) == nil)
		#expect(Wire.bool(JSON.parse(#""1""#)))
		#expect(!Wire.bool(JSON.parse(#""false""#)))
		#expect(Wire.long(JSON.parse(#"" 12 ""#)) == 12)
	}

	@Test func intListReadsArraysAndCsv()
	{	#expect(Wire.intList(JSON.parse(#"[1,"2"]"#)) == [1, 2])
		#expect(Wire.intList(.string("3, 4")) == [3, 4])
		#expect(Wire.intList(nil) == [])
	}

	@Test func dateHeader()
	{	#expect(HttpDate.parseMs("Thu, 01 Jan 1970 00:00:00 GMT") == 0)
		#expect(HttpDate.parseMs("Sun, 06 Nov 1994 08:49:37 GMT") == 784_111_777_000)
		#expect(HttpDate.parseMs("Wed, 29 Feb 2028 23:59:59 GMT") == 1_835_481_599_000)
		#expect(HttpDate.parseMs("Sunday, 06-Nov-94 08:49:37 GMT") == nil)
		#expect(HttpDate.parseMs("Sun, 06 Nov 1994 08:49:37 PST") == nil)
	}
}

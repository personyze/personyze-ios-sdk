import Testing
@testable import Personyze

struct SessionTests
{	@Test func startTimeIsFieldZero()
	{	#expect(Session.startTime("1761220800 42 7 1 1761220800 0 491 0") == 1761220800)
		#expect(Session.startTime("  1761220800") == 1761220800)
	}

	/// Garbage reads as 0, i.e. long expired - so a corrupt session heals instead of answering 400 forever.
	@Test func unparseableStartIsZero()
	{	#expect(Session.startTime(nil) == 0)
		#expect(Session.startTime("") == 0)
		#expect(Session.startTime("abc 1 2") == 0)
		#expect(Session.startTime("99999999999999999999 1 2") == 0)
		#expect(Session.startTime("12x 1") == 0)
	}

	@Test func visitorIsFieldOne()
	{	#expect(Session.visitor("1 42 7 1") == 42)
		#expect(Session.visitor("1 -963761860 7 1") == -963761860)
		#expect(Session.visitor("1") == nil)
		#expect(Session.visitor("1 abc") == nil)
		#expect(Session.visitor("1 -") == nil)
		#expect(Session.visitor(nil) == nil)
	}

	@Test func expiryUsesNinetyMinutesLessFiveSeconds()
	{	let start: Int64 = 1_761_220_800
		let s = "\(start) 42 7 1"
		#expect(!Session.isExpired(s, serverNowMs: start*1000 + Session.ttlMs - 5001))
		#expect(Session.isExpired(s, serverNowMs: start*1000 + Session.ttlMs - 5000))
		#expect(Session.isExpired(nil, serverNowMs: 0))
		#expect(Session.isExpired("garbage", serverNowMs: start*1000))
	}

	/// The vectors of the Node port (test/client.test.js), the first confirmed against the live endpoint.
	@Test func serverUserIdMatchesNode()
	{	#expect(Session.serverUserId(.text("pythonsdk-test-6ada7418@example.com")) == -963761860)
		let ids: [UserId] = [.number(123), .text("123"), .text(" 42 "), .text("0x1A"), .text("1e3")]
		#expect(ids.map { Session.serverUserId($0) } == [123, 123, 42, 26, 1000])
		#expect(Session.serverUserId(.number(0)) == Session.serverUserId(.text("0")))
		#expect(Session.serverUserId(nil) == nil)
		#expect(Session.serverUserId(.text("")) == nil)
		#expect(Session.serverUserId(.text("   ")) == nil)
		#expect(Session.serverUserId(.text("12.5")) == nil)
	}

	@Test func serverUserIdFollowsJsNumber()
	{	#expect(Session.serverUserId(.text("+5")) == 5)
		#expect(Session.serverUserId(.text("0b11")) == 3)
		#expect(Session.serverUserId(.text("0o17")) == 15)
		#expect(Session.serverUserId(.text("\u{A0}42\u{FEFF}")) == 42)
		#expect(Session.serverUserId(.text("-2147483648")) == -2147483648)
		#expect(Session.serverUserId(.number(2147483647)) == 2147483647)
		#expect(Session.serverUserId(.text("5.")) == 5)
		// Not numbers to JavaScript, or out of range: the CRC of the text.
		#expect(Session.serverUserId(.text("-0x1A")) == crc("-0x1A"))
		#expect(Session.serverUserId(.text("2147483648")) == crc("2147483648"))
		#expect(Session.serverUserId(.number(2147483648)) == crc("2147483648"))
		#expect(Session.serverUserId(.text("Infinity")) == crc("Infinity"))
		#expect(Session.serverUserId(.text("1_000")) == crc("1_000"))
		#expect(Session.serverUserId(.text("0x")) == crc("0x"))
		#expect(Session.serverUserId(.text("-0")) == crc("-0"))
		#expect(Session.serverUserId(.text(".5")) == nil)
	}

	@Test func jsNumberGrammar()
	{	#expect(Session.jsNumber("") == 0)
		#expect(Session.jsNumber(".5") == 0.5)
		#expect(Session.jsNumber("1E3") == 1000)
		#expect(Session.jsNumber("-1.5e-1") == -0.15)
		#expect(Session.jsNumber("1f").isNaN)
		#expect(Session.jsNumber("NaN").isNaN)
		#expect(Session.jsNumber("nan").isNaN)
		#expect(Session.jsNumber("inf").isNaN)
		#expect(Session.jsNumber("0x1p3").isNaN)
		#expect(Session.jsNumber("0o9").isNaN)
		#expect(Session.jsNumber("1e").isNaN)
		#expect(Session.jsNumber(".").isNaN)
		#expect(Session.jsNumber("-Infinity") == -.infinity)
	}

	@Test func jsTrimIsWiderThanAscii()
	{	#expect(Session.jsTrim("\u{2003}\u{3000} a b \u{2028}\u{FEFF}") == "a b")
		#expect(Session.jsTrim("\u{200B}x") == "\u{200B}x")
	}

	@Test func utf8LikeTextEncoder()
	{	#expect(Session.utf8("😀") == [0xF0, 0x9F, 0x98, 0x80])
		#expect(Session.utf8("ש") == [0xD7, 0xA9])
	}

	@Test func crc32CheckValue()
	{	#expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF43926)
		#expect(CRC32.checksum([UInt8]()) == 0)
	}

	@Test func sessionOfAnotherVisitorIsNotOurs()
	{	#expect(Session.isSessionOf("1 42 7 1", .number(42)))
		#expect(Session.isSessionOf("1 42 7 1", .text("42")))
		#expect(!Session.isSessionOf("1 42 7 1", .number(43)))
		#expect(Session.isSessionOf("1 -963761860 7 1", .text("pythonsdk-test-6ada7418@example.com")))
		// Cannot tell: kept, and left to the expiry rule.
		#expect(Session.isSessionOf("garbage", .number(42)))
		#expect(Session.isSessionOf("1 42 7 1", .text("12.5")))
	}

	@Test func counterIsFieldThree()
	{	#expect(Session.counter("1 42 7 3 1 0 491 0") == 3)
		#expect(Session.counter("1 42") == nil)
	}

	private func crc(_ s: String) -> Int32
	{	Int32(bitPattern: CRC32.checksum(Array(s.utf8)))
	}
}

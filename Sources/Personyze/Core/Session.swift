import Foundation

/// A visitor id as the app gives it: a number of its own, or text (an email, a UUID). It goes out
/// as it came, a JSON number or a JSON string, and the server makes a visitor of either
/// (`Session.serverUserId`).
enum UserId: Sendable, Hashable
{	case number(Int64)
	case text(String)

	var json: JSON
	{	switch self
		{	case .number(let n):
				return .int(n)
			case .text(let s):
				return .string(s)
		}
	}

	/// The id as text: what the server hashes when it is not a 32-bit number.
	var text: String
	{	switch self
		{	case .number(let n):
				return String(n)
			case .text(let s):
				return s
		}
	}
}

/// The session string and the visitor id - the two things a port must get right (SPEC section 3).
///
/// The session string is opaque except for two fields: 0, the session's start (a Unix time), and
/// 1, the visitor it belongs to. Everything else (visit id, counter, hosts) is the server's.
enum Session
{	/// The server's own session timeout.
	static let ttlMs: Int64 = 90*60_000
	/// Renew a session about to expire deliberately, rather than have it rejected in flight.
	static let expiryMarginMs: Int64 = 5000

	/// Field 0 in seconds, or 0 for anything that is not one.
	///
	/// At most 10 digits: a corrupted `99999999999999999999 …` must read as garbage (expired), not
	/// as a start far in the future that never expires - that answers `400 Invalid session_id`
	/// forever.
	static func startTime(_ sessionId: String?) -> Int64
	{	guard let bytes = sessionId.map({ Array($0.utf8) }) else
		{	return 0
		}
		var i = 0
		while i < bytes.count && isSpace(bytes[i])
		{	i += 1
		}
		var value: Int64 = 0
		var digits = 0
		while i < bytes.count && isDigit(bytes[i])
		{	digits += 1
			if digits > 10
			{	return 0
			}
			value = value*10 + Int64(bytes[i] - 0x30)
			i += 1
		}
		if digits == 0 || i < bytes.count && !isSpace(bytes[i])
		{	return 0
		}
		return value
	}

	/// Field 1: the visitor the session belongs to, or nil when it holds none.
	static func visitor(_ sessionId: String?) -> Int64?
	{	guard let field = field(sessionId, 1) else
		{	return nil
		}
		let digits = field.hasPrefix("-") ? field.dropFirst() : field
		guard (1 ... 10).contains(digits.utf8.count) && digits.utf8.allSatisfy(isDigit) else
		{	return nil
		}
		return Int64(field)
	}

	/// Field 3, the session counter: 1 for the visitor's first session. Read only by diagnostics
	/// and the conformance test (step 7) - the SDK itself treats it as opaque.
	static func counter(_ sessionId: String?) -> Int?
	{	field(sessionId, 3).flatMap { Int32($0) }.map { Int($0) }
	}

	static func isExpired(_ sessionId: String?, serverNowMs: Int64) -> Bool
	{	guard let sessionId, !sessionId.isEmpty else
		{	return true
		}
		return startTime(sessionId)*1000 + ttlMs - expiryMarginMs <= serverNowMs
	}

	/// Whether `sessionId` may be sent for `userId`: false only when it surely belongs to another
	/// visitor. Anything that cannot be told either way is left to the expiry rule.
	static func isSessionOf(_ sessionId: String?, _ userId: UserId?) -> Bool
	{	guard let owner = visitor(sessionId), let expected = serverUserId(userId) else
		{	return true
		}
		return owner == Int64(expected)
	}

	/// The visitor id the server makes of `user_id` (`LogVisitRequest.fromSdkTracker`): what
	/// JavaScript's `Number()` reads as a non-zero 32-bit integer is that integer; anything else the
	/// CRC-32 of its text in UTF-8, as a signed 32-bit integer. Nil for no id, and for a number with
	/// a fraction, which the server keeps as it is.
	static func serverUserId(_ userId: UserId?) -> Int32?
	{	guard let userId else
		{	return nil
		}
		let text = userId.text
		if jsTrim(text).isEmpty
		{	return nil
		}
		var n: Double
		switch userId
		{	case .number(let i):
				n = Double(i)
			case .text:
				n = jsNumber(text)
		}
		if n.isNaN
		{	n = 0
		}
		if n != 0 && n >= Double(Int32.min) && n <= Double(Int32.max)
		{	return n == n.rounded(.down) ? Int32(n) : nil
		}
		return Int32(bitPattern: CRC32.checksum(utf8(text)))
	}

	/// JavaScript's `Number(string)` (ECMA-262 StringToNumber): trimmed; empty is 0; `0x`/`0o`/`0b`
	/// integers without a sign; decimal with an optional sign, fraction and exponent; `Infinity`;
	/// anything else NaN. No numeric separators. Swift's `Double(String)` accepts more (`nan`,
	/// `inf`, hex floats), so the grammar is matched first.
	static func jsNumber(_ text: String) -> Double
	{	let s = jsTrim(text)
		let b = Array(s.utf8)
		if b.isEmpty
		{	return 0
		}
		// No sign before a radix prefix: `Number("-0x1A")` is NaN.
		if b.count > 2 && b[0] == 0x30
		{	var radix: Double = 0
			switch b[1]
			{	case 0x78, 0x58:
					radix = 16
				case 0x6F, 0x4F:
					radix = 8
				case 0x62, 0x42:
					radix = 2
				default:
					break
			}
			if radix != 0
			{	var value: Double = 0
				for c in b[2...]
				{	guard let d = digitValue(c), d < radix else
					{	return .nan
					}
					value = value*radix + d
				}
				return value
			}
		}
		var i = 0
		var negative = false
		if b[0] == 0x2B || b[0] == 0x2D
		{	negative = b[0] == 0x2D
			i = 1
		}
		if b[i...].elementsEqual("Infinity".utf8)
		{	return negative ? -.infinity : .infinity
		}
		let intDigits = countDigits(b, &i)
		var fracDigits = 0
		if i < b.count && b[i] == 0x2E
		{	i += 1
			fracDigits = countDigits(b, &i)
		}
		if intDigits == 0 && fracDigits == 0
		{	return .nan
		}
		if i < b.count && (b[i] == 0x65 || b[i] == 0x45)
		{	i += 1
			if i < b.count && (b[i] == 0x2B || b[i] == 0x2D)
			{	i += 1
			}
			if countDigits(b, &i) == 0
			{	return .nan
			}
		}
		if i != b.count
		{	return .nan
		}
		return Double(s) ?? .nan
	}

	/// `String.prototype.trim`: WhiteSpace and LineTerminator, which include U+00A0, U+FEFF and
	/// every Unicode space separator - wider than Foundation's whitespace set.
	static func jsTrim(_ s: String) -> String
	{	let scalars = s.unicodeScalars
		var start = scalars.startIndex
		var end = scalars.endIndex
		while start < end && isJsSpace(scalars[start])
		{	start = scalars.index(after: start)
		}
		while end > start && isJsSpace(scalars[scalars.index(before: end)])
		{	end = scalars.index(before: end)
		}
		return String(scalars[start ..< end])
	}

	/// UTF-8 as JavaScript's `TextEncoder` writes it. A Swift string cannot hold an unpaired
	/// surrogate - decoding replaces one with U+FFFD, which is what `TextEncoder` writes for it -
	/// so the string's own UTF-8 is that.
	static func utf8(_ s: String) -> [UInt8]
	{	Array(s.utf8)
	}

	private static func field(_ sessionId: String?, _ n: Int) -> Substring?
	{	guard let parts = sessionId?.split(separator: " ", omittingEmptySubsequences: false), n < parts.count else
		{	return nil
		}
		return parts[n]
	}

	/// `\s` of the patterns this ports: space, tab, LF, VT, FF, CR.
	private static func isSpace(_ c: UInt8) -> Bool
	{	c == 0x20 || (0x09 ... 0x0D).contains(c)
	}

	private static func isDigit(_ c: UInt8) -> Bool
	{	(0x30 ... 0x39).contains(c)
	}

	private static func countDigits(_ b: [UInt8], _ i: inout Int) -> Int
	{	let from = i
		while i < b.count && isDigit(b[i])
		{	i += 1
		}
		return i - from
	}

	private static func digitValue(_ c: UInt8) -> Double?
	{	switch c
		{	case 0x30 ... 0x39:
				return Double(c - 0x30)
			case 0x61 ... 0x66:
				return Double(c - 0x61 + 10)
			case 0x41 ... 0x46:
				return Double(c - 0x41 + 10)
			default:
				return nil
		}
	}

	private static func isJsSpace(_ u: Unicode.Scalar) -> Bool
	{	switch u.value
		{	case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0xFEFF, 0x2028, 0x2029:
				return true
			default:
				return u.properties.generalCategory == .spaceSeparator
		}
	}
}

/// CRC-32 (IEEE 802.3), as zlib and JavaScript's crc32 libraries compute it.
enum CRC32
{	private static let table: [UInt32] = (0 ..< 256).map { n in
		var c = UInt32(n)
		for _ in 0 ..< 8
		{	c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
		}
		return c
	}

	static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32
	{	var crc: UInt32 = 0xFFFFFFFF
		for b in bytes
		{	crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
		}
		return crc ^ 0xFFFFFFFF
	}
}

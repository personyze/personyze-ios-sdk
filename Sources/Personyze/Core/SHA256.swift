import Foundation

/// SHA-256 (FIPS 180-4), for the API key's fingerprint. Foundation has no hash on Linux, and
/// CryptoKit is Apple's only.
enum SHA256
{	/// Lower-case hex of the digest of `text` in UTF-8.
	static func hex(_ text: String) -> String
	{	digest(Array(text.utf8)).map { byte in String(byte, radix: 16).leftPadded(to: 2) }.joined()
	}

	static func digest(_ message: [UInt8]) -> [UInt8]
	{	var h: [UInt32] = [
			0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
		]
		var data = message
		data.append(0x80)
		while data.count % 64 != 56
		{	data.append(0)
		}
		let bits = UInt64(message.count)*8
		for shift in stride(from: 56, through: 0, by: -8)
		{	data.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
		}
		var w = [UInt32](repeating: 0, count: 64)
		for chunk in stride(from: 0, to: data.count, by: 64)
		{	for i in 0 ..< 16
			{	let at = chunk + i*4
				w[i] = UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
			}
			for i in 16 ..< 64
			{	let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
				let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
				w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
			}
			var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
			for i in 0 ..< 64
			{	let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
				let ch = (e & f) ^ (~e & g)
				let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
				let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
				let maj = (a & b) ^ (a & c) ^ (b & c)
				let t2 = s0 &+ maj
				hh = g
				g = f
				f = e
				e = d &+ t1
				d = c
				c = b
				b = a
				a = t1 &+ t2
			}
			h[0] = h[0] &+ a
			h[1] = h[1] &+ b
			h[2] = h[2] &+ c
			h[3] = h[3] &+ d
			h[4] = h[4] &+ e
			h[5] = h[5] &+ f
			h[6] = h[6] &+ g
			h[7] = h[7] &+ hh
		}
		return h.flatMap { word in [UInt8(word >> 24), UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF)] }
	}

	private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32
	{	x >> n | x << (32 - n)
	}

	private static let k: [UInt32] = [
		0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
		0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
		0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
		0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
		0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
		0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
		0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
		0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
	]
}

extension String
{	func leftPadded(to width: Int, with pad: Character = "0") -> String
	{	count >= width ? self : String(repeating: pad, count: width - count) + self
	}
}

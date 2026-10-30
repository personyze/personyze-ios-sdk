import Foundation

/// Paths under `<baseUrl>/rest/`, and the two encodings they need.
enum Endpoints
{	static let tracker = "tracker-v1"

	/// The 1.x columns plus `placeholder_order` (SPEC section 10), so actions order as the web tag
	/// orders them. A server older than that column answers 400; then `actionColumnsV1`.
	static let actionColumns = "id,name,content_type,content_param,content_begin,content_end,libs_app,placeholders,placeholder_order"
	static let actionColumnsV1 = "id,name,content_type,content_param,content_begin,content_end,libs_app,placeholders"
	static let conditionColumns = "id,name"
	static let placeholderColumns = "id,name,html_id,units_count_max"

	static func conditions(_ ids: some Sequence<Int>) -> String
	{	"conditions/columns/\(conditionColumns)/where/id:" + list(ids)
	}

	static func actions(_ ids: some Sequence<Int>, withOrder: Bool) -> String
	{	"actions/columns/" + (withOrder ? actionColumns : actionColumnsV1) + "/where/id:" + list(ids)
	}

	static func placeholders(_ ids: some Sequence<Int>) -> String
	{	"placeholders/columns/\(placeholderColumns)/where/id:" + list(ids)
	}

	static func verdict(_ conditionId: Int) -> String
	{	"ab_test/where/condition_id=\(conditionId)"
	}

	/// The visitor's queued notification, by the visitor id - the id the server makes of `user_id`,
	/// which is what field 1 of their session holds. It needs no encoding, and is all the server
	/// reads from a session here (SPEC section 11).
	static func notification(_ visitorId: Int32, messageId: Int64? = nil) -> String
	{	var path = "current_notification/where/user_id=\(visitorId)"
		if let messageId
		{	path += "&message_id=\(messageId)"
		}
		return path
	}

	/// The document of a `Navigate`. The server decodes it (`decodeURIComponent`), so a raw `%`
	/// in a name threw there; a name without special characters arrives exactly as before.
	static func documentUrn(_ document: String) -> String
	{	"urn:personyze:doc:" + encodeURIComponent(document)
	}

	/// JavaScript's `encodeURIComponent`: everything but `A-Z a-z 0-9 - _ . ! ~ * ' ( )` as UTF-8
	/// percent escapes (a space is `%20`, never `+`).
	static func encodeURIComponent(_ s: String) -> String
	{	var out = ""
		out.reserveCapacity(s.utf8.count + 16)
		for c in s.utf8
		{	if isUnreserved(c)
			{	out.unicodeScalars.append(Unicode.Scalar(c))
			}
			else
			{	out.unicodeScalars.append("%")
				out.unicodeScalars.append(hexDigits[Int(c >> 4)])
				out.unicodeScalars.append(hexDigits[Int(c & 0xF)])
			}
		}
		return out
	}

	private static let hexDigits = Array("0123456789ABCDEF".unicodeScalars)

	private static func isUnreserved(_ c: UInt8) -> Bool
	{	switch c
		{	case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39:
				return true
			default:
				return "-_.!~*'()".utf8.contains(c)
		}
	}

	private static func list(_ ids: some Sequence<Int>) -> String
	{	ids.map(String.init).joined(separator: ",")
	}
}

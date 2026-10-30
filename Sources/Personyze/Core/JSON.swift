import Foundation

/// A JSON value, read leniently from what the tracker and `/rest` answer.
///
/// Decoded into this enum rather than read through `JSONSerialization`, whose `Any` bridges numbers
/// and booleans differently on Darwin and on Linux - the tests run on both and must read a body as
/// an iPhone does.
///
/// Written by hand, so a request's keys go out in the order the guide lists them on every OS
/// version (Darwin's older `JSONEncoder` ordered them by hash), and so the same value always
/// writes the same text.
enum JSON: Sendable, Equatable
{	case null
	case bool(Bool)
	case int(Int64)
	case double(Double)
	case string(String)
	case array([JSON])
	case object([String: JSON])

	subscript(key: String) -> JSON?
	{	if case .object(let fields) = self
		{	return fields[key]
		}
		return nil
	}

	var arrayValue: [JSON]?
	{	if case .array(let items) = self
		{	return items
		}
		return nil
	}

	var objectValue: [String: JSON]?
	{	if case .object(let fields) = self
		{	return fields
		}
		return nil
	}

	/// Nil for text that is not JSON.
	static func parse(_ text: String) -> JSON?
	{	parse(Data(text.utf8))
	}

	static func parse(_ data: Data) -> JSON?
	{	try? JSONDecoder().decode(JSON.self, from: data)
	}

	/// Compact JSON. Object keys are sorted.
	var serialized: String
	{	var out = ""
		write(to: &out)
		return out
	}

	/// An object with its keys in the order given.
	static func serialize(orderedObject pairs: [(String, JSON)]) -> String
	{	var out = "{"
		for (i, (key, value)) in pairs.enumerated()
		{	if i > 0
			{	out += ","
			}
			writeString(key, to: &out)
			out += ":"
			value.write(to: &out)
		}
		out += "}"
		return out
	}

	private func write(to out: inout String)
	{	switch self
		{	case .null:
				out += "null"
			case .bool(let b):
				out += b ? "true" : "false"
			case .int(let n):
				out += String(n)
			case .double(let d):
				out += d.isFinite ? String(d) : "null"
			case .string(let s):
				JSON.writeString(s, to: &out)
			case .array(let items):
				out += "["
				for (i, item) in items.enumerated()
				{	if i > 0
					{	out += ","
					}
					item.write(to: &out)
				}
				out += "]"
			case .object(let fields):
				out += JSON.serialize(orderedObject: fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
		}
	}

	private static let hexDigits = Array("0123456789ABCDEF".unicodeScalars)

	private static func writeString(_ s: String, to out: inout String)
	{	out += "\""
		for u in s.unicodeScalars
		{	switch u
			{	case "\"":
					out += "\\\""
				case "\\":
					out += "\\\\"
				case "\n":
					out += "\\n"
				case "\r":
					out += "\\r"
				case "\t":
					out += "\\t"
				default:
					if u.value < 0x20
					{	out += "\\u00"
						out.unicodeScalars.append(hexDigits[Int(u.value >> 4)])
						out.unicodeScalars.append(hexDigits[Int(u.value & 0xF)])
					}
					else
					{	out.unicodeScalars.append(u)
					}
			}
		}
		out += "\""
	}
}

extension JSON: Decodable
{	/// `Bool` first: decoding a number as `Bool` fails everywhere, while Darwin's older decoder
	/// reads `true` as the integer 1.
	init(from decoder: any Decoder) throws
	{	let c = try decoder.singleValueContainer()
		if c.decodeNil()
		{	self = .null
		}
		else if let b = try? c.decode(Bool.self)
		{	self = .bool(b)
		}
		else if let n = try? c.decode(Int64.self)
		{	self = .int(n)
		}
		else if let d = try? c.decode(Double.self)
		{	self = .double(d)
		}
		else if let s = try? c.decode(String.self)
		{	self = .string(s)
		}
		else if let items = try? c.decode([JSON].self)
		{	self = .array(items)
		}
		else
		{	self = .object(try c.decode([String: JSON].self))
		}
	}
}

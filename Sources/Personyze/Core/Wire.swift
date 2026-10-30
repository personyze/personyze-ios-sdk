import Foundation

/// What describes the device on every request.
struct DeviceContext: Sendable, Equatable
{	/// What the system calls itself (`iOS`, `iPadOS`), as the 1.x SDK sent it.
	var platform: String
	/// Hours from UTC, with a fraction for zones such as India's (5.5).
	var timeZone: Double
	/// The user's preferred languages, comma-separated (`en-US,he-IL`).
	var languages: String
	/// `WIDTHxHEIGHT`.
	var screen: String
	/// `iOS/17.2`. The server reads a name, a slash and a version of digits and dots, and drops
	/// anything else.
	var os: String
	/// `phone`, `tablet` or `regular`.
	var deviceType: String
}

/// The tracker request and response, with the field names the guide documents. A port must not
/// rename or reshape them (SPEC section 1).
enum Wire
{	static func requestBody
	(	userId: UserId,
		sessionId: String?,
		newSession: Bool,
		pastSessions: [Int64],
		device: DeviceContext,
		notiEnabled: Bool,
		commands: [Command]
	) -> String
	{	let commandsJson: [JSON] = commands.map { cmd in .array(cmd.map { arg in arg.map(JSON.string) ?? .null }) }
		return JSON.serialize(
			orderedObject: [
				("user_id", userId.json),
				("session_id", sessionId.map(JSON.string) ?? .null),
				("new_session", .bool(newSession)),
				("past_sessions", .string(pastSessions.map(String.init).joined(separator: ","))),
				("platform", .string(device.platform)),
				("time_zone", .double(device.timeZone)),
				("languages", .string(device.languages)),
				("screen", .string(device.screen)),
				("os", .string(device.os)),
				("device_type", .string(device.deviceType)),
				("noti_enabled", .bool(notiEnabled)),
				("commands", .array(commandsJson)),
			]
		)
	}

	struct Decided: Sendable, Equatable
	{	let id: Int
		let data: [String: String]?
	}

	struct TrackerResponse: Sendable, Equatable
	{	let sessionId: String?
		let cacheVersion: Int
		let conditions: [Int]
		let actions: [Decided]
		let dismissConditions: [Int]
		let dismissActions: [Int]
		let raw: String
	}

	/// Nil when the body is not the object the tracker sends - treated as a failed request.
	static func parseResponse(_ text: String) -> TrackerResponse?
	{	guard let obj = JSON.parse(text)?.objectValue, obj["actions"] != nil || obj["session_id"] != nil else
		{	return nil
		}
		return TrackerResponse(
			sessionId: primitiveText(obj["session_id"]).flatMap { $0.isEmpty ? nil : $0 },
			cacheVersion: int(obj["cache_version"]) ?? 0,
			conditions: (obj["conditions"]?.arrayValue ?? []).compactMap { int($0["id"]) },
			actions: (obj["actions"]?.arrayValue ?? []).compactMap { (row: JSON) -> Decided? in
				guard let id = int(row["id"]) else
				{	return nil
				}
				return Decided(id: id, data: row["data"]?.objectValue?.mapValues { Wire.text($0) })
			},
			dismissConditions: (obj["dismiss_conditions"]?.arrayValue ?? []).compactMap { int($0) },
			dismissActions: (obj["dismiss_actions"]?.arrayValue ?? []).compactMap { int($0) },
			raw: text
		)
	}

	/// A REST GET answering an array of rows. Nil when it is not one.
	static func parseRows(_ text: String) -> [[String: JSON]]?
	{	JSON.parse(text)?.arrayValue?.compactMap { $0.objectValue }
	}

	/// An id or count that may come as a number or as numeric text; nil outside 32 bits.
	static func int(_ e: JSON?) -> Int?
	{	switch e
		{	case .int(let n)?:
				return Int32(exactly: n).map { Int($0) }
			case .double(let d)?:
				return Int32(exactly: d).map { Int($0) }
			case .string(let s)?:
				let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
				if let n = Int32(t)
				{	return Int(n)
				}
				return Double(t).flatMap { Int32(exactly: $0) }.map { Int($0) }
			default:
				return nil
		}
	}

	static func long(_ e: JSON?) -> Int64?
	{	switch e
		{	case .int(let n)?:
				return n
			case .double(let d)?:
				return Int64(exactly: d)
			case .string(let s)?:
				return Int64(s.trimmingCharacters(in: .whitespacesAndNewlines))
			default:
				return nil
		}
	}

	static func double(_ e: JSON?) -> Double?
	{	switch e
		{	case .int(let n)?:
				return Double(n)
			case .double(let d)?:
				return d
			case .string(let s)?:
				return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
			default:
				return nil
		}
	}

	/// `true`, or a number other than 0 - as a number or as text.
	static func bool(_ e: JSON?) -> Bool
	{	switch e
		{	case .bool(let b)?:
				return b
			case .int(let n)?:
				return n != 0
			case .double(let d)?:
				return d != 0
			case .string(let s)?:
				return s == "true" || (Double(s) ?? 0) != 0
			default:
				return false
		}
	}

	/// A value as text, the way the 1.x SDKs stringified it: strings as they are, other JSON as JSON.
	static func text(_ e: JSON?) -> String
	{	switch e
		{	case nil, .null?:
				return ""
			case .string(let s)?:
				return s
			case let other?:
				return other.serialized
		}
	}

	/// An array of ids, or the same as comma-separated text.
	static func intList(_ e: JSON?) -> [Int]
	{	switch e
		{	case .array(let items)?:
				return items.compactMap { int($0) }
			case nil, .null?, .object?:
				return []
			case let other?:
				return text(other).split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)).map { Int($0) } }
		}
	}

	/// The text of a string, number or boolean; nil for null, an array or an object.
	private static func primitiveText(_ e: JSON?) -> String?
	{	switch e
		{	case .string?, .int?, .double?, .bool?:
				return text(e)
			default:
				return nil
		}
	}
}

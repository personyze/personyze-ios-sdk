import Foundation

/// The 1.x SDK's state in `UserDefaults`, read once so an upgraded app keeps its visitors - their
/// history and their A/B arms. Its templates cache (`.dat` files in Caches) is not worth migrating;
/// it reloads.
///
/// 1.x sent `identifierForVendor.hashValue` as `user_id`, which Swift reseeds on every launch: the
/// server filed the visitor under whatever field 1 of the session string held, and the session
/// string is where that visitor survived. It also fingerprinted the key with `hashValue`, so its
/// own "another key" check failed on every launch and nothing tells the account: same account is
/// assumed.
struct LegacyDefaults: LegacySource
{	/// Nil for `UserDefaults.standard`; tests use a suite of their own.
	let suiteName: String?
	let cacheDirectory: URL?

	static let sessionKey = "Personyze User"
	static let pastSessionsKey = "Personyze Past Sessions"
	static let blockedKey = "Personyze Blocked Actions"
	static let newSessionKey = "Personyze New Session"
	static let otherKeys = ["Personyze Conditions", "Personyze Actions", "Personyze Cache Version", "Api Key Hash"]

	private var defaults: UserDefaults
	{	suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
	}

	func read() -> LegacyState?
	{	let d = defaults
		let session = d.string(forKey: LegacyDefaults.sessionKey).flatMap { $0.isEmpty ? nil : $0 }
		let past = d.string(forKey: LegacyDefaults.pastSessionsKey) ?? ""
		let blocked = d.string(forKey: LegacyDefaults.blockedKey) ?? ""
		if session == nil && past.isEmpty && blocked.isEmpty
		{	return nil
		}
		return LegacyState(
			visitorId: Session.visitor(session).flatMap { Int32(exactly: $0) }.flatMap { $0 == 0 ? nil : $0 },
			session: session,
			pastSessionsOldestFirst: past.split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) },
			blocked: LegacyDefaults.blockedActions(blocked),
			newSession: d.bool(forKey: LegacyDefaults.newSessionKey),
			notiLastCheckMs: 0,
			sameAccount: true
		)
	}

	/// `"88:2,89:1"`: action id -> sessions left, as 1.x's `StoredIntMap` wrote it.
	static func blockedActions(_ text: String) -> [Int: Int]
	{	var map: [Int: Int] = [:]
		for pair in text.split(separator: ",")
		{	let kv = pair.split(separator: ":", omittingEmptySubsequences: false)
			if kv.count == 2, let k = Int(kv[0].trimmingCharacters(in: .whitespaces)), let v = Int(kv[1].trimmingCharacters(in: .whitespaces)), k > 0, v > 0
			{	map[k] = v
			}
		}
		return map
	}

	func delete()
	{	let d = defaults
		for key in [LegacyDefaults.sessionKey, LegacyDefaults.pastSessionsKey, LegacyDefaults.blockedKey, LegacyDefaults.newSessionKey] + LegacyDefaults.otherKeys
		{	d.removeObject(forKey: key)
		}
		guard let dir = cacheDirectory else
		{	return
		}
		let fm = FileManager.default
		for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
		{	// "Personyze Action 88.dat", "Personyze Action Data 88.dat", "Personyze Condition 7.dat", "Personyze Placeholder 635.dat"
			if name.hasPrefix("Personyze ") && name.hasSuffix(".dat")
			{	try? fm.removeItem(at: dir.appendingPathComponent(name))
			}
		}
	}
}

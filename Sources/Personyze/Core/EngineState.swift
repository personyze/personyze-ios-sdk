import Foundation

// The files the engine keeps. Unknown keys are ignored and missing ones take their defaults, so a
// newer SDK reads an older file; `v` changes only for an incompatible layout. Swift's synthesized
// decoding would fail on a missing key instead, hence the decoders written out below.

/// `state.json`.
struct PersistedState: Codable, Sendable, Equatable
{	var v = 1
	/// A SHA-256 prefix of the API key - never the key. Another key means another account.
	var apiKeyFp: String?
	/// The app's user id, or nil for the install's anonymous visitor.
	var userId: UserId?
	/// The newest session string, for the visitor in field 1.
	var session: String?
	/// Bumped by `startNewSession()`; a batch of a later epoch than `sentEpoch` opens a new session.
	var epoch = 0
	var sentEpoch = 0
	/// Server time minus device time, from the `Date` header: a device clock off by 90 minutes
	/// would otherwise open a new session on every request.
	var clockOffsetMs: Int64 = 0
	/// Session start times, newest first, the current one included - as the web tag keeps them.
	var pastSessions: [Int64] = []
	/// Action id -> sessions left not to show it ("don't show again").
	var blocked: [Int: Int] = [:]
	var cacheVersion = 0
	var result: PersistedResult?
	/// Action statuses reported since the last navigation: an action is reported executed once per page.
	var pageReports: [Int: [String]] = [:]
	var notifications = PersistedNotifications()
	/// Device time until which the account is treated as paused (HTTP 429).
	var throttledUntilMs: Int64 = 0
	var push = PersistedPush()

	init(apiKeyFp: String? = nil, userId: UserId? = nil)
	{	self.apiKeyFp = apiKeyFp
		self.userId = userId
	}

	init(from decoder: any Decoder) throws
	{	let c = try decoder.container(keyedBy: CodingKeys.self)
		v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
		apiKeyFp = try c.decodeIfPresent(String.self, forKey: .apiKeyFp)
		userId = try c.decodeIfPresent(UserId.self, forKey: .userId)
		session = try c.decodeIfPresent(String.self, forKey: .session)
		epoch = try c.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
		sentEpoch = try c.decodeIfPresent(Int.self, forKey: .sentEpoch) ?? 0
		clockOffsetMs = try c.decodeIfPresent(Int64.self, forKey: .clockOffsetMs) ?? 0
		pastSessions = try c.decodeIfPresent([Int64].self, forKey: .pastSessions) ?? []
		blocked = try c.decodeIfPresent([Int: Int].self, forKey: .blocked) ?? [:]
		cacheVersion = try c.decodeIfPresent(Int.self, forKey: .cacheVersion) ?? 0
		result = try c.decodeIfPresent(PersistedResult.self, forKey: .result)
		pageReports = try c.decodeIfPresent([Int: [String]].self, forKey: .pageReports) ?? [:]
		notifications = try c.decodeIfPresent(PersistedNotifications.self, forKey: .notifications) ?? PersistedNotifications()
		throttledUntilMs = try c.decodeIfPresent(Int64.self, forKey: .throttledUntilMs) ?? 0
		push = try c.decodeIfPresent(PersistedPush.self, forKey: .push) ?? PersistedPush()
	}
}

/// The device's push registration (SPEC section 11): the token the app passed on, and what
/// Personyze has of it.
struct PersistedPush: Codable, Sendable, Equatable
{	/// What Apple's push service gave this install; nil before the app passes one on.
	var token: String?
	/// "<visitor id> <token>" as last registered: registered again when either changes, or a week
	/// has passed. Nil when Personyze has no registration of this device.
	var registered: String?
	var registeredAtMs: Int64 = 0
	/// Whether Personyze pushes to this device - the account has a key for the platform (what the
	/// registration answered). Then the background checks are few.
	var active = false

	init()
	{
	}

	init(from decoder: any Decoder) throws
	{	let c = try decoder.container(keyedBy: CodingKeys.self)
		token = try c.decodeIfPresent(String.self, forKey: .token)
		registered = try c.decodeIfPresent(String.self, forKey: .registered)
		registeredAtMs = try c.decodeIfPresent(Int64.self, forKey: .registeredAtMs) ?? 0
		active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
	}
}

struct PersistedResult: Codable, Sendable, Equatable
{	var conditions: [Int] = []
	var actions: [PersistedAction] = []
	var dismissedConditions: [Int] = []
	var dismissedActions: [Int] = []
	var sessionId: String?
	var cacheVersion = 0
	var raw: String?

	init
	(	conditions: [Int],
		actions: [PersistedAction],
		dismissedConditions: [Int] = [],
		dismissedActions: [Int] = [],
		sessionId: String?,
		cacheVersion: Int,
		raw: String?
	)
	{	self.conditions = conditions
		self.actions = actions
		self.dismissedConditions = dismissedConditions
		self.dismissedActions = dismissedActions
		self.sessionId = sessionId
		self.cacheVersion = cacheVersion
		self.raw = raw
	}

	init(from decoder: any Decoder) throws
	{	let c = try decoder.container(keyedBy: CodingKeys.self)
		conditions = try c.decodeIfPresent([Int].self, forKey: .conditions) ?? []
		actions = try c.decodeIfPresent([PersistedAction].self, forKey: .actions) ?? []
		dismissedConditions = try c.decodeIfPresent([Int].self, forKey: .dismissedConditions) ?? []
		dismissedActions = try c.decodeIfPresent([Int].self, forKey: .dismissedActions) ?? []
		sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
		cacheVersion = try c.decodeIfPresent(Int.self, forKey: .cacheVersion) ?? 0
		raw = try c.decodeIfPresent(String.self, forKey: .raw)
	}
}

struct PersistedAction: Codable, Sendable, Equatable
{	var id: Int
	var data: [String: String]?
}

struct PersistedNotifications: Codable, Sendable, Equatable
{	var lastCheckMs: Int64 = 0
	/// The last message shown to each visitor id, oldest first. The server keeps one queued message
	/// per visitor and replaces it on each send, so a different id is always a new send. A list,
	/// not a dictionary: the oldest are the ones dropped.
	var delivered: [Delivered] = []
	/// After a 1.x upgrade the queued message was probably shown already: take the first one seen as
	/// delivered, silently.
	var primeOnNextPoll = false
	/// Report addresses (shown, tapped) not sent yet, oldest first.
	var reports: [String] = []

	struct Delivered: Codable, Sendable, Equatable
	{	var visitor: String
		var messageId: Int64
	}

	init(lastCheckMs: Int64 = 0, primeOnNextPoll: Bool = false)
	{	self.lastCheckMs = lastCheckMs
		self.primeOnNextPoll = primeOnNextPoll
	}

	init(from decoder: any Decoder) throws
	{	let c = try decoder.container(keyedBy: CodingKeys.self)
		lastCheckMs = try c.decodeIfPresent(Int64.self, forKey: .lastCheckMs) ?? 0
		delivered = try c.decodeIfPresent([Delivered].self, forKey: .delivered) ?? []
		primeOnNextPoll = try c.decodeIfPresent(Bool.self, forKey: .primeOnNextPoll) ?? false
		reports = try c.decodeIfPresent([String].self, forKey: .reports) ?? []
	}
}

/// A queued command and what it was queued under.
struct PendingItem: Codable, Sendable, Equatable
{	var cmd: Command
	/// The `user_id` it is about.
	var user: UserId
	var epoch: Int
	/// Start of the session it was queued in (0 for none): an action report goes only into that session.
	var sessionStart: Int64
	var queuedAtMs: Int64
	/// From `track()`: sent in a request of its own.
	var raw = false
	/// Written to disk before the request goes out; found set at startup, it may have been sent.
	var inflight = false
	/// A navigation is never kept for later - a page view sent hours late is a wrong page view.
	var navigate = false
	var seq: Int64 = 0

	init
	(	cmd: Command,
		user: UserId,
		epoch: Int,
		sessionStart: Int64,
		queuedAtMs: Int64,
		raw: Bool = false,
		inflight: Bool = false,
		navigate: Bool = false,
		seq: Int64 = 0
	)
	{	self.cmd = cmd
		self.user = user
		self.epoch = epoch
		self.sessionStart = sessionStart
		self.queuedAtMs = queuedAtMs
		self.raw = raw
		self.inflight = inflight
		self.navigate = navigate
		self.seq = seq
	}

	init(from decoder: any Decoder) throws
	{	let c = try decoder.container(keyedBy: CodingKeys.self)
		cmd = try c.decode(Command.self, forKey: .cmd)
		user = try c.decode(UserId.self, forKey: .user)
		epoch = try c.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
		sessionStart = try c.decodeIfPresent(Int64.self, forKey: .sessionStart) ?? 0
		queuedAtMs = try c.decodeIfPresent(Int64.self, forKey: .queuedAtMs) ?? 0
		raw = try c.decodeIfPresent(Bool.self, forKey: .raw) ?? false
		inflight = try c.decodeIfPresent(Bool.self, forKey: .inflight) ?? false
		navigate = try c.decodeIfPresent(Bool.self, forKey: .navigate) ?? false
		seq = try c.decodeIfPresent(Int64.self, forKey: .seq) ?? 0
	}
}

/// `outbox.json`.
struct OutboxFile: Codable, Sendable
{	var v = 1
	var items: [PendingItem] = []

	init(items: [PendingItem])
	{	self.items = items
	}

	init(from decoder: any Decoder) throws
	{	let c = try decoder.container(keyedBy: CodingKeys.self)
		v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
		items = try c.decodeIfPresent([PendingItem].self, forKey: .items) ?? []
	}
}

/// `metadata.json`: the per-account templates, cached by `cache_version`. Rows are kept raw so a
/// column this version does not read survives.
struct MetadataFile: Codable, Sendable
{	var v = 1
	var apiKeyFp: String?
	var cacheVersion = 0
	var conditions: [Int: [String: JSON]] = [:]
	var actions: [Int: [String: JSON]] = [:]
	var placeholders: [Int: [String: JSON]] = [:]
	/// Ids asked for and not returned, for this cache version: not asked again.
	var missing: [String] = []
	/// False once the server refused `placeholder_order`.
	var placeholderOrder = true

	init(apiKeyFp: String?, cacheVersion: Int = 0)
	{	self.apiKeyFp = apiKeyFp
		self.cacheVersion = cacheVersion
	}

	init(from decoder: any Decoder) throws
	{	let c = try decoder.container(keyedBy: CodingKeys.self)
		v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
		apiKeyFp = try c.decodeIfPresent(String.self, forKey: .apiKeyFp)
		cacheVersion = try c.decodeIfPresent(Int.self, forKey: .cacheVersion) ?? 0
		conditions = try c.decodeIfPresent([Int: [String: JSON]].self, forKey: .conditions) ?? [:]
		actions = try c.decodeIfPresent([Int: [String: JSON]].self, forKey: .actions) ?? [:]
		placeholders = try c.decodeIfPresent([Int: [String: JSON]].self, forKey: .placeholders) ?? [:]
		missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
		placeholderOrder = try c.decodeIfPresent(Bool.self, forKey: .placeholderOrder) ?? true
	}
}

/// A user id on disk is the JSON it goes out as: a number or a string.
extension UserId: Codable
{	init(from decoder: any Decoder) throws
	{	let c = try decoder.singleValueContainer()
		if let n = try? c.decode(Int64.self)
		{	self = .number(n)
		}
		else
		{	self = .text(try c.decode(String.self))
		}
	}

	func encode(to encoder: any Encoder) throws
	{	var c = encoder.singleValueContainer()
		switch self
		{	case .number(let n):
				try c.encode(n)
			case .text(let s):
				try c.encode(s)
		}
	}
}

extension JSON: Encodable
{	func encode(to encoder: any Encoder) throws
	{	var c = encoder.singleValueContainer()
		switch self
		{	case .null:
				try c.encodeNil()
			case .bool(let b):
				try c.encode(b)
			case .int(let n):
				try c.encode(n)
			case .double(let d):
				if d.isFinite
				{	try c.encode(d)
				}
				else
				{	try c.encodeNil()
				}
			case .string(let s):
				try c.encode(s)
			case .array(let items):
				try c.encode(items)
			case .object(let fields):
				try c.encode(fields)
		}
	}
}

/// Reading and writing the files above. A file that does not decode reads as nil.
enum StateCoding
{	static func encode<T: Encodable>(_ value: T) -> String?
	{	let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
	}

	static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T?
	{	try? JSONDecoder().decode(type, from: Data(text.utf8))
	}
}

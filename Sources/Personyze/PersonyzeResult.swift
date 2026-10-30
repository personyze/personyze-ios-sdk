import Foundation

/// What Personyze decided for the visitor: the campaigns (conditions) they match and the actions
/// to present now.
///
/// A decision belongs to one screen. A navigation replaces it; events and reports sent without a
/// navigation add to it and remove what Personyze dismissed. A failed navigation answers an empty
/// result with `error` set - the app renders its default, as it would for a visitor Personyze has
/// nothing for.
public struct PersonyzeResult: Sendable, Equatable
{	/// The actions to present, in the order Personyze sent them.
	public let actions: [PersonyzeAction]
	/// The campaigns the visitor matches. Rarely needed: only for app logic of your own.
	public let conditions: [PersonyzeCondition]
	/// Actions Personyze withdrew in the last response that was not a navigation.
	public let dismissedActions: [Int]
	/// Campaigns the visitor stopped matching in the last response that was not a navigation.
	public let dismissedConditions: [Int]
	/// The session string this result was decided in.
	public let sessionId: String?
	/// The account's `cache_version` when this was decided.
	public let cacheVersion: Int
	/// The last tracker response verbatim, for anything this type does not model.
	public let rawJson: String?
	/// Why this result is empty, when it is empty because something failed.
	public let error: PersonyzeError?

	/// No decision.
	public static let empty = PersonyzeResult(
		actions: [],
		conditions: [],
		dismissedActions: [],
		dismissedConditions: [],
		sessionId: nil,
		cacheVersion: 0,
		rawJson: nil,
		error: nil
	)

	static func failed(_ error: PersonyzeError) -> PersonyzeResult
	{	empty.with(error: error)
	}

	func with(error: PersonyzeError?) -> PersonyzeResult
	{	PersonyzeResult(
			actions: actions,
			conditions: conditions,
			dismissedActions: dismissedActions,
			dismissedConditions: dismissedConditions,
			sessionId: sessionId,
			cacheVersion: cacheVersion,
			rawJson: rawJson,
			error: error
		)
	}

	/// Whether Personyze decided this action. What a server-side A/B test is written against:
	/// `if result.has(88) { showVariantB() } else { showDefault() }`.
	public func has(_ actionId: Int) -> Bool
	{	actions.contains { $0.id == actionId }
	}

	public func action(_ actionId: Int) -> PersonyzeAction?
	{	actions.first { $0.id == actionId }
	}

	/// The action's per-visitor data (the values its content is built from), or nil if not decided.
	public func data(for actionId: Int) -> [String: String]?
	{	action(actionId)?.data
	}

	/// The first of these action ids that was decided, or nil - for picking the arm of a test.
	public func first(of actionIds: Int...) -> Int?
	{	actionIds.first { has($0) }
	}

	/// The actions targeted to this placeholder, as the web tag would fill it: by
	/// `placeholder_order` (none counts as 999), then by id, at most `units_count_max` of them.
	/// `placeholder` is the placeholder's name or its HTML id, as set in the panel.
	public func actions(in placeholder: String) -> [PersonyzeAction]
	{	actions { $0.name == placeholder || $0.htmlId == placeholder }
	}

	public func actions(inPlaceholder placeholderId: Int) -> [PersonyzeAction]
	{	actions { $0.id == placeholderId }
	}

	private func actions(where match: (PersonyzePlaceholder) -> Bool) -> [PersonyzeAction]
	{	var capacity = 0
		let list = actions.filter { action in
			guard let placeholder = action.placeholders.first(where: match) else
			{	return false
			}
			if capacity == 0
			{	capacity = placeholder.unitsCountMax
			}
			return true
		}
		.sorted { ($0.placeholderOrder ?? 999, $0.id) < ($1.placeholderOrder ?? 999, $1.id) }
		return capacity > 0 ? Array(list.prefix(capacity)) : list
	}

	/// No actions and no conditions.
	public var isEmpty: Bool
	{	actions.isEmpty && conditions.isEmpty
	}

	/// Empty because the request failed, not because Personyze had nothing.
	public var failed: Bool
	{	error != nil
	}
}

/// An action Personyze decided to present - usually HTML (a banner, a recommendation widget),
/// sometimes JSON or text you render yourself.
///
/// The content comes in two parts: the per-visitor `data` arrives with the decision, the template
/// around it is fetched once per account version and cached. Until it arrives `isLoaded` is false
/// and `content` is nil; the decision itself (`PersonyzeResult.has`) is already valid.
public struct PersonyzeAction: Sendable, Equatable, Identifiable
{	public let id: Int
	/// The values Personyze computed for this visitor (product lists, texts).
	public let data: [String: String]
	/// The action's name in the panel, once loaded.
	public let name: String?
	/// MIME type: `text/html` for banners and recommendation widgets, `application/json` for a
	/// JSON feed, or whatever the action type produces.
	public let contentType: String?
	/// The placeholders the action is targeted to, as set in the panel.
	public let placeholders: [PersonyzePlaceholder]
	/// Order among the actions sharing a placeholder; nil means last (999).
	public let placeholderOrder: Int?
	/// Helper scripts the HTML needs in a web view (`libs_app`).
	public let libs: [String]
	let contentParam: String
	let contentBegin: String
	let contentEnd: String
	let cacheVersion: Int
	/// Whether the template has arrived.
	public let isLoaded: Bool
	/// The client that decided this action; where its report shortcuts go.
	weak var owner: (any ActionReporter)?
	var assetsUrl: String

	/// An action whose template has not arrived.
	init(id: Int, data: [String: String], cacheVersion: Int, assetsUrl: String)
	{	self.init(
			id: id,
			data: data,
			name: nil,
			contentType: nil,
			placeholders: [],
			placeholderOrder: nil,
			libs: [],
			contentParam: "",
			contentBegin: "",
			contentEnd: "",
			cacheVersion: cacheVersion,
			isLoaded: false,
			assetsUrl: assetsUrl
		)
	}

	init
	(	id: Int,
		data: [String: String],
		name: String?,
		contentType: String?,
		placeholders: [PersonyzePlaceholder],
		placeholderOrder: Int?,
		libs: [String],
		contentParam: String,
		contentBegin: String,
		contentEnd: String,
		cacheVersion: Int,
		isLoaded: Bool,
		assetsUrl: String
	)
	{	self.id = id
		self.data = data
		self.name = name
		self.contentType = contentType
		self.placeholders = placeholders
		self.placeholderOrder = placeholderOrder
		self.libs = libs
		self.contentParam = contentParam
		self.contentBegin = contentBegin
		self.contentEnd = contentEnd
		self.cacheVersion = cacheVersion
		self.isLoaded = isLoaded
		self.assetsUrl = assetsUrl
	}

	/// The raw content: `content_begin + data[content_param] + content_end`, with `${action_id}`
	/// replaced - the formula the web tag uses. Nil until `isLoaded`.
	public var content: String?
	{	guard isLoaded else
		{	return nil
		}
		let middle = contentParam.isEmpty ? "" : data[contentParam] ?? ""
		return (contentBegin + middle + contentEnd).replacingOccurrences(of: "${action_id}", with: String(id))
	}

	public var isHtml: Bool
	{	contentType == "text/html"
	}

	public var isJson: Bool
	{	contentType == "application/json"
	}

	/// For a JSON action whose content is an array of objects (a product feed): the rows, every
	/// value as text. Nil for anything else.
	public func contentJsonArray() -> [[String: String]]?
	{	guard isJson, let content, let rows = JSON.parse(content)?.arrayValue else
		{	return nil
		}
		return rows.compactMap { $0.objectValue }.map { row in
			row.mapValues { value in
				switch value
				{	case .null:
						return "null"
					case .string(let s):
						return s
					default:
						return value.serialized
				}
			}
		}
	}

	/// For an HTML action: a complete page that runs it in a web view - Personyze's web view
	/// library, the helper scripts, the content, and the click handling that reports to
	/// `personyze_message_handler`. Nil for other content types or before `isLoaded`.
	public func contentHtmlDocument() -> String?
	{	HtmlDocument.build(self, assetsUrl: assetsUrl, extraHead: "")
	}

	/// Report that this action was shown (`executed`).
	public func reportExecuted()
	{	reporter?.reportExecuted(id)
	}

	/// Report a click on the action's call to action (`target`) - what the Clicks criterion of an
	/// A/B test counts, and only that.
	public func reportEngaged()
	{	reporter?.reportEngaged(id)
	}

	/// Report that the visitor closed the action; with `dontShowForSessions` > 0 it is not
	/// presented again for that many sessions.
	public func reportClosed(dontShowForSessions: Int = 0)
	{	reporter?.reportClosed(id, dontShowForSessions: dontShowForSessions)
	}

	public func reportProductClicked(_ productId: String)
	{	reporter?.reportProductClicked(id, productId: productId)
	}

	public func reportArticleClicked(_ articleId: String)
	{	reporter?.reportArticleClicked(id, articleId: articleId)
	}

	/// Report that the action could not be presented; the message appears in Live visits.
	public func reportError(_ message: String)
	{	reporter?.reportError(id, message: message)
	}

	/// The client that decided it, else the one `Personyze.initialize` created.
	private var reporter: (any ActionReporter)?
	{	owner ?? Personyze.client
	}

	public static func == (a: PersonyzeAction, b: PersonyzeAction) -> Bool
	{	a.id == b.id && a.data == b.data && a.isLoaded == b.isLoaded && a.cacheVersion == b.cacheVersion &&
			a.contentType == b.contentType && a.contentParam == b.contentParam && a.contentBegin == b.contentBegin &&
			a.contentEnd == b.contentEnd && a.name == b.name && a.placeholders == b.placeholders &&
			a.placeholderOrder == b.placeholderOrder && a.libs == b.libs
	}
}

/// Where an action's report shortcuts go: the client that decided it.
protocol ActionReporter: AnyObject, Sendable
{	func reportExecuted(_ actionId: Int)
	func reportEngaged(_ actionId: Int)
	func reportClosed(_ actionId: Int, dontShowForSessions: Int)
	func reportProductClicked(_ actionId: Int, productId: String)
	func reportArticleClicked(_ actionId: Int, articleId: String)
	func reportError(_ actionId: Int, message: String)
}

/// A campaign the visitor matches.
public struct PersonyzeCondition: Sendable, Equatable, Identifiable
{	public let id: Int
	/// The campaign's name in the panel, once loaded.
	public let name: String?
}

/// A placeholder an action is targeted to: in an app, a named slot of your own.
public struct PersonyzePlaceholder: Sendable, Equatable, Identifiable
{	public let id: Int
	public let name: String
	/// The placeholder's HTML id or selector as set in the panel.
	public let htmlId: String
	/// How many actions it holds; 0 means no limit.
	public let unitsCountMax: Int
}

/// Who Personyze is talking about right now.
public struct PersonyzeVisitor: Sendable, Equatable
{	/// The id the app set, or nil for the anonymous install visitor.
	public let userId: String?
	/// The 32-bit visitor id Personyze files this visitor under - your numeric id, or the CRC-32
	/// of a text one, or the install's own anonymous id.
	public let visitorId: Int?
	/// The current session string, or nil before the first request.
	public let sessionId: String?
}

import Foundation

/// Something the visitor tapped inside a rendered action, as Personyze's web view library reports
/// it (`{href, clicked, arg}` through `personyze_message_handler`).
public struct PersonyzeClick: Sendable, Equatable
{	public enum Kind: Sendable, Equatable
	{	/// The call to action (`target`) - a link, or the action itself when it marks no targets.
		case target
		/// A close or "don't show again" button.
		case close
		/// A product in a recommendation widget.
		case product
		/// An article in a recommendation widget.
		case article
	}

	public let actionId: Int
	public let kind: Kind
	/// The link's address when a link was tapped, else empty.
	public let href: String
	/// For `.product` and `.article` the item's Internal ID; for `.close` the number of sessions
	/// not to show the action again.
	public let arg: String

	/// For `.close`: sessions not to show the action again (0 = just close it).
	public var dontShowForSessions: Int
	{	kind == .close ? max(Int(arg.trimmingCharacters(in: .whitespaces)) ?? 0, 0) : 0
	}

	public var productId: String?
	{	kind == .product ? arg : nil
	}

	public var articleId: String?
	{	kind == .article ? arg : nil
	}

	/// The wire's `clicked` value as a kind, or nil for one this version does not know.
	static func kind(of clicked: String) -> Kind?
	{	switch clicked
		{	case "target":
				return .target
			case "close":
				return .close
			case "product":
				return .product
			case "article":
				return .article
			default:
				return nil
		}
	}
}

import Foundation

/// One tracker command: `["Product Viewed", "A1000"]`. Strings, as the 1.x SDKs sent them; the
/// server coerces (`Number(command[1])`), and the guide documents both forms. A profile value may
/// be nil.
typealias Command = [String?]

/// Builds commands with the names and casing the 1.x SDKs used (the server matches them
/// case-insensitively), and refuses what the server would refuse - one bad command answers 400 for
/// the whole request, taking every other event in it along.
enum Commands
{	static let navigateName = "Navigate"
	static let actionStatusName = "Action Status"
	static let userProfileName = "User profile"

	/// A request body may not exceed this (the 1.x limit, `POST_LIMIT`); one command must leave
	/// room for the rest of the body.
	static let maxBody = 50_000
	static let maxCommand = 45_000

	static let statuses: Set<String> = ["executed", "target", "close", "product", "article", "dont-show", "rules-mismatch", "error"]

	static func navigate(_ document: String) throws(PersonyzeError) -> Command
	{	try require(!isBlank(document), "Personyze: navigate() needs a document name")
		return [navigateName, Endpoints.documentUrn(document)]
	}

	/// One command of field/value pairs, in the order given.
	static func profile(_ fields: [(String, String?)]) throws(PersonyzeError) -> Command
	{	try require(!fields.isEmpty, "Personyze: setProfile() needs at least one field")
		var cmd: Command = [userProfileName]
		for (field, value) in fields
		{	try require(!isBlank(field), "Personyze: a profile field name is empty")
			cmd.append(field)
			cmd.append(value)
		}
		return try checked(cmd)
	}

	/// `["Product Viewed", id, "action_id", n, "quantity", n]`; the pairs only when given.
	static func product(_ name: String, _ productId: String, actionId: Int?, quantity: Int?) throws(PersonyzeError) -> Command
	{	try require(!isBlank(productId), "Personyze: \(name) needs a product id (No Product ID specified)")
		var cmd: Command = [name, productId]
		if let actionId
		{	try require(actionId > 0, "Personyze: \(name): action_id must be positive")
			cmd.append("action_id")
			cmd.append(String(actionId))
		}
		if let quantity
		{	try require(quantity > 0, "Personyze: \(name): quantity must be positive")
			cmd.append("quantity")
			cmd.append(String(quantity))
		}
		return try checked(cmd)
	}

	static func article(_ name: String, _ articleId: String, actionId: Int?) throws(PersonyzeError) -> Command
	{	try require(!isBlank(articleId), "Personyze: \(name) needs an article id (No Article ID specified)")
		var cmd: Command = [name, articleId]
		if let actionId
		{	try require(actionId > 0, "Personyze: \(name): action_id must be positive")
			cmd.append("action_id")
			cmd.append(String(actionId))
		}
		return try checked(cmd)
	}

	/// The server requires both (`No Promotion ID specified`, `No action_id specified`).
	static func promotion(_ name: String, _ promotionId: String, actionId: Int) throws(PersonyzeError) -> Command
	{	try require(!isBlank(promotionId), "Personyze: \(name) needs a promotion id")
		try require(actionId > 0, "Personyze: \(name) needs the promotion action's id")
		return try checked([name, promotionId.trimmingCharacters(in: .whitespacesAndNewlines), "action_id", String(actionId)])
	}

	static func coupon(_ code: String) throws(PersonyzeError) -> Command
	{	try require(!isBlank(code), "Personyze: couponUsed() needs a code")
		return try checked(["coupon used", code.trimmingCharacters(in: .whitespacesAndNewlines)])
	}

	static func bare(_ name: String) -> Command
	{	[name]
	}

	/// `["Action Status", "<id>", status, arg]`, four elements as the 1.x SDKs sent them.
	static func actionStatus(_ actionId: Int, _ status: String, _ arg: String = "") throws(PersonyzeError) -> Command
	{	try require(actionId > 0, "Personyze: invalid action id \(actionId)")
		try require(statuses.contains(status), "Personyze: unknown action status '\(status)'")
		return try checked([actionStatusName, String(actionId), status, arg])
	}

	static func raw(_ command: [String]) throws(PersonyzeError) -> Command
	{	try require(!command.isEmpty && !isBlank(command[0]), "Personyze: track() needs a command name")
		return try checked(command)
	}

	static func isNavigate(_ cmd: Command) -> Bool
	{	cmd.count >= 2 && cmd[0]?.lowercased() == navigateName.lowercased()
	}

	static func isActionStatus(_ cmd: Command) -> Bool
	{	cmd.count >= 3 && cmd[0]?.lowercased() == actionStatusName.lowercased()
	}

	/// The length of a command as it will appear in the body, in UTF-8 bytes (close enough to pack
	/// batches).
	static func jsonLength(_ cmd: Command) -> Int
	{	var n = 2
		for arg in cmd
		{	guard let arg else
			{	n += 7
				continue
			}
			n += arg.utf8.count + 3
			for c in arg.utf8 where c == 0x22 || c == 0x5C || c < 0x20
			{	n += 5
			}
		}
		return n
	}

	private static func checked(_ cmd: Command) throws(PersonyzeError) -> Command
	{	try require(jsonLength(cmd) <= maxCommand, "Personyze: a \(cmd[0] ?? "") command over \(maxCommand) characters cannot be sent")
		return cmd
	}

	private static func isBlank(_ s: String) -> Bool
	{	s.allSatisfy(\.isWhitespace)
	}

	private static func require(_ ok: Bool, _ message: @autoclosure () -> String) throws(PersonyzeError)
	{	if !ok
		{	throw .invalid(message: message())
		}
	}
}

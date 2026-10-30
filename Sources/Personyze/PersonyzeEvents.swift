import Foundation

/// What the visitor did. Each call queues one command; the queue goes out with the next
/// navigation, or by itself a few seconds later, or when the app goes to the background. None of
/// these block or touch the network, and all are safe from any thread.
///
/// A blank id, or a promotion without its action id, is not sent: the call is ignored and the
/// error handler gets `PersonyzeError.invalid`. Personyze would refuse it (`No Product ID
/// specified`), and with it every other event in the same request.
///
/// The same calls are on `Personyze` and `PersonyzeClient`; this type is what a navigation's
/// events closure gets.
public struct PersonyzeEvents: Sendable
{	let engine: Engine

	/// Profile data about the visitor - `email`, `first_name`, or any field of your own - for
	/// targeting, content and email campaigns.
	public func setProfile(_ field: String, _ value: String?)
	{	engine.enqueue { try Commands.profile([(field, value)]) }
	}

	/// Several profile fields in one command.
	public func setProfile(_ fields: [String: String?])
	{	engine.enqueue { try Commands.profile(fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }) }
	}

	/// The visitor viewed a product. `productId` is the "Internal ID" in your products catalog.
	/// `actionId` attributes it to the action that showed it (recommendation contribution).
	public func productViewed(_ productId: String, actionId: Int? = nil)
	{	engine.enqueue { try Commands.product("Product Viewed", productId, actionId: actionId, quantity: nil) }
	}

	public func productAddedToCart(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	engine.enqueue { try Commands.product("Product Added to cart", productId, actionId: actionId, quantity: quantity) }
	}

	/// Added to a wishlist or favorites.
	public func productLiked(_ productId: String, actionId: Int? = nil)
	{	engine.enqueue { try Commands.product("Product Liked", productId, actionId: actionId, quantity: nil) }
	}

	/// A purchase. With `actionId` it counts for the "Products purchased" criterion of the action's
	/// A/B test (SPEC section 6) - without it a purchase-judged test sees nothing.
	public func productPurchased(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	engine.enqueue { try Commands.product("Product Purchased", productId, actionId: actionId, quantity: quantity) }
	}

	/// Removed from the wishlist. No effect for a product not reported liked.
	public func productUnliked(_ productId: String, actionId: Int? = nil)
	{	engine.enqueue { try Commands.product("Product Unliked", productId, actionId: actionId, quantity: nil) }
	}

	/// No effect for a product not reported added to cart.
	public func productRemovedFromCart(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	engine.enqueue { try Commands.product("Product Removed from cart", productId, actionId: actionId, quantity: quantity) }
	}

	/// Everything reported added to cart was purchased.
	public func productsPurchased()
	{	engine.enqueue { Commands.bare("Products Purchased") }
	}

	/// The wishlist was emptied.
	public func productsUnliked()
	{	engine.enqueue { Commands.bare("Products Unliked") }
	}

	/// The cart was emptied.
	public func productsRemovedFromCart()
	{	engine.enqueue { Commands.bare("Products Removed from cart") }
	}

	/// `articleId` is the "Internal ID" in your articles catalog.
	public func articleViewed(_ articleId: String, actionId: Int? = nil)
	{	engine.enqueue { try Commands.article("Article Viewed", articleId, actionId: actionId) }
	}

	public func articleLiked(_ articleId: String, actionId: Int? = nil)
	{	engine.enqueue { try Commands.article("Article Liked", articleId, actionId: actionId) }
	}

	public func articleCommented(_ articleId: String, actionId: Int? = nil)
	{	engine.enqueue { try Commands.article("Article Commented", articleId, actionId: actionId) }
	}

	public func articleUnliked(_ articleId: String, actionId: Int? = nil)
	{	engine.enqueue { try Commands.article("Article Unliked", articleId, actionId: actionId) }
	}

	/// The visitor reached the article's goal.
	public func articleGoal(_ articleId: String, actionId: Int? = nil)
	{	engine.enqueue { try Commands.article("Article Goal", articleId, actionId: actionId) }
	}

	public func articlesUnliked()
	{	engine.enqueue { Commands.bare("Articles Unliked") }
	}

	/// A promotion card of a promotions action came into view. `promotionId` is the card's
	/// `data-personyze-click-target="promotions <id>"`; `actionId` is required.
	public func promotionViewed(_ promotionId: String, actionId: Int)
	{	engine.enqueue { try Commands.promotion("promotion viewed", promotionId, actionId: actionId) }
	}

	public func promotionClicked(_ promotionId: String, actionId: Int)
	{	engine.enqueue { try Commands.promotion("promotion clicked", promotionId, actionId: actionId) }
	}

	/// The visitor revealed the promotion's coupon code.
	public func codeRevealed(_ promotionId: String, actionId: Int)
	{	engine.enqueue { try Commands.promotion("code revealed", promotionId, actionId: actionId) }
	}

	/// A coupon code was redeemed in the app.
	public func couponUsed(_ code: String)
	{	engine.enqueue { try Commands.coupon(code) }
	}

	/// Any tracker command, sent as given - for what the typed calls do not cover. Sent in a
	/// request of its own, so a command Personyze refuses cannot take other events with it. An
	/// empty command is ignored.
	public func track(_ command: [String])
	{	if !command.isEmpty
		{	engine.enqueue(raw: true) { try Commands.raw(command) }
		}
	}

	/// The action was shown (`executed`). An action never reported executed looks like it never
	/// ran, and its A/B arm like it had no traffic.
	public func reportExecuted(_ actionId: Int)
	{	engine.enqueue { try Commands.actionStatus(actionId, "executed") }
	}

	/// The visitor tapped the action's call to action (`target`) - the Clicks criterion of an A/B
	/// test, and only that. A purchase is `productPurchased` with the action id.
	public func reportEngaged(_ actionId: Int)
	{	engine.enqueue { try Commands.actionStatus(actionId, "target") }
	}

	/// The visitor closed the action; with `dontShowForSessions` > 0 it is not presented again for
	/// that many sessions.
	public func reportClosed(_ actionId: Int, dontShowForSessions: Int = 0)
	{	engine.enqueue { try Commands.actionStatus(actionId, "close", String(max(dontShowForSessions, 0))) }
	}

	public func reportProductClicked(_ actionId: Int, productId: String)
	{	engine.enqueue {
			try PersonyzeEvents.requireId(productId, "Personyze: reportProductClicked() needs a product id")
			return try Commands.actionStatus(actionId, "product", productId)
		}
	}

	public func reportArticleClicked(_ actionId: Int, articleId: String)
	{	engine.enqueue {
			try PersonyzeEvents.requireId(articleId, "Personyze: reportArticleClicked() needs an article id")
			return try Commands.actionStatus(actionId, "article", articleId)
		}
	}

	/// The action could not be presented. The message shows in Live visits.
	public func reportError(_ actionId: Int, message: String)
	{	engine.enqueue { try Commands.actionStatus(actionId, "error", message) }
	}

	/// A tap inside an action, from a renderer of your own.
	public func report(_ click: PersonyzeClick)
	{	switch click.kind
		{	case .target:
				reportEngaged(click.actionId)
			case .close:
				reportClosed(click.actionId, dontShowForSessions: click.dontShowForSessions)
			case .product:
				reportProductClicked(click.actionId, productId: click.arg)
			case .article:
				reportArticleClicked(click.actionId, articleId: click.arg)
		}
	}

	private static func requireId(_ id: String, _ message: String) throws
	{	if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		{	throw PersonyzeError.invalid(message: message)
		}
	}
}

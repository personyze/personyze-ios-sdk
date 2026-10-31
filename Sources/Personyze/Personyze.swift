import Foundation

/// The SDK's entry point. Initialize once, where the app starts:
///
/// ```swift
/// @main
/// struct ShopApp: App
/// {	init()
/// 	{	Personyze.initialize(PersonyzeConfig(apiKey: "YOUR_API_KEY"))
/// 	}
/// 	...
/// }
/// ```
///
/// then, on each screen:
///
/// ```swift
/// let result = await Personyze.navigate("ProductScreen") { $0.productViewed("A1000") }
/// ```
///
/// Every member forwards to the client `initialize` created. Called before `initialize`, the
/// event and report calls are ignored (and logged), and the async ones answer an empty result.
public enum Personyze
{	/// This SDK's version, sent in the `User-Agent`.
	public static let sdkVersion = "2.0.0"

	private static let current = Locked<PersonyzeClient?>(nil)
	private static let emptyResult = StateCell(PersonyzeResult.empty)
	private static let emptyVisitor = StateCell(PersonyzeVisitor(userId: nil, visitorId: nil, sessionId: nil))

	/// Create the client, or answer the existing one when `config` is the same. Another config
	/// (another key, say) replaces it. Never touches the disk on this thread.
	///
	/// An invalid config - an empty key, a base URL that is not https - stops the app here: it is
	/// a mistake in the app's code, and shows on its first run.
	@discardableResult
	public static func initialize(_ config: PersonyzeConfig) -> PersonyzeClient
	{	initialize(config, environment: nil)
	}

	@discardableResult
	static func initialize(_ config: PersonyzeConfig, environment: ((Locked<Bool>) -> ClientEnvironment)?) -> PersonyzeClient
	{	if let problem = config.problem
		{	preconditionFailure(problem)
		}
		#if os(iOS)
		// Here, as the app starts: iOS takes background task handlers only before launch ends.
		BackgroundRefresh.registerIfDeclared()
		onMain
		{	AppLifecycle.install()
		}
		#endif
		return current.withLock
		{	client in
			if let existing = client
			{	if existing.config.sameAs(config)
				{	existing.setErrorListener(config.onError)
					return existing
				}
				existing.close()
			}
			let created = PersonyzeClient(config: config, environment: environment)
			client = created
			return created
		}
	}

	/// The client `initialize` created, or nil before it.
	public static var client: PersonyzeClient?
	{	current.value
	}

	public static var isInitialized: Bool
	{	client != nil
	}

	/// Tests only: forget the client.
	static func shutdown()
	{	current.withLock
		{	client in
			client?.close()
			client = nil
		}
	}

	private static func events(_ call: String, _ body: (PersonyzeClient) -> Void)
	{	if let client
		{	body(client)
		}
		else
		{	Log.write("Personyze.\(call) ignored: Personyze.initialize() has not been called")
		}
	}

	private static var notInitialized: PersonyzeResult
	{	.failed(.invalid(message: "Personyze.initialize() has not been called"))
	}

	// MARK: - decisions

	/// The current decision; updated by every response and restored when the app starts.
	public static var result: PersonyzeResult
	{	client?.result ?? .empty
	}

	/// The current decision, then each change. Subscribe after `initialize`: before it this is
	/// the empty decision and nothing after.
	public static var results: AsyncStream<PersonyzeResult>
	{	client?.results ?? emptyResult.stream()
	}

	/// The current visitor and session.
	public static var visitor: PersonyzeVisitor
	{	client?.visitor ?? emptyVisitor.value
	}

	/// The current visitor, then each change. Subscribe after `initialize`.
	public static var visitors: AsyncStream<PersonyzeVisitor>
	{	client?.visitors ?? emptyVisitor.stream()
	}

	/// The visitor opened a screen ("document"): log it and get what to present there, in one
	/// round trip. `events` run first, on the caller's own actor, and go in the same request,
	/// attributed to this screen:
	///
	/// ```swift
	/// let result = await Personyze.navigate("Product") { $0.productViewed("A1000") }
	/// ```
	///
	/// Never throws for a network or server problem: the answer is then empty with `error` set -
	/// render your default, as for a visitor Personyze has nothing for. Call it once per screen
	/// entry, not on every view update: each call is a page view.
	@discardableResult
	nonisolated(nonsending) public static func navigate(_ document: String, events: ((PersonyzeEvents) -> Void)? = nil) async -> PersonyzeResult
	{	guard let client else
		{	return notInitialized
		}
		return await client.navigate(document, events: events)
	}

	/// Send what is queued and answer the current decision, merged with what the response
	/// changed. With nothing queued it answers the current decision without a request.
	@discardableResult
	public static func refresh() async -> PersonyzeResult
	{	await client?.refresh() ?? notInitialized
	}

	/// Send what is queued now instead of waiting for the automatic send.
	public static func flush() async
	{	await client?.flush()
	}

	// MARK: - visitor

	/// Identify the visitor with your own user id (after login). Personyze files them under it from
	/// the next request on; the anonymous visitor's session is not carried over (SPEC section 3).
	/// Nil logs out, back to this install's anonymous visitor.
	public static func setUserId(_ userId: String?)
	{	events("setUserId") { $0.setUserId(userId) }
	}

	/// A numeric user id.
	public static func setUserId(_ userId: Int)
	{	events("setUserId") { $0.setUserId(userId) }
	}

	/// Start a new Personyze session on the next request. A session otherwise ends 90 minutes
	/// after it started.
	public static func startNewSession()
	{	events("startNewSession") { $0.startNewSession() }
	}

	/// Forget the cached action and campaign templates and load them again. Normally never needed.
	public static func clearCache() async
	{	await client?.clearCache()
	}

	/// A new anonymous visitor, and everything stored for the old one deleted: session, queued
	/// events, decision, history. For a privacy request or a test.
	public static func reset() async
	{	await client?.reset()
	}

	// MARK: - events

	/// Profile data about the visitor - `email`, `first_name`, or any field of your own - for
	/// targeting, content and email campaigns.
	public static func setProfile(_ field: String, _ value: String?)
	{	events("setProfile") { $0.setProfile(field, value) }
	}

	/// Several profile fields in one command.
	public static func setProfile(_ fields: [String: String?])
	{	events("setProfile") { $0.setProfile(fields) }
	}

	/// The visitor viewed a product. `productId` is the "Internal ID" in your products catalog.
	/// `actionId` attributes it to the action that showed it (recommendation contribution).
	public static func productViewed(_ productId: String, actionId: Int? = nil)
	{	events("productViewed") { $0.productViewed(productId, actionId: actionId) }
	}

	public static func productAddedToCart(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	events("productAddedToCart") { $0.productAddedToCart(productId, actionId: actionId, quantity: quantity) }
	}

	/// Added to a wishlist or favorites.
	public static func productLiked(_ productId: String, actionId: Int? = nil)
	{	events("productLiked") { $0.productLiked(productId, actionId: actionId) }
	}

	/// A purchase. With `actionId` it counts for the "Products purchased" criterion of the action's
	/// A/B test - without it a purchase-judged test sees nothing.
	public static func productPurchased(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	events("productPurchased") { $0.productPurchased(productId, actionId: actionId, quantity: quantity) }
	}

	/// Removed from the wishlist. No effect for a product not reported liked.
	public static func productUnliked(_ productId: String, actionId: Int? = nil)
	{	events("productUnliked") { $0.productUnliked(productId, actionId: actionId) }
	}

	/// No effect for a product not reported added to cart.
	public static func productRemovedFromCart(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	events("productRemovedFromCart") { $0.productRemovedFromCart(productId, actionId: actionId, quantity: quantity) }
	}

	/// Everything reported added to cart was purchased.
	public static func productsPurchased()
	{	events("productsPurchased") { $0.productsPurchased() }
	}

	/// The wishlist was emptied.
	public static func productsUnliked()
	{	events("productsUnliked") { $0.productsUnliked() }
	}

	/// The cart was emptied.
	public static func productsRemovedFromCart()
	{	events("productsRemovedFromCart") { $0.productsRemovedFromCart() }
	}

	/// `articleId` is the "Internal ID" in your articles catalog.
	public static func articleViewed(_ articleId: String, actionId: Int? = nil)
	{	events("articleViewed") { $0.articleViewed(articleId, actionId: actionId) }
	}

	public static func articleLiked(_ articleId: String, actionId: Int? = nil)
	{	events("articleLiked") { $0.articleLiked(articleId, actionId: actionId) }
	}

	public static func articleCommented(_ articleId: String, actionId: Int? = nil)
	{	events("articleCommented") { $0.articleCommented(articleId, actionId: actionId) }
	}

	public static func articleUnliked(_ articleId: String, actionId: Int? = nil)
	{	events("articleUnliked") { $0.articleUnliked(articleId, actionId: actionId) }
	}

	/// The visitor reached the article's goal.
	public static func articleGoal(_ articleId: String, actionId: Int? = nil)
	{	events("articleGoal") { $0.articleGoal(articleId, actionId: actionId) }
	}

	public static func articlesUnliked()
	{	events("articlesUnliked") { $0.articlesUnliked() }
	}

	/// A promotion card of a promotions action came into view. `promotionId` is the card's
	/// `data-personyze-click-target="promotions <id>"`; `actionId` is required.
	public static func promotionViewed(_ promotionId: String, actionId: Int)
	{	events("promotionViewed") { $0.promotionViewed(promotionId, actionId: actionId) }
	}

	public static func promotionClicked(_ promotionId: String, actionId: Int)
	{	events("promotionClicked") { $0.promotionClicked(promotionId, actionId: actionId) }
	}

	/// The visitor revealed the promotion's coupon code.
	public static func codeRevealed(_ promotionId: String, actionId: Int)
	{	events("codeRevealed") { $0.codeRevealed(promotionId, actionId: actionId) }
	}

	/// A coupon code was redeemed in the app.
	public static func couponUsed(_ code: String)
	{	events("couponUsed") { $0.couponUsed(code) }
	}

	/// Any tracker command, sent as given - for what the typed calls do not cover. Sent in a
	/// request of its own, so a command Personyze refuses cannot take other events with it.
	public static func track(_ command: [String])
	{	events("track") { $0.track(command) }
	}

	// MARK: - action reports

	/// The action was shown (`executed`). An action never reported executed looks like it never
	/// ran, and its A/B arm like it had no traffic.
	public static func reportExecuted(_ actionId: Int)
	{	events("reportExecuted") { $0.reportExecuted(actionId) }
	}

	/// The visitor tapped the action's call to action (`target`) - the Clicks criterion of an A/B
	/// test, and only that. A purchase is `productPurchased` with the action id.
	public static func reportEngaged(_ actionId: Int)
	{	events("reportEngaged") { $0.reportEngaged(actionId) }
	}

	/// The visitor closed the action; with `dontShowForSessions` > 0 it is not presented again for
	/// that many sessions.
	public static func reportClosed(_ actionId: Int, dontShowForSessions: Int = 0)
	{	events("reportClosed") { $0.reportClosed(actionId, dontShowForSessions: dontShowForSessions) }
	}

	public static func reportProductClicked(_ actionId: Int, productId: String)
	{	events("reportProductClicked") { $0.reportProductClicked(actionId, productId: productId) }
	}

	public static func reportArticleClicked(_ actionId: Int, articleId: String)
	{	events("reportArticleClicked") { $0.reportArticleClicked(actionId, articleId: articleId) }
	}

	/// The action could not be presented. The message shows in Live visits.
	public static func reportError(_ actionId: Int, message: String)
	{	events("reportError") { $0.reportError(actionId, message: message) }
	}

	/// A tap inside an action, from a renderer of your own.
	public static func report(_ click: PersonyzeClick)
	{	events("report") { $0.report(click) }
	}

	// MARK: - notifications and A/B tests

	/// Check for a notification now and show it, ignoring the 15-minute interval. Answers the
	/// queued notification, or nil.
	public static func checkNotifications() async -> PersonyzeNotification?
	{	await client?.checkNotifications()
	}

	/// Turn the notifications on or off (also `PersonyzeConfig.notifications`): the periodic check,
	/// and the device's push registration.
	public static func setNotificationsEnabled(_ enabled: Bool)
	{	events("setNotificationsEnabled") { $0.setNotificationsEnabled(enabled) }
	}

	/// The device token Apple's push service gave the app, passed on from your app delegate's
	/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`: Personyze then pushes
	/// this visitor's notifications to the device at once (`PersonyzeClient.setPushToken`).
	public static func setPushToken(_ deviceToken: Data)
	{	events("setPushToken") { $0.setPushToken(deviceToken) }
	}

	/// Who is winning the A/B test of campaign `conditionId`.
	public static func verdict(_ conditionId: Int) async -> Result<PersonyzeVerdict, PersonyzeError>
	{	guard let client else
		{	return .failure(.invalid(message: "Personyze.initialize() has not been called"))
		}
		return await client.verdict(conditionId)
	}
}

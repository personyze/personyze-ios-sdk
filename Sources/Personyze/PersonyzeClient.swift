import Foundation

/// A Personyze client: decisions, events, action reports, the visitor, notifications. Create it
/// with `Personyze.initialize`, which forwards every call to it; one at a time per process.
///
/// Every member is safe from any thread or actor. Nothing throws for a network or server
/// problem: a failed decision answers an empty result with its `error` set, and every failure
/// reaches `PersonyzeConfig.onError` (SPEC section 11).
public final class PersonyzeClient: Sendable, ActionReporter, CustomStringConvertible
{	public let config: PersonyzeConfig

	let engine: Engine
	private let recorder: PersonyzeEvents
	private let presenter: any NotificationPresenter
	private let notificationsEnabled: Locked<Bool>
	private let errorListener: Locked<(@Sendable (PersonyzeError, PersonyzeErrorContext) -> Void)?>

	init(config: PersonyzeConfig, environment: ((Locked<Bool>) -> ClientEnvironment)? = nil)
	{	let notificationsEnabled = Locked(config.notifications)
		let errorListener = Locked(config.onError)
		let owner = WeakRef<PersonyzeClient>()
		let env = environment?(notificationsEnabled) ?? ClientEnvironment.current(config: config, notifications: notificationsEnabled)
		self.config = config
		self.notificationsEnabled = notificationsEnabled
		self.errorListener = errorListener
		self.presenter = env.presenter
		self.engine = Engine(
			config: config.engineConfig,
			platform: env.platform,
			store: env.store,
			cacheStore: env.cacheStore,
			transport: env.transport,
			// 1.x kept one state per app; it becomes the default storage's.
			legacy: config.storageName == "default" ? env.legacy : nil,
			onError: { error, context in errorListener.value?(error, context) },
			owner: { owner.value }
		)
		recorder = PersonyzeEvents(engine: engine)
		owner.value = self
		env.presenter.schedulePolling(config.notifications)
	}

	// MARK: - decisions

	/// The current decision; updated by every response and restored when the app starts.
	public var result: PersonyzeResult
	{	engine.result.value
	}

	/// The current decision, then each change.
	public var results: AsyncStream<PersonyzeResult>
	{	engine.result.stream()
	}

	/// The current visitor and session.
	public var visitor: PersonyzeVisitor
	{	engine.visitor.value
	}

	/// The current visitor, then each change.
	public var visitors: AsyncStream<PersonyzeVisitor>
	{	engine.visitor.stream()
	}

	/// The visitor opened a screen ("document"): log it and get what to present there, in one
	/// round trip. `events` run first, on the caller's own actor, and go in the same request,
	/// attributed to this screen:
	///
	/// ```swift
	/// let result = await Personyze.navigate("Product") { $0.productViewed("A1000") }
	/// ```
	///
	/// Never throws for a network or server problem: the answer is then empty with `error` set.
	/// Call it once per screen entry, not on every view update - each call is a page view.
	///
	/// `nonisolated(nonsending)`: it runs on the caller's actor, so the closure may read the
	/// screen's state - handed to code off that actor, a closure touching main-actor state would
	/// not compile under Swift 6.
	@discardableResult
	nonisolated(nonsending) public func navigate(_ document: String, events: ((PersonyzeEvents) -> Void)? = nil) async -> PersonyzeResult
	{	let ticket = engine.beginNavigation(document)
		events?(recorder)
		return await engine.finishNavigation(ticket)
	}

	/// Send what is queued and answer the current decision, merged with what the response
	/// changed. With nothing queued it answers the current decision without a request.
	@discardableResult
	public func refresh() async -> PersonyzeResult
	{	await engine.refresh()
	}

	/// Send what is queued now instead of waiting for the automatic send.
	public func flush() async
	{	await engine.flush()
	}

	// MARK: - visitor

	/// Identify the visitor with your own user id (after login). Personyze files them under it from
	/// the next request on; the anonymous visitor's session is not carried over (SPEC section 3).
	/// Nil logs out, back to this install's anonymous visitor.
	public func setUserId(_ userId: String?)
	{	if let userId, userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		{	engine.reportInvalid("Personyze: setUserId() needs a non-blank id, or nil to log out; ignored", operation: "setUserId")
		}
		else
		{	engine.setUserId(userId.map { .text($0) })
		}
	}

	/// A numeric user id. Past 2^53 it goes as text, which Personyze hashes exactly; as a number
	/// its JavaScript would round it.
	public func setUserId(_ userId: Int)
	{	engine.setUserId(Engine.userId(Int64(userId)))
	}

	/// Start a new Personyze session on the next request. A session otherwise ends 90 minutes
	/// after it started.
	public func startNewSession()
	{	engine.startNewSession()
	}

	/// Forget the cached action and campaign templates and load them again. Normally never needed.
	public func clearCache() async
	{	await engine.clearCache()
	}

	/// A new anonymous visitor, and everything stored for the old one deleted: session, queued
	/// events, decision, history. For a privacy request or a test.
	public func reset() async
	{	await engine.reset()
	}

	// MARK: - events and reports (documented on PersonyzeEvents)

	public func setProfile(_ field: String, _ value: String?)
	{	recorder.setProfile(field, value)
	}

	public func setProfile(_ fields: [String: String?])
	{	recorder.setProfile(fields)
	}

	public func productViewed(_ productId: String, actionId: Int? = nil)
	{	recorder.productViewed(productId, actionId: actionId)
	}

	public func productAddedToCart(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	recorder.productAddedToCart(productId, actionId: actionId, quantity: quantity)
	}

	public func productLiked(_ productId: String, actionId: Int? = nil)
	{	recorder.productLiked(productId, actionId: actionId)
	}

	public func productPurchased(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	recorder.productPurchased(productId, actionId: actionId, quantity: quantity)
	}

	public func productUnliked(_ productId: String, actionId: Int? = nil)
	{	recorder.productUnliked(productId, actionId: actionId)
	}

	public func productRemovedFromCart(_ productId: String, actionId: Int? = nil, quantity: Int? = nil)
	{	recorder.productRemovedFromCart(productId, actionId: actionId, quantity: quantity)
	}

	public func productsPurchased()
	{	recorder.productsPurchased()
	}

	public func productsUnliked()
	{	recorder.productsUnliked()
	}

	public func productsRemovedFromCart()
	{	recorder.productsRemovedFromCart()
	}

	public func articleViewed(_ articleId: String, actionId: Int? = nil)
	{	recorder.articleViewed(articleId, actionId: actionId)
	}

	public func articleLiked(_ articleId: String, actionId: Int? = nil)
	{	recorder.articleLiked(articleId, actionId: actionId)
	}

	public func articleCommented(_ articleId: String, actionId: Int? = nil)
	{	recorder.articleCommented(articleId, actionId: actionId)
	}

	public func articleUnliked(_ articleId: String, actionId: Int? = nil)
	{	recorder.articleUnliked(articleId, actionId: actionId)
	}

	public func articleGoal(_ articleId: String, actionId: Int? = nil)
	{	recorder.articleGoal(articleId, actionId: actionId)
	}

	public func articlesUnliked()
	{	recorder.articlesUnliked()
	}

	public func promotionViewed(_ promotionId: String, actionId: Int)
	{	recorder.promotionViewed(promotionId, actionId: actionId)
	}

	public func promotionClicked(_ promotionId: String, actionId: Int)
	{	recorder.promotionClicked(promotionId, actionId: actionId)
	}

	public func codeRevealed(_ promotionId: String, actionId: Int)
	{	recorder.codeRevealed(promotionId, actionId: actionId)
	}

	public func couponUsed(_ code: String)
	{	recorder.couponUsed(code)
	}

	public func track(_ command: [String])
	{	recorder.track(command)
	}

	public func reportExecuted(_ actionId: Int)
	{	recorder.reportExecuted(actionId)
	}

	public func reportEngaged(_ actionId: Int)
	{	recorder.reportEngaged(actionId)
	}

	public func reportClosed(_ actionId: Int, dontShowForSessions: Int = 0)
	{	recorder.reportClosed(actionId, dontShowForSessions: dontShowForSessions)
	}

	public func reportProductClicked(_ actionId: Int, productId: String)
	{	recorder.reportProductClicked(actionId, productId: productId)
	}

	public func reportArticleClicked(_ actionId: Int, articleId: String)
	{	recorder.reportArticleClicked(actionId, articleId: articleId)
	}

	public func reportError(_ actionId: Int, message: String)
	{	recorder.reportError(actionId, message: message)
	}

	public func report(_ click: PersonyzeClick)
	{	recorder.report(click)
	}

	// MARK: - notifications and A/B tests

	/// Check for a notification now and show it, ignoring the 15-minute interval. Answers the
	/// queued notification, or nil.
	public func checkNotifications() async -> PersonyzeNotification?
	{	await checkNotifications(force: true)
	}

	/// Reports kept from before go first: a tap made offline, a report the process did not live to
	/// send. A notification posted is reported shown, and taken off the server's queue.
	func checkNotifications(force: Bool) async -> PersonyzeNotification?
	{	await engine.sendNotificationReports()
		guard await presenter.canShow(), let notification = await engine.pollNotification(force: force) else
		{	return nil
		}
		if await presenter.show(notification)
		{	async let ack: Void = engine.ackNotification(notification.messageId)
			await engine.reportNotification(notification.shownUrl)
			await ack
		}
		return notification
	}

	/// Whether the app wants notifications now: the config, then `setNotificationsEnabled`.
	var notificationsWanted: Bool
	{	notificationsEnabled.value
	}

	/// Turn the periodic notification check on or off (also `PersonyzeConfig.notifications`).
	public func setNotificationsEnabled(_ enabled: Bool)
	{	notificationsEnabled.value = enabled
		presenter.schedulePolling(enabled)
	}

	/// Who is winning the A/B test of campaign `conditionId`.
	public func verdict(_ conditionId: Int) async -> Result<PersonyzeVerdict, PersonyzeError>
	{	await engine.verdict(conditionId)
	}

	// MARK: - support

	/// The stored state, redacted: visitor, session fields, queue, cache. For a support case or a
	/// test screen; the format may change.
	public func diagnostics() -> String
	{	engine.diagnostics()
	}

	/// The app left the foreground: send what is queued while it may still run.
	func flushInBackground() async -> Bool
	{	await engine.flushLive(budgetMs: config.engineConfig.backgroundTimeoutMs, operation: "flush")
	}

	func setErrorListener(_ listener: (@Sendable (PersonyzeError, PersonyzeErrorContext) -> Void)?)
	{	errorListener.value = listener
	}

	func close()
	{	presenter.schedulePolling(false)
		engine.close()
	}

	public var description: String
	{	"PersonyzeClient(\(config))"
	}
}

#if os(iOS)
import Foundation
import UIKit
import UserNotifications

/// Shows a Personyze notification as a local notification: one at a time, a new one replacing the
/// last, as on Android. The picture (or else the icon) is attached; the buttons become the
/// notification's actions. Where a tap goes is the app's to pass on - the notification center's
/// delegate is the app's, so the SDK does not take it: `Personyze.handleNotificationResponse`.
struct UserNotificationPresenter: NotificationPresenter
{	static let requestId = "personyze"
	static let userInfoKey = "personyze"
	static let buttonPrefix = "personyze.button."

	/// Whether the user allows the app's notifications to appear anywhere.
	static func allowed() async -> Bool
	{	let s = await UNUserNotificationCenter.current().notificationSettings()
		switch s.authorizationStatus
		{	case .authorized, .provisional, .ephemeral:
				return s.alertSetting == .enabled || s.notificationCenterSetting == .enabled || s.lockScreenSetting == .enabled
			default:
				return false
		}
	}

	func canShow() async -> Bool
	{	await UserNotificationPresenter.allowed()
	}

	func show(_ notification: PersonyzeNotification) async -> Bool
	{	let content = UNMutableNotificationContent()
		content.title = notification.title
		content.body = notification.body
		if !notification.silent
		{	content.sound = .default
		}
		content.threadIdentifier = UserNotificationPresenter.requestId
		content.userInfo = [
			UserNotificationPresenter.userInfoKey: [
				"url": notification.url,
				"buttons": notification.buttons.map { $0.url },
				"message_id": NSNumber(value: notification.messageId),
				"click_url": notification.clickUrl,
			] as [String: Any],
		]
		if let attachment = await UserNotificationPresenter.attachment(notification.imageUrl.isEmpty ? notification.iconUrl : notification.imageUrl)
		{	content.attachments = [attachment]
		}
		if !notification.buttons.isEmpty
		{	content.categoryIdentifier = await UserNotificationPresenter.category(notification.buttons.map { $0.title })
		}
		do
		{	try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UserNotificationPresenter.requestId, content: content, trigger: nil))
			return true
		}
		catch
		{	Log.write("Personyze: could not post the notification: \(error)")
			return false
		}
	}

	func schedulePolling(_ enabled: Bool)
	{	if enabled
		{	BackgroundRefresh.schedule(after: 15*60)
		}
	}

	/// A category whose actions are these buttons, one per set of titles, added beside the app's
	/// own categories - `setNotificationCategories` replaces them all, so they are read first.
	static func category(_ titles: [String]) async -> String
	{	let id = "personyze." + SHA256.hex(titles.joined(separator: "\n")).prefix(16)
		let center = UNUserNotificationCenter.current()
		var categories = await center.notificationCategories()
		if !categories.contains(where: { $0.identifier == id })
		{	let actions = titles.enumerated().map { i, title in
				UNNotificationAction(identifier: buttonPrefix + String(i), title: title, options: [.foreground])
			}
			categories.insert(UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: []))
			center.setNotificationCategories(categories)
		}
		return id
	}

	/// An image to attach: downloaded to a file, which is what a notification takes, named by its
	/// type, which is how the notification tells it. Nil when it cannot be had within 10 seconds.
	static func attachment(_ address: String) async -> UNNotificationAttachment?
	{	guard let url = URL(string: address), url.scheme?.lowercased() == "https" else
		{	return nil
		}
		let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
		guard let (file, response) = try? await URLSession.shared.download(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else
		{	return nil
		}
		let types = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic"]
		guard let ext = response.mimeType.flatMap({ types[$0.lowercased()] }) ?? (url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()) else
		{	return nil
		}
		let destination = FileManager.default.temporaryDirectory.appendingPathComponent("personyze-\(UUID().uuidString).\(ext)")
		do
		{	try FileManager.default.moveItem(at: file, to: destination)
			return try UNNotificationAttachment(identifier: "picture", url: destination, options: nil)
		}
		catch
		{	return nil
		}
	}
}

extension Personyze
{	/// Opens where a Personyze notification leads when the user taps it, or one of its buttons. Call
	/// it from your notification center delegate; it answers false for a notification that is not
	/// Personyze's:
	///
	/// ```swift
	/// func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async
	/// {	if Personyze.handleNotificationResponse(response)
	/// 	{	return
	/// 	}
	/// 	// the app's own notifications
	/// }
	/// ```
	///
	/// It also reports the tap to Personyze, so the campaign counts it as a click, as a website's
	/// push is counted.
	///
	/// A notification arriving while the app is in front appears only if the delegate's
	/// `userNotificationCenter(_:willPresent:)` says so.
	@discardableResult
	public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool
	{	guard let info = response.notification.request.content.userInfo[UserNotificationPresenter.userInfoKey] as? [String: Any] else
		{	return false
		}
		let action = response.actionIdentifier
		if action == UNNotificationDismissActionIdentifier
		{	return true
		}
		if let report = info["click_url"] as? String, !report.isEmpty
		{	reportTap(report)
		}
		var address = info["url"] as? String ?? ""
		if action.hasPrefix(UserNotificationPresenter.buttonPrefix), let i = Int(action.dropFirst(UserNotificationPresenter.buttonPrefix.count)), let buttons = info["buttons"] as? [String], buttons.indices.contains(i)
		{	address = buttons[i]
		}
		if let url = SafeLink.url(address, assetsUrl: nil)
		{	Task { @MainActor in
				UIApplication.shared.open(url)
			}
		}
		return true
	}

	/// The tap's report, sent while iOS lets the app run - opening the address may take it out of
	/// the foreground - and kept for the next check if it cannot go now. Not before `initialize`:
	/// the app has not said yet that anything may be sent.
	private static func reportTap(_ address: String)
	{	guard let client = Personyze.client else
		{	Log.write("Personyze: a notification was tapped before Personyze.initialize(); the tap is not reported")
			return
		}
		onMain
		{	let handle = BackgroundTaskHandle()
			handle.begin()
			Task { @MainActor in
				await client.engine.reportNotification(address)
				handle.end()
			}
		}
	}
}
#endif

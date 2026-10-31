#if os(iOS)
import Foundation
import PersonyzeNotificationService
import UIKit
import UserNotifications

/// Shows a Personyze notification as a local notification: one at a time, a new one replacing the
/// last, as on Android - and replacing, or replaced by, the same message pushed (it carries the
/// push's collapse id). The picture (or else the icon) is attached; the buttons become the
/// notification's actions - as the app's Notification Service Extension does to a pushed one
/// (`PersonyzePush`). Where a tap goes is the app's to pass on - the notification center's
/// delegate is the app's, so the SDK does not take it: `Personyze.handleNotificationResponse`.
struct UserNotificationPresenter: NotificationPresenter
{
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
		content.threadIdentifier = PersonyzePush.requestId
		content.userInfo = [PersonyzePush.userInfoKey: UserNotificationPresenter.userInfo(notification)]
		if let attachment = await PersonyzePush.attachment(notification.imageUrl.isEmpty ? notification.iconUrl : notification.imageUrl)
		{	content.attachments = [attachment]
		}
		if !notification.buttons.isEmpty
		{	content.categoryIdentifier = await PersonyzePush.category(notification.buttons.map { $0.title })
		}
		do
		{	try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: PersonyzePush.requestId, content: content, trigger: nil))
			return true
		}
		catch
		{	Log.write("Personyze: could not post the notification: \(error)")
			return false
		}
	}

	func schedulePolling(_ enabled: Bool, everySeconds: Int)
	{	if enabled
		{	BackgroundRefresh.schedule(after: TimeInterval(everySeconds))
		}
	}

	/// The `personyze` object a notification carries - what `GET current_notification` answered,
	/// as a push carries it too (`PersonyzePush.Message` reads either).
	static func userInfo(_ n: PersonyzeNotification) -> [String: Any]
	{	[	"message_id": NSNumber(value: n.messageId),
			"tag": n.url,
			"image": n.imageUrl,
			"icon": n.iconUrl,
			"actions": n.buttons.map { ["title": $0.title, "icon": $0.iconUrl, "action": $0.url] },
			"silent": n.silent,
			"shown_url": n.shownUrl,
			"click_url": n.clickUrl,
		]
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
	///
	/// The same for a notification Personyze pushed (`Personyze.setPushToken`) as for one the app's
	/// own check posted: both carry the same `personyze` object.
	@discardableResult
	public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool
	{	guard let info = response.notification.request.content.userInfo[PersonyzePush.userInfoKey] as? [String: Any] else
		{	return false
		}
		let action = response.actionIdentifier
		if action == UNNotificationDismissActionIdentifier
		{	return true
		}
		let message = PersonyzePush.Message(info)
		if !message.clickUrl.isEmpty
		{	reportTap(message.clickUrl)
		}
		var address = message.url
		if action.hasPrefix(PersonyzePush.buttonPrefix), let i = Int(action.dropFirst(PersonyzePush.buttonPrefix.count)), message.buttons.indices.contains(i)
		{	address = message.buttons[i].url
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

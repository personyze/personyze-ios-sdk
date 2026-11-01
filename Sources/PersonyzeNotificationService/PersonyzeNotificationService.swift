#if os(iOS)
import Foundation
import UserNotifications

/// A pushed Personyze notification, made whole on the device (SPEC section 11): Apple's push
/// service draws a push by itself - title, text, sound - and only an app's Notification Service
/// Extension may add to it. This is that extension's class: it attaches the picture (or else the
/// icon), turns the buttons into the notification's actions, and reports the notification shown,
/// so the campaign counts it, as it counts one the app's own check posts. A push that is not
/// Personyze's passes untouched.
///
/// In Xcode: File › New › Target › Notification Service Extension, add the
/// `PersonyzeNotificationService` library of this package to it, and make its class this one:
///
/// ```swift
/// import PersonyzeNotificationService
///
/// final class NotificationService: PersonyzeNotificationService, @unchecked Sendable
/// {
/// }
/// ```
///
/// An extension that handles other pushes too overrides `didReceive(_:withContentHandler:)` and
/// calls `super` for the ones `isPersonyze(_:)` answers true for. Without the extension a pushed
/// notification still appears and is still reported when tapped; it shows no picture or buttons,
/// and is counted shown only when tapped.
open class PersonyzeNotificationService: UNNotificationServiceExtension, @unchecked Sendable
{	private let lock = NSLock()
	private var pending: (handler: (UNNotificationContent) -> Void, content: UNMutableNotificationContent)?

	/// Whether the notification is one Personyze sent.
	public static func isPersonyze(_ request: UNNotificationRequest) -> Bool
	{	request.content.userInfo[PersonyzePush.userInfoKey] is [String: Any]
	}

	open override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void)
	{	guard let info = request.content.userInfo[PersonyzePush.userInfoKey] as? [String: Any], let content = request.content.mutableCopy() as? UNMutableNotificationContent else
		{	contentHandler(request.content)
			return
		}
		lock.withLock
		{	pending = (contentHandler, content)
		}
		let message = PersonyzePush.Message(info)
		Task { [self] in
			let attachment = await PersonyzePush.attachment(message.picture)
			let category = message.buttonTitles.isEmpty ? nil : await PersonyzePush.category(message.buttonTitles)
			lock.withLock
			{	if let content = pending?.content
				{	if let attachment
					{	content.attachments = [attachment]
					}
					if let category
					{	content.categoryIdentifier = category
					}
				}
			}
			await PersonyzePush.reportShown(message.shownUrl)
			deliver()
		}
	}

	/// iOS's time is up: the notification goes as it is now.
	open override func serviceExtensionTimeWillExpire()
	{	deliver()
	}

	private func deliver()
	{	let done = lock.withLock
		{	() -> (handler: (UNNotificationContent) -> Void, content: UNMutableNotificationContent)? in
			defer
			{	pending = nil
			}
			return pending
		}
		if let done
		{	done.handler(done.content)
		}
	}
}

/// What a Personyze notification looks like on the device - the same whether the app's own check
/// posted it or Apple's push service delivered it: its `userInfo["personyze"]` is the answer of
/// `GET current_notification` (without the title and text, which a push carries in `aps`).
/// Shared with the SDK, which posts the checked ones.
package enum PersonyzePush
{	package static let userInfoKey = "personyze"
	/// The one notification the SDK posts at a time; a push uses it as its collapse id, so the two
	/// replace each other instead of doubling.
	package static let requestId = "personyze"
	package static let buttonPrefix = "personyze.button."

	/// The parts of the `personyze` object the device needs.
	package struct Message
	{	package var messageId: Int64
		package var url: String
		package var buttons: [(title: String, url: String)]
		package var picture: String
		package var shownUrl: String
		package var clickUrl: String

		package init(_ info: [String: Any])
		{	let text = { (v: Any?) in (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
			messageId = (info["message_id"] as? NSNumber)?.int64Value ?? Int64(text(info["message_id"])) ?? 0
			url = text(info["tag"])
			buttons = ((info["actions"] as? [[String: Any]]) ?? []).compactMap { b in
				let title = text(b["title"])
				let url = text(b["action"])
				return title.isEmpty || url.isEmpty ? nil : (title, url)
			}
			let image = text(info["image"])
			picture = image.isEmpty ? text(info["icon"]) : image
			shownUrl = text(info["shown_url"])
			clickUrl = text(info["click_url"])
		}

		package var buttonTitles: [String]
		{	buttons.map { $0.title }
		}
	}

	/// A category whose actions are these buttons, one per set of titles, added beside the app's
	/// own categories - `setNotificationCategories` replaces them all, so they are read first.
	package static func category(_ titles: [String]) async -> String
	{	let id = "personyze." + fnv1a(titles.joined(separator: "\n"))
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
	package static func attachment(_ address: String) async -> UNNotificationAttachment?
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

	/// The extension's "shown" report: one GET of the address the server gave, https only, no API
	/// key. An extension has seconds to live and nowhere to keep a report for later, so one that
	/// fails is lost - the tap's still counts.
	package static func reportShown(_ address: String) async
	{	guard let url = URL(string: address), url.scheme?.lowercased() == "https" else
		{	return
		}
		let config = URLSessionConfiguration.ephemeral
		config.urlCache = nil
		let session = URLSession(configuration: config)
		defer
		{	session.finishTasksAndInvalidate()
		}
		_ = try? await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10))
	}

	/// A short stable name for a set of titles (FNV-1a, 64 bits): the same in the app and in its
	/// extension, so one set of buttons is one category.
	static func fnv1a(_ text: String) -> String
	{	var hash: UInt64 = 0xCBF29CE484222325
		for byte in text.utf8
		{	hash = (hash ^ UInt64(byte)) &* 0x100000001B3
		}
		return String(hash, radix: 16)
	}
}
#endif

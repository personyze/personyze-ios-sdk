import Foundation

/// `GET current_notification` answers `null` or one queued message (app-service
/// `mod_rest/handlers/current_notification.ts`), put there by a "Web Push Send" action for a visitor
/// whose requests said `noti_enabled`.
enum NotificationPoll
{	static func parse(_ text: String) -> PersonyzeNotification?
	{	let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != "null", let obj = JSON.parse(trimmed)?.objectValue else
		{	return nil
		}
		let title = trimmedText(obj["title"])
		let body = trimmedText(obj["body"])
		guard let messageId = Wire.long(obj["message_id"]), messageId > 0, !title.isEmpty, !body.isEmpty else
		{	return nil
		}
		let buttons = (obj["actions"]?.arrayValue ?? []).compactMap { (e: JSON) -> PersonyzeNotification.Button? in
			guard let b = e.objectValue else
			{	return nil
			}
			let buttonTitle = trimmedText(b["title"])
			let url = trimmedText(b["action"])
			if buttonTitle.isEmpty || url.isEmpty
			{	return nil
			}
			return PersonyzeNotification.Button(title: buttonTitle, iconUrl: trimmedText(b["icon"]), url: url)
		}
		return PersonyzeNotification(
			messageId: messageId,
			title: title,
			body: body,
			url: trimmedText(obj["tag"]),
			imageUrl: trimmedText(obj["image"]),
			iconUrl: trimmedText(obj["icon"]),
			badgeUrl: trimmedText(obj["badge"]),
			buttons: Array(buttons.prefix(3)),
			silent: Wire.bool(obj["silent"]),
			renotify: Wire.bool(obj["renotify"]),
			vibrate: Wire.text(obj["vibrate"]).split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 >= 0 }
		)
	}

	private static func trimmedText(_ e: JSON?) -> String
	{	Wire.text(e).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}

/// `GET /rest/ab_test/where/condition_id=N` (the shape the Node port types as `AbVerdict`).
enum VerdictParser
{	static func parse(_ text: String) -> PersonyzeVerdict?
	{	guard let obj = JSON.parse(text)?.objectValue, let conditionId = Wire.int(obj["condition_id"]) else
		{	return nil
		}
		return PersonyzeVerdict(
			conditionId: conditionId,
			conditionName: Wire.text(obj["condition_name"]),
			hasWinner: Wire.bool(obj["has_winner"]),
			winnerActiongroupId: Wire.int(obj["winner_actiongroup_id"]),
			message: Wire.text(obj["message"]),
			controlGroupRotation: Wire.double(obj["control_group_rotation"]) ?? 0,
			maxDurationReached: Wire.bool(obj["max_duration_reached"]),
			goals: objects(obj["goals"]).map { g in
				PersonyzeVerdict.Goal(
					abGoal: Wire.text(g["ab_goal"]),
					title: Wire.text(g["title"]),
					lowerIsBetter: Wire.bool(g["lower_is_better"]),
					best: arm(g["best"]),
					comparedTo: arm(g["compared_to"]),
					significancePrc: Wire.double(g["significance_prc"]),
					improvementPrc: Wire.double(g["improvement_prc"]),
					minSignificancePrc: Wire.double(g["min_significance_prc"]),
					minImprovementPrc: Wire.double(g["min_improvement_prc"]),
					reached: Wire.bool(g["reached"]),
					summary: Wire.text(g["summary"]),
					groups: objects(g["groups"]).map { r in
						PersonyzeVerdict.Group(
							actiongroupId: Wire.int(r["actiongroup_id"]) ?? 0,
							name: Wire.text(r["name"]),
							value: Wire.double(r["value"]),
							denom: Wire.double(r["denom"]),
							rate: Wire.double(r["rate"])
						)
					}
				)
			},
			rawJson: text
		)
	}

	private static func objects(_ e: JSON?) -> [[String: JSON]]
	{	(e?.arrayValue ?? []).compactMap { $0.objectValue }
	}

	private static func arm(_ e: JSON?) -> PersonyzeVerdict.Arm?
	{	e?.objectValue.map { PersonyzeVerdict.Arm(actiongroupId: Wire.int($0["actiongroup_id"]) ?? 0, name: Wire.text($0["name"]), rate: Wire.double($0["rate"])) }
	}
}

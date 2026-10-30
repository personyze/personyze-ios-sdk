import Foundation

/// A notification a "Web Push Send" action queued for this visitor. The SDK shows it itself; this
/// is what a check for notifications answers, for logging or a UI of your own.
public struct PersonyzeNotification: Sendable, Equatable
{	public let messageId: Int64
	public let title: String
	public let body: String
	/// Where a tap on the notification goes (the message's `tag`), or empty.
	public let url: String
	public let imageUrl: String
	public let iconUrl: String
	public let badgeUrl: String
	public let buttons: [Button]
	public let silent: Bool
	public let renotify: Bool
	/// The vibration pattern the campaign set, in milliseconds. iOS plays no custom patterns; it is
	/// here for a UI of your own.
	public let vibrate: [Int64]
	/// Where the SDK reports the notification shown (the server's `shown_url`), or empty: nothing to
	/// report with.
	let shownUrl: String
	/// Where the SDK reports a tap on it or one of its buttons (`click_url`), or empty.
	let clickUrl: String

	public struct Button: Sendable, Equatable
	{	public let title: String
		public let iconUrl: String
		/// The address the button opens.
		public let url: String
	}
}

/// Who is winning an A/B test: `GET /rest/ab_test` for one campaign. Read-only; no visitor or
/// session is involved.
public struct PersonyzeVerdict: Sendable, Equatable
{	public let conditionId: Int
	public let conditionName: String
	/// True only when every configured goal passed its thresholds and they all name the same arm.
	public let hasWinner: Bool
	public let winnerActiongroupId: Int?
	/// Why there is no winner yet, in words; empty once there is one.
	public let message: String
	public let controlGroupRotation: Double
	public let maxDurationReached: Bool
	public let goals: [Goal]
	/// The response verbatim.
	public let rawJson: String

	public struct Goal: Sendable, Equatable
	{	public let abGoal: String
		public let title: String
		/// True for bounce rate: the best arm is the lowest.
		public let lowerIsBetter: Bool
		public let best: Arm?
		public let comparedTo: Arm?
		public let significancePrc: Double?
		/// Percentage points better than `comparedTo`, not a relative percentage.
		public let improvementPrc: Double?
		public let minSignificancePrc: Double?
		public let minImprovementPrc: Double?
		public let reached: Bool
		public let summary: String
		public let groups: [Group]
	}

	public struct Arm: Sendable, Equatable
	{	public let actiongroupId: Int
		public let name: String
		public let rate: Double?
	}

	public struct Group: Sendable, Equatable
	{	public let actiongroupId: Int
		public let name: String
		public let value: Double?
		public let denom: Double?
		public let rate: Double?
	}
}

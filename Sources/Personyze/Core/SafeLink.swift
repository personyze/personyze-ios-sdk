import Foundation

/// An address the visitor tapped - in an action, or in a notification - as a URL the app may open.
enum SafeLink
{	/// Nil for nothing to open: a script, a local file or data, and a link back to the assets
	/// origin. That last is a relative link written for the customer's site (`href="/"`), resolved
	/// against the CDN that serves the page: in an app it would open Personyze's CDN in the browser
	/// (the Android SDK measured one on a live action, 2026-10-23).
	static func url(_ address: String, assetsUrl: String?) -> URL?
	{	let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else
		{	return nil
		}
		if ["javascript", "file", "data", "about", "blob", "content"].contains(scheme)
		{	return nil
		}
		if let assets = assetsUrl.flatMap({ URL(string: $0) }), scheme == assets.scheme?.lowercased(), url.host?.lowercased() == assets.host?.lowercased()
		{	return nil
		}
		return url
	}
}

import Foundation

/// The page an HTML action runs in inside a web view.
///
/// `web-view.js` is Personyze's web view library (php-service `templates/web-view`): it runs the
/// content's templates and reports clicks to `personyze_message_handler`. The helper scripts an
/// action needs (`libs_app`: timer, survey, slider...) come from `actions/default/`. 1.x asked for
/// `actions/webkit/`, which is never built (CompileActionsJs writes only `default`), so every
/// action needing one rendered without it - the Android SDK measured the 404 in production on
/// 2026-10-23.
enum HtmlDocument
{	static func build(_ action: PersonyzeAction, assetsUrl: String, extraHead: String) -> String?
	{	guard action.isHtml, let content = action.content else
		{	return nil
		}
		let v = action.cacheVersion
		var html = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
		html += extraHead
		html += "</head><body style=\"visibility:hidden\" onload=\"document.body.style.visibility=''\"><script src=\""
		html += attr(assetsUrl + "web-view.js?v=\(v)")
		html += "\"></script>"
		for lib in action.libs
		{	html += "<script src=\""
			html += attr(assetsUrl + "actions/default/" + Endpoints.encodeURIComponent(lib) + ".js?v=\(v)")
			html += "\"></script>"
		}
		html += content
		html += "<script>_S_T.new_elem(document.body, null)</script></body></html>"
		return html
	}

	private static func attr(_ s: String) -> String
	{	s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
	}

	static func libs(of libsApp: String) -> [String]
	{	libsApp.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
	}
}

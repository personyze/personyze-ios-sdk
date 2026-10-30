import Foundation

/// The page an HTML action runs in inside a web view.
///
/// `web-view.js` is Personyze's web view library (php-service `templates/web-view`): it runs the
/// content's templates and reports clicks - to `window.personyze_message_handler` on Android, and
/// where that is absent to WebKit's `window.webkit.messageHandlers.personyze`, the handler 1.x
/// registered, as an object rather than JSON text. The helper scripts an
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

	/// The WebKit message handler the library posts to.
	static let webKitHandler = "personyze"

	/// Tells the view the content's height, through the same handler - the server's library never
	/// sends `height`. The Android SDK's script, posting to WebKit.
	///
	/// Measured as the bottom of the body's children and text (with the last margins), not as the
	/// height of `<html>` or `<body>`: the page has no doctype, as 1.x's had none, so it renders in
	/// quirks mode, where the body takes the viewport's height - and the viewport is the view.
	/// Measuring the body fed the view's own height back: on Android a live banner (action 240,
	/// 2026-10-23) stretched the view to the whole screen. Each child is observed (re-armed when
	/// children change), and measured again a moment after load: a helper script (`responsive`) or
	/// a late font changes the layout after the first measurement.
	static let heightScript = "<script>(function(){" +
		"function h(){var b=document.body;if(!b)return;var bs=getComputedStyle(b),bottom=0,i,e,cs;" +
		"var rg=document.createRange();rg.selectNodeContents(b);bottom=rg.getBoundingClientRect().bottom;" +
		"for(i=0;i<b.children.length;i++){e=b.children[i];cs=getComputedStyle(e);if(cs.position==='fixed'||cs.display==='none')continue;" +
		"bottom=Math.max(bottom,e.getBoundingClientRect().bottom+(parseFloat(cs.marginBottom)||0));}" +
		"var v=Math.ceil(bottom+window.scrollY+(parseFloat(bs.paddingBottom)||0)+(parseFloat(bs.marginBottom)||0));" +
		"if(v>0&&v!==h.l){h.l=v;try{window.webkit.messageHandlers.\(webKitHandler).postMessage({height:v})}catch(x){}}}" +
		"var ro=window.ResizeObserver?new ResizeObserver(h):null;" +
		"function watch(){if(ro)for(var i=0;i<document.body.children.length;i++)ro.observe(document.body.children[i]);}" +
		"document.addEventListener('DOMContentLoaded',function(){h();watch();if(window.MutationObserver)new MutationObserver(function(){watch();h();}).observe(document.body,{childList:true});});" +
		"window.addEventListener('load',function(){h();setTimeout(h,300);setTimeout(h,1500);});" +
		"})()</script>"
}

/// What the page in an action view posts: the content's height (our script), or a tap the
/// library reports - `{href, clicked, arg}`.
enum ActionViewMessage: Equatable
{	case height(Double)
	case click(kind: PersonyzeClick.Kind, href: String, arg: String)

	/// `body` as WebKit hands it over: a dictionary of strings and numbers. JSON text is read too,
	/// in case a version of the library posts it as it does on Android. Nil for anything else, and
	/// for a tap of a kind this version does not know.
	static func parse(_ body: Any) -> ActionViewMessage?
	{	var fields: [String: Any]? = body as? [String: Any]
		if fields == nil, let text = body as? String, let obj = JSON.parse(text)?.objectValue
		{	fields = obj.mapValues { (value: JSON) -> Any in
				switch value
				{	case .int(let n):
						return Double(n)
					case .double(let d):
						return d
					default:
						return Wire.text(value)
				}
			}
		}
		guard let fields else
		{	return nil
		}
		if let height = fields["height"]
		{	return number(height).map { .height($0) }
		}
		guard let kind = PersonyzeClick.kind(of: text(fields["clicked"])) else
		{	return nil
		}
		return .click(kind: kind, href: text(fields["href"]), arg: text(fields["arg"]))
	}

	private static func number(_ value: Any) -> Double?
	{	switch value
		{	case let d as Double:
				return d
			case let i as Int:
				return Double(i)
			case let s as String:
				return Double(s)
			default:
				return nil
		}
	}

	private static func text(_ value: Any?) -> String
	{	switch value
		{	case let s as String:
				return s
			case let d as Double:
				return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
			case let i as Int:
				return String(i)
			default:
				return ""
		}
	}
}

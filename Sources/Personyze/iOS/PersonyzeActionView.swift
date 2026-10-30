#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// Renders an HTML `PersonyzeAction` in a web view, as 1.x's `renderOnWebkitView` did, and reports
/// what happens in it:
///
/// - `executed` once the page has loaded (`reportExecuted`);
/// - a tap on the call to action, a close button, a recommended product or article
///   (`reportClicks`); then `onClick` - return true to handle it yourself, else a link opens in the
///   browser and a close hides the view.
///
/// Its intrinsic height is its content's (`autoHeight`), so it fits a stack view or a self-sizing
/// cell. In SwiftUI, `PersonyzeActionContent`.
@MainActor
public final class PersonyzeActionView: UIView
{	/// Report `executed` when the action has loaded.
	public var reportExecuted = true
	/// Report taps to Personyze.
	public var reportClicks = true
	/// Be as tall as the content, and do not scroll.
	public var autoHeight = true
	{	didSet
		{	webView?.scrollView.isScrollEnabled = !autoHeight
			invalidateIntrinsicContentSize()
		}
	}
	/// A tap inside the action. Return true when the app handled it; false lets the view do the
	/// default - open a link in the browser, hide the view on close.
	public var onClick: ((PersonyzeClick) -> Bool)?
	/// The content's height changed - for a container that does not follow the intrinsic size.
	public var onHeightChange: ((CGFloat) -> Void)?

	/// The action shown, or nil.
	public private(set) var action: PersonyzeAction?

	private var webView: WKWebView?
	private var renderedKey: String?
	private var executedPending = false
	private var contentHeight: CGFloat = 0
	private var closed = false
	/// The page being loaded: the one navigation the view lets through.
	private var expectedLoad: URL?
	private lazy var bridge = ActionViewBridge(view: self)

	public override init(frame: CGRect)
	{	super.init(frame: frame)
		backgroundColor = .clear
	}

	public required init?(coder: NSCoder)
	{	super.init(coder: coder)
		backgroundColor = .clear
	}

	/// Show `action`. The same action with the same content again does nothing, so this is safe to
	/// call on every cell reuse or view update. Non-HTML content, or a template not loaded yet,
	/// clears the view.
	public func render(_ action: PersonyzeAction)
	{	guard let html = HtmlDocument.build(action, assetsUrl: action.assetsUrl, extraHead: HtmlDocument.heightScript), let base = URL(string: action.assetsUrl) else
		{	clear()
			return
		}
		let key = "\(action.id):\(html.hashValue)"
		if key == renderedKey && webView != nil
		{	return
		}
		let wv = webView ?? makeWebView()
		self.action = action
		renderedKey = key
		closed = false
		isHidden = false
		contentHeight = 0
		executedPending = reportExecuted
		expectedLoad = base
		wv.loadHTMLString(html, baseURL: base)
		invalidateIntrinsicContentSize()
	}

	/// Show nothing.
	public func clear()
	{	action = nil
		renderedKey = nil
		executedPending = false
		contentHeight = 0
		expectedLoad = nil
		webView?.loadHTMLString("", baseURL: nil)
		invalidateIntrinsicContentSize()
	}

	/// Release the web view. The view can render again afterwards, with a new one.
	public func destroy()
	{	if let wv = webView
		{	wv.configuration.userContentController.removeScriptMessageHandler(forName: HtmlDocument.webKitHandler, contentWorld: .page)
			wv.navigationDelegate = nil
			wv.stopLoading()
			wv.removeFromSuperview()
		}
		webView = nil
		renderedKey = nil
		executedPending = false
	}

	public override var intrinsicContentSize: CGSize
	{	if closed || action == nil
		{	return CGSize(width: UIView.noIntrinsicMetric, height: 0)
		}
		if autoHeight
		{	// 1 point until measured: the page needs a frame to lay out in.
			return CGSize(width: UIView.noIntrinsicMetric, height: max(contentHeight, 1))
		}
		return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
	}

	private func makeWebView() -> WKWebView
	{	let config = WKWebViewConfiguration()
		// The page's storage lives as long as the view: nothing of the action stays in the app's
		// web data. The popup and template code keeps state in sessionStorage, which this keeps.
		config.websiteDataStore = .nonPersistent()
		config.preferences.javaScriptCanOpenWindowsAutomatically = false
		config.mediaTypesRequiringUserActionForPlayback = .all
		config.userContentController.add(bridge, contentWorld: .page, name: HtmlDocument.webKitHandler)
		let wv = WKWebView(frame: bounds, configuration: config)
		wv.isOpaque = false
		wv.backgroundColor = .clear
		wv.scrollView.backgroundColor = .clear
		wv.scrollView.isScrollEnabled = !autoHeight
		wv.navigationDelegate = bridge
		wv.translatesAutoresizingMaskIntoConstraints = false
		addSubview(wv)
		NSLayoutConstraint.activate([
			wv.leadingAnchor.constraint(equalTo: leadingAnchor),
			wv.trailingAnchor.constraint(equalTo: trailingAnchor),
			wv.topAnchor.constraint(equalTo: topAnchor),
			wv.bottomAnchor.constraint(equalTo: bottomAnchor),
		])
		webView = wv
		return wv
	}

	/// The client that decided the action, else the one `Personyze.initialize` created.
	private var reporter: (any ActionReporter)?
	{	if let owner = action?.owner
		{	return owner
		}
		return Personyze.client
	}

	// MARK: - from the page

	func received(_ message: ActionViewMessage, from origin: WKSecurityOrigin)
	{	guard let action, origin.host.lowercased() == URL(string: action.assetsUrl)?.host?.lowercased() else
		{	return
		}
		switch message
		{	case .height(let value):
				let height = CGFloat(value)
				if height != contentHeight
				{	contentHeight = height
					if autoHeight
					{	invalidateIntrinsicContentSize()
						superview?.setNeedsLayout()
					}
					onHeightChange?(height)
				}
			case .click(let kind, let href, let arg):
				handle(PersonyzeClick(actionId: action.id, kind: kind, href: href, arg: arg))
		}
	}

	private func handle(_ click: PersonyzeClick)
	{	if reportClicks
		{	reporter?.report(click)
		}
		if onClick?(click) == true
		{	return
		}
		if click.kind == .close
		{	closed = true
			isHidden = true
			invalidateIntrinsicContentSize()
			superview?.setNeedsLayout()
		}
		else if let url = SafeLink.url(click.href, assetsUrl: action?.assetsUrl)
		{	UIApplication.shared.open(url)
		}
		else if !click.href.isEmpty
		{	Log.write("Personyze: not opening \(click.href) - a relative link in the action, with no site behind it in an app")
		}
	}

	/// Nothing leaves the action's page. The page itself loads; an iframe of its content (a video,
	/// a map) loads; a link the library did not catch is reported as a tap on the call to action
	/// and opened outside.
	func policy(for navigation: WKNavigationAction) -> WKNavigationActionPolicy
	{	if navigation.targetFrame.map({ !$0.isMainFrame }) ?? false
		{	return .allow
		}
		let url = navigation.request.url
		if url?.absoluteString == "about:blank"
		{	return .allow
		}
		if let url, url == expectedLoad
		{	expectedLoad = nil
			return .allow
		}
		if navigation.navigationType == .linkActivated, let action, let url
		{	handle(PersonyzeClick(actionId: action.id, kind: .target, href: url.absoluteString, arg: ""))
		}
		return .cancel
	}

	func didFinishLoading()
	{	if executedPending, let action
		{	executedPending = false
			reporter?.reportExecuted(action.id)
		}
	}

	/// The page's process ended (memory pressure, a crash): the web view is blank from here on.
	/// Released, so the next `render` makes a new one.
	func contentProcessEnded()
	{	destroy()
	}
}

/// The web view's delegates, holding the view weakly: the user content controller keeps its
/// message handler for as long as the web view lives.
@MainActor
final class ActionViewBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate
{	private weak var view: PersonyzeActionView?

	init(view: PersonyzeActionView)
	{	self.view = view
	}

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage)
	{	guard message.frameInfo.isMainFrame, let parsed = ActionViewMessage.parse(message.body) else
		{	return
		}
		view?.received(parsed, from: message.frameInfo.securityOrigin)
	}

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy
	{	view?.policy(for: navigationAction) ?? .cancel
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
	{	view?.didFinishLoading()
	}

	func webViewWebContentProcessDidTerminate(_ webView: WKWebView)
	{	view?.contentProcessEnded()
	}
}

/// A `PersonyzeActionView` in SwiftUI, as tall as its content:
///
/// ```swift
/// if let banner = result.actions(in: "Home banner").first
/// {	PersonyzeActionContent(banner)
/// }
/// ```
public struct PersonyzeActionContent: UIViewRepresentable
{	private let action: PersonyzeAction
	private let onClick: ((PersonyzeClick) -> Bool)?

	/// `onClick`: return true when the app handled the tap; false lets the view do the default.
	public init(_ action: PersonyzeAction, onClick: ((PersonyzeClick) -> Bool)? = nil)
	{	self.action = action
		self.onClick = onClick
	}

	public func makeUIView(context: Context) -> PersonyzeActionView
	{	let view = PersonyzeActionView()
		view.setContentHuggingPriority(.required, for: .vertical)
		view.setContentCompressionResistancePriority(.required, for: .vertical)
		update(view)
		return view
	}

	public func updateUIView(_ view: PersonyzeActionView, context: Context)
	{	update(view)
	}

	private func update(_ view: PersonyzeActionView)
	{	view.onClick = onClick
		view.render(action)
	}

	@available(iOS 16.0, *)
	public func sizeThatFits(_ proposal: ProposedViewSize, uiView: PersonyzeActionView, context: Context) -> CGSize?
	{	CGSize(width: proposal.width ?? uiView.bounds.width, height: max(uiView.intrinsicContentSize.height, 0))
	}

	public static func dismantleUIView(_ view: PersonyzeActionView, coordinator: ())
	{	view.destroy()
	}
}
#endif

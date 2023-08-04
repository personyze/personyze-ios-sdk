# class PersonyzeAction (Personyze iOS SDK reference)

This object represents an “action” (in most cases - HTML content) that you want to execute in your application. You get action objects from call to [PersonyzeTracker.inst.getResult()](../PersonyzeTracker/README.md#personyzetrackerinstgetresult)

### action.id

```swift
var id: Int
```

Readonly field holding the action ID that distinguishes one action from another. This is Personyze internal property.

### action.name

```swift
var name: String?
```

Readonly field holding the action name - how you called it in the Personyze panel.

### action.contentType

```swift
var contentType: String?
```

Readonly field holding MIME type of action's content. It depends on action type. If you create a Banner, or a Recommendation action, the MIME type is “text/html”. In Personyze panel you can create action of type Javascript, and target it to the application, and the MIME type will be “application/javascript”. There is no reason to do this, because there is nothing to do with Javascript code in a mobile application. So you can decide how and whether to handle this action according to it's MIME type.

### action.content

```swift
var content: String
```

Readonly field holding the raw content of the action. It can be an HTML string, a JSON stringified value, or something else.

### action.contentJsonArray

```swift
var contentJsonArray: [Dictionary<String, String>]?
```

Assuming that the action raw content was a JSON stringified array of objects, this readonly field contains the action content as `[Dictionary<String, String>]`. If the action's content cannot be parsed this way, or if MIME type was not “application/json”, this field contains nil.

### action.contentHtmlDoc

```swift
var contentHtmlDoc: String?
```

If the MIME type of the action is “text/html”, this readonly field contains action's HTML wrapped in <html>, <head> and <body> tags, with added all the libraries necessary to run this HTML in a WebView widget.

It also adds capturing onclick event handler that prevents the user from leaving this HTML page by clicking on a hyperlink. So clicks will be blocked, and the HTML document will be not interactive. Use `action.renderOnWebkitView()` (see below) to react on clicks.

### action.renderOnWebkitView()

```swift
func renderOnWebkitView(_ webView: WKWebView)
func renderOnWebkitView(_ webView: WKWebView, clickedCallback: ((PersonyzeActionClicked) -> Void)?)
```

If the MIME type of the action is “text/html”, this method renders the HTML on a provided WebView component. It uses `action.contentHtmlDoc` to get the HTML, and installs click event handlers, that allow you to react on things clicked inside the HTML document.

When user clicks a hyperlink, the default behavior is suppressed, but you will catch this click, and get the link URL. To do this `webView.configuration.userContentController` is utilized.

Personyze HTML actions can contain whatever HTML content that you put in the Personyze panel when you create the action. There can be hyperlinks. Also Personyze allows to put “close this action” buttons, so probably you want to react on them clicked too. Recommendation actions also report about recommended products clicked.

You can catch all these user-generated events through the `clickedCallback` parameter. If you're not interested in catching events, you can omit this parameter.

Here is typical usage example:

```swift
action.renderOnWebkitView(webView)
{	clicked in
	// Got event. This means that you clicked some sensitive region
	// I report this event to Personyze. So there will be CTR and close-rate statistics, and widget contribution rate (products bought from this action)
	PersonyzeTracker.inst.reportActionClicked(clicked: clicked)
	// Also i show the event on screen
	self.labelStatus.text = "clicked=\(clicked.status); arg=\(clicked.arg); href=\(clicked.href)"
}
```

The `PersonyzeActionClicked` is dumb structure with the following fields:

- actionId: Int
- href: String - if a hyperlink clicked, this is it's URL. Otherwise empty string.
- status: String - one of “target”, “close”, “product”, “article”.
- arg: String - for a product or an article - it's Internal ID. For “close” this is number of sessions not to show again.

If you handle this click event, report to Personyze about it by calling [PersonyzeTracker.inst.reportActionClicked()](../PersonyzeTracker/README.md#personyzetrackerinstreportactionclicked), so Personyze will be able to show you CTR, close-rates, recommendation contribution value, and other statistics about how this action performs.

### action.reportExecuted()

```swift
func reportExecuted()
```

If you present this action in a custom way (not through `action.renderOnWebkitView()`), call this function after the action is shown to the user, so action status will be changed to “executed” in Personyze dashboard, and execution statistics will be counted.

### action.reportClick()

```swift
func reportClick()
```

If you present this action in a custom way (not through `action.renderOnWebkitView()`), and this action is considered “clickable”, call this method to report to Personyze that it was clicked. Later Personyze will show you CTR (percent of clicked per shown) statistics that will indicate the performance of this action.

### action.reportClose()

```swift
func reportClose()
func reportClose(dontShowSessions: Int)
```

If you present this action in a custom way (not through `action.renderOnWebkitView()`), and this action is considered “closable”, call this method when you dismiss the action content from the screen __as the result of user's intent to close it__ (the user doesn't want to see it). Later Personyze will show you close-rate (percent of closed per shown) statistics that will indicate the performance of this action.

- dontShowSessions - If provided, Personyze will not show (return from [PersonyzeTracker.inst.getResult()](../PersonyzeTracker/README.md#personyzetrackerinstgetresult)) this action this number of sessions. By default the session is 1.5 hours, but you can force start of new session by calling [PersonyzeTracker.inst.startNewSession()](../PersonyzeTracker/README.md#personyzetrackerinststartnewsession).

### action.reportProductClick()

```swift
func reportProductClick(productId: String)
```

If you present this action in a custom way (not through `action.renderOnWebkitView()`), and this action is showing product recommendations, call this method to report user's click on certain product. Later Personyze will show you contribution rate of this action and other statistics.

- productId - the “Internal ID” column in your products catalog, that you imported to Personyze.

### action.reportArticleClick()

```swift
func reportArticleClick(articleId: String)
```

### action.reportError()

```swift
func reportError(message: String)
```

If something went wrong with presenting this action to the user, it's recommended to call this method. This will set Personyze state of this action to “not executed”, and you will see the error message in Live Visits dashboard in the Personyze panel.

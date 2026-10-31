# Personyze iOS SDK 2.0

**Work in progress.** A rewrite of the 1.x SDK (a single `PersonyzeIosSdk.swift` dragged into an Xcode project) as
a Swift package, following the Android SDK 2.0 decision for decision: the same wire, the same session rules, the
same failure handling. 1.x stays available on this repository's `v1` branch.

Everything is in place and builds and tests on iOS; what is not yet proven is its behaviour in a running app - an
action rendered on screen, a notification shown, a background send - and the live conformance test.

## Use

Initialize once, where the app starts:

```swift
import Personyze

@main
struct ShopApp: App
{	init()
	{	Personyze.initialize(PersonyzeConfig(apiKey: "YOUR_API_KEY"))
	}
	...
}
```

On each screen, log the page view and get what to show there, in one round trip. Events in the closure go in the
same request, attributed to the screen; the closure runs on the caller's actor, so it may read the view's state:

```swift
let result = await Personyze.navigate("Product") { $0.productViewed(product.id) }
if result.has(88)
{	showVariantB()
}
```

Everything else the visitor does is one call that queues a command and returns at once, from any thread:

```swift
Personyze.productAddedToCart("A1000", quantity: 2)
Personyze.setUserId(user.email)	// after login; nil logs out
```

Nothing throws for a network or server problem. A failed decision answers an empty result with `error` set, so
the app renders its default; every failure the SDK absorbs reaches `PersonyzeConfig.onError`. The current decision
and visitor are also streams, for a view that follows them: `for await result in Personyze.results { ... }`, or in
SwiftUI `@StateObject private var personyze = PersonyzeModel()`.

### Showing an action

An HTML action (a banner, a recommendation widget) renders in a web view that reports it shown, reports taps on
it, opens its links in the browser and is as tall as its content:

```swift
if let banner = result.actions(in: "Home banner").first	// the placeholder's name or HTML id in the panel
{	PersonyzeActionContent(banner)	// SwiftUI; in UIKit, PersonyzeActionView and render(_:)
}
```

A JSON action (a product feed) is data for your own views: `action.contentJsonArray()`.

### Sending in the background

Queued events go out as the app leaves the foreground, and when the network returns. For what is left after that,
and for notifications while the app is closed, iOS runs a background refresh - if the app declares it in
`Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array><string>com.personyze.sdk.refresh</string></array>
<key>UIBackgroundModes</key>
<array><string>fetch</string></array>
```

Without it, both happen while the app runs. Call `Personyze.initialize` as the app starts (`App.init`, or
`application(_:didFinishLaunchingWithOptions:)`): iOS takes the handler only then, and the key is never stored, so a
launch in the background finds it only there.

### Notifications

`notifications = true` in the config shows what a "Web Push Send" campaign queues for the visitor, as a local
notification. The app asks the user's permission itself (`UNUserNotificationCenter.requestAuthorization`), and
passes taps on to the SDK from its notification delegate, which stays the app's:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async
{	if Personyze.handleNotificationResponse(response)
	{	return
	}
	// the app's own notifications
}
```

The campaign's statistics count each notification shown and each tap on it or its buttons - the tap through
`handleNotificationResponse` - as they count a website's push. A report that cannot go at once (no network)
goes with the next notification check. The SDK checks as the app comes to the front (once a minute at most), and
in the background as iOS allows.

#### Pushed at once (Apple's push service)

With the account's Apple push key uploaded in the Personyze panel (Integrations › App push), a campaign reaches
the phone at once, even with the app closed, instead of at the app's next check. In the app's target, add the
Push Notifications capability, and pass the device token on from the app delegate - the SDK asks iOS for it
itself, once the user allows notifications:

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)
{	Personyze.setPushToken(deviceToken)
}
```

Taps on a pushed notification go through `handleNotificationResponse` as above. The SDK registers the device with
Personyze for the current visitor, again after a login or a logout, and takes it off when the notifications are
turned off or the visitor is reset; once Personyze pushes to the device, the background check is rare. A push
that does not go is still shown at the app's next check.

iOS draws a pushed notification by itself: title, text, sound. For its picture and buttons, and for the campaign
to count it shown before it is tapped, add a Notification Service Extension (File › New › Target › Notification
Service Extension) with this package's `PersonyzeNotificationService` library, its class Personyze's:

```swift
import PersonyzeNotificationService

class NotificationService: PersonyzeNotificationService
{
}
```

### Upgrading from 1.x

The first launch after the upgrade reads 1.x's state from `UserDefaults` and deletes it: the visitor, their
session, their recent sessions and the actions they closed. Nothing to do in the app.

## What is where

| | |
| --- | --- |
| `Personyze.swift`, `PersonyzeClient.swift`, `PersonyzeEvents.swift`, `PersonyzeConfig.swift` | The API |
| `PersonyzeResult.swift`, `PersonyzeNotification.swift`, `PersonyzeClick.swift` | What a decision, an action, a notification, an A/B verdict and a tap look like to the app |
| `Core/Engine.swift` | The state machine: the queue, one tracker request at a time, what is kept or dropped when a request fails, templates, notifications, the 1.x upgrade |
| `Core/EngineState.swift` | `state.json`, `outbox.json`, `metadata.json` - read by newer versions too |
| `Core/Session.swift` | The session string, the 90-minute expiry, the visitor id the server makes of `user_id` |
| `Core/Wire.swift` | The tracker request and response, field for field as the guide documents them |
| `Core/Commands.swift`, `Core/Endpoints.swift` | Commands and `/rest` paths, refusing what the server would refuse |
| `Core/Transport.swift`, `Core/RestClient.swift` | URLSession under one deadline per call, at most one retry, whether a failed request may have been sent |
| `Core/Store.swift` | Atomic files for state and the event queue |
| `System/ClientEnvironment.swift` | What a client is built from: the device, the disk, the network, notifications |
| `iOS/IOSEnvironment.swift` | The device from UIKit, the network, the background send and refresh, the app's foreground and background |
| `iOS/PersonyzeActionView.swift` | The web view an action renders in, and `PersonyzeActionContent` for SwiftUI |
| `iOS/UserNotificationPresenter.swift` | Notifications, and `Personyze.handleNotificationResponse` |
| `Sources/PersonyzeNotificationService` | The library for the app's Notification Service Extension: a pushed notification's picture, buttons and "shown" report; also how the SDK draws its own |
| `Apple/PersonyzeModel.swift` | The decision and the visitor as an `ObservableObject` |
| `Core/LegacyDefaults.swift` | 1.x's state in `UserDefaults`, read once on upgrade |

`Tests/PersonyzeTests/EngineTests.swift` is the Android SDK's `EngineTest`, test for test.

## Requirements

iOS 15 or later. Xcode 26 or later (Swift 6.2) - what the App Store requires of every upload since April 2026.

## Develop

The engine (`Sources/Personyze/Core`) imports nothing but Foundation, so it builds and tests on Linux as well as
on a Mac. The iOS layer (`Sources/Personyze/iOS`) is compiled only for iOS; CI builds and tests it on a simulator.

```bash
swift build
swift test
```

On Linux, install Swift with [swiftly](https://www.swift.org/install/linux/). No Xcode, no Mac.

CI (`.github/workflows/ci.yml`) runs the tests on Linux and on macOS, builds the package for iOS, and runs the
tests on an iOS Simulator.

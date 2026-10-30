# Personyze iOS SDK 2.0

**Work in progress.** A rewrite of the 1.x SDK (a single `PersonyzeIosSdk.swift` dragged into an Xcode project) as
a Swift package, following the Android SDK 2.0 decision for decision: the same wire, the same session rules, the
same failure handling. 1.x stays available on this repository's `v1` branch.

The API is in place; the iOS layer is not yet - rendering actions in a web view, showing notifications, the
device's screen and type, the background send, the upgrade from 1.x. Until it is, decisions and events work, and
an app renders actions itself.

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
and visitor are also streams, for a view that follows them: `for await result in Personyze.results { ... }`.

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

`Tests/PersonyzeTests/EngineTests.swift` is the Android SDK's `EngineTest`, test for test.

## Requirements

iOS 15 or later. Xcode 26 or later (Swift 6.2) - what the App Store requires of every upload since April 2026.

## Develop

The engine (`Sources/Personyze/Core`) imports nothing but Foundation, so it builds and tests on Linux as well as
on a Mac. The iOS layer will be compiled only where UIKit exists.

```bash
swift build
swift test
```

On Linux, install Swift with [swiftly](https://www.swift.org/install/linux/). No Xcode, no Mac.

CI (`.github/workflows/ci.yml`) runs the tests on Linux and on macOS, builds the package for iOS, and runs the
tests on an iOS Simulator.

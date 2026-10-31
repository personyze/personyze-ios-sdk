// swift-tools-version: 6.2
// Xcode 26: the App Store has accepted nothing older since 2026-04-28, so no app that can ship is held back.
// 6.2 brings `nonisolated(nonsending)`, which `navigate` needs to run the app's closure on the app's actor.
import PackageDescription

let package = Package(
	name: "Personyze",
	platforms: [
		.iOS(.v15),
		// The engine is platform-free; macOS is declared so its tests run on a Mac as they do on Linux.
		.macOS(.v12),
	],
	products: [
		.library(name: "Personyze", targets: ["Personyze"]),
		// For the app's Notification Service Extension: a pushed notification's picture, buttons and "shown" report. Small,
		// and with nothing of the SDK's own in it - an extension has little memory and no app around it.
		.library(name: "PersonyzeNotificationService", targets: ["PersonyzeNotificationService"]),
	],
	targets: [
		.target(name: "Personyze", dependencies: ["PersonyzeNotificationService"]),
		.target(name: "PersonyzeNotificationService"),
		.testTarget(name: "PersonyzeTests", dependencies: ["Personyze", "PersonyzeNotificationService"]),
	]
)

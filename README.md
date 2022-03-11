# personyze-ios-sdk

This library allows you to use [Personyze system](https://www.personyze.com/) on iOS devices.

See [reference manual](./doc/README.md).

See also:

- [Personyze Android SDK](https://github.com/personyze/personyzeandroidsdk)
- [Personyze Android SDK Demo app](https://github.com/personyze/personyzeandroidsdk-demo)
- Personyze iOS SDK
- [Personyze iOS SDK Demo app](https://github.com/personyze/personyze-ios-sdk-demo)

## How to get started with the Personyze iOS SDK

This is as simple as to download the SDK archive from [here](https://github.com/personyze/personyze-ios-sdk/archive/refs/heads/main.zip). Extract it. Then create a new xcode project, or open an existing one, and drag the PersonyzeIosSdk.swift file from Finder to the “Project Navigator” panel on the left of the xcode screen, where other project files are.

The SDK is ready. To feel like it works add the following swift code to viewDidLoad() of your ViewController, or somewhere else:

```swift
do
{   let tracker = try PersonyzeTracker(apiKey: "0011223344556677889900112233445566778899")
    tracker.navigate(documentName: "ViewController")
    tracker.done()
}
catch
{   print(error)
}
```

Use your API key instead of “0011223344556677889900112233445566778899”. API keys for your account can be found on Personyze in the [“Settings” → “Integrations” page](https://personyze.com/site/tracker/condition#cat=Account%20settings%2FMain%20settings%2FIntegrations). You need the full-featured key.

The code above logs a navigation to page called “ViewController”.

You can look up this request on Personyze [Live Visits Dashboard](https://personyze.com/site/tracker/condition#cat=Dashboard%2FReal%20time%20visitors). In filters, select “Pages” → “only containing” → “ViewController”.

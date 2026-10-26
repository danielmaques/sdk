# Pushify iOS SDK

The Pushify Swift package uses StoreKit 2 and the first-party Pushify `/sdk/v1` API. It implements customer bootstrap/identity, attributes, offerings, StoreKit purchase and restore, transaction recovery, encrypted verified-customer caching, update streams, app events, virtual-currency spending and acquisition links.

> **Implementation status:** native purchase and customer flows exist, including localized StoreKit product details, encrypted last-known paywall/offering cache, published `pushify.paywall/v1` data, Customer Center configuration, and support ticket intake. The SwiftUI paywall renderer now handles icons, timelines, carousels, tabs, and countdowns as well as core text, package, purchase, restore, image, and navigation components. Rendering still differs from the editor in details; video/web view and several Customer Center actions remain unsupported. Store sandbox journeys and release-package validation are outstanding. This SDK is not production-ready yet.

## Requirements

- iOS 15 or newer.
- Swift 5.9 or newer.
- A Pushify **public app key** for your app.
- Associated Domains / Universal Links or a URL scheme configured by the host app if links should open the app. The SDK does not configure entitlements or app navigation.

## Add the Swift package

The package has not been released to a public registry yet. For local development in Xcode, add the repository's `ios/` directory as a local Swift package. In Swift Package Manager, choose **Add Local…** and select `sdk/ios` (or use **File → Add Package Dependencies… → Add Local…**).

Then import the module in your app:

```swift
import PushifySDK
```

## Put the key in the app configuration

Add `PUSHIFY_PUBLIC_APP_KEY` to your app's `.xcconfig` and expose it through the target's `Info.plist` build settings. This is a public client key; do not put a server secret here.

```text
// AppConfig.xcconfig
PUSHIFY_PUBLIC_APP_KEY = pushify_public_app_key
```

Add `PUSHIFY_PUBLIC_APP_KEY` to the app target's `Info.plist` with value `$(PUSHIFY_PUBLIC_APP_KEY)` so the build setting is available at runtime.

Create the resolver once at the app composition root (your `App` type or dependency container):

```swift
private func makePushifyLinks() -> PushifyAcquisitionLinks {
    let key = Bundle.main.object(forInfoDictionaryKey: "PUSHIFY_PUBLIC_APP_KEY") as? String ?? ""
    do {
        return try PushifyAcquisitionLinks(publicApiKey: key)
    } catch {
        fatalError("Check PUSHIFY_PUBLIC_APP_KEY in the app configuration: \(error)")
    }
}
```

Configure purchases at the same app composition root:

```swift
let purchases = try await PushifyPurchases.configure(apiKey: key)
let customer = try await purchases.customerInfo()
let offerings = try await purchases.offerings()

if let offering = offerings.offerings.first, let paywall = offering.paywall {
    // Embed this in a SwiftUI sheet or navigation destination.
    let paywallView = PushifyPaywallView(document: paywall, offering: offering, purchases: purchases)
}

if let offering = offerings.offerings.first, let paywall = offering.paywall {
    // Present PushifyPaywallView in your navigation or sheet.
    let view = PushifyPaywallView(document: paywall, offering: offering, purchases: purchases)
}

if let package = offerings.offerings.first?.packages.first {
    switch try await purchases.purchase(packageID: package.id) {
    case .purchased(let customer):
        print(customer.entitlements.active.map(\.key))
    case .pending, .cancelled:
        break
    }
}
```

`configure` starts StoreKit transaction recovery and returns a client even when the initial network is unavailable. `customerInfo()` and `offerings()` perform fresh requests and report their errors. `cachedCustomerInfo()` is the last server-verified snapshot stored on device.

## Connect Universal Links

In the app target's **Signing & Capabilities**, enable **Associated Domains** and add `applinks:links.example.com`, replacing the example with the actual link domain shown in your Pushify project. The domain must host the Apple App Site Association file for your app. The SDK does not modify entitlements or URL callbacks.

## Handle direct app links

Call `resolve(url:appUserID:)` with the URL delivered by iOS. The helper extracts and resolves a Pushify token in one call and returns `nil` for other URLs. The app owns URL delivery and navigation, including handling links on cold launch and while already open.

```swift
import PushifySDK

let acquisitionLinks = makePushifyLinks() // create once in the app root

func handleIncomingURL(_ url: URL) async {
    do {
        guard let link = try await acquisitionLinks.resolve(
            url: url,
            appUserID: currentPushifyAppUserID() // Pass nil before identity is known.
        ) else { return }

        // Validate the destination against the routes supported by your app.
        await MainActor.run {
            appRouter.open(destination: link.destination, campaign: link.campaign)
        }
    } catch {
        // Keep normal app navigation available if resolution fails.
        await MainActor.run { appRouter.showLinkFallback() }
    }
}
```

Call `handleIncomingURL(_:)` from your SwiftUI `.onOpenURL` handler, UIKit scene delegate, or the URL callback used by your app. The resolver returns data; it does not invoke the app router.

In a SwiftUI app, keep one resolver on your `App` type and attach this handler at the root:

```swift
WindowGroup {
    RootView()
        .onOpenURL { url in
            Task { await handleIncomingURL(url) }
        }
}
```

For UIKit, call the same method from your existing scene / application URL callback. No additional URL listener is needed.

## Read an iOS deferred token

iOS does not provide a general install-referrer API equivalent for every install path. This preview supports a **user-initiated pasteboard handoff** only. Explain to the user why the app is checking for a Pushify link, then call the method in response to that action. iOS may display its pasteboard privacy prompt.

```swift
@MainActor
func userTappedContinueFromCampaign() async {
    do {
        guard let link = try await acquisitionLinks.resolveDeferredPasteboard(
            appUserID: currentPushifyAppUserID()
        ) else { showDefaultOnboarding(); return }
        appRouter.open(destination: link.destination, campaign: link.campaign)
    } catch {
        showDefaultOnboarding()
    }
}
```

The method accepts only a correctly formatted `rdit_` token and clears the pasteboard after consuming it. It does not poll the clipboard and does not read or clear unrelated clipboard contents.

## Resolution response

`PushifyAcquisitionLink` includes the server's `status`, `linkId`, `name`, `slug`, `destination`, `appScheme`, `campaign`, and `attributed` fields. The `object` field is also decoded when present.

For common flows, use `resolve(url:appUserID:)` for an incoming URL and `resolveDeferredPasteboard(appUserID:)` from a user action. Both return an optional link, so URLs without a Pushify token and unavailable deferred tokens do not need exception-based control flow. Use `resolve(_:appUserID:)` when your app already has the opaque token.

Pass the same app user ID used by your Pushify customer identity when it is known. `appUserID` is optional, so resolution can happen before login. The SDK does not create an artificial customer for anonymous installs. Handle `AcquisitionLinkError` and network/decoding errors so a failed attribution lookup does not block the app.

## Errors and security

- The API base URL must be HTTPS. The supported service is Pushify Cloud.
- Invalid token syntax is rejected locally; HTTP and decoding failures throw errors.
- Never log the public key or raw link token. Validate destinations against the routes your app supports before navigating.
- The public app key belongs in the app; never include a server secret in the application bundle.

## Current limitations

- The native renderer covers text, package selection, purchase, restore, image, icon, timeline, carousel, tabs, countdown and screen navigation. Carousel timing, editor styling/localization details, video and web-view designs still need implementation or parity work.

- The app must forward Universal Links / custom URL callbacks to the SDK helper. Automatic lifecycle capture and pending-link storage are not implemented.
- Deferred capture uses an explicit clipboard action and may show a system privacy prompt. It cannot guarantee post-install recovery for every user or distribution path.
- Paywall documents and Customer Center configuration are available, but native screens and store-management actions are not implemented. Offering products include localized StoreKit display price and currency data.
- StoreKit sandbox journeys, accessibility QA and release archive validation remain outstanding. Do not ship this package for production purchase processing yet.
- The Swift package is not published yet; add it locally during development.

For the shared attribution contract and privacy behavior, see [Acquisition links in Pushify SDKs](../docs/acquisition-links.md). For planned full SDK scope, see the [SDK PRD](../../prd/sdks/PRD.md).

## Build

```sh
xcodebuild -scheme PushifySDK -destination 'generic/platform=iOS Simulator' build
```

# Pushify iOS SDK

The Pushify Swift package currently provides acquisition-link token extraction and resolution. It can parse a direct token from an incoming app URL, optionally read the Pushify deferred token from the pasteboard after your app explains that action to the user, and exchange a token with the Pushify API.

> **Preview:** purchases, customer identity, offerings, entitlements, restore, and native paywall UI are not implemented. Do not use this preview to process production purchases.

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

## Resolve a direct app link

Create the resolver once with your public app key. When your app receives a URL, extract the `rdt` token and resolve it. The app owns URL delivery and navigation, including handling links on cold launch and while already open.

```swift
import PushifySDK

let acquisitionLinks = try PushifyAcquisitionLinks(
    publicApiKey: PushifyConfiguration.publicAppKey
)

func handleIncomingURL(_ url: URL) async {
    guard let token = acquisitionLinks.token(from: url) else { return }

    do {
        let link = try await acquisitionLinks.resolve(
            token,
            appUserID: currentPushifyAppUserID() // Pass nil before identity is known.
        )

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

## Read an iOS deferred token

iOS does not provide a general install-referrer API equivalent for every install path. This preview supports a **user-initiated pasteboard handoff** only. Explain to the user why the app is checking for a Pushify link, then call the method in response to that action. iOS may display its pasteboard privacy prompt.

```swift
@MainActor
func userTappedContinueFromCampaign() async {
    guard let token = acquisitionLinks.consumeDeferredTokenFromPasteboard() else {
        showDefaultOnboarding()
        return
    }

    do {
        let link = try await acquisitionLinks.resolve(
            token,
            appUserID: currentPushifyAppUserID()
        )
        appRouter.open(destination: link.destination, campaign: link.campaign)
    } catch {
        showDefaultOnboarding()
    }
}
```

The method accepts only a correctly formatted `rdit_` token and clears the pasteboard after consuming it. It does not poll the clipboard and does not read or clear unrelated clipboard contents.

## Resolution response

`PushifyAcquisitionLink` includes the server's `status`, `linkId`, `name`, `slug`, `destination`, `appScheme`, `campaign`, and `attributed` fields. The `object` field is also decoded when present.

Pass the same app user ID used by your Pushify customer identity when it is known. `appUserID` is optional, so resolution can happen before login. The SDK does not create an artificial customer for anonymous installs. Handle `AcquisitionLinkError` and network/decoding errors so a failed attribution lookup does not block the app.

## Errors and security

- The API base URL must be HTTPS. `apiBaseURL` may point to your compatible Pushify deployment.
- Invalid token syntax is rejected locally; HTTP and decoding failures throw errors.
- Never log the public key or raw link token. Validate destinations against the routes your app supports before navigating.
- The public app key belongs in the app; never include a server secret in the application bundle.

## Current limitations

- The app must forward Universal Links / custom URL callbacks to the SDK helper. Automatic lifecycle capture and pending-link storage are not implemented.
- Deferred capture uses an explicit clipboard action and may show a system privacy prompt. It cannot guarantee post-install recovery for every user or distribution path.
- Purchases, customer identity, offerings, entitlements, restore, paywalls and complete lifecycle integration are not implemented.
- The Swift package is not published yet; add it locally during development.

For the shared attribution contract and privacy behavior, see [Acquisition links in Pushify SDKs](../docs/acquisition-links.md). For planned full SDK scope, see the [SDK PRD](../../prd/sdks/PRD.md).

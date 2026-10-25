# Pushify Android SDK

The Pushify Android package is an original Kotlin library for resolving Pushify acquisition links. It can extract a direct token from an incoming URL, read a deferred token delivered by Google Play Install Referrer, and exchange either token with the Pushify API.

> **Preview:** the current package only implements acquisition-link helpers. Purchases, customer identity, offerings, entitlements, restore, and paywall UI are not implemented. Do not use this preview to process production purchases.

## Requirements

- Android API 23 or newer.
- Kotlin and Android Gradle Plugin versions supported by your app.
- A Pushify **public app key** for the app in your Pushify project.
- HTTPS App Links / intent-filter configuration in your app if you want Android to open your app from a web link. The SDK does not configure your domain or navigation routes.

## Add the library

The package has not been published to Maven Central yet. For local development, check out this repository and include `android/pushify` as a Gradle project. In the host app's `settings.gradle.kts`:

```kotlin
include(":pushify")
project(":pushify").projectDir = file("../pushify-sdk/android/pushify")
```

Then add it to the app module's `build.gradle.kts`:

```kotlin
dependencies {
    implementation(project(":pushify"))
}
```

The library manifest declares the `INTERNET` permission and the module brings in Google Play Install Referrer. Your host app remains responsible for Android App Links, intent filters and dispatching incoming URLs.

## Resolve a direct app link

Pass the incoming URL to `tokenFromUrl`. The helper returns a token only when it finds a valid `rdt` query parameter. Resolve it with the public app key and, if already known, the same app user ID used by your purchase integration:

```kotlin
import app.pushify.sdk.AcquisitionLinks

class MainActivity : AppCompatActivity() {
    private val acquisitionLinks by lazy {
        AcquisitionLinks(publicApiKey = BuildConfig.PUSHIFY_PUBLIC_API_KEY)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        intent?.data?.toString()?.let(::handlePushifyUrl)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.toString()?.let(::handlePushifyUrl)
    }

    private fun handlePushifyUrl(url: String) {
        val token = acquisitionLinks.tokenFromUrl(url) ?: return
        acquisitionLinks.resolve(token, appUserId = currentPushifyAppUserId()) { result ->
            result.onSuccess { link ->
                // Validate the destination against your app's routing policy.
                // Then navigate using your app's own navigation framework.
                openDestination(link.destination, link.campaign)
            }.onFailure { error ->
                // Keep the app usable if the network or token resolution fails.
                showLinkFallback(error)
            }
        }
    }
}
```

`resolve` performs its HTTP request on a background executor and invokes its completion on Android's main thread. Handle the `Result` and avoid blocking the UI. The SDK returns the destination; it does not navigate automatically.

## Read a deferred Google Play token

Call `deferredToken` after app startup. Google Play Install Referrer may return `null` when the install did not come through a supported Play referrer or the referrer is unavailable:

```kotlin
acquisitionLinks.deferredToken(applicationContext) { token ->
    if (token == null) return@deferredToken

    acquisitionLinks.resolve(token, appUserId = currentPushifyAppUserId()) { result ->
        result.onSuccess { link ->
            openDestination(link.destination, link.campaign)
        }.onFailure(::reportLinkResolutionError)
    }
}
```

Use the documented Store listing / Install Referrer setup for your distribution path. This library reads the opaque `rdit` token; it does not guarantee that every store or installation flow can preserve it.

## Resolution response

`AcquisitionLink` contains:

| Property | Meaning |
|---|---|
| `status` | Server resolution / attribution status. |
| `linkId`, `name`, `slug` | Link metadata. |
| `destination` | The configured in-app destination. |
| `appScheme` | The app scheme configured for the link. |
| `campaign` | Campaign values configured for the link. |
| `attributed` | Whether the server associated this resolution with a customer. |

Pass `appUserId` only when you have the actual app user ID. The parameter is optional so a link can be resolved before sign-in. Follow your identity flow and resolve/associate again when the user becomes known if required by your integration. Do not invent a customer ID for anonymous installs.

## Errors and security

- The API URL must use HTTPS. `apiBaseUrl` can point to a compatible Pushify server in development or self-hosted deployments, but must remain HTTPS.
- Invalid token syntax is rejected before making a request. HTTP, decoding and connectivity failures are returned through `Result.failure`.
- Never log the public key or raw link token. Treat destinations as untrusted input and allow only routes your app recognizes.
- The public app key is intended for client apps; do not put a server secret in the APK.

## Current limitations

- The library does not configure Android App Links, receive links automatically, or navigate to screens.
- Deferred-token retrieval uses Google Play Install Referrer. Other stores may require a different supported handoff.
- Customer identity, purchase / restore flows, entitlement state, paywalls and full SDK lifecycle integration are not implemented.
- This package is not published yet; install from the source workspace during development.

For the shared attribution contract and privacy behavior, see [Acquisition links in Pushify SDKs](../docs/acquisition-links.md). For planned full SDK scope, see the [SDK PRD](../../prd/sdks/PRD.md).

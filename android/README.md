# Pushify Android SDK

The Pushify Android package is an original Kotlin library using Google Play Billing and the Pushify `/sdk/v1` API. It currently implements customer bootstrap and identity, attributes, offering/package lookup, purchase flow, server transaction sync, purchase acknowledge/consume after server acceptance, and restore/reconciliation. It also contains acquisition-link helpers.

> **Implementation status:** this package is not production-ready. Its Android build has not yet passed in this checkout, and localized product presentation, offline cache, listener APIs, paywalls, and sandbox journeys remain in progress.

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

## Configure once in your application class

Put the public app key in your app's build configuration (for example, a `BuildConfig` field) and create one resolver in the Android `Application` class. This is the only SDK initialization point:

In the app module's `build.gradle.kts`, expose the public key as a build config field. Load it from a local Gradle property or CI variable rather than committing environment-specific values:

```kotlin
android {
    buildFeatures { buildConfig = true }
    defaultConfig {
        val pushifyKey = providers.gradleProperty("PUSHIFY_PUBLIC_APP_KEY").orElse("").get()
        buildConfigField("String", "PUSHIFY_PUBLIC_APP_KEY", "\"$pushifyKey\"")
    }
}
```

```kotlin
import android.app.Application
import app.pushify.sdk.PushifyPurchases

class ExampleApplication : Application() {
    lateinit var pushifyPurchases: PushifyPurchases
        private set

    override fun onCreate() {
        super.onCreate()
        pushifyPurchases = PushifyPurchases(
            context = this,
            publicApiKey = BuildConfig.PUSHIFY_PUBLIC_APP_KEY,
        )
        pushifyPurchases.configure { result ->
            result.onSuccess { customer -> /* use server-verified state */ }
        }
    }
}
```

The acquisition-link resolver can be initialized alongside the purchases client when your app uses Pushify app links.

## Purchase and restore

Call `offerings` to load package IDs from the dashboard catalog. Then initiate the native Google Play sheet from an Activity:

```kotlin
pushifyPurchases.offerings { result ->
    val packageId = result.getOrThrow().getJSONArray("offerings")
        .getJSONObject(0).getJSONArray("packages").getJSONObject(0).getString("id")
    pushifyPurchases.purchase(this, packageId) { purchase ->
        purchase.onSuccess { outcome ->
            when (outcome) {
                is PushifyPurchases.PurchaseOutcome.Purchased -> { /* entitlements are server-verified */ }
                PushifyPurchases.PurchaseOutcome.Pending -> { /* wait for Google Play approval */ }
                PushifyPurchases.PurchaseOutcome.Cancelled -> Unit
            }
        }
    }
}
pushifyPurchases.restorePurchases { result -> /* refreshed customer snapshot */ }
```

The SDK syncs the purchase token before acknowledging or consuming it. A network failure leaves the purchase available for retry during restore or the next SDK startup.

Register the class in `AndroidManifest.xml`:

```xml
<application
    android:name=".ExampleApplication"
    ...>
</application>
```

## Connect your app links

The SDK does not own Android navigation or your web domain. Add an App Links intent filter to the Activity that handles your routes and replace `links.example.com` with the link domain shown in your Pushify project. Host the matching `assetlinks.json` for your Android application ID and signing certificate so Android can verify the domain.

```xml
<activity android:name=".MainActivity" android:exported="true">
    <intent-filter android:autoVerify="true">
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="https" android:host="links.example.com" />
    </intent-filter>
</activity>
```

## Handle direct links

Pass the incoming URL to `resolveUrl`. If the URL is not a Pushify link, it returns `false` and you can continue normal routing. The resolver is reused from your `Application` class:

```kotlin
import android.content.Intent
import androidx.appcompat.app.AppCompatActivity
import app.pushify.sdk.AcquisitionLinks
import app.pushify.sdk.NoDeferredAcquisitionLinkException

class MainActivity : AppCompatActivity() {
    private val pushifyLinks: AcquisitionLinks
        get() = (application as ExampleApplication).pushifyLinks

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        intent?.data?.toString()?.let(::handlePushifyUrl)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.toString()?.let(::handlePushifyUrl)
    }

    private fun handlePushifyUrl(url: String) {
        val handled = pushifyLinks.resolveUrl(
            url = url,
            appUserId = currentPushifyAppUserId(),
        ) { result ->
            result.onSuccess { link ->
                // Validate the destination against your app's routing policy.
                // Then navigate using your app's own navigation framework.
                openDestination(link.destination, link.campaign)
            }.onFailure { error ->
                // Keep the app usable if the network or token resolution fails.
                showLinkFallback(error)
            }
        }
        if (!handled) continueNormalRouting(url)
    }
}
```

`resolveUrl` extracts and resolves the token in one call. The HTTP request runs on a background executor and its completion runs on Android's main thread. If the URL is not a Pushify link, the method returns `false`, so your normal router can handle it. The SDK returns the destination; it does not navigate automatically.

## Read a deferred Google Play token

Call `resolveDeferred` after app startup if your onboarding flow should check the Google Play Install Referrer. If no supported token is present, the callback receives `NoDeferredAcquisitionLinkException`:

```kotlin
pushifyLinks.resolveDeferred(
    context = applicationContext,
    appUserId = currentPushifyAppUserId(),
) { result ->
    result.onSuccess { link -> openDestination(link.destination, link.campaign) }
        .onFailure { error ->
            if (error !is NoDeferredAcquisitionLinkException) {
                reportLinkResolutionError(error)
            }
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

For common flows, use `resolveUrl(url, appUserId, completion)` for direct app links and `resolveDeferred(context, appUserId, completion)` for the Google Play handoff. Lower-level `tokenFromUrl`, `deferredToken`, and `resolve` methods remain available for custom flows.

`resolveUrl` returns whether it accepted a Pushify token; resolution success or failure is delivered exactly once through the callback. `resolveDeferred` reports a missing token with `NoDeferredAcquisitionLinkException` and reports network / response errors through `Result.failure`.

Pass `appUserId` only when you have the actual app user ID. The parameter is optional so a link can be resolved before sign-in. Follow your identity flow and resolve/associate again when the user becomes known if required by your integration. Do not invent a customer ID for anonymous installs.

## Errors and security

- The API URL must use HTTPS. `apiBaseUrl` can point to a compatible Pushify server in development or self-hosted deployments, but must remain HTTPS.
- Invalid token syntax is rejected before making a request. HTTP, decoding and connectivity failures are returned through `Result.failure`.
- Never log the public key or raw link token. Treat destinations as untrusted input and allow only routes your app recognizes.
- The public app key is intended for client apps; do not put a server secret in the APK.

## Current limitations

- The library does not configure Android App Links or navigate to screens; the host Activity forwards its incoming URLs to `resolveUrl`.
- Deferred-token retrieval uses Google Play Install Referrer. Other stores may require a different supported handoff.
- Customer identity, purchase / restore flows, entitlement state, paywalls and full SDK lifecycle integration are not implemented.
- This package is not published yet; install from the source workspace during development.

For the shared attribution contract and privacy behavior, see [Acquisition links in Pushify SDKs](../docs/acquisition-links.md). For planned full SDK scope, see the [SDK PRD](../../prd/sdks/PRD.md).

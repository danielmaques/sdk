# `pushify_purchases` for Flutter

The Flutter package exposes the first-party purchase foundation through Android and iOS plugins: customer bootstrap/identity, attributes, offerings, native purchases and restore, verified transaction sync, encrypted customer snapshots, update streams, app events and idempotent virtual-currency spending. Acquisition links are included as well.

> **Implementation status:** the Dart API and Flutter widget expose published `pushify.paywall/v1` offerings, core paywall components, localized Customer Center configuration and support ticket intake through the native plugins. Advanced editor components, Customer Center actions, store sandbox journeys, plugin migration warnings and release validation remain outstanding. The package is not production-ready and has not been published.

## Requirements

- Flutter 3.22 or newer and Dart 3.4 or newer.
- Android API 23 or newer / iOS 15 or newer for the native plugin portions.
- A Pushify **public app key**.
- App Links / Universal Links or a URL scheme configured by the host app if incoming web links should open the app.

## Add the package

The package name is a planned name and registry availability is not confirmed. Until the first release, use the local path in your app's `pubspec.yaml`:

```yaml
dependencies:
  pushify_purchases:
    path: ../pushify-sdk/flutter
```

Then run `flutter pub get`. The Android and iOS plugin code is included by Flutter's plugin tooling. Your app must still configure the platform link domains, URL schemes and route delivery.

If the editor reports that `package:flutter/...` or `package:http/...` cannot be found, run `flutter pub get` from `sdk/flutter` for standalone development, or from the host app after adding this package as a path dependency. Then restart the Dart analysis server if the diagnostics remain cached.

## Configure once in `main.dart`

Pass the public key at app startup, then provide the configured object to your router or link-handling service. Flutter's `--dart-define` keeps environment-specific public configuration out of source control; the key is public and must not be treated as a server secret.

```dart
// lib/main.dart
import 'package:pushify_purchases/pushify_purchases.dart';

void main() {
  const publicKey = String.fromEnvironment('PUSHIFY_PUBLIC_APP_KEY');
  final purchases = PushifyPurchases(publicApiKey: publicKey);
  runApp(MyApp(purchases: purchases));
}
```

Run with `--dart-define=PUSHIFY_PUBLIC_APP_KEY=pushify_public_app_key`, then call `await purchases.configure()` once before purchase APIs. Keep the instance in your app-level dependency provider.

```dart
final snapshot = await purchases.customerInfo();
final offerings = await purchases.offerings();
final items = (offerings['offerings'] as List).cast<Map<String, Object?>>();
final currentId = offerings['current_offering_id'];
final current = items.firstWhere((item) => item['id'] == currentId, orElse: () => <String, Object?>{});
final paywall = current['paywall'];
if (current.isNotEmpty && paywall is Map<String, Object?>) {
  // Return this widget from a route or show it in a modal.
  PushifyPaywall(document: paywall, offering: current, purchases: purchases);
}

final updates = purchases.customerInfoUpdates.listen((customer) {
  // Refresh access UI from verified customer state.
});
```

## Connect app links

Replace the example domain with the link domain shown in your Pushify project.

For Android, add an App Links intent filter to the Activity that owns navigation and serve the matching `assetlinks.json`:

```xml
<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="https" android:host="links.example.com" />
</intent-filter>
```

For iOS, enable **Associated Domains** for the Runner target and add `applinks:links.example.com`; serve the corresponding Apple App Site Association file. Use your existing Flutter router/deep-link integration to forward both the initial URI and runtime URI events. The SDK does not take over Flutter navigation.

## Handle direct links

Call `handle` from the incoming-URI callback your router already uses. It captures and resolves a valid direct link in one call, returning `null` for a URL without a Pushify token.

```dart
// Inject pushifyLinks from main.dart into your router / link service.

Future<void> handleIncomingUri(Uri uri, PushifyAcquisitionLinks pushifyLinks) async {
  try {
    final link = await pushifyLinks.handle(
      uri,
      appUserId: currentPushifyAppUserId(), // null before login
    );
    if (link == null) return;

    // Validate the destination against routes supported by your app.
    appRouter.open(link.destination, extra: link.campaign);
  } on PushifyAcquisitionLinkException catch (error) {
    appLogger.warning('Could not resolve Pushify link', error);
    showLinkFallback();
  }
}
```

Call `handleIncomingUri` for the initial link and every link event delivered by your router. This preview does not subscribe to Flutter lifecycle events or provide an incoming-link stream.

## Read a deferred install token

On Android, `readDeferredToken()` checks the Install Referrer supplied by Google Play. On iOS, it reads and clears a matching Pushify `rdit_` token from the pasteboard. Because iOS may show a privacy prompt, call this only after the app has explained the action and the user chose to continue.

```dart
Future<void> continueFromCampaign(PushifyAcquisitionLinks pushifyLinks) async {
  try {
    final link = await pushifyLinks.resolveDeferredLink(
      appUserId: currentPushifyAppUserId(),
    );
    if (link == null) {
      showDefaultOnboarding();
      return;
    }

    appRouter.open(link.destination, extra: link.campaign);
  } on PushifyAcquisitionLinkException catch (error) {
    appLogger.warning('Could not resolve deferred Pushify link', error);
    showDefaultOnboarding();
  }
}
```

`readDeferredToken` stores the returned token as the pending token too. If you need to customize handling, call it directly and then use `resolve` or `getInitialLink`.

## API reference

- `PushifyAcquisitionLinks.capture(Uri)` returns `true` when it captured a valid direct token.
- `PushifyAcquisitionLinks.handle(Uri, {String? appUserId})` captures and resolves a direct URL in one call.
- `PushifyAcquisitionLinks.getInitialLink({String? appUserId})` resolves the pending token, or returns `null` if none was captured.
- `PushifyAcquisitionLinks.readDeferredToken()` returns a deferred token or `null` when the OS/store has none.
- `PushifyAcquisitionLinks.resolveDeferredLink({String? appUserId})` reads and resolves a deferred token in one call.
- `PushifyAcquisitionLinks.resolve(String, {String? appUserId})` resolves a token directly.
- `dispose()` closes the HTTP client created by this instance. If you pass a client, you retain ownership and must close it yourself. Do not use the resolver after disposal.
- `PushifyAcquisitionLink` exposes `linkId`, `name`, `slug`, `destination`, `appScheme`, `campaign`, `attributed`, and `status`.

`appUserId` is optional: resolve before login if needed, and use the same stable app user ID as your Pushify identity integration when known. The SDK does not create an artificial customer for anonymous users.

## Errors and security

- Use HTTPS for `apiBaseUrl`. The SDK connects to Pushify Cloud.
- Invalid token syntax and non-2xx server responses throw `PushifyAcquisitionLinkException`.
- Never log the public key or raw token. Validate the returned destination against your own navigation routes.
- The public app key is safe for client configuration; do not include a server secret in the Flutter bundle.
- An injected `http.Client` remains caller-owned and must be closed by the caller.

## Current limitations

- The app/router is responsible for delivering initial and runtime URLs to `handle` (or `capture`).
- Deferred recovery depends on platform behavior: Google Play Install Referrer on Android, user-initiated pasteboard access on iOS. No probabilistic matching is used.
- Paywall documents and Customer Center configuration are exposed as Pushify maps, but ready-made Flutter screens are not implemented. Offering data is enriched with localized StoreKit/Play product details.
- Apple/Google sandbox flows and Flutter plugin integration builds have not passed in this environment, so do not ship this package for production purchase processing yet.
- The package is not published; use a local path dependency until a version is released.

For the shared attribution contract and privacy behavior, see [Acquisition links in Pushify SDKs](../docs/acquisition-links.md). For planned full SDK scope, see the [SDK PRD](../../prd/sdks/PRD.md).

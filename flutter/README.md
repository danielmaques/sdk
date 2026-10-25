# `pushify_purchases` for Flutter

The Pushify Flutter package currently provides acquisition-link capture and resolution, plus a platform call to read a deferred token from Android Install Referrer or an explicit iOS pasteboard handoff.

> **Preview:** this package does not yet implement purchases, customer identity, offerings, entitlements, restore, full app lifecycle integration, or paywall widgets. It is not ready for production purchase processing and has not been published to pub.dev.

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

## Capture and resolve a direct link

`capture` stores a valid `rdt` token in this object in memory. Your app needs to pass both the initial URL and URLs received while running from its chosen deep-link handler. `getInitialLink` resolves the pending token with Pushify and clears it after successful resolution.

```dart
import 'package:pushify_purchases/pushify_purchases.dart';

final acquisitionLinks = PushifyAcquisitionLinks(
  publicApiKey: const String.fromEnvironment('PUSHIFY_PUBLIC_APP_KEY'),
);

Future<void> handleIncomingUri(Uri uri) async {
  if (!acquisitionLinks.capture(uri)) return;

  try {
    final link = await acquisitionLinks.getInitialLink(
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

Call `handleIncomingUri` for the initial link and every link event delivered by your deep-link setup. This preview does not subscribe to Flutter lifecycle events or provide an incoming-link stream.

## Read a deferred install token

On Android, `readDeferredToken()` checks the Install Referrer supplied by Google Play. On iOS, it reads and clears a matching Pushify `rdit_` token from the pasteboard. Because iOS may show a privacy prompt, call this only after the app has explained the action and the user chose to continue.

```dart
Future<void> continueFromCampaign() async {
  try {
    final token = await acquisitionLinks.readDeferredToken();
    if (token == null) {
      showDefaultOnboarding();
      return;
    }

    final link = await acquisitionLinks.resolve(
      token,
      appUserId: currentPushifyAppUserId(),
    );
    appRouter.open(link.destination, extra: link.campaign);
  } on PushifyAcquisitionLinkException catch (error) {
    appLogger.warning('Could not resolve deferred Pushify link', error);
    showDefaultOnboarding();
  }
}
```

`readDeferredToken` stores the returned token as the pending token too. If you prefer, call `getInitialLink` afterward instead of calling `resolve` yourself.

## API reference

- `PushifyAcquisitionLinks.capture(Uri)` returns `true` when it captured a valid direct token.
- `PushifyAcquisitionLinks.getInitialLink({String? appUserId})` resolves the pending token, or returns `null` if none was captured.
- `PushifyAcquisitionLinks.readDeferredToken()` returns a deferred token or `null` when the OS/store has none.
- `PushifyAcquisitionLinks.resolve(String, {String? appUserId})` resolves a token directly.
- `dispose()` closes the HTTP client created by this instance. If you pass a client, you retain ownership and must close it yourself. Do not use the resolver after disposal.
- `PushifyAcquisitionLink` exposes `linkId`, `name`, `slug`, `destination`, `appScheme`, `campaign`, `attributed`, and `status`.

`appUserId` is optional: resolve before login if needed, and use the same stable app user ID as your Pushify identity integration when known. The SDK does not create an artificial customer for anonymous users.

## Errors and security

- Use HTTPS for `apiBaseUrl`. A compatible self-hosted Pushify API can be configured there.
- Invalid token syntax and non-2xx server responses throw `PushifyAcquisitionLinkException`.
- Never log the public key or raw token. Validate the returned destination against your own navigation routes.
- The public app key is safe for client configuration; do not include a server secret in the Flutter bundle.
- An injected `http.Client` remains caller-owned and must be closed by the caller.

## Current limitations

- The app is responsible for delivering initial and runtime URLs to `capture`.
- Deferred recovery depends on platform behavior: Google Play Install Referrer on Android, user-initiated pasteboard access on iOS. No probabilistic matching is used.
- Purchase, restore, identity, entitlement and native paywall APIs are planned but absent from this preview.
- The package is not published; use a local path dependency until a version is released.

For the shared attribution contract and privacy behavior, see [Acquisition links in Pushify SDKs](../docs/acquisition-links.md). For planned full SDK scope, see the [SDK PRD](../../prd/sdks/PRD.md).

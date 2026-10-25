# `@pushify/purchases` for React Native

The React Native package exposes native StoreKit 2 and Google Play Billing through first-party iOS/Android modules. It implements customer bootstrap/identity, attributes, offerings, purchase and restore, verified transaction sync, encrypted customer snapshots, update events, app events, virtual-currency spends and acquisition links.

> **Implementation status:** StoreKit and Play Billing clients compile, and the TypeScript facade passes strict type checking with the React Native peer types. Full React Native host-app builds, dashboard paywall rendering, Customer Center, store sandbox journeys, and release validation remain outstanding. The package is not production-ready and has not been published to npm.

## Requirements

- React 18 or newer.
- React Native 0.74 or newer.
- iOS 15 or newer / Android API 23 or newer for the included native module.
- A Pushify **public app key**.
- App Links / Universal Links or a URL scheme configured by the host app.

## Add the package

The npm package is not released yet. During development, add the local package to your app's `package.json`:

```json
{
  "dependencies": {
    "@pushify/purchases": "file:../pushify-sdk/react-native"
  }
}
```

Install dependencies, run CocoaPods installation for iOS (for example, `npx pod-install`), and rebuild the native app. The package includes a React Native native module for reading deferred tokens. If your React Native setup does not autolink this local package, register `PushifyPurchasesPackage` in your Android host application according to your app's native package-registration pattern.

The host app is responsible for OS link association files, entitlements, intent filters and route handling.

## Configure once at app startup

Create one purchases client and one link resolver in an app-level module such as `src/pushify.ts`. Use your normal build-time configuration mechanism to provide the **public app key**. It is safe for client apps, but it is not a server secret.

```ts
// src/pushify.ts
import { PushifyAcquisitionLinks, PushifyPurchases } from '@pushify/purchases';
import { PUSHIFY_PUBLIC_APP_KEY } from './appConfig';

export const pushifyLinks = new PushifyAcquisitionLinks({
  publicApiKey: PUSHIFY_PUBLIC_APP_KEY,
});

export const pushifyPurchases = new PushifyPurchases({
  publicApiKey: PUSHIFY_PUBLIC_APP_KEY,
});
```

Call `await pushifyPurchases.configure()` once at application startup. Then load offerings and start native purchases with a package ID:

```ts
const customer = await pushifyPurchases.customerInfo();
const offeringSet = await pushifyPurchases.offerings();
const packageId = offeringSet.offerings[0]?.packages[0]?.id;
if (packageId) {
  const outcome = await pushifyPurchases.purchase(packageId);
  if (outcome.status === 'purchased') {
    // outcome.customerInfo contains server-verified access.
  }
}
```

## Connect app links

The host app handles domain verification and route delivery. Replace `links.example.com` with the link domain configured in your Pushify project.

- **Android:** add an `autoVerify` `VIEW` / `BROWSABLE` HTTPS intent filter to the Activity that owns navigation, then host the matching `assetlinks.json` for the application ID and signing certificate. React Native must deliver the initial URL and runtime `url` events.
- **iOS:** enable **Associated Domains** in the app target, add `applinks:links.example.com`, and host the matching Apple App Site Association file. React Native's `Linking` API then delivers initial and runtime URLs.

The SDK does not change your navigation container or register a competing URL listener for you.

## Handle and resolve incoming links

React Native delivers incoming URLs through `Linking`. Use the exported helper to parse the Pushify token and then resolve it. The SDK returns the configured destination and campaign data; your app validates and navigates to the destination.

```tsx
import { useEffect } from 'react';
import { Linking } from 'react-native';
import { pushifyLinks } from './pushify';

async function handleUrl(url: string) {
  try {
    const link = await pushifyLinks.handleUrl(
      url,
      getCurrentPushifyAppUserId(), // omit / pass undefined before identity is known
    );
    if (!link) return;
    appRouter.open(link.destination, { campaign: link.campaign });
  } catch (error) {
    showLinkFallback(error);
  }
}

export function PushifyLinkListener() {
  useEffect(() => {
    let active = true;

    void Linking.getInitialURL().then((url) => {
      if (active && url) void handleUrl(url);
    });
    const subscription = Linking.addEventListener('url', ({ url }) => {
      void handleUrl(url);
    });

    return () => {
      active = false;
      subscription.remove();
    };
  }, []);

  return null;
}
```

Mount `PushifyLinkListener` once near the root of the app. If your navigation container already handles `Linking`, call `pushifyLinks.handleUrl(url, currentAppUserId)` from that existing handler instead; do not register both paths for the same URL.

## Read a deferred install token

The native method reads Google Play Install Referrer on Android. On iOS it reads a matching Pushify token from the pasteboard and clears it. Call it only after explaining the action to the user; iOS may display a pasteboard privacy prompt.

```ts
import { pushifyLinks } from './pushify';

async function continueFromCampaign() {
  try {
    const link = await pushifyLinks.resolveDeferred(getCurrentPushifyAppUserId());
    if (!link) return showDefaultOnboarding();
    appRouter.open(link.destination, { campaign: link.campaign });
  } catch (error) {
    showDefaultOnboarding();
  }
}
```

The helper returns `undefined` when the native module is unavailable or there is no valid deferred token. It does not perform probabilistic install matching.

## API reference

- `acquisitionTokenFromUrl(url)` returns the direct `rdt` token or `undefined`.
- `PushifyAcquisitionLinks.handleUrl(url, appUserId?)` extracts and resolves a direct link in one call.
- `PushifyAcquisitionLinks.resolveDeferred(appUserId?)` reads and resolves a supported deferred handoff in one call.
- `resolveAcquisitionLink(token, options)` posts to `/sdk/v1/acquisition-links/resolve` using `publicApiKey`, optional `apiBaseUrl`, and optional `appUserId`.
- `readDeferredAcquisitionToken()` asks the native module for a deferred `rdit_` token.
- `PushifyAcquisitionLink` contains `status`, `link_id`, `name`, `slug`, `destination`, `app_scheme`, `campaign`, and `attributed`.

The optional `appUserId` should match the ID used by your Pushify identity integration. Resolution may happen before login; do not generate a fake customer ID just to resolve a token.

## Errors and security

- The API URL must use HTTPS and point to Pushify Cloud.
- Invalid tokens, network errors and non-success HTTP responses reject the promise.
- Never log the public key or raw token. Validate `destination` against routes supported by your app before navigating.
- The public app key is intended for client use. Never ship a server secret in the bundle.

## Current limitations

- Dashboard paywalls and Customer Center are not implemented. Native offerings include localized product details where the store returns them.
- iOS/Android sandbox purchase journeys and React Native host-app builds remain unverified, so do not ship this package for production purchase processing yet.
- Native deferred token handling depends on supported store/platform handoff. iOS uses an explicit pasteboard action; Android reads Google Play Install Referrer.
- The package is not published; use the local package path until a release is available.

For the shared attribution contract and privacy behavior, see [Acquisition links in Pushify SDKs](../docs/acquisition-links.md). For planned full SDK scope, see the [SDK PRD](../../prd/sdks/PRD.md).

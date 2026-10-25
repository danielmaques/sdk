# `@pushify/purchases` for React Native

The Pushify React Native package currently exposes helpers for extracting an acquisition token from an app URL, resolving it through Pushify, and requesting a deferred token from the native Android or iOS implementation.

> **Preview:** native purchases, customer identity, offerings, entitlements, restore, paywall components, and automatic pending-link lifecycle handling are not implemented. This package is not ready for production purchase processing and has not been published to npm.

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

## Handle and resolve incoming links

React Native delivers incoming URLs through `Linking`. Use the exported helper to parse the Pushify token and then resolve it. The SDK returns the configured destination and campaign data; your app validates and navigates to the destination.

```tsx
import { useEffect } from 'react';
import { Linking } from 'react-native';
import {
  acquisitionTokenFromUrl,
  resolveAcquisitionLink,
} from '@pushify/purchases';

const publicApiKey = 'pushify_public_app_key';

async function handleUrl(url: string) {
  const token = acquisitionTokenFromUrl(url);
  if (!token) return;

  try {
    const link = await resolveAcquisitionLink(token, {
      publicApiKey,
      appUserId: getCurrentPushifyAppUserId(), // omit before identity is known
    });
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

This example uses React Native's URL event delivery; adapt registration to your existing router if it already owns incoming links. Avoid processing the same URL twice when both your router and this listener receive it.

## Read a deferred install token

The native method reads Google Play Install Referrer on Android. On iOS it reads a matching Pushify token from the pasteboard and clears it. Call it only after explaining the action to the user; iOS may display a pasteboard privacy prompt.

```ts
import {
  readDeferredAcquisitionToken,
  resolveAcquisitionLink,
} from '@pushify/purchases';

async function continueFromCampaign() {
  try {
    const token = await readDeferredAcquisitionToken();
    if (!token) return showDefaultOnboarding();

    const link = await resolveAcquisitionLink(token, {
      publicApiKey,
      appUserId: getCurrentPushifyAppUserId(),
    });
    appRouter.open(link.destination, { campaign: link.campaign });
  } catch (error) {
    showDefaultOnboarding();
  }
}
```

The helper returns `undefined` when the native module is unavailable or there is no valid deferred token. It does not perform probabilistic install matching.

## API reference

- `acquisitionTokenFromUrl(url)` returns the direct `rdt` token or `undefined`.
- `resolveAcquisitionLink(token, options)` posts to `/v1/acquisition_links/resolve` using `publicApiKey`, optional `apiBaseUrl`, and optional `appUserId`.
- `readDeferredAcquisitionToken()` asks the native module for a deferred `rdit_` token.
- `PushifyAcquisitionLink` contains `status`, `link_id`, `name`, `slug`, `destination`, `app_scheme`, `campaign`, and `attributed`.

The optional `appUserId` should match the ID used by your Pushify identity integration. Resolution may happen before login; do not generate a fake customer ID just to resolve a token.

## Errors and security

- The API URL must use HTTPS. Configure `apiBaseUrl` only for a compatible Pushify deployment.
- Invalid tokens, network errors and non-success HTTP responses reject the promise.
- Never log the public key or raw token. Validate `destination` against routes supported by your app before navigating.
- The public app key is intended for client use. Never ship a server secret in the bundle.

## Current limitations

- This package currently implements helpers, not a full customer-facing purchase SDK.
- Native deferred token handling depends on supported store/platform handoff. iOS uses an explicit pasteboard action; Android reads Google Play Install Referrer.
- Purchase, restore, identity, entitlement and React Native paywall UI are not implemented.
- The package is not published; use the local package path until a release is available.

For the shared attribution contract and privacy behavior, see [Acquisition links in Pushify SDKs](../docs/acquisition-links.md). For planned full SDK scope, see the [SDK PRD](../../prd/sdks/PRD.md).

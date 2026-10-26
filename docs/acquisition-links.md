# Acquisition links in Pushify SDKs

Pushify acquisition links resolve opaque click tokens through the public app API. A host app owns navigation: the SDK returns the destination and campaign values but does not choose a screen or change partner-attribution fields.

## Direct app links

Configure one resolver at the app root, then pass incoming URLs to the platform's high-level handler: Android `resolveUrl`, iOS `resolve(url:)`, Flutter `handle(Uri)`, or React Native `handleUrl`. Each extracts and resolves the token in one call. The methods return `false`, `nil`, or `undefined` for URLs without a valid Pushify token. The app owns OS link delivery and navigation. Route to the returned `destination` only after validating it against the app's own navigation policy.

## Deferred links

- Android reads the `rdit` value from the Google Play Install Referrer. `resolveDeferred` reads and resolves it in one call. The value is opaque and expires after the backend's deferred-token window.
- iOS can read the `rdit_` clipboard value after an explicit call that the app makes with an explanatory user flow. The OS may display its pasteboard privacy prompt. Pushify SDKs never read unrelated clipboard content or poll the clipboard.
- iOS exposes `resolveDeferredPasteboard`; Flutter exposes `resolveDeferredLink`; React Native exposes `resolveDeferred`. If the platform returns no token, or the user denies clipboard access, the click remains unassigned and no installation is guessed from device attributes.

## Resolution contract

The client sends `POST /sdk/v1/acquisition-links/resolve` with `Authorization: Bearer <public-app-key>` and JSON `{ "token": "rdlt_...", "customer_id": "..." }`. `customer_id` is optional. A successful response includes a `link` object with `id`, `name`, `slug`, `destination`, `app_scheme`, `campaign`, `status`, and `attributed`. Direct and deferred resolution may be retried; the server controls token expiry and attribution.

Never log or persist raw tokens longer than required for resolution. Do not collect IP addresses or device fingerprints, and do not infer a match when a platform handoff is unavailable.

## Implementation status

The four source packages implement purchase, restore/sync, customer identity, entitlement snapshots, acquisition-link extraction/resolution, and their platform-specific deferred-token readers. Native library builds, Flutter analysis, the React Native TypeScript build, and npm/pub.dev archive dry-runs have passed. End-to-end acquisition attribution across all four sample hosts, store sandbox purchase journeys, and package release validation remain outstanding; the packages are still not production-ready and have not been published.

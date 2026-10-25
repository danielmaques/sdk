# Acquisition links in Pushify SDKs

Pushify acquisition links resolve opaque click tokens through the public app API. A host app owns navigation: the SDK returns the destination and campaign values but does not choose a screen or change partner-attribution fields.

## Direct app links

Configure one resolver at the app root, then pass incoming URLs to the platform's high-level handler: Android `resolveUrl`, iOS `resolve(url:)`, Flutter `handle(Uri)`, or React Native `handleUrl`. Each extracts and resolves the token in one call. The methods return `false`, `nil`, or `undefined` for URLs without a valid Pushify token. The app owns OS link delivery and navigation. Route to the returned `destination` only after validating it against the app's own navigation policy.

## Deferred links

- Android reads the `rdit` value from the Google Play Install Referrer. `resolveDeferred` reads and resolves it in one call. The value is opaque and expires after the backend's deferred-token window.
- iOS can read the `rdit_` clipboard value after an explicit call that the app makes with an explanatory user flow. The OS may display its pasteboard privacy prompt. Pushify SDKs never read unrelated clipboard content or poll the clipboard.
- iOS exposes `resolveDeferredPasteboard`; Flutter exposes `resolveDeferredLink`; React Native exposes `resolveDeferred`. If the platform returns no token, or the user denies clipboard access, the click remains unassigned and no installation is guessed from device attributes.

## Resolution contract

The client sends `POST /v1/acquisition_links/resolve` with `Authorization: Bearer <public-app-key>` and JSON `{ "token": "rdlt_...", "app_user_id": "..." }`. `app_user_id` is optional. A successful response includes `status`, `link_id`, `name`, `slug`, `destination`, `app_scheme`, `campaign`, and `attributed`. Direct and deferred resolution may be retried; the server controls token expiry and attribution.

Never log or persist raw tokens longer than required for resolution. Do not collect IP addresses or device fingerprints, and do not infer a match when a platform handoff is unavailable.

## Preview status

The current source preview implements token extraction/resolution and platform deferred-token reads. The native purchase, restore, customer identity and entitlement clients are incomplete, so the packages are not production-ready and have not been published.

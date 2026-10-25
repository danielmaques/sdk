# Acquisition links in Pushify SDKs

Pushify acquisition links resolve opaque click tokens through the public app API. A host app owns navigation: the SDK returns the destination and campaign values but does not choose a screen or change partner-attribution fields.

## Direct app links

Pass the incoming app URL to the platform SDK's `tokenFromUrl`, `token(from:)`, `capture(Uri)`, or `acquisitionTokenFromUrl` helper. If a valid `rdt` token is present, call the SDK resolver with that token and, when known, the same app user id used for purchases. The server accepts resolution before or after customer identification. Route to the returned `destination` after the app validates it for its own navigation policy.

## Deferred links

- Android reads the `rdit` value from the Google Play Install Referrer. The value is opaque and expires after the backend's deferred-token window.
- iOS can read the `rdit_` clipboard value after an explicit call that the app makes with an explanatory user flow. The OS may display its pasteboard privacy prompt. Pushify SDKs never read unrelated clipboard content or poll the clipboard.
- Flutter and React Native expose a call to request the native token. If the platform returns no token, or the user denies clipboard access, the click remains unassigned and no installation is guessed from device attributes.

## Resolution contract

The client sends `POST /v1/acquisition_links/resolve` with `Authorization: Bearer <public-app-key>` and JSON `{ "token": "rdlt_...", "app_user_id": "..." }`. `app_user_id` is optional. A successful response includes `status`, `link_id`, `name`, `slug`, `destination`, `app_scheme`, `campaign`, and `attributed`. Direct and deferred resolution may be retried; the server controls token expiry and attribution.

Never log or persist raw tokens longer than required for resolution. Do not collect IP addresses or device fingerprints, and do not infer a match when a platform handoff is unavailable.

## Preview status

The current source preview implements token extraction/resolution and platform deferred-token reads. The native purchase, restore, customer identity and entitlement clients are incomplete, so the packages are not production-ready and have not been published.

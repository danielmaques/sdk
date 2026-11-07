# Pushify SDKs

This public workspace contains original Pushify SDK implementations for Android, iOS, Flutter, and React Native. It is maintained separately from the private Pushify server and dashboard repository.

The packages use native platform APIs and Pushify's documented server protocol. No SDK source from another company is included, adapted, or vendored.

## SDK guides

| Platform | Package | Guide | Distribution |
|---|---|---|---|
| Android | Kotlin library | [Android setup and purchase guide](android/README.md) | Maven Central release pending |
| iOS | Swift package | [iOS setup and purchase guide](ios/README.md) | Swift Package release pending |
| Flutter | `pushify_purchases` | [Flutter setup and purchase guide](flutter/README.md) | pub.dev release pending |
| React Native | `@pushify/purchases` | [React Native setup and purchase guide](react-native/README.md) | npm release pending |

## Implemented purchase foundation

The native iOS and Android clients and the Flutter/React Native bridges expose customer bootstrap, identity, attributes, offerings, native purchases, restore/sync, verified transaction delivery, cached customer snapshots, customer update listeners, event submission and idempotent virtual-currency spends. StoreKit 2 and Google Play Billing are the purchase engines. Acquisition-link helpers are also available on all four platforms.

Native localized product hydration is implemented for StoreKit and Play Billing and is forwarded by the Flutter/React Native bridges. The first-party API serves published paywalls in `pushify.paywall/v1` and `/v2` and localized Customer Center configuration. All four packages render core paywall controls plus icons, timelines, carousels, tabs, countdowns, localized Terms/Privacy links, explicit package purchases, ordered and conditional workflow navigation, close/back/next purchase outcomes, ordered State/attribute/URL purchase chains, named custom app actions, session State variables with text interpolation, and per-button Shrink/Grow/Fade feedback with native haptics where supported. The optional `onCustomAction` callback on each paywall view receives the configured action name; without a handler the renderer displays an unavailable message. The callback is fire-and-forget and has no result or paywall branch. Pushify-only behavior is carried by the versioned paywall document and stripped from the RevenueCat-compatible offerings component payload where applicable. Runtime behavior and styling still differ from the editor, and native video/web-view components are missing. Custom placements, callback actions with success/failure branches, delay and web redemption remain unsupported. Customer Center purchase/refund/support flows are basic and do not cover every dashboard action. Conditional flow branches are implemented for declared State comparisons; targeting and experiments inside paywall documents, complete offline behavior, cross-platform device sandbox journeys and production package validation remain incomplete. Host apps own link-domain setup and navigation.

### Named custom paywall actions

Set a button action to `custom_action` and give it a name such as `help_center`. The paywall view passes that name to your app callback. The callback lets the host app present its own screen or run application logic; Pushify does not define the meaning of the name. It is not called by the browser preview. Callback actions that return data or control paywall branches are not part of this contract.

| SDK | Paywall view callback |
|---|---|
| iOS | `PushifyPaywallView(..., onCustomAction: { name in ... })` |
| Android | `PushifyPaywallView(..., onCustomAction = { name -> ... })` |
| Flutter | `PushifyPaywall(..., onCustomAction: (name) { ... })` |
| React Native | `<PushifyPaywallView ... onCustomAction={name => ...} />` |

## Production readiness

The SDKs are **not production-ready yet**. Paywalls and several client-facing capabilities in the product plan are missing, and the full Apple/Google sandbox acceptance suite has not passed. No package has been published. Each guide records its platform-specific build and capability limits.

See the shared [acquisition-link contract](docs/acquisition-links.md) and the [SDK product plan](../prd/sdks/PRD.md).

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

Native localized product hydration is implemented for StoreKit and Play Billing and is forwarded by the Flutter/React Native bridges. The first-party API serves published paywalls in `pushify.paywall/v1` and localized Customer Center configuration. All four packages render core paywall controls plus icons, timelines, carousels, tabs, and countdowns; behavior and styling still differ from the editor, and native video/web-view components are missing. Customer Center purchase/refund/support flows are basic and do not cover every dashboard action. Targeting and experiments, complete offline behavior, cross-platform sandbox journeys and production package validation remain incomplete. The host app still owns link-domain setup and navigation.

## Production readiness

The SDKs are **not production-ready yet**. Paywalls and several client-facing capabilities in the product plan are missing, and the full Apple/Google sandbox acceptance suite has not passed. No package has been published. Each guide records its platform-specific build and capability limits.

See the shared [acquisition-link contract](docs/acquisition-links.md) and the [SDK product plan](../prd/sdks/PRD.md).

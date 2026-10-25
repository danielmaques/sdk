# Pushify SDKs

This public workspace contains original Pushify SDK implementations for Android, iOS, Flutter, and React Native. It is maintained separately from the private Pushify server and dashboard repository.

The packages use native platform APIs and Pushify's documented server protocol. No SDK source from another company is included, adapted, or vendored.

## SDK guides

| Platform | Package | Guide | Distribution |
|---|---|---|---|
| Android | Kotlin library | [Android setup and acquisition-link guide](android/README.md) | Maven Central release pending |
| iOS | Swift package | [iOS setup and acquisition-link guide](ios/README.md) | Swift Package release pending |
| Flutter | `pushify_purchases` | [Flutter setup and acquisition-link guide](flutter/README.md) | pub.dev release pending; package name availability unconfirmed |
| React Native | `@pushify/purchases` | [React Native setup and acquisition-link guide](react-native/README.md) | npm release pending |

## Preview capabilities

The current preview implements acquisition-link token parsing and resolution. Each platform has a one-call helper for handling a direct app URL; Android reads deferred tokens from Google Play Install Referrer, and iOS supports a user-initiated pasteboard handoff. Flutter and React Native expose matching deferred-resolution helpers.

Each platform guide includes prerequisites, local installation, direct-link handling, deferred-token retrieval, API response fields, security notes, and current limitations. The host app remains responsible for link-domain setup and deciding how to navigate to a returned destination.

## Not production-ready yet

Customer identity, offerings and products, purchases, receipt / transaction sync, restore, entitlements, and native paywall presentation are part of the planned complete SDK scope but are not implemented in this preview. No package has been published. Do not use this preview for production purchase processing.

See the shared [acquisition-link contract](docs/acquisition-links.md) and the [SDK product plan](../prd/sdks/PRD.md).

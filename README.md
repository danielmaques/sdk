# Pushify SDKs

This repository contains original Pushify SDK implementations for Android, iOS, Flutter, and React Native. It is intentionally separate from the private server and dashboard repository.

The SDKs use native platform purchase APIs and Pushify's documented server protocol. No SDK source from another company is vendored or adapted here. Public documentation and compatibility descriptions are written for Pushify.

## Packages

| Directory | Package | Distribution |
|---|---|---|
| `android/` | `app.pushify.sdk:pushify-android` | Maven Central (release setup pending) |
| `ios/` | `PushifySDK` | Swift Package Manager (release setup pending) |
| `flutter/` | `pushify_purchases` | pub.dev (name availability and release setup pending) |
| `react-native/` | `@pushify/purchases` | npm (release setup pending) |

Every SDK will support configuration, customer identity, products/offerings, purchase, restore, entitlements, customer info, transaction sync, native paywall presentation, and acquisition-link capture/resolution before being described as complete. Paywalls will use Pushify-owned UI and configuration, with native presentation on Compose, SwiftUI/UIKit, Flutter and React Native. The current preview does not yet implement purchases or paywalls. See [the SDK PRD](../prd/sdks/PRD.md) for scope and privacy requirements.

The acquisition-link preview contract and platform limits are in [the SDK guide](docs/acquisition-links.md).

## Status

Initial independent workspace. No registry release has been published. Platform support and release versions will be documented here as the implementations become complete.

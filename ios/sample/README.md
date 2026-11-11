# iOS Purchase Test Lab sample

This SwiftUI app exercises a Pushify sandbox app through StoreKit 2. It can load offerings, open the native purchase sheet, restore purchases, refresh entitlements and export a session-local redacted report. Store actions are developer-operated; the sample does not create App Store transactions remotely or use a remote device.

## Build and run

Open `PushifyTestLab.xcodeproj` in Xcode and set `PUSHIFY_PUBLIC_APP_KEY` in the Run scheme's environment variables to a public key for a sandbox app. The key is public and must not be a server secret. To use a self-hosted server, change `PUSHIFY_API_BASE_URL` in `TestLab.xcconfig`.

You can also build without opening Xcode:

```sh
xcodebuild -project PushifyTestLab.xcodeproj -scheme PushifyTestLab \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  PUSHIFY_PUBLIC_APP_KEY=pk_test_... build
```

## Runner deep links

The app accepts `pushify-testlab://run?scenario=offerings_refresh`, `restore`, and `entitlement_refresh`. For a purchase, also provide the package identifier, URL encoded:

```text
pushify-testlab://run?scenario=purchase&package_id=pkg_monthly
```

A local developer can open a link with `xcrun simctl openurl booted '<deep-link>'` after installing and launching the app, or use `pushify test mobile --platform ios` to launch the selected scenario and collect its private report. Purchase requires a StoreKit configuration or Apple sandbox account with matching products. `pushify test purchases` is a separate server-side Test Store runner and does not invoke StoreKit.

The app saves `pushify-test-run.json` in its private Documents directory and offers the report through the system share sheet. It includes outcomes and SDK correlation IDs, but excludes customer IDs, transaction identifiers, purchase proofs and raw error messages.

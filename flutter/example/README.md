# Pushify Flutter example

This app loads the current customer and offering, then opens a published paywall or the configured Customer Center.

```sh
fvm flutter pub get
fvm flutter run --dart-define=PUSHIFY_PUBLIC_APP_KEY=pushify_public_app_key
```

Replace the example key with a public key from a Pushify app. The local `pushify_purchases/` package directory links to the SDK source so Flutter's Swift Package Manager integration sees the package under its published identity.

The example also includes a **Purchase Test Lab** for developer-operated StoreKit sandbox and Google Play license-tester actions: load offerings, buy a package, restore purchases, refresh entitlements, and review a local run list. Configure the matching store account on the simulator/device before testing. The runner does not create store transactions remotely and its history is kept only in the current app session.

Open **SDK diagnostics** to preview and copy the opt-in redacted local support bundle. It is not uploaded.

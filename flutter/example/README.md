# Pushify Flutter example

This app loads the current customer and offering, then opens a published paywall or the configured Customer Center.

```sh
fvm flutter pub get
fvm flutter run --dart-define=PUSHIFY_PUBLIC_APP_KEY=pushify_public_app_key
```

Replace the example key with a public key from a Pushify app. The local `pushify_purchases/` package directory links to the SDK source so Flutter's Swift Package Manager integration sees the package under its published identity.

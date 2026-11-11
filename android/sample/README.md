# Android Purchase Test Lab sample

This developer-operated sample app exercises a Pushify sandbox app through the Android SDK. It can refresh offerings, open Google Play Billing for a selected package, restore purchases, refresh entitlements, and copy a local redacted run report. It does not automate a Play purchase or use a remote device.

## Build

From `sdk/android`, provide a public key for a sandbox app as a local Gradle property. The key is compiled into the app and must never be a secret key.

```sh
./gradlew :sample:assembleDebug -PPUSHIFY_PUBLIC_APP_KEY=pk_test_...
```

For a self-hosted server, add `-PPUSHIFY_API_BASE_URL=https://api.example.test`. The default API URL is `https://api.pushify.app`.

## Runner intents

The activity accepts explicit intents for `offerings_refresh`, `purchase`, `restore`, and `entitlement_refresh`. A local runner can launch them with Android Debug Bridge:

```sh
adb shell am start -n app.pushify.testlab/.MainActivity --es pushify_scenario restore
adb shell am start -n app.pushify.testlab/.MainActivity --es pushify_scenario purchase --es pushify_package_id pkg_monthly
```

Purchase requires a Google Play license tester and a Play-installed build with matching products. ADB invocation is a manual bridge only; `pushify test purchases` does not yet launch or attach to this app.

Run reports stay in the app's private files directory as `pushify-test-run.json`. They include scenario outcomes and SDK diagnostic correlation IDs, but no customer IDs or purchase tokens. Use **Copy redacted run report** to export the report for review.

<!-- Pushify SDK test guide: https://pushify.app/docs/sdk/testing -->

# Mobile purchase testing

## Repeatable Test Store runs

`pushify test purchases` runs the selected lifecycle scenarios against a Pushify Test Store app and product. Use a sandbox project and a secret key scoped to that project. Each scenario is applied through the purchase pipeline in a rollback-only transaction by default; the CLI saves a redacted run summary but no customer, transaction, event, or webhook data. Pass `--keep-data` only when you want the sandbox records retained for inspection. Generated customer IDs start with `pushify-testlab` (change the prefix with `--customer-prefix`).

```sh
npx pushify test purchases \
  --to https://api.pushify.app \
  --to-project proj_your_sandbox_project \
  --app-id app_your_test_store_app \
  --product-id prod_your_test_product \
  --scenarios purchase,restore,duplicate_delivery,trial,trial_conversion,renewal,cancel,billing_issue,refund,expire \
  --format junit > purchase-tests.xml
```

Set `REVENUEDOT_API_KEY` in the CI secret store, or run interactively and enter the key at the hidden prompt. Do not put a production customer ID in `--customer-prefix`. The CLI makes one request per scenario and does not retry non-idempotent requests. `trial_conversion` needs a subscription and simulates at least seven elapsed days; `renewal`, `billing_issue`, `cancel`, and `expire` need a subscription product. Refund supports subscriptions and one-time products. Incompatible products fail as a scenario result.

The JSON report uses `pushify.purchase-test-report/v1`; JUnit exits with code 1 when any requested scenario fails. Test Store scenarios use the same purchase, event, entitlement, and webhook pipeline as ordinary simulated purchases. This runner exercises the server lifecycle; it does not launch a mobile app or claim that StoreKit / Play Billing was invoked.

### Native sample runners

The Flutter, Android and iOS samples provide developer-operated StoreKit/Play Billing flows for offerings, purchase, restore and entitlement refresh. Setup and manual runner commands are documented in [`android/sample/README.md`](android/sample/README.md) and [`ios/sample/README.md`](ios/sample/README.md). Native samples write a session-local `pushify.mobile-test-run/v1` report with SDK correlation IDs and without customer identifiers, transaction identifiers or purchase tokens. `pushify test mobile` launches the installed Android/iOS sample, collects that local report, and emits JSON/JUnit.

The local CLI bridge is available for an already installed, developer-operated sample app:

```sh
npx pushify test mobile --platform ios --scenarios offerings_refresh,restore
npx pushify test mobile --platform android --scenarios purchase --package-id pkg_monthly --device emulator-5554 --format junit
```

Use `--bundle-id` for a custom iOS sample bundle id, `--android-app-id` for a custom Android application id, and `--timeout-seconds` to allow time for a manual store sheet interaction. The iOS command targets a booted Simulator by default; Android uses the selected ADB device. Purchase requires the matching StoreKit/Play sandbox product. The CLI reads the app-private report locally and returns JSON or JUnit; it does not create store transactions or run a device fleet.

## Apple sandbox and StoreKit Testing

These are developer-operated store tests. Create an App Store Connect sandbox tester and use a sandbox-signed app with matching bundle ID and product identifiers. For local StoreKit Testing, attach an Xcode StoreKit configuration file to the scheme and select the intended product and renewal behavior. Install on a device or simulator configured for the selected flow, make the purchase in the native sheet, then verify the SDK customer snapshot, Customer Access Trace, store notification health, and webhook delivery. Apple controls sandbox accounts and transaction timing; Pushify cannot create these transactions remotely.

## Google Play license testing

Upload the app to an internal testing track, add the test account as a license tester in Play Console, and install the Play-distributed build with the matching package name and product/base-plan identifiers. Start the purchase from Google Play Billing, then verify the SDK customer snapshot, Customer Access Trace, notification health, and webhook delivery. Google controls license-tester eligibility and transaction timing; Pushify cannot create these transactions remotely.

Never use production store credentials or real customer identifiers for test runs. See the platform SDK guides for configuration and device requirements.

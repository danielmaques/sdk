<!-- Pushify SDK test guide: https://pushify.app/docs/sdk/testing -->

# Mobile purchase testing

## Repeatable Test Store runs

`pushify test purchases` runs the selected lifecycle scenarios against a Pushify Test Store app and product. Use a sandbox project and a secret key scoped to that project. The generated customer IDs start with `pushify-testlab` (change the prefix with `--customer-prefix`); scenarios create normal sandbox customer, transaction, event, and webhook records so that the timeline and integrations can be inspected after the run.

```sh
npx pushify test purchases \
  --to https://api.pushify.app \
  --to-project proj_your_sandbox_project \
  --app-id app_your_test_store_app \
  --product-id prod_your_test_product \
  --scenarios purchase,trial,trial_conversion,renewal,cancel,billing_issue,refund,expire \
  --format junit > purchase-tests.xml
```

Set `REVENUEDOT_API_KEY` in the CI secret store, or run interactively and enter the key at the hidden prompt. Do not put a production customer ID in `--customer-prefix`. The CLI makes one request per scenario and does not retry non-idempotent requests. `trial_conversion` needs a subscription and simulates at least seven elapsed days; `renewal`, `billing_issue`, `cancel`, and `expire` need a subscription product. Refund supports subscriptions and one-time products. Incompatible products fail as a scenario result.

The JSON report uses `pushify.purchase-test-report/v1`; JUnit exits with code 1 when any requested scenario fails. Test Store scenarios use the same purchase, event, entitlement, and webhook pipeline as ordinary simulated purchases. This runner exercises the server lifecycle; it does not launch a mobile app or claim that StoreKit / Play Billing was invoked.

## Apple sandbox and StoreKit Testing

These are developer-operated store tests. Create an App Store Connect sandbox tester and use a sandbox-signed app with matching bundle ID and product identifiers. For local StoreKit Testing, attach an Xcode StoreKit configuration file to the scheme and select the intended product and renewal behavior. Install on a device or simulator configured for the selected flow, make the purchase in the native sheet, then verify the SDK customer snapshot, Customer Access Trace, store notification health, and webhook delivery. Apple controls sandbox accounts and transaction timing; Pushify cannot create these transactions remotely.

## Google Play license testing

Upload the app to an internal testing track, add the test account as a license tester in Play Console, and install the Play-distributed build with the matching package name and product/base-plan identifiers. Start the purchase from Google Play Billing, then verify the SDK customer snapshot, Customer Access Trace, notification health, and webhook delivery. Google controls license-tester eligibility and transaction timing; Pushify cannot create these transactions remotely.

Never use production store credentials or real customer identifiers for test runs. See the platform SDK guides for configuration and device requirements.

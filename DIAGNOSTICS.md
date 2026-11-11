# SDK diagnostics contract

`pushify.sdk-diagnostics/v1` is opt-in local debug output. Event names are `sdk_configured`, `customer_info_requested`, `offerings_requested`, `purchase_started`, `purchase_completed`, `restore_completed`, and `request_failed`. Each event carries a UTC epoch-millisecond timestamp, UUID correlation ID, outcome, retryable flag, and a fixed safe message. Ring buffers keep at most 100 events in memory.

Exports may include platform, API host, a masked public key, counts of cached offerings, products, and active entitlements, and `recent_retryable_failure_count` (retryable failures still present in the bounded in-memory event buffer). This count is diagnostic evidence, not a persisted store retry-queue count. Exports must not include customer IDs, attributes, receipt data, transaction IDs, server response bodies, request paths, or credentials. Applications must explicitly enable the inspector; SDK diagnostics never upload automatically.

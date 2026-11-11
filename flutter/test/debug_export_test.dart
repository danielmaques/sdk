import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pushify_purchases/pushify_purchases.dart';

void main() {
  test('diagnostic export is opt-in and includes the shared safe schema', () {
    final purchases = PushifyPurchases(
      publicApiKey: 'pk_live_example_public_key',
      appVersion: '2.4.1',
    );

    expect(purchases.debugExport(), isNull);

    purchases.enableDebugInspector();
    final encoded = purchases.debugExport();
    expect(encoded, isNotNull);
    expect(encoded, isNot(contains('pk_live_example_public_key')));

    final report = jsonDecode(encoded!) as Map<String, dynamic>;
    expect(report.keys.toSet(), {
      'schema',
      'platform',
      'api_host',
      'sdk_version',
      'app_version',
      'app_environment',
      'customer_state',
      'masked_public_key',
      'cached_offering_count',
      'cached_product_ids',
      'active_entitlement_count',
      'store_product_count',
      'store_product_lookup',
      'retry_queue_count',
      'recent_retryable_failure_count',
      'last_offerings_result',
      'last_sync_result',
      'events',
    });
    expect(report['schema'], 'pushify.sdk-diagnostics/v1');
    expect(report['app_version'], '2.4.1');
    expect(report['customer_state'], 'not_loaded');
    expect(report['store_product_lookup'], {
      'status': 'not_checked',
      'resolved_count': null,
      'missing_count': null,
    });
    expect(report['last_offerings_result'], isNull);
    expect(report['last_sync_result'], isNull);
  });
}

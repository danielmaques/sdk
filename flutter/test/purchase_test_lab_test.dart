import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushify_purchases/pushify_purchases.dart';

// This test intentionally exercises the developer sample, not the published SDK library.
// ignore: avoid_relative_lib_imports
import '../example/lib/purchase_test_lab.dart';

void main() {
  test('purchase test reports keep only valid bounded correlation IDs', () {
    const valid = '123e4567-e89b-12d3-a456-426614174000';
    final events = List.generate(25, (index) => {
      'correlation_id': index == 24 ? 'customer-id' : valid,
    });
    final export = jsonEncode({'events': events});

    final result = purchaseTestCorrelationIds(export);

    expect(result, hasLength(20));
    expect(result, everyElement(valid));
    expect(purchaseTestCorrelationIds('{invalid'), isEmpty);
    expect(purchaseTestCorrelationIds(null), isEmpty);
  });

  testWidgets('copy exports the versioned local run report', (tester) async {
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });

    final purchases = PushifyPurchases(publicApiKey: 'pk_test_1234567890');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PurchaseTestLab(purchases: purchases)),
    ));
    await tester.tap(find.text('Copy report'));
    await tester.pump();

    expect(find.text('Copied'), findsOneWidget);
    final report = jsonDecode(clipboardText!) as Map<String, dynamic>;
    expect(report, containsPair('schema', 'pushify.mobile-test-run/v1'));
    expect(['ios', 'android'], contains(report['platform']));
    expect(report['run_id'], startsWith('flutter-'));
    expect(report['operations'], hasLength(1));
    expect((report['operations'] as List).single, containsPair('scenario', 'offerings_refresh'));
    expect((report['operations'] as List).single, containsPair('status', 'failed'));
    expect(clipboardText, isNot(contains('PushifyException')));

    await tester.pumpWidget(const SizedBox.shrink());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
}

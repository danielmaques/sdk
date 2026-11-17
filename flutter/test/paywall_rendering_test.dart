import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pushify_purchases/pushify_purchases.dart';

void main() {
  testWidgets('renders horizontal stack layout and themed text', (tester) async {
    final purchases = PushifyPurchases(
      publicApiKey: 'pushify_public_test_key',
      apiBaseUrl: Uri.parse('https://api.example.test'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PushifyPaywall(
          purchases: purchases,
          offering: const {'packages': <Object?>[]},
          document: {
            'default_locale': 'en_US',
            'screens': [
              {
                'id': 'main',
                'content': {
                  'id': 'root',
                  'kind': 'stack',
                  'properties': {
                    'dimension': {
                      'type': 'horizontal',
                      'alignment': 'center',
                      'distribution': 'start',
                    },
                    'spacing': 12,
                    'padding': {
                      'top': 0,
                      'bottom': 0,
                      'leading': 0,
                      'trailing': 0,
                    },
                    'margin': {
                      'top': 0,
                      'bottom': 0,
                      'leading': 0,
                      'trailing': 0,
                    },
                  },
                  'children': [
                    {
                      'id': 'first',
                      'kind': 'text',
                      'properties': {
                        'text': 'First',
                        'color': {
                          'light': {'type': 'hex', 'value': '#ff0000ff'},
                        },
                        'font_size': 18,
                        'font_weight': 'semibold',
                      },
                      'children': <Object?>[],
                    },
                    {
                      'id': 'second',
                      'kind': 'text',
                      'properties': {'text': 'Second'},
                      'children': <Object?>[],
                    },
                  ],
                },
                'localizations': <String, Object?>{},
              },
            ],
          },
        ),
      ),
    );

    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.byType(Row), findsOneWidget);
    final firstText = tester.widget<Text>(find.text('First'));
    expect(firstText.style?.color, const Color(0xffff0000));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

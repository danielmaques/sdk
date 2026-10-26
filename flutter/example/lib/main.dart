import 'package:flutter/material.dart';
import 'package:pushify_purchases/pushify_purchases.dart';

const _publicKey = String.fromEnvironment('PUSHIFY_PUBLIC_APP_KEY');

void main() => runApp(const PushifyExampleApp());

class PushifyExampleApp extends StatefulWidget {
  const PushifyExampleApp({super.key});

  @override
  State<PushifyExampleApp> createState() => _PushifyExampleAppState();
}

class _PushifyExampleAppState extends State<PushifyExampleApp> {
  late final PushifyPurchases? _purchases;
  late final Future<void> _ready;
  Map<String, Object?>? _offering;
  Map<String, Object?>? _customer;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _purchases = _publicKey.isEmpty
        ? null
        : PushifyPurchases(publicApiKey: _publicKey);
    _ready = _configure();
  }

  Future<void> _configure() async {
    final purchases = _purchases;
    if (purchases == null) return;
    try {
      await purchases.configure();
      final responses = await Future.wait([
        purchases.offerings(),
        purchases.customerInfo(),
      ]);
      final catalog = responses[0];
      final offerings = (catalog['offerings'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => item.cast<String, Object?>())
          .toList();
      final currentId = catalog['current_offering_id'];
      if (mounted) {
        setState(() {
          final matching = offerings.where((item) => item['id'] == currentId);
          _offering = matching.isEmpty ? null : matching.first;
          _customer = responses[1];
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Pushify SDK example',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff7057d9)),
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('Pushify SDK example')),
      body: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_publicKey.isEmpty) {
            return const Center(
              child: Text('Set PUSHIFY_PUBLIC_APP_KEY with --dart-define.'),
            );
          }
          if (_error != null) {
            return Center(child: Text('Pushify unavailable: $_error'));
          }
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('Customer', style: Theme.of(context).textTheme.titleLarge),
              Text(
                _customer == null
                    ? 'No customer snapshot yet.'
                    : 'Customer state loaded.',
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _offering?['paywall'] is Map
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PushifyPaywall(
                            document: (_offering!['paywall'] as Map)
                                .cast<String, Object?>(),
                            offering: _offering!,
                            purchases: _purchases!,
                            onPurchased: (customer) =>
                                setState(() => _customer = customer),
                          ),
                        ),
                      )
                    : null,
                child: const Text('Open published paywall'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Customer Center')),
                      body: PushifyCustomerCenterView(purchases: _purchases!),
                    ),
                  ),
                ),
                child: const Text('Open Customer Center'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

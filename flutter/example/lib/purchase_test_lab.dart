import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pushify_purchases/pushify_purchases.dart';

/// Developer-operated StoreKit / Play Billing runner for the example app.
class PurchaseTestLab extends StatefulWidget {
  const PurchaseTestLab({super.key, required this.purchases});

  final PushifyPurchases purchases;

  @override
  State<PurchaseTestLab> createState() => _PurchaseTestLabState();
}

class _PurchaseTestLabState extends State<PurchaseTestLab> {
  Map<String, Object?>? _catalog;
  final List<Map<String, Object?>> _results = [];
  bool _busy = false;
  bool _copied = false;
  String? _error;
  late final String _runId = 'flutter-${DateTime.now().toUtc().microsecondsSinceEpoch}';

  String get _platform => Platform.isIOS ? 'ios' : 'android';
  String get _environment => Platform.isIOS ? 'storekit_sandbox' : 'play_sandbox';

  @override
  void dispose() {
    widget.purchases.enableDebugInspector(enabled: false);
    super.dispose();
  }

  String get _report => const JsonEncoder.withIndent('  ').convert({
        'schema': 'pushify.mobile-test-run/v1',
        'run_id': _runId,
        'environment': _environment,
        'platform': _platform,
        'operations': _results,
      });

  Future<void> _loadOfferings() async {
    setState(() { _busy = true; _error = null; });
    try {
      final catalog = await widget.purchases.offerings();
      if (mounted) setState(() => _catalog = catalog);
      _record('offerings_refresh', 'passed');
    } catch (error) {
      if (mounted) setState(() => _error = 'Offerings request failed: $error');
      _record('offerings_refresh', 'failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _purchase(String packageId) async {
    await _run('purchase', () async {
      final result = await widget.purchases.purchase(packageId);
      return result.status;
    });
  }

  Future<void> _restore() => _run('restore', () async {
    await widget.purchases.restorePurchases();
    return 'completed';
  });

  Future<void> _sync() => _run('entitlement_refresh', () async {
    await widget.purchases.syncPurchases();
    return 'completed';
  });

  Future<void> _run(String name, Future<String> Function() action) async {
    setState(() { _busy = true; _error = null; });
    try {
      final outcome = await action();
      _record(name, outcome);
    } catch (error) {
      _record(name, 'failed');
      if (mounted) setState(() => _error = '$name failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _record(String scenario, String outcome) {
    if (!mounted) return;
    final status = switch (outcome) {
      'pending' => 'pending',
      'cancelled' => 'cancelled',
      'failed' => 'failed',
      _ => 'passed',
    };
    setState(() {
      _results.insert(0, {
        'scenario': scenario,
        'status': status,
        'outcome': outcome,
        'occurred_at': DateTime.now().toUtc().toIso8601String(),
        'correlation_ids': purchaseTestCorrelationIds(widget.purchases.debugExport()),
      });
      if (_results.length > 50) _results.removeRange(50, _results.length);
      _copied = false;
    });
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _report));
    if (mounted) setState(() => _copied = true);
  }

  List<Map<String, Object?>> get _packages {
    final offerings = _catalog?['offerings'];
    if (offerings is! List) return [];
    return offerings.whereType<Map>().expand((offering) {
      final packages = offering['packages'];
      if (packages is! List) return const <Map<String, Object?>>[];
      return packages.whereType<Map>().map((item) => item.cast<String, Object?>());
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    widget.purchases.enableDebugInspector();
    _loadOfferings();
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Purchase Test Lab', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('Runs real store sandbox actions on this device. Configure a StoreKit test account or a Google Play license tester first. These checks do not use the Test Store CLI.'),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(onPressed: _busy ? null : _loadOfferings, child: const Text('Refresh offerings')),
            OutlinedButton(onPressed: _busy ? null : _restore, child: const Text('Restore purchases')),
            OutlinedButton(onPressed: _busy ? null : _sync, child: const Text('Refresh entitlements')),
          ]),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 16),
          Text('Purchase packages', style: Theme.of(context).textTheme.titleMedium),
          if (_packages.isEmpty) const ListTile(title: Text('No packages loaded'), subtitle: Text('Refresh offerings and check the app catalog.')),
          for (final item in _packages)
            ListTile(
              title: Text(item['id']?.toString() ?? 'Package'),
              subtitle: Text((item['product'] as Map?)?['product_id']?.toString() ?? 'Product identifier unavailable'),
              trailing: FilledButton(
                onPressed: _busy ? null : () => _purchase(item['id'].toString()),
                child: const Text('Buy'),
              ),
            ),
          const Divider(),
          Row(children: [
            Expanded(child: Text('Run history', style: Theme.of(context).textTheme.titleMedium)),
            TextButton(onPressed: _copyReport, child: Text(_copied ? 'Copied' : 'Copy report')),
            TextButton(onPressed: () => setState(() { _results.clear(); _copied = false; }), child: const Text('Clear')),
          ]),
          SelectableText(_report, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      );
}

/// Extracts only UUID correlation IDs from the already-redacted SDK debug export.
List<String> purchaseTestCorrelationIds(String? debugExport) {
  if (debugExport == null) return const [];
  try {
    final decoded = jsonDecode(debugExport);
    if (decoded is! Map || decoded['events'] is! List) return const [];
    return (decoded['events'] as List)
        .whereType<Map>()
        .map((event) => event['correlation_id'])
        .whereType<String>()
        .where((id) => RegExp(r'^[0-9a-f-]{36}$', caseSensitive: false).hasMatch(id))
        .toList(growable: false)
        .reversed
        .take(20)
        .toList(growable: false);
  } on FormatException {
    return const [];
  }
}

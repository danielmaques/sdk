import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'purchases.dart';

/// Opt-in local inspector with a preview and copy action for redacted diagnostics.
class PushifyDebugInspector extends StatefulWidget {
  const PushifyDebugInspector({super.key, required this.purchases});

  final PushifyPurchases purchases;

  @override
  State<PushifyDebugInspector> createState() => _PushifyDebugInspectorState();
}

class _PushifyDebugInspectorState extends State<PushifyDebugInspector> {
  String _report = 'Enable diagnostics to collect a local support bundle.';
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    widget.purchases.enableDebugInspector();
    _refresh();
  }

  Future<void> _refresh() async {
    await widget.purchases.refreshDebugRetryQueueCount();
    if (!mounted) return;
    setState(() {
      _report = widget.purchases.debugExport() ?? 'No diagnostic report is available.';
      _copied = false;
    });
  }

  @override
  void dispose() {
    widget.purchases.enableDebugInspector(enabled: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Pushify diagnostics', style: Theme.of(context).textTheme.titleMedium)),
              TextButton(onPressed: _refresh, child: const Text('Refresh')),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _report));
                  if (mounted) setState(() => _copied = true);
                },
                child: Text(_copied ? 'Copied' : 'Copy'),
              ),
            ]),
            const Text('Stored on this device. Nothing is uploaded automatically.'),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(child: SelectableText(_report, style: const TextStyle(fontFamily: 'monospace'))),
            ),
          ]),
        ),
      );
}

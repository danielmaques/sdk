import 'package:flutter/material.dart';

import 'purchases.dart';

/// Renders the core Pushify paywall components using the platform's native widgets.
class PushifyPaywall extends StatefulWidget {
  const PushifyPaywall({
    required this.document,
    required this.offering,
    required this.purchases,
    this.locale,
    this.onClose,
    this.onPurchased,
    super.key,
  });

  final Map<String, Object?> document;
  final Map<String, Object?> offering;
  final PushifyPurchases purchases;
  final String? locale;
  final VoidCallback? onClose;
  final ValueChanged<Map<String, Object?>>? onPurchased;

  @override
  State<PushifyPaywall> createState() => _PushifyPaywallState();
}

class _PushifyPaywallState extends State<PushifyPaywall> {
  late final List<Map<String, Object?>> _screens;
  String _screenId = '';
  String _selectedPackage = '';
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _screens = _maps(widget.document['screens']);
    final firstScreen = _screens.isEmpty ? null : _screens.first;
    _screenId = firstScreen?['id'] as String? ?? '';
    final firstContent = _map(firstScreen?['content']);
    _selectedPackage = _findSelectedPackage(firstContent) ?? (_packages.isEmpty ? null : _packages.first['id'] as String?) ?? '';
  }

  List<Map<String, Object?>> get _packages => _maps(widget.offering['packages']);

  @override
  Widget build(BuildContext context) {
    final matches = _screens.where((item) => item['id'] == _screenId);
    final screen = matches.isEmpty ? (_screens.isEmpty ? null : _screens.first) : matches.first;
    if (screen == null) return const Center(child: Text('Paywall unavailable'));
    return Scaffold(
      backgroundColor: _background(_map(screen['background']), Theme.of(context).colorScheme.surface),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (widget.onClose case final close?) Align(alignment: Alignment.centerRight, child: IconButton(onPressed: close, tooltip: 'Close paywall', icon: const Icon(Icons.close))),
              Expanded(child: SingleChildScrollView(child: _render(_map(screen['content']), screen))),
              if (screen['footer'] != null) _render(_map(screen['footer']), screen),
              if (_message case final message?) Padding(padding: const EdgeInsets.all(8), child: Semantics(liveRegion: true, child: Text(message))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _render(Map<String, Object?> node, Map<String, Object?> screen) {
    final kind = node['kind'] as String? ?? '';
    final properties = _map(node['properties']);
    final children = _maps(node['children']);
    switch (kind) {
      case 'stack':
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children.map((child) => Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: _render(child, screen))).toList());
      case 'hstack':
        return Row(mainAxisSize: MainAxisSize.max, children: children.map((child) => Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _render(child, screen)))).toList());
      case 'text':
      case 'title':
        return Text(_localized(node, screen), textAlign: TextAlign.center, style: TextStyle(fontSize: _number(properties['font_size']) ?? 20, fontWeight: _fontWeight(properties['font_weight'])));
      case 'package':
        final packageId = properties['package_id'] as String?;
        final matches = _packages.where((value) => value['id'] == packageId);
        final item = matches.isEmpty ? null : matches.first;
        if (item == null) return const SizedBox.shrink();
        final product = _map(item['product']);
        final selected = _selectedPackage == packageId;
        return Semantics(
          button: true,
          selected: selected,
          label: '${_localized(node, screen, properties['label'] as String? ?? product['display_name'] as String? ?? packageId ?? '')}, ${product['localized_price'] ?? ''}',
          child: OutlinedButton(
            onPressed: () => setState(() => _selectedPackage = packageId ?? ''),
            style: OutlinedButton.styleFrom(side: BorderSide(width: selected ? 2 : 1, color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline)),
            child: Row(children: [Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_localized(node, screen, properties['label'] as String? ?? product['display_name'] as String? ?? packageId ?? ''), style: const TextStyle(fontWeight: FontWeight.w600)), if (product['localized_price'] != null) Text(product['localized_price'] as String, style: Theme.of(context).textTheme.bodySmall)]))]),
          ),
        );
      case 'purchase_button':
      case 'cta':
        return FilledButton(onPressed: _busy || _selectedPackage.isEmpty ? null : _buy, child: _busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(_localized(node, screen, 'Continue')));
      case 'restore_button':
        return TextButton(onPressed: _busy ? null : _restore, child: Text(_localized(node, screen, 'Restore purchases')));
      case 'button':
        return TextButton(onPressed: () {
          if (properties['action'] == 'restore') { _restore(); return; }
          final next = properties['next_screen_id'];
          if (_screens.any((item) => item['id'] == next)) {
            setState(() => _screenId = next as String);
          } else {
            _buy();
          }
        }, child: Text(_localized(node, screen, 'Continue')));
      case 'spacer':
        return SizedBox(height: _number(properties['size']) ?? 8);
      case 'image':
        final source = _map(_map(properties['source'])['light']);
        final url = source['url'] as String?;
        return url == null || !url.startsWith('https://') ? const SizedBox.shrink() : Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const SizedBox.shrink(), semanticLabel: properties['accessibility_label'] as String?);
      default:
        if (children.isNotEmpty) return Column(mainAxisSize: MainAxisSize.min, children: children.map((child) => _render(child, screen)).toList());
        return Text(properties['text'] as String? ?? '');
    }
  }

  Future<void> _buy() async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; });
    try {
      final result = await widget.purchases.purchase(_selectedPackage);
      if (result.isPurchased && result.customerInfo != null) widget.onPurchased?.call(result.customerInfo!);
      if (result.isPending) setState(() => _message = 'Purchase is pending approval.');
    } catch (_) {
      setState(() => _message = 'Purchase could not be completed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() { _busy = true; _message = null; });
    try { await widget.purchases.restorePurchases(); setState(() => _message = 'Purchases restored.'); }
    catch (_) { setState(() => _message = 'Purchases could not be restored. Please try again.'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  String _localized(Map<String, Object?> node, Map<String, Object?> screen, [String fallback = '']) {
    final key = _map(node['properties'])['text_lid'];
    if (key is String) {
      final localizations = _map(screen['localizations']);
      final locales = _map(widget.document['locales']);
      for (final locale in [widget.locale, widget.document['default_locale'] as String?, 'en_US']) {
        if (locale == null) continue;
        final value = _map(localizations[locale])[key] ?? _map(locales[locale])[key];
        if (value is String) return value;
      }
    }
    return fallback.isNotEmpty ? fallback : _map(node['properties'])['text'] as String? ?? '';
  }

  Color _background(Map<String, Object?> background, Color fallback) {
    final hex = _map(_map(background['value'])['light'])['value'];
    if (hex is! String) return fallback;
    final normalized = hex.replaceAll('#', '');
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) return fallback;
    final argb = normalized.length == 8 ? ((parsed & 0xff) << 24) | (parsed >> 8) : 0xff000000 | parsed;
    return Color(argb);
  }

  FontWeight _fontWeight(Object? value) => switch (value) { 'bold' => FontWeight.bold, 'semibold' => FontWeight.w600, 'medium' => FontWeight.w500, 'light' => FontWeight.w300, _ => FontWeight.normal };
  double? _number(Object? value) => value is num ? value.toDouble() : null;
  String? _findSelectedPackage(Map<String, Object?> node) {
    if (node['kind'] == 'package' && _map(node['properties'])['is_selected_by_default'] == true) return _map(node['properties'])['package_id'] as String?;
    for (final child in _maps(node['children'])) { final found = _findSelectedPackage(child); if (found != null) return found; }
    return null;
  }
}

Map<String, Object?> _map(Object? value) => value is Map ? value.map((key, item) => MapEntry(key.toString(), item)) : <String, Object?>{};
List<Map<String, Object?>> _maps(Object? value) => value is List ? value.map(_map).toList() : <Map<String, Object?>>[];

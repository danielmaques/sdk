import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import 'purchases.dart';

/// Dashboard-configured customer account screen for the current app customer.
class PushifyCustomerCenterView extends StatefulWidget {
  const PushifyCustomerCenterView({
    required this.purchases,
    this.locale,
    this.onCustomAction,
    super.key,
  });

  final PushifyPurchases purchases;
  final String? locale;
  final Future<void> Function(String actionIdentifier)? onCustomAction;

  @override
  State<PushifyCustomerCenterView> createState() =>
      _PushifyCustomerCenterViewState();
}

class _PushifyCustomerCenterViewState extends State<PushifyCustomerCenterView> {
  late Future<_CenterData> _data;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  @override
  void didUpdateWidget(covariant PushifyCustomerCenterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.purchases != widget.purchases ||
        oldWidget.locale != widget.locale) {
      _data = _load();
    }
  }

  Future<_CenterData> _load() async {
    final results = await Future.wait([
      widget.purchases.customerCenter(locale: widget.locale),
      widget.purchases.customerInfo(),
    ]);
    final response = results[0];
    final customer = results[1];
    return _CenterData(_map(response['configuration']), customer);
  }

  Future<void> _perform(Map<String, Object?> path) async {
    if (_busy) return;
    final type = path['type'] as String? ?? '';
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      switch (type) {
        case 'MISSING_PURCHASE':
          await widget.purchases.restorePurchases();
          _message = 'Purchases restored.';
        case 'CANCEL':
          await widget.purchases.openManageSubscriptions();
          break;
        case 'REFUND_REQUEST':
          final refundUrl = switch (defaultTargetPlatform) {
            TargetPlatform.android =>
              'https://play.google.com/store/account/orderhistory',
            _ => 'https://reportaproblem.apple.com/',
          };
          await widget.purchases.openUrl(refundUrl);
          break;
        case 'CUSTOM_URL':
          final url = path['url'] as String?;
          if (url == null || url.isEmpty) {
            throw StateError('Customer Center URL is missing.');
          }
          await widget.purchases.openUrl(url);
          break;
        case 'CUSTOM_ACTION':
          final action = path['action_identifier'] as String?;
          if (action != null && widget.onCustomAction != null) {
            await widget.onCustomAction!(action);
          } else {
            _message = 'This account action is not available.';
          }
          break;
        default:
          _message = 'This account action is not available.';
          break;
      }
      _data = _load();
    } catch (_) {
      _message = 'This action could not be completed. Please try again.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendTicket() async {
    final email = TextEditingController();
    final message = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Contact support'),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => v == null || !v.contains('@')
                    ? 'Enter a valid email.'
                    : null),
            TextFormField(
                controller: message,
                minLines: 3,
                maxLines: 6,
                decoration:
                    const InputDecoration(labelText: 'How can we help?'),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Enter a message.' : null),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  Navigator.pop(context, true);
                }
              },
              child: const Text('Send')),
        ],
      ),
    );
    final emailValue = email.text.trim();
    final messageValue = message.text.trim();
    email.dispose();
    message.dispose();
    if (submitted != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.purchases
          .createSupportTicket(email: emailValue, message: messageValue);
      if (mounted) {
        setState(() => _message = 'Your request was sent to support.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'The support request could not be sent. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_CenterData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Customer Center is unavailable.'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final config = snapshot.data!.configuration;
          final active =
              _list(_map(snapshot.data!.customer['entitlements'])['active'])
                  .isNotEmpty;
          final screens = _map(config['screens']);
          final screen = _map(screens[active ? 'MANAGEMENT' : 'NO_ACTIVE']);
          final support = _map(config['support']);
          final strings =
              _map(_map(config['localization'])['localized_strings']);
          final title = screen['title'] as String? ?? 'Manage subscription';
          final subtitle = screen['subtitle'] as String?;
          final paths = _list(screen['paths']).map(_map).toList();
          final allowTickets =
              _map(support['support_tickets'])['allow_creation'] == true;
          return ListView(padding: const EdgeInsets.all(20), children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            if (subtitle != null)
              Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 16),
                  child: Text(subtitle)),
            if (_busy) const LinearProgressIndicator(),
            for (final path in paths)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Semantics(
                    button: true,
                    child: OutlinedButton(
                        onPressed: _busy ? null : () => _perform(path),
                        child: Text(path['title'] as String? ?? 'Continue')),
                  )),
            if (active && support['display_purchase_history_link'] == true)
              ListTile(
                  title: Text(strings['check_past_purchases'] as String? ??
                      'Check past purchases'),
                  subtitle: Text(
                      '${_list(snapshot.data!.customer['transactions']).length} verified purchases')),
            if (allowTickets)
              OutlinedButton.icon(
                  onPressed: _busy ? null : _sendTicket,
                  icon: const Icon(Icons.support_agent),
                  label: Text(strings['contact_support'] as String? ??
                      'Contact support')),
            if (_message != null)
              Padding(
                  padding: const EdgeInsets.all(8),
                  child: Semantics(liveRegion: true, child: Text(_message!))),
          ]);
        },
      );
}

class _CenterData {
  const _CenterData(this.configuration, this.customer);
  final Map<String, Object?> configuration;
  final Map<String, Object?> customer;
}

Map<String, Object?> _map(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, Object?>{};
List<Object?> _list(Object? value) => value is List ? value : const [];

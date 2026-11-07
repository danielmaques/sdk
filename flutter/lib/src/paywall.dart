import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:io';

import 'purchases.dart';

part 'paywall_rendering.dart';
part 'paywall_actions.dart';
part 'paywall_localization.dart';
part 'paywall_experience.dart';
part 'paywall_feedback.dart';
part 'paywall_helpers.dart';

/// Renders the core Pushify paywall components using the platform's native widgets.
class PushifyPaywall extends StatefulWidget {
  const PushifyPaywall({
    required this.document,
    required this.offering,
    required this.purchases,
    this.locale,
    this.onClose,
    this.onPurchased,
    this.onCustomAction,
    this._isExitOffer = false,
    super.key,
  });

  final Map<String, Object?> document;
  final Map<String, Object?> offering;
  final PushifyPurchases purchases;
  final String? locale;
  final VoidCallback? onClose;
  final ValueChanged<Map<String, Object?>>? onPurchased;
  final ValueChanged<String>? onCustomAction;
  final bool _isExitOffer;

  @override
  State<PushifyPaywall> createState() => _PushifyPaywallState();
}

class _PushifyPaywallState extends State<PushifyPaywall> {
  late final List<Map<String, Object?>> _screens;
  String _screenId = '';
  String _selectedPackage = '';
  String? _message;
  bool _busy = false;
  Timer? _clock;
  DateTime _now = DateTime.now();
  final Map<String, int> _carouselPages = {};
  final Map<String, PageController> _carouselControllers = {};
  final Map<String, String> _selectedTabs = {};
  final Map<String, Object?> _variables = {};
  Map<String, Object?>? _exitOffering;
  bool _dismissing = false;
  final Set<String> _surveyedTriggers = {};

  void _update(VoidCallback callback) => setState(callback);

  @override
  void initState() {
    super.initState();
    _screens = _maps(widget.document['screens']);
    for (final entry in _map(widget.document['custom_variables']).entries) {
      _variables[entry.key] = _map(entry.value)['initial_value'];
    }
    final requestedStart = widget.document['initial_screen_id'];
    final entryScreens = _screens.where(
      (screen) => screen['id'] == requestedStart,
    );
    final firstScreen = entryScreens.isEmpty
        ? (_screens.isEmpty ? null : _screens.first)
        : entryScreens.first;
    _screenId = firstScreen?['id'] as String? ?? '';
    final firstContent = _map(firstScreen?['content']);
    _selectedPackage =
        _findSelectedPackage(firstContent) ??
        (_packages.isEmpty ? null : _packages.first['id'] as String?) ??
        '';
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    for (final controller in _carouselControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  List<Map<String, Object?>> get _packages =>
      _maps(widget.offering['packages']);

  @override
  Widget build(BuildContext context) {
    if (_exitOffering case final exitOffering?) {
      final document = _map(exitOffering['paywall']);
      return PushifyPaywall(
        document: document,
        offering: exitOffering,
        purchases: widget.purchases,
        locale: widget.locale,
        onClose: widget.onClose,
        onPurchased: widget.onPurchased,
        onCustomAction: widget.onCustomAction,
        isExitOffer: true,
      );
    }
    final matches = _screens.where((item) => item['id'] == _screenId);
    final screen = matches.isEmpty
        ? (_screens.isEmpty ? null : _screens.first)
        : matches.first;
    if (screen == null) return const Center(child: Text('Paywall unavailable'));
    return Scaffold(
      backgroundColor: _background(
        _map(screen['background']),
        Theme.of(context).colorScheme.surface,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (widget.onClose case final _?)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    onPressed: _dismissManually,
                    tooltip: 'Close paywall',
                    icon: const Icon(Icons.close),
                  ),
                ),
              Expanded(
                child: SingleChildScrollView(
                  child: _render(_map(screen['content']), screen),
                ),
              ),
              if (screen['footer'] != null)
                _render(_map(screen['footer']), screen),
              if (_message case final message?)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Semantics(liveRegion: true, child: Text(message)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _dismissManually() async {
    if (_dismissing) return;
    _dismissing = true;
    final currentScreens = _screens.where((screen) => screen['id'] == _screenId);
    await _presentSurvey(
      'close',
      currentScreens.isEmpty ? null : currentScreens.first,
    );
    if (widget._isExitOffer) {
      widget.onClose?.call();
      return;
    }
    final index = _screens.indexWhere((screen) => screen['id'] == _screenId);
    final exit = _map(_map(widget.document['exit_offer'])['dismiss']);
    final offeringId = exit['offering_id'] as String?;
    if (index >= 0 &&
        index == _screens.length - 1 &&
        offeringId != null &&
        offeringId != widget.offering['id']) {
      try {
        final catalog = await widget.purchases.offerings();
        final offerings = _maps(catalog['offerings']);
        final matches = offerings.where(
          (offering) =>
              offering['id'] == offeringId && offering['paywall'] is Map,
        );
        if (matches.isNotEmpty) {
          final target = matches.first;
          unawaited(
            widget.purchases
                .logEvent(
                  'PAYWALL_EXIT_OFFER',
                  properties: {
                    'type': 'dismiss',
                    'offering_id': offeringId,
                    'paywall_id': widget.document['id'],
                  },
                )
                .catchError((_) => 0),
          );
          if (mounted) setState(() => _exitOffering = target);
          return;
        }
      } catch (_) {
        // If the destination is unavailable, dismissal must still complete.
      }
    }
    _dismissing = false;
    widget.onClose?.call();
  }
}

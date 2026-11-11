import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Error envelope raised by the Pushify purchase plugin.
class PushifyException implements Exception {
  const PushifyException(this.code, this.message, {this.details});

  final String code;
  final String message;
  final Object? details;

  @override
  String toString() => 'PushifyException($code): $message';
}

/// Result from the native store sheet. Pending purchases do not grant access.
class PushifyPurchaseResult {
  const PushifyPurchaseResult({required this.status, this.customerInfo});

  final String status;
  final Map<String, Object?>? customerInfo;

  bool get isPurchased => status == 'purchased';
  bool get isPending => status == 'pending';
  bool get isCancelled => status == 'cancelled';

  factory PushifyPurchaseResult.fromMap(Map<Object?, Object?> value) {
    final customer = value['customerInfo'];
    return PushifyPurchaseResult(
      status: value['status'] as String? ?? 'unknown',
      customerInfo: customer is Map ? _stringMap(customer) : null,
    );
  }
}

/// First-party Flutter client for customer state, StoreKit/Play purchases and Pushify app features.
class PushifyPurchases {
  PushifyPurchases({required String publicApiKey, Uri? apiBaseUrl, String? appVersion})
    : _publicApiKey = publicApiKey.trim(),
      _apiBaseUrl = apiBaseUrl ?? Uri.https('api.pushify.app', ''),
      _appVersion = appVersion {
    if (_publicApiKey.isEmpty ||
        _apiBaseUrl.scheme != 'https' ||
        _apiBaseUrl.host.isEmpty) {
      throw ArgumentError('A public app key and HTTPS API URL are required.');
    }
  }

  static const MethodChannel _channel = MethodChannel('app.pushify/purchases');
  static const EventChannel _events = EventChannel('app.pushify/customer-info');
  final String _publicApiKey;
  final Uri _apiBaseUrl;
  final String? _appVersion;
  bool _configured = false;
  bool _debugInspectorEnabled = false;
  final List<Map<String, Object?>> _diagnosticEvents = [];
  Map<String, Object?>? _cachedInfo;
  Map<String, Object?>? _cachedCatalog;
  int? _retryQueueCount;

  /// Enables a bounded in-memory debug log. Nothing is uploaded automatically.
  void enableDebugInspector({bool enabled = true}) => _debugInspectorEnabled = enabled;

  /// Refreshes the platform store's unfinished purchase count for the local inspector.
  Future<int?> refreshDebugRetryQueueCount() async {
    if (!_debugInspectorEnabled) return null;
    try {
      _retryQueueCount = await _invoke<int>('debugRetryQueueCount');
    } on PlatformException {
      _retryQueueCount = null;
    }
    return _retryQueueCount;
  }

  /// Redacted JSON export; null until the host app explicitly enables diagnostics.
  String? debugExport() {
    if (!_debugInspectorEnabled) return null;
    final key = _publicApiKey;
    final masked = key.length > 10 ? '${key.substring(0, 6)}…${key.substring(key.length - 4)}' : '••••';
    final entitlements = _cachedInfo?['entitlements'];
    final active = entitlements is Map ? entitlements['active'] : null;
    final offerings = _cachedCatalog?['offerings'];
    final products = <String>[];
    final resolvedStoreProducts = <String>{};
    if (offerings is List) {
      for (final offering in offerings.whereType<Map>()) {
        final packages = offering['packages'];
        if (packages is! List) continue;
        for (final item in packages.whereType<Map>()) {
          final product = item['product'];
          if (product is Map) {
            if (product['product_id'] is String) {
              final id = product['product_id'] as String;
              products.add(id);
              if (product['localized_price'] is String && (product['localized_price'] as String).isNotEmpty) resolvedStoreProducts.add(id);
            }
          }
        }
      }
    }
    return jsonEncode({
      'schema': 'pushify.sdk-diagnostics/v1', 'platform': 'flutter', 'api_host': _apiBaseUrl.host,
      'sdk_version': '0.1.0', 'app_version': _appVersion, 'app_environment': kReleaseMode ? 'production' : 'development',
      'customer_state': _cachedInfo == null ? 'not_loaded' : 'cached',
      'masked_public_key': masked,
      'cached_offering_count': (_cachedCatalog?['offerings'] as List?)?.length ?? 0,
      'cached_product_ids': products.toSet().toList()..sort(), 'active_entitlement_count': active is List ? active.length : active is Map ? active.length : 0,
      'store_product_count': _cachedCatalog == null ? null : resolvedStoreProducts.length,
      'store_product_lookup': {
        'status': _cachedCatalog == null ? 'not_checked' : 'checked',
        'resolved_count': _cachedCatalog == null ? null : resolvedStoreProducts.length,
        'missing_count': _cachedCatalog == null ? null : (products.toSet().difference(resolvedStoreProducts).length),
      },
      'retry_queue_count': _retryQueueCount,
      'recent_retryable_failure_count': _diagnosticEvents.where((event) => event['outcome'] == 'failure' && event['retryable'] == true).length,
      'last_offerings_result': _lastDiagnosticResult(const {'offerings_requested'}),
      'last_sync_result': _lastDiagnosticResult(const {'customer_info_requested', 'restore_completed', 'entitlement_sync_completed'}),
      'events': List<Map<String, Object?>>.unmodifiable(_diagnosticEvents),
    });
  }

  Map<String, Object?>? _lastDiagnosticResult(Set<String> names) {
    for (final event in _diagnosticEvents.reversed) {
      if (names.contains(event['name'])) {
        return {
          'outcome': event['outcome'],
          'timestamp_ms': event['timestamp_ms'],
          'correlation_id': event['correlation_id'],
        };
      }
    }
    return null;
  }

  Future<T> _debugged<T>(String name, Future<T> Function() operation, String message) async {
    try { final value = await operation(); _recordDiagnostic(name, 'success', false, message); return value; }
    catch (_) { _recordDiagnostic(name, 'failure', true, 'SDK operation failed; response details are omitted.'); rethrow; }
  }

  void _recordDiagnostic(String name, String outcome, bool retryable, String message) {
    if (!_debugInspectorEnabled) return;
    _diagnosticEvents.add({
      'name': name, 'timestamp_ms': DateTime.now().toUtc().millisecondsSinceEpoch,
      'correlation_id': _eventId(), 'outcome': outcome, 'retryable': retryable, 'message': message,
    });
    if (_diagnosticEvents.length > 100) _diagnosticEvents.removeRange(0, _diagnosticEvents.length - 100);
  }

  /// Configures the native StoreKit 2 or Google Play Billing implementation.
  Future<Map<String, Object?>?> configure() async {
    final value = await _debugged('sdk_configured', () => _invoke<Map<Object?, Object?>>('configure', {
      'publicApiKey': _publicApiKey,
      'apiBaseUrl': _apiBaseUrl.toString().replaceFirst(RegExp(r'/$'), ''),
    }), 'SDK configured.');
    _configured = true;
    _cachedInfo = value == null ? null : _stringMap(value);
    return _cachedInfo;
  }

  /// Returns the current server snapshot.
  Future<Map<String, Object?>> customerInfo() async {
    final info = _requireMap(await _debugged('customer_info_requested', () => _invoke<Map<Object?, Object?>>('customerInfo'), 'Customer state synchronized.'));
    _cachedInfo = info; return info;
  }

  /// Returns the last server-verified snapshot saved on this device, if available.
  Future<Map<String, Object?>?> cachedCustomerInfo() async {
    final value = await _invoke<Map<Object?, Object?>>('cachedCustomerInfo');
    return value == null ? null : _stringMap(value);
  }

  /// Gets current offerings and published paywall documents for this app.
  Future<Map<String, Object?>> offerings({String? placement}) async =>
      _cacheOfferings(_requireMap(
        await _debugged('offerings_requested', () => _invoke<Map<Object?, Object?>>('offerings', {
          ..._optionalField('placement', placement),
        }), 'Offerings request completed.'),
      ));

  Map<String, Object?> _cacheOfferings(Map<String, Object?> offerings) { _cachedCatalog = offerings; return offerings; }

  /// Loads the published localized Customer Center configuration.
  Future<Map<String, Object?>> customerCenter({String? locale}) async =>
      _requireMap(
        await _invoke<Map<Object?, Object?>>('customerCenter', {
          ..._optionalField('locale', locale),
        }),
      );

  /// Opens the current platform's native subscription management page.
  Future<void> openManageSubscriptions() async =>
      _invoke<void>('openManageSubscriptions');

  /// Opens a safe URL supplied by the published Customer Center configuration.
  Future<void> openUrl(String url) async =>
      _invoke<void>('openUrl', {'url': url});

  /// Submits a support request using the project's Customer Center policy.
  Future<Map<String, Object?>> createSupportTicket({
    required String email,
    required String message,
  }) async => _requireMap(
    await _invoke<Map<Object?, Object?>>('createSupportTicket', {
      'email': email,
      'message': message,
    }),
  );

  /// Links the current anonymous customer to the application's stable customer ID.
  Future<Map<String, Object?>> identify(String customerId) async => _requireMap(
    await _invoke<Map<Object?, Object?>>('identify', {
      'customerId': customerId,
    }),
  );

  /// Starts a new anonymous customer identity.
  Future<Map<String, Object?>> logOut() async =>
      _requireMap(await _invoke<Map<Object?, Object?>>('logOut'));

  /// Sets or clears scalar customer attributes.
  Future<Map<String, Object?>> setAttributes(
    Map<String, Object?> attributes,
  ) async => _requireMap(
    await _invoke<Map<Object?, Object?>>('setAttributes', {
      'attributes': attributes,
    }),
  );

  /// Starts the native Apple or Google purchase flow for an offering package ID.
  Future<PushifyPurchaseResult> purchase(String packageId) async {
    _recordDiagnostic('purchase_started', 'started', false, 'Store purchase flow started.');
    try {
      final value = await _invoke<Map<Object?, Object?>>('purchase', {'packageId': packageId});
      if (value == null) throw const PushifyException('invalid_response', 'The store returned no purchase result.');
      final result = PushifyPurchaseResult.fromMap(value);
      if (result.customerInfo != null) _cachedInfo = result.customerInfo;
      final outcome = result.isPending ? 'pending' : result.isCancelled ? 'cancelled' : result.isPurchased ? 'success' : 'failure';
      _recordDiagnostic('purchase_completed', outcome, false, switch (outcome) {
        'pending' => 'Store purchase is pending approval.',
        'cancelled' => 'Store purchase was cancelled.',
        'success' => 'Store purchase flow completed.',
        _ => 'Store purchase returned an unsupported result.',
      });
      return result;
    } catch (_) {
      _recordDiagnostic('purchase_completed', 'failure', true, 'SDK operation failed; response details are omitted.');
      rethrow;
    }
  }

  /// Restores store purchases and synchronizes verified customer state.
  Future<Map<String, Object?>> restorePurchases() async {
    final info = _requireMap(await _debugged('restore_completed', () => _invoke<Map<Object?, Object?>>('restorePurchases'), 'Restore completed.'));
    _cachedInfo = info; return info;
  }

  /// Reconciles current store ownership without presenting a purchase UI.
  Future<Map<String, Object?>> syncPurchases() async {
    final info = _requireMap(await _debugged('entitlement_sync_completed', () => _invoke<Map<Object?, Object?>>('syncPurchases'), 'Purchase sync completed.'));
    _cachedInfo = info; return info;
  }

  /// Sends a deduplicated app event. Reuse [eventId] to safely retry that event.
  Future<int> logEvent(
    String name, {
    Map<String, Object?> properties = const {},
    String? eventId,
  }) async {
    final id = eventId ?? _eventId();
    return await _invoke<int>('logEvent', {
          'name': name,
          'properties': properties,
          'eventId': id,
        }) ??
        0;
  }

  /// Atomically spends virtual currencies. Reuse [idempotencyKey] for retries.
  Future<Map<String, Object?>> spendVirtualCurrency({
    required Map<String, int> adjustments,
    required String idempotencyKey,
    String? reference,
  }) async => _requireMap(
    await _invoke<Map<Object?, Object?>>('spendVirtualCurrency', {
      'adjustments': adjustments,
      'idempotencyKey': idempotencyKey,
      ..._optionalField('reference', reference),
    }),
  );

  /// Emits verified customer snapshots after login, restore, purchase, or refresh.
  Stream<Map<String, Object?>> get customerInfoUpdates => _events
      .receiveBroadcastStream()
      .map((value) => _requireMap(value as Map));

  /// Reads an install handoff token after showing the user the pasteboard explanation on iOS.
  Future<String?> readDeferredToken() async =>
      _invoke<String>('readDeferredToken');

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (method != 'configure' &&
        method != 'readDeferredToken' &&
        !_configured) {
      throw const PushifyException(
        'not_configured',
        'Call configure before using Pushify purchases.',
      );
    }
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw PushifyException(
        error.code,
        error.message ?? 'Pushify operation failed.',
        details: error.details,
      );
    } on MissingPluginException {
      throw const PushifyException(
        'plugin_unavailable',
        'The Pushify native plugin is not available on this platform.',
      );
    }
  }

  Map<String, Object?> _requireMap(Map? value) {
    if (value == null) {
      throw const PushifyException(
        'invalid_response',
        'The Pushify plugin returned no data.',
      );
    }
    return _stringMap(value);
  }

  String _eventId() {
    final random = Random.secure();
    final suffix = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return 'evt_${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }
}

Map<String, Object?> _stringMap(Map value) =>
    value.map((key, value) => MapEntry(key.toString(), value));

Map<String, Object?> _optionalField(String key, String? value) =>
    value == null ? const {} : {key: value};

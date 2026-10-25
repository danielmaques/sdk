import 'dart:async';
import 'dart:math';

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
  PushifyPurchases({required String publicApiKey, Uri? apiBaseUrl})
      : _publicApiKey = publicApiKey.trim(),
        _apiBaseUrl = apiBaseUrl ?? Uri.https('api.pushify.app', '') {
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
  bool _configured = false;

  /// Configures the native StoreKit 2 or Google Play Billing implementation.
  Future<Map<String, Object?>?> configure() async {
    final value = await _invoke<Map<Object?, Object?>>('configure', {
      'publicApiKey': _publicApiKey,
      'apiBaseUrl': _apiBaseUrl.toString().replaceFirst(RegExp(r'/$'), ''),
    });
    _configured = true;
    return value == null ? null : _stringMap(value);
  }

  /// Returns the current server snapshot.
  Future<Map<String, Object?>> customerInfo() async =>
      _requireMap(await _invoke<Map<Object?, Object?>>('customerInfo'));

  /// Returns the last server-verified snapshot saved on this device, if available.
  Future<Map<String, Object?>?> cachedCustomerInfo() async {
    final value = await _invoke<Map<Object?, Object?>>('cachedCustomerInfo');
    return value == null ? null : _stringMap(value);
  }

  /// Gets current offerings and published paywall documents for this app.
  Future<Map<String, Object?>> offerings() async =>
      _requireMap(await _invoke<Map<Object?, Object?>>('offerings'));

  /// Links the current anonymous customer to the application's stable customer ID.
  Future<Map<String, Object?>> identify(String customerId) async =>
      _requireMap(await _invoke<Map<Object?, Object?>>('identify', {'customerId': customerId}));

  /// Starts a new anonymous customer identity.
  Future<Map<String, Object?>> logOut() async =>
      _requireMap(await _invoke<Map<Object?, Object?>>('logOut'));

  /// Sets or clears scalar customer attributes.
  Future<Map<String, Object?>> setAttributes(Map<String, Object?> attributes) async =>
      _requireMap(await _invoke<Map<Object?, Object?>>('setAttributes', {'attributes': attributes}));

  /// Starts the native Apple or Google purchase flow for an offering package ID.
  Future<PushifyPurchaseResult> purchase(String packageId) async {
    final value = await _invoke<Map<Object?, Object?>>('purchase', {'packageId': packageId});
    if (value == null) throw const PushifyException('invalid_response', 'The store returned no purchase result.');
    return PushifyPurchaseResult.fromMap(value);
  }

  /// Restores store purchases and synchronizes verified customer state.
  Future<Map<String, Object?>> restorePurchases() async =>
      _requireMap(await _invoke<Map<Object?, Object?>>('restorePurchases'));

  /// Reconciles current store ownership without presenting a purchase UI.
  Future<Map<String, Object?>> syncPurchases() async =>
      _requireMap(await _invoke<Map<Object?, Object?>>('syncPurchases'));

  /// Sends a deduplicated app event. Reuse [eventId] to safely retry that event.
  Future<int> logEvent(String name, {Map<String, Object?> properties = const {}, String? eventId}) async {
    final id = eventId ?? _eventId();
    return await _invoke<int>('logEvent', {'name': name, 'properties': properties, 'eventId': id}) ?? 0;
  }

  /// Atomically spends virtual currencies. Reuse [idempotencyKey] for retries.
  Future<Map<String, Object?>> spendVirtualCurrency({
    required Map<String, int> adjustments,
    required String idempotencyKey,
    String? reference,
  }) async => _requireMap(await _invoke<Map<Object?, Object?>>('spendVirtualCurrency', {
        'adjustments': adjustments,
        'idempotencyKey': idempotencyKey,
        if (reference != null) 'reference': reference,
      }));

  /// Emits verified customer snapshots after login, restore, purchase, or refresh.
  Stream<Map<String, Object?>> get customerInfoUpdates =>
      _events.receiveBroadcastStream().map((value) => _requireMap(value as Map));

  /// Reads an install handoff token after showing the user the pasteboard explanation on iOS.
  Future<String?> readDeferredToken() async => _invoke<String>('readDeferredToken');

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    if (method != 'configure' && method != 'readDeferredToken' && !_configured) {
      throw const PushifyException('not_configured', 'Call configure before using Pushify purchases.');
    }
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw PushifyException(error.code, error.message ?? 'Pushify operation failed.', details: error.details);
    } on MissingPluginException {
      throw const PushifyException('plugin_unavailable', 'The Pushify native plugin is not available on this platform.');
    }
  }

  Map<String, Object?> _requireMap(Map? value) {
    if (value == null) throw const PushifyException('invalid_response', 'The Pushify plugin returned no data.');
    return _stringMap(value);
  }

  String _eventId() {
    final random = Random.secure();
    final suffix = List<int>.generate(16, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'evt_${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }
}

Map<String, Object?> _stringMap(Map value) =>
    value.map((key, value) => MapEntry(key.toString(), value));

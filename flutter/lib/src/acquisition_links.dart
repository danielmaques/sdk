import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';

/// A Pushify link resolved for this app. The app chooses how to navigate.
class PushifyAcquisitionLink {
  const PushifyAcquisitionLink({
    required this.linkId,
    required this.name,
    required this.slug,
    required this.destination,
    required this.appScheme,
    required this.campaign,
    required this.attributed,
    required this.status,
  });

  final String linkId;
  final String name;
  final String slug;
  final String destination;
  final String appScheme;
  final Map<String, String> campaign;
  final bool attributed;
  final String status;

  factory PushifyAcquisitionLink.fromJson(Map<String, dynamic> json) {
    return PushifyAcquisitionLink(
      linkId: json['link_id'] as String,
      name: json['name'] as String,
      slug: json['slug'] as String,
      destination: json['destination'] as String,
      appScheme: json['app_scheme'] as String,
      campaign: (json['campaign'] as Map<String, dynamic>? ?? const {})
          .map((key, value) => MapEntry(key, value.toString())),
      attributed: json['attributed'] as bool? ?? false,
      status: json['status'] as String? ?? 'resolved',
    );
  }
}

/// Typed errors returned by [PushifyAcquisitionLinks.resolve].
class PushifyAcquisitionLinkException implements Exception {
  const PushifyAcquisitionLinkException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'PushifyAcquisitionLinkException: $message';
}

/// Captures direct links and resolves direct or deferred references through Pushify.
class PushifyAcquisitionLinks {
  static const MethodChannel _platform = MethodChannel('app.pushify/purchases');
  PushifyAcquisitionLinks({
    required String publicApiKey,
    Uri apiBaseUrl = const Uri(scheme: 'https', host: 'api.pushify.app'),
    http.Client? client,
  })  : _publicApiKey = publicApiKey,
        _apiBaseUrl = apiBaseUrl,
        _client = client ?? http.Client() {
    if (publicApiKey.isEmpty || apiBaseUrl.scheme != 'https') {
      throw ArgumentError('A public app key and HTTPS API URL are required.');
    }
  }

  final String _publicApiKey;
  final Uri _apiBaseUrl;
  final http.Client _client;
  String? _pendingToken;

  /// Captures the `rdt` token from an incoming Pushify app link.
  bool capture(Uri uri) {
    final token = uri.queryParameters['rdt'];
    if (token == null || !_isToken(token)) return false;
    _pendingToken = token;
    return true;
  }

  /// Reads the deferred Pushify token after explaining the iOS pasteboard prompt to the user.
  /// Android reads the referrer supplied by Google Play. Returns null when unavailable.
  Future<String?> readDeferredToken() async {
    final token = await _platform.invokeMethod<String>('readDeferredToken');
    if (token == null || !_isToken(token) || !token.startsWith('rdit_')) return null;
    _pendingToken = token;
    return token;
  }

  /// Resolves the pending token once, returning null when no valid token was captured.
  Future<PushifyAcquisitionLink?> getInitialLink({String? appUserId}) async {
    final token = _pendingToken;
    if (token == null) return null;
    final link = await resolve(token, appUserId: appUserId);
    if (_pendingToken == token) _pendingToken = null;
    return link;
  }

  /// Resolves a direct `rdlt_` or deferred `rdit_` token.
  Future<PushifyAcquisitionLink> resolve(
    String token, {
    String? appUserId,
  }) async {
    if (!_isToken(token)) {
      throw const PushifyAcquisitionLinkException('Invalid token.');
    }
    final uri = _apiBaseUrl.resolve('/v1/acquisition_links/resolve');
    final response = await _client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $_publicApiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'token': token,
        if (appUserId != null && appUserId.isNotEmpty) 'app_user_id': appUserId,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PushifyAcquisitionLinkException(
        'Link resolution failed.',
        statusCode: response.statusCode,
      );
    }
    if (response.bodyBytes.length > 65536) {
      throw const PushifyAcquisitionLinkException('Response was too large.');
    }
    return PushifyAcquisitionLink.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  void dispose() => _client.close();

  static bool _isToken(String token) =>
      RegExp(r'^(rdlt|rdit)_[A-Za-z0-9_-]{30,80}$').hasMatch(token);
}

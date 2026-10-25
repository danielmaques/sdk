import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';

const _maxResponseBytes = 65536;
const _requestTimeout = Duration(seconds: 10);

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
    final rawCampaign = json['campaign'];
    if (rawCampaign != null && rawCampaign is! Map<String, dynamic>) {
      throw const FormatException('The campaign field must be a JSON object.');
    }

    final rawAttributed = json['attributed'];
    if (rawAttributed != null && rawAttributed is! bool) {
      throw const FormatException('The attributed field must be a boolean.');
    }

    return PushifyAcquisitionLink(
      linkId: json['link_id'] as String,
      name: json['name'] as String,
      slug: json['slug'] as String,
      destination: json['destination'] as String,
      appScheme: json['app_scheme'] as String,
      campaign: (rawCampaign as Map<String, dynamic>? ?? const {}).map(
        (key, value) => MapEntry(key, value.toString()),
      ),
      attributed: rawAttributed as bool? ?? false,
      status: json['status'] as String? ?? 'resolved',
    );
  }
}

/// Typed errors returned by [PushifyAcquisitionLinks.resolve].
class PushifyAcquisitionLinkException implements Exception {
  const PushifyAcquisitionLinkException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => 'PushifyAcquisitionLinkException: $message';
}

/// Captures direct links and resolves direct or deferred references through Pushify.
class PushifyAcquisitionLinks {
  static const MethodChannel _platform = MethodChannel('app.pushify/purchases');
  PushifyAcquisitionLinks({
    required String publicApiKey,
    Uri? apiBaseUrl,
    http.Client? client,
  })  : _publicApiKey = publicApiKey.trim(),
        _apiBaseUrl = apiBaseUrl ?? Uri.https('api.pushify.app', ''),
        _client = client ?? http.Client(),
        _ownsClient = client == null {
    if (publicApiKey.trim().isEmpty ||
        _apiBaseUrl.scheme != 'https' ||
        _apiBaseUrl.host.isEmpty) {
      throw ArgumentError('A public app key and HTTPS API URL are required.');
    }
  }

  final String _publicApiKey;
  final Uri _apiBaseUrl;
  final http.Client _client;
  final bool _ownsClient;
  String? _pendingToken;
  bool _disposed = false;

  /// Captures the `rdt` token from an incoming Pushify app link.
  bool capture(Uri uri) {
    _checkNotDisposed();
    _pendingToken = null;
    final token = uri.queryParameters['rdt'];
    if (token == null || !_isToken(token)) return false;
    _pendingToken = token;
    return true;
  }

  /// Captures and resolves a direct app URL in one call.
  /// Returns `null` when [uri] does not contain a valid Pushify token.
  Future<PushifyAcquisitionLink?> handle(
    Uri uri, {
    String? appUserId,
  }) async {
    if (!capture(uri)) return null;
    return getInitialLink(appUserId: appUserId);
  }

  /// Reads the deferred Pushify token after explaining the iOS pasteboard prompt to the user.
  /// Android reads the referrer supplied by Google Play. Returns null when unavailable.
  Future<String?> readDeferredToken() async {
    _checkNotDisposed();
    final String? token;
    try {
      token = await _platform.invokeMethod<String>('readDeferredToken');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw PushifyAcquisitionLinkException(
        'Could not read the deferred link token.',
        cause: error,
      );
    }
    if (token == null || !_isToken(token) || !token.startsWith('rdit_'))
      return null;
    _pendingToken = token;
    return token;
  }

  /// Reads and resolves a deferred Android or iOS handoff in one call.
  /// Returns `null` when the platform has no supported token available.
  Future<PushifyAcquisitionLink?> resolveDeferredLink({
    String? appUserId,
  }) async {
    final token = await readDeferredToken();
    if (token == null) return null;
    return resolve(token, appUserId: appUserId);
  }

  /// Resolves the pending token once, returning null when no valid token was captured.
  Future<PushifyAcquisitionLink?> getInitialLink({String? appUserId}) async {
    _checkNotDisposed();
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
    _checkNotDisposed();
    if (!_isToken(token)) {
      throw const PushifyAcquisitionLinkException('Invalid token.');
    }
    final uri = _apiBaseUrl.resolve('/v1/acquisition_links/resolve');
    try {
      final response = await _sendBoundedRequest(
        uri,
        jsonEncode({
          'token': token,
          if (appUserId != null && appUserId.isNotEmpty)
            'app_user_id': appUserId,
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PushifyAcquisitionLinkException(
          'Link resolution failed.',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'The server response must be a JSON object.',
        );
      }
      return PushifyAcquisitionLink.fromJson(decoded);
    } on PushifyAcquisitionLinkException {
      rethrow;
    } on TimeoutException catch (error) {
      throw PushifyAcquisitionLinkException(
        'Link resolution timed out.',
        cause: error,
      );
    } on Object catch (error) {
      throw PushifyAcquisitionLinkException(
        'Could not resolve the acquisition link.',
        cause: error,
      );
    }
  }

  Future<http.Response> _sendBoundedRequest(Uri uri, String body) async {
    final request = http.Request('POST', uri)
      ..headers.addAll({
        'Authorization': 'Bearer $_publicApiKey',
        'Content-Type': 'application/json',
      })
      ..body = body;

    return _sendAndReadBounded(request).timeout(_requestTimeout);
  }

  Future<http.Response> _sendAndReadBounded(http.Request request) async {
    final streamed = await _client.send(request);
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in streamed.stream) {
        if (bytes.length + chunk.length > _maxResponseBytes) {
          throw const PushifyAcquisitionLinkException(
            'Pushify response was too large.',
          );
        }
        bytes.add(chunk);
      }
    } on PushifyAcquisitionLinkException {
      rethrow;
    }

    return http.Response.bytes(
      bytes.takeBytes(),
      streamed.statusCode,
      request: request,
      headers: streamed.headers,
      isRedirect: streamed.isRedirect,
      persistentConnection: streamed.persistentConnection,
      reasonPhrase: streamed.reasonPhrase,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsClient) _client.close();
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw const PushifyAcquisitionLinkException(
        'This PushifyAcquisitionLinks instance has been disposed.',
      );
    }
  }

  static bool _isToken(String token) =>
      RegExp(r'^(rdlt|rdit)_[A-Za-z0-9_-]{30,80}$').hasMatch(token);
}

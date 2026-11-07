part of 'paywall.dart';

extension _PaywallLocalization on _PushifyPaywallState {
  String _localized(
    Map<String, Object?> node,
    Map<String, Object?> screen, [
    String fallback = '',
  ]) {
    final key = _map(node['properties'])['text_lid'];
    if (key is String) {
      final localizations = _map(screen['localizations']);
      final locales = _map(widget.document['locales']);
      for (final locale in [
        widget.locale,
        widget.document['default_locale'] as String?,
        'en_US',
      ]) {
        if (locale == null) continue;
        final value =
            _map(localizations[locale])[key] ?? _map(locales[locale])[key];
        if (value is String) return _interpolate(value);
      }
    }
    return fallback.isNotEmpty
        ? _interpolate(fallback)
        : _interpolate(_map(node['properties'])['text'] as String? ?? '');
  }

  String _interpolate(String value) => value.replaceAllMapped(
    RegExp(r'\{\{\s*(?:state\.([A-Za-z_][A-Za-z0-9_]*)|callbacks\.([A-Za-z_][A-Za-z0-9_]*)\.data\.([A-Za-z_][A-Za-z0-9_.-]*))\s*\}\}'),
    (match) {
      final stateName = match[1];
      if (stateName != null) {
        if (!_variables.containsKey(stateName)) return match[0]!;
        final stateValue = _variables[stateName];
        return stateValue is List ? stateValue.join(', ') : '$stateValue';
      }
      final callbackName = match[2], dataKey = match[3];
      final result = callbackName == null || dataKey == null ? null : _callbackData[callbackName]?[dataKey];
      return result == null ? match[0]! : '$result';
    },
  );

  String? _localizedValue(String key, Map<String, Object?> screen) {
    final perScreen = _map(screen['localizations']);
    final locales = _map(widget.document['locales']);
    for (final locale in [
      widget.locale,
      Localizations.maybeLocaleOf(context)?.toString(),
      widget.document['default_locale'] as String?,
      'en_US',
    ]) {
      if (locale == null) continue;
      for (final candidate in {
        locale,
        locale.replaceAll('-', '_'),
        locale.replaceAll('_', '-'),
      }) {
        final value =
            _map(perScreen[candidate])[key] ?? _map(locales[candidate])[key];
        if (value is String) return _interpolate(value);
      }
    }
    return null;
  }

  Color _background(Map<String, Object?> background, Color fallback) {
    final hex = _map(_map(background['value'])['light'])['value'];
    if (hex is! String) return fallback;
    final normalized = hex.replaceAll('#', '');
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) return fallback;
    final argb = normalized.length == 8
        ? ((parsed & 0xff) << 24) | (parsed >> 8)
        : 0xff000000 | parsed;
    return Color(argb);
  }

  FontWeight _fontWeight(Object? value) => switch (value) {
    'bold' => FontWeight.bold,
    'semibold' => FontWeight.w600,
    'medium' => FontWeight.w500,
    'light' => FontWeight.w300,
    _ => FontWeight.normal,
  };
  double? _number(Object? value) => value is num ? value.toDouble() : null;
  String? _findSelectedPackage(Map<String, Object?> node) {
    if (node['kind'] == 'package' &&
        _map(node['properties'])['is_selected_by_default'] == true) {
      return _map(node['properties'])['package_id'] as String?;
    }
    for (final child in _maps(node['children'])) {
      final found = _findSelectedPackage(child);
      if (found != null) return found;
    }
    return null;
  }
}

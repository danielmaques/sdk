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
    RegExp(
      r'\{\{\s*(?:state\.([A-Za-z_][A-Za-z0-9_]*)|callbacks\.([A-Za-z_][A-Za-z0-9_]*)\.data\.([A-Za-z_][A-Za-z0-9_.-]*)|products\.(purchased|abandoned)\.([A-Za-z_][A-Za-z0-9_]*))\s*\}\}',
    ),
    (match) {
      final stateName = match[1];
      if (stateName != null) {
        if (!_variables.containsKey(stateName)) return match[0]!;
        final stateValue = _variables[stateName];
        return stateValue is List ? stateValue.join(', ') : '$stateValue';
      }
      final callbackName = match[2], dataKey = match[3];
      if (callbackName == null && match[4] != null && match[5] != null) {
        final product = _transactionProducts[match[4]!];
        final field = match[5]!;
        if (product == null) return match[0]!;
        final peers = _maps(
          widget.offering['packages'],
        ).map((item) => _map(item['product'])).toList();
        final result = _productAliasValue(field, product, peers);
        return result ?? match[0]!;
      }
      final result = callbackName == null || dataKey == null
          ? null
          : _callbackData[callbackName]?[dataKey];
      return result == null ? match[0]! : '$result';
    },
  );

  String? _productAliasValue(
    String field,
    Map<String, Object?> product,
    List<Map<String, Object?>> peers,
  ) {
    final variableLocalizations = _map(
      widget.offering['variable_localizations'],
    );
    final locale =
        widget.locale ??
        Localizations.maybeLocaleOf(context)?.toString() ??
        'en_US';
    final words = _map(
      variableLocalizations[locale] ??
          variableLocalizations[locale.replaceAll('-', '_')] ??
          variableLocalizations['en_US'],
    );
    final period = _productPeriod(product['duration'] as String?);
    final trial = _productPeriod(product['trial_duration'] as String?);
    final currency = product['currency_code'] as String?;
    final amount = double.tryParse('${product['price_amount']}');
    NumberFormat? currencyFormat() => currency == null
        ? null
        : NumberFormat.currency(
            locale: locale.replaceAll('-', '_'),
            name: currency,
          );
    String? money(double value) => currencyFormat()?.format(value);
    String? currencySymbol() => currencyFormat()?.currencySymbol;
    double unitsIn(_ProductPeriod value, String target) {
      const factors = <String, Map<String, double>>{
        'day': {'day': 1, 'week': 1 / 7, 'month': 1 / 30, 'year': 1 / 365},
        'week': {'day': 7, 'week': 1, 'month': 7 * 12 / 365, 'year': 7 / 365},
        'month': {'day': 30, 'week': 365 / 12 / 7, 'month': 1, 'year': 1 / 12},
        'year': {'day': 365, 'week': 365 / 7, 'month': 12, 'year': 1},
      };
      return value.count * factors[value.unit]![target]!;
    }

    String plural(_ProductPeriod value) =>
        (words['num_${value.unit}_${value.count == 1 ? 'one' : 'other'}']
                    as String? ??
                '%d ${value.unit}${value.count == 1 ? '' : 's'}')
            .replaceAll('%d', '${value.count}');
    String unit(_ProductPeriod value, {bool short = false}) {
      if (value.count > 1) {
        final key = short
            ? 'num_${value.unit}s_short'
            : 'num_${value.unit}_other';
        return (words[key] as String? ??
                (short ? '%d${value.unit[0]}' : '%d ${value.unit}s'))
            .replaceAll('%d', '${value.count}');
      }
      return words[short ? '${value.unit}_short' : value.unit] as String? ??
          value.unit;
    }

    switch (field) {
      case 'price':
      case 'localized_price':
        return product['localized_price'] as String?;
      case 'product_id':
        return product['product_id'] as String?;
      case 'store_product_name':
        return product['display_name'] as String?;
      case 'currency_code':
        return product['currency_code'] as String?;
      case 'currency_symbol':
        return currencySymbol();
      case 'period':
        return period == null ? '' : unit(period);
      case 'period_abbreviated':
        return period == null ? '' : unit(period, short: true);
      case 'periodly':
        if (period == null) return '';
        return period.count > 1
            ? plural(period)
            : words[{
                        'day': 'daily',
                        'week': 'weekly',
                        'month': 'monthly',
                        'year': 'yearly',
                      }[period.unit]]
                      as String? ??
                  '';
      case 'period_with_unit':
        return period == null ? '' : plural(period);
      case 'period_in_days':
      case 'period_in_weeks':
      case 'period_in_months':
      case 'period_in_years':
        if (period == null) return '';
        final target = field
            .replaceFirst('period_in_', '')
            .replaceFirst(RegExp(r's$'), '');
        return '${unitsIn(period, target).round()}';
      case 'price_per_period':
      case 'price_per_period_abbreviated':
        final price = product['localized_price'] as String?;
        return price == null || period == null
            ? price
            : '$price/${unit(period, short: field.endsWith('abbreviated'))}';
      case 'price_per_day':
      case 'price_per_week':
      case 'price_per_month':
      case 'price_per_year':
        if (amount == null) return null;
        final target = field.replaceFirst('price_per_', '');
        final units = period == null ? null : unitsIn(period, target);
        if (units == null || units <= 0) return money(amount);
        final formatter = currencyFormat();
        if (formatter == null) return null;
        final scale = math.pow(10, formatter.maximumFractionDigits).toDouble();
        return formatter.format((amount / units * scale).floor() / scale);
      case 'offer_price':
      case 'offer_price_per_day':
      case 'offer_price_per_week':
      case 'offer_price_per_month':
      case 'offer_price_per_year':
        return trial == null
            ? product['localized_price'] as String?
            : words['free_price'] as String? ?? 'free';
      case 'offer_price_with_zero':
        return trial == null ? product['localized_price'] as String? : money(0);
      case 'offer_period':
        return trial == null
            ? ''
            : unit(_ProductPeriod(1, trial.unit, trial.days));
      case 'offer_period_abbreviated':
        return trial == null
            ? ''
            : unit(_ProductPeriod(1, trial.unit, trial.days), short: true);
      case 'offer_period_with_unit':
        return trial == null ? '' : plural(trial);
      case 'offer_period_in_days':
      case 'offer_period_in_weeks':
      case 'offer_period_in_months':
      case 'offer_period_in_years':
        if (trial == null) return '';
        final target = field
            .replaceFirst('offer_period_in_', '')
            .replaceFirst(RegExp(r's$'), '');
        return '${unitsIn(trial, target).round()}';
      case 'offer_end_date':
        return trial == null
            ? ''
            : 'in ${trial.days} day${trial.days == 1 ? '' : 's'}';
      case 'relative_discount':
        if (amount == null || period == null || currency == null) return '';
        final mine = amount / unitsIn(period, 'month');
        final otherMonthlyPrices = peers
            .where((peer) => peer['currency_code'] == currency)
            .map((peer) {
              final peerPrice = double.tryParse('${peer['price_amount']}');
              final peerPeriod = _productPeriod(peer['duration'] as String?);
              return peerPrice == null || peerPeriod == null
                  ? null
                  : peerPrice / unitsIn(peerPeriod, 'month');
            })
            .whereType<double>()
            .toList();
        if (otherMonthlyPrices.isEmpty) return '';
        final top = otherMonthlyPrices.reduce((a, b) => a > b ? a : b);
        final percent = top > mine ? ((1 - mine / top) * 100).round() : 0;
        return percent > 0
            ? (words['percent'] as String? ?? '%d%%')
                  .replaceAll('%d', '$percent')
                  .replaceAll('%%', '%')
            : '';
      case 'secondary_offer_price':
      case 'secondary_offer_period':
      case 'secondary_offer_period_abbreviated':
        return '';
      default:
        return null;
    }
  }

  _ProductPeriod? _productPeriod(String? iso) {
    if (iso == null) return null;
    final match = RegExp(
      r'^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$',
    ).firstMatch(iso);
    if (match == null) return null;
    final parts = <(int, String, int)>[
      (int.tryParse(match[1] ?? '') ?? 0, 'year', 365),
      (int.tryParse(match[2] ?? '') ?? 0, 'month', 30),
      (int.tryParse(match[3] ?? '') ?? 0, 'week', 7),
      (int.tryParse(match[4] ?? '') ?? 0, 'day', 1),
    ].where((part) => part.$1 > 0).toList();
    if (parts.isEmpty) return null;
    if (parts.length == 1) {
      return _ProductPeriod(
        parts.single.$1,
        parts.single.$2,
        parts.single.$1 * parts.single.$3,
      );
    }
    final days = parts.fold<int>(0, (total, part) => total + part.$1 * part.$3);
    return _ProductPeriod(days, 'day', days);
  }

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

  Color _background(
    Map<String, Object?> background,
    Color fallback, {
    bool dark = false,
  }) {
    final values = _map(background['value']);
    final variant = _map((dark ? values['dark'] : null) ?? values['light']);
    final hex = variant['value'] ?? _maps(variant['points']).firstOrNull?['color'];
    if (hex is! String) return fallback;
    final normalized = hex.replaceAll('#', '');
    final parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) return fallback;
    final argb = normalized.length == 8
        ? ((parsed & 0xff) << 24) | (parsed >> 8)
        : 0xff000000 | parsed;
    return Color(argb);
  }

  BoxDecoration _backgroundDecoration(
    Map<String, Object?> background,
    Color fallback, {
    bool dark = false,
  }
  ) {
    final values = _map(background['value']);
    final variant = _map((dark ? values['dark'] : null) ?? values['light']);
    final points = _maps(variant['points']);
    if (variant['type'] != 'linear' || points.isEmpty) {
      return BoxDecoration(color: _background(background, fallback, dark: dark));
    }
    final colors = points.map((point) {
      final hex = point['color'];
      if (hex is! String) return fallback;
      final value = hex.replaceFirst('#', '');
      final parsed = int.tryParse(value, radix: 16);
      if (parsed == null) return fallback;
      return Color(value.length == 8
          ? ((parsed & 0xff) << 24) | (parsed >> 8)
          : 0xff000000 | parsed);
    }).toList();
    final angle = ((_number(variant['degrees']) ?? 180) * math.pi / 180);
    final dx = math.sin(angle);
    final dy = -math.cos(angle);
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment(-dx, -dy),
        end: Alignment(dx, dy),
        colors: colors,
        stops: points.map((point) => (_number(point['percent']) ?? 0).clamp(0, 100) / 100).toList(),
      ),
    );
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

class _ProductPeriod {
  const _ProductPeriod(this.count, this.unit, this.days);
  final int count;
  final String unit;
  final int days;
}

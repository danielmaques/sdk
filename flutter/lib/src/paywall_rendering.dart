part of 'paywall.dart';

extension _PaywallRendering on _PushifyPaywallState {
  Widget _render(Map<String, Object?> node, Map<String, Object?> screen) {
    final properties = _map(node['properties']);
    return _decorateNode(_renderContent(node, screen), properties);
  }

  Widget _renderContent(Map<String, Object?> node, Map<String, Object?> screen) {
    final kind = node['kind'] as String? ?? '';
    final properties = _map(node['properties']);
    final children = _maps(node['children']);
    switch (kind) {
      case 'stack':
        final dimension = _map(properties['dimension']);
        final direction = dimension['type'] as String? ?? 'vertical';
        final alignment = dimension['alignment'] as String? ?? 'center';
        final spacing = (_number(properties['spacing']) ?? 0)
            .clamp(0, 100000)
            .toDouble();
        if (direction == 'zlayer') {
          return Stack(
            alignment: _stackAlignment(alignment),
            children: children
                .map((child) => Align(
                      alignment: _stackAlignment(alignment),
                      child: _render(child, screen),
                    ))
                .toList(),
          );
        }
        final horizontal = direction == 'horizontal';
        final distribution = dimension['distribution'] as String? ?? 'start';
        final rendered = <Widget>[];
        for (var index = 0; index < children.length; index++) {
          final child = children[index];
          var widget = _render(child, screen);
          final childSize = _map(_map(child['properties'])['size']);
          final mainSize = _map(childSize[horizontal ? 'width' : 'height']);
          if (horizontal && mainSize['type'] == 'fill') {
            widget = Expanded(child: widget);
          }
          rendered.add(widget);
          if (index < children.length - 1 && spacing > 0) {
            rendered.add(SizedBox(
              width: horizontal ? spacing : null,
              height: horizontal ? null : spacing,
            ));
          }
        }
        return horizontal
            ? Row(
                mainAxisAlignment: _mainAxisAlignment(distribution),
                crossAxisAlignment: _crossAxisAlignment(alignment, horizontal: true),
                children: rendered,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: _mainAxisAlignment(distribution),
                crossAxisAlignment: _crossAxisAlignment(alignment, horizontal: false),
                children: rendered,
              );
      case 'hstack':
        return Row(
          mainAxisSize: MainAxisSize.max,
          children: children
              .map(
                (child) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _render(child, screen),
                  ),
                ),
              )
              .toList(),
        );
      case 'text':
      case 'title':
        return Text(
          _localized(node, screen),
          textAlign: _textAlignment(properties['horizontal_alignment'] as String?),
          style: TextStyle(
            fontSize: _number(properties['font_size']) ?? 20,
            fontWeight: _fontWeight(properties['font_weight']),
            color: _color(properties['color'], Theme.of(context).colorScheme.onSurface),
            fontFamily: properties['font_name'] as String?,
          ),
        );
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
          label:
              '${_localized(node, screen, properties['label'] as String? ?? product['display_name'] as String? ?? packageId ?? '')}, ${product['localized_price'] ?? ''}',
          child: OutlinedButton(
            onPressed: () => _update(() => _selectedPackage = packageId ?? ''),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                width: selected ? 2 : 1,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _localized(
                          node,
                          screen,
                          properties['label'] as String? ??
                              product['display_name'] as String? ??
                              packageId ??
                              '',
                        ),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (product['localized_price'] != null)
                        Text(
                          product['localized_price'] as String,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      case 'purchase_button':
      case 'cta':
        return FilledButton(
          onPressed: _busy || _selectedPackage.isEmpty
              ? null
              : () => _buy(screen: screen),
          child: _busy
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : children.isNotEmpty
              ? Column(
                  children: children
                      .map((child) => _render(child, screen))
                      .toList(),
                )
              : Text(_localized(node, screen, 'Continue')),
        );
      case 'restore_button':
        return TextButton(
          onPressed: _busy ? null : _restore,
          child: Text(_localized(node, screen, 'Restore purchases')),
        );
      case 'button':
        final action = _map(properties['action']);
        return _ActionFeedback(
          animation: action['animation'] as String? ?? 'none',
          child: TextButton(
            onPressed: () {
              _performActionHaptics(action['haptics'] as String?);
              _handleButton(node, screen);
            },
            child: children.isNotEmpty
                ? Column(
                    children: children
                        .map((child) => _render(child, screen))
                        .toList(),
                  )
                : Text(_localized(node, screen, 'Continue')),
          ),
        );
      case 'spacer':
        return SizedBox(height: _number(properties['size']) ?? 8);
      case 'image':
        final sources = _map(properties['source']);
        final dark = Theme.of(context).brightness == Brightness.dark;
        final chosen = _map(sources[dark ? 'dark' : 'light']);
        final source = chosen.isNotEmpty ? chosen : _map(sources['light']);
        final url = (source['url'] ?? source['original']) as String?;
        return url == null || !url.startsWith('https://')
            ? const SizedBox.shrink()
            : Image.network(
                url,
                fit: _boxFit(properties['fit_mode'] as String?),
                errorBuilder: (context, error, stackTrace) =>
                    const SizedBox.shrink(),
                semanticLabel: properties['accessibility_label'] as String?,
              );
      case 'video':
        return _video(properties);
      case 'web_view':
        return _webView(properties, screen);
      case 'icon':
        final name = (properties['icon_name'] as String? ?? 'star')
            .toLowerCase();
        final glyph = switch (name) {
          'check' || 'checkmark' => Icons.check,
          'star' => Icons.star,
          'bell' => Icons.notifications,
          'lock' => Icons.lock,
          'unlock' => Icons.lock_open,
          'heart' => Icons.favorite,
          'clock' => Icons.schedule,
          'sparkles' => Icons.auto_awesome,
          _ => Icons.circle,
        };
        final size = _sizeValue(properties['size']) ?? 24;
        return Icon(
          glyph,
          size: size,
          color: _color(
            _map(properties['color'])['light'] is Map
                ? _map(_map(properties['color'])['light'])['value']
                : properties['color'],
            Theme.of(context).colorScheme.primary,
          ),
          semanticLabel: properties['accessibility_label'] as String?,
        );
      case 'timeline':
        final items = _maps(properties['items']);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < items.length; i++)
              _timelineItem(items[i], screen, i < items.length - 1),
          ],
        );
      case 'carousel':
        final pages = _maps(properties['pages']);
        if (pages.isEmpty) return const SizedBox.shrink();
        final id = node['id'] as String? ?? 'carousel';
        final page =
            (_carouselPages[id] ??
                    (_number(properties['initial_page_index']) ?? 0).toInt())
                .clamp(0, pages.length - 1);
        final control = _map(properties['page_control']);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _number(_map(properties['size'])['height']) ?? 220,
              child: PageView.builder(
                controller: _carouselControllers.putIfAbsent(
                  id,
                  () => PageController(initialPage: page),
                ),
                itemCount: pages.length,
                onPageChanged: (value) =>
                    _update(() => _carouselPages[id] = value),
                itemBuilder: (context, index) =>
                    _renderRaw(pages[index], screen),
              ),
            ),
            if (pages.length > 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < pages.length; i++)
                      Container(
                        width: i == page ? 18 : 6,
                        height: 6,
                        margin: EdgeInsets.symmetric(
                          horizontal: _number(control['spacing']) ?? 3,
                        ),
                        decoration: BoxDecoration(
                          color: i == page
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        );
      case 'tabs':
        final tabs = _maps(properties['tabs']);
        if (tabs.isEmpty) return const SizedBox.shrink();
        final id = node['id'] as String? ?? 'tabs';
        final chosen =
            _selectedTabs[id] ??
            properties['default_tab_id'] as String? ??
            tabs.first['id'] as String? ??
            '';
        final active = tabs.firstWhere(
          (tab) => tab['id'] == chosen,
          orElse: () => tabs.first,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              children: [
                for (final tab in tabs)
                  ChoiceChip(
                    label: Text(tab['name'] as String? ?? ''),
                    selected: tab['id'] == chosen,
                    onSelected: (_) => _update(
                      () => _selectedTabs[id] = tab['id'] as String? ?? '',
                    ),
                  ),
              ],
            ),
            _renderRaw(_map(active['stack']), screen),
          ],
        );
      case 'countdown':
        final rawDate = _map(properties['style'])['date'] as String?;
        final date = rawDate == null
            ? null
            : DateTime.tryParse(rawDate)?.toLocal();
        final left = date == null ? Duration.zero : date.difference(_now);
        final active = left.isNegative || date == null
            ? _map(properties['end_stack'])
            : _map(properties['countdown_stack']);
        final days = left.inSeconds.clamp(0, 1 << 30) ~/ 86400;
        final hours = left.inHours.remainder(24).toString().padLeft(2, '0');
        final minutes = left.inMinutes.remainder(60).toString().padLeft(2, '0');
        final seconds = left.inSeconds.remainder(60).toString().padLeft(2, '0');
        return _renderRaw(
          _replaceCountdownTokens(_map(active), days, hours, minutes, seconds),
          screen,
        );
      case 'tab_control':
        return const SizedBox.shrink();
      default:
        if (children.isNotEmpty) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: children.map((child) => _render(child, screen)).toList(),
          );
        }
        return Text(properties['text'] as String? ?? '');
    }
  }

  Widget _renderRaw(Map<String, Object?> raw, Map<String, Object?> screen) {
    final kind = raw['kind'] as String? ?? raw['type'] as String? ?? '';
    final props =
        raw['properties'] is Map
              ? _map(raw['properties'])
              : Map<String, Object?>.from(raw)
          ..remove('type')
          ..remove('components')
          ..remove('children')
          ..remove('id');
    props.remove('kind');
    final children = _maps(raw['children']).isNotEmpty
        ? _maps(raw['children'])
        : _maps(raw['components']);
    return _render({
      'kind': kind,
      'properties': props,
      'children': children,
      'id': raw['id'],
    }, screen);
  }

  Widget _decorateNode(Widget child, Map<String, Object?> properties) {
    final size = _map(properties['size']);
    final widthSize = _map(size['width']);
    final heightSize = _map(size['height']);
    final width = widthSize['type'] == 'fixed'
        ? _number(widthSize['value'])
        : widthSize['type'] == 'fill'
        ? double.infinity
        : null;
    final height = heightSize['type'] == 'fixed'
        ? _number(heightSize['value'])
        : null;
    final widthFactor = widthSize['type'] == 'relative'
        ? _number(widthSize['value'])
        : null;
    final heightFactor = heightSize['type'] == 'relative'
        ? _number(heightSize['value'])
        : null;
    final padding = _edgeInsets(properties['padding']);
    final margin = _edgeInsets(properties['margin']);
    final background = _map(properties['background']);
    final colorValue = background['type'] == 'color'
        ? background['value']
        : properties['background_color'];
    final gradientValue = _map(background['value']);
    final gradient = gradientValue['type'] == 'linear'
        ? _linearGradient(gradientValue)
        : gradientValue['type'] == 'radial'
        ? _radialGradient(gradientValue)
        : null;
    final shape = _map(properties['shape']);
    final corners = _map(shape['corners']);
    final radius = BorderRadiusDirectional.only(
      topStart: Radius.circular(_number(corners['top_leading']) ?? 0),
      topEnd: Radius.circular(_number(corners['top_trailing']) ?? 0),
      bottomStart: Radius.circular(_number(corners['bottom_leading']) ?? 0),
      bottomEnd: Radius.circular(_number(corners['bottom_trailing']) ?? 0),
    );
    final border = _map(properties['border']);
    final shadow = _map(properties['shadow']);
    final hasDecoration = colorValue != null || gradient != null ||
        shape.isNotEmpty || border.isNotEmpty || shadow.isNotEmpty;
    child = Container(
      width: width,
      height: height,
      padding: padding,
      decoration: hasDecoration
          ? BoxDecoration(
              color: colorValue == null || gradient != null
                  ? null
                  : _color(colorValue, Colors.transparent),
              gradient: gradient,
              borderRadius: shape['type'] == 'pill'
                  ? BorderRadiusDirectional.circular(9999)
                  : shape.isEmpty
                  ? null
                  : radius,
              border: border.isEmpty
                  ? null
                  : Border.all(
                      color: _color(border['color'], Colors.transparent),
                      width: (_number(border['width']) ?? 1).clamp(0, 100).toDouble(),
                    ),
              boxShadow: shadow.isEmpty
                  ? null
                  : [
                      BoxShadow(
                        color: _color(shadow['color'], Colors.transparent),
                        blurRadius: (_number(shadow['radius']) ?? 0).clamp(0, 1000).toDouble(),
                        offset: Offset(_number(shadow['x']) ?? 0, _number(shadow['y']) ?? 0),
                      ),
                    ],
            )
          : null,
      child: child,
    );
    if (widthFactor != null || heightFactor != null) {
      child = FractionallySizedBox(
        widthFactor: widthFactor?.clamp(0, 1).toDouble(),
        heightFactor: heightFactor?.clamp(0, 1).toDouble(),
        alignment: AlignmentDirectional.topStart,
        child: child,
      );
    }
    if (margin != EdgeInsetsDirectional.zero) {
      child = Padding(padding: margin, child: child);
    }
    return child;
  }

  EdgeInsetsDirectional _edgeInsets(Object? value) {
    final sides = _map(value);
    return EdgeInsetsDirectional.fromSTEB(
      _number(sides['leading']) ?? 0,
      _number(sides['top']) ?? 0,
      _number(sides['trailing']) ?? 0,
      _number(sides['bottom']) ?? 0,
    );
  }

  MainAxisAlignment _mainAxisAlignment(String value) => switch (value) {
    'center' => MainAxisAlignment.center,
    'end' => MainAxisAlignment.end,
    'space_between' => MainAxisAlignment.spaceBetween,
    'space_around' => MainAxisAlignment.spaceAround,
    'space_evenly' => MainAxisAlignment.spaceEvenly,
    _ => MainAxisAlignment.start,
  };

  CrossAxisAlignment _crossAxisAlignment(
    String value, {
    required bool horizontal,
  }) => switch ((horizontal, value)) {
    (true, 'top') => CrossAxisAlignment.start,
    (true, 'bottom') => CrossAxisAlignment.end,
    (false, 'leading') => CrossAxisAlignment.start,
    (false, 'trailing') => CrossAxisAlignment.end,
    (_, 'center') => CrossAxisAlignment.center,
    _ => CrossAxisAlignment.stretch,
  };

  TextAlign _textAlignment(String? value) => switch (value) {
    'leading' => TextAlign.start,
    'trailing' => TextAlign.end,
    'left' => TextAlign.left,
    'right' => TextAlign.right,
    'justify' => TextAlign.justify,
    _ => TextAlign.center,
  };

  AlignmentGeometry _stackAlignment(String? value) => switch (value) {
    'leading' => AlignmentDirectional.centerStart,
    'trailing' => AlignmentDirectional.centerEnd,
    'top' => Alignment.topCenter,
    'bottom' => Alignment.bottomCenter,
    'top_leading' => AlignmentDirectional.topStart,
    'top_trailing' => AlignmentDirectional.topEnd,
    'bottom_leading' => AlignmentDirectional.bottomStart,
    'bottom_trailing' => AlignmentDirectional.bottomEnd,
    _ => Alignment.center,
  };

  BoxFit _boxFit(String? value) => value == 'fit' ? BoxFit.contain : BoxFit.cover;

  double? _sizeValue(Object? value) {
    final dimension = _map(value);
    return _number(dimension['value']) ?? _number(dimension['width'] is Map ? _map(dimension['width'])['value'] : null);
  }

  LinearGradient _linearGradient(Map<String, Object?> value) {
    final points = _maps(value['points']);
    final colors = points.map((point) => _color(point['color'], Colors.transparent)).toList();
    final stops = points.map((point) => (_number(point['percent']) ?? 0).clamp(0, 100).toDouble() / 100).toList();
    final degrees = (_number(value['degrees']) ?? 180) * 3.141592653589793 / 180;
    final center = Alignment(cos(degrees), sin(degrees));
    return LinearGradient(
      begin: Alignment(-center.x, -center.y),
      end: center,
      colors: colors.length > 1 ? colors : [Colors.transparent, Colors.transparent],
      stops: stops.length == colors.length && colors.length > 1 ? stops : null,
    );
  }

  RadialGradient _radialGradient(Map<String, Object?> value) {
    final points = _maps(value['points']);
    final colors = points.map((point) => _color(point['color'], Colors.transparent)).toList();
    final stops = points.map((point) => (_number(point['percent']) ?? 0).clamp(0, 100).toDouble() / 100).toList();
    return RadialGradient(
      colors: colors.length > 1 ? colors : [Colors.transparent, Colors.transparent],
      stops: stops.length == colors.length && colors.length > 1 ? stops : null,
    );
  }

  Widget _timelineItem(
    Map<String, Object?> item,
    Map<String, Object?> screen,
    bool connector,
  ) {
    final icon = _map(item['icon']);
    final iconName = icon['icon_name'] as String? ?? 'check';
    final glyph = switch (iconName) {
      'check' || 'checkmark' => Icons.check,
      'bell' => Icons.notifications,
      'star' => Icons.star,
      'unlock' => Icons.lock_open,
      _ => Icons.circle,
    };
    final title = _map(item['title']);
    final description = _map(item['description']);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              CircleAvatar(radius: 14, child: Icon(glyph, size: 16)),
              if (connector)
                Expanded(
                  child: Container(
                    width: 2,
                    color: Theme.of(context).colorScheme.outlineVariant,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty) _renderRaw(title, screen),
                  if (description.isNotEmpty) _renderRaw(description, screen),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Map<String, Object?> _replaceCountdownTokens(
    Map<String, Object?> node,
    int days,
    String hours,
    String minutes,
    String seconds,
  ) {
    final result = Map<String, Object?>.from(node);
    if (result['properties'] is Map) {
      final properties = _map(result['properties']);
      if (properties['text'] is String) {
        properties['text'] = _countdownText(
          properties['text'] as String,
          days,
          hours,
          minutes,
          seconds,
        );
      }
      result['properties'] = properties;
    }
    if (result['text'] is String) {
      result['text'] = _countdownText(
        result['text'] as String,
        days,
        hours,
        minutes,
        seconds,
      );
    }
    final components = _maps(result['components'])
        .map(
          (child) =>
              _replaceCountdownTokens(child, days, hours, minutes, seconds),
        )
        .toList();
    if (result['components'] is List) result['components'] = components;
    final children = _maps(result['children'])
        .map(
          (child) =>
              _replaceCountdownTokens(child, days, hours, minutes, seconds),
        )
        .toList();
    if (result['children'] is List) result['children'] = children;
    return result;
  }

  String _countdownText(
    String value,
    int days,
    String hours,
    String minutes,
    String seconds,
  ) => value
      .replaceAll('{{ count_days_without_zero }}', '$days')
      .replaceAll('{{ count_hours_with_zero }}', hours)
      .replaceAll('{{ count_minutes_with_zero }}', minutes)
      .replaceAll('{{ count_seconds_with_zero }}', seconds);

  Color _color(Object? value, Color fallback) {
    if (value is Map) {
      final object = _map(value);
      final dark = Theme.of(context).brightness == Brightness.dark;
      final variant = _map(object[dark ? 'dark' : 'light']);
      final selected = variant.isNotEmpty ? variant : object;
      final nestedValue = _map(selected['value']);
      value = selected['value'] ?? nestedValue['value'];
    }
    if (value is! String) return fallback;
    final hex = value.replaceFirst('#', '');
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return fallback;
    return Color(
      hex.length == 8
          ? ((parsed & 0xff) << 24) | (parsed >> 8)
          : 0xff000000 | parsed,
    );
  }
}

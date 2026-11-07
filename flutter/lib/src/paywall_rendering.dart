part of 'paywall.dart';

extension _PaywallRendering on _PushifyPaywallState {
  Widget _video(Map<String, Object?> properties) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final sources = _map(properties['source']);
    final selected = _map(sources[dark ? 'dark' : 'light']);
    final source = selected.isNotEmpty ? selected : _map(sources['light']);
    final url = source['url'] as String?;
    final fallback = _map(properties['fallback_source']);
    final selectedPoster = _map(fallback[dark ? 'dark' : 'light']);
    final posterSource = selectedPoster.isNotEmpty
        ? selectedPoster
        : _map(fallback['light']);
    final posterUrl =
        (posterSource['original'] ?? posterSource['url']) as String?;
    final fitMode = properties['fit_mode'] == 'fit' ? 'fit' : 'fill';
    final supported =
        url != null &&
        url.startsWith('https://') &&
        (Platform.isAndroid || Platform.isIOS);
    if (!supported) return _videoPoster(posterUrl, fitMode);

    final player = <String, Object?>{
      'url': url,
      'posterUrl': posterUrl,
      'autoPlay': properties['auto_play'] as bool? ?? true,
      'loop': properties['loop'] as bool? ?? true,
      'muted': properties['mute_audio'] as bool? ?? true,
      'showControls': properties['show_controls'] as bool? ?? false,
      'fitMode': fitMode,
      'accessibilityLabel':
          properties['accessibility_label'] as String? ?? 'Video',
    };
    final native = Platform.isAndroid
        ? AndroidView(
            key: ValueKey('pushify-video-$url'),
            viewType: 'app.pushify/paywall-video',
            creationParams: player,
            creationParamsCodec: const StandardMessageCodec(),
          )
        : UiKitView(
            key: ValueKey('pushify-video-$url'),
            viewType: 'app.pushify/paywall-video',
            layoutDirection: TextDirection.ltr,
            creationParams: player,
            creationParamsCodec: const StandardMessageCodec(),
          );
    final sourceWidth = (_number(source['width']) ?? 1)
        .clamp(1, 100000)
        .toDouble();
    final sourceHeight = (_number(source['height']) ?? 1)
        .clamp(1, 100000)
        .toDouble();
    final size = _map(properties['size']);
    final heightSize = _map(size['height']);
    final fixedHeight = heightSize['type'] == 'fixed'
        ? _number(heightSize['value'])
        : null;
    final surface = ClipRect(child: native);
    return fixedHeight == null
        ? AspectRatio(aspectRatio: sourceWidth / sourceHeight, child: surface)
        : SizedBox(height: fixedHeight, width: double.infinity, child: surface);
  }

  Widget _webView(
    Map<String, Object?> properties,
    Map<String, Object?> screen,
  ) {
    final url = properties['url'] as String? ?? '';
    final fallbackNode = _map(properties['fallback']);
    final fallback = fallbackNode.isEmpty
        ? null
        : _render(fallbackNode, screen);
    final protocolVersion =
        _number(properties['protocol_version'])?.toInt() ?? 1;
    final size = _map(properties['size']);
    final height = _map(size['height']);
    final fixedHeight = height['type'] == 'fixed'
        ? _number(height['value'])
        : null;
    final heightValue = (fixedHeight ?? 240).clamp(1, 100000).toDouble();
    final uri = Uri.tryParse(url);
    if (protocolVersion != 1 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !(Platform.isAndroid || Platform.isIOS)) {
      return SizedBox(
        height: heightValue,
        child: fallback ?? _experienceUnavailable(),
      );
    }
    return _PaywallExperienceWebView(
      key: ValueKey('pushify-web-experience-$url'),
      url: uri,
      height: heightValue,
      fallback: fallback,
    );
  }

  Widget _experienceUnavailable() => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Semantics(
        label: 'Interactive experience unavailable',
        child: Icon(Icons.web_asset_off_outlined, color: Colors.white70),
      ),
    ),
  );

  Widget _videoPoster(String? url, String fitMode) {
    if (url != null && url.startsWith('https://')) {
      return Image.network(
        url,
        fit: fitMode == 'fit' ? BoxFit.contain : BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _videoUnavailable(),
        semanticLabel: 'Video preview',
      );
    }
    return _videoUnavailable();
  }

  Widget _videoUnavailable() => const ColoredBox(
    color: Colors.black,
    child: Center(
      child: Icon(Icons.videocam_off_outlined, color: Colors.white70),
    ),
  );

  Widget _render(Map<String, Object?> node, Map<String, Object?> screen) {
    final kind = node['kind'] as String? ?? '';
    final properties = _map(node['properties']);
    final children = _maps(node['children']);
    switch (kind) {
      case 'stack':
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children
              .map(
                (child) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: _render(child, screen),
                ),
              )
              .toList(),
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
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: _number(properties['font_size']) ?? 20,
            fontWeight: _fontWeight(properties['font_weight']),
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
        final source = _map(_map(properties['source'])['light']);
        final url = source['url'] as String?;
        return url == null || !url.startsWith('https://')
            ? const SizedBox.shrink()
            : Image.network(
                url,
                fit: BoxFit.contain,
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
        final size = _number(properties['size']) ?? 24;
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
      final directLight = _map(object['light']);
      final nestedValue = _map(object['value']);
      value = directLight['value'] ?? _map(nestedValue['light'])['value'];
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

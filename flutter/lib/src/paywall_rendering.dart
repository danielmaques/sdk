part of 'paywall.dart';

extension _PaywallRendering on _PushifyPaywallState {
  Widget _motion(Widget child, Map<String, Object?> motion, Object? id) {
    if (motion['enabled'] != true || MediaQuery.of(context).disableAnimations) {
      return child;
    }
    final durationMs = (_number(motion['duration_ms']) ?? 400).toInt().clamp(0, 5000);
    final delayMs = (_number(motion['delay_ms']) ?? 0).toInt().clamp(0, 10000);
    final totalMs = durationMs + delayMs;
    if (totalMs == 0 || durationMs == 0) return child;
    final easing = switch (motion['easing']) {
      'linear' => Curves.linear,
      'ease_in' => Curves.easeIn,
      'ease_in_out' => Curves.easeInOut,
      _ => Curves.easeOut,
    };
    final start = totalMs == 0 ? 0.0 : delayMs / totalMs;
    return TweenAnimationBuilder<double>(
      key: ValueKey('pushify-motion-$id'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: totalMs),
      curve: Interval(start, 1, curve: easing),
      child: child,
      builder: (context, progress, content) {
        final remaining = 1 - progress;
        final scale = _number(motion['scale']) ?? 1;
        final opacity = _number(motion['opacity']) ?? 0;
        final rotation = (_number(motion['rotation']) ?? 0) * 0.017453292519943295;
        return Opacity(
          opacity: (opacity + (1 - opacity) * progress).clamp(0, 1),
          child: Transform.translate(
            offset: Offset((_number(motion['x']) ?? 0) * remaining, (_number(motion['y']) ?? 16) * remaining),
            child: Transform.rotate(
              angle: rotation * remaining,
              child: Transform.scale(scale: scale + (1 - scale) * progress, child: content),
            ),
          ),
        );
      },
    );
  }

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
            layoutDirection: ui.TextDirection.ltr,
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

  List<Map<String, Object?>> _eligibleDiscountWheelPrizes(
    Map<String, Object?> config,
  ) {
    final rawPrizes = _maps(config['prizes']);
    final eligible = <Map<String, Object?>>[];
    for (final prize in rawPrizes) {
      final packageId = prize['package_id'] as String?;
      final offerId = prize['android_offer_id'] as String?;
      if (packageId == null || offerId == null || offerId.isEmpty) continue;
      final matchingPackages = _packages.where((item) => item['id'] == packageId).toList();
      if (matchingPackages.isEmpty) continue;
      final package = matchingPackages.first;
      final product = _map(package['product']);
      final planId = product['plan_id'] as String?;
      final matchingOffers = _maps(product['eligible_store_offers']).where((item) {
        return item['offer_id'] == offerId &&
            item['offer_type'] == 'google_play_subscription' &&
            item['eligible'] == true &&
            (planId == null || planId.isEmpty || item['base_plan_id'] == planId);
      }).toList();
      if (matchingOffers.isNotEmpty) eligible.add({'prize': prize, 'package': package, 'offer': matchingOffers.first});
    }
    return eligible;
  }

  Widget _discountWheel(
    Map<String, Object?> node,
    Map<String, Object?> properties,
    Map<String, Object?> screen,
  ) {
    final config = _map(properties['pushify_discount_wheel']);
    final eligible = _eligibleDiscountWheelPrizes(config);
    if (eligible.isEmpty) {
      final fallback = _map(properties['fallback']);
      return fallback.isEmpty
          ? const Center(child: Text('No Google Play introductory offers are eligible.'))
          : _render(fallback, screen);
    }
    final wheelId = node['id'] as String? ?? 'discount-wheel';
    final labels = eligible.map((item) {
      final prize = _map(item['prize']);
      return _localizedValue(prize['label_lid'] as String? ?? '', screen) ?? 'Offer';
    }).toList();
    final wheelSectors = List<int>.generate(8, (index) => math.min(eligible.length - 1, index * eligible.length ~/ 8).toInt());
    final sectorLabels = wheelSectors.map((eligibleIndex) => labels[eligibleIndex]).toList();
    final winner = _discountWheelPrize;
    final matchingWinner = winner?['node_id'] == wheelId ? winner : null;
    final offer = _map(matchingWinner?['offer']);
    final winnerLabel = matchingWinner?['label'] as String? ?? 'Offer selected';
    final intro = [offer['localized_price'], offer['billing_period']]
        .whereType<String>().where((value) => value.isNotEmpty).join(' for ');
    final renewal = [offer['renewal_price'], offer['renewal_period']]
        .whereType<String>().where((value) => value.isNotEmpty).join(' / ');
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 8000);
    void spin() {
      if (_discountWheelUsed || _discountWheelSpinning) return;
      final prizeIndex = math.Random().nextInt(eligible.length);
      final selected = eligible[prizeIndex];
      final matchingSectors = wheelSectors.indexed.where((entry) => entry.$2 == prizeIndex).map((entry) => entry.$1).toList();
      final wheelIndex = matchingSectors[math.Random().nextInt(matchingSectors.length)];
      final selectedPrize = _map(selected['prize']);
      final selectedPackage = _map(selected['package']);
      final selectedOffer = _map(selected['offer']);
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      _update(() {
        _discountWheelUsed = true;
        _discountWheelSpinning = !reduceMotion;
        _selectedPackage = selectedPackage['id'] as String? ?? '';
        _discountWheelPrize = {
          'node_id': wheelId,
          'wheel_index': wheelIndex,
          'label': labels[prizeIndex],
          'prize': selectedPrize,
          'package': selectedPackage,
          'offer': selectedOffer,
        };
        _discountWheelTurns += reduceMotion ? 0 : (5 + (8 - wheelIndex - 0.5) / 8);
      });
      if (!reduceMotion) {
        Future<void>.delayed(duration).then((_) {
          if (mounted) _update(() => _discountWheelSpinning = false);
        });
      }
    }
    final selectedIndex = (matchingWinner?['wheel_index'] as int?) ?? -1;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Stack(alignment: Alignment.center, children: [
          AnimatedRotation(
            turns: _discountWheelTurns,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: CustomPaint(
              size: const Size(300, 300),
              painter: _DiscountWheelPainter(sectorLabels, selectedIndex: selectedIndex),
            ),
          ),
          const Positioned(top: 0, child: Icon(Icons.arrow_drop_down, size: 30, color: Color(0xffff873c))),
          GestureDetector(
            onTap: spin,
            child: Container(
              width: 58,
              height: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: const Color(0xff20b45a), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
              child: Text(_discountWheelSpinning ? '…' : matchingWinner == null ? 'SPIN' : '✓', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900)),
            ),
          ),
          if (matchingWinner != null && !_discountWheelSpinning)
            _WheelConfetti(reducedMotion: MediaQuery.disableAnimationsOf(context)),
        ]),
        if (matchingWinner != null && !_discountWheelSpinning) ...[
          const SizedBox(height: 6),
          Text('$winnerLabel: ${[intro, renewal].where((value) => value.isNotEmpty).join(', then ')}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          const Text('The price and renewal terms come from Google Play.', textAlign: TextAlign.center, style: TextStyle(fontSize: 11)),
        ],
      ]),
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

  bool _visibilityMatches(Object? raw) {
    if (raw == null) return true;
    final condition = _map(raw);
    final mode = condition['mode'];
    final rules = condition['rules'];
    if ((mode != 'all' && mode != 'any') || rules is! List || rules.isEmpty || rules.length > 8) return true;
    final declarations = _map(widget.document['custom_variables']);
    final results = <bool>[];
    for (final rawRule in rules) {
      final rule = _map(rawRule);
      final reference = rule['variable'];
      if (reference is! String || !reference.startsWith('state.')) return true;
      final name = reference.substring(6);
      final systemState = (name == 'didCompleteTransaction' || name == 'didAbandonTransaction') && !declarations.containsKey(name);
      final declaration = _map(declarations[name]);
      if (declaration.isEmpty && !systemState) return true;
      final type = systemState ? 'boolean' : declaration['value_type'];
      final current = _variables[name] ?? (systemState ? false : declaration['initial_value']);
      final expected = rule['value'];
      if ((type == 'text' && expected is! String) ||
          (type == 'number' && expected is! num) ||
          (type == 'boolean' && expected is! bool) ||
          (type == 'selection' && expected is! String)) {
        return true;
      }
      final operator = rule['operator'];
      if (operator == 'contains' && type == 'selection' && expected is String) {
        results.add(current is List ? current.contains(expected) : current == expected);
      } else if (operator == 'not_contains' && type == 'selection' && expected is String) {
        results.add(current is List ? !current.contains(expected) : current != expected);
      } else if (operator == 'equals') {
        results.add(current is num && expected is num ? current == expected : current == expected);
      } else if (operator == 'not_equals') {
        results.add(current is num && expected is num ? current != expected : current != expected);
      } else if (current is num && expected is num && operator == 'greater_than') {
        results.add(current > expected);
      } else if (current is num && expected is num && operator == 'less_than') {
        results.add(current < expected);
      } else if (current is num && expected is num && operator == 'greater_than_or_equal') {
        results.add(current >= expected);
      } else if (current is num && expected is num && operator == 'less_than_or_equal') {
        results.add(current <= expected);
      } else {
        return true;
      }
    }
    return mode == 'all' ? results.every((value) => value) : results.any((value) => value);
  }

  Widget _render(Map<String, Object?> node, Map<String, Object?> screen) {
    if (!_visibilityMatches(_map(node['properties'])['pushify_visibility'])) {
      return const SizedBox.shrink();
    }
    final accessibility = _map(_map(node['properties'])['pushify_accessibility']);
    final properties = _map(node['properties']);
    final motion = _map(properties['pushify_motion']);
    final role = accessibility['role'] as String? ?? 'automatic';
    Widget child = _renderContent(node, screen);
    child = _motion(child, motion, node['id']);
    if (accessibility['hidden'] == true || role == 'presentation') {
      child = ExcludeSemantics(child: child);
    } else if (accessibility.isNotEmpty) {
      child = Semantics(
        label: accessibility['label'] as String?,
        button: role == 'button',
        link: role == 'link',
        image: role == 'image',
        header: role == 'heading',
        liveRegion: role == 'alert',
        container: role == 'dialog',
        explicitChildNodes: role == 'dialog',
        child: child,
      );
    }
    return child;
  }

  Widget _renderContent(Map<String, Object?> node, Map<String, Object?> screen) {
    final kind = node['kind'] as String? ?? '';
    final properties = _map(node['properties']);
    final children = _maps(node['children']);
    switch (kind) {
      case 'stack':
        final dimension = _map(properties['dimension']);
        final spacing = (_number(properties['spacing']) ?? 0).clamp(0, 80).toDouble();
        return _decorateStack(
          properties,
          Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: _mainAxisAlignment(dimension['distribution']),
            crossAxisAlignment: _crossAxisAlignment(dimension['alignment']),
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0) SizedBox(height: spacing),
                _render(children[index], screen),
              ],
            ],
          ),
        );
      case 'hstack':
        final dimension = _map(properties['dimension']);
        final spacing = (_number(properties['spacing']) ?? 0).clamp(0, 80).toDouble();
        return _decorateStack(
          properties,
          Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: _mainAxisAlignment(dimension['distribution']),
            crossAxisAlignment: _rowCrossAxisAlignment(dimension['alignment']),
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0) SizedBox(width: spacing),
                Flexible(child: _render(children[index], screen)),
              ],
            ],
          ),
        );
      case 'text':
      case 'title':
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Text(
          _localized(node, screen),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: _number(properties['font_size']) ?? 20,
            fontWeight: _fontWeight(properties['font_weight']),
            color: properties.containsKey('color')
                ? _color(
                    properties['color'],
                    Theme.of(context).colorScheme.onSurface,
                    dark: dark,
                  )
                : null,
          ),
        );
      case 'input':
        final reference = properties['state_variable'] as String? ?? '';
        final name = reference.startsWith('state.') ? reference.substring(6) : '';
        final declaration = _map(_map(widget.document['custom_variables'])[name]);
        if (name.isEmpty || declaration['type'] != 'state' || declaration['value_type'] != 'text') return const SizedBox.shrink();
        final current = _variables[name] as String? ?? declaration['initial_value'] as String? ?? '';
        final id = node['id'] as String? ?? reference;
        final controller = _inputControllers.putIfAbsent(id, () => TextEditingController(text: current));
        if (controller.text != current) controller.value = controller.value.copyWith(text: current, selection: TextSelection.collapsed(offset: current.length));
        final labelKey = properties['label_lid'] as String?;
        final placeholderKey = properties['placeholder_lid'] as String?;
        final label = labelKey == null ? null : _localizedValue(labelKey, screen);
        final placeholder = placeholderKey == null ? null : _localizedValue(placeholderKey, screen);
        final keyboard = switch (properties['keyboard']) {
          'email' => TextInputType.emailAddress,
          'number' => const TextInputType.numberWithOptions(decimal: true, signed: true),
          _ => TextInputType.text,
        };
        final maxLength = (_number(properties['max_length']) ?? 100).toInt().clamp(1, 500);
        return TextField(
          controller: controller,
          keyboardType: keyboard,
          maxLength: maxLength,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          decoration: InputDecoration(labelText: label, hintText: placeholder, border: const OutlineInputBorder()),
          onChanged: (value) => _update(() => _variables[name] = value),
        );
      case 'slider':
        final reference = properties['state_variable'] as String? ?? '';
        final name = reference.startsWith('state.') ? reference.substring(6) : '';
        final declaration = _map(_map(widget.document['custom_variables'])[name]);
        if (name.isEmpty || declaration['type'] != 'state' || declaration['value_type'] != 'number') return const SizedBox.shrink();
        final minimum = _number(properties['minimum']) ?? 0;
        final maximum = _number(properties['maximum']) ?? 100;
        final step = _number(properties['step']) ?? 1;
        final initial = _number(_variables[name]) ?? _number(declaration['initial_value']) ?? minimum;
        final value = initial.clamp(minimum, maximum).toDouble();
        final divisions = step > 0 ? ((maximum - minimum) / step).round().clamp(1, 100000) : null;
        final labelKey = properties['label_lid'] as String?;
        final label = labelKey == null ? 'Choose a value' : _localizedValue(labelKey, screen) ?? 'Choose a value';
        final control = Slider(
          value: value,
          min: minimum,
          max: maximum,
          divisions: divisions,
          label: value.toStringAsFixed(step > 0 && step < 1 ? 1 : 0),
          onChanged: (next) => _update(() => _variables[name] = next),
        );
        return Semantics(
          slider: true,
          label: label,
          value: value.toString(),
          child: properties['orientation'] == 'vertical'
              ? SizedBox(height: 180, child: RotatedBox(quarterTurns: 3, child: control))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [Expanded(child: Text(label)), Text(value.toString())]),
                    control,
                  ],
                ),
        );
      case 'multiple_choice':
        final valueReference = properties['state_variable'] as String? ?? '';
        final labelReference = properties['label_state_variable'] as String? ?? '';
        final valueName = valueReference.startsWith('state.') ? valueReference.substring(6) : '';
        final labelName = labelReference.startsWith('state.') ? labelReference.substring(6) : '';
        final valueDeclaration = _map(_map(widget.document['custom_variables'])[valueName]);
        final labelDeclaration = _map(_map(widget.document['custom_variables'])[labelName]);
        final multiple = properties['mode'] == 'multiple';
        final rawSelected = _variables[valueName] ?? valueDeclaration['initial_value'];
        final selected = multiple
            ? rawSelected is List ? rawSelected.whereType<String>().toList() : <String>[]
            : rawSelected is String && rawSelected.isNotEmpty ? <String>[rawSelected] : <String>[];
        final choices = _maps(properties['options']);
        if (properties['randomize_order'] == true) {
          choices.shuffle(math.Random(_randomizationSeed ^ (node['id'] as String? ?? '').hashCode));
        }
        String choiceLabel(Map<String, Object?> choice) {
          final key = choice['label_lid'] as String? ?? '';
          return _interpolate(_localizedValue(key, screen) ?? choice['value'] as String? ?? '');
        }
        void selectChoice(String value) {
          final next = multiple
              ? selected.contains(value) ? selected.where((item) => item != value).toList() : [...selected, value]
              : <String>[value];
          final byValue = {for (final choice in _maps(properties['options'])) (choice['value'] as String? ?? ''): choice};
          final selectedLabels = next.map((item) => byValue[item] == null ? item : choiceLabel(byValue[item]!)).join(', ');
          _update(() {
            if (valueName.isNotEmpty && valueDeclaration['value_type'] == 'selection') _variables[valueName] = multiple ? next : next.isEmpty ? '' : next.first;
            if (labelName.isNotEmpty && labelDeclaration['value_type'] == 'text') _variables[labelName] = selectedLabels;
          });
        }
        final control = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: choices.map((choice) {
            final value = choice['value'] as String? ?? '';
            final label = choiceLabel(choice);
            final checked = selected.contains(value);
            final icon = multiple
                ? checked ? Icons.check_box : Icons.check_box_outline_blank
                : checked ? Icons.radio_button_checked : Icons.radio_button_unchecked;
            return Semantics(
              button: true,
              checked: checked,
              inMutuallyExclusiveGroup: !multiple,
              label: label,
              child: InkWell(
                onTap: () => selectChoice(value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 10), Expanded(child: Text(label))]),
                ),
              ),
            );
          }).toList(),
        );
        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: multiple ? 'Choose one or more options' : 'Choose one option',
          child: control,
        );
      case 'picker':
        final valueReference = properties['state_variable'] as String? ?? '';
        final labelReference = properties['label_state_variable'] as String? ?? '';
        final valueName = valueReference.startsWith('state.') ? valueReference.substring(6) : '';
        final labelName = labelReference.startsWith('state.') ? labelReference.substring(6) : '';
        final choices = _maps(properties['options']);
        final selected = _variables[valueName] as String? ?? '';
        final promptKey = properties['label_lid'] as String? ?? '';
        final prompt = _interpolate(_localizedValue(promptKey, screen) ?? 'Choose an option');
        String choiceLabel(Map<String, Object?> choice) {
          final key = choice['label_lid'] as String? ?? '';
          return _interpolate(_localizedValue(key, screen) ?? choice['value'] as String? ?? '');
        }
        final selectedOption = choices.where((choice) => choice['value'] == selected).firstOrNull;
        final selectedLabel = selectedOption == null ? 'Choose an option' : choiceLabel(selectedOption);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(prompt, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Semantics(
              button: true,
              label: prompt,
              value: selected.isEmpty ? 'No option selected' : selectedLabel,
              child: OutlinedButton(
                onPressed: () async {
                  final next = await showModalBottomSheet<String>(
                    context: context,
                    builder: (sheetContext) => SafeArea(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          Padding(padding: const EdgeInsets.all(16), child: Text(prompt, style: Theme.of(sheetContext).textTheme.titleMedium)),
                          for (final choice in choices)
                            ListTile(
                              title: Text(choiceLabel(choice)),
                              trailing: choice['value'] == selected ? const Icon(Icons.check) : null,
                              onTap: () => Navigator.of(sheetContext).pop(choice['value'] as String? ?? ''),
                            ),
                        ],
                      ),
                    ),
                  );
                  if (next == null) return;
                  final option = choices.where((choice) => choice['value'] == next).firstOrNull;
                  _update(() {
                    if (valueName.isNotEmpty) _variables[valueName] = next;
                    if (labelName.isNotEmpty) _variables[labelName] = option == null ? '' : choiceLabel(option);
                  });
                },
                child: Row(children: [Expanded(child: Text(selectedLabel, textAlign: TextAlign.start)), const Icon(Icons.arrow_drop_down)]),
              ),
            ),
          ],
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
              _runTapActions(node, screen);
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
      case 'lottie':
        final url = properties['url'] as String? ?? '';
        final fit = properties['fit_mode'] == 'fill' ? BoxFit.cover : BoxFit.contain;
        final size = _map(properties['size']);
        final height = _map(size['height']);
        final fixedHeight = height['type'] == 'fixed' ? _number(height['value']) : 180.0;
        final reducedMotion = MediaQuery.of(context).disableAnimations;
        if (!url.startsWith('https://')) {
          return SizedBox(height: fixedHeight, child: Semantics(label: properties['accessibility_label'] as String? ?? 'Animation unavailable', image: true, child: const Center(child: Icon(Icons.animation_outlined))));
        }
        return SizedBox(
          height: fixedHeight,
          child: Semantics(
            label: properties['accessibility_label'] as String? ?? 'Animation',
            image: true,
            child: Lottie.network(
              url,
              fit: fit,
              animate: (properties['auto_play'] as bool? ?? true) && !reducedMotion,
              repeat: properties['loop'] as bool? ?? true,
              frameBuilder: (context, child, composition) => composition == null ? const Center(child: CircularProgressIndicator(strokeWidth: 2)) : child,
              errorBuilder: (context, error, stackTrace) => const Center(child: Icon(Icons.animation_outlined)),
            ),
          ),
        );
      case 'web_view':
        return properties['pushify_discount_wheel'] is Map
            ? _discountWheel(node, properties, screen)
            : _webView(properties, screen);
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
        final dark = Theme.of(context).brightness == Brightness.dark;
        final iconBackground = _map(properties['icon_background']);
        final backgroundColor = _map(iconBackground['color']);
        final foreground = _color(
          properties['color'],
          Theme.of(context).colorScheme.primary,
          dark: dark,
        );
        if (backgroundColor.isNotEmpty) {
          final shape = _map(iconBackground['shape']);
          return Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _color(
                iconBackground['color'],
                Theme.of(context).colorScheme.primary,
                dark: dark,
              ),
              shape: shape['type'] == 'circle'
                  ? BoxShape.circle
                  : BoxShape.rectangle,
              borderRadius: shape['type'] == 'circle'
                  ? null
                  : BorderRadius.circular(8),
            ),
            child: Icon(
              glyph,
              size: size,
              color: foreground,
              semanticLabel: properties['accessibility_label'] as String?,
            ),
          );
        }
        return Icon(
          glyph,
          size: size,
          color: foreground,
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
        _syncCarouselAutoAdvance(id, properties, pages.length);
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
        final duration = _number(properties['duration_seconds']);
        final id = node['id'] as String? ?? 'countdown';
        late final DateTime? date;
        if (duration != null && duration > 0) {
          final start = _countdownStartedAt.putIfAbsent(id, () => _now);
          date = start.add(Duration(seconds: duration.toInt()));
        } else {
          final rawDate = _map(properties['style'])['date'] as String?;
          date = rawDate == null ? null : DateTime.tryParse(rawDate)?.toLocal();
        }
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

  Widget _decorateStack(Map<String, Object?> properties, Widget child) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = _map(properties['background']);
    final shape = _map(properties['shape']);
    final corners = _map(shape['corners']);
    final border = _map(properties['border']);
    final borderWidth = (_number(border['width']) ?? 0).clamp(0, 12).toDouble();
    final borderColor = _map(border['color']);
    final radius = shape['type'] == 'pill'
        ? 999.0
        : (_number(corners['top_leading']) ??
              _number(corners['top_trailing']) ??
              _number(corners['bottom_leading']) ??
              0);
    final base = background.isEmpty
        ? const BoxDecoration()
        : _backgroundDecoration(
            background,
            Theme.of(context).colorScheme.surface,
            dark: dark,
          );
    final decoration = base.copyWith(
      borderRadius: radius > 0 ? BorderRadius.circular(radius) : null,
      border: borderWidth > 0
          ? Border.all(
              width: borderWidth,
              color: _color(
                borderColor,
                Theme.of(context).colorScheme.outline,
                dark: dark,
              ),
            )
          : null,
    );
    return Container(
      padding: _edgeInsets(properties['padding']),
      margin: _edgeInsets(properties['margin']),
      decoration: decoration,
      child: child,
    );
  }

  void _syncCarouselAutoAdvance(
    String id,
    Map<String, Object?> properties,
    int pageCount,
  ) {
    final autoAdvance = _map(properties['auto_advance']);
    final interval = (_number(autoAdvance['ms_time_per_page']) ?? 0)
        .toInt()
        .clamp(1000, 60000);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final enabled = pageCount > 1 &&
        autoAdvance.isNotEmpty &&
        _number(autoAdvance['ms_time_per_page']) != null &&
        !reducedMotion;
    if (!enabled) {
      _carouselAutoAdvanceTimers.remove(id)?.cancel();
      _carouselAutoAdvanceSignatures.remove(id);
      return;
    }

    final loop = properties['loop'] == true;
    final transition = ((_number(autoAdvance['ms_transition_time']) ?? 400)
            .toInt())
        .clamp(0, 5000);
    final signature = '$interval:$pageCount:$loop:$transition';
    if (_carouselAutoAdvanceSignatures[id] == signature) return;
    _carouselAutoAdvanceTimers.remove(id)?.cancel();
    _carouselAutoAdvanceSignatures[id] = signature;
    _carouselAutoAdvanceTimers[id] = Timer.periodic(
      Duration(milliseconds: interval),
      (timer) {
        if (!mounted || MediaQuery.disableAnimationsOf(context)) {
          timer.cancel();
          _carouselAutoAdvanceTimers.remove(id);
          _carouselAutoAdvanceSignatures.remove(id);
          return;
        }
        final current = (_carouselPages[id] ??
                (_number(properties['initial_page_index']) ?? 0).toInt())
            .clamp(0, pageCount - 1);
        if (current == pageCount - 1 && !loop) {
          timer.cancel();
          _carouselAutoAdvanceTimers.remove(id);
          _carouselAutoAdvanceSignatures.remove(id);
          return;
        }
        final next = current == pageCount - 1 ? 0 : current + 1;
        _update(() => _carouselPages[id] = next);
        final controller = _carouselControllers[id];
        if (controller?.hasClients == true) {
          if (transition == 0) {
            controller!.jumpToPage(next);
          } else {
            controller!.animateToPage(
              next,
              duration: Duration(milliseconds: transition),
              curve: Curves.easeOutCubic,
            );
          }
        }
      },
    );
  }

  EdgeInsets _edgeInsets(Object? raw) {
    final box = _map(raw);
    return EdgeInsets.fromLTRB(
      (_number(box['leading']) ?? 0).clamp(0, 120).toDouble(),
      (_number(box['top']) ?? 0).clamp(0, 120).toDouble(),
      (_number(box['trailing']) ?? 0).clamp(0, 120).toDouble(),
      (_number(box['bottom']) ?? 0).clamp(0, 120).toDouble(),
    );
  }

  MainAxisAlignment _mainAxisAlignment(Object? value) => switch (value) {
    'center' => MainAxisAlignment.center,
    'end' => MainAxisAlignment.end,
    'space_between' => MainAxisAlignment.spaceBetween,
    'space_around' => MainAxisAlignment.spaceAround,
    'space_evenly' => MainAxisAlignment.spaceEvenly,
    _ => MainAxisAlignment.start,
  };

  CrossAxisAlignment _crossAxisAlignment(Object? value) => switch (value) {
    'leading' => CrossAxisAlignment.start,
    'trailing' => CrossAxisAlignment.end,
    'center' => CrossAxisAlignment.center,
    _ => CrossAxisAlignment.stretch,
  };

  CrossAxisAlignment _rowCrossAxisAlignment(Object? value) => switch (value) {
    'top' => CrossAxisAlignment.start,
    'bottom' => CrossAxisAlignment.end,
    _ => CrossAxisAlignment.center,
  };

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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final iconBackground = _map(_map(icon['icon_background'])['color']);
    final iconColor = _color(
      icon['color'],
      iconBackground.isNotEmpty
          ? Theme.of(context).colorScheme.onPrimary
          : Theme.of(context).colorScheme.primary,
      dark: dark,
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: iconBackground.isEmpty
                    ? null
                    : _color(
                        _map(icon['icon_background'])['color'],
                        Theme.of(context).colorScheme.primary,
                        dark: dark,
                      ),
                child: Icon(glyph, size: 16, color: iconColor),
              ),
              if (connector)
                Expanded(
                  child: Container(
                    width: 2,
                    color: _color(
                      _map(item['connector'])['color'],
                      Theme.of(context).colorScheme.outlineVariant,
                      dark: dark,
                    ),
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

  Color _color(Object? value, Color fallback, {bool dark = false}) {
    if (value is Map) {
      final object = _map(value);
      final nestedValue = _map(object['value']);
      final direct = _map(object[dark ? 'dark' : 'light']);
      final nested = _map(nestedValue[dark ? 'dark' : 'light']);
      final fallbackVariant = _map(object[dark ? 'light' : 'dark']);
      final fallbackNested = _map(nestedValue[dark ? 'light' : 'dark']);
      value = direct['value'] ?? nested['value'] ?? fallbackVariant['value'] ?? fallbackNested['value'];
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

class _WheelConfetti extends StatefulWidget {
  const _WheelConfetti({required this.reducedMotion});

  final bool reducedMotion;

  @override
  State<_WheelConfetti> createState() => _WheelConfettiState();
}

class _WheelConfettiState extends State<_WheelConfetti>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 6000),
    );
    if (!widget.reducedMotion) _controller.forward();
  }

  @override
  void didUpdateWidget(covariant _WheelConfetti oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reducedMotion && !oldWidget.reducedMotion) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.reducedMotion) return const SizedBox.shrink();
    return IgnorePointer(
      child: SizedBox(
        width: 220,
        height: 220,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: _WheelConfettiPainter(_controller.value),
          ),
        ),
      ),
    );
  }
}

class _WheelConfettiPainter extends CustomPainter {
  _WheelConfettiPainter(this.progress);

  final double progress;
  static const _colors = [
    Color(0xff70d000),
    Color(0xfff5e663),
    Color(0xffff9b35),
    Color(0xffb5eb32),
    Color(0xffffffff),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < 42; i++) {
      final seed = i * 2.399963229728653;
      final spread = 18 + (i % 7) * 3.0;
      final x = size.width * .5 + math.cos(seed) * spread + math.cos(seed) * progress * 105;
      final y = size.height * .46 + math.sin(seed) * spread - (i % 4) * progress * 42 + progress * progress * 380;
      paint.color = _colors[i % _colors.length].withOpacity((1 - progress).clamp(0, 1));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(seed + progress * 8);
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: 5, height: 9), paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _WheelConfettiPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _DiscountWheelPainter extends CustomPainter {
  _DiscountWheelPainter(this.labels, {required this.selectedIndex});

  final List<String> labels;
  final int selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (labels.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2 - 4;
    final bounds = Rect.fromCircle(center: center, radius: radius);
    final sweep = 2 * math.pi / labels.length;
    final paint = Paint()..style = PaintingStyle.fill;
    for (var index = 0; index < labels.length; index++) {
      paint.color = index == selectedIndex
          ? const Color(0xffff873c)
          : const Color(0xfffbf8e3);
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..arcTo(bounds, -math.pi / 2 + index * sweep, sweep, false)
        ..close();
      canvas.drawPath(path, paint);
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white;
      canvas.drawArc(bounds, -math.pi / 2 + index * sweep, sweep, false, paint);
      paint.style = PaintingStyle.fill;
      final text = labels[index].length > 14 ? '${labels[index].substring(0, 13)}…' : labels[index];
      final painter = TextPainter(
        text: TextSpan(text: text, style: const TextStyle(color: Color(0xff17202a), fontSize: 12, fontWeight: FontWeight.w700)),
        textDirection: ui.TextDirection.ltr,
        maxLines: 2,
        textAlign: TextAlign.center,
      )..layout(maxWidth: radius * .56);
      final angle = -math.pi / 2 + (index + .5) * sweep;
      final labelCenter = Offset(center.dx + math.cos(angle) * radius * .64, center.dy + math.sin(angle) * radius * .64);
      painter.paint(canvas, labelCenter - Offset(painter.width / 2, painter.height / 2));
    }
    canvas.drawCircle(center, radius, Paint()..style = PaintingStyle.stroke..strokeWidth = 7..color = const Color(0xff20b45a));
  }

  @override
  bool shouldRepaint(covariant _DiscountWheelPainter oldDelegate) =>
      labels != oldDelegate.labels || selectedIndex != oldDelegate.selectedIndex;
}

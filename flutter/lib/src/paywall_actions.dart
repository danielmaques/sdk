part of 'paywall.dart';

extension _PaywallActions on _PushifyPaywallState {
  Future<void> _buy({
    String? packageId,
    Map<String, Object?> action = const {},
    Map<String, Object?>? screen,
  }) async {
    if (_busy) return;
    final productId = packageId ?? _selectedPackage;
    final available = _maps(
      widget.offering['packages'],
    ).any((item) => item['id'] == productId);
    if (!available) {
      _update(() => _message = 'This purchase option is unavailable.');
      return;
    }
    _update(() {
      _busy = true;
      _message = null;
    });
    try {
      final reminder = _trialReminderRequest(screen);
      final result = await widget.purchases.purchase(
        productId,
        trialReminder: reminder,
      );
      if (result.isPurchased && result.customerInfo != null) {
        final product = _map(_maps(widget.offering['packages']).firstWhere((item) => item['id'] == productId, orElse: () => {})['product']);
        _update(() { _transactionProducts.clear(); if (product.isNotEmpty) _transactionProducts['purchased'] = product; });
        _setTransactionState(completed: true);
        widget.onPurchased?.call(result.customerInfo!);
        await _presentSurvey('post_purchase', screen);
        await _runPurchaseOutcome('after_purchase', 'close', action, screen);
      }
      if (result.isCancelled) {
        final product = _map(_maps(widget.offering['packages']).firstWhere((item) => item['id'] == productId, orElse: () => {})['product']);
        _update(() { _transactionProducts.clear(); if (product.isNotEmpty) _transactionProducts['abandoned'] = product; });
        _setTransactionState(completed: false);
        await _runPurchaseOutcome('on_abandon', 'none', action, screen);
      }
      if (result.isPending) {
        _update(() => _message = 'Purchase is pending approval.');
      }
    } catch (_) {
      _update(
        () => _message = 'Purchase could not be completed. Please try again.',
      );
    } finally {
      if (mounted) _update(() => _busy = false);
    }
  }

  void _setTransactionState({required bool completed}) {
    final declarations = _map(widget.document['custom_variables']);
    _update(() {
      if (!declarations.containsKey('didCompleteTransaction')) _variables['didCompleteTransaction'] = completed;
      if (!declarations.containsKey('didAbandonTransaction')) _variables['didAbandonTransaction'] = !completed;
    });
  }

  Map<String, Object?>? _trialReminderRequest(
    Map<String, Object?>? screen,
  ) {
    final reminder = _map(widget.document['trial_reminder']);
    if (reminder.isEmpty || screen == null) return null;
    final titleKey = reminder['title_lid'];
    final subtitleKey = reminder['subtitle_lid'];
    final bodyKey = reminder['body_lid'];
    if (titleKey is! String || bodyKey is! String) return null;
    final title = _localizedValue(titleKey, screen);
    final body = _localizedValue(bodyKey, screen);
    if (title == null || body == null) return null;
    return {
      ...reminder,
      'title': title,
      if (subtitleKey is String)
        'subtitle': _localizedValue(subtitleKey, screen) ?? '',
      'body': body,
    };
  }

  Future<void> _presentSurvey(
    String trigger,
    Map<String, Object?>? screen,
  ) async {
    if (_surveyedTriggers.contains(trigger)) return;
    final survey = _map(_map(widget.document['surveys'])[trigger]);
    final options = _maps(survey['options']);
    if (screen == null || survey.isEmpty || options.isEmpty || !mounted) return;
    final questionKey = survey['question_lid'];
    if (questionKey is! String) return;
    final question = _localizedValue(questionKey, screen) ?? 'Tell us what you think';
    final answers = <String, String>{};
    for (final option in options) {
      final id = option['id'];
      final key = option['label_lid'];
      if (id is String && key is String) {
        answers[id] = _localizedValue(key, screen) ?? key;
      }
    }
    if (answers.isEmpty) return;
    final skipKey = survey['skip_label_lid'];
    final skipLabel = skipKey is String
        ? (_localizedValue(skipKey, screen) ?? 'Skip')
        : 'Skip';
    _surveyedTriggers.add(trigger);
    final selected = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(question),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final answer in answers.entries)
              ListTile(
                title: Text(answer.value),
                onTap: () => Navigator.of(dialogContext).pop(answer.key),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(skipLabel),
          ),
        ],
      ),
    );
    if (selected != null) {
      unawaited(
        widget.purchases
            .logEvent(
              'paywall_survey_response',
              properties: {
                'paywall_id': widget.document['id'],
                'survey_id': survey['id'],
                'trigger': trigger,
                'option_id': selected,
              },
            )
            .catchError((_) => 0),
      );
    }
  }

  Future<void> _runPurchaseOutcome(
    String key,
    String fallback,
    Map<String, Object?> action,
    Map<String, Object?>? screen,
  ) async {
    for (final step in _maps(_map(action['pushify_actions'])[key])) {
      if (step['type'] == 'update_variable') {
        final name = (step['variable'] as String? ?? '').replaceFirst(
          RegExp(r'^state\.'),
          '',
        );
        final definition = _map(
          _map(widget.document['custom_variables'])[name],
        );
        if (definition.isEmpty) {
          if (mounted) {
            _update(() => _message = 'This state variable is not declared.');
          }
          return;
        }
        final before = _variables[name] ?? definition['initial_value'];
        final operation = step['operation'] as String? ?? 'set';
        final Object? value;
        if (definition['value_type'] == 'number') {
          final amount = step['value'] as num? ?? 0;
          final current = before as num? ?? 0;
          value = operation == 'increment'
              ? current + amount
              : operation == 'decrement'
              ? current - amount
              : amount;
        } else if (definition['value_type'] == 'boolean') {
          value = operation == 'toggle'
              ? !(before as bool? ?? false)
              : step['value'] == true;
        } else {
          value = step['value'] as String? ?? before?.toString() ?? '';
        }
        if (mounted) _update(() => _variables[name] = value);
      } else if (step['type'] == 'navigate_to') {
        if (screen == null) {
          if (mounted) _update(() => _message = 'This link is unavailable.');
          return;
        }
        await _openActionLink(step, screen);
      } else if (step['type'] == 'set_user_attributes') {
        final attributes = Map<String, Object?>.from(_map(step['attributes']));
        final valid =
            attributes.isNotEmpty &&
            attributes.entries.every(
              (entry) =>
                  entry.key.trim().isNotEmpty &&
                  entry.key.length <= 100 &&
                  (entry.value == null ||
                      entry.value is String ||
                      entry.value is num ||
                      entry.value is bool),
            );
        if (!valid) {
          if (mounted) {
            _update(() => _message = 'This user attribute is invalid.');
          }
          return;
        }
        try {
          await widget.purchases.setAttributes(attributes);
        } catch (_) {
          if (mounted) {
            _update(
              () => _message =
                  'User attributes could not be updated. Please try again.',
            );
          }
          return;
        }
      } else if (step['type'] == 'custom_placement') {
        _dispatchCustomPlacement(step);
      }
    }
    final type = _map(action[key])['type'] as String? ?? fallback;
    if (type == 'none') return;
    if (type == 'close') {
      widget.onClose?.call();
      return;
    }
    final index = _screens.indexWhere((item) => item['id'] == screen?['id']);
    if (type == 'navigate_back') {
      if (index > 0) {
        _update(() => _screenId = _screens[index - 1]['id'] as String);
      } else {
        widget.onClose?.call();
      }
    } else if (type == 'workflow') {
      if (index >= 0 && index + 1 < _screens.length) {
        _update(() => _screenId = _screens[index + 1]['id'] as String);
      } else {
        _update(() => _message = 'This flow has no next screen.');
      }
    } else {
      _update(
        () => _message =
            'This purchase outcome is not supported by this SDK version.',
      );
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    _update(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.purchases.restorePurchases();
      _update(() => _message = 'Purchases restored.');
    } catch (_) {
      _update(
        () => _message = 'Purchases could not be restored. Please try again.',
      );
    } finally {
      if (mounted) _update(() => _busy = false);
    }
  }

  Future<void> _runTapActions(
    Map<String, Object?> node,
    Map<String, Object?> screen,
  ) async {
    final action = _map(_map(node['properties'])['action']);
    final steps = _maps(_map(action['pushify_actions'])['on_tap']);
    if (steps.isEmpty) { await _handleButton(node, screen); return; }
    final id = node['id'];
    if (id is! String || id.isEmpty) { _update(() => _message = 'This button action sequence has no component id.'); return; }
    final active = _tapActionRuns[id];
    if (active != null) {
      if (!active.waiting || !active.interruptible) return;
      active.cancelled = true;
      active.timer?.cancel();
      if (!(active.delayCompleter?.isCompleted ?? true)) active.delayCompleter!.complete(false);
      _tapActionRuns.remove(id);
    }
    final run = _TapActionRun();
    _tapActionRuns[id] = run;
    try {
      for (final step in steps) {
        if (run.cancelled) return;
        if (step['type'] == 'delay') {
          final seconds = step['seconds'];
          final interruptible = step['interruptible'];
          if (seconds is! num || !seconds.isFinite || seconds < 0 || seconds > 60 || interruptible is! bool) { _update(() => _message = 'This delay action is invalid.'); return; }
          run.waiting = true;
          run.interruptible = interruptible;
          final completer = Completer<bool>();
          run.delayCompleter = completer;
          run.timer = Timer(Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round()), () {
            run.waiting = false; run.delayCompleter = null; run.timer = null;
            if (!completer.isCompleted) completer.complete(true);
          });
          final completed = await completer.future;
          if (!completed || run.cancelled) return;
        } else if (step['type'] == 'update_variable') {
          final name = (step['variable'] as String? ?? '').replaceFirst(RegExp(r'^state\.'), '');
          final definition = _map(_map(widget.document['custom_variables'])[name]);
          if (definition.isEmpty) { _update(() => _message = 'This state variable is not declared.'); return; }
          final before = _variables[name] ?? definition['initial_value'];
          final operation = step['operation'] as String? ?? 'set';
          final Object? value;
          if (definition['value_type'] == 'number') {
            final amount = step['value'] as num? ?? 0; final current = before as num? ?? 0;
            value = operation == 'increment' ? current + amount : operation == 'decrement' ? current - amount : amount;
          } else if (definition['value_type'] == 'boolean') {
            value = operation == 'toggle' ? !(before as bool? ?? false) : step['value'] == true;
          } else { value = step['value'] as String? ?? before?.toString() ?? ''; }
          _update(() => _variables[name] = value);
        } else if (step['type'] == 'set_user_attributes') {
          final attributes = Map<String, Object?>.from(_map(step['attributes']));
          final valid = attributes.isNotEmpty && attributes.entries.every((entry) => entry.key.trim().isNotEmpty && entry.key.length <= 100 && (entry.value == null || entry.value is String || entry.value is num && (entry.value as num).isFinite || entry.value is bool));
          if (!valid) { _update(() => _message = attributes.isEmpty ? 'No user attributes are configured.' : 'This user attribute is invalid.'); return; }
          try { await widget.purchases.setAttributes(attributes); }
          catch (_) { _update(() => _message = 'User attributes could not be updated. Please try again.'); return; }
        } else if (step['type'] == 'navigate_to') {
          await _openActionLink(step, screen);
        } else if (step['type'] == 'custom_action') {
          final name = (step['name'] as String? ?? '').trim();
          if (name.isEmpty) { _update(() => _message = 'This custom action has no name.'); return; }
          final callback = widget.onCustomAction;
          if (callback == null) { _update(() => _message = 'This app action is unavailable.'); return; }
          callback(name);
        } else if (step['type'] == 'custom_callback') {
          final callback = widget.onCustomCallback;
          final name = (step['name'] as String? ?? '').trim();
          if (name.isEmpty) { _update(() => _message = 'This callback has no name.'); return; }
          if (callback == null) { _update(() => _message = 'This app callback is unavailable.'); return; }
          final arguments = <String, Object?>{};
          _map(step['variables']).forEach((key, reference) {
            final variableName = (reference as String? ?? '').replaceFirst(RegExp(r'^state\.'), '');
            if (_variables.containsKey(variableName)) arguments[key] = _variables[variableName];
          });
          Future<bool> dispatchCallback() async {
            try {
              PushifyCustomCallbackResult result;
              try { result = await Future<PushifyCustomCallbackResult>.sync(() => callback(name, Map.unmodifiable(arguments))); }
              catch (_) { if (mounted && !run.cancelled) _update(() => _message = 'This app callback could not be completed. Please try again.'); result = const PushifyCustomCallbackResult(status: 'failure'); }
              final entries = result.data.entries;
              bool validValue(Object? value) {
                if (value == null || value is bool) return true;
                if (value is String) return value.length <= 500;
                if (value is num) return value.isFinite;
                return false;
              }
              final valid = (result.status == 'success' || result.status == 'failure') && entries.length <= 20 && entries.every((entry) => RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,99}$').hasMatch(entry.key) && validValue(entry.value));
              if (!valid && mounted && !run.cancelled) _update(() => _message = 'This app callback returned an invalid result.');
              if (!mounted || _presentationClosed || run.cancelled) return false;
              final status = valid ? result.status : 'failure';
              _callbackData[name] = valid ? Map<String, Object?>.from(result.data) : {};
              _update(() {});
              final branch = _maps(step[status == 'success' ? 'on_success' : 'on_failure']);
              for (final branchStep in branch) {
                if (!mounted || _presentationClosed || run.cancelled) return false;
                if (branchStep['type'] == 'update_variable') {
                  final variableName = (branchStep['variable'] as String? ?? '').replaceFirst(RegExp(r'^state\.'), '');
                  final definition = _map(_map(widget.document['custom_variables'])[variableName]);
                  if (definition.isEmpty) { _update(() => _message = 'This state variable is not declared.'); return false; }
                  final before = _variables[variableName] ?? definition['initial_value'];
                  final operation = branchStep['operation'] as String? ?? 'set';
                  final Object? next = definition['value_type'] == 'number' ? (operation == 'increment' ? (before as num? ?? 0) + (branchStep['value'] as num? ?? 0) : operation == 'decrement' ? (before as num? ?? 0) - (branchStep['value'] as num? ?? 0) : branchStep['value']) : definition['value_type'] == 'boolean' ? (operation == 'toggle' ? !(before as bool? ?? false) : branchStep['value'] == true) : branchStep['value'] ?? before;
                  _update(() => _variables[variableName] = next);
                } else if (branchStep['type'] == 'set_user_attributes') {
                  try { await widget.purchases.setAttributes(Map<String, Object?>.from(_map(branchStep['attributes']))); }
                  catch (_) { _update(() => _message = 'User attributes could not be updated. Please try again.'); return false; }
                } else if (branchStep['type'] == 'navigate_to') {
                  await _openActionLink(branchStep, screen);
                } else if (branchStep['type'] == 'custom_action') {
                  final actionName = (branchStep['name'] as String? ?? '').trim();
                  if (actionName.isEmpty || widget.onCustomAction == null) { _update(() => _message = 'This app action is unavailable.'); return false; }
                  widget.onCustomAction!(actionName);
                } else if (branchStep['type'] == 'custom_placement') {
                  _dispatchCustomPlacement(branchStep);
                } else if (branchStep['type'] == 'delay') {
                  final seconds = branchStep['seconds'];
                  if (seconds is! num || !seconds.isFinite || seconds < 0 || seconds > 60) { _update(() => _message = 'This callback delay is invalid.'); return false; }
                  await Future<void>.delayed(Duration(microseconds: (seconds * Duration.microsecondsPerSecond).round()));
                }
              }
              return true;
            } catch (_) {
              if (mounted && !run.cancelled) _update(() => _message = 'This callback action could not be completed. Please try again.');
              return false;
            }
          }
          if (step['behavior'] == 'non_blocking') { unawaited(dispatchCallback()); }
          else if (!await dispatchCallback()) {
            return;
          }
        } else if (step['type'] == 'custom_placement') {
          _dispatchCustomPlacement(step);
        }
      }
      if (!run.cancelled && mounted) await _handleButton(node, screen);
    } finally {
      if (identical(_tapActionRuns[id], run)) _tapActionRuns.remove(id);
    }
  }

  Future<void> _handleButton(
    Map<String, Object?> node,
    Map<String, Object?> screen,
  ) async {
    final properties = _map(node['properties']);
    final action = _map(properties['action']);
    final kind = action['type'] ?? properties['action'];
    if (kind == 'update_variable') {
      final name = (action['variable'] as String? ?? '').replaceFirst(
        RegExp(r'^state\.'),
        '',
      );
      final definition = _map(_map(widget.document['custom_variables'])[name]);
      if (definition.isEmpty) {
        _update(() => _message = 'This state variable is not declared.');
        return;
      }
      final before = _variables[name] ?? definition['initial_value'];
      final operation = action['operation'] as String? ?? 'set';
      final Object? value;
      if (definition['value_type'] == 'number') {
        final amount = action['value'] as num? ?? 0;
        final current = before as num? ?? 0;
        value = operation == 'increment'
            ? current + amount
            : operation == 'decrement'
            ? current - amount
            : amount;
      } else if (definition['value_type'] == 'boolean') {
        value = operation == 'toggle'
            ? !(before as bool? ?? false)
            : action['value'] == true;
      } else {
        value = action['value'] as String? ?? before?.toString() ?? '';
      }
      _update(() {
        _variables[name] = value;
      });
      return;
    }
    if (kind == 'restore_purchases' || kind == 'restore') {
      await _restore();
      return;
    }
    if (kind == 'set_user_attributes') {
      final attributes = Map<String, Object?>.from(_map(action['attributes']));
      if (attributes.isEmpty) {
        _update(() => _message = 'No user attributes are configured.');
        return;
      }
      final valid = attributes.entries.every(
        (entry) =>
            entry.key.trim().isNotEmpty &&
            entry.key.length <= 100 &&
            (entry.value == null ||
                entry.value is String ||
                entry.value is num ||
                entry.value is bool),
      );
      if (!valid) {
        _update(() => _message = 'This user attribute is invalid.');
        return;
      }
      if (_busy) return;
      _update(() {
        _busy = true;
        _message = null;
      });
      try {
        await widget.purchases.setAttributes(attributes);
        _update(() => _message = 'User attributes updated.');
      } catch (_) {
        _update(
          () => _message =
              'User attributes could not be updated. Please try again.',
        );
      } finally {
        _update(() => _busy = false);
      }
      return;
    }
    if (kind == 'navigate_to') {
      if (action['destination'] == 'offer_code') {
        if (Platform.isIOS) {
          try {
            await widget.purchases.redeemOfferCode();
            _update(() => _message = null);
          } catch (_) {
            _update(() => _message = 'Offer code redemption could not be completed.');
          }
        } else if (Platform.isAndroid) {
          final proceed = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Redeem a promo code'),
              content: const Text(
                'Google Play opens the selected plan checkout. Choose Redeem in the payment options to enter your code.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('Continue'),
                ),
              ],
            ),
          );
          if (proceed == true && mounted) await _buy(screen: screen);
        } else {
          _update(() => _message = 'Offer code redemption is unavailable on this platform.');
        }
        return;
      }
      await _openActionLink(action, screen);
      return;
    }
    if (kind == 'custom_action') {
      final name = (action['name'] as String? ?? '').trim();
      if (name.isEmpty) {
        _update(() => _message = 'This custom action has no name.');
        return;
      }
      final callback = widget.onCustomAction;
      if (callback == null) {
        _update(() => _message = 'This app action is unavailable.');
        return;
      }
      _update(() => _message = null);
      callback(name);
      return;
    }
    if (kind == 'custom_placement') {
      _dispatchCustomPlacement(action);
      return;
    }
    if (kind == 'navigate_back') {
      final index = _screens.indexWhere((item) => item['id'] == _screenId);
      if (index > 0) {
        _update(() => _screenId = _screens[index - 1]['id'] as String);
      } else {
        await _dismissManually();
      }
      return;
    }
    if (kind == 'workflow') {
      final routes = _maps(action['routes']);
      Map<String, Object?>? matched;
      for (final route in routes) {
        final name = (route['variable'] as String? ?? '').replaceFirst(
          RegExp(r'^state\.'),
          '',
        );
        final current = _variables[name];
        final expected = route['value'];
        final isMatch = switch (route['operator']) {
          'equals' => current == expected,
          'not_equals' => current != expected,
          'contains' => current is List ? current.contains(expected) : current == expected,
          'not_contains' => current is List ? !current.contains(expected) : current != expected,
          'greater_than' =>
            current is num && expected is num && current > expected,
          'less_than' =>
            current is num && expected is num && current < expected,
          _ => false,
        };
        if (isMatch) {
          matched = route;
          break;
        }
      }
      final target = matched?['screen_id'];
      if (target is String && _screens.any((item) => item['id'] == target)) {
        _update(() => _screenId = target);
        return;
      }
      final index = _screens.indexWhere((item) => item['id'] == screen['id']);
      if (index >= 0 && index + 1 < _screens.length) {
        _update(() => _screenId = _screens[index + 1]['id'] as String);
      } else {
        _update(() => _message = 'This flow has no next screen.');
      }
      return;
    }
    final next = properties['next_screen_id'];
    if (next is String && _screens.any((item) => item['id'] == next)) {
      _update(() => _screenId = next);
      return;
    }
    if (kind == 'close' || kind == 'close_workflow') {
      await _dismissManually();
      return;
    }
    if (kind == 'purchase' ||
        kind == 'purchase_with_outcome' ||
        kind == 'purchase_product') {
      final packageId = action['package_id'];
      await _buy(
        packageId: packageId is String && packageId.isNotEmpty
            ? packageId
            : null,
        action: action,
        screen: screen,
      );
      return;
    }
    _update(
      () =>
          _message = 'This button action is not supported by this SDK version.',
    );
  }

  void _dispatchCustomPlacement(Map<String, Object?> action) {
    final name = (action['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      _update(() => _message = 'This custom placement has no name.');
      return;
    }
    final callback = widget.onCustomPlacement;
    if (callback == null) {
      _update(() => _message = 'This app placement is unavailable.');
      return;
    }
    final raw = _map(action['parameters']);
    final valid = raw.length <= 20 && raw.entries.every((entry) {
      final key = entry.key;
      final value = entry.value;
      return RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,99}$').hasMatch(key) &&
          (value == null || value is String && value.length <= 500 || value is num && value.isFinite || value is bool);
    });
    if (!valid) {
      _update(() => _message = 'This custom placement has invalid parameters.');
      return;
    }
    _update(() => _message = null);
    try {
      callback(name, Map<String, Object?>.unmodifiable(raw));
    } catch (_) {
      _update(() => _message = 'The app placement could not be handled.');
    }
  }

  void _performActionHaptics(String? kind) {
    switch (kind) {
      case 'light':
        HapticFeedback.lightImpact();
      case 'medium':
        HapticFeedback.mediumImpact();
      case 'heavy':
        HapticFeedback.heavyImpact();
      case 'success':
        HapticFeedback.heavyImpact();
      case 'warning':
        HapticFeedback.mediumImpact();
      case 'error':
        HapticFeedback.heavyImpact();
      case 'selection':
        HapticFeedback.selectionClick();
    }
  }

  Future<void> _openActionLink(
    Map<String, Object?> action,
    Map<String, Object?> screen,
  ) async {
    final urlRef = _map(action['url']);
    final key = urlRef['url_lid'];
    final raw = key is String ? _localizedValue(key, screen) : urlRef['url'];
    final uri = raw is String ? Uri.tryParse(raw) : null;
    final method = urlRef['method'] is String
        ? urlRef['method'] as String
        : 'in_app_browser';
    final browser = method == 'in_app_browser' || method == 'external_browser';
    final safeScheme =
        uri != null &&
        uri.scheme.isNotEmpty &&
        !{
          'javascript',
          'data',
          'file',
          'content',
          'intent',
        }.contains(uri.scheme.toLowerCase());
    if (uri == null ||
        !safeScheme ||
        (browser &&
            (!uri.hasAuthority ||
                !{'https', 'http'}.contains(uri.scheme.toLowerCase()))) ||
        (method == 'deep_link' &&
            {'https', 'http'}.contains(uri.scheme.toLowerCase()) &&
            !uri.hasAuthority) ||
        !{'in_app_browser', 'external_browser', 'deep_link'}.contains(method)) {
      _update(() => _message = 'This link is unavailable.');
      return;
    }
    try {
      final mode = method == 'in_app_browser'
          ? LaunchMode.inAppBrowserView
          : LaunchMode.externalApplication;
      final opened = await launchUrl(uri, mode: mode);
      if (!opened && mounted) {
        _update(() => _message = 'This link could not be opened.');
      }
    } catch (_) {
      if (mounted) _update(() => _message = 'This link could not be opened.');
    }
  }
}

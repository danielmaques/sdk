import * as React from 'react';
import { useEffect, useMemo, useRef, useState } from 'react';
import { AccessibilityInfo, ActivityIndicator, Animated, Easing, Image, Modal, NativeModules, PanResponder, Pressable, ScrollView, StyleSheet, Text, TextInput, View, FlatList, Vibration, Platform, requireNativeComponent, useColorScheme } from 'react-native';
import type { StyleProp, ViewStyle } from 'react-native';
import { WebView } from 'react-native-webview';
import type { PushifyOfferings, PushifyPaywallNode, PushifyPaywallV1, PushifyPurchases } from './purchases';

export type PushifyPaywallProps = {
  document: PushifyPaywallV1;
  offering: PushifyOfferings['offerings'][number];
  purchases: PushifyPurchases;
  locale?: string;
  onClose?: () => void;
  onPurchased?: (customer: Awaited<ReturnType<PushifyPurchases['customerInfo']>>) => void;
  onCustomAction?: (name: string) => void | Promise<void>;
  onCustomPlacement?: (name: string, parameters: Readonly<Record<string, string | number | boolean | null>>) => void | Promise<void>;
};

type PaywallRendererProps = Omit<PushifyPaywallProps, 'onClose'> & {
  onClose?: (screenId?: string) => void;
  onPurchaseClose?: () => void;
};

type PushifyNativeVideoProps = {
  videoUrl?: string;
  posterUrl?: string;
  autoPlay?: boolean;
  loops?: boolean;
  muted?: boolean;
  showControls?: boolean;
  fitMode?: string;
  accessibilityLabel?: string;
  style?: StyleProp<ViewStyle>;
};

type TapActionRun = { waiting: boolean; interruptible: boolean; cancelled: boolean; timer?: ReturnType<typeof setTimeout>; resolveDelay?: (completed: boolean) => void };

const NativePushifyVideo = requireNativeComponent<PushifyNativeVideoProps>('PushifyVideoView');

function PaywallSlider({ value, minimum, maximum, step, orientation, label, onChange }: { value: number; minimum: number; maximum: number; step: number; orientation: 'horizontal' | 'vertical'; label: string; onChange: (value: number) => void }) {
  const vertical = orientation === 'vertical';
  const [length, setLength] = useState(1);
  const changeAt = (coordinate: number) => {
    const ratio = Math.max(0, Math.min(1, coordinate / Math.max(1, length)));
    const directed = vertical ? 1 - ratio : ratio;
    const raw = minimum + directed * (maximum - minimum);
    const next = step > 0 ? Math.min(maximum, minimum + Math.round((raw - minimum) / step) * step) : raw;
    onChange(Number(next.toPrecision(8)));
  };
  const responder = useMemo(() => PanResponder.create({
    onStartShouldSetPanResponder: () => true,
    onMoveShouldSetPanResponder: () => true,
    onPanResponderGrant: (event) => changeAt(vertical ? length - event.nativeEvent.locationY : event.nativeEvent.locationX),
    onPanResponderMove: (event) => changeAt(vertical ? length - event.nativeEvent.locationY : event.nativeEvent.locationX),
  }), [length, maximum, minimum, step, vertical]);
  const fraction = Math.max(0, Math.min(1, (value - minimum) / (maximum - minimum)));
  const adjust = (delta: number) => onChange(Math.max(minimum, Math.min(maximum, value + delta * (step > 0 ? step : (maximum - minimum) / 100))));
  return React.createElement(View, {
    onLayout: (event: { nativeEvent: { layout: { width: number; height: number } } }) => setLength(vertical ? event.nativeEvent.layout.height : event.nativeEvent.layout.width),
    ...responder.panHandlers,
    accessible: true,
    accessibilityRole: 'adjustable',
    accessibilityLabel: label,
    accessibilityValue: { min: minimum, max: maximum, now: value },
    accessibilityActions: [{ name: 'increment' }, { name: 'decrement' }],
    onAccessibilityAction: (event: { nativeEvent: { actionName: string } }) => adjust(event.nativeEvent.actionName === 'increment' ? 1 : -1),
    style: { width: vertical ? 40 : '100%', height: vertical ? 180 : 38, alignItems: 'center', justifyContent: 'center' },
  }, React.createElement(View, { style: { width: vertical ? 6 : '100%', height: vertical ? '100%' : 6, borderRadius: 999, backgroundColor: '#d4d4d8', overflow: 'visible', justifyContent: 'center' } },
    React.createElement(View, { style: vertical ? { position: 'absolute', bottom: 0, width: 6, height: `${fraction * 100}%`, borderRadius: 999, backgroundColor: '#315ee8' } : { width: `${fraction * 100}%`, height: 6, borderRadius: 999, backgroundColor: '#315ee8' } }),
    React.createElement(View, { style: vertical ? { position: 'absolute', bottom: `${fraction * 100}%`, left: -7, width: 20, height: 20, borderRadius: 10, backgroundColor: '#315ee8', marginBottom: -10 } : { position: 'absolute', left: `${fraction * 100}%`, top: -7, width: 20, height: 20, borderRadius: 10, backgroundColor: '#315ee8', marginLeft: -10 } }),
  ));
}

function PaywallChoice({ options, mode, randomize, id, selected, label, onSelect }: { options: Array<{ id: string; value: string; label: string }>; mode: 'single' | 'multiple'; randomize: boolean; id: string; selected: string[]; label: string; onSelect: (value: string) => void }) {
  const [seed] = useState(() => Math.random());
  const ordered = useMemo(() => {
    if (!randomize) return options;
    const score = (value: string) => { let result = Math.floor(seed * 0x7fffffff); for (const char of `${id}:${value}`) result = Math.imul(result ^ char.charCodeAt(0), 16777619); return result >>> 0; };
    return [...options].sort((a, b) => score(a.value) - score(b.value));
  }, [options, randomize, id, seed]);
  const multiple = mode === 'multiple';
  return React.createElement(View, { accessibilityRole: 'radiogroup', accessibilityLabel: label, style: { width: '100%' } }, ...ordered.map((option) => {
    const checked = selected.includes(option.value);
    return React.createElement(Pressable, {
      key: option.id,
      onPress: () => onSelect(option.value),
      accessibilityRole: multiple ? 'checkbox' : 'radio',
      accessibilityState: { checked, selected: checked },
      accessibilityLabel: option.label,
      style: { flexDirection: 'row', alignItems: 'center', minHeight: 44, paddingVertical: 8, paddingHorizontal: 12, marginVertical: 4, borderWidth: checked ? 2 : 1, borderColor: checked ? '#315ee8' : '#a1a1aa', borderRadius: 10, backgroundColor: checked ? '#eff4ff' : 'transparent' },
    }, React.createElement(Text, { style: { width: 22, marginRight: 10, color: checked ? '#315ee8' : '#52525b' } }, checked ? multiple ? '☑' : '⦿' : multiple ? '□' : '◯'), React.createElement(Text, { style: { flex: 1 } }, option.label));
  }));
}

type MotionValues = { enabled?: boolean; x?: number; y?: number; rotation?: number; scale?: number; opacity?: number; duration_ms?: number; delay_ms?: number; easing?: string };
type AccessibilityValues = { label?: string; role?: string; hidden?: boolean };

function MotionNode({ children, motion, accessibility }: { children: React.ReactNode; motion: MotionValues; accessibility: AccessibilityValues }): React.ReactElement {
  const active = motion.enabled === true;
  const progress = useRef(new Animated.Value(active ? 0 : 1)).current;
  const [reducedMotion, setReducedMotion] = useState(false);
  useEffect(() => {
    let mounted = true;
    void AccessibilityInfo.isReduceMotionEnabled().then((enabled) => { if (mounted) setReducedMotion(enabled); }).catch(() => undefined);
    const subscription = AccessibilityInfo.addEventListener('reduceMotionChanged', setReducedMotion);
    return () => { mounted = false; subscription.remove(); };
  }, []);
  useEffect(() => {
    if (!active) { progress.setValue(1); return; }
    if (reducedMotion) { progress.setValue(1); return; }
    progress.setValue(0);
    const easing = motion.easing === 'linear' ? Easing.linear : motion.easing === 'ease_in' ? Easing.in(Easing.ease) : motion.easing === 'ease_in_out' ? Easing.inOut(Easing.ease) : Easing.out(Easing.ease);
    const animation = Animated.sequence([
      Animated.delay(Math.max(0, Math.min(10000, motion.delay_ms ?? 0))),
      Animated.timing(progress, { toValue: 1, duration: Math.max(0, Math.min(5000, motion.duration_ms ?? 400)), easing, useNativeDriver: true }),
    ]);
    animation.start();
    return () => animation.stop();
  }, [active, reducedMotion, progress, motion.x, motion.y, motion.rotation, motion.scale, motion.opacity, motion.duration_ms, motion.delay_ms, motion.easing]);
  const hidden = accessibility.hidden === true || accessibility.role === 'presentation';
  const role = accessibility.role === 'heading' ? 'header' : accessibility.role === 'presentation' ? 'none' : accessibility.role === 'dialog' ? 'summary' : accessibility.role;
  const style = active && !reducedMotion ? {
    opacity: progress.interpolate({ inputRange: [0, 1], outputRange: [motion.opacity ?? 0, 1] }),
    transform: [
      { translateX: progress.interpolate({ inputRange: [0, 1], outputRange: [motion.x ?? 0, 0] }) },
      { translateY: progress.interpolate({ inputRange: [0, 1], outputRange: [motion.y ?? 16, 0] }) },
      { rotate: progress.interpolate({ inputRange: [0, 1], outputRange: [`${motion.rotation ?? 0}deg`, '0deg'] }) },
      { scale: progress.interpolate({ inputRange: [0, 1], outputRange: [motion.scale ?? 1, 1] }) },
    ],
  } : undefined;
  return React.createElement(Animated.View, {
    style,
    accessible: hidden ? false : !!(accessibility.label || role),
    accessibilityLabel: hidden ? undefined : accessibility.label,
    accessibilityRole: hidden ? undefined : role as never,
    accessibilityElementsHidden: hidden,
    importantForAccessibility: hidden ? 'no-hide-descendants' : 'auto',
  }, children);
}

/** Accessible renderer for the core Pushify paywall document components. */
export function PushifyPaywallView(props: PushifyPaywallProps): React.ReactElement {
  const [exitOffering, setExitOffering] = useState<PushifyOfferings['offerings'][number] | null>(null);
  const [availableExitOffering, setAvailableExitOffering] = useState<PushifyOfferings['offerings'][number] | null>(null);
  const closing = useRef(false);
  useEffect(() => {
    setExitOffering(null); setAvailableExitOffering(null); closing.current = false;
    const exit = record(record(props.document.exit_offer).dismiss);
    const exitOfferingID = text(exit.offering_id);
    if (!exitOfferingID || exitOfferingID === props.offering.id) return;
    let current = true;
    void props.purchases.offerings().then((catalog) => {
      if (current) setAvailableExitOffering(catalog.offerings.find((candidate) => candidate.id === exitOfferingID && candidate.paywall) ?? null);
    }).catch(() => { if (current) setAvailableExitOffering(null); });
    return () => { current = false; };
  }, [props.document.id, props.document.revision, props.offering.id, props.purchases]);

  async function closeManually(screenId?: string): Promise<void> {
    if (closing.current) return;
    closing.current = true;
    if (exitOffering) { props.onClose?.(); return; }
    const screens = props.document.screens;
    const screenIndex = screens.findIndex((candidate) => candidate.id === screenId);
    const exit = record(record(props.document.exit_offer).dismiss);
    const exitOfferingID = text(exit.offering_id);
    if (screenIndex >= 0 && screenIndex === screens.length - 1 && exitOfferingID && exitOfferingID !== props.offering.id) {
      try {
        const catalog = availableExitOffering ? null : await props.purchases.offerings();
        const target = availableExitOffering ?? catalog?.offerings.find((candidate) => candidate.id === exitOfferingID && candidate.paywall);
        if (target?.paywall) {
          void props.purchases.logEvent('PAYWALL_EXIT_OFFER', { type: 'dismiss', offering_id: target.id, paywall_id: props.document.id }).catch(() => undefined);
          closing.current = false;
          setExitOffering(target);
          return;
        }
      } catch { /* An unavailable exit offer must not trap the customer on the original paywall. */ }
    }
    closing.current = false;
    props.onClose?.();
  }

  const document = exitOffering?.paywall ?? props.document;
  const offering = exitOffering ?? props.offering;
  return React.createElement(PaywallRenderer, {
    key: `${document.id}-${document.revision}-${offering.id}`,
    ...props,
    document,
    offering,
    onClose: (screenId?: string) => { void closeManually(screenId); },
    onPurchaseClose: props.onClose,
  });
}

function PaywallRenderer(props: PaywallRendererProps): React.ReactElement {
  const firstScreen = props.document.screens.find((candidate) => candidate.id === props.document.initial_screen_id) ?? props.document.screens[0];
  const packages = props.offering.packages;
  const colorScheme = useColorScheme();
  const defaultPackage = useMemo(() => findPackage(firstScreen?.content, true), [firstScreen]);
  const [selected, setSelected] = useState(defaultPackage ?? packages[0]?.id ?? '');
  const [screenID, setScreenID] = useState(firstScreen?.id ?? '');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const [carouselPages, setCarouselPages] = useState<Record<string, number>>({});
  const [selectedTabs, setSelectedTabs] = useState<Record<string, string>>({});
  const [variables, setVariables] = useState<Record<string, string | number | boolean | string[]>>(() => {
    const custom = props.document.custom_variables ?? {};
    return {
      ...Object.fromEntries(Object.entries(custom).map(([key, value]) => [key, value.initial_value])),
      ...(!Object.prototype.hasOwnProperty.call(custom, 'didCompleteTransaction') ? { didCompleteTransaction: false } : {}),
      ...(!Object.prototype.hasOwnProperty.call(custom, 'didAbandonTransaction') ? { didAbandonTransaction: false } : {}),
    };
  });
  const [activeSurvey, setActiveSurvey] = useState<{ trigger: 'close' | 'post_purchase'; survey: NonNullable<PushifyPaywallV1['surveys']>['close'] } | null>(null);
  const surveyedTriggers = useRef(new Set<string>());
  const surveyResolver = useRef<(() => void) | null>(null);
  const tapActionRuns = useRef(new Map<string, TapActionRun>());
  const screen = props.document.screens.find((candidate) => candidate.id === screenID) ?? firstScreen;
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  useEffect(() => () => {
    for (const run of tapActionRuns.current.values()) { if (run.timer) clearTimeout(run.timer); run.cancelled = true; run.resolveDelay?.(false); }
    tapActionRuns.current.clear();
  }, []);

  function finishSurvey(optionID?: string): void {
    if (optionID && activeSurvey) {
      void props.purchases.logEvent('paywall_survey_response', {
        paywall_id: props.document.id,
        survey_id: activeSurvey.survey?.id,
        trigger: activeSurvey.trigger,
        option_id: optionID,
      }).catch(() => undefined);
    }
    setActiveSurvey(null);
    surveyResolver.current?.();
    surveyResolver.current = null;
  }

  async function presentSurvey(trigger: 'close' | 'post_purchase', sourceScreen = screen): Promise<void> {
    if (!sourceScreen || surveyedTriggers.current.has(trigger)) return;
    const survey = props.document.surveys?.[trigger];
    if (!survey?.options.length) return;
    surveyedTriggers.current.add(trigger);
    await new Promise<void>((resolve) => {
      surveyResolver.current = resolve;
      setActiveSurvey({ trigger, survey });
    });
  }

  async function closeWithSurvey(sourceScreen = screen): Promise<void> {
    await presentSurvey('close', sourceScreen);
    props.onClose?.(sourceScreen?.id);
  }

  async function purchase(packageID?: string, action: Record<string, unknown> = {}, sourceScreen = screen) {
    const productID = packageID ?? selected;
    if (busy) return;
    if (!packages.some((item) => item.id === productID)) { setMessage('This purchase option is unavailable.'); return; }
    setBusy(true); setMessage(null);
    try {
      const reminder = props.document.trial_reminder;
      const reminderTitle = reminder ? localizedValue(reminder.title_lid) : null;
      const reminderBody = reminder ? localizedValue(reminder.body_lid) : null;
      const trialReminder = reminder && sourceScreen && reminderTitle && reminderBody ? {
        ...reminder,
        title: reminderTitle,
        ...(reminder.subtitle_lid ? { subtitle: localizedValue(reminder.subtitle_lid) ?? '' } : {}),
        body: reminderBody,
      } : null;
      const result = await props.purchases.purchase(productID, trialReminder);
      if (result.status === 'purchased') {
        setVariables((current) => ({ ...current,
          ...(!Object.prototype.hasOwnProperty.call(props.document.custom_variables ?? {}, 'didCompleteTransaction') ? { didCompleteTransaction: true } : {}),
          ...(!Object.prototype.hasOwnProperty.call(props.document.custom_variables ?? {}, 'didAbandonTransaction') ? { didAbandonTransaction: false } : {}),
        }));
        props.onPurchased?.(result.customerInfo);
      }
      if (result.status === 'purchased') await presentSurvey('post_purchase', sourceScreen);
      if (result.status === 'purchased') await runPurchaseOutcome('after_purchase', 'close', action, sourceScreen);
      if (result.status === 'cancelled') {
        setVariables((current) => ({ ...current,
          ...(!Object.prototype.hasOwnProperty.call(props.document.custom_variables ?? {}, 'didCompleteTransaction') ? { didCompleteTransaction: false } : {}),
          ...(!Object.prototype.hasOwnProperty.call(props.document.custom_variables ?? {}, 'didAbandonTransaction') ? { didAbandonTransaction: true } : {}),
        }));
        await runPurchaseOutcome('on_abandon', 'none', action, sourceScreen);
      }
      if (result.status === 'pending') setMessage('Purchase is pending approval.');
    } catch {
      setMessage('Purchase could not be completed. Please try again.');
    } finally { setBusy(false); }
  }

  async function runPurchaseOutcome(key: string, fallback: string, action: Record<string, unknown>, sourceScreen?: PushifyPaywallV1['screens'][number]): Promise<void> {
    for (const step of array(record(action.pushify_actions)[key]).map(record)) {
      if (step.type === 'update_variable') {
        const name = text(step.variable)?.replace(/^state\./, '');
        const declaration = name ? props.document.custom_variables?.[name] : undefined;
        if (!name || !declaration) { setMessage('This state variable is not declared.'); return; }
        setVariables((current) => {
          const before = current[name] ?? declaration.initial_value;
          const operation = text(step.operation) ?? 'set';
          let next: string | number | boolean | string[];
          if (declaration.value_type === 'number') { const amount = number(step.value) ?? 0; next = operation === 'increment' ? Number(before) + amount : operation === 'decrement' ? Number(before) - amount : amount; }
          else if (declaration.value_type === 'boolean') next = operation === 'toggle' ? !Boolean(before) : step.value === true;
          else if (declaration.value_type === 'selection') next = before as string | string[];
          else next = text(step.value) ?? String(before);
          return { ...current, [name]: next };
        });
      } else if (step.type === 'navigate_to') {
        await openActionLink(step);
      } else if (step.type === 'set_user_attributes') {
        const configured = record(step.attributes);
        const attributes: Record<string, string | number | boolean | null> = {};
        for (const [name, value] of Object.entries(configured)) {
          if (!name.trim() || name.length > 100 || (value !== null && typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean')) { setMessage('This user attribute is invalid.'); return; }
          attributes[name] = value as string | number | boolean | null;
        }
        if (!Object.keys(attributes).length) { setMessage('No user attributes are configured.'); return; }
        try { await props.purchases.setAttributes(attributes); }
        catch { setMessage('User attributes could not be updated. Please try again.'); return; }
      } else if (step.type === 'custom_placement') {
        dispatchCustomPlacement(step);
      }
    }
    const outcome = record(action[key]);
    const kind = text(outcome.type) ?? fallback;
    if (kind === 'none') return;
    if (kind === 'close') { props.onPurchaseClose?.(); return; }
    const index = props.document.screens.findIndex((candidate) => candidate.id === sourceScreen?.id);
    if (kind === 'navigate_back') {
      if (index > 0) setScreenID(props.document.screens[index - 1]!.id);
      else props.onPurchaseClose?.();
    } else if (kind === 'workflow') {
      const nextScreen = index >= 0 ? props.document.screens[index + 1] : undefined;
      if (nextScreen) setScreenID(nextScreen.id);
      else setMessage('This flow has no next screen.');
    } else {
      setMessage('This purchase outcome is not supported by this SDK version.');
    }
  }

  async function restore() {
    if (busy) return;
    setBusy(true); setMessage(null);
    try { await props.purchases.restorePurchases(); setMessage('Purchases restored.'); }
    catch { setMessage('Purchases could not be restored. Please try again.'); }
    finally { setBusy(false); }
  }

  function localized(node: PushifyPaywallNode, fallback = ''): string {
    const key = node.properties.text_lid;
    const locales = [props.locale, Intl.DateTimeFormat().resolvedOptions().locale, props.document.default_locale, 'en_US'].filter((item): item is string => Boolean(item));
    if (typeof key === 'string') {
      for (const locale of locales) {
        const value = node.properties.text_lid && (screen?.localizations[locale]?.[key] ?? props.document.locales[locale]?.[key]);
        if (typeof value === 'string') return interpolate(value);
      }
    }
    return interpolate(fallback || (typeof node.properties.text === 'string' ? node.properties.text : ''));
  }

  function interpolate(value: string): string { return value.replace(/\{\{\s*state\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/g, (token, key: string) => variables[key] === undefined ? token : Array.isArray(variables[key]) ? variables[key].join(', ') : String(variables[key])); }

  function localizedValue(key: string): string | null {
    const locales = [props.locale, Intl.DateTimeFormat().resolvedOptions().locale, props.document.default_locale, 'en_US'].filter((item): item is string => Boolean(item));
    for (const locale of locales) {
      for (const candidate of new Set([locale, locale.replace(/-/g, '_'), locale.replace(/_/g, '-')])) {
        const value = screen?.localizations[candidate]?.[key] ?? props.document.locales[candidate]?.[key];
        if (typeof value === 'string') return value;
      }
    }
    return null;
  }

  async function openActionLink(action: Record<string, unknown>): Promise<void> {
    const urlRef = record(action.url);
    const urlKey = text(urlRef.url_lid);
    const rawURL = urlKey ? localizedValue(urlKey) : text(urlRef.url);
    let parsed: URL;
    try { parsed = new URL(rawURL ?? ''); } catch { setMessage('This link is unavailable.'); return; }
    const method = text(urlRef.method) ?? 'in_app_browser';
    const browser = method === 'in_app_browser' || method === 'external_browser';
    if (!['in_app_browser', 'external_browser', 'deep_link'].includes(method) ||
      (browser && !['https:', 'http:'].includes(parsed.protocol)) ||
      (method === 'deep_link' && (['javascript:', 'data:', 'file:', 'content:', 'intent:'].includes(parsed.protocol) ||
        (['http:', 'https:'].includes(parsed.protocol) && !parsed.host)))) {
      setMessage('This link is unavailable.'); return;
    }
    try {
      const native = NativeModules.PushifyPurchases as { openPaywallLink?: (url: string, method: string) => Promise<boolean> } | undefined;
      if (!native?.openPaywallLink) throw new Error('The native link handler is unavailable. Update the Pushify SDK.');
      await native.openPaywallLink(parsed.toString(), method);
    }
    catch { setMessage('This link could not be opened.'); }
  }

  async function handleButton(node: PushifyPaywallNode): Promise<void> {
    const action = record(node.properties.action);
    const kind = text(action.type) ?? text(node.properties.action);
    if (kind === 'update_variable') {
      const name = text(action.variable)?.replace(/^state\./, '');
      const declaration = name ? props.document.custom_variables?.[name] : undefined;
      if (!name || !declaration) { setMessage('This state variable is not declared.'); return; }
      setVariables((current) => { const before = current[name] ?? declaration.initial_value; const operation = text(action.operation) ?? 'set'; let next: string | number | boolean | string[];
        if (declaration.value_type === 'number') { const value = number(action.value) ?? 0; next = operation === 'increment' ? Number(before) + value : operation === 'decrement' ? Number(before) - value : value; }
        else if (declaration.value_type === 'boolean') next = operation === 'toggle' ? !Boolean(before) : action.value === true;
        else if (declaration.value_type === 'selection') next = before as string | string[];
        else next = text(action.value) ?? String(before);
        return { ...current, [name]: next };
      });
      return;
    }
    if (kind === 'restore_purchases' || kind === 'restore') { await restore(); return; }
    if (kind === 'set_user_attributes') {
      const configured = record(action.attributes);
      const attributes: Record<string, string | number | boolean | null> = {};
      for (const [key, value] of Object.entries(configured)) {
        if (!key.trim() || key.length > 100 || (value !== null && typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean')) {
          setMessage('This user attribute is invalid.'); return;
        }
        attributes[key] = value;
      }
      if (!Object.keys(attributes).length) { setMessage('No user attributes are configured.'); return; }
      if (busy) return;
      setBusy(true); setMessage(null);
      try { await props.purchases.setAttributes(attributes); setMessage('User attributes updated.'); }
      catch { setMessage('User attributes could not be updated. Please try again.'); }
      finally { setBusy(false); }
      return;
    }
    if (kind === 'navigate_to') { await openActionLink(action); return; }
    if (kind === 'custom_placement') { dispatchCustomPlacement(action); return; }
    if (kind === 'custom_action') {
      const name = text(action.name)?.trim();
      if (!name) { setMessage('This custom action has no name.'); return; }
      if (!props.onCustomAction) { setMessage('This app action is unavailable.'); return; }
      setMessage(null);
      try { await props.onCustomAction(name); }
      catch { setMessage('This app action could not be completed. Please try again.'); }
      return;
    }
    if (kind === 'navigate_back') {
      const index = props.document.screens.findIndex((candidate) => candidate.id === screen?.id);
      if (index > 0) setScreenID(props.document.screens[index - 1]!.id);
      else await closeWithSurvey(screen);
      return;
    }
    if (kind === 'workflow') {
      const routes = Array.isArray(action.routes) ? action.routes as Record<string, unknown>[] : [];
      const destination = routes.find((route) => {
        const name = text(route.variable)?.replace(/^state\./, '');
        const current = name ? variables[name] : undefined;
        const value = route.value;
        switch (route.operator) {
          case 'equals': return current === value;
          case 'not_equals': return current !== value;
          case 'contains': return Array.isArray(current) ? current.includes(value as string) : current === value;
          case 'not_contains': return Array.isArray(current) ? !current.includes(value as string) : current !== value;
          case 'greater_than': return typeof current === 'number' && typeof value === 'number' && current > value;
          case 'less_than': return typeof current === 'number' && typeof value === 'number' && current < value;
          default: return false;
        }
      });
      const target = text(destination?.screen_id);
      if (target && props.document.screens.some((candidate) => candidate.id === target)) { setScreenID(target); return; }
      const index = props.document.screens.findIndex((candidate) => candidate.id === screen?.id);
      const nextScreen = index >= 0 ? props.document.screens[index + 1] : undefined;
      if (nextScreen) setScreenID(nextScreen.id);
      else setMessage('This flow has no next screen.');
      return;
    }
    const next = text(node.properties.next_screen_id);
    if (next && props.document.screens.some((candidate) => candidate.id === next)) { setScreenID(next); return; }
    if (kind === 'purchase' || kind === 'purchase_with_outcome' || kind === 'purchase_product' || node.kind === 'purchase_button') { await purchase(text(action.package_id) ?? undefined, action, screen); return; }
    if (kind === 'close' || kind === 'close_workflow') { await closeWithSurvey(screen); return; }
    setMessage('This button action is not supported by this SDK version.');
  }

  async function runTapActions(node: PushifyPaywallNode): Promise<void> {
    const action = record(node.properties.action);
    const steps = array(record(action.pushify_actions).on_tap).map(record);
    if (!steps.length) { await handleButton(node); return; }
    const id = node.id;
    if (!id) { setMessage('This button action sequence has no component id.'); return; }
    const active = tapActionRuns.current.get(id);
    if (active) {
      if (!active.waiting || !active.interruptible) return;
      active.cancelled = true;
      if (active.timer) clearTimeout(active.timer);
      active.resolveDelay?.(false);
      tapActionRuns.current.delete(id);
    }
    const run: TapActionRun = { waiting: false, interruptible: false, cancelled: false };
    tapActionRuns.current.set(id, run);
    try {
      for (const step of steps) {
        if (run.cancelled) return;
        if (step.type === 'delay') {
          const seconds = number(step.seconds);
          if (seconds === null || seconds < 0 || seconds > 60 || typeof step.interruptible !== 'boolean') { setMessage('This delay action is invalid.'); return; }
          run.waiting = true;
          run.interruptible = step.interruptible;
          const completed = await new Promise<boolean>((resolve) => {
            run.resolveDelay = resolve;
            run.timer = setTimeout(() => { run.waiting = false; run.resolveDelay = undefined; run.timer = undefined; resolve(true); }, seconds * 1000);
          });
          if (!completed || run.cancelled) return;
        } else if (step.type === 'update_variable') {
          const name = text(step.variable)?.replace(/^state\./, '');
          const declaration = name ? props.document.custom_variables?.[name] : undefined;
          if (!name || !declaration) { setMessage('This state variable is not declared.'); return; }
          setVariables((current) => {
            const before = current[name] ?? declaration.initial_value;
            const operation = text(step.operation) ?? 'set';
            let next: string | number | boolean | string[];
            if (declaration.value_type === 'number') { const value = number(step.value) ?? 0; next = operation === 'increment' ? Number(before) + value : operation === 'decrement' ? Number(before) - value : value; }
            else if (declaration.value_type === 'boolean') next = operation === 'toggle' ? !Boolean(before) : step.value === true;
            else next = text(step.value) ?? String(before);
            return { ...current, [name]: next };
          });
        } else if (step.type === 'set_user_attributes') {
          const configured = record(step.attributes);
          const attributes: Record<string, string | number | boolean | null> = {};
          for (const [key, value] of Object.entries(configured)) {
            if (!key.trim() || key.length > 100 || (value !== null && typeof value !== 'string' && typeof value !== 'number' && typeof value !== 'boolean')) { setMessage('This user attribute is invalid.'); return; }
            attributes[key] = value as string | number | boolean | null;
          }
          if (!Object.keys(attributes).length) { setMessage('No user attributes are configured.'); return; }
          try { await props.purchases.setAttributes(attributes); }
          catch { setMessage('User attributes could not be updated. Please try again.'); return; }
        } else if (step.type === 'navigate_to') {
          await openActionLink(step);
        } else if (step.type === 'custom_action') {
          const name = text(step.name)?.trim();
          if (!name) { setMessage('This custom action has no name.'); return; }
          if (!props.onCustomAction) { setMessage('This app action is unavailable.'); return; }
          try { await props.onCustomAction(name); }
          catch { setMessage('This app action could not be completed. Please try again.'); return; }
        } else if (step.type === 'custom_placement') {
          dispatchCustomPlacement(step);
        }
      }
      if (!run.cancelled) await handleButton(node);
    } finally {
      if (tapActionRuns.current.get(id) === run) tapActionRuns.current.delete(id);
    }
  }

  function dispatchCustomPlacement(action: Record<string, unknown>): void {
    const name = text(action.name)?.trim();
    if (!name) { setMessage('This custom placement has no name.'); return; }
    const callback = props.onCustomPlacement;
    if (!callback) { setMessage('This app placement is unavailable.'); return; }
    const entries = Object.entries(record(action.parameters));
    const valid = entries.length <= 20 && entries.every(([key, value]) => /^[A-Za-z_][A-Za-z0-9_.-]{0,99}$/.test(key) && (value === null || typeof value === 'boolean' || typeof value === 'number' && Number.isFinite(value) || typeof value === 'string' && value.length <= 500));
    if (!valid) { setMessage('This custom placement has invalid parameters.'); return; }
    setMessage(null);
    try {
      const result = callback(name, Object.freeze(Object.fromEntries(entries)) as Readonly<Record<string, string | number | boolean | null>>);
      if (result && typeof (result as Promise<void>).then === 'function') void Promise.resolve(result).catch(() => setMessage('The app placement could not be handled.'));
    } catch {
      setMessage('The app placement could not be handled.');
    }
  }

  function actionFeedback(node: PushifyPaywallNode): void {
    const action = record(node.properties.action);
    const vibration: Record<string, number> = { light: 10, medium: 20, heavy: 35, success: 18, warning: 28, error: 38, selection: 6 };
    const duration = vibration[text(action.haptics) ?? ''];
    if (duration) Vibration.vibrate(duration);
  }

  function visibilityMatches(raw: unknown): boolean {
    if (raw == null) return true;
    const condition = record(raw);
    const rules = array(condition.rules).map(record);
    if ((condition.mode !== 'all' && condition.mode !== 'any') || rules.length < 1 || rules.length > 8) return true;
    const results: boolean[] = [];
    for (const rule of rules) {
      const reference = text(rule.variable);
      if (!reference?.startsWith('state.')) return true;
      const key = reference.slice(6);
      const declaration = props.document.custom_variables?.[key];
      const systemState = (key === 'didCompleteTransaction' || key === 'didAbandonTransaction') && !declaration;
      if ((!declaration || declaration.type !== 'state') && !systemState) return true;
      const current = variables[key] ?? (systemState ? false : declaration!.initial_value);
      const expected = rule.value;
      const valueType = systemState ? 'boolean' : declaration!.value_type;
      if ((valueType === 'text' && typeof expected !== 'string') || (valueType === 'number' && typeof expected !== 'number') || (valueType === 'boolean' && typeof expected !== 'boolean') || (valueType === 'selection' && typeof expected !== 'string')) return true;
      switch (rule.operator) {
        case 'equals': results.push(current === expected); break;
        case 'not_equals': results.push(current !== expected); break;
        case 'contains': if (valueType !== 'selection' || typeof expected !== 'string') return true; else results.push(Array.isArray(current) ? current.includes(expected) : current === expected); break;
        case 'not_contains': if (valueType !== 'selection' || typeof expected !== 'string') return true; else results.push(Array.isArray(current) ? !current.includes(expected) : current !== expected); break;
        case 'greater_than': if (typeof current !== 'number' || typeof expected !== 'number') return true; else results.push(current > expected); break;
        case 'less_than': if (typeof current !== 'number' || typeof expected !== 'number') return true; else results.push(current < expected); break;
        case 'greater_than_or_equal': if (typeof current !== 'number' || typeof expected !== 'number') return true; else results.push(current >= expected); break;
        case 'less_than_or_equal': if (typeof current !== 'number' || typeof expected !== 'number') return true; else results.push(current <= expected); break;
        default: return true;
      }
    }
    return condition.mode === 'all' ? results.every(Boolean) : results.some(Boolean);
  }

  function renderNode(node: PushifyPaywallNode): React.ReactNode {
    if (!visibilityMatches(node.properties.pushify_visibility)) return null;
    const content = renderNodeContent(node);
    const accessibility = record(node.properties.pushify_accessibility);
    const motion = record(node.properties.pushify_motion) as MotionValues;
    if (!React.isValidElement(content)) return content;
    if (!Object.keys(accessibility).length && motion.enabled !== true) return content;
    return React.createElement(MotionNode, { key: `motion-${node.id ?? node.kind}`, motion, accessibility: accessibility as AccessibilityValues, children: content });
  }

  function renderNodeContent(node: PushifyPaywallNode): React.ReactNode {
    const children = node.children.map((child) => renderNode(child));
    switch (node.kind) {
      case 'stack': return React.createElement(View, { key: node.id ?? undefined, style: styles.stack }, ...children);
      case 'hstack': return React.createElement(View, { key: node.id ?? undefined, style: styles.row }, ...children.map((child) => React.createElement(View, { style: styles.rowChild }, child)));
      case 'text':
      case 'title': return React.createElement(Text, { key: node.id ?? undefined, style: [styles.text, { fontSize: number(node.properties.font_size) ?? 20, fontWeight: weight(node.properties.font_weight) }] }, localized(node));
      case 'input': {
        const reference = text(node.properties.state_variable) ?? '';
        const name = reference.startsWith('state.') ? reference.slice(6) : '';
        const declaration = name ? props.document.custom_variables?.[name] : undefined;
        if (!declaration || declaration.type !== 'state' || declaration.value_type !== 'text') return null;
        const labelId = text(node.properties.label_lid);
        const placeholderId = text(node.properties.placeholder_lid);
        const label = labelId ? interpolate(localizedValue(labelId) ?? 'Your response') : 'Your response';
        const placeholder = placeholderId ? interpolate(localizedValue(placeholderId) ?? '') : '';
        return React.createElement(View, { key: node.id ?? undefined, style: styles.inputWrap },
          React.createElement(Text, { style: styles.inputLabel, accessibilityRole: 'text' }, label),
          React.createElement(TextInput, {
            value: String(variables[name] ?? declaration.initial_value),
            onChangeText: (value) => setVariables((current) => ({ ...current, [name]: value })),
            placeholder,
            maxLength: Math.max(1, Math.min(500, number(node.properties.max_length) ?? 100)),
            keyboardType: node.properties.keyboard === 'email' ? 'email-address' : node.properties.keyboard === 'number' ? 'decimal-pad' : 'default',
            accessibilityLabel: label,
            style: styles.input,
          }),
        );
      }
      case 'slider': {
        const reference = text(node.properties.state_variable) ?? '';
        const name = reference.startsWith('state.') ? reference.slice(6) : '';
        const declaration = name ? props.document.custom_variables?.[name] : undefined;
        if (!declaration || declaration.type !== 'state' || declaration.value_type !== 'number') return null;
        const minimum = number(node.properties.minimum) ?? 0;
        const maximum = number(node.properties.maximum) ?? 100;
        const step = number(node.properties.step) ?? 1;
        const initial = number(variables[name]) ?? number(declaration.initial_value) ?? minimum;
        const value = Math.max(minimum, Math.min(maximum, initial));
        const labelId = text(node.properties.label_lid);
        const label = labelId ? interpolate(localizedValue(labelId) ?? 'Choose a value') : 'Choose a value';
        return React.createElement(View, { key: node.id ?? undefined, style: { width: '100%', alignItems: 'stretch', paddingVertical: 4 } },
          React.createElement(View, { style: { flexDirection: 'row', justifyContent: 'space-between', marginBottom: 4 } },
            React.createElement(Text, null, label),
            React.createElement(Text, { accessibilityLabel: `${label} value` }, String(value)),
          ),
          React.createElement(PaywallSlider, { value, minimum, maximum, step, orientation: node.properties.orientation === 'vertical' ? 'vertical' : 'horizontal', label, onChange: (next) => setVariables((current) => ({ ...current, [name]: next })) }),
        );
      }
      case 'multiple_choice': {
        const valueReference = text(node.properties.state_variable) ?? '';
        const labelReference = text(node.properties.label_state_variable) ?? '';
        const valueName = valueReference.startsWith('state.') ? valueReference.slice(6) : '';
        const labelName = labelReference.startsWith('state.') ? labelReference.slice(6) : '';
        const valueDeclaration = valueName ? props.document.custom_variables?.[valueName] : undefined;
        const labelDeclaration = labelName ? props.document.custom_variables?.[labelName] : undefined;
        if (valueDeclaration?.value_type !== 'selection' || labelDeclaration?.value_type !== 'text') return null;
        const multiple = node.properties.mode === 'multiple';
        const raw = variables[valueName] ?? valueDeclaration.initial_value;
        const chosen = multiple ? Array.isArray(raw) ? raw.filter((value): value is string => typeof value === 'string') : [] : typeof raw === 'string' && raw ? [raw] : [];
        const options = array(node.properties.options).map(record).map((option) => ({
          id: text(option.id) ?? text(option.value) ?? '',
          value: text(option.value) ?? '',
          label: interpolate(localizedValue(text(option.label_lid) ?? '') ?? text(option.value) ?? ''),
        }));
        const label = 'Choose an option';
        const select = (value: string) => {
          const next = multiple ? chosen.includes(value) ? chosen.filter((item) => item !== value) : [...chosen, value] : [value];
          const labels = new Map(options.map((option) => [option.value, option.label]));
          setVariables((current) => ({ ...current, [valueName]: multiple ? next : next[0] ?? '', [labelName]: next.map((item) => labels.get(item) ?? item).join(', ') }));
        };
        return React.createElement(PaywallChoice, { key: node.id ?? undefined, options, mode: multiple ? 'multiple' : 'single', randomize: node.properties.randomize_order === true, id: text(node.id) ?? 'choice', selected: chosen, label, onSelect: select });
      }
      case 'package': {
        const id = typeof node.properties.package_id === 'string' ? node.properties.package_id : '';
        const item = packages.find((candidate) => candidate.id === id);
        if (!item) return null;
        const active = selected === id;
        const label = localized(node, text(node.properties.label) ?? item.product.display_name ?? id);
        return React.createElement(Pressable, {
          key: node.id ?? id, onPress: () => setSelected(id), accessibilityRole: 'radio', accessibilityState: { checked: active }, accessibilityLabel: `${label}, ${item.product.localized_price ?? ''}`,
          style: [styles.package, active && styles.packageActive],
        }, React.createElement(Text, { style: styles.packageTitle }, `${active ? '◉' : '○'}  ${label}`), item.product.localized_price ? React.createElement(Text, { style: styles.price }, item.product.localized_price) : null);
      }
      case 'purchase_button':
      case 'cta': return React.createElement(Pressable, { key: node.id ?? undefined, onPress: () => { void purchase(); }, disabled: busy || !selected, accessibilityRole: 'button', accessibilityState: { disabled: busy || !selected }, style: [styles.cta, (busy || !selected) && styles.disabled] }, busy ? React.createElement(ActivityIndicator, { color: '#ffffff' }) : children.length ? React.createElement(View, { style: styles.stack }, ...children) : React.createElement(Text, { style: styles.ctaText }, localized(node, 'Continue')));
      case 'restore_button': return React.createElement(Pressable, { key: node.id ?? undefined, onPress: restore, disabled: busy, accessibilityRole: 'button', style: styles.quiet }, React.createElement(Text, null, localized(node, 'Restore purchases')));
      case 'button': {
        const action = record(node.properties.action);
        const animation = text(action.animation) ?? 'none';
        return React.createElement(Pressable, { key: node.id ?? undefined, onPress: () => { actionFeedback(node); void runTapActions(node); }, accessibilityRole: 'button', style: (state: { pressed: boolean }) => [styles.quiet, animation === 'shrink' && state.pressed ? { transform: [{ scale: 0.96 }] } : animation === 'grow' && state.pressed ? { transform: [{ scale: 1.04 }] } : undefined, animation === 'fade' && state.pressed ? { opacity: 0.55 } : undefined] }, children.length ? React.createElement(View, { style: styles.stack }, ...children) : React.createElement(Text, null, localized(node, 'Continue')));
      }
      case 'spacer': return React.createElement(View, { key: node.id ?? undefined, style: { height: number(node.properties.size) ?? 8 } });
      case 'image': {
        const source = record(node.properties.source);
        const light = record(source.light);
        const uri = text(light.url);
        return uri?.startsWith('https://') ? React.createElement(Image, { key: node.id ?? uri, source: { uri }, resizeMode: 'contain', accessibilityLabel: text(node.properties.accessibility_label) ?? '', style: styles.image }) : null;
      }
      case 'video': {
        const sources = record(node.properties.source);
        const dark = colorScheme === 'dark';
        const selectedSource = record(sources[dark ? 'dark' : 'light']);
        const lightSource = record(sources.light);
        const source = Object.keys(selectedSource).length ? selectedSource : lightSource;
        const uri = text(source.url);
        const fallback = record(node.properties.fallback_source);
        const selectedPoster = record(fallback[dark ? 'dark' : 'light']);
        const posterSource = Object.keys(selectedPoster).length ? selectedPoster : record(fallback.light);
        const poster = text(posterSource.original) ?? text(posterSource.url);
        const fitMode = text(node.properties.fit_mode) === 'fit' ? 'fit' : 'fill';
        const heightSize = record(record(node.properties.size).height);
        const fixedHeight = heightSize.type === 'fixed' ? number(heightSize.value) : undefined;
        const width = number(source.width) ?? 1;
        const height = number(source.height) ?? 1;
        const style = { width: '100%' as const, height: fixedHeight ?? undefined, aspectRatio: fixedHeight ? undefined : width / height, backgroundColor: '#000000' };
        if (!uri?.startsWith('https://') || (Platform.OS !== 'ios' && Platform.OS !== 'android')) {
          return poster?.startsWith('https://')
            ? React.createElement(Image, { key: node.id ?? poster, source: { uri: poster }, resizeMode: fitMode === 'fit' ? 'contain' : 'cover', accessibilityLabel: 'Video preview', style })
            : React.createElement(View, { key: node.id ?? undefined, accessibilityRole: 'image', accessibilityLabel: 'Video unavailable', style });
        }
        return React.createElement(NativePushifyVideo, {
          key: node.id ?? uri,
          videoUrl: uri,
          posterUrl: poster?.startsWith('https://') ? poster : undefined,
          autoPlay: node.properties.auto_play !== false,
          loops: node.properties.loop !== false,
          muted: node.properties.mute_audio !== false,
          showControls: node.properties.show_controls === true,
          fitMode,
          accessibilityLabel: text(node.properties.accessibility_label) ?? 'Video',
          style,
        });
      }
      case 'icon': {
        const name = text(node.properties.icon_name) ?? '★';
        const symbols: Record<string, string> = { check: '✓', checkmark: '✓', star: '★', bell: '♢', unlock: '◇', lock: '▣', heart: '♥', clock: '◷' };
        return React.createElement(Text, { key: node.id ?? undefined, accessibilityLabel: text(node.properties.accessibility_label) ?? undefined, style: { fontSize: number(node.properties.size) ?? 24, color: color(node.properties.color, '#315ee8'), textAlign: 'center' } }, symbols[name] ?? '●');
      }
      case 'timeline': {
        const items = array(node.properties.items).map(record);
        return React.createElement(View, { key: node.id ?? undefined, style: styles.stack }, ...items.map((item, index) => {
          const icon = record(item.icon); const title = nestedNode(item.title); const description = nestedNode(item.description);
          return React.createElement(View, { key: `${node.id ?? 'timeline'}-${index}`, style: styles.timelineRow }, React.createElement(View, { style: styles.timelineRail }, React.createElement(View, { style: styles.timelineIcon }, React.createElement(Text, { style: styles.timelineGlyph }, iconGlyph(text(icon.icon_name)))), index < items.length - 1 ? React.createElement(View, { style: styles.timelineLine }) : null), React.createElement(View, { style: styles.timelineCopy }, title ? renderNode(title) : null, description ? renderNode(description) : null));
        }));
      }
      case 'carousel': {
        const pages = array(node.properties.pages).map(nestedNode).filter((page): page is PushifyPaywallNode => page !== null);
        if (!pages.length) return null;
        const id = node.id ?? 'carousel'; const page = Math.min(carouselPages[id] ?? number(node.properties.initial_page_index) ?? 0, pages.length - 1);
        return React.createElement(View, { key: id }, React.createElement(FlatList<PushifyPaywallNode>, { horizontal: true, pagingEnabled: true, data: pages, initialScrollIndex: page, keyExtractor: (_, index) => `${id}-${index}`, showsHorizontalScrollIndicator: false, onMomentumScrollEnd: (event) => { const width = event.nativeEvent.layoutMeasurement.width; if (width > 0) setCarouselPages((current) => ({ ...current, [id]: Math.round(event.nativeEvent.contentOffset.x / width) })); }, renderItem: ({ item }) => React.createElement(View, { style: { width: '100%', paddingHorizontal: number(node.properties.page_spacing) ?? 0 } }, renderNode(item)) }), React.createElement(View, { style: styles.dots }, ...pages.map((_: PushifyPaywallNode, index: number) => React.createElement(View, { key: index, style: [styles.dot, page === index && styles.dotActive] }))));
      }
      case 'tabs': {
        const tabs = array(node.properties.tabs).map(record); if (!tabs.length) return null;
        const id = node.id ?? 'tabs'; const chosen = selectedTabs[id] ?? text(node.properties.default_tab_id) ?? text(tabs[0].id) ?? '';
        const active = tabs.find((tab) => tab.id === chosen) ?? tabs[0];
        return React.createElement(View, { key: id }, React.createElement(View, { style: styles.tabRow }, ...tabs.map((tab) => React.createElement(Pressable, { key: text(tab.id), accessibilityRole: 'tab', accessibilityState: { selected: tab.id === chosen }, onPress: () => setSelectedTabs((current) => ({ ...current, [id]: text(tab.id) ?? '' })), style: [styles.tab, tab.id === chosen && styles.tabActive] }, React.createElement(Text, null, text(tab.name) ?? '')))), renderNode(nestedNode(active.stack) ?? { id: null, kind: 'stack', properties: {}, children: [] }));
      }
      case 'countdown': {
        const date = Date.parse(text(record(node.properties.style).date) ?? ''); const remaining = Number.isFinite(date) ? Math.max(0, Math.floor((date - now) / 1000)) : 0;
        const template = remaining > 0 ? record(node.properties.countdown_stack) : record(node.properties.end_stack);
        const replaced = replaceCountdown(template, Math.floor(remaining / 86400), twoDigits(Math.floor(remaining / 3600) % 24), twoDigits(Math.floor(remaining / 60) % 60), twoDigits(remaining % 60));
        const nested = nestedNode(replaced); return nested ? renderNode(nested) : null;
      }
      case 'web_view': {
        const fallback = nestedNode(node.properties.fallback);
        const url = text(node.properties.url) ?? '';
        const size = record(node.properties.size);
        const heightSize = record(size.height);
        const height = Math.max(1, Math.min(100000, heightSize.type === 'fixed' ? number(heightSize.value) ?? 240 : 240));
        if (node.properties.protocol_version !== undefined && node.properties.protocol_version !== 1) {
          return fallback ? renderNode(fallback) : renderExperienceState('error');
        }
        if (!Platform.OS.match(/^(ios|android)$/) || !webViewOrigin(url)) {
          return fallback ? renderNode(fallback) : renderExperienceState('error');
        }
        return React.createElement(PaywallWebExperience, {
          key: `${node.id ?? 'web-experience'}-${url}`,
          url,
          height,
          fallback: fallback ? renderNode(fallback) : null,
        });
      }
      case 'tab_control': return null;
      default:
        return children.length ? React.createElement(View, { key: node.id ?? undefined, style: styles.stack }, ...children) : text(node.properties.text) ? React.createElement(Text, { key: node.id ?? undefined, style: styles.text }, text(node.properties.text)) : null;
    }
  }

  if (!screen) return React.createElement(View, { style: styles.root }, React.createElement(Text, null, 'Paywall unavailable'));
  const background = record(screen.background);
  const light = record(record(background.value).light);
  const backgroundColor = text(light.value) ?? '#ffffff';
  return React.createElement(View, { style: [styles.root, { backgroundColor }] },
    props.onClose ? React.createElement(View, { style: styles.closeRow }, React.createElement(Pressable, { onPress: () => { void closeWithSurvey(screen); }, accessibilityRole: 'button', accessibilityLabel: 'Close paywall', hitSlop: 12 }, React.createElement(Text, { style: styles.close }, '×'))) : null,
    React.createElement(ScrollView, { contentContainerStyle: styles.content }, screen.content ? renderNode(screen.content) : null),
    screen.footer ? renderNode(screen.footer) : null,
    message ? React.createElement(Text, { accessibilityLiveRegion: 'polite', style: styles.message }, message) : null,
    React.createElement(Modal, { visible: activeSurvey !== null, transparent: true, animationType: 'fade', onRequestClose: () => finishSurvey() },
      activeSurvey ? React.createElement(View, { style: styles.surveyBackdrop },
        React.createElement(View, { style: styles.surveyCard, accessibilityRole: 'summary' },
          React.createElement(Text, { style: styles.surveyQuestion }, localizedValue(activeSurvey.survey?.question_lid ?? '') ?? 'Tell us what you think'),
          ...(activeSurvey.survey?.options ?? []).map((option) => React.createElement(Pressable, {
            key: option.id,
            onPress: () => finishSurvey(option.id),
            accessibilityRole: 'button',
          }, React.createElement(Text, { style: styles.surveyOption }, localizedValue(option.label_lid) ?? option.label_lid))),
          React.createElement(Pressable, { onPress: () => finishSurvey(), accessibilityRole: 'button' }, React.createElement(Text, { style: styles.surveySkip }, localizedValue(activeSurvey.survey?.skip_label_lid ?? '') ?? 'Skip')),
        ),
      ) : null,
    ),
  );
}

type PaywallWebExperienceProps = {
  url: string;
  height: number;
  fallback: React.ReactNode;
};

function webViewOrigin(raw: string): string | null {
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' && url.hostname ? url.origin : null;
  } catch {
    return null;
  }
}

function renderExperienceState(state: 'loading' | 'error'): React.ReactElement {
  return React.createElement(View, {
    style: styles.webExperienceStatus,
    accessibilityRole: state === 'loading' ? 'progressbar' : 'image',
    accessibilityLabel: state === 'loading' ? 'Loading interactive experience' : 'Interactive experience unavailable',
  }, state === 'loading'
    ? React.createElement(ActivityIndicator, { color: '#ffffff' })
    : React.createElement(Text, { style: styles.webExperienceStatusText }, 'Interactive experience unavailable'));
}

function PaywallWebExperience({ url, height, fallback }: PaywallWebExperienceProps): React.ReactElement {
  const [state, setState] = useState<'loading' | 'ready' | 'error'>('loading');
  const origin = webViewOrigin(url);
  const mainFrameURL = useRef(url);
  const allowNavigation = (target: string) => {
    const targetOrigin = webViewOrigin(target);
    return origin !== null && targetOrigin === origin;
  };
  return React.createElement(View, { style: [styles.webExperience, { height }] },
    React.createElement(WebView, {
      source: { uri: url },
      style: styles.webExperienceFrame,
      originWhitelist: ['*'],
      javaScriptEnabled: true,
      domStorageEnabled: true,
      incognito: true,
      sharedCookiesEnabled: false,
      allowFileAccess: false,
      mixedContentMode: 'never',
      setSupportMultipleWindows: false,
      javaScriptCanOpenWindowsAutomatically: false,
      mediaPlaybackRequiresUserAction: true,
      onShouldStartLoadWithRequest: (request) => {
        const allowed = allowNavigation(request.url);
        if (allowed && request.isTopFrame) mainFrameURL.current = request.url;
        return allowed;
      },
      onLoadStart: (event) => { mainFrameURL.current = event.nativeEvent.url; setState('loading'); },
      onLoad: () => setState('ready'),
      onError: () => setState('error'),
      onHttpError: (event) => {
        if (event.nativeEvent.url === mainFrameURL.current && event.nativeEvent.statusCode >= 400) setState('error');
      },
      onRenderProcessGone: () => setState('error'),
    }),
    state !== 'ready'
      ? React.createElement(View, { style: styles.webExperienceFallback }, fallback ?? renderExperienceState(state))
      : null,
  );
}

function array(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
function nestedNode(value: unknown): PushifyPaywallNode | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const input = value as Record<string, unknown>; const kind = text(input.kind) ?? text(input.type); if (!kind) return null;
  const props = input.properties && typeof input.properties === 'object' && !Array.isArray(input.properties)
    ? record(input.properties)
    : { ...input };
  delete props.kind; delete props.type; delete props.children; delete props.components; delete props.id; delete props.properties;
  const childValues = array(input.children).length ? array(input.children) : array(input.components);
  return { id: text(input.id), kind, properties: props, children: childValues.map(nestedNode).filter((child): child is PushifyPaywallNode => child !== null) };
}
function replaceCountdown(value: Record<string, unknown>, days: number, hours: string, minutes: string, seconds: string): Record<string, unknown> {
  const result = { ...value };
  const replace = (text: string) => text.split('{{ count_days_without_zero }}').join(String(days)).split('{{ count_hours_with_zero }}').join(hours).split('{{ count_minutes_with_zero }}').join(minutes).split('{{ count_seconds_with_zero }}').join(seconds);
  if (typeof result.text === 'string') result.text = replace(result.text);
  if (result.properties && typeof result.properties === 'object') {
    const properties = { ...record(result.properties) };
    if (typeof properties.text === 'string') properties.text = replace(properties.text);
    result.properties = properties;
  }
  if (Array.isArray(result.components)) result.components = result.components.map((child) => replaceCountdown(record(child), days, hours, minutes, seconds));
  if (Array.isArray(result.children)) result.children = result.children.map((child) => replaceCountdown(record(child), days, hours, minutes, seconds));
  return result;
}
function twoDigits(value: number): string { return String(value).padStart(2, '0'); }
function iconGlyph(name: string | null): string { return ({ check: '✓', checkmark: '✓', star: '★', bell: '♢', unlock: '◇' } as Record<string, string>)[name ?? ''] ?? '•'; }
function color(value: unknown, fallback: string): string {
  if (value && typeof value === 'object') {
    const object = record(value);
    value = record(object.light).value ?? record(record(object.value).light).value;
  }
  if (typeof value === 'string' && /^#[\da-f]{6}([\da-f]{2})?$/i.test(value)) return value.length === 9 ? `#${value.slice(7)}${value.slice(1, 7)}` : value;
  return fallback;
}

function findPackage(node: PushifyPaywallNode | null | undefined, selectedOnly: boolean): string | null {
  if (!node) return null;
  if (node.kind === 'package' && (!selectedOnly || node.properties.is_selected_by_default === true) && typeof node.properties.package_id === 'string') return node.properties.package_id;
  for (const child of node.children) { const found = findPackage(child, selectedOnly); if (found) return found; }
  return null;
}
function record(value: unknown): Record<string, unknown> { return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}; }
function text(value: unknown): string | null { return typeof value === 'string' ? value : null; }
function number(value: unknown): number | null { return typeof value === 'number' && Number.isFinite(value) ? value : null; }
function weight(value: unknown): 'normal' | '500' | '600' | 'bold' { return value === 'bold' ? 'bold' : value === 'semibold' ? '600' : value === 'medium' ? '500' : 'normal'; }

const styles = StyleSheet.create({
  surveyBackdrop: { flex: 1, justifyContent: 'center', padding: 24, backgroundColor: 'rgba(0,0,0,0.55)' }, surveyCard: { borderRadius: 18, backgroundColor: '#ffffff', padding: 20, gap: 12 }, surveyQuestion: { fontSize: 18, fontWeight: '700', marginBottom: 4 }, surveyOption: { paddingVertical: 12, paddingHorizontal: 10, borderRadius: 10, overflow: 'hidden', backgroundColor: '#f2f3f5', color: '#171717' }, surveySkip: { textAlign: 'center', padding: 10, color: '#555555' },
  root: { flex: 1, padding: 16 }, closeRow: { minHeight: 44, alignItems: 'flex-end', justifyContent: 'center' }, close: { fontSize: 28, paddingHorizontal: 8 },
  webExperience: { width: '100%', overflow: 'hidden', borderRadius: 12, backgroundColor: '#000000' }, webExperienceFrame: { ...StyleSheet.absoluteFillObject }, webExperienceFallback: { ...StyleSheet.absoluteFillObject, zIndex: 1 }, webExperienceStatus: { ...StyleSheet.absoluteFillObject, alignItems: 'center', justifyContent: 'center', backgroundColor: '#000000' }, webExperienceStatusText: { color: '#ffffff', textAlign: 'center' },
  content: { flexGrow: 1, justifyContent: 'center', gap: 10 }, stack: { gap: 10, alignItems: 'stretch' }, row: { flexDirection: 'row', alignItems: 'center' }, rowChild: { flex: 1 },
  text: { textAlign: 'center', flexShrink: 1 }, inputWrap: { width: '100%', marginVertical: 6, gap: 5 }, inputLabel: { fontSize: 13, color: '#444444' }, input: { minHeight: 42, borderWidth: 1, borderColor: '#777777', borderRadius: 8, paddingHorizontal: 12, color: '#111111', backgroundColor: '#ffffff' }, package: { borderWidth: 1, borderColor: '#8b8b8b', borderRadius: 14, padding: 14, marginVertical: 5 }, packageActive: { borderWidth: 2, borderColor: '#315ee8' }, packageTitle: { fontSize: 16, fontWeight: '600' }, price: { marginLeft: 26, marginTop: 4 },
  cta: { backgroundColor: '#315ee8', borderRadius: 14, padding: 16, alignItems: 'center', minHeight: 52 }, disabled: { opacity: 0.55 }, ctaText: { color: '#ffffff', fontWeight: '700' }, quiet: { padding: 12, alignItems: 'center' }, image: { width: '100%', height: 180 }, message: { textAlign: 'center', padding: 8 },
  timelineRow: { flexDirection: 'row', minHeight: 54 }, timelineRail: { alignItems: 'center', width: 36 }, timelineIcon: { width: 28, height: 28, borderRadius: 14, backgroundColor: '#315ee8', alignItems: 'center', justifyContent: 'center' }, timelineGlyph: { color: '#ffffff', fontWeight: '700' }, timelineLine: { width: 2, flex: 1, backgroundColor: '#d4d4d4', marginVertical: 4 }, timelineCopy: { flex: 1, paddingBottom: 12 }, dots: { flexDirection: 'row', justifyContent: 'center', gap: 6, padding: 8 }, dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#d4d4d4' }, dotActive: { width: 18, backgroundColor: '#315ee8' }, tabRow: { flexDirection: 'row', gap: 6, marginBottom: 10 }, tab: { flex: 1, alignItems: 'center', padding: 10, borderRadius: 9, backgroundColor: '#f1f1f1' }, tabActive: { backgroundColor: '#dce5ff' },
});

import * as React from 'react';
import { useEffect, useMemo, useState } from 'react';
import { ActivityIndicator, Image, Linking, Pressable, ScrollView, StyleSheet, Text, View, FlatList } from 'react-native';
import type { PushifyOfferings, PushifyPaywallNode, PushifyPaywallV1, PushifyPurchases } from './purchases';

export type PushifyPaywallProps = {
  document: PushifyPaywallV1;
  offering: PushifyOfferings['offerings'][number];
  purchases: PushifyPurchases;
  locale?: string;
  onClose?: () => void;
  onPurchased?: (customer: Awaited<ReturnType<PushifyPurchases['customerInfo']>>) => void;
};

/** Accessible renderer for the core Pushify paywall document components. */
export function PushifyPaywallView(props: PushifyPaywallProps): React.ReactElement {
  const firstScreen = props.document.screens[0];
  const packages = props.offering.packages;
  const defaultPackage = useMemo(() => findPackage(firstScreen?.content, true), [firstScreen]);
  const [selected, setSelected] = useState(defaultPackage ?? packages[0]?.id ?? '');
  const [screenID, setScreenID] = useState(firstScreen?.id ?? '');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const [carouselPages, setCarouselPages] = useState<Record<string, number>>({});
  const [selectedTabs, setSelectedTabs] = useState<Record<string, string>>({});
  const [variables, setVariables] = useState<Record<string, string | number | boolean>>(() => Object.fromEntries(Object.entries(props.document.custom_variables ?? {}).map(([key, value]) => [key, value.initial_value])));
  const screen = props.document.screens.find((candidate) => candidate.id === screenID) ?? firstScreen;
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);

  async function purchase(packageID?: string, action: Record<string, unknown> = {}, sourceScreen = screen) {
    const productID = packageID ?? selected;
    if (busy) return;
    if (!packages.some((item) => item.id === productID)) { setMessage('This purchase option is unavailable.'); return; }
    setBusy(true); setMessage(null);
    try {
      const result = await props.purchases.purchase(productID);
      if (result.status === 'purchased') props.onPurchased?.(result.customerInfo);
      if (result.status === 'purchased') runPurchaseOutcome('after_purchase', 'close', action, sourceScreen);
      if (result.status === 'cancelled') runPurchaseOutcome('on_abandon', 'none', action, sourceScreen);
      if (result.status === 'pending') setMessage('Purchase is pending approval.');
    } catch {
      setMessage('Purchase could not be completed. Please try again.');
    } finally { setBusy(false); }
  }

  function runPurchaseOutcome(key: string, fallback: string, action: Record<string, unknown>, sourceScreen?: PushifyPaywallV1['screens'][number]): void {
    const outcome = record(action[key]);
    const kind = text(outcome.type) ?? fallback;
    if (kind === 'none') return;
    if (kind === 'close') { props.onClose?.(); return; }
    const index = props.document.screens.findIndex((candidate) => candidate.id === sourceScreen?.id);
    if (kind === 'navigate_back') {
      if (index > 0) setScreenID(props.document.screens[index - 1]!.id);
      else props.onClose?.();
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
    const locales = [props.locale, props.document.default_locale, 'en_US'].filter((item): item is string => Boolean(item));
    if (typeof key === 'string') {
      for (const locale of locales) {
        const value = node.properties.text_lid && (screen?.localizations[locale]?.[key] ?? props.document.locales[locale]?.[key]);
        if (typeof value === 'string') return interpolate(value);
      }
    }
    return interpolate(fallback || (typeof node.properties.text === 'string' ? node.properties.text : ''));
  }

  function interpolate(value: string): string { return value.replace(/\{\{\s*state\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}/g, (token, key: string) => variables[key] === undefined ? token : String(variables[key])); }

  function localizedValue(key: string): string | null {
    const locales = [props.locale, props.document.default_locale, 'en_US'].filter((item): item is string => Boolean(item));
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
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') { setMessage('This link is unavailable.'); return; }
    try { await Linking.openURL(parsed.toString()); }
    catch { setMessage('This link could not be opened.'); }
  }

  async function handleButton(node: PushifyPaywallNode): Promise<void> {
    const action = record(node.properties.action);
    const kind = text(action.type) ?? text(node.properties.action);
    if (kind === 'update_variable') {
      const name = text(action.variable)?.replace(/^state\./, '');
      const declaration = name ? props.document.custom_variables?.[name] : undefined;
      if (!name || !declaration) { setMessage('This state variable is not declared.'); return; }
      setVariables((current) => { const before = current[name] ?? declaration.initial_value; const operation = text(action.operation) ?? 'set'; let next: string | number | boolean;
        if (declaration.value_type === 'number') { const value = number(action.value) ?? 0; next = operation === 'increment' ? Number(before) + value : operation === 'decrement' ? Number(before) - value : value; }
        else if (declaration.value_type === 'boolean') next = operation === 'toggle' ? !Boolean(before) : action.value === true;
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
    if (kind === 'navigate_back') {
      const index = props.document.screens.findIndex((candidate) => candidate.id === screen?.id);
      if (index > 0) setScreenID(props.document.screens[index - 1]!.id);
      else props.onClose?.();
      return;
    }
    if (kind === 'workflow') {
      const index = props.document.screens.findIndex((candidate) => candidate.id === screen?.id);
      const nextScreen = index >= 0 ? props.document.screens[index + 1] : undefined;
      if (nextScreen) setScreenID(nextScreen.id);
      else setMessage('This flow has no next screen.');
      return;
    }
    const next = text(node.properties.next_screen_id);
    if (next && props.document.screens.some((candidate) => candidate.id === next)) { setScreenID(next); return; }
    if (kind === 'purchase' || kind === 'purchase_with_outcome' || kind === 'purchase_product' || node.kind === 'purchase_button') { await purchase(text(action.package_id) ?? undefined, action, screen); return; }
    if (kind === 'close' || kind === 'close_workflow') { props.onClose?.(); return; }
    setMessage('This button action is not supported by this SDK version.');
  }

  function renderNode(node: PushifyPaywallNode): React.ReactNode {
    const children = node.children.map((child) => renderNode(child));
    switch (node.kind) {
      case 'stack': return React.createElement(View, { key: node.id ?? undefined, style: styles.stack }, ...children);
      case 'hstack': return React.createElement(View, { key: node.id ?? undefined, style: styles.row }, ...children.map((child) => React.createElement(View, { style: styles.rowChild }, child)));
      case 'text':
      case 'title': return React.createElement(Text, { key: node.id ?? undefined, style: [styles.text, { fontSize: number(node.properties.font_size) ?? 20, fontWeight: weight(node.properties.font_weight) }] }, localized(node));
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
      case 'button': return React.createElement(Pressable, { key: node.id ?? undefined, onPress: () => { void handleButton(node); }, accessibilityRole: 'button', style: styles.quiet }, children.length ? React.createElement(View, { style: styles.stack }, ...children) : React.createElement(Text, null, localized(node, 'Continue')));
      case 'spacer': return React.createElement(View, { key: node.id ?? undefined, style: { height: number(node.properties.size) ?? 8 } });
      case 'image': {
        const source = record(node.properties.source);
        const light = record(source.light);
        const uri = text(light.url);
        return uri?.startsWith('https://') ? React.createElement(Image, { key: node.id ?? uri, source: { uri }, resizeMode: 'contain', accessibilityLabel: text(node.properties.accessibility_label) ?? '', style: styles.image }) : null;
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
        return fallback ? renderNode(fallback) : null;
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
    props.onClose ? React.createElement(View, { style: styles.closeRow }, React.createElement(Pressable, { onPress: props.onClose, accessibilityRole: 'button', accessibilityLabel: 'Close paywall', hitSlop: 12 }, React.createElement(Text, { style: styles.close }, '×'))) : null,
    React.createElement(ScrollView, { contentContainerStyle: styles.content }, screen.content ? renderNode(screen.content) : null),
    screen.footer ? renderNode(screen.footer) : null,
    message ? React.createElement(Text, { accessibilityLiveRegion: 'polite', style: styles.message }, message) : null,
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
  root: { flex: 1, padding: 16 }, closeRow: { minHeight: 44, alignItems: 'flex-end', justifyContent: 'center' }, close: { fontSize: 28, paddingHorizontal: 8 },
  content: { flexGrow: 1, justifyContent: 'center', gap: 10 }, stack: { gap: 10, alignItems: 'stretch' }, row: { flexDirection: 'row', alignItems: 'center' }, rowChild: { flex: 1 },
  text: { textAlign: 'center', flexShrink: 1 }, package: { borderWidth: 1, borderColor: '#8b8b8b', borderRadius: 14, padding: 14, marginVertical: 5 }, packageActive: { borderWidth: 2, borderColor: '#315ee8' }, packageTitle: { fontSize: 16, fontWeight: '600' }, price: { marginLeft: 26, marginTop: 4 },
  cta: { backgroundColor: '#315ee8', borderRadius: 14, padding: 16, alignItems: 'center', minHeight: 52 }, disabled: { opacity: 0.55 }, ctaText: { color: '#ffffff', fontWeight: '700' }, quiet: { padding: 12, alignItems: 'center' }, image: { width: '100%', height: 180 }, message: { textAlign: 'center', padding: 8 },
  timelineRow: { flexDirection: 'row', minHeight: 54 }, timelineRail: { alignItems: 'center', width: 36 }, timelineIcon: { width: 28, height: 28, borderRadius: 14, backgroundColor: '#315ee8', alignItems: 'center', justifyContent: 'center' }, timelineGlyph: { color: '#ffffff', fontWeight: '700' }, timelineLine: { width: 2, flex: 1, backgroundColor: '#d4d4d4', marginVertical: 4 }, timelineCopy: { flex: 1, paddingBottom: 12 }, dots: { flexDirection: 'row', justifyContent: 'center', gap: 6, padding: 8 }, dot: { width: 6, height: 6, borderRadius: 3, backgroundColor: '#d4d4d4' }, dotActive: { width: 18, backgroundColor: '#315ee8' }, tabRow: { flexDirection: 'row', gap: 6, marginBottom: 10 }, tab: { flex: 1, alignItems: 'center', padding: 10, borderRadius: 9, backgroundColor: '#f1f1f1' }, tabActive: { backgroundColor: '#dce5ff' },
});

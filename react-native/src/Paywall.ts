import * as React from 'react';
import { useMemo, useState } from 'react';
import { ActivityIndicator, Image, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
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
  const screen = props.document.screens.find((candidate) => candidate.id === screenID) ?? firstScreen;

  async function purchase() {
    if (!selected || busy) return;
    setBusy(true); setMessage(null);
    try {
      const result = await props.purchases.purchase(selected);
      if (result.status === 'purchased') props.onPurchased?.(result.customerInfo);
      if (result.status === 'pending') setMessage('Purchase is pending approval.');
    } catch {
      setMessage('Purchase could not be completed. Please try again.');
    } finally { setBusy(false); }
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
        if (typeof value === 'string') return value;
      }
    }
    return fallback || (typeof node.properties.text === 'string' ? node.properties.text : '');
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
      case 'cta': return React.createElement(Pressable, { key: node.id ?? undefined, onPress: purchase, disabled: busy || !selected, accessibilityRole: 'button', accessibilityState: { disabled: busy || !selected }, style: [styles.cta, (busy || !selected) && styles.disabled] }, busy ? React.createElement(ActivityIndicator, { color: '#ffffff' }) : React.createElement(Text, { style: styles.ctaText }, localized(node, 'Continue')));
      case 'restore_button': return React.createElement(Pressable, { key: node.id ?? undefined, onPress: restore, disabled: busy, accessibilityRole: 'button', style: styles.quiet }, React.createElement(Text, null, localized(node, 'Restore purchases')));
      case 'button': return React.createElement(Pressable, { key: node.id ?? undefined, onPress: () => {
        if (node.properties.action === 'restore') { void restore(); return; }
        const next = node.properties.next_screen_id;
        if (typeof next === 'string' && props.document.screens.some((candidate) => candidate.id === next)) setScreenID(next);
        else void purchase();
      }, accessibilityRole: 'button', style: styles.quiet }, React.createElement(Text, null, localized(node, 'Continue')));
      case 'spacer': return React.createElement(View, { key: node.id ?? undefined, style: { height: number(node.properties.size) ?? 8 } });
      case 'image': {
        const source = record(node.properties.source);
        const light = record(source.light);
        const uri = text(light.url);
        return uri?.startsWith('https://') ? React.createElement(Image, { key: node.id ?? uri, source: { uri }, resizeMode: 'contain', accessibilityLabel: text(node.properties.accessibility_label) ?? '', style: styles.image }) : null;
      }
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
});

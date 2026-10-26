import * as React from 'react';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Linking, Modal, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import type { PushifyPurchases } from './purchases';

export type PushifyCustomerCenterProps = {
  purchases: PushifyPurchases;
  locale?: string;
  onCustomAction?: (actionIdentifier: string) => void | Promise<void>;
};

type JsonMap = Record<string, unknown>;

/** Dashboard-configured customer management screen with native store and support actions. */
export function PushifyCustomerCenterView({ purchases, locale, onCustomAction }: PushifyCustomerCenterProps): React.ReactElement {
  const [configuration, setConfiguration] = useState<JsonMap | null>(null);
  const [customer, setCustomer] = useState<JsonMap | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [ticketOpen, setTicketOpen] = useState(false);
  const [email, setEmail] = useState('');
  const [ticketMessage, setTicketMessage] = useState('');
  const [loadError, setLoadError] = useState(false);

  async function load() {
    setLoadError(false);
    try {
      const [center, snapshot] = await Promise.all([purchases.customerCenter(locale), purchases.customerInfo()]);
      setConfiguration(map(center.configuration));
      setCustomer(snapshot);
    } catch {
      setLoadError(true);
    }
  }
  useEffect(() => { void load(); }, [purchases, locale]);

  async function runPath(path: JsonMap) {
    if (busy) return;
    setBusy(true); setMessage(null);
    try {
      switch (path.type) {
        case 'MISSING_PURCHASE':
          await purchases.restorePurchases();
          setMessage('Purchases restored.');
          await load();
          break;
        case 'CANCEL':
          await Linking.openURL(Platform.OS === 'ios' ? 'https://apps.apple.com/account/subscriptions' : 'https://play.google.com/store/account/subscriptions');
          break;
        case 'REFUND_REQUEST':
          await Linking.openURL(Platform.OS === 'ios' ? 'https://reportaproblem.apple.com/' : 'https://play.google.com/store/account/orderhistory');
          break;
        case 'CUSTOM_URL':
          if (!isAllowedUrl(path.url)) throw new Error('Customer Center URL is invalid.');
          await Linking.openURL(path.url);
          break;
        case 'CUSTOM_ACTION':
          if (typeof path.action_identifier === 'string' && onCustomAction) await onCustomAction(path.action_identifier);
          else setMessage('This account action is not available.');
          break;
        default:
          setMessage('This account action is not available.');
      }
    } catch {
      setMessage('This action could not be completed. Please try again.');
    } finally { setBusy(false); }
  }

  async function sendTicket() {
    if (!email.trim() || !email.includes('@') || !ticketMessage.trim()) { setMessage('Enter a valid email and message.'); return; }
    setBusy(true); setMessage(null);
    try {
      await purchases.createSupportTicket(email.trim(), ticketMessage.trim());
      setTicketOpen(false); setEmail(''); setTicketMessage(''); setMessage('Your request was sent to support.');
    } catch { setMessage('The support request could not be sent. Please try again.'); }
    finally { setBusy(false); }
  }

  if (loadError) return React.createElement(View, { style: styles.center }, React.createElement(Text, null, 'Customer Center is unavailable.'), React.createElement(Pressable, { onPress: () => { void load(); }, accessibilityRole: 'button' }, React.createElement(Text, { style: styles.link }, 'Try again')));
  if (!configuration || !customer) return React.createElement(View, { style: styles.center, accessibilityLabel: 'Loading Customer Center' }, React.createElement(ActivityIndicator));

  const active = list(map(customer.entitlements).active).length > 0;
  const screens = map(configuration.screens);
  const screen = map(screens[active ? 'MANAGEMENT' : 'NO_ACTIVE']);
  const support = map(configuration.support);
  const ticketPolicy = map(support.support_tickets);
  const allowTickets = ticketPolicy.allow_creation === true;
  const strings = map(map(configuration.localization).localized_strings);
  const paths = list(screen.paths).map(map);

  return React.createElement(View, { style: styles.root },
    React.createElement(ScrollView, { contentContainerStyle: styles.content },
      React.createElement(Text, { accessibilityRole: 'header', style: styles.heading }, str(screen.title, 'Manage subscription')),
      typeof screen.subtitle === 'string' ? React.createElement(Text, { style: styles.subtitle }, screen.subtitle) : null,
      busy ? React.createElement(ActivityIndicator, { style: styles.progress }) : null,
      ...paths.map((path, index) => React.createElement(Pressable, {
        key: str(path.id, String(index)), accessibilityRole: 'button', disabled: busy, onPress: () => { void runPath(path); }, style: styles.action,
      }, React.createElement(Text, { style: styles.actionText }, str(path.title, 'Continue')))),
      active && support.display_purchase_history_link === true ? React.createElement(Text, { style: styles.detail }, `${list(customer.transactions).length} verified purchases`) : null,
      allowTickets ? React.createElement(Pressable, { accessibilityRole: 'button', disabled: busy, onPress: () => setTicketOpen(true), style: styles.secondary }, React.createElement(Text, null, str(strings.contact_support, 'Contact support'))) : null,
      message ? React.createElement(Text, { accessibilityLiveRegion: 'polite', style: styles.message }, message) : null,
    ),
    React.createElement(Modal, { visible: ticketOpen, transparent: true, animationType: 'slide', onRequestClose: () => setTicketOpen(false) },
      React.createElement(View, { style: styles.modalBackdrop }, React.createElement(View, { style: styles.modal },
        React.createElement(Text, { accessibilityRole: 'header', style: styles.heading }, 'Contact support'),
        React.createElement(TextInput, { value: email, onChangeText: setEmail, autoCapitalize: 'none', keyboardType: 'email-address', placeholder: 'Email', accessibilityLabel: 'Email' }),
        React.createElement(TextInput, { value: ticketMessage, onChangeText: setTicketMessage, placeholder: 'How can we help?', accessibilityLabel: 'Message', multiline: true, numberOfLines: 5, style: styles.input }),
        React.createElement(Pressable, { accessibilityRole: 'button', disabled: busy, onPress: () => { void sendTicket(); }, style: styles.action }, React.createElement(Text, { style: styles.actionText }, 'Send request')),
        React.createElement(Pressable, { accessibilityRole: 'button', onPress: () => setTicketOpen(false), style: styles.secondary }, React.createElement(Text, null, 'Close')),
      )),
    ),
  );
}

function map(value: unknown): JsonMap { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as JsonMap : {}; }
function list(value: unknown): unknown[] { return Array.isArray(value) ? value : []; }
function str(value: unknown, fallback: string): string { return typeof value === 'string' ? value : fallback; }
function isAllowedUrl(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  const scheme = value.match(/^([a-z][a-z0-9+.-]*):/i)?.[1]?.toLowerCase();
  return Boolean(scheme && !['javascript', 'data', 'file', 'blob', 'about'].includes(scheme));
}

const styles = StyleSheet.create({
  root: { flex: 1 }, content: { padding: 20, gap: 12 }, center: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12 },
  heading: { fontSize: 24, fontWeight: '700' }, subtitle: { fontSize: 16, opacity: 0.8, marginBottom: 8 }, progress: { marginVertical: 8 },
  action: { minHeight: 48, justifyContent: 'center', alignItems: 'center', borderWidth: 1, borderColor: '#777777', borderRadius: 12, paddingHorizontal: 16, paddingVertical: 12 }, actionText: { fontSize: 16, fontWeight: '600' },
  secondary: { alignSelf: 'center', padding: 12 }, detail: { paddingVertical: 8, opacity: 0.8 }, message: { textAlign: 'center', padding: 8 }, link: { textDecorationLine: 'underline' },
  modalBackdrop: { flex: 1, justifyContent: 'center', backgroundColor: '#00000080', padding: 20 }, modal: { backgroundColor: '#ffffff', borderRadius: 16, padding: 20, gap: 12 }, input: { minHeight: 100, textAlignVertical: 'top' },
});

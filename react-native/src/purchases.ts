import { NativeEventEmitter, NativeModules, type EmitterSubscription } from 'react-native';

export type PushifyCustomerInfo = {
  customer: { id: string; original_id: string; first_seen_at: string; attributes: Record<string, { value: string | null; updated_at_ms: number | null }> };
  entitlements: { active: Array<{ key: string; expires_at: string | null; product_id: string }>; available: string[] };
  transactions: Array<{ product_id: string; store: string; purchased_at: string; transaction_id: string }>;
  virtual_currencies: Array<{ code: string; name: string; description: string | null; balance: number }>;
  [key: string]: unknown;
};

export type PushifyOfferings = {
  schema: 'pushify.offerings/v1';
  current_offering_id: string | null;
  offerings: Array<{
    id: string;
    description: string;
    paywall: PushifyPaywallV1 | null;
    packages: Array<{ id: string; product: {
      product_id: string;
      plan_id: string | null;
      type: string | null;
      display_name?: string;
      localized_price?: string;
      price_amount?: string;
      currency_code?: string;
      pricing_phases?: Array<{
        formatted_price: string;
        price_amount_micros: string;
        currency_code: string;
        billing_period: string;
        recurrence_mode: number;
        billing_cycle_count: number;
      }>;
    } }>;
  }>;
  [key: string]: unknown;
};

export type PushifyPaywallNode = { id: string | null; kind: string; properties: Record<string, unknown>; children: PushifyPaywallNode[] };
export type PushifyPaywallV1 = {
  schema: 'pushify.paywall/v1'; id: string; revision: number; default_locale: string;
  locales: Record<string, Record<string, unknown>>;
  screens: Array<{ id: string; name: string; background: unknown; content: PushifyPaywallNode | null; footer: PushifyPaywallNode | null; localizations: Record<string, Record<string, unknown>> }>;
  automatically_scale_font_size: boolean; exit_offer: unknown; state: unknown;
};

export type PushifyPurchaseResult =
  | { status: 'purchased'; customerInfo: PushifyCustomerInfo }
  | { status: 'pending' }
  | { status: 'cancelled' };

export type PushifyPurchasesOptions = {
  publicApiKey: string;
  apiBaseUrl?: string;
};

type NativePurchasesModule = {
  configure(options: PushifyPurchasesOptions): Promise<PushifyCustomerInfo | null>;
  customerInfo(): Promise<PushifyCustomerInfo>;
  cachedCustomerInfo(): Promise<PushifyCustomerInfo | null>;
  offerings(placement?: string): Promise<PushifyOfferings>;
  customerCenter(locale?: string): Promise<{ schema: 'pushify.customer-center/v1'; customer_id: string; configuration: Record<string, unknown> }>;
  createSupportTicket(email: string, message: string): Promise<{ accepted: boolean }>;
  identify(customerId: string): Promise<PushifyCustomerInfo>;
  logOut(): Promise<PushifyCustomerInfo>;
  setAttributes(attributes: Record<string, string | number | boolean | null>): Promise<PushifyCustomerInfo>;
  restorePurchases(): Promise<PushifyCustomerInfo>;
  syncPurchases(): Promise<PushifyCustomerInfo>;
  purchase(packageId: string): Promise<PushifyPurchaseResult>;
  logEvent(name: string, properties: Record<string, unknown>, eventId: string): Promise<number>;
  spendVirtualCurrency(adjustments: Record<string, number>, idempotencyKey: string, reference?: string | null): Promise<{ virtual_currencies: PushifyCustomerInfo['virtual_currencies'] }>;
  readDeferredToken(): Promise<string | null>;
  addListener(eventName: string): void;
  removeListeners(count: number): void;
};

const native = NativeModules.PushifyPurchases as NativePurchasesModule | undefined;
const emitter = native ? new NativeEventEmitter(NativeModules.PushifyPurchases) : undefined;

/** First-party React Native client backed by StoreKit 2 on iOS and Play Billing on Android. */
export class PushifyPurchases {
  private readonly options: PushifyPurchasesOptions;

  constructor(options: PushifyPurchasesOptions) {
    if (!options.publicApiKey.trim()) throw new Error('A Pushify public app key is required.');
    const base = new URL(options.apiBaseUrl ?? 'https://api.pushify.app');
    if (base.protocol !== 'https:') throw new Error('Pushify API URL must use HTTPS.');
    this.options = { ...options, apiBaseUrl: base.toString().replace(/\/$/, '') };
    this.requireNative();
  }

  /** Configures the native store client and begins purchase reconciliation. */
  configure(): Promise<PushifyCustomerInfo | null> {
    return this.requireNative().configure(this.options);
  }

  customerInfo(): Promise<PushifyCustomerInfo> { return this.requireNative().customerInfo(); }
  cachedCustomerInfo(): Promise<PushifyCustomerInfo | null> { return this.requireNative().cachedCustomerInfo(); }
  offerings(placement?: string): Promise<PushifyOfferings> { return this.requireNative().offerings(placement); }
  customerCenter(locale?: string): Promise<{ schema: 'pushify.customer-center/v1'; customer_id: string; configuration: Record<string, unknown> }> { return this.requireNative().customerCenter(locale); }
  createSupportTicket(email: string, message: string): Promise<{ accepted: boolean }> { return this.requireNative().createSupportTicket(email, message); }
  identify(customerId: string): Promise<PushifyCustomerInfo> { return this.requireNative().identify(customerId); }
  logOut(): Promise<PushifyCustomerInfo> { return this.requireNative().logOut(); }
  setAttributes(attributes: Record<string, string | number | boolean | null>): Promise<PushifyCustomerInfo> { return this.requireNative().setAttributes(attributes); }
  restorePurchases(): Promise<PushifyCustomerInfo> { return this.requireNative().restorePurchases(); }
  syncPurchases(): Promise<PushifyCustomerInfo> { return this.requireNative().syncPurchases(); }
  purchase(packageId: string): Promise<PushifyPurchaseResult> { return this.requireNative().purchase(packageId); }

  logEvent(name: string, properties: Record<string, unknown> = {}, eventId = createEventId()): Promise<number> {
    return this.requireNative().logEvent(name, properties, eventId);
  }

  spendVirtualCurrency(adjustments: Record<string, number>, idempotencyKey: string, reference?: string): Promise<{ virtual_currencies: PushifyCustomerInfo['virtual_currencies'] }> {
    return this.requireNative().spendVirtualCurrency(adjustments, idempotencyKey, reference);
  }

  /** Subscribes to server-verified customer snapshot updates. */
  addCustomerInfoListener(listener: (customer: PushifyCustomerInfo) => void): EmitterSubscription {
    if (!emitter) throw new Error('Pushify native module is unavailable. Rebuild the app after installing the package.');
    return emitter.addListener('customerInfoUpdated', listener);
  }

  readDeferredToken(): Promise<string | null> { return this.requireNative().readDeferredToken(); }

  private requireNative(): NativePurchasesModule {
    if (!native) throw new Error('Pushify native module is unavailable. Rebuild the app after installing the package.');
    return native;
  }
}

function createEventId(): string {
  const random = Array.from({ length: 16 }, () => Math.floor(Math.random() * 256).toString(16).padStart(2, '0')).join('');
  return `evt_${Date.now()}_${random}`;
}

import { NativeModules } from 'react-native';

/** A resolved Pushify acquisition link. The app decides how to navigate. */
export type PushifyAcquisitionLink = {
  object: 'acquisition_link_resolution';
  status: 'resolved' | 'attributed';
  link_id: string;
  name: string;
  slug: string;
  destination: string;
  app_scheme: string;
  campaign: Record<string, string>;
  attributed: boolean;
};

export type AcquisitionLinkClientOptions = {
  publicApiKey: string;
  apiBaseUrl?: string;
  appUserId?: string;
};

const TOKEN = /^(rdlt|rdit)_[A-Za-z0-9_-]{30,80}$/;

/** Finds a direct acquisition token in an incoming Pushify app URL. */
export function acquisitionTokenFromUrl(url: string): string | undefined {
  try {
    const token = new URL(url).searchParams.get('rdt') ?? undefined;
    return token && TOKEN.test(token) ? token : undefined;
  } catch {
    return undefined;
  }
}

/** Resolves a direct or deferred token with the Pushify public app key. */
export async function resolveAcquisitionLink(
  token: string,
  options: AcquisitionLinkClientOptions,
): Promise<PushifyAcquisitionLink> {
  if (!TOKEN.test(token)) throw new Error('Invalid Pushify acquisition-link token.');
  if (!options.publicApiKey) throw new Error('A Pushify public app key is required.');
  const base = options.apiBaseUrl ?? 'https://api.pushify.app';
  const endpoint = new URL('/sdk/v1/acquisition-links/resolve', base);
  if (endpoint.protocol !== 'https:') throw new Error('Pushify API URL must use HTTPS.');

  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${options.publicApiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      token,
      ...(options.appUserId ? { customer_id: options.appUserId } : {}),
    }),
  });
  if (!response.ok) {
    throw new Error(`Pushify acquisition-link resolution failed (HTTP ${response.status}).`);
  }
  const body = await response.text();
  if (body.length > 65536) throw new Error('Pushify response was too large.');
  const payload = JSON.parse(body) as { link?: Record<string, unknown> };
  const link = payload.link;
  if (!link || typeof link.id !== 'string' || typeof link.destination !== 'string') {
    throw new Error('Pushify returned an invalid acquisition-link response.');
  }
  return {
    object: 'acquisition_link_resolution',
    status: link.status === 'attributed' ? 'attributed' : 'resolved',
    link_id: link.id,
    name: typeof link.name === 'string' ? link.name : '',
    slug: typeof link.slug === 'string' ? link.slug : '',
    destination: link.destination,
    app_scheme: typeof link.app_scheme === 'string' ? link.app_scheme : '',
    campaign: link.campaign && typeof link.campaign === 'object'
      ? link.campaign as Record<string, string>
      : {},
    attributed: link.attributed === true,
  };
}
/** Reads the deferred token after your app has explained the iOS pasteboard prompt. */
export async function readDeferredAcquisitionToken(): Promise<string | undefined> {
  const token = await NativeModules.PushifyPurchases?.readDeferredToken?.();
  return typeof token === 'string' && token.startsWith('rdit_') && TOKEN.test(token)
    ? token
    : undefined;
}

/**
 * Small app-level facade: configure the public key once, then hand it URLs from
 * React Native Linking and ask it to resolve supported deferred handoffs.
 */
export class PushifyAcquisitionLinks {
  constructor(private readonly options: AcquisitionLinkClientOptions) {
    if (!options.publicApiKey.trim()) {
      throw new Error('A Pushify public app key is required.');
    }
    const base = new URL(options.apiBaseUrl ?? 'https://api.pushify.app');
    if (base.protocol !== 'https:') {
      throw new Error('Pushify API URL must use HTTPS.');
    }
  }

  /** Resolves a direct app URL, or returns undefined when it is not a Pushify link. */
  async handleUrl(
    url: string,
    appUserId = this.options.appUserId,
  ): Promise<PushifyAcquisitionLink | undefined> {
    const token = acquisitionTokenFromUrl(url);
    if (!token) return undefined;
    return resolveAcquisitionLink(token, { ...this.options, appUserId });
  }

  /** Reads and resolves a supported deferred handoff in one call. */
  async resolveDeferred(
    appUserId = this.options.appUserId,
  ): Promise<PushifyAcquisitionLink | undefined> {
    const token = await readDeferredAcquisitionToken();
    if (!token) return undefined;
    return resolveAcquisitionLink(token, { ...this.options, appUserId });
  }
}

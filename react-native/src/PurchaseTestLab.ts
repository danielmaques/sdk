import * as React from 'react';
import { Platform, Pressable, ScrollView, Share, Text, View } from 'react-native';
import { PushifyPurchases, type PushifyOfferings, type PushifyPurchaseResult } from './purchases';

type OperationName = 'offerings_refresh' | 'purchase' | 'restore' | 'entitlement_refresh';
type Operation = {
  scenario: OperationName;
  status: 'passed' | 'failed' | 'pending' | 'cancelled';
  outcome: string;
  occurred_at: string;
  correlation_ids: string[];
};

export type PushifyPurchaseTestLabProps = { purchases: PushifyPurchases };

/** Developer-operated StoreKit / Play Billing runner with a redacted, session-local report. */
export function PushifyPurchaseTestLab({ purchases }: PushifyPurchaseTestLabProps): React.ReactElement {
  const [offerings, setOfferings] = React.useState<PushifyOfferings | null>(null);
  const [operations, setOperations] = React.useState<Operation[]>([]);
  const [busy, setBusy] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const mounted = React.useRef(true);
  const runId = React.useRef(`${Date.now()}-${Math.random().toString(36).slice(2, 10)}`).current;

  React.useEffect(() => {
    mounted.current = true;
    purchases.enableDebugInspector(true);
    return () => { mounted.current = false; purchases.enableDebugInspector(false); };
  }, [purchases]);

  const correlationIds = React.useCallback(() => {
    try {
      const report = JSON.parse(purchases.debugExport() ?? '{}') as { events?: { correlation_id?: unknown }[] };
      return (report.events ?? []).map((event) => event.correlation_id)
        .filter((id): id is string => typeof id === 'string' && /^[0-9a-f-]{36}$/i.test(id)).slice(-20);
    } catch { return []; }
  }, [purchases]);

  const run = async (scenario: OperationName, action: () => Promise<string | PushifyPurchaseResult>) => {
    if (busy) return;
    setBusy(true); setError(null);
    let outcome = 'failed';
    let status: Operation['status'] = 'failed';
    try {
      const result = await action();
      outcome = typeof result === 'string' ? result : result.status;
      status = outcome === 'pending' || outcome === 'cancelled' ? outcome : 'passed';
      if (scenario === 'offerings_refresh' && typeof result !== 'string') status = 'failed';
    } catch {
      if (mounted.current) setError('The store or SDK operation failed. Details are omitted from this local report.');
    } finally {
      if (mounted.current) {
        setOperations((current: Operation[]) => [...current, {
          scenario, status, outcome, occurred_at: new Date().toISOString(), correlation_ids: correlationIds(),
        }].slice(-50));
        setBusy(false);
      }
    }
  };

  const refreshOfferings = () => run('offerings_refresh', async () => {
    const result = await purchases.offerings();
    if (mounted.current) setOfferings(result);
    return 'passed';
  });
  const restore = () => run('restore', async () => { await purchases.restorePurchases(); return 'passed'; });
  const refreshEntitlements = () => run('entitlement_refresh', async () => { await purchases.syncPurchases(); return 'passed'; });
  const purchase = (packageId: string) => run('purchase', () => purchases.purchase(packageId));
  const shareReport = async () => {
    try {
      await Share.share({ title: 'Pushify mobile test report', message: report });
    } catch {
      if (mounted.current) setError('The report could not be shared. Its contents remain on this screen.');
    }
  };
  const report = JSON.stringify({
    schema: 'pushify.mobile-test-run/v1', run_id: runId, platform: Platform.OS,
    environment: Platform.OS === 'ios' ? 'storekit_sandbox' : 'play_sandbox',
    app_environment: __DEV__ ? 'development' : 'production', operations,
  }, null, 2);

  const button = (label: string, onPress: () => void, key?: string) => React.createElement(Pressable, {
    key, accessibilityRole: 'button', accessibilityLabel: label, disabled: busy,
    onPress, style: { borderWidth: 1, borderColor: '#777', borderRadius: 8, paddingVertical: 10, paddingHorizontal: 12, opacity: busy ? 0.55 : 1 },
  }, React.createElement(Text, null, label));

  return React.createElement(View, { style: { borderWidth: 1, borderColor: '#888', borderRadius: 10, padding: 16, gap: 12 } },
    React.createElement(Text, { accessibilityRole: 'header', style: { fontSize: 20, fontWeight: '600' } }, 'Purchase Test Lab'),
    React.createElement(Text, null, 'Runs developer-operated store sandbox actions. This report stays in memory on this screen; nothing is uploaded automatically.'),
    React.createElement(View, { style: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 } },
      button('Refresh offerings', () => { void refreshOfferings(); }),
      button('Restore purchases', () => { void restore(); }),
      button('Refresh entitlements', () => { void refreshEntitlements(); })),
    busy ? React.createElement(Text, { accessibilityRole: 'progressbar' }, 'Waiting for the store…') : null,
    error ? React.createElement(Text, { accessibilityRole: 'alert' }, error) : null,
    React.createElement(ScrollView, { style: { maxHeight: 220 } },
      ...(offerings?.offerings.flatMap((offering: PushifyOfferings['offerings'][number]) => offering.packages.map((item: PushifyOfferings['offerings'][number]['packages'][number]) => button(
        `Buy ${item.product.display_name ?? item.product.product_id}`,
        () => { void purchase(item.id); }, item.id,
      ))) ?? [React.createElement(Text, { key: 'empty' }, 'No offerings loaded. Refresh offerings to begin.')]),
    ),
    React.createElement(Text, { accessibilityRole: 'header', style: { fontWeight: '600' } }, `Run report · ${operations.length} operation(s)`),
    React.createElement(ScrollView, { style: { maxHeight: 240 } },
      React.createElement(Text, { selectable: true, style: { fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace', fontSize: 12 } }, report)),
    button('Share run report', () => { void shareReport(); }),
    button('Clear session report', () => setOperations([])),
  );
}

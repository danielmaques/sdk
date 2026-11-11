import * as React from 'react';
import { Pressable, ScrollView, Share, Text, View } from 'react-native';
import { PushifyPurchases } from './purchases';

export type PushifyDebugInspectorProps = { purchases: PushifyPurchases };

/** Opt-in local inspector with a preview and copy-ready redacted JSON bundle. */
export function PushifyDebugInspector({ purchases }: PushifyDebugInspectorProps): React.ReactElement {
  const [report, setReport] = React.useState('Enable diagnostics to collect a local support bundle.');
  const [expanded, setExpanded] = React.useState(false);
  const mounted = React.useRef(true);
  React.useEffect(() => {
    mounted.current = true;
    purchases.enableDebugInspector(true);
    return () => { mounted.current = false; purchases.enableDebugInspector(false); };
  }, [purchases]);
  const refresh = async () => {
    await purchases.refreshDebugRetryQueueCount();
    if (mounted.current) setReport(purchases.debugExport() ?? 'No diagnostic report is available.');
  };
  const shareReport = async () => {
    try {
      await Share.share({ title: 'Pushify SDK diagnostics', message: report });
    } catch {
      if (mounted.current) setReport('The report could not be shared. Refresh to preview it again.');
    }
  };
  return React.createElement(View, { style: { borderWidth: 1, borderColor: '#888', borderRadius: 8, padding: 16, gap: 8 } },
    React.createElement(Pressable, { accessibilityRole: 'button', onPress: () => { setExpanded((value) => !value); refresh(); } },
      React.createElement(Text, { style: { fontSize: 18, fontWeight: '600' } }, expanded ? 'Hide Pushify diagnostics' : 'Show Pushify diagnostics')),
    expanded ? React.createElement(React.Fragment, null,
      React.createElement(Text, null, 'Stored on this device. Nothing is uploaded automatically.'),
      React.createElement(Pressable, { accessibilityRole: 'button', onPress: refresh }, React.createElement(Text, null, 'Refresh')),
      React.createElement(Pressable, { accessibilityRole: 'button', accessibilityLabel: 'Share redacted diagnostic report', onPress: () => { void shareReport(); } }, React.createElement(Text, null, 'Share support report')),
      React.createElement(ScrollView, { style: { maxHeight: 280 } },
        React.createElement(Text, { selectable: true, style: { fontFamily: 'monospace', fontSize: 12 } }, report))) : null);
}

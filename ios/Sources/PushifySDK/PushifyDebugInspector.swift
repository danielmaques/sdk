import SwiftUI
import UIKit

/// An opt-in local inspector that previews and copies a redacted SDK support bundle.
@MainActor
public struct PushifyDebugInspector: View {
    private let purchases: PushifyPurchases
    @State private var report = "Enable diagnostics to collect a local support bundle."
    @State private var copied = false

    public init(purchases: PushifyPurchases) { self.purchases = purchases }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pushify diagnostics").font(.headline)
                Spacer()
                Button("Refresh") { Task { await refresh() } }
                Button(copied ? "Copied" : "Copy") { UIPasteboard.general.string = report; copied = true }
                    .disabled(report.hasPrefix("Enable diagnostics"))
            }
            Text("Stored on this device. Nothing is uploaded automatically.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(report).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
        }
        .padding()
        .task { await purchases.enableDebugInspector(true); await refresh() }
        .onDisappear { Task { await purchases.enableDebugInspector(false) } }
    }

    private func refresh() async {
        _ = await purchases.debugRetryQueueCount()
        guard let data = await purchases.debugExport(), let value = String(data: data, encoding: .utf8) else { return }
        report = value
        copied = false
    }
}

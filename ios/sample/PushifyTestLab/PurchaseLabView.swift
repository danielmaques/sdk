// Pushify: open-source, self-hostable purchase infrastructure with a RevenueCat SDK-compatible API.
// This file: presents native StoreKit sandbox actions and a redacted session report.
// Docs: https://pushify.app/docs/sdks/ios   Migrate from RevenueCat: https://pushify.app/docs/migrate
import SwiftUI
import UIKit

struct PurchaseLabView: View {
    @ObservedObject var model: PurchaseLabModel
    @State private var showingShareSheet = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Uses this device's StoreKit sandbox account. Purchases are developer-operated; the app cannot create App Store transactions remotely.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(model.status).font(.callout).accessibilityIdentifier("purchase-lab-status")
                    Button("Refresh offerings") { Task { await model.refreshOfferings() } }
                        .buttonStyle(.borderedProminent).disabled(!model.isReady)
                    Button("Restore purchases") { Task { await model.restore() } }
                        .buttonStyle(.bordered).disabled(!model.isReady)
                    Button("Refresh entitlements") { Task { await model.sync() } }
                        .buttonStyle(.bordered).disabled(!model.isReady)

                    if let offerings = model.offerings {
                        ForEach(offerings.offerings, id: \.id) { offering in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(offering.description.isEmpty ? offering.id : offering.description)
                                    .font(.headline)
                                ForEach(offering.packages, id: \.id) { package in
                                    Button {
                                        Task { await model.purchase(packageID: package.id) }
                                    } label: {
                                        HStack {
                                            Text(package.product.displayName ?? package.product.productId)
                                            Spacer()
                                            Text(package.product.localizedPrice ?? "Buy")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(!model.isReady)
                                }
                            }
                        }
                    }

                    HStack {
                        Text("Redacted run report").font(.headline)
                        Spacer()
                        Button { showingShareSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                    Text(model.reportText).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Purchase Test Lab")
            .sheet(isPresented: $showingShareSheet) { ActivitySheet(items: [model.reportText]) }
        }
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

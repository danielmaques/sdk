// Pushify: open-source, self-hostable purchase infrastructure with a RevenueCat SDK-compatible API.
// This file: runs developer-operated StoreKit scenarios and saves a redacted local session report.
// Docs: https://pushify.app/docs/sdks/ios   Migrate from RevenueCat: https://pushify.app/docs/migrate
import Foundation
import Combine
import PushifySDK

@MainActor
final class PurchaseLabModel: ObservableObject {
    struct Operation: Codable, Identifiable {
        let id: UUID
        let scenario: String
        let status: String
        let outcome: String
        let occurredAt: Date
        let correlationIDs: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case scenario
            case status
            case outcome
            case occurredAt = "occurred_at"
            case correlationIDs = "correlation_ids"
        }
    }

    struct Report: Codable {
        let schema: String
        let runID: UUID
        let environment: String
        let platform: String
        var operations: [Operation]

        enum CodingKeys: String, CodingKey {
            case schema
            case runID = "run_id"
            case environment
            case platform
            case operations
        }
    }

    @Published private(set) var status = "Starting StoreKit Test Lab…"
    @Published private(set) var offerings: PushifyOfferings?
    @Published private(set) var report: Report
    @Published private(set) var reportText = ""
    @Published private(set) var isReady = false

    private var purchases: PushifyPurchases?
    private var pendingRunnerURL: URL?
    private let reportURL: URL

    init() {
        reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pushify-test-run.json")
        if let data = try? Data(contentsOf: reportURL), let saved = try? JSONDecoder.pushify.decode(Report.self, from: data) {
            report = saved
        } else {
            report = Report(schema: "pushify.mobile-test-run/v1", runID: UUID(), environment: "storekit_sandbox", platform: "ios", operations: [])
        }
        refreshReportText()
    }

    func configure() async {
        guard purchases == nil else { return }
        let key = ProcessInfo.processInfo.environment["PUSHIFY_PUBLIC_APP_KEY"]
            ?? Bundle.main.object(forInfoDictionaryKey: "PUSHIFY_PUBLIC_APP_KEY") as? String
            ?? ""
        guard !key.isEmpty, !key.contains("$(") else {
            status = "Set PUSHIFY_PUBLIC_APP_KEY to a public key for a sandbox app in the Run scheme environment."
            return
        }
        do {
            let apiURLString = Bundle.main.object(forInfoDictionaryKey: "PUSHIFY_API_BASE_URL") as? String
            let apiURL = URL(string: apiURLString ?? "https://api.pushify.app") ?? URL(string: "https://api.pushify.app")!
            let client = try await PushifyPurchases.configure(apiKey: key, apiBaseURL: apiURL)
            await client.enableDebugInspector(true)
            purchases = client
            isReady = true
            status = "Connected. Choose a package or run restore and entitlement refresh."
            await refreshOfferings()
            if let pendingRunnerURL { self.pendingRunnerURL = nil; await run(url: pendingRunnerURL) }
        } catch {
            status = "SDK setup failed: \(error.localizedDescription)"
            await append(scenario: "configure", outcome: "failed")
        }
    }

    func refreshOfferings() async {
        guard let purchases else { status = "Wait for SDK setup to finish first."; return }
        status = "Refreshing offerings…"
        do {
            offerings = try await purchases.offerings()
            status = "Offerings loaded from Pushify."
            await append(scenario: "offerings_refresh", outcome: "passed")
        } catch {
            status = "Offerings failed: \(error.localizedDescription)"
            await append(scenario: "offerings_refresh", outcome: "failed")
        }
    }

    func purchase(packageID: String) async {
        guard let purchases else { status = "Wait for SDK setup to finish first."; return }
        status = "Waiting for the StoreKit purchase sheet…"
        do {
            let result = try await purchases.purchase(packageID: packageID)
            switch result {
            case .purchased:
                status = "Purchase completed."
                await append(scenario: "purchase", outcome: "purchased")
            case .pending:
                status = "Purchase is pending approval."
                await append(scenario: "purchase", outcome: "pending")
            case .cancelled:
                status = "Purchase was cancelled."
                await append(scenario: "purchase", outcome: "cancelled")
            }
        } catch {
            status = "Purchase failed: \(error.localizedDescription)"
            await append(scenario: "purchase", outcome: "failed")
        }
    }

    func restore() async { await runAction("restore") { try await $0.restorePurchases() } }
    func sync() async { await runAction("entitlement_refresh") { try await $0.syncPurchases() } }

    func acceptRunnerURL(_ url: URL) {
        guard url.scheme == "pushify-testlab", url.host == "run" else { return }
        guard isReady else { pendingRunnerURL = url; return }
        Task { await run(url: url) }
    }

    func exportReport() -> URL? {
        do {
            try JSONEncoder.pushify.encode(report).write(to: reportURL, options: .atomic)
            refreshReportText()
            return reportURL
        } catch {
            status = "Could not save the local run report."
            return nil
        }
    }

    private func runAction(_ name: String, action: (PushifyPurchases) async throws -> PushifyCustomerSnapshot) async {
        guard let purchases else { status = "Wait for SDK setup to finish first."; return }
        status = "Running \(name)…"
        do {
            _ = try await action(purchases)
            status = "\(name) completed."
            await append(scenario: name, outcome: "passed")
        } catch {
            status = "\(name) failed: \(error.localizedDescription)"
            await append(scenario: name, outcome: "failed")
        }
    }

    private func run(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scenario = components.queryItems?.first(where: { $0.name == "scenario" })?.value else { return }
        switch scenario {
        case "offerings_refresh": await refreshOfferings()
        case "restore": await restore()
        case "entitlement_refresh": await sync()
        case "purchase":
            guard let packageID = components.queryItems?.first(where: { $0.name == "package_id" })?.value else {
                await append(scenario: "purchase", outcome: "failed")
                return
            }
            await purchase(packageID: packageID)
        default: await append(scenario: "unsupported", outcome: "unsupported")
        }
    }

    private func append(scenario: String, outcome: String) async {
        report.operations.append(Operation(
            id: UUID(), scenario: scenario,
            status: ["passed", "purchased"].contains(outcome) ? "passed" : outcome,
            outcome: outcome, occurredAt: Date(), correlationIDs: await diagnosticCorrelationIDs()
        ))
        _ = exportReport()
    }

    private func diagnosticCorrelationIDs() async -> [String] {
        guard let purchases, let data = await purchases.debugExport(),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = value["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { $0["correlation_id"] as? String }
    }

    private func refreshReportText() {
        let encoder = JSONEncoder.pushify
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report), let value = String(data: data, encoding: .utf8) { reportText = value }
    }
}

private extension JSONEncoder {
    static var pushify: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var pushify: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

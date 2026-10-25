import Foundation
import StoreKit

private struct PushifyErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String; let message: String; let retryable: Bool }
    let error: Detail
}

public struct PushifyCustomerSnapshot: Decodable, Sendable {
    public struct Customer: Decodable, Sendable {
        public let id: String
        public let originalId: String
        public let firstSeenAt: Date
        public let attributes: [String: Attribute]
    }

    public struct Attribute: Decodable, Sendable {
        public let value: String?
        public let updatedAtMs: Int64?
    }

    public struct Entitlement: Decodable, Sendable {
        public let key: String
        public let expiresAt: Date?
        public let productId: String
    }

    public struct VirtualCurrency: Decodable, Sendable {
        public let code: String
        public let name: String
        public let description: String?
        public let balance: Int
    }

    public struct Transaction: Decodable, Sendable {
        public let productId: String
        public let store: String
        public let purchasedAt: Date
        public let transactionId: String
    }

    public let created: Bool?
    public let identityChanged: Bool?
    public let customer: Customer
    public let entitlements: Entitlements
    public struct Entitlements: Decodable, Sendable { public let active: [Entitlement]; public let available: [String] }
    public let transactions: [Transaction]
    public let virtualCurrencies: [VirtualCurrency]
}

public struct PushifyOfferings: Decodable, Sendable {
    public struct Offering: Decodable, Sendable {
        public struct Package: Decodable, Sendable {
            public struct StoreProduct: Decodable, Sendable {
                public let productId: String
                public let planId: String?
            }
            public let id: String
            public let product: StoreProduct
        }
        public let id: String
        public let description: String
        public let packages: [Package]
    }
    public let currentOfferingId: String?
    public let offerings: [Offering]
}

public enum PushifyPurchaseResult: Sendable {
    case purchased(PushifyCustomerSnapshot)
    case pending
    case cancelled
}

public enum PushifyError: Error, Sendable {
    case invalidConfiguration
    case invalidResponse
    case server(status: Int, code: String, message: String, retryable: Bool)
    case unverifiedTransaction
    case productUnavailable(String)
}

/// First-party StoreKit 2 client for the Pushify SDK API.
public actor PushifyPurchases {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let identityKey: String
    private var customerID: String?
    private var cachedSnapshot: PushifyCustomerSnapshot?
    private var updatesTask: Task<Void, Never>?

    public init(apiKey: String, apiBaseURL: URL = URL(string: "https://api.pushify.app")!, session: URLSession = .shared, defaults: UserDefaults = .standard) throws {
        guard !apiKey.isEmpty, apiBaseURL.scheme == "https", apiBaseURL.host != nil else { throw PushifyError.invalidConfiguration }
        self.apiKey = apiKey
        self.baseURL = apiBaseURL
        self.session = session
        self.defaults = defaults
        self.identityKey = "app.pushify.customer.\(Bundle.main.bundleIdentifier ?? "default")"
        self.customerID = defaults.string(forKey: identityKey)
    }

    /// Starts the SDK, restores unfinished StoreKit transactions, and returns the latest server-verified customer state.
    public static func configure(apiKey: String, apiBaseURL: URL = URL(string: "https://api.pushify.app")!) async throws -> PushifyPurchases {
        let purchases = try PushifyPurchases(apiKey: apiKey, apiBaseURL: apiBaseURL)
        _ = try await purchases.customerInfo()
        try await purchases.syncUnfinishedTransactions()
        await purchases.listenForTransactionUpdates()
        return purchases
    }

    public func customerInfo() async throws -> PushifyCustomerSnapshot {
        let id = ensureCustomerID()
        let snapshot: PushifyCustomerSnapshot = try await request(path: "/sdk/v1/customers/bootstrap", method: "POST", body: ["customer_id": id])
        cachedSnapshot = snapshot
        return snapshot
    }

    public func cachedCustomerInfo() -> PushifyCustomerSnapshot? { cachedSnapshot }

    public func offerings() async throws -> PushifyOfferings {
        try await request(path: "/sdk/v1/offerings", method: "GET")
    }

    public func identify(customerID newID: String) async throws -> PushifyCustomerSnapshot {
        guard !newID.isEmpty, newID.count <= 100 else { throw PushifyError.invalidConfiguration }
        let oldID = ensureCustomerID()
        let snapshot: PushifyCustomerSnapshot = try await request(path: "/sdk/v1/customers/identify", method: "POST", body: ["current_customer_id": oldID, "new_customer_id": newID])
        customerID = newID
        defaults.set(newID, forKey: identityKey)
        cachedSnapshot = snapshot
        return snapshot
    }

    public func setAttributes(_ attributes: [String: Any]) async throws -> PushifyCustomerSnapshot.Customer {
        let id = ensureCustomerID()
        var pathCharacters = CharacterSet.urlPathAllowed
        pathCharacters.remove(charactersIn: "/?#")
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? id
        let updated: PushifyCustomerSnapshot.Customer = try await request(path: "/sdk/v1/customers/\(encodedID)/attributes", method: "PATCH", body: ["attributes": attributes])
        return updated
    }

    /// Uses StoreKit's native purchase sheet and grants access only after Pushify verifies the signed transaction.
    public func purchase(packageID: String) async throws -> PushifyPurchaseResult {
        let catalog = try await offerings()
        guard let package = catalog.offerings.flatMap(\.packages).first(where: { $0.id == packageID }) else { throw PushifyError.productUnavailable(packageID) }
        let products = try await Product.products(for: [package.product.productId])
        guard let product = products.first else { throw PushifyError.productUnavailable(package.product.productId) }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw PushifyError.unverifiedTransaction }
            do {
                let snapshot = try await sync(transaction, proof: verification.jwsRepresentation)
                await transaction.finish()
                cachedSnapshot = snapshot
                return .purchased(snapshot)
            } catch {
                // StoreKit keeps the transaction unfinished. Launch/updates retry it without losing the proof.
                throw error
            }
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            throw PushifyError.invalidResponse
        }
    }

    public func restorePurchases() async throws -> PushifyCustomerSnapshot {
        try await AppStore.sync()
        try await syncUnfinishedTransactions()
        var latest = try await customerInfo()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            latest = try await sync(transaction, proof: result.jwsRepresentation)
            await transaction.finish()
        }
        cachedSnapshot = latest
        return latest
    }

    private func syncUnfinishedTransactions() async throws {
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else { continue }
            let snapshot = try await sync(transaction, proof: result.jwsRepresentation)
            await transaction.finish()
            cachedSnapshot = snapshot
        }
    }

    private func listenForTransactionUpdates() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.processTransactionUpdate(update)
            }
        }
    }

    private func processTransactionUpdate(_ update: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = update else { return }
        do {
            let snapshot = try await sync(transaction, proof: update.jwsRepresentation)
            await transaction.finish()
            cachedSnapshot = snapshot
        } catch {
            // Keep the StoreKit transaction unfinished; the next launch/update retries server synchronization.
        }
    }

    private func sync(_ transaction: StoreKit.Transaction, proof: String) async throws -> PushifyCustomerSnapshot {
        let body: [String: Any] = ["customer_id": ensureCustomerID(), "product_id": transaction.productID,
                                   "transaction_id": String(transaction.id), "proof": proof]
        let snapshot: PushifyCustomerSnapshot = try await request(path: "/sdk/v1/transactions/sync", method: "POST", body: body)
        return snapshot
    }

    private func ensureCustomerID() -> String {
        if let customerID { return customerID }
        let id = "$PushifyAnonymousID:\(UUID().uuidString.lowercased())"
        customerID = id
        defaults.set(id, forKey: identityKey)
        return id
    }

    private func request<T: Decodable>(path: String, method: String, body: Any? = nil) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw PushifyError.invalidConfiguration }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed, .sortedKeys])
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PushifyError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? JSONDecoder().decode(PushifyErrorEnvelope.self, from: data).error {
                throw PushifyError.server(status: response.statusCode, code: error.code, message: error.message, retryable: error.retryable)
            }
            throw PushifyError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

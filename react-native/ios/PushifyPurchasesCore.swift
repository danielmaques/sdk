import Foundation
import StoreKit
import CryptoKit
import Security

private struct PushifyErrorEnvelope: Decodable {
    struct Detail: Decodable { let code: String; let message: String; let retryable: Bool }
    let error: Detail
}

public struct PushifyCustomerSnapshot: Codable, Sendable {
    public struct Customer: Codable, Sendable {
        public let id: String
        public let originalId: String
        public let firstSeenAt: Date
        public let attributes: [String: Attribute]
    }

    public struct Attribute: Codable, Sendable {
        public let value: String?
        public let updatedAtMs: Int64?
    }

    public struct Entitlement: Codable, Sendable {
        public let key: String
        public let expiresAt: Date?
        public let productId: String
    }

    public struct VirtualCurrency: Codable, Sendable {
        public let code: String
        public let name: String
        public let description: String?
        public let balance: Int
    }

    public struct Transaction: Codable, Sendable {
        public let productId: String
        public let store: String
        public let purchasedAt: Date
        public let transactionId: String
    }

    public let created: Bool?
    public let identityChanged: Bool?
    public let customer: Customer
    public let entitlements: Entitlements
    public struct Entitlements: Codable, Sendable { public let active: [Entitlement]; public let available: [String] }
    public let transactions: [Transaction]
    public let virtualCurrencies: [VirtualCurrency]
}

public struct PushifyCurrencySpendResult: Codable, Sendable {
    public let virtualCurrencies: [PushifyCustomerSnapshot.VirtualCurrency]
}

private struct PushifyEventResponse: Decodable { let accepted: Int }

public struct PushifyOfferings: Codable, Sendable {
    public struct Offering: Codable, Sendable {
        public struct Package: Codable, Sendable {
            public struct StoreProduct: Codable, Sendable {
                public let productId: String
                public let planId: String?
                public let type: String?
                public let displayName: String?
                public let localizedPrice: String?
                public let priceAmount: String?
                public let currencyCode: String?
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
    private var observers: [UUID: AsyncStream<PushifyCustomerSnapshot>.Continuation] = [:]
    private let snapshotKey: String

    public init(apiKey: String, apiBaseURL: URL = URL(string: "https://api.pushify.app")!, session: URLSession = .shared, defaults: UserDefaults = .standard) throws {
        guard !apiKey.isEmpty, apiBaseURL.scheme == "https", apiBaseURL.host != nil else { throw PushifyError.invalidConfiguration }
        self.apiKey = apiKey
        self.baseURL = apiBaseURL
        self.session = session
        self.defaults = defaults
        self.identityKey = "app.pushify.customer.\(Bundle.main.bundleIdentifier ?? "default")"
        self.snapshotKey = "app.pushify.snapshot.\(Bundle.main.bundleIdentifier ?? "default")"
        self.customerID = defaults.string(forKey: identityKey)
        if let encrypted = defaults.data(forKey: snapshotKey),
           let data = try? AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: Self.cacheEncryptionKey(service: identityKey)) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.cachedSnapshot = try? decoder.decode(PushifyCustomerSnapshot.self, from: data)
        }
    }

    /// Creates a client and starts transaction reconciliation. Network failure during startup leaves the client
    /// usable with its last verified cache; calls that require fresh server data still report their errors.
    public static func configure(apiKey: String, apiBaseURL: URL = URL(string: "https://api.pushify.app")!) async throws -> PushifyPurchases {
        let purchases = try PushifyPurchases(apiKey: apiKey, apiBaseURL: apiBaseURL)
        await purchases.listenForTransactionUpdates()
        Task {
            _ = try? await purchases.customerInfo()
            try? await purchases.syncUnfinishedTransactions()
        }
        return purchases
    }

    public func customerInfo() async throws -> PushifyCustomerSnapshot {
        let id = ensureCustomerID()
        let snapshot: PushifyCustomerSnapshot = try await request(path: "/sdk/v1/customers/bootstrap", method: "POST", body: ["customer_id": id])
        save(snapshot)
        return snapshot
    }

    public func cachedCustomerInfo() -> PushifyCustomerSnapshot? { cachedSnapshot }

    public func offerings() async throws -> PushifyOfferings {
        let catalog: PushifyOfferings = try await request(path: "/sdk/v1/offerings", method: "GET")
        let identifiers = Array(Set(catalog.offerings.flatMap(\.packages).map(\.product.productId)))
        let storeProducts = try await Product.products(for: identifiers)
        let byIdentifier = Dictionary(uniqueKeysWithValues: storeProducts.map { ($0.id, $0) })
        return PushifyOfferings(
            currentOfferingId: catalog.currentOfferingId,
            offerings: catalog.offerings.map { offering in
                PushifyOfferings.Offering(
                    id: offering.id,
                    description: offering.description,
                    packages: offering.packages.map { package in
                        let native = byIdentifier[package.product.productId]
                        return PushifyOfferings.Offering.Package(
                            id: package.id,
                            product: PushifyOfferings.Offering.Package.StoreProduct(
                                productId: package.product.productId,
                                planId: package.product.planId,
                                type: package.product.type,
                                displayName: native?.displayName,
                                localizedPrice: native?.displayPrice,
                                priceAmount: native.map { NSDecimalNumber(decimal: $0.price).stringValue },
                                currencyCode: native?.priceFormatStyle.currencyCode
                            )
                        )
                    }
                )
            }
        )
    }

    public func identify(customerID newID: String) async throws -> PushifyCustomerSnapshot {
        guard !newID.isEmpty, newID.count <= 100 else { throw PushifyError.invalidConfiguration }
        let oldID = ensureCustomerID()
        let snapshot: PushifyCustomerSnapshot = try await request(path: "/sdk/v1/customers/identify", method: "POST", body: ["current_customer_id": oldID, "new_customer_id": newID])
        customerID = newID
        defaults.set(newID, forKey: identityKey)
        save(snapshot)
        return snapshot
    }

    /// Starts a fresh anonymous identity. The previous customer's purchases remain attached to the previous ID.
    public func logOut() async throws -> PushifyCustomerSnapshot {
        customerID = nil
        defaults.removeObject(forKey: identityKey)
        cachedSnapshot = nil
        defaults.removeObject(forKey: snapshotKey)
        return try await customerInfo()
    }

    /// Emits the latest server-verified snapshot after a purchase, restore, login, or successful refresh.
    public func customerInfoUpdates() -> AsyncStream<PushifyCustomerSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            if let cachedSnapshot { continuation.yield(cachedSnapshot) }
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeObserver(id) }
            }
        }
    }

    public func setAttributes(_ attributes: [String: Any]) async throws -> PushifyCustomerSnapshot.Customer {
        let id = ensureCustomerID()
        var pathCharacters = CharacterSet.urlPathAllowed
        pathCharacters.remove(charactersIn: "/?#")
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? id
        let updated: PushifyCustomerSnapshot.Customer = try await request(path: "/sdk/v1/customers/\(encodedID)/attributes", method: "PATCH", body: ["attributes": attributes])
        _ = try await customerInfo()
        return updated
    }

    /// Reconciles unfinished transactions and current non-consumable/subscription entitlements without prompting for sign-in.
    public func syncPurchases() async throws -> PushifyCustomerSnapshot {
        try await syncUnfinishedTransactions()
        var latest = try await customerInfo()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            latest = try await sync(transaction, proof: result.jwsRepresentation)
            save(latest)
        }
        return latest
    }

    /// Sends an app event to Pushify. The event identifier is generated once for this request and can be supplied
    /// by the caller when it needs to retry the same logical event after a transient network failure.
    @discardableResult
    public func logEvent(_ name: String, properties: [String: Any] = [:], eventID: String = UUID().uuidString) async throws -> Int {
        guard !name.isEmpty, name.count <= 64, !eventID.isEmpty, eventID.count <= 64 else { throw PushifyError.invalidConfiguration }
        var event = properties
        event["id"] = eventID
        event["type"] = name
        event["customer_id"] = ensureCustomerID()
        event["occurred_at_ms"] = Int64(Date().timeIntervalSince1970 * 1_000)
        let response: PushifyEventResponse = try await request(path: "/sdk/v1/events", method: "POST", body: ["events": [event]])
        return response.accepted
    }

    /// Atomically spends configured virtual currencies using a stable idempotency key.
    public func spendVirtualCurrency(_ adjustments: [String: Int], idempotencyKey: String, reference: String? = nil) async throws -> PushifyCurrencySpendResult {
        guard !adjustments.isEmpty, adjustments.allSatisfy({ !$0.key.isEmpty && $0.value > 0 }),
              !idempotencyKey.isEmpty, idempotencyKey.count <= 200 else { throw PushifyError.invalidConfiguration }
        let id = ensureCustomerID()
        var pathCharacters = CharacterSet.urlPathAllowed
        pathCharacters.remove(charactersIn: "/?#")
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: pathCharacters) ?? id
        let response: PushifyCurrencySpendResult = try await request(
            path: "/sdk/v1/customers/\(encodedID)/virtual-currencies/spends", method: "POST",
            body: ["adjustments": adjustments, "reference": reference as Any? ?? NSNull()],
            headers: ["Idempotency-Key": idempotencyKey]
        )
        return response
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
                save(snapshot)
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
        return try await syncPurchases()
    }

    private func syncUnfinishedTransactions() async throws {
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else { continue }
            let snapshot = try await sync(transaction, proof: result.jwsRepresentation)
            await transaction.finish()
            save(snapshot)
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
            save(snapshot)
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

    private func save(_ snapshot: PushifyCustomerSnapshot) {
        cachedSnapshot = snapshot
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot),
           let encrypted = try? AES.GCM.seal(data, using: Self.cacheEncryptionKey(service: identityKey)).combined {
            defaults.set(encrypted, forKey: snapshotKey)
        }
        for observer in observers.values { observer.yield(snapshot) }
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private static func cacheEncryptionKey(service: String) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.pushify.cache",
            kSecAttrAccount as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound else { throw PushifyError.invalidConfiguration }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.pushify.cache",
            kSecAttrAccount as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        if insertStatus == errSecDuplicateItem { return try cacheEncryptionKey(service: service) }
        guard insertStatus == errSecSuccess else { throw PushifyError.invalidConfiguration }
        return SymmetricKey(data: data)
    }

    private func request<T: Decodable>(path: String, method: String, body: Any? = nil, headers: [String: String] = [:]) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw PushifyError.invalidConfiguration }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
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

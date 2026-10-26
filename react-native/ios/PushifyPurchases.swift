import Foundation
import React
import StoreKit
import UIKit

@objc(PushifyPurchases)
final class PushifyPurchasesModule: RCTEventEmitter {
    private var purchases: PushifyPurchases?
    private var updatesTask: Task<Void, Never>?

    @objc override static func requiresMainQueueSetup() -> Bool { true }
    override func supportedEvents() -> [String]! { ["customerInfoUpdated"] }

    @objc func configure(_ options: NSDictionary,
                         resolver resolve: @escaping RCTPromiseResolveBlock,
                         rejecter reject: @escaping RCTPromiseRejectBlock) {
        let key = (options["publicApiKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { reject("invalid_configuration", "A Pushify public app key is required.", nil); return }
        let baseURL = (options["apiBaseUrl"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://api.pushify.app")!
        Task {
            do {
                let client = try await PushifyPurchases.configure(apiKey: key, apiBaseURL: baseURL)
                purchases = client
                if let snapshot = await client.cachedCustomerInfo() { resolve(try encode(snapshot)) }
                else { resolve(NSNull()) }
            } catch { self.rejectError(reject, error) }
        }
    }

    @objc func readDeferredToken(_ resolve: @escaping RCTPromiseResolveBlock,
                                 rejecter reject: @escaping RCTPromiseRejectBlock) {
        // Call only after the app has explained the pasteboard handoff to the user.
        guard let token = UIPasteboard.general.string,
              token.range(of: #"^rdit_[A-Za-z0-9_-]{30,80}$"#, options: .regularExpression) != nil else {
            resolve(nil)
            return
        }
        UIPasteboard.general.string = nil
        resolve(token)
    }

    @objc func customerInfo(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { try self.encode(try await $0.customerInfo()) }
    }

    @objc func cachedCustomerInfo(_ resolve: @escaping RCTPromiseResolveBlock,
                                  rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let purchases else { resolve(nil); return }
        Task { if let value = await purchases.cachedCustomerInfo() { resolve(try self.encode(value)) } else { resolve(nil) } }
    }

    @objc func offerings(_ placement: String?, resolver resolve: @escaping RCTPromiseResolveBlock,
                         rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { try self.encode(try await $0.offerings(placement: placement)) }
    }

    @objc func customerCenter(_ locale: String?, resolver resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { try self.encode(try await $0.customerCenter(locale: locale)) }
    }

    @objc func createSupportTicket(_ email: String, message: String,
                                   resolver resolve: @escaping RCTPromiseResolveBlock,
                                   rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { client in try await client.createSupportTicket(email: email, message: message); return ["accepted": true] }
    }

    @objc func identify(_ customerID: String,
                        resolver resolve: @escaping RCTPromiseResolveBlock,
                        rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { try self.encode(try await $0.identify(customerID: customerID)) }
    }

    @objc func logOut(_ resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { try self.encode(try await $0.logOut()) }
    }

    @objc func setAttributes(_ attributes: NSDictionary,
                             resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
        let values = attributes as? [String: Any] ?? [:]
        perform(resolve, reject) { client in
            _ = try await client.setAttributes(values)
            return try self.encode(try await client.customerInfo())
        }
    }

    @objc func restorePurchases(_ resolve: @escaping RCTPromiseResolveBlock,
                                rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { try self.encode(try await $0.restorePurchases()) }
    }

    @objc func syncPurchases(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { try self.encode(try await $0.syncPurchases()) }
    }

    @objc func purchase(_ packageID: String,
                        resolver resolve: @escaping RCTPromiseResolveBlock,
                        rejecter reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { client in
            switch try await client.purchase(packageID: packageID) {
            case .purchased(let snapshot): return ["status": "purchased", "customerInfo": try self.encode(snapshot)]
            case .pending: return ["status": "pending"]
            case .cancelled: return ["status": "cancelled"]
            }
        }
    }

    @objc func logEvent(_ name: String, properties: NSDictionary, eventID: String,
                        resolver resolve: @escaping RCTPromiseResolveBlock,
                        rejecter reject: @escaping RCTPromiseRejectBlock) {
        let values = properties as? [String: Any] ?? [:]
        perform(resolve, reject) { client in try await client.logEvent(name, properties: values, eventID: eventID) }
    }

    @objc func spendVirtualCurrency(_ adjustments: NSDictionary, idempotencyKey: String, reference: String?,
                                    resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter reject: @escaping RCTPromiseRejectBlock) {
        let values = adjustments as? [String: Int] ?? [:]
        perform(resolve, reject) { try self.encode(try await $0.spendVirtualCurrency(values, idempotencyKey: idempotencyKey, reference: reference)) }
    }

    override func startObserving() {
        guard let purchases else { return }
        updatesTask?.cancel()
        updatesTask = Task {
            for await snapshot in await purchases.customerInfoUpdates() {
                guard !Task.isCancelled else { return }
                if let value = try? self.encode(snapshot) { self.sendEvent(withName: "customerInfoUpdated", body: value) }
            }
        }
    }

    override func stopObserving() { updatesTask?.cancel(); updatesTask = nil }

    private func perform(_ resolve: @escaping RCTPromiseResolveBlock,
                         _ reject: @escaping RCTPromiseRejectBlock,
                         operation: @escaping (PushifyPurchases) async throws -> Any) {
        guard let purchases else { reject("not_configured", "Call configure before using Pushify purchases.", nil); return }
        Task { do { resolve(try await operation(purchases)) } catch { self.rejectError(reject, error) } }
    }

    private func rejectError(_ reject: @escaping RCTPromiseRejectBlock, _ error: Error) {
        if let apiError = error as? PushifyError,
           case let .server(status, code, message, retryable) = apiError {
            let details = NSError(domain: "app.pushify.sdk", code: status, userInfo: ["retryable": retryable])
            reject(code, message, details)
        } else {
            reject("pushify_error", String(describing: error), error)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }
}

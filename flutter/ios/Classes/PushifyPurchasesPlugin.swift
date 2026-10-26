import Flutter
import Foundation
import StoreKit
import UIKit

public final class PushifyPurchasesPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private static let methodChannelName = "app.pushify/purchases"
    private static let eventChannelName = "app.pushify/customer-info"
    private var purchases: PushifyPurchases?
    private var updatesTask: Task<Void, Never>?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PushifyPurchasesPlugin()
        let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methods)
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: registrar.messenger())
        events.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "configure":
            guard let key = args["publicApiKey"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                result(FlutterError(code: "invalid_configuration", message: "A Pushify public app key is required.", details: nil))
                return
            }
            let baseURL = (args["apiBaseUrl"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://api.pushify.app")!
            Task {
                do {
                    let client = try await PushifyPurchases.configure(apiKey: key, apiBaseURL: baseURL)
                    purchases = client
                    if let snapshot = await client.cachedCustomerInfo() { finish(result, try encode(snapshot)) }
                    else { finish(result, NSNull()) }
                } catch { self.finishError(result, error) }
            }
        case "readDeferredToken":
            // Call only after the app has explained the pasteboard handoff to the user.
            guard let value = UIPasteboard.general.string,
                  value.range(of: #"^rdit_[A-Za-z0-9_-]{30,80}$"#, options: .regularExpression) != nil else {
                result(nil)
                return
            }
            UIPasteboard.general.string = nil
            result(value)
        case "customerInfo":
            withClient(result) { client in self.finish(result, try await self.encode(try await client.customerInfo())) }
        case "cachedCustomerInfo":
            guard let client = purchases else { result(nil); return }
            Task { if let value = await client.cachedCustomerInfo() { self.finish(result, try self.encode(value)) } else { self.finish(result, NSNull()) } }
        case "offerings":
            withClient(result) { client in self.finish(result, try await self.encode(try await client.offerings(placement: args["placement"] as? String))) }
        case "customerCenter":
            withClient(result) { client in
                let value = try await client.customerCenter(locale: args["locale"] as? String)
                self.finish(result, try self.encode(value))
            }
        case "createSupportTicket":
            let email = args["email"] as? String ?? ""
            let message = args["message"] as? String ?? ""
            withClient(result) { client in try await client.createSupportTicket(email: email, message: message); self.finish(result, ["accepted": true]) }
        case "identify":
            guard let customerID = args["customerId"] as? String else { result(FlutterError(code: "invalid_customer_id", message: "customerId is required.", details: nil)); return }
            withClient(result) { client in self.finish(result, try await self.encode(try await client.identify(customerID: customerID))) }
        case "logOut":
            withClient(result) { client in self.finish(result, try await self.encode(try await client.logOut())) }
        case "setAttributes":
            let attributes = args["attributes"] as? [String: Any] ?? [:]
            withClient(result) { client in _ = try await client.setAttributes(attributes); self.finish(result, try self.encode(try await client.customerInfo())) }
        case "restorePurchases", "syncPurchases":
            withClient(result) { client in
                let snapshot = call.method == "restorePurchases" ? try await client.restorePurchases() : try await client.syncPurchases()
                self.finish(result, try self.encode(snapshot))
            }
        case "purchase":
            guard let packageID = args["packageId"] as? String else { result(FlutterError(code: "invalid_package", message: "packageId is required.", details: nil)); return }
            withClient(result) { client in
                switch try await client.purchase(packageID: packageID) {
                case .purchased(let snapshot): self.finish(result, ["status": "purchased", "customerInfo": try self.encode(snapshot)])
                case .pending: self.finish(result, ["status": "pending"])
                case .cancelled: self.finish(result, ["status": "cancelled"])
                }
            }
        case "logEvent":
            let name = args["name"] as? String ?? ""
            let properties = args["properties"] as? [String: Any] ?? [:]
            let eventID = args["eventId"] as? String ?? UUID().uuidString
            withClient(result) { client in self.finish(result, try await client.logEvent(name, properties: properties, eventID: eventID)) }
        case "spendVirtualCurrency":
            let adjustments = args["adjustments"] as? [String: Int] ?? [:]
            let key = args["idempotencyKey"] as? String ?? ""
            let reference = args["reference"] as? String
            withClient(result) { client in self.finish(result, try self.encode(try await client.spendVirtualCurrency(adjustments, idempotencyKey: key, reference: reference))) }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink sink: @escaping FlutterEventSink) -> FlutterError? {
        guard let purchases else { return nil }
        updatesTask?.cancel()
        updatesTask = Task {
            for await snapshot in await purchases.customerInfoUpdates() {
                guard !Task.isCancelled else { return }
                if let value = try? self.encode(snapshot) { DispatchQueue.main.async { sink(value) } }
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        updatesTask?.cancel()
        updatesTask = nil
        return nil
    }

    private func withClient(_ result: @escaping FlutterResult, operation: @escaping (PushifyPurchases) async throws -> Void) {
        guard let purchases else { result(FlutterError(code: "not_configured", message: "Call configure before using Pushify purchases.", details: nil)); return }
        Task { do { try await operation(purchases) } catch { self.finishError(result, error) } }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
    }

    private func finish(_ result: @escaping FlutterResult, _ value: Any) { DispatchQueue.main.async { result(value) } }

    private func finishError(_ result: @escaping FlutterResult, _ error: Error) {
        let flutterError: FlutterError
        if let apiError = error as? PushifyError,
           case let .server(status, code, message, retryable) = apiError {
            flutterError = FlutterError(code: code, message: message, details: ["status": status, "retryable": retryable])
        } else {
            flutterError = FlutterError(code: "pushify_error", message: String(describing: error), details: nil)
        }
        DispatchQueue.main.async { result(flutterError) }
    }
}

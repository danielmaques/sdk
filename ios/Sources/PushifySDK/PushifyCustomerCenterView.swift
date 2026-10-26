import SwiftUI

/// Native SwiftUI surface for published Customer Center configuration.
@MainActor
public struct PushifyCustomerCenterView: View {
    private let purchases: PushifyPurchases
    private let onCustomAction: ((String) -> Void)?
    @Environment(\.openURL) private var openURL
    @State private var configuration: PushifyJSONValue?
    @State private var customer: PushifyCustomerSnapshot?
    @State private var busy = false
    @State private var message: String?
    @State private var showTicket = false

    public init(purchases: PushifyPurchases, onCustomAction: ((String) -> Void)? = nil) {
        self.purchases = purchases
        self.onCustomAction = onCustomAction
    }

    public var body: some View {
        Group {
            if let configuration, let customer {
                let hasAccess = !customer.entitlements.active.isEmpty
                let screens = object(value(configuration, "screens"))
                let screen = object(screens[hasAccess ? "MANAGEMENT" : "NO_ACTIVE"])
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(string(screen["title"]) ?? "Manage subscription").font(.title2.bold())
                        if let subtitle = string(screen["subtitle"]) { Text(subtitle).foregroundStyle(.secondary) }
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        ForEach(Array(array(screen["paths"]).enumerated()), id: \.offset) { _, path in
                            if case .object(let fields) = path {
                                Button(string(fields["title"]) ?? "Continue") { perform(fields) }
                                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                                    .disabled(busy)
                            }
                        }
                        if hasAccess, bool(object(value(configuration, "support"))["display_purchase_history_link"]) {
                            Text("\(customer.transactions.count) verified purchases").font(.footnote).foregroundStyle(.secondary)
                        }
                        if bool(object(object(value(configuration, "support"))["support_tickets"])["allow_creation"]) {
                            Button(string(object(object(value(configuration, "localization"))["localized_strings"])["contact_support"]) ?? "Contact support") { showTicket = true }
                                .buttonStyle(.bordered)
                        }
                        if let message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                    }
                    .padding()
                }
            } else if busy {
                ProgressView("Loading Customer Center")
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.largeTitle)
                    Text("Customer Center unavailable").font(.headline)
                    Button("Try again", action: load)
                }
            }
        }
        .task { load() }
        .sheet(isPresented: $showTicket) {
            PushifyTicketForm { email, body in
                Task {
                    busy = true
                    do { try await purchases.createSupportTicket(email: email, message: body); message = "Your request was sent to support." }
                    catch { message = "The support request could not be sent. Please try again." }
                    busy = false
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
    }

    private func load() {
        busy = true
        Task {
            do {
                async let center = purchases.customerCenter()
                async let snapshot = purchases.customerInfo()
                configuration = try await center
                customer = try await snapshot
            } catch {
                configuration = nil
                customer = nil
            }
            busy = false
        }
    }

    private func perform(_ path: [String: PushifyJSONValue]) {
        guard !busy else { return }
        switch string(path["type"]) {
        case "MISSING_PURCHASE":
            busy = true
            Task {
                do { customer = try await purchases.restorePurchases(); message = "Purchases restored." }
                catch { message = "Purchases could not be restored. Please try again." }
                busy = false
            }
        case "CANCEL": open("https://apps.apple.com/account/subscriptions")
        case "REFUND_REQUEST": open("https://reportaproblem.apple.com/")
        case "CUSTOM_URL": if let url = string(path["url"]) { open(url) }
        case "CUSTOM_ACTION":
            if let action = string(path["action_identifier"]), let onCustomAction { onCustomAction(action) }
            else { message = "This account action is not available." }
        default: message = "This account action is not available."
        }
    }

    private func open(_ raw: String) {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), !["javascript", "data", "file", "blob", "about"].contains(scheme) else {
            message = "This link is unavailable."
            return
        }
        openURL(url) { accepted in if !accepted { message = "This link could not be opened." } }
    }

    private func value(_ value: PushifyJSONValue?, _ key: String) -> PushifyJSONValue? {
        guard case .object(let fields)? = value else { return nil }
        return fields[key]
    }

    private func object(_ value: PushifyJSONValue?) -> [String: PushifyJSONValue] { if case .object(let fields)? = value { return fields }; return [:] }
    private func array(_ value: PushifyJSONValue?) -> [PushifyJSONValue] { if case .array(let values)? = value { return values }; return [] }
    private func string(_ value: PushifyJSONValue?) -> String? { if case .string(let text)? = value { return text }; return nil }
    private func bool(_ value: PushifyJSONValue?) -> Bool { if case .bool(let result)? = value { return result }; return false }
}

private struct PushifyTicketForm: View {
    let onSubmit: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var message = ""

    var body: some View {
        NavigationView {
            Form {
                TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextEditor(text: $message).frame(minHeight: 120).accessibilityLabel("How can we help?")
            }
            .navigationTitle("Contact support")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        onSubmit(email.trimmingCharacters(in: .whitespacesAndNewlines), message.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }.disabled(!email.contains("@") || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

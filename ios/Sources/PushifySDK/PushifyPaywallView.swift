import SwiftUI

/// A native, accessible renderer for the core Pushify paywall components.
@MainActor
public struct PushifyPaywallView: View {
    private let document: PushifyPaywallDocument
    private let offering: PushifyOfferings.Offering
    private let purchases: PushifyPurchases
    private let onDismiss: (() -> Void)?
    @State private var selectedPackageID: String
    @State private var screenID: String
    @State private var busy = false
    @State private var message: String?

    public init(document: PushifyPaywallDocument, offering: PushifyOfferings.Offering, purchases: PushifyPurchases, onDismiss: (() -> Void)? = nil) {
        self.document = document
        self.offering = offering
        self.purchases = purchases
        self.onDismiss = onDismiss
        let defaultPackage = Self.packageNodes(document.screens.first?.content)
            .first(where: { Self.bool($0.properties["is_selected_by_default"]) })
        _selectedPackageID = State(initialValue: Self.string(defaultPackage?.properties["package_id"]) ?? offering.packages.first?.id ?? "")
        _screenID = State(initialValue: document.screens.first?.id ?? "")
    }

    public var body: some View {
        Group {
            if let screen = document.screens.first(where: { $0.id == screenID }) ?? document.screens.first {
                VStack(spacing: 0) {
                    if onDismiss != nil {
                        HStack {
                            Spacer()
                            Button(action: { onDismiss?() }) {
                                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Close paywall")
                        }
                    }
                    if let content = screen.content { render(content, screen: screen).frame(maxWidth: .infinity, maxHeight: .infinity) }
                    if let footer = screen.footer { render(footer, screen: screen) }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
                }
                .padding()
                .background(backgroundColor(screen.background).ignoresSafeArea())
                .accessibilityElement(children: .contain)
            } else {
                VStack(spacing: 8) { Image(systemName: "exclamationmark.triangle"); Text("Paywall unavailable") }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
    }

    @ViewBuilder private func render(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen) -> some View {
        switch node.kind {
        case "stack":
            VStack(alignment: .center, spacing: CGFloat(number(node.properties["spacing"]) ?? 12)) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in AnyView(render(child, screen: screen)) }
            }.frame(maxWidth: .infinity)
        case "hstack":
            HStack(spacing: CGFloat(number(node.properties["spacing"]) ?? 12)) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in AnyView(render(child, screen: screen)) }
            }.frame(maxWidth: .infinity)
        case "text", "title":
            Text(localized(node, screen: screen)).font(.system(size: CGFloat(number(node.properties["font_size"]) ?? 20), weight: fontWeight(node.properties["font_weight"]), design: .default))
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
        case "package":
            if let packageID = string(node.properties["package_id"]), let package = offering.packages.first(where: { $0.id == packageID }) {
                Button { selectedPackageID = packageID } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedPackageID == packageID ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(localized(node, screen: screen, fallback: string(node.properties["label"]) ?? package.product.displayName ?? packageID)).font(.body.weight(.semibold))
                            if let price = package.product.localizedPrice { Text(price).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 14).stroke(selectedPackageID == packageID ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 2))
                .accessibilityAddTraits(selectedPackageID == packageID ? .isSelected : [])
            }
        case "purchase_button", "cta":
            Button(action: buySelected) {
                HStack { if busy { ProgressView().tint(.white) }; Text(localized(node, screen: screen, fallback: "Continue")).font(.headline) }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).disabled(busy || selectedPackageID.isEmpty)
        case "restore_button":
            Button(localized(node, screen: screen, fallback: "Restore purchases"), action: restore).disabled(busy)
        case "button":
            Button(localized(node, screen: screen, fallback: "Continue")) {
                if string(node.properties["action"]) == "restore" { restore() }
                else if let next = string(node.properties["next_screen_id"]), document.screens.contains(where: { $0.id == next }) { screenID = next }
                else { buySelected() }
            }
        case "spacer":
            Spacer(minLength: CGFloat(number(node.properties["size"]) ?? 8))
        case "image":
            if let url = mediaURL(node.properties) {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .accessibilityLabel(string(node.properties["accessibility_label"]) ?? "")
            }
        default:
            if !node.children.isEmpty {
                VStack(spacing: 8) { ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in AnyView(render(child, screen: screen)) } }
            } else if let text = string(node.properties["text"]) { Text(text).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func buySelected() {
        guard !busy else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                switch try await purchases.purchase(packageID: selectedPackageID) {
                case .purchased: onDismiss?()
                case .pending: message = "Purchase is pending approval."
                case .cancelled: break
                }
            } catch { message = "Purchase could not be completed. Please try again." }
        }
    }

    private func restore() {
        guard !busy else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do { _ = try await purchases.restorePurchases(); message = "Purchases restored." }
            catch { message = "Purchases could not be restored. Please try again." }
        }
    }

    private func localized(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen, fallback: String? = nil) -> String {
        if let key = string(node.properties["text_lid"]) {
            for locale in [Locale.current.identifier, document.defaultLocale, "en_US"] {
                if case .string(let value)? = screen.localizations[locale]?[key] ?? document.locales[locale]?[key] { return value }
            }
        }
        return fallback ?? string(node.properties["text"]) ?? ""
    }

    private func backgroundColor(_ value: PushifyJSONValue?) -> Color {
        guard case .object(let root)? = value, case .object(let valueRoot)? = root["value"],
              case .object(let light)? = valueRoot["light"], case .string(let hex)? = light["value"] else { return Color(uiColor: .systemBackground) }
        return Color(hex: hex)
    }

    private func mediaURL(_ properties: [String: PushifyJSONValue]) -> URL? {
        guard case .object(let source)? = properties["source"], case .object(let light)? = source["light"], case .string(let url)? = light["url"] else { return nil }
        return URL(string: url)
    }

    private func fontWeight(_ value: PushifyJSONValue?) -> Font.Weight {
        switch string(value)?.lowercased() { case "bold", "semibold": return .semibold; case "medium": return .medium; case "light": return .light; default: return .regular }
    }

    private func string(_ value: PushifyJSONValue?) -> String? { if case .string(let v)? = value { return v }; return nil }
    private func number(_ value: PushifyJSONValue?) -> Double? {
        switch value { case .integer(let v)?: return Double(v); case .number(let v)?: return v; default: return nil }
    }
    private func bool(_ value: PushifyJSONValue?) -> Bool { if case .bool(let v)? = value { return v }; return false }

    private static func string(_ value: PushifyJSONValue?) -> String? { if case .string(let v)? = value { return v }; return nil }
    private static func bool(_ value: PushifyJSONValue?) -> Bool { if case .bool(let v)? = value { return v }; return false }
    private static func packageNodes(_ node: PushifyPaywallNode?) -> [PushifyPaywallNode] {
        guard let node else { return [] }
        return (node.kind == "package" ? [node] : []) + node.children.flatMap(packageNodes)
    }
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0xFFFFFFFF
        let hasAlpha = hex.count == 9
        self.init(.sRGB, red: Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255,
                  green: Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255,
                  blue: Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255,
                  opacity: hasAlpha ? Double(value & 0xff) / 255 : 1)
    }
}

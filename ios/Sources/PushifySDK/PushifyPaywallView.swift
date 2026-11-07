import SwiftUI
import WebKit
import UIKit

/// A native, accessible renderer for the core Pushify paywall components.
@MainActor
public struct PushifyPaywallView: View {
    @Environment(\.openURL) private var openURL
    private let document: PushifyPaywallDocument
    private let offering: PushifyOfferings.Offering
    private let purchases: PushifyPurchases
    private let onDismiss: (() -> Void)?
    @State private var selectedPackageID: String
    @State private var screenID: String
    @State private var busy = false
    @State private var message: String?
    @State private var selectedTabs: [String: String] = [:]
    @State private var carouselPages: [String: Int] = [:]
    @State private var failedExperienceIDs: Set<String> = []
    @State private var variables: [String: PushifyJSONValue]

    public init(document: PushifyPaywallDocument, offering: PushifyOfferings.Offering, purchases: PushifyPurchases, onDismiss: (() -> Void)? = nil) {
        self.document = document
        self.offering = offering
        self.purchases = purchases
        self.onDismiss = onDismiss
        let defaultPackage = Self.packageNodes(document.screens.first?.content)
            .first(where: { Self.bool($0.properties["is_selected_by_default"]) })
        _selectedPackageID = State(initialValue: Self.string(defaultPackage?.properties["package_id"]) ?? offering.packages.first?.id ?? "")
        _screenID = State(initialValue: document.screens.first?.id ?? "")
        _variables = State(initialValue: document.customVariables?.mapValues(\.initialValue) ?? [:])
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

    private func render(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen) -> AnyView {
        AnyView(renderContent(node, screen: screen))
    }

    @ViewBuilder private func renderContent(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen) -> some View {
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
            Button(action: { buySelected(screen: screen) }) {
                HStack {
                    if busy { ProgressView().tint(.white) }
                    if let content = node.children.first { render(content, screen: screen) }
                    else { Text(localized(node, screen: screen, fallback: "Continue")).font(.headline) }
                }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent).disabled(busy || selectedPackageID.isEmpty)
        case "restore_button":
            Button(localized(node, screen: screen, fallback: "Restore purchases"), action: restore).disabled(busy)
        case "button":
            Button {
                actionFeedback(node)
                handleButton(node, screen: screen)
            } label: {
                if let content = node.children.first {
                    AnyView(render(content, screen: screen))
                } else {
                    AnyView(Text(localized(node, screen: screen, fallback: "Continue")))
                }
            }
            .buttonStyle(PushifyActionButtonStyle(animation: actionString(node, key: "animation") ?? "none"))
        case "spacer":
            Spacer(minLength: CGFloat(number(node.properties["size"]) ?? 8))
        case "image":
            if let url = mediaURL(node.properties) {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .accessibilityLabel(string(node.properties["accessibility_label"]) ?? "")
            }
        case "web_view":
            if let rawURL = string(node.properties["url"]), let url = URL(string: rawURL), url.scheme == "https" {
                let experienceID = "\(string(node.properties["id"]) ?? "experience"):\(rawURL)"
                if failedExperienceIDs.contains(experienceID), let fallback = nestedNode(node.properties["fallback"]) {
                    render(fallback, screen: screen)
                } else {
                    PaywallExperienceWebView(url: url, onFailure: { self.failedExperienceIDs.insert(experienceID) })
                        .frame(height: CGFloat(number(object(object(node.properties["size"])?["height"])?["value"]) ?? 240))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else if let fallback = nestedNode(node.properties["fallback"]) {
                render(fallback, screen: screen)
            } else {
                EmptyView()
            }
        case "icon":
            Image(systemName: symbolName(string(node.properties["icon_name"]) ?? "star"))
                .font(.system(size: CGFloat(number(node.properties["size"]) ?? 24)))
                .foregroundStyle(Color(hex: colorString(node.properties["color"]) ?? "#315ee8"))
                .accessibilityLabel(string(node.properties["accessibility_label"]) ?? "")
        case "timeline":
            let items = array(node.properties["items"])
            VStack(alignment: .leading, spacing: CGFloat(number(node.properties["item_spacing"]) ?? 18)) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: CGFloat(number(node.properties["column_gutter"]) ?? 14)) {
                        VStack(spacing: 4) {
                            if let icon = nestedNode(item["icon"]) { AnyView(render(icon, screen: screen)).frame(width: 28, height: 28) }
                            if index < items.count - 1 { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity) }
                        }
                        VStack(alignment: .leading, spacing: CGFloat(number(node.properties["text_spacing"]) ?? 4)) {
                            if let title = nestedNode(item["title"]) { AnyView(render(title, screen: screen)) }
                            if let description = nestedNode(item["description"]) { AnyView(render(description, screen: screen)) }
                        }
                    }
                }
            }
        case "carousel":
            let pages = array(node.properties["pages"]).compactMap(nestedNode)
            if !pages.isEmpty {
                let carouselID = node.id ?? "carousel"
                let selected = min(carouselPages[carouselID] ?? Int(number(node.properties["initial_page_index"]) ?? 0), pages.count - 1)
                VStack(spacing: 8) {
                    TabView(selection: Binding(get: { selected }, set: { carouselPages[carouselID] = $0 })) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, page in AnyView(render(page, screen: screen)).tag(index) }
                    }.tabViewStyle(.page(indexDisplayMode: .automatic))
                }
            }
        case "tabs":
            let tabs = array(node.properties["tabs"]).compactMap { item -> (String, String, PushifyPaywallNode)? in
                guard let id = string(item["id"]), let name = string(item["name"]), let stack = nestedNode(item["stack"]) else { return nil }
                return (id, name, stack)
            }
            if let first = tabs.first {
                let tabsID = node.id ?? "tabs"
                let activeID = selectedTabs[tabsID] ?? string(node.properties["default_tab_id"]) ?? first.0
                VStack(spacing: 12) {
                    HStack { ForEach(tabs, id: \.0) { item in Button(item.1) { selectedTabs[tabsID] = item.0 }.buttonStyle(.bordered).tint(activeID == item.0 ? .accentColor : .secondary) } }
                    if let active = tabs.first(where: { $0.0 == activeID }) { AnyView(render(active.2, screen: screen)) }
                }
            }
        case "countdown":
            if let style = object(node.properties["style"]), let rawDate = string(style["date"]), let date = ISO8601DateFormatter().date(from: rawDate), date > .now {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let template = nestedNode(node.properties["countdown_stack"]).map { firstText($0, screen: screen) } ?? "{{ count_days_without_zero }}d {{ count_hours_with_zero }}:{{ count_minutes_with_zero }}:{{ count_seconds_with_zero }}"
                    Text(countdownLabel(from: context.date, to: date, template: template)).monospacedDigit().accessibilityLabel("Offer countdown")
                }
            } else if let end = nestedNode(node.properties["end_stack"]) { AnyView(render(end, screen: screen)) }
        case "tab_control":
            EmptyView()
        default:
            if !node.children.isEmpty {
                VStack(spacing: 8) { ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in AnyView(render(child, screen: screen)) } }
            } else if let text = string(node.properties["text"]) { Text(text).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func buySelected(packageID: String? = nil, action: [String: PushifyJSONValue] = [:], screen: PushifyPaywallScreen? = nil) {
        let productID = packageID ?? selectedPackageID
        guard !busy else { return }
        guard offering.packages.contains(where: { $0.id == productID }) else { message = "This purchase option is unavailable."; return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                switch try await purchases.purchase(packageID: productID) {
                case .purchased: await runPurchaseOutcome("after_purchase", fallback: "close", action: action, screen: screen)
                case .pending: message = "Purchase is pending approval."
                case .cancelled: await runPurchaseOutcome("on_abandon", fallback: "none", action: action, screen: screen)
                }
            } catch { message = "Purchase could not be completed. Please try again." }
        }
    }

    private func runPurchaseOutcome(_ key: String, fallback: String, action: [String: PushifyJSONValue], screen: PushifyPaywallScreen?) async {
        let steps = array(object(action["pushify_actions"])?[key])
        for step in steps {
            switch string(step["type"]) {
            case "update_variable": updateVariable(step)
            case "set_user_attributes":
                let configured = object(step["attributes"]) ?? [:]
                guard !configured.isEmpty else { message = "No user attributes are configured."; return }
                let valid = configured.allSatisfy { key, value in
                    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.count <= 100 else { return false }
                    switch value { case .string, .integer, .number, .bool, .null: return true; case .object, .array: return false }
                }
                guard valid else { message = "This user attribute is invalid."; return }
                do { _ = try await purchases.setAttributes(configured.mapValues(foundationValue)) }
                catch { message = "User attributes could not be updated. Please try again."; return }
            default: break
            }
        }
        let route = object(action[key])
        let type = string(route?["type"]) ?? fallback
        guard type != "none" else { return }
        guard let screen else { if type == "close" { onDismiss?() }; return }
        switch type {
        case "close": onDismiss?()
        case "navigate_back":
            if let index = document.screens.firstIndex(where: { $0.id == screen.id }), index > 0 { screenID = document.screens[index - 1].id }
            else { onDismiss?() }
        case "workflow":
            if let index = document.screens.firstIndex(where: { $0.id == screen.id }), index + 1 < document.screens.count { screenID = document.screens[index + 1].id }
            else { message = "This flow has no next screen." }
        default: message = "This purchase outcome is not supported by this SDK version."
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
            for locale in [Locale.current.identifier.replacingOccurrences(of: "-", with: "_"), Locale.current.identifier, document.defaultLocale, "en_US"] {
                if case .string(let value)? = screen.localizations[locale]?[key] ?? document.locales[locale]?[key] { return interpolate(value) }
            }
        }
        return interpolate(fallback ?? string(node.properties["text"]) ?? "")
    }

    private func interpolate(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*state\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let name = ns.substring(with: match.range(at: 1))
            guard let value = variables[name] else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: string(value) ?? number(value).map { String($0) } ?? (bool(value) ? "true" : "false"))
        }
        return result
    }

    private func localizedValue(_ key: String, screen: PushifyPaywallScreen) -> String? {
        for locale in [Locale.current.identifier.replacingOccurrences(of: "-", with: "_"), Locale.current.identifier, document.defaultLocale, "en_US"] {
            if case .string(let value)? = screen.localizations[locale]?[key] ?? document.locales[locale]?[key] { return value }
        }
        return nil
    }

    private func handleButton(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen) {
        let action = object(node.properties["action"]) ?? [:]
        let kind = string(action["type"]) ?? string(node.properties["action"]) ?? ""
        switch kind {
        case "update_variable": updateVariable(action)
        case "restore_purchases", "restore": restore()
        case "set_user_attributes": setUserAttributes(action)
        case "navigate_to": openActionLink(action, screen: screen)
        case "navigate_back":
            if let index = document.screens.firstIndex(where: { $0.id == screenID }), index > 0 { screenID = document.screens[index - 1].id }
            else { onDismiss?() }
        case "workflow":
            if let index = document.screens.firstIndex(where: { $0.id == screen.id }), index + 1 < document.screens.count {
                screenID = document.screens[index + 1].id
            } else {
                message = "This flow has no next screen."
            }
        case "close", "close_workflow": onDismiss?()
        case "purchase", "purchase_with_outcome", "purchase_product": buySelected(packageID: string(action["package_id"]), action: action, screen: screen)
        default:
            if let next = string(node.properties["next_screen_id"]), document.screens.contains(where: { $0.id == next }) { screenID = next }
            else { message = "This button action is not supported by this SDK version." }
        }
    }

    private func actionFeedback(_ node: PushifyPaywallNode) {
        guard let kind = actionString(node, key: "haptics"), kind != "none" else { return }
        switch kind {
        case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        default: break
        }
    }

    private func actionString(_ node: PushifyPaywallNode, key: String) -> String? {
        guard case .object(let action)? = node.properties["action"] else { return nil }
        return string(action[key])
    }

    private func updateVariable(_ action: [String: PushifyJSONValue]) {
        guard let reference = string(action["variable"]), reference.hasPrefix("state."), let key = document.customVariables?[String(reference.dropFirst(6))], key.type == "state" else { message = "This state variable is not declared."; return }
        let name = String(reference.dropFirst(6)); let before = variables[name] ?? key.initialValue
        let operation = string(action["operation"]) ?? "set"; let amount = number(action["value"]) ?? 0
        switch key.valueType {
        case "number":
            let current = number(before) ?? 0
            variables[name] = .number(operation == "increment" ? current + amount : operation == "decrement" ? current - amount : amount)
        case "boolean":
            variables[name] = .bool(operation == "toggle" ? !bool(before) : bool(action["value"]))
        default: variables[name] = action["value"] ?? before
        }
    }

    private func setUserAttributes(_ action: [String: PushifyJSONValue]) {
        let configured = object(action["attributes"]) ?? [:]
        guard !configured.isEmpty else { message = "No user attributes are configured."; return }
        let valid = configured.allSatisfy { key, value in
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.count <= 100 else { return false }
            switch value { case .string, .integer, .number, .bool, .null: return true; case .object, .array: return false }
        }
        guard valid else { message = "This user attribute is invalid."; return }
        guard !busy else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                let attributes = configured.mapValues(foundationValue)
                _ = try await purchases.setAttributes(attributes)
                message = "User attributes updated."
            } catch {
                message = "User attributes could not be updated. Please try again."
            }
        }
    }

    private func foundationValue(_ value: PushifyJSONValue) -> Any {
        switch value {
        case .string(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        case .object(let value): value.mapValues(foundationValue)
        case .array(let value): value.map(foundationValue)
        }
    }

    private func openActionLink(_ action: [String: PushifyJSONValue], screen: PushifyPaywallScreen) {
        let url = object(action["url"]) ?? [:]
        let key = string(url["url_lid"])
        let raw = key.flatMap { localizedValue($0, screen: screen) } ?? string(url["url"])
        guard let raw, let value = URL(string: raw), let scheme = value.scheme?.lowercased(), ["http", "https"].contains(scheme), value.host != nil else {
            message = "This link is unavailable."
            return
        }
        openURL(value) { accepted in
            if !accepted { message = "This link could not be opened." }
        }
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

    private func array(_ value: PushifyJSONValue?) -> [[String: PushifyJSONValue]] { if case .array(let values)? = value { return values.compactMap { if case .object(let item) = $0 { return item }; return nil } }; return [] }
    private func object(_ value: PushifyJSONValue?) -> [String: PushifyJSONValue]? { if case .object(let item)? = value { return item }; return nil }
    private func nestedNode(_ value: [String: PushifyJSONValue]?) -> PushifyPaywallNode? {
        guard let value, let kind = string(value["kind"]) ?? string(value["type"]) else { return nil }
        let components: [PushifyPaywallNode] = (value["children"] ?? value["components"]).flatMap { raw in
            guard case .array(let items) = raw else { return nil }
            return items.compactMap { item -> PushifyPaywallNode? in guard case .object(let object) = item else { return nil }; return nestedNode(object) }
        } ?? []
        var properties = object(value["properties"]) ?? value
        if properties["fallback"] == nil, let fallback = value["fallback"] { properties["fallback"] = fallback }
        ["kind", "type", "children", "components", "id", "properties"].forEach { properties.removeValue(forKey: $0) }
        return PushifyPaywallNode(id: string(value["id"]), kind: kind, properties: properties, children: components)
    }
    private func nestedNode(_ value: PushifyJSONValue?) -> PushifyPaywallNode? {
        guard case .object(let object)? = value else { return nil }
        return nestedNode(object)
    }
    private func symbolName(_ value: String) -> String { ["check": "checkmark", "unlock": "lock.open", "bell": "bell", "star": "star.fill", "heart": "heart.fill", "clock": "clock", "lock": "lock.fill" ][value] ?? "circle.fill" }
    private func colorString(_ value: PushifyJSONValue?) -> String? {
        if case .string(let color)? = value { return color }
        if case .object(let object)? = value {
            let colors: [String: PushifyJSONValue]
            if case .object(let nested)? = object["value"] { colors = nested } else { colors = object }
            if case .object(let light)? = colors["light"], case .string(let color)? = light["value"] { return color }
        }
        return nil
    }
    private func firstText(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen) -> String {
        if node.kind == "text" || node.kind == "title" { return localized(node, screen: screen) }
        return node.children.first(where: { $0.kind == "text" || $0.kind == "title" }).map { localized($0, screen: screen) }
            ?? node.children.first.map { firstText($0, screen: screen) }
            ?? "{{ count_days_without_zero }}d {{ count_hours_with_zero }}:{{ count_minutes_with_zero }}:{{ count_seconds_with_zero }}"
    }
    private func countdownLabel(from now: Date, to end: Date, template: String) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        let days = seconds / 86_400
        let hours = (seconds / 3_600) % 24
        let minutes = (seconds / 60) % 60
        let remainder = seconds % 60
        return template
            .replacingOccurrences(of: "{{ count_days_without_zero }}", with: String(days))
            .replacingOccurrences(of: "{{ count_hours_with_zero }}", with: String(format: "%02d", hours))
            .replacingOccurrences(of: "{{ count_minutes_with_zero }}", with: String(format: "%02d", minutes))
            .replacingOccurrences(of: "{{ count_seconds_with_zero }}", with: String(format: "%02d", remainder))
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

@MainActor
private struct PaywallExperienceWebView: UIViewRepresentable {
    let url: URL
    let onFailure: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20))
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFailure: () -> Void
        init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "https" ? .allow : .cancel)
        }
    }
}

private struct PushifyActionButtonStyle: ButtonStyle {
    let animation: String
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(animation == "shrink" && configuration.isPressed ? 0.96 : animation == "grow" && configuration.isPressed ? 1.04 : 1)
            .opacity(animation == "fade" && configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
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

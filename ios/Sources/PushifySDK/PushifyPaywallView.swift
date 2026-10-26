import SwiftUI
import WebKit

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
    @State private var selectedTabs: [String: String] = [:]
    @State private var carouselPages: [String: Int] = [:]
    @State private var failedExperienceIDs: Set<String> = []

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

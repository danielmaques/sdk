import SwiftUI
import AVKit
import WebKit
import UIKit
import SafariServices
import StoreKit

private struct PresentedPaywallSurvey: Identifiable {
    let id: String
    let trigger: String
    let survey: PushifyPaywallSurvey
    let localizations: [String: [String: PushifyJSONValue]]
}

@MainActor private final class TapActionRun {
    let id = UUID()
    var waiting = false
    var interruptible = false
    var task: Task<Void, Never>?
    var callbackTasks: [Task<Void, Never>] = []
    var pendingCallbackCount = 0
    var terminalFinished = false
}

/// A native, accessible renderer for the core Pushify paywall components.
@MainActor
public struct PushifyPaywallView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    private let document: PushifyPaywallDocument
    private let offering: PushifyOfferings.Offering
    private let purchases: PushifyPurchases
    private let onDismiss: (() -> Void)?
    private let onCustomAction: ((String) -> Void)?
    private let onCustomPlacement: ((String, [String: PushifyJSONValue]) -> Void)?
    private let onCustomCallback: ((String, [String: PushifyJSONValue]) async throws -> PushifyCustomCallbackResult)?
    private let isExitOffer: Bool
    @State private var selectedPackageID: String
    @State private var screenID: String
    @State private var busy = false
    @State private var message: String?
    @State private var inAppBrowserLink: PushifyBrowserLink?
    @State private var selectedTabs: [String: String] = [:]
    @State private var carouselPages: [String: Int] = [:]
    @State private var failedExperienceIDs: Set<String> = []
    @State private var variables: [String: PushifyJSONValue]
    @State private var callbackData: [String: [String: PushifyJSONValue]] = [:]
    @State private var transactionProducts: [String: PushifyOfferings.Offering.Package.StoreProduct] = [:]
    @State private var exitOffering: PushifyOfferings.Offering?
    @State private var dismissing = false
    @State private var presentedSurvey: PresentedPaywallSurvey?
    @State private var surveyedTriggers: Set<String> = []
    @State private var randomizationSeed = Int.random(in: Int.min...Int.max)
    @State private var surveyContinuation: CheckedContinuation<Void, Never>?
    @State private var tapActionRuns: [String: TapActionRun] = [:]

    public init(document: PushifyPaywallDocument, offering: PushifyOfferings.Offering, purchases: PushifyPurchases, onDismiss: (() -> Void)? = nil, onCustomAction: ((String) -> Void)? = nil, onCustomPlacement: ((String, [String: PushifyJSONValue]) -> Void)? = nil, onCustomCallback: ((String, [String: PushifyJSONValue]) async throws -> PushifyCustomCallbackResult)? = nil) {
        self.document = document
        self.offering = offering
        self.purchases = purchases
        self.onDismiss = onDismiss
        self.onCustomAction = onCustomAction
        self.onCustomPlacement = onCustomPlacement
        self.onCustomCallback = onCustomCallback
        self.isExitOffer = false
        let entryScreen = document.screens.first(where: { $0.id == document.initialScreenID }) ?? document.screens.first
        let defaultPackage = Self.packageNodes(entryScreen?.content)
            .first(where: { Self.bool($0.properties["is_selected_by_default"]) })
        _selectedPackageID = State(initialValue: Self.string(defaultPackage?.properties["package_id"]) ?? offering.packages.first?.id ?? "")
        _screenID = State(initialValue: entryScreen?.id ?? "")
        var initialVariables = document.customVariables?.mapValues(\.initialValue) ?? [:]
        if document.customVariables?["didCompleteTransaction"] == nil { initialVariables["didCompleteTransaction"] = .bool(false) }
        if document.customVariables?["didAbandonTransaction"] == nil { initialVariables["didAbandonTransaction"] = .bool(false) }
        _variables = State(initialValue: initialVariables)
    }

    private init(document: PushifyPaywallDocument, offering: PushifyOfferings.Offering, purchases: PushifyPurchases, onDismiss: (() -> Void)?, onCustomAction: ((String) -> Void)?, onCustomPlacement: ((String, [String: PushifyJSONValue]) -> Void)?, onCustomCallback: ((String, [String: PushifyJSONValue]) async throws -> PushifyCustomCallbackResult)?, isExitOffer: Bool) {
        self.document = document
        self.offering = offering
        self.purchases = purchases
        self.onDismiss = onDismiss
        self.onCustomAction = onCustomAction
        self.onCustomPlacement = onCustomPlacement
        self.onCustomCallback = onCustomCallback
        self.isExitOffer = isExitOffer
        let entryScreen = document.screens.first(where: { $0.id == document.initialScreenID }) ?? document.screens.first
        let defaultPackage = Self.packageNodes(entryScreen?.content)
            .first(where: { Self.bool($0.properties["is_selected_by_default"]) })
        _selectedPackageID = State(initialValue: Self.string(defaultPackage?.properties["package_id"]) ?? offering.packages.first?.id ?? "")
        _screenID = State(initialValue: entryScreen?.id ?? "")
        var initialVariables = document.customVariables?.mapValues(\.initialValue) ?? [:]
        if document.customVariables?["didCompleteTransaction"] == nil { initialVariables["didCompleteTransaction"] = .bool(false) }
        if document.customVariables?["didAbandonTransaction"] == nil { initialVariables["didAbandonTransaction"] = .bool(false) }
        _variables = State(initialValue: initialVariables)
    }

    public var body: some View {
        Group {
            if let exitOffering, let exitDocument = exitOffering.paywall {
                AnyView(PushifyPaywallView(document: exitDocument, offering: exitOffering, purchases: purchases, onDismiss: onDismiss, onCustomAction: onCustomAction, onCustomPlacement: onCustomPlacement, onCustomCallback: onCustomCallback, isExitOffer: true))
            } else if let screen = document.screens.first(where: { $0.id == screenID }) ?? document.screens.first {
                VStack(spacing: 0) {
                    if onDismiss != nil {
                        HStack {
                            Spacer()
                            Button(action: { Task { await dismissManually() } }) {
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
        .sheet(item: $inAppBrowserLink) { link in PushifySafariView(url: link.url).ignoresSafeArea() }
        .sheet(item: $presentedSurvey) { presentation in
            VStack(alignment: .leading, spacing: 14) {
                Text(surveyText(presentation.survey.questionLid, localizations: presentation.localizations)).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                ForEach(presentation.survey.options, id: \.id) { option in
                    Button(surveyText(option.labelLid, localizations: presentation.localizations)) { finishSurvey(optionID: option.id) }
                        .buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(surveyText(presentation.survey.skipLabelLid ?? "", localizations: presentation.localizations, fallback: "Skip")) { finishSurvey(optionID: nil) }
                    .buttonStyle(.plain).frame(maxWidth: .infinity).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(24)
            .interactiveDismissDisabled()
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
        .onDisappear {
            for run in tapActionRuns.values { run.task?.cancel(); run.callbackTasks.forEach { $0.cancel() } }
            tapActionRuns.removeAll()
        }
    }

    private func dismissManually() async {
        guard !dismissing else { return }
        let index = document.screens.firstIndex(where: { $0.id == screenID })
        if !isExitOffer, index != nil,
           let screen = document.screens.first(where: { $0.id == screenID }) {
            await presentSurvey("close", screen: screen)
        }
        if isExitOffer { dismissing = true; onDismiss?(); return }
        guard let index, index == document.screens.count - 1,
              let exit = object(document.exitOffer),
              let dismiss = object(exit["dismiss"]),
              let destinationID = string(dismiss["offering_id"]),
              destinationID != offering.id else { dismissing = true; onDismiss?(); return }
        dismissing = true
        defer { dismissing = false }
        do {
            let catalog = try await purchases.offerings()
            guard let destination = catalog.offerings.first(where: { $0.id == destinationID && $0.paywall != nil }),
                  destination.paywall != nil else { onDismiss?(); return }
            _ = try? await purchases.logEvent("PAYWALL_EXIT_OFFER", properties: ["type": "dismiss", "offering_id": destinationID, "paywall_id": document.id])
            exitOffering = destination
        } catch {
            onDismiss?()
        }
    }

    private func presentSurvey(_ trigger: String, screen: PushifyPaywallScreen) async {
        guard !surveyedTriggers.contains(trigger), let survey = document.surveys?[trigger] else { return }
        surveyedTriggers.insert(trigger)
        await withCheckedContinuation { continuation in
            surveyContinuation = continuation
            presentedSurvey = PresentedPaywallSurvey(id: "\(trigger)-\(survey.id)", trigger: trigger, survey: survey, localizations: screen.localizations)
        }
    }

    private func finishSurvey(optionID: String?) {
        guard let presentation = presentedSurvey else { return }
        if let optionID {
            Task {
                _ = try? await purchases.logEvent("paywall_survey_response", properties: [
                    "paywall_id": document.id, "survey_id": presentation.survey.id, "trigger": presentation.trigger, "option_id": optionID,
                ])
            }
        }
        presentedSurvey = nil
        let continuation = surveyContinuation
        surveyContinuation = nil
        continuation?.resume()
    }

    private func surveyText(_ key: String, localizations: [String: [String: PushifyJSONValue]], fallback: String? = nil) -> String {
        guard !key.isEmpty else { return fallback ?? "" }
        for locale in [Locale.current.identifier.replacingOccurrences(of: "-", with: "_"), document.defaultLocale, "en_US"] {
            if case .string(let value)? = localizations[locale]?[key] ?? document.locales[locale]?[key] { return value }
        }
        return fallback ?? key
    }

    private func render(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen) -> AnyView {
        if !visibilityMatches(object(node.properties["pushify_visibility"])) { return AnyView(EmptyView()) }
        let motion = object(node.properties["pushify_motion"])
        let accessibility = object(node.properties["pushify_accessibility"])
        let role = string(accessibility?["role"]) ?? "automatic"
        var view = AnyView(renderContent(node, screen: screen))
        if Self.bool(motion?["enabled"]) {
            view = AnyView(PushifyMotionView(
                x: CGFloat(number(motion?["x"]) ?? 0), y: CGFloat(number(motion?["y"]) ?? 16),
                rotation: number(motion?["rotation"]) ?? 0, scale: number(motion?["scale"]) ?? 1,
                opacity: number(motion?["opacity"]) ?? 0,
                duration: number(motion?["duration_ms"]) ?? 400, delay: number(motion?["delay_ms"]) ?? 0,
                easing: string(motion?["easing"]) ?? "ease_out", content: view
            ))
        }
        if Self.bool(accessibility?["hidden"]) || role == "presentation" {
            view = AnyView(view.accessibilityHidden(true))
        } else if let label = string(accessibility?["label"]), !label.isEmpty {
            view = AnyView(view.accessibilityElement(children: .ignore).accessibilityLabel(label))
        }
        switch role {
        case "button": view = AnyView(view.accessibilityAddTraits(.isButton))
        case "link": view = AnyView(view.accessibilityAddTraits(.isLink))
        case "image": view = AnyView(view.accessibilityAddTraits(.isImage))
        case "heading": view = AnyView(view.accessibilityAddTraits(.isHeader))
        case "alert": view = AnyView(view.accessibilityAddTraits(.updatesFrequently))
        case "dialog": view = AnyView(view.accessibilityElement(children: .contain))
        default: break
        }
        return view
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
                .foregroundStyle(colorString(node.properties["color"], dark: colorScheme == .dark).map { Color(hex: $0) } ?? Color.primary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
        case "input":
            let reference = string(node.properties["state_variable"]) ?? ""
            let name = reference.hasPrefix("state.") ? String(reference.dropFirst(6)) : ""
            if let declaration = document.customVariables?[name], declaration.type == "state", declaration.valueType == "text" {
                let labelKey = string(node.properties["label_lid"])
                let placeholderKey = string(node.properties["placeholder_lid"])
                let label = labelKey.flatMap { localizedValue($0, screen: screen) }.map(interpolate) ?? "Your response"
                let placeholder = placeholderKey.flatMap { localizedValue($0, screen: screen) }.map(interpolate) ?? ""
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).font(.footnote).foregroundStyle(.secondary)
                    TextField(placeholder, text: Binding(
                        get: { string(variables[name]) ?? string(declaration.initialValue) ?? "" },
                        set: { variables[name] = .string(String($0.prefix(max(1, min(500, Int(number(node.properties["max_length"]) ?? 100)))))) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(string(node.properties["keyboard"]) == "email" ? .emailAddress : string(node.properties["keyboard"]) == "number" ? .decimalPad : .default)
                    .textInputAutocapitalization(string(node.properties["keyboard"]) == "email" ? .never : .sentences)
                    .autocorrectionDisabled(string(node.properties["keyboard"]) == "email")
                    .accessibilityLabel(label)
                }
            } else {
                EmptyView()
            }
        case "slider":
            let reference = string(node.properties["state_variable"]) ?? ""
            let name = reference.hasPrefix("state.") ? String(reference.dropFirst(6)) : ""
            if let declaration = document.customVariables?[name], declaration.type == "state", declaration.valueType == "number" {
                let minimum = number(node.properties["minimum"]) ?? 0
                let maximum = number(node.properties["maximum"]) ?? 100
                let step = number(node.properties["step"]) ?? 1
                let current = number(variables[name]) ?? number(declaration.initialValue) ?? minimum
                let value = min(max(current, minimum), maximum)
                let label = string(node.properties["label_lid"]).flatMap { localizedValue($0, screen: screen) }.map(interpolate) ?? "Choose a value"
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(label).font(.footnote); Spacer(); Text(value.formatted()).font(.footnote.monospacedDigit()) }
                    Group {
                        if step > 0 {
                            Slider(value: Binding(get: { min(max(number(variables[name]) ?? value, minimum), maximum) }, set: { variables[name] = .number($0) }), in: minimum...maximum, step: step)
                        } else {
                            Slider(value: Binding(get: { min(max(number(variables[name]) ?? value, minimum), maximum) }, set: { variables[name] = .number($0) }), in: minimum...maximum)
                        }
                    }
                    .rotationEffect(string(node.properties["orientation"]) == "vertical" ? .degrees(-90) : .zero)
                    .frame(maxWidth: string(node.properties["orientation"]) == "vertical" ? 220 : .infinity, minHeight: string(node.properties["orientation"]) == "vertical" ? 180 : 28)
                    .accessibilityLabel(label)
                }
            } else {
                EmptyView()
            }
        case "multiple_choice":
            let valueReference = string(node.properties["state_variable"]) ?? ""
            let labelReference = string(node.properties["label_state_variable"]) ?? ""
            let valueName = valueReference.hasPrefix("state.") ? String(valueReference.dropFirst(6)) : ""
            let labelName = labelReference.hasPrefix("state.") ? String(labelReference.dropFirst(6)) : ""
            if let valueDeclaration = document.customVariables?[valueName], valueDeclaration.valueType == "selection",
               let labelDeclaration = document.customVariables?[labelName], labelDeclaration.valueType == "text" {
                let multiple = string(node.properties["mode"]) == "multiple"
                let selected = selectedChoiceValues(variables[valueName] ?? valueDeclaration.initialValue, multiple: multiple)
                let rawOptions = node.properties["options"]
                let choiceOptions: [[String: PushifyJSONValue]] = rawOptions.flatMap { value -> [[String: PushifyJSONValue]]? in
                    if case .array(let values) = value { values.compactMap { object($0) } }
                    else { nil }
                } ?? []
                let choices = Self.bool(node.properties["randomize_order"]) ? choiceOptions.sorted(by: { choiceScore($0, seed: randomizationSeed) < choiceScore($1, seed: randomizationSeed) }) : choiceOptions
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { _, option in
                        let value = string(option["value"]) ?? ""
                        let labelKey = string(option["label_lid"]) ?? ""
                        let label = interpolate(localizedValue(labelKey, screen: screen) ?? value)
                        let isSelected = selected.contains(value)
                        Button {
                            let next = multiple ? (isSelected ? selected.filter { $0 != value } : selected + [value]) : [value]
                            let labels = next.map { selectedValue in
                                let match = choiceOptions.first { string($0["value"]) == selectedValue }
                                let key = string(match?["label_lid"]) ?? ""
                                return interpolate(localizedValue(key, screen: screen) ?? selectedValue)
                            }.joined(separator: ", ")
                            variables[valueName] = multiple ? .array(next.map(PushifyJSONValue.string)) : .string(next.first ?? "")
                            variables[labelName] = .string(labels)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: multiple ? (isSelected ? "checkmark.square.fill" : "square") : (isSelected ? "largecircle.fill.circle" : "circle"))
                                Text(label).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: isSelected ? 2 : 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(multiple ? "Choose one or more options" : "Choose one option")
            } else {
                EmptyView()
            }
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
                runTapActions(node, screen: screen)
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
            if let url = mediaURL(node.properties, key: "source", dark: colorScheme == .dark) {
                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .accessibilityLabel(string(node.properties["accessibility_label"]) ?? "")
            }
        case "video":
            if let url = mediaURL(node.properties, key: "source", dark: colorScheme == .dark), url.scheme?.lowercased() == "https" {
                let sources = object(node.properties["source"])
                let selectedSource = object((colorScheme == .dark ? sources?["dark"] : nil) ?? sources?["light"])
                let size = object(node.properties["size"])
                let heightSize = object(size?["height"])
                let fixedHeight = string(heightSize?["type"]) == "fixed" ? number(heightSize?["value"]) : nil
                PushifyPaywallVideo(
                    url: url,
                    posterURL: mediaURL(node.properties, key: "fallback_source", dark: colorScheme == .dark).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil },
                    width: number(selectedSource?["width"]) ?? 1,
                    height: number(selectedSource?["height"]) ?? 1,
                    autoPlay: Self.bool(node.properties["auto_play"], default: true),
                    loops: Self.bool(node.properties["loop"], default: true),
                    muted: Self.bool(node.properties["mute_audio"], default: true),
                    showsControls: Self.bool(node.properties["show_controls"], default: false),
                    fitMode: string(node.properties["fit_mode"]) ?? "fill",
                    fixedHeight: fixedHeight.map { CGFloat($0) }
                )
                .accessibilityLabel(string(node.properties["accessibility_label"]) ?? "Video")
            } else {
                videoUnavailable(node.properties, dark: colorScheme == .dark)
            }
        case "web_view":
            if let rawURL = string(node.properties["url"]), let url = URL(string: rawURL), isHTTPSOrigin(url), (number(node.properties["protocol_version"]) ?? 1) == 1 {
                let experienceID = "\(string(node.properties["id"]) ?? "experience"):\(rawURL)"
                let fallback = nestedNode(node.properties["fallback"]).map { render($0, screen: screen) }
                if failedExperienceIDs.contains(experienceID), let fallback { fallback }
                else {
                    PaywallExperienceWebView(url: url, fallback: fallback, onFailure: { self.failedExperienceIDs.insert(experienceID) })
                        .frame(height: CGFloat(number(object(object(node.properties["size"])?["height"])?["value"]) ?? 240))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else if let fallback = nestedNode(node.properties["fallback"]) {
                render(fallback, screen: screen)
            } else {
                EmptyView()
            }
        case "icon":
            let iconBackground = object(node.properties["icon_background"])
            let backgroundColor = colorString(iconBackground?["color"], dark: colorScheme == .dark)
            let shape = object(iconBackground?["shape"])
            Image(systemName: symbolName(string(node.properties["icon_name"]) ?? "star"))
                .font(.system(size: CGFloat(number(node.properties["size"]) ?? 24)))
                .foregroundStyle(Color(hex: colorString(node.properties["color"], dark: colorScheme == .dark) ?? "#315ee8"))
                .padding(backgroundColor == nil ? 0 : 6)
                .background {
                    if let backgroundColor {
                        if string(shape?["type"]) == "circle" { Circle().fill(Color(hex: backgroundColor)) }
                        else { RoundedRectangle(cornerRadius: 8).fill(Color(hex: backgroundColor)) }
                    }
                }
                .accessibilityLabel(string(node.properties["accessibility_label"]) ?? "")
        case "timeline":
            let items = array(node.properties["items"])
            VStack(alignment: .leading, spacing: CGFloat(number(node.properties["item_spacing"]) ?? 18)) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: CGFloat(number(node.properties["column_gutter"]) ?? 14)) {
                        VStack(spacing: 4) {
                            if let icon = nestedNode(item["icon"]) { AnyView(render(icon, screen: screen)).frame(width: 28, height: 28) }
                            if index < items.count - 1 {
                                let connector = object(item["connector"])
                                let lineColor = colorString(connector?["color"], dark: colorScheme == .dark)
                                Rectangle().fill(lineColor.map { Color(hex: $0) } ?? Color.secondary.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                            }
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
                let reminder = document.trialReminder
                let title = reminder.map { surveyText($0.titleLid, localizations: screen?.localizations ?? [:]) }
                let subtitle = reminder?.subtitleLid.map { surveyText($0, localizations: screen?.localizations ?? [:]) }
                let body = reminder.map { surveyText($0.bodyLid, localizations: screen?.localizations ?? [:]) }
                switch try await purchases.purchase(packageID: productID, trialReminder: reminder, title: title, subtitle: subtitle, body: body) {
                case .purchased:
                    transactionProducts = offering.packages.first(where: { $0.id == productID }).map { ["purchased": $0.product] } ?? [:]
                    setTransactionState(completed: true)
                    if let screen { await presentSurvey("post_purchase", screen: screen) }
                    await runPurchaseOutcome("after_purchase", fallback: "close", action: action, screen: screen)
                case .pending: message = "Purchase is pending approval."
                case .cancelled:
                    transactionProducts = offering.packages.first(where: { $0.id == productID }).map { ["abandoned": $0.product] } ?? [:]
                    setTransactionState(completed: false)
                    await runPurchaseOutcome("on_abandon", fallback: "none", action: action, screen: screen)
                }
            } catch { message = "Purchase could not be completed. Please try again." }
        }
    }

    private func setTransactionState(completed: Bool) {
        if document.customVariables?["didCompleteTransaction"] == nil { variables["didCompleteTransaction"] = .bool(completed) }
        if document.customVariables?["didAbandonTransaction"] == nil { variables["didAbandonTransaction"] = .bool(!completed) }
    }

    private func runPurchaseOutcome(_ key: String, fallback: String, action: [String: PushifyJSONValue], screen: PushifyPaywallScreen?) async {
        let steps = array(object(action["pushify_actions"])?[key])
        for step in steps {
            switch string(step["type"]) {
            case "update_variable": updateVariable(step)
            case "navigate_to":
                if let screen { openActionLink(step, screen: screen) }
                else { message = "This link is unavailable." }
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
            case "custom_placement":
                dispatchCustomPlacement(step)
            default: break
            }
        }
        let route = object(action[key])
        let type = string(route?["type"]) ?? fallback
        guard type != "none" else { return }
        guard let screen else { if type == "close" { dismissing = true; onDismiss?() }; return }
        switch type {
        case "close": dismissing = true; onDismiss?()
        case "navigate_back":
            if let index = document.screens.firstIndex(where: { $0.id == screen.id }), index > 0 { screenID = document.screens[index - 1].id }
            else { dismissing = true; onDismiss?() }
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
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*(?:state\.([A-Za-z_][A-Za-z0-9_]*)|callbacks\.([A-Za-z_][A-Za-z0-9_]*)\.data\.([A-Za-z_][A-Za-z0-9_.-]*)|products\.(purchased|abandoned)\.([A-Za-z_][A-Za-z0-9_]*))\s*\}\}"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = text
        for match in matches.reversed() {
            let name = match.range(at: 1).location == NSNotFound ? nil : ns.substring(with: match.range(at: 1))
            let value: PushifyJSONValue?
            if let name { value = variables[name] }
            else if match.range(at: 2).location != NSNotFound, match.range(at: 3).location != NSNotFound {
                let callback = ns.substring(with: match.range(at: 2)), key = ns.substring(with: match.range(at: 3))
                value = callbackData[callback]?[key]
            } else if match.range(at: 4).location != NSNotFound, match.range(at: 5).location != NSNotFound {
                let outcome = ns.substring(with: match.range(at: 4)), field = ns.substring(with: match.range(at: 5))
                guard let product = transactionProducts[outcome] else { continue }
                let raw = productAliasValue(field, product: product, peers: offering.packages.map(\.product), locale: Locale.current.identifier)
                guard let raw else { continue }
                result = (result as NSString).replacingCharacters(in: match.range, with: raw)
                continue
            } else { value = nil }
            guard let value else { continue }
            let formatted: String
            if case .array(let values) = value { formatted = values.compactMap { string($0) }.joined(separator: ", ") }
            else { formatted = string(value) ?? number(value).map { String($0) } ?? (bool(value) ? "true" : "false") }
            result = (result as NSString).replacingCharacters(in: match.range, with: formatted)
        }
        return result
    }

    private func productAliasValue(_ field: String, product: PushifyOfferings.Offering.Package.StoreProduct, peers: [PushifyOfferings.Offering.Package.StoreProduct], locale: String) -> String? {
        typealias Period = (count: Int, unit: String, days: Double)
        func parse(_ raw: String?) -> Period? {
            guard let raw else { return nil }
            let regex = try? NSRegularExpression(pattern: #"^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$"#)
            let ns = raw as NSString
            guard let match = regex?.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)), match.range.length == ns.length else { return nil }
            let values = (1...4).map { index -> Int in
                guard match.range(at: index).location != NSNotFound else { return 0 }
                return Int(ns.substring(with: match.range(at: index))) ?? 0
            }
            let units = [("year", values[0], 365.0), ("month", values[1], 30.0), ("week", values[2], 7.0), ("day", values[3], 1.0)].filter { $0.1 > 0 }
            guard !units.isEmpty else { return nil }
            if units.count == 1 { return (units[0].1, units[0].0, Double(units[0].1) * units[0].2) }
            let days = units.reduce(0.0) { $0 + Double($1.1) * $1.2 }
            return (Int(days.rounded()), "day", days)
        }
        let words = offering.variableLocalizations?[locale] ?? offering.variableLocalizations?[locale.replacingOccurrences(of: "-", with: "_")] ?? offering.variableLocalizations?[document.defaultLocale] ?? offering.variableLocalizations?["en_US"] ?? [:]
        let period = parse(product.duration)
        let trial = parse(product.trialDuration)
        let price = product.priceAmount.flatMap(Double.init)
        let currency = product.currencyCode
        func money(_ amount: Double) -> String? {
            guard let currency else { return nil }
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            formatter.locale = Locale(identifier: locale.replacingOccurrences(of: "_", with: "-"))
            return formatter.string(from: NSNumber(value: amount))
        }
        func countText(_ value: Period) -> String {
            let oneOrOther = words["num_\(value.unit)_\(value.count == 1 ? "one" : "other")"] ?? "%d \(value.unit)s"
            return oneOrOther.replacingOccurrences(of: "%d", with: String(value.count))
        }
        func unitText(_ value: Period, short: Bool = false) -> String {
            if value.count > 1 {
                let key = short ? "num_\(value.unit)s_short" : "num_\(value.unit)_other"
                let fallback = short ? "%d\(value.unit.prefix(1))" : "%d \(value.unit)s"
                return (words[key] ?? fallback).replacingOccurrences(of: "%d", with: String(value.count))
            }
            return words[short ? "\(value.unit)_short" : value.unit] ?? value.unit
        }
        func unitsIn(_ value: Period, _ unit: String) -> Double? {
            let factors: [String: [String: Double]] = [
                "day": ["day": 1, "week": 1 / 7, "month": 1 / 30, "year": 1 / 365],
                "week": ["day": 7, "week": 1, "month": 7 * 12 / 365, "year": 7 / 365],
                "month": ["day": 30, "week": 365 / 12 / 7, "month": 1, "year": 1 / 12],
                "year": ["day": 365, "week": 365 / 7, "month": 12, "year": 1],
            ]
            guard let factor = factors[value.unit]?[unit] else { return nil }
            return Double(value.count) * factor
        }
        func amountFor(_ unit: String) -> Int? {
            guard let period, let units = unitsIn(period, unit) else { return nil }
            return Int(units.rounded())
        }
        switch field {
        case "price", "localized_price": return product.localizedPrice ?? price.flatMap(money)
        case "product_id": return product.productId
        case "store_product_name": return product.displayName
        case "currency_code": return currency
        case "currency_symbol":
            guard let currency else { return nil }
            let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = currency
            formatter.locale = Locale(identifier: locale.replacingOccurrences(of: "_", with: "-")); return formatter.currencySymbol
        case "period": return period.map { unitText($0) } ?? ""
        case "period_abbreviated": return period.map { unitText($0, short: true) } ?? ""
        case "periodly":
            guard let period else { return "" }
            if period.count > 1 { return countText(period) }
            return words[["day": "daily", "week": "weekly", "month": "monthly", "year": "yearly"][period.unit] ?? ""] ?? ""
        case "period_with_unit": return period.map(countText) ?? ""
        case "period_in_days", "period_in_weeks", "period_in_months", "period_in_years":
            let unit = field.replacingOccurrences(of: "period_in_", with: "").replacingOccurrences(of: "s", with: "")
            return amountFor(unit).map(String.init) ?? ""
        case "price_per_period", "price_per_period_abbreviated":
            guard let formatted = product.localizedPrice ?? price.flatMap(money) else { return nil }
            guard let period else { return formatted }
            return "\(formatted)/\(unitText(period, short: field.hasSuffix("abbreviated")))"
        case "price_per_day", "price_per_week", "price_per_month", "price_per_year":
            guard let price else { return nil }
            let unit = field.replacingOccurrences(of: "price_per_", with: "")
            guard let period, let units = unitsIn(period, unit), units > 0 else { return money(price) }
            let fractionDigits = currency.flatMap { code -> Int? in
                let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = code
                formatter.locale = Locale(identifier: locale.replacingOccurrences(of: "_", with: "-"))
                return formatter.maximumFractionDigits
            } ?? 2
            let scale = pow(10, Double(max(0, min(6, fractionDigits))))
            let rounded = (price / units * scale).rounded(.down) / scale
            return money(rounded)
        case "offer_price", "offer_price_per_day", "offer_price_per_week", "offer_price_per_month", "offer_price_per_year":
            guard let price else { return nil }
            return trial != nil ? (words["free_price"] ?? "free") : money(price)
        case "offer_price_with_zero": return trial != nil ? money(0) : price.flatMap(money)
        case "offer_period", "offer_period_abbreviated":
            guard let trial else { return "" }
            return unitText((1, trial.unit, trial.days), short: field.hasSuffix("abbreviated"))
        case "offer_period_with_unit": return trial.map(countText) ?? ""
        case "offer_period_in_days", "offer_period_in_weeks", "offer_period_in_months", "offer_period_in_years":
            guard let trial else { return "" }
            let unit = field.replacingOccurrences(of: "offer_period_in_", with: "").replacingOccurrences(of: "s", with: "")
            return unitsIn(trial, unit).map { String(Int($0.rounded())) } ?? ""
        case "relative_discount":
            guard let price, let period, let currency else { return "" }
            let monthly = price / max(1, unitsIn(period, "month") ?? 1)
            let others = peers.compactMap { peer -> Double? in
                guard peer.productId != product.productId, peer.currencyCode == currency, let amount = peer.priceAmount.flatMap(Double.init), let parsed = parse(peer.duration) else { return nil }
                return amount / max(1, unitsIn(parsed, "month") ?? 1)
            }
            guard let highest = others.max(), monthly < highest else { return "" }
            return (words["percent"] ?? "%d%%").replacingOccurrences(of: "%d", with: String(Int(((1 - monthly / highest) * 100).rounded()))).replacingOccurrences(of: "%%", with: "%")
        case "offer_end_date":
            guard let trial else { return "" }
            return "in \(trial.days) day\(trial.days == 1 ? "" : "s")"
        case "secondary_offer_price", "secondary_offer_period", "secondary_offer_period_abbreviated": return ""
        default: return nil
        }
    }

    private func localizedValue(_ key: String, screen: PushifyPaywallScreen) -> String? {
        for locale in [Locale.current.identifier.replacingOccurrences(of: "-", with: "_"), Locale.current.identifier, document.defaultLocale, "en_US"] {
            if case .string(let value)? = screen.localizations[locale]?[key] ?? document.locales[locale]?[key] { return value }
        }
        return nil
    }

    private func runTapActions(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen) {
        let action = object(node.properties["action"]) ?? [:]
        let steps = array(object(action["pushify_actions"])?["on_tap"])
        guard !steps.isEmpty else { handleButton(node, screen: screen); return }
        guard let id = node.id, !id.isEmpty else { message = "This button action sequence has no component id."; return }
        if let active = tapActionRuns[id] {
            guard active.waiting && active.interruptible else { return }
            active.task?.cancel()
            tapActionRuns.removeValue(forKey: id)
        }
        let run = TapActionRun()
        tapActionRuns[id] = run
        run.task = Task {
            for step in steps {
                guard !Task.isCancelled, tapActionRuns[id] === run else { return }
                switch string(step["type"]) {
                case "delay":
                    guard let seconds = number(step["seconds"]), seconds.isFinite, (0...60).contains(seconds), let interruptible = step["interruptible"] else { message = "This delay action is invalid."; tapActionRuns.removeValue(forKey: id); return }
                    guard case .bool(let isInterruptible) = interruptible else { message = "This delay action is invalid."; tapActionRuns.removeValue(forKey: id); return }
                    run.waiting = true
                    run.interruptible = isInterruptible
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                    catch { return }
                    guard !Task.isCancelled, tapActionRuns[id] === run else { return }
                    run.waiting = false
                case "update_variable":
                    updateVariable(step)
                case "navigate_to":
                    openActionLink(step, screen: screen)
                case "set_user_attributes":
                    let configured = object(step["attributes"]) ?? [:]
                    guard !configured.isEmpty else { message = "No user attributes are configured."; tapActionRuns.removeValue(forKey: id); return }
                    let valid = configured.allSatisfy { key, value in
                        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.count <= 100 else { return false }
                        switch value { case .string, .integer, .number, .bool, .null: return true; case .object, .array: return false }
                    }
                    guard valid else { message = "This user attribute is invalid."; tapActionRuns.removeValue(forKey: id); return }
                    do { _ = try await purchases.setAttributes(configured.mapValues(foundationValue)) }
                    catch { message = "User attributes could not be updated. Please try again."; tapActionRuns.removeValue(forKey: id); return }
                case "custom_action":
                    guard let name = string(step["name"]), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "This custom action has no name."; tapActionRuns.removeValue(forKey: id); return }
                    guard let onCustomAction else { message = "This app action is unavailable."; tapActionRuns.removeValue(forKey: id); return }
                    onCustomAction(name.trimmingCharacters(in: .whitespacesAndNewlines))
                case "custom_callback":
                    guard let name = string(step["name"] )?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { message = "This callback has no name."; tapActionRuns.removeValue(forKey: id); return }
                    let callbackArguments = object(step["variables"])?.reduce(into: [String: PushifyJSONValue]()) { result, entry in
                        guard let reference = string(entry.value), reference.hasPrefix("state."), let value = variables[String(reference.dropFirst(6))] else { return }
                        result[entry.key] = value
                    } ?? [:]
                    @MainActor func finishCallback(_ result: PushifyCustomCallbackResult) async {
                        let valid = ["success", "failure"].contains(result.status) && result.data.count <= 20 &&
                              result.data.allSatisfy { key, value in
                                  let safeKey = key.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,99}$"#, options: .regularExpression) != nil
                                  let safeValue: Bool
                                  switch value { case .string(let value): safeValue = value.count <= 500; case .integer(_), .bool(_), .null: safeValue = true; case .number(let value): safeValue = value.isFinite; case .object(_), .array(_): safeValue = false }
                                  return safeKey && safeValue
                              }
                        if !valid { message = "This app callback returned an invalid result." }
                        guard !dismissing else { return }
                        let status = valid ? result.status : "failure"
                        let data = valid ? result.data : [:]
                        callbackData[name] = data
                        let branchSteps = array(step[status == "success" ? "on_success" : "on_failure"])
                        for branch in branchSteps {
                            guard let branchType = string(branch["type"]), !dismissing else { return }
                            switch branchType {
                            case "update_variable": updateVariable(branch)
                            case "navigate_to": openActionLink(branch, screen: screen)
                            case "set_user_attributes":
                                let configured = object(branch["attributes"]) ?? [:]
                                do { _ = try await purchases.setAttributes(configured.mapValues(foundationValue)) }
                                catch { message = "User attributes could not be updated. Please try again."; return }
                            case "custom_action": if let actionName = string(branch["name"]), !actionName.isEmpty { onCustomAction?(actionName) }
                            case "custom_placement": dispatchCustomPlacement(branch)
                            case "delay":
                                guard let seconds = number(branch["seconds"]), seconds.isFinite, (0...60).contains(seconds) else { message = "This callback delay is invalid."; return }
                                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                            default: message = "This callback action is not supported by this SDK version."; return
                            }
                        }
                    }
                    if let onCustomCallback {
                        if string(step["behavior"]) == "non_blocking" {
                            run.pendingCallbackCount += 1
                            let task = Task {
                                do { await finishCallback(try await onCustomCallback(name, callbackArguments)) }
                                catch { message = "This app callback could not be completed. Please try again."; await finishCallback(PushifyCustomCallbackResult(status: "failure")) }
                                run.pendingCallbackCount -= 1
                                if run.terminalFinished && run.pendingCallbackCount == 0 && tapActionRuns[id] === run { tapActionRuns.removeValue(forKey: id) }
                            }
                            run.callbackTasks.append(task)
                        } else {
                            do { await finishCallback(try await onCustomCallback(name, callbackArguments)) }
                            catch { message = "This app callback could not be completed. Please try again."; await finishCallback(PushifyCustomCallbackResult(status: "failure")) }
                            if dismissing { tapActionRuns.removeValue(forKey: id); return }
                        }
                    } else {
                        message = "This app callback is unavailable."
                        await finishCallback(PushifyCustomCallbackResult(status: "failure"))
                        tapActionRuns.removeValue(forKey: id); return
                    }
                case "custom_placement":
                    dispatchCustomPlacement(step)
                default:
                    message = "This tap action is not supported by this SDK version."
                    tapActionRuns.removeValue(forKey: id)
                    return
                }
            }
            guard !Task.isCancelled, tapActionRuns[id] === run else { return }
            handleButton(node, screen: screen)
            run.terminalFinished = true
            if run.pendingCallbackCount == 0 { tapActionRuns.removeValue(forKey: id) }
        }
    }

    private func handleButton(_ node: PushifyPaywallNode, screen: PushifyPaywallScreen) {
        let action = object(node.properties["action"]) ?? [:]
        let kind = string(action["type"]) ?? string(node.properties["action"]) ?? ""
        switch kind {
        case "update_variable": updateVariable(action)
        case "restore_purchases", "restore": restore()
        case "set_user_attributes": setUserAttributes(action)
        case "navigate_to":
            if string(action["destination"]) == "offer_code" { redeemOfferCode() }
            else { openActionLink(action, screen: screen) }
        case "custom_action":
            guard let name = string(action["name"]), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "This custom action has no name."; return }
            guard let onCustomAction else { message = "This app action is unavailable."; return }
            message = nil
            onCustomAction(name.trimmingCharacters(in: .whitespacesAndNewlines))
        case "custom_placement": dispatchCustomPlacement(action)
        case "navigate_back":
            if let index = document.screens.firstIndex(where: { $0.id == screenID }), index > 0 { screenID = document.screens[index - 1].id }
            else { Task { await dismissManually() } }
        case "workflow":
            if case .array(let routes)? = action["routes"], let route = routes.compactMap({ object($0) }).first(where: { matchesRoute($0) }),
               let target = string(route["screen_id"]), document.screens.contains(where: { $0.id == target }) {
                screenID = target
                return
            }
            if let index = document.screens.firstIndex(where: { $0.id == screen.id }), index + 1 < document.screens.count {
                screenID = document.screens[index + 1].id
            } else {
                message = "This flow has no next screen."
            }
        case "close", "close_workflow": Task { await dismissManually() }
        case "purchase", "purchase_with_outcome", "purchase_product": buySelected(packageID: string(action["package_id"]), action: action, screen: screen)
        default:
            if let next = string(node.properties["next_screen_id"]), document.screens.contains(where: { $0.id == next }) { screenID = next }
            else { message = "This button action is not supported by this SDK version." }
        }
    }

    private func dispatchCustomPlacement(_ action: [String: PushifyJSONValue]) {
        guard let rawName = string(action["name"]), !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "This custom placement has no name."; return }
        guard let onCustomPlacement else { message = "This app placement is unavailable."; return }
        let parameters = object(action["parameters"]) ?? [:]
        let valid = parameters.count <= 20 && parameters.allSatisfy { key, value in
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,99}$", options: .regularExpression) != nil else { return false }
            switch value { case .string(let text): return text.count <= 500; case .integer, .number, .bool, .null: return true; case .object, .array: return false }
        }
        guard valid else { message = "This custom placement has invalid parameters."; return }
        message = nil
        onCustomPlacement(rawName.trimmingCharacters(in: .whitespacesAndNewlines), parameters)
    }

    private func redeemOfferCode() {
        if #available(iOS 16.0, *) {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                message = "Offer code redemption is unavailable right now."
                return
            }
            Task {
                do {
                    try await AppStore.presentOfferCodeRedeemSheet(in: scene)
                    // The sheet does not report whether a code was redeemed. Reconcile
                    // transactions after it closes; Transaction.updates handles later delivery.
                    _ = try await purchases.syncPurchases()
                    message = nil
                } catch {
                    message = "Offer code redemption could not be completed."
                }
            }
        } else {
            SKPaymentQueue.default().presentCodeRedemptionSheet()
        }
    }


    private func matchesRoute(_ route: [String: PushifyJSONValue]) -> Bool {
        guard let reference = string(route["variable"]), reference.hasPrefix("state.") else { return false }
        let key = String(reference.dropFirst(6))
        guard let current = variables[key], let expected = route["value"] else { return false }
        switch string(route["operator"]) {
        case "equals": return sameValue(current, expected)
        case "not_equals": return !sameValue(current, expected)
        case "contains": return selectedChoiceValues(current, multiple: true).contains(string(expected) ?? "")
        case "not_contains": return !selectedChoiceValues(current, multiple: true).contains(string(expected) ?? "")
        case "greater_than":
            guard let left = number(current), let right = number(expected) else { return false }
            return left > right
        case "less_than":
            guard let left = number(current), let right = number(expected) else { return false }
            return left < right
        default: return false
        }
    }

    private func visibilityMatches(_ condition: [String: PushifyJSONValue]?) -> Bool {
        guard let condition else { return true }
        guard let mode = string(condition["mode"]), ["all", "any"].contains(mode), case .array(let rules)? = condition["rules"], (1...8).contains(rules.count) else { return true }
        var results: [Bool] = []
        for value in rules {
            guard case .object(let rule) = value, let reference = string(rule["variable"]), reference.hasPrefix("state."),
                  let expected = rule["value"] else { return true }
            let name = String(reference.dropFirst(6))
            let declaration = document.customVariables?[name]
            let systemState = (name == "didCompleteTransaction" || name == "didAbandonTransaction") && declaration == nil
            guard (declaration?.type == "state") || systemState else { return true }
            let current = variables[name] ?? (systemState ? .bool(false) : declaration?.initialValue)
            guard let current else { return true }
            switch string(rule["operator"]) {
            case "equals": results.append(sameValue(current, expected))
            case "not_equals": results.append(!sameValue(current, expected))
            case "contains": results.append(selectedChoiceValues(current, multiple: true).contains(string(expected) ?? ""))
            case "not_contains": results.append(!selectedChoiceValues(current, multiple: true).contains(string(expected) ?? ""))
            case "greater_than": guard let left = number(current), let right = number(expected) else { return true }; results.append(left > right)
            case "less_than": guard let left = number(current), let right = number(expected) else { return true }; results.append(left < right)
            case "greater_than_or_equal": guard let left = number(current), let right = number(expected) else { return true }; results.append(left >= right)
            case "less_than_or_equal": guard let left = number(current), let right = number(expected) else { return true }; results.append(left <= right)
            default: return true
            }
        }
        return mode == "all" ? results.allSatisfy { $0 } : results.contains(true)
    }

    private func number(_ value: PushifyJSONValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .integer(let number): return Double(number)
        default: return nil
        }
    }

    private func selectedChoiceValues(_ value: PushifyJSONValue, multiple: Bool) -> [String] {
        if multiple, case .array(let items) = value { return items.compactMap { string($0) } }
        guard let item = string(value), !item.isEmpty else { return [] }
        return [item]
    }

    private func choiceScore(_ option: [String: PushifyJSONValue], seed: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(seed)
        hasher.combine(string(option["id"]) ?? string(option["value"]) ?? "")
        return hasher.finalize()
    }

    private func sameValue(_ left: PushifyJSONValue, _ right: PushifyJSONValue) -> Bool {
        switch (left, right) {
        case (.string(let a), .string(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.integer(let a), .number(let b)), (.number(let b), .integer(let a)): return Double(a) == b
        case (.bool(let a), .bool(let b)): return a == b
        default: return false
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
        let method = string(url["method"]) ?? "in_app_browser"
        guard let raw, let value = URL(string: raw), let scheme = value.scheme?.lowercased(),
              ["in_app_browser", "external_browser", "deep_link"].contains(method),
              (method == "deep_link"
                ? !["javascript", "data", "file", "content", "intent"].contains(scheme) && (!["http", "https"].contains(scheme) || value.host != nil)
                : ["http", "https"].contains(scheme) && value.host != nil) else {
            message = "This link is unavailable."
            return
        }
        switch method {
        case "in_app_browser": inAppBrowserLink = PushifyBrowserLink(url: value)
        case "external_browser": UIApplication.shared.open(value) { accepted in
            if !accepted { message = "This link could not be opened." }
        }
        default: openURL(value) { accepted in
            if !accepted { message = "This link could not be opened." }
        }
        }
    }

    private func backgroundColor(_ value: PushifyJSONValue?) -> Color {
        guard case .object(let root)? = value, case .object(let valueRoot)? = root["value"],
              case .object(let light)? = valueRoot["light"], case .string(let hex)? = light["value"] else { return Color(uiColor: .systemBackground) }
        return Color(hex: hex)
    }

    private func mediaURL(_ properties: [String: PushifyJSONValue], key: String = "source", dark: Bool = false) -> URL? {
        guard let sources = object(properties[key]),
              let media = object((dark ? sources["dark"] : nil) ?? sources["light"]),
              let rawURL = string(media["url"]) ?? string(media["original"]),
              let url = URL(string: rawURL) else { return nil }
        return url
    }

    @ViewBuilder private func videoUnavailable(_ properties: [String: PushifyJSONValue], dark: Bool) -> some View {
        if let poster = mediaURL(properties, key: "fallback_source", dark: dark) {
            AsyncImage(url: poster) { image in image.resizable().scaledToFill() } placeholder: { videoPlaceholder }
                .clipped()
        } else {
            videoPlaceholder
        }
    }

    private var videoPlaceholder: some View {
        ZStack {
            Color.black
            Image(systemName: "video.slash.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .accessibilityLabel("Video unavailable")
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
    private func colorString(_ value: PushifyJSONValue?, dark: Bool = false) -> String? {
        if case .string(let color)? = value { return color }
        if case .object(let object)? = value {
            let colors = self.object(object["value"]) ?? object
            let selected = (dark ? self.object(colors["dark"]) : nil) ?? self.object(colors["light"])
            if case .string(let color)? = selected?["value"] { return color }
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
    private static func bool(_ value: PushifyJSONValue?, default fallback: Bool = false) -> Bool { if case .bool(let v)? = value { return v }; return fallback }
    private static func packageNodes(_ node: PushifyPaywallNode?) -> [PushifyPaywallNode] {
        guard let node else { return [] }
        return (node.kind == "package" ? [node] : []) + node.children.flatMap(packageNodes)
    }
}

private func isHTTPSOrigin(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && !(url.host?.isEmpty ?? true)
}

private func sameHTTPSOrigin(_ target: URL?, as origin: URL) -> Bool {
    guard let target, isHTTPSOrigin(target), isHTTPSOrigin(origin),
          target.host?.lowercased() == origin.host?.lowercased() else { return false }
    return (target.port ?? 443) == (origin.port ?? 443)
}

private struct PaywallExperienceWebView: View {
    let url: URL
    let fallback: AnyView?
    let onFailure: () -> Void
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        ZStack {
            PaywallExperienceWebViewRepresentable(
                url: url,
                onLoad: { loading = false; failed = false },
                onFailure: { loading = false; failed = true; onFailure() }
            )
            if loading || failed {
                fallback ?? AnyView(
                    Group {
                        if failed {
                            Label("Interactive experience unavailable", systemImage: "web.slash")
                                .font(.footnote).foregroundStyle(.white.opacity(0.8))
                        } else {
                            ProgressView().tint(.white).accessibilityLabel("Loading interactive experience")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                )
            }
        }
    }
}

@MainActor
private struct PaywallExperienceWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let onLoad: () -> Void
    let onFailure: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20))
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator(origin: url, onLoad: onLoad, onFailure: onFailure) }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard view.url != url else { return }
        view.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let origin: URL
        let onLoad: () -> Void
        let onFailure: () -> Void
        init(origin: URL, onLoad: @escaping () -> Void, onFailure: @escaping () -> Void) {
            self.origin = origin
            self.onLoad = onLoad
            self.onFailure = onFailure
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if !isCancelled(error) { onFailure() } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if !isCancelled(error) { onFailure() } }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.targetFrame != nil && sameHTTPSOrigin(navigationAction.request.url, as: origin) ? .allow : .cancel)
        }
        private func isCancelled(_ error: Error) -> Bool {
            let value = error as NSError
            return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
        }
    }
}

private struct PushifyBrowserLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct PushifySafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
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

private struct PushifyMotionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    let x: CGFloat
    let y: CGFloat
    let rotation: Double
    let scale: Double
    let opacity: Double
    let duration: Double
    let delay: Double
    let easing: String
    let content: AnyView

    private var transition: Animation {
        let animation: Animation
        switch easing {
        case "linear": animation = .linear(duration: duration / 1000)
        case "ease_in": animation = .easeIn(duration: duration / 1000)
        case "ease_in_out": animation = .easeInOut(duration: duration / 1000)
        default: animation = .easeOut(duration: duration / 1000)
        }
        return animation.delay(delay / 1000)
    }

    var body: some View {
        content
            .offset(x: !appeared && !reduceMotion ? x : 0, y: !appeared && !reduceMotion ? y : 0)
            .rotationEffect(.degrees(!appeared && !reduceMotion ? rotation : 0))
            .scaleEffect(!appeared && !reduceMotion ? scale : 1)
            .opacity(!appeared && !reduceMotion ? opacity : 1)
            .animation(reduceMotion ? nil : transition, value: appeared)
            .onAppear { appeared = true }
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

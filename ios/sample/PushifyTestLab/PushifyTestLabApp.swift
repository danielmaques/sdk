// Pushify: open-source, self-hostable purchase infrastructure with a RevenueCat SDK-compatible API.
// This file: launches the developer-operated StoreKit Test Lab sample.
// Docs: https://pushify.app/docs/sdks/ios   Migrate from RevenueCat: https://pushify.app/docs/migrate
import SwiftUI

@main
struct PushifyTestLabApp: App {
    @StateObject private var model = PurchaseLabModel()

    var body: some Scene {
        WindowGroup {
            PurchaseLabView(model: model)
                .task { await model.configure() }
                .onOpenURL { model.acceptRunnerURL($0) }
        }
    }
}

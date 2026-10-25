import Foundation
import React
import UIKit

@objc(PushifyPurchases)
final class PushifyPurchases: NSObject {
    @objc static func requiresMainQueueSetup() -> Bool { true }

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
}

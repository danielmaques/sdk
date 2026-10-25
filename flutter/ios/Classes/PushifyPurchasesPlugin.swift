import Flutter
import UIKit

public final class PushifyPurchasesPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "app.pushify/purchases", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(PushifyPurchasesPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "readDeferredToken" else {
            result(FlutterMethodNotImplemented)
            return
        }
        // Call only after the app has explained the pasteboard handoff to the user.
        guard let value = UIPasteboard.general.string,
              value.range(of: #"^rdit_[A-Za-z0-9_-]{30,80}$"#, options: .regularExpression) != nil else {
            result(nil)
            return
        }
        UIPasteboard.general.string = nil
        result(value)
    }
}

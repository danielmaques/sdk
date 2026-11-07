import Flutter
import Foundation
import UIKit
import WebKit

final class PushifyPaywallWebViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier: Int64, arguments args: Any?) -> FlutterPlatformView {
        PushifyPaywallWebViewPlatformView(
            frame: frame,
            viewIdentifier: viewIdentifier,
            messenger: messenger,
            arguments: args as? [String: Any] ?? [:]
        )
    }
}

private final class PushifyPaywallWebViewPlatformView: NSObject, FlutterPlatformView, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let origin: URL
    private let channel: FlutterMethodChannel
    private var clientReady = false
    private var currentStatus = "loading"

    init(frame: CGRect, viewIdentifier: Int64, messenger: FlutterBinaryMessenger, arguments: [String: Any]) {
        let rawURL = arguments["url"] as? String ?? ""
        origin = URL(string: rawURL) ?? URL(string: "https://invalid.pushify.app")!
        channel = FlutterMethodChannel(name: "app.pushify/paywall-web/\(viewIdentifier)", binaryMessenger: messenger)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: frame, configuration: configuration)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(FlutterError(code: "disposed", message: "The WebView is no longer available.", details: nil)); return }
            guard call.method == "ready" else { result(FlutterMethodNotImplemented); return }
            self.clientReady = true
            result(self.currentStatus)
        }

        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        webView.uiDelegate = self

        guard Self.isHTTPSOrigin(origin) else {
            report("failed")
            return
        }
        webView.load(URLRequest(url: origin, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20))
    }

    func view() -> UIView { webView }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame != nil,
              Self.sameHTTPSOrigin(navigationAction.request.url, as: origin) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard Self.sameHTTPSOrigin(webView.url, as: origin) else {
            report("failed")
            return
        }
        report("loaded")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if !Self.isCancellation(error) { report("failed") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !Self.isCancellation(error) { report("failed") }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    deinit {
        channel.setMethodCallHandler(nil)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func report(_ status: String) {
        currentStatus = status
        if clientReady { channel.invokeMethod(status, arguments: nil) }
    }

    private static func isHTTPSOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host?.isEmpty ?? true)
    }

    private static func sameHTTPSOrigin(_ candidate: URL?, as expected: URL) -> Bool {
        guard let candidate, isHTTPSOrigin(candidate), isHTTPSOrigin(expected),
              candidate.host?.lowercased() == expected.host?.lowercased() else { return false }
        return (candidate.port ?? 443) == (expected.port ?? 443)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled
    }
}

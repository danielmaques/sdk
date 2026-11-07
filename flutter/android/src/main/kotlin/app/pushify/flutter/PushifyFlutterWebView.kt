package app.pushify.flutter

import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

internal class PushifyFlutterWebViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        PushifyFlutterWebView(context, viewId, messenger, args as? Map<*, *> ?: emptyMap<Any, Any>())
}

private class PushifyFlutterWebView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
    arguments: Map<*, *>,
) : PlatformView {
    private val origin = Uri.parse(arguments["url"] as? String ?: "")
    private val channel = MethodChannel(messenger, "app.pushify/paywall-web/$viewId")
    private val root = FrameLayout(context).apply { setBackgroundColor(Color.BLACK) }
    private val webView = WebView(context)
    private var clientReady = false
    private var currentStatus = "loading"

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "ready") {
                clientReady = true
                result.success(currentStatus)
            } else result.notImplemented()
        }
        webView.apply {
            setBackgroundColor(Color.TRANSPARENT)
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                allowFileAccess = false
                allowContentAccess = false
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                javaScriptCanOpenWindowsAutomatically = false
                setSupportMultipleWindows(false)
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) safeBrowsingEnabled = true
            }
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                    !sameOrigin(request.url, origin)

                override fun onPageFinished(view: WebView, url: String) {
                    if (sameOrigin(Uri.parse(url), origin)) report("loaded")
                }

                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: android.webkit.WebResourceError) {
                    if (request.isForMainFrame) report("failed")
                }

                override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                    if (request.isForMainFrame && response.statusCode >= 400) report("failed")
                }
            }
        }
        root.addView(webView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        if (isHttpsOrigin(origin)) webView.loadUrl(origin.toString()) else report("failed")
    }

    private fun report(status: String) {
        currentStatus = status
        if (clientReady) channel.invokeMethod(status, null)
    }

    override fun getView(): View = root

    override fun dispose() {
        webView.stopLoading()
        webView.webViewClient = WebViewClient()
        channel.setMethodCallHandler(null)
        root.removeView(webView)
        webView.destroy()
    }

    private fun isHttpsOrigin(uri: Uri): Boolean =
        uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrBlank()

    private fun sameOrigin(candidate: Uri, expected: Uri): Boolean =
        isHttpsOrigin(candidate) && isHttpsOrigin(expected) &&
            candidate.host.equals(expected.host, ignoreCase = true) &&
            effectivePort(candidate) == effectivePort(expected)

    private fun effectivePort(uri: Uri): Int = if (uri.port == -1) 443 else uri.port
}

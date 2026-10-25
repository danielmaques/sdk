package app.pushify.flutter

import android.content.Context
import android.net.Uri
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class PushifyPurchasesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app.pushify/purchases").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "readDeferredToken") {
            readDeferredToken(result)
        } else {
            result.notImplemented()
        }
    }

    private fun readDeferredToken(result: MethodChannel.Result) {
        val appContext = context ?: return result.success(null)
        val client = InstallReferrerClient.newBuilder(appContext).build()
        val completed = AtomicBoolean(false)
        client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                val token = runCatching {
                    if (responseCode != InstallReferrerClient.InstallReferrerResponse.OK) return@runCatching null
                    val referrer = Uri.parse("https://pushify.invalid/?${client.installReferrer.installReferrer}")
                    referrer.getQueryParameter("rdit")?.takeIf { TOKEN.matches(it) }
                }.getOrNull()
                client.endConnection()
                if (completed.compareAndSet(false, true)) result.success(token)
            }

            override fun onInstallReferrerServiceDisconnected() {
                client.endConnection()
                if (completed.compareAndSet(false, true)) result.success(null)
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    private companion object { val TOKEN = Regex("^rdit_[A-Za-z0-9_-]{30,80}$") }
}

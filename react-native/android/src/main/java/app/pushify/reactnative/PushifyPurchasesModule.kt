package app.pushify.reactnative

import android.net.Uri
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import java.util.concurrent.atomic.AtomicBoolean

class PushifyPurchasesModule(context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
    override fun getName(): String = "PushifyPurchases"

    @ReactMethod
    fun readDeferredToken(promise: Promise) {
        val client = InstallReferrerClient.newBuilder(reactApplicationContext).build()
        val completed = AtomicBoolean(false)
        client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                val token = runCatching {
                    if (responseCode != InstallReferrerClient.InstallReferrerResponse.OK) return@runCatching null
                    Uri.parse("https://pushify.invalid/?${client.installReferrer.installReferrer}")
                        .getQueryParameter("rdit")?.takeIf { TOKEN.matches(it) }
                }.getOrNull()
                client.endConnection()
                if (completed.compareAndSet(false, true)) promise.resolve(token)
            }

            override fun onInstallReferrerServiceDisconnected() {
                client.endConnection()
                if (completed.compareAndSet(false, true)) promise.resolve(null)
            }
        })
    }

    private companion object { val TOKEN = Regex("^rdit_[A-Za-z0-9_-]{30,80}$") }
}

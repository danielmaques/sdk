package app.pushify.reactnative

import android.net.Uri
import app.pushify.sdk.PushifyPurchases
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class PushifyPurchasesModule(context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {
    private var purchases: PushifyPurchases? = null
    private var customerListener: PushifyPurchases.CustomerInfoListener? = null
    private var listenerCount = 0
    override fun getName(): String = "PushifyPurchases"

    @ReactMethod
    fun configure(options: ReadableMap, promise: Promise) {
        val key = options.getString("publicApiKey")?.trim().orEmpty()
        val baseUrl = if (options.hasKey("apiBaseUrl")) options.getString("apiBaseUrl") ?: "https://api.pushify.app" else "https://api.pushify.app"
        if (key.isEmpty()) return promise.reject("invalid_configuration", "A Pushify public app key is required.")
        runCatching {
            customerListener?.let { purchases?.removeCustomerInfoListener(it) }
            purchases?.close()
            customerListener = null
            val sdk = PushifyPurchases(reactApplicationContext, key, baseUrl)
            purchases = sdk
            sdk.configure { result -> result.fold(onSuccess = { promise.resolve(toWritableMap(it)) }, onFailure = { reject(promise, it) }) }
        }.onFailure { reject(promise, it) }
    }

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

    @ReactMethod fun customerInfo(promise: Promise) = withPurchases(promise) { it.customerInfo { sendJson(promise, it) } }
    @ReactMethod fun cachedCustomerInfo(promise: Promise) = promise.resolve(purchases?.cachedCustomerInfo()?.let(::toWritableMap))
    @ReactMethod fun offerings(placement: String?, promise: Promise) = withPurchases(promise) { it.offerings(placement) { sendJson(promise, it) } }
    @ReactMethod fun customerCenter(locale: String?, promise: Promise) = withPurchases(promise) { it.customerCenter(locale) { sendJson(promise, it) } }
    @ReactMethod fun createSupportTicket(email: String, message: String, promise: Promise) = withPurchases(promise) { it.createSupportTicket(email, message) { sendJson(promise, it) } }
    @ReactMethod fun identify(customerId: String, promise: Promise) = withPurchases(promise) { it.identify(customerId) { sendJson(promise, it) } }
    @ReactMethod fun logOut(promise: Promise) = withPurchases(promise) { it.logOut { sendJson(promise, it) } }
    @ReactMethod fun restorePurchases(promise: Promise) = withPurchases(promise) { it.restorePurchases { sendJson(promise, it) } }
    @ReactMethod fun syncPurchases(promise: Promise) = withPurchases(promise) { it.syncPurchases { sendJson(promise, it) } }

    @ReactMethod
    fun setAttributes(attributes: ReadableMap, promise: Promise) = withPurchases(promise) { sdk ->
        sdk.setAttributes(JSONObject(attributes.toHashMap())) { sendJson(promise, it) }
    }

    @ReactMethod
    fun purchase(packageId: String, promise: Promise) {
        val sdk = purchases ?: return promise.reject("not_configured", "Call configure before using Pushify purchases.")
        val activity = currentActivity ?: return promise.reject("activity_unavailable", "Purchases require a foreground Android Activity.")
        sdk.purchase(activity, packageId) { result ->
            result.fold(onSuccess = { outcome ->
                when (outcome) {
                    is PushifyPurchases.PurchaseOutcome.Purchased -> promise.resolve(Arguments.makeNativeMap(mapOf("status" to "purchased", "customerInfo" to toWritableMap(outcome.customer))))
                    PushifyPurchases.PurchaseOutcome.Pending -> promise.resolve(Arguments.makeNativeMap(mapOf("status" to "pending")))
                    PushifyPurchases.PurchaseOutcome.Cancelled -> promise.resolve(Arguments.makeNativeMap(mapOf("status" to "cancelled")))
                }
            }, onFailure = { reject(promise, it) })
        }
    }

    @ReactMethod
    fun logEvent(name: String, properties: ReadableMap, eventId: String?, promise: Promise) = withPurchases(promise) { sdk ->
        sdk.logEvent(name, JSONObject(properties.toHashMap()), eventId ?: UUID.randomUUID().toString()) { result ->
            result.fold(onSuccess = { promise.resolve(it) }, onFailure = { reject(promise, it) })
        }
    }

    @ReactMethod
    fun spendVirtualCurrency(adjustments: ReadableMap, idempotencyKey: String, reference: String?, promise: Promise) = withPurchases(promise) { sdk ->
        sdk.spendVirtualCurrency(JSONObject(adjustments.toHashMap()), idempotencyKey, reference) { sendJson(promise, it) }
    }

    @ReactMethod fun addListener(eventName: String) { listenerCount++; if (listenerCount == 1) listenForCustomerUpdates() }
    @ReactMethod fun removeListeners(count: Int) { listenerCount = (listenerCount - count).coerceAtLeast(0); if (listenerCount == 0) stopListening() }

    private fun listenForCustomerUpdates() {
        val sdk = purchases ?: return
        val listener = PushifyPurchases.CustomerInfoListener { snapshot -> emit("customerInfoUpdated", toWritableMap(snapshot)) }
        customerListener = listener
        sdk.addCustomerInfoListener(listener)
        sdk.cachedCustomerInfo()?.let { emit("customerInfoUpdated", toWritableMap(it)) }
    }

    private fun stopListening() {
        customerListener?.let { purchases?.removeCustomerInfoListener(it) }
        customerListener = null
    }

    private fun emit(name: String, body: WritableMap) {
        if (reactApplicationContext.hasActiveCatalystInstance()) {
            reactApplicationContext.getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java).emit(name, body)
        }
    }

    private inline fun withPurchases(promise: Promise, operation: (PushifyPurchases) -> Unit) {
        val sdk = purchases
        if (sdk == null) promise.reject("not_configured", "Call configure before using Pushify purchases.") else operation(sdk)
    }

    private fun sendJson(promise: Promise, result: Result<JSONObject>) = result.fold(
        onSuccess = { promise.resolve(toWritableMap(it)) }, onFailure = { reject(promise, it) },
    )

    private fun reject(promise: Promise, error: Throwable) {
        val apiError = error as? PushifyPurchases.PushifyApiException
        promise.reject(apiError?.code ?: "pushify_error", error.message ?: "Pushify request failed.", error)
    }

    private fun toWritableMap(value: JSONObject): WritableMap {
        val map = mutableMapOf<String, Any?>()
        val keys = value.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            map[key] = toNative(value.opt(key))
        }
        return Arguments.makeNativeMap(map)
    }

    private fun toNative(value: Any?): Any? = when (value) {
        is JSONObject -> toWritableMap(value)
        is JSONArray -> Arguments.makeNativeArray((0 until value.length()).map { toNative(value.opt(it)) })
        JSONObject.NULL -> null
        else -> value
    }

    override fun onCatalystInstanceDestroy() {
        stopListening()
        purchases?.close()
        purchases = null
        super.onCatalystInstanceDestroy()
    }

    private companion object { val TOKEN = Regex("^rdit_[A-Za-z0-9_-]{30,80}$") }
}

package app.pushify.flutter

import android.app.Activity
import android.content.Context
import android.net.Uri
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import app.pushify.sdk.PushifyPurchases
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

class PushifyPurchasesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    EventChannel.StreamHandler {
    private var channel: MethodChannel? = null
    private var events: EventChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var purchases: PushifyPurchases? = null
    private var eventSink: EventChannel.EventSink? = null
    private var customerListener: PushifyPurchases.CustomerInfoListener? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app.pushify/purchases").also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "app.pushify/customer-info").also { it.setStreamHandler(this) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> configure(call, result)
            "readDeferredToken" -> readDeferredToken(result)
            "customerInfo" -> withPurchases(result) { it.customerInfo { sendJson(result, it) } }
            "cachedCustomerInfo" -> result.success(purchases?.cachedCustomerInfo()?.let(::toFlutter))
            "offerings" -> withPurchases(result) { it.offerings { sendJson(result, it) } }
            "identify" -> withPurchases(result) { sdk -> sdk.identify(call.argument<String>("customerId").orEmpty()) { sendJson(result, it) } }
            "logOut" -> withPurchases(result) { it.logOut { sendJson(result, it) } }
            "setAttributes" -> withPurchases(result) { sdk ->
                val attributes = call.argument<Map<String, Any?>>("attributes") ?: emptyMap()
                sdk.setAttributes(JSONObject(attributes)) { sendJson(result, it) }
            }
            "restorePurchases", "syncPurchases" -> withPurchases(result) { it.syncPurchases { sendJson(result, it) } }
            "purchase" -> purchase(call, result)
            "logEvent" -> withPurchases(result) { sdk ->
                val props = JSONObject(call.argument<Map<String, Any?>>("properties") ?: emptyMap<String, Any?>())
                sdk.logEvent(call.argument<String>("name").orEmpty(), props, call.argument<String>("eventId") ?: java.util.UUID.randomUUID().toString()) { outcome ->
                    outcome.fold(onSuccess = { result.success(it) }, onFailure = { sendError(result, it) })
                }
            }
            "spendVirtualCurrency" -> withPurchases(result) { sdk ->
                val adjustments = JSONObject(call.argument<Map<String, Int>>("adjustments") ?: emptyMap<String, Int>())
                sdk.spendVirtualCurrency(adjustments, call.argument<String>("idempotencyKey").orEmpty(), call.argument("reference")) { sendJson(result, it) }
            }
            else -> result.notImplemented()
        }
    }

    private fun configure(call: MethodCall, result: MethodChannel.Result) {
        val appContext = context ?: return result.error("not_ready", "The Pushify plugin is not attached.", null)
        val key = call.argument<String>("publicApiKey")?.trim().orEmpty()
        val baseUrl = call.argument<String>("apiBaseUrl") ?: "https://api.pushify.app"
        if (key.isEmpty()) return result.error("invalid_configuration", "A Pushify public app key is required.", null)
        runCatching {
            customerListener?.let { purchases?.removeCustomerInfoListener(it) }
            customerListener = null
            purchases = PushifyPurchases(appContext, key, baseUrl).also { sdk ->
                sdk.configure { outcome -> sendJson(result, outcome) }
            }
        }.onFailure { sendError(result, it) }
    }

    private fun purchase(call: MethodCall, result: MethodChannel.Result) {
        val sdk = purchases ?: return result.error("not_configured", "Call configure before purchasing.", null)
        val currentActivity = activity ?: return result.error("activity_unavailable", "Purchases require a foreground Android Activity.", null)
        sdk.purchase(currentActivity, call.argument<String>("packageId").orEmpty()) { outcome ->
            outcome.fold(onSuccess = { value ->
                when (value) {
                    is PushifyPurchases.PurchaseOutcome.Purchased -> result.success(mapOf("status" to "purchased", "customerInfo" to toFlutter(value.customer)))
                    PushifyPurchases.PurchaseOutcome.Pending -> result.success(mapOf("status" to "pending"))
                    PushifyPurchases.PurchaseOutcome.Cancelled -> result.success(mapOf("status" to "cancelled"))
                }
            }, onFailure = { sendError(result, it) })
        }
    }

    private inline fun withPurchases(result: MethodChannel.Result, block: (PushifyPurchases) -> Unit) {
        val sdk = purchases
        if (sdk == null) result.error("not_configured", "Call configure before using Pushify purchases.", null)
        else block(sdk)
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

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
        val sdk = purchases ?: return
        val listener = PushifyPurchases.CustomerInfoListener { snapshot -> sink.success(toFlutter(snapshot)) }
        customerListener = listener
        sdk.addCustomerInfoListener(listener)
        sdk.cachedCustomerInfo()?.let { sink.success(toFlutter(it)) }
    }

    override fun onCancel(arguments: Any?) {
        customerListener?.let { purchases?.removeCustomerInfoListener(it) }
        customerListener = null
        eventSink = null
    }

    private fun sendJson(result: MethodChannel.Result, outcome: Result<JSONObject>) = outcome.fold(
        onSuccess = { result.success(toFlutter(it)) }, onFailure = { sendError(result, it) },
    )

    private fun sendError(result: MethodChannel.Result, error: Throwable) {
        val apiError = error as? PushifyPurchases.PushifyApiException
        result.error(apiError?.code ?: "pushify_error", error.message ?: "Pushify request failed.", mapOf("status" to apiError?.status, "retryable" to apiError?.retryable))
    }

    private fun toFlutter(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { key -> toFlutter(value.opt(key)) }
        is JSONArray -> (0 until value.length()).map { toFlutter(value.opt(it)) }
        JSONObject.NULL -> null
        else -> value
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivity() { activity = null }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onCancel(null)
        channel?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        channel = null
        events = null
        purchases = null
        context = null
    }

    private companion object { val TOKEN = Regex("^rdit_[A-Za-z0-9_-]{30,80}$") }
}

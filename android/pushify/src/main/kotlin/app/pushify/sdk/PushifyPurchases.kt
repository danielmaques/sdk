package app.pushify.sdk

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ConsumeParams
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.ForkJoinPool

/** First-party Google Play Billing client for the Pushify SDK API. */
public class PushifyPurchases(
    context: Context,
    private val publicApiKey: String,
    apiBaseUrl: String = "https://api.pushify.app",
    private val executor: Executor = ForkJoinPool.commonPool(),
) : PurchasesUpdatedListener {
    private val appContext = context.applicationContext
    private val endpoint = apiBaseUrl.trimEnd('/')
    private val main = Handler(Looper.getMainLooper())
    private val prefs = appContext.getSharedPreferences("app.pushify.purchases", Context.MODE_PRIVATE)
    private val identityKey = "customer_${appContext.packageName}"
    private var customerId: String? = prefs.getString(identityKey, null)
    private var lastSnapshot: JSONObject? = null
    private var pendingPurchaseCompletion: ((Result<PurchaseOutcome>) -> Unit)? = null
    private var pendingOffer: StorePackage? = null
    private val billing = BillingClient.newBuilder(appContext)
        .setListener(this)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .build()

    init {
        require(publicApiKey.isNotBlank()) { "A Pushify public app key is required." }
        require(URL(endpoint).protocol == "https") { "Pushify API URL must use HTTPS." }
    }

    /** Connects Play Billing, bootstraps the stable customer, and retries owned transactions. */
    public fun configure(completion: (Result<JSONObject>) -> Unit) {
        billing.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    post(completion, Result.failure(error("billing_unavailable", result.debugMessage, true)))
                    return
                }
                customerInfo { customer ->
                    customer.fold(onSuccess = { bootstrap ->
                        lastSnapshot = bootstrap
                        syncOwnedPurchases { sync -> post(completion, sync) }
                    }, onFailure = { post(completion, Result.failure(it)) })
                }
            }
            override fun onBillingServiceDisconnected() { /* BillingClient reconnects on the next operation. */ }
        })
    }

    public fun customerInfo(completion: (Result<JSONObject>) -> Unit) {
        val id = ensureCustomerId()
        request("/sdk/v1/customers/bootstrap", "POST", JSONObject().put("customer_id", id), completion)
    }

    public fun offerings(completion: (Result<JSONObject>) -> Unit) = request("/sdk/v1/offerings", "GET", null, completion)

    public fun identify(newCustomerId: String, completion: (Result<JSONObject>) -> Unit) {
        if (newCustomerId.isBlank() || newCustomerId.length > 100) {
            post(completion, Result.failure(error("invalid_customer_id", "Customer ID must contain 1–100 characters.", false)))
            return
        }
        val oldId = ensureCustomerId()
        request("/sdk/v1/customers/identify", "POST", JSONObject().put("current_customer_id", oldId).put("new_customer_id", newCustomerId)) { result ->
            result.onSuccess { customerId = newCustomerId; prefs.edit().putString(identityKey, newCustomerId).apply(); lastSnapshot = it }
            completion(result)
        }
    }

    public fun setAttributes(attributes: JSONObject, completion: (Result<JSONObject>) -> Unit) {
        val id = encodePath(ensureCustomerId())
        request("/sdk/v1/customers/$id/attributes", "PATCH", JSONObject().put("attributes", attributes), completion)
    }

    /** Starts the native Google Play purchase sheet for the package selected from [offerings]. */
    public fun purchase(activity: Activity, packageId: String, completion: (Result<PurchaseOutcome>) -> Unit) {
        if (pendingPurchaseCompletion != null) {
            completion(Result.failure(error("purchase_in_progress", "A purchase is already in progress.", false)))
            return
        }
        offerings { result -> result.fold(onSuccess = { body ->
            val storePackage = findPackage(body, packageId)
            if (storePackage == null) {
                completion(Result.failure(error("package_unavailable", "The requested package is not in the current offering.", false)))
                return@fold
            }
            queryDetails(storePackage) { detailResult -> detailResult.fold(onSuccess = { details ->
                pendingOffer = storePackage
                pendingPurchaseCompletion = completion
                val productParams = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(details)
                selectOfferToken(details, storePackage)?.let(productParams::setOfferToken)
                val flow = BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(productParams.build())).build()
                val launch = billing.launchBillingFlow(activity, flow)
                if (launch.responseCode != BillingClient.BillingResponseCode.OK) {
                    val callback = pendingPurchaseCompletion
                    pendingPurchaseCompletion = null
                    pendingOffer = null
                    callback?.let { post(it, Result.failure(error("billing_flow_failed", launch.debugMessage, launch.responseCode == BillingClient.BillingResponseCode.SERVICE_DISCONNECTED))) }
                }
            }, onFailure = { completion(Result.failure(it)) })
        }, onFailure = { completion(Result.failure(it)) }) }
    }

    /** Restores and syncs current subscriptions and one-time products owned by this Play account. */
    public fun restorePurchases(completion: (Result<JSONObject>) -> Unit) = syncOwnedPurchases(completion)

    public fun cachedCustomerInfo(): JSONObject? = lastSnapshot?.let { JSONObject(it.toString()) }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                val items = purchases.orEmpty()
                if (items.isEmpty()) return completePurchase(Result.failure(error("empty_purchase_result", "Google Play returned no purchase data.", true)))
                if (items.any { it.purchaseState == Purchase.PurchaseState.PENDING }) return completePurchase(Result.success(PurchaseOutcome.Pending))
                val purchase = items.firstOrNull { it.purchaseState == Purchase.PurchaseState.PURCHASED }
                    ?: return completePurchase(Result.failure(error("invalid_purchase_state", "Google Play returned an unsupported purchase state.", true)))
                syncPurchase(purchase, pendingOffer) { sync ->
                    sync.onSuccess { lastSnapshot = it }
                    completePurchase(sync.map { PurchaseOutcome.Purchased(it) })
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED -> completePurchase(Result.success(PurchaseOutcome.Cancelled))
            else -> completePurchase(Result.failure(error("billing_error", result.debugMessage, result.responseCode == BillingClient.BillingResponseCode.SERVICE_DISCONNECTED)))
        }
    }

    private fun completePurchase(result: Result<PurchaseOutcome>) {
        val completion = pendingPurchaseCompletion
        pendingPurchaseCompletion = null
        pendingOffer = null
        completion?.let { post(it, result) }
    }

    private fun syncOwnedPurchases(completion: (Result<JSONObject>) -> Unit) {
        if (!billing.isReady) return post(completion, Result.failure(error("billing_unavailable", "Google Play Billing is not connected.", true)))
        val found = mutableListOf<Purchase>()
        var remaining = 2
        var failed: Throwable? = null
        listOf(BillingClient.ProductType.SUBS, BillingClient.ProductType.INAPP).forEach { type ->
            billing.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(type).build()) { result, items ->
                synchronized(found) {
                    if (result.responseCode == BillingClient.BillingResponseCode.OK) found.addAll(items)
                    else failed = error("purchase_query_failed", result.debugMessage, result.responseCode == BillingClient.BillingResponseCode.SERVICE_DISCONNECTED)
                    remaining--
                    if (remaining == 0) {
                        val error = failed
                        if (error != null) post(completion, Result.failure(error))
                        else syncList(found.distinctBy { it.purchaseToken }, 0, completion)
                    }
                }
            }
        }
    }

    private fun syncList(items: List<Purchase>, index: Int, completion: (Result<JSONObject>) -> Unit) {
        if (index >= items.size) return customerInfo { refreshed -> refreshed.onSuccess { lastSnapshot = it }; completion(refreshed) }
        val purchase = items[index]
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) return syncList(items, index + 1, completion)
        syncPurchase(purchase, null) { result -> result.fold(onSuccess = { syncList(items, index + 1, completion) }, onFailure = { post(completion, Result.failure(it)) }) }
    }

    private fun syncPurchase(purchase: Purchase, knownPackage: StorePackage?, completion: (Result<JSONObject>) -> Unit) {
        val productId = purchase.products.firstOrNull()
        if (productId == null) return post(completion, Result.failure(error("invalid_purchase", "Google Play purchase contains no product ID.", false)))
        val selected = knownPackage ?: StorePackage("", productId, null, null)
        val body = JSONObject().put("customer_id", ensureCustomerId()).put("product_id", productId).put("proof", purchase.purchaseToken)
        selected.planId?.let { body.put("plan_id", it) }
        request("/sdk/v1/transactions/sync", "POST", body) { result ->
            result.fold(onSuccess = { snapshot ->
                val accepted: (Result<Unit>) -> Unit = { fulfillment ->
                    fulfillment.fold(onSuccess = { post(completion, Result.success(snapshot)) }, onFailure = { post(completion, Result.failure(it)) })
                }
                if (selected.type == "consumable") consume(purchase, accepted) else acknowledge(purchase, accepted)
            }, onFailure = { post(completion, Result.failure(it)) })
        }
    }

    private fun acknowledge(purchase: Purchase, completion: (Result<Unit>) -> Unit) {
        if (purchase.isAcknowledged) return post(completion, Result.success(Unit))
        billing.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build()) { result ->
            val outcome = if (result.responseCode == BillingClient.BillingResponseCode.OK) Result.success(Unit)
            else Result.failure(error("acknowledgement_failed", result.debugMessage, true))
            post(completion, outcome)
        }
    }

    private fun consume(purchase: Purchase, completion: (Result<Unit>) -> Unit) {
        billing.consumeAsync(ConsumeParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build()) { result, _ ->
            val outcome = if (result.responseCode == BillingClient.BillingResponseCode.OK) Result.success(Unit)
            else Result.failure(error("consumption_failed", result.debugMessage, true))
            post(completion, outcome)
        }
    }

    private fun queryDetails(item: StorePackage, completion: (Result<ProductDetails>) -> Unit) {
        val type = if (item.type == "subscription" || item.planId != null) BillingClient.ProductType.SUBS else BillingClient.ProductType.INAPP
        val params = QueryProductDetailsParams.newBuilder().setProductList(listOf(
            QueryProductDetailsParams.Product.newBuilder().setProductId(item.productId).setProductType(type).build(),
        )).build()
        billing.queryProductDetailsAsync(params) { result, details ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) return@queryProductDetailsAsync post(completion, Result.failure(error("product_query_failed", result.debugMessage, true)))
            val product = details.productDetailsList.firstOrNull() ?: return@queryProductDetailsAsync post(completion, Result.failure(error("product_unavailable", "The product is unavailable in Google Play.", false)))
            post(completion, Result.success(product))
        }
    }

    private fun selectOfferToken(details: ProductDetails, item: StorePackage): String? {
        val subscription = details.subscriptionOfferDetails.orEmpty()
        val matched = subscription.firstOrNull { it.basePlanId == item.planId && (item.offerId == null || it.offerId == item.offerId) }
        return matched?.offerToken ?: subscription.firstOrNull()?.offerToken
            ?: details.oneTimePurchaseOfferDetailsList?.firstOrNull()?.offerToken
    }

    private data class StorePackage(val id: String, val productId: String, val planId: String?, val offerId: String?, val type: String? = null)

    private fun findPackage(body: JSONObject, wanted: String): StorePackage? {
        val offerings = body.optJSONArray("offerings") ?: return null
        for (i in 0 until offerings.length()) {
            val packages = offerings.optJSONObject(i)?.optJSONArray("packages") ?: continue
            for (j in 0 until packages.length()) {
                val item = packages.optJSONObject(j) ?: continue
                if (item.optString("id") != wanted) continue
                val product = item.optJSONObject("product") ?: return null
                return StorePackage(wanted, product.optString("product_id"), product.optString("plan_id").takeIf { it.isNotBlank() && it != "null" }, product.optString("offer_id").takeIf { it.isNotBlank() && it != "null" }, product.optString("type").takeIf { it.isNotBlank() && it != "null" })
            }
        }
        return null
    }

    private fun ensureCustomerId(): String {
        customerId?.let { return it }
        val generated = "\$PushifyAnonymousID:${UUID.randomUUID()}"
        customerId = generated
        prefs.edit().putString(identityKey, generated).apply()
        return generated
    }

    private fun request(path: String, method: String, body: JSONObject?, completion: (Result<JSONObject>) -> Unit) {
        executor.execute {
            val result = runCatching {
                val connection = (URL("$endpoint$path").openConnection() as HttpURLConnection).apply {
                    requestMethod = method
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    setRequestProperty("Authorization", "Bearer $publicApiKey")
                    setRequestProperty("Accept", "application/json")
                    if (body != null) { doOutput = true; setRequestProperty("Content-Type", "application/json") }
                }
                try {
                    body?.let { connection.outputStream.use { stream -> stream.write(it.toString().toByteArray(StandardCharsets.UTF_8)) } }
                    val status = connection.responseCode
                    val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                    val text = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
                    if (status !in 200..299) {
                        val info = runCatching { JSONObject(text).getJSONObject("error") }.getOrNull()
                        throw PushifyApiException(status, info?.optString("code", "http_error") ?: "http_error", info?.optString("message", "Pushify API request failed.") ?: "Pushify API request failed.", info?.optBoolean("retryable", status >= 500) ?: (status >= 500))
                    }
                    JSONObject(text)
                } finally { connection.disconnect() }
            }
            post(completion, result)
        }
    }

    private fun <T> post(completion: (Result<T>) -> Unit, result: Result<T>) = main.post { completion(result) }
    private fun error(code: String, message: String?, retryable: Boolean) = PushifyApiException(0, code, message ?: code, retryable)
    private fun encodePath(value: String) = java.net.URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")

    public sealed interface PurchaseOutcome {
        public data class Purchased(val customer: JSONObject) : PurchaseOutcome
        public data object Pending : PurchaseOutcome
        public data object Cancelled : PurchaseOutcome
    }

    public class PushifyApiException(public val status: Int, public val code: String, override val message: String, public val retryable: Boolean) : Exception(message)

    private companion object { const val TIMEOUT_MS = 20_000 }
}

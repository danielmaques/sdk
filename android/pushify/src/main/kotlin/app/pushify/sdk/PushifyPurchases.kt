package app.pushify.sdk

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
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
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.util.concurrent.CopyOnWriteArraySet
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
    private val snapshotKey = "snapshot_${appContext.packageName}"
    private val offeringsKey = "offerings_${appContext.packageName}"
    private val keystoreAlias = "app.pushify.sdk.${appContext.packageName}"
    private var customerId: String? = prefs.getString(identityKey, null)
    private var lastSnapshot: JSONObject? = readCachedSnapshot()
    private var lastOfferings: JSONObject? = readCachedOfferings()
    private val customerInfoListeners = CopyOnWriteArraySet<CustomerInfoListener>()
    private var pendingPurchaseCompletion: ((Result<PurchaseOutcome>) -> Unit)? = null
    private var pendingOffer: StorePackage? = null
    private val billing = BillingClient.newBuilder(appContext)
        .setListener(this)
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
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
                    val cached = cachedCustomerInfo()
                    if (cached != null) post(completion, Result.success(cached))
                    else post(completion, Result.failure(error("billing_unavailable", result.debugMessage, true)))
                    return
                }
                customerInfo { customer ->
                    customer.fold(onSuccess = { bootstrap ->
                        syncOwnedPurchases { sync ->
                            sync.fold(onSuccess = { post(completion, Result.success(it)) }, onFailure = { failure ->
                                cachedCustomerInfo()?.let { post(completion, Result.success(it)) } ?: post(completion, Result.failure(failure))
                            })
                        }
                    }, onFailure = { failure ->
                        cachedCustomerInfo()?.let { post(completion, Result.success(it)) } ?: post(completion, Result.failure(failure))
                    })
                }
            }
            override fun onBillingServiceDisconnected() { /* BillingClient reconnects on the next operation. */ }
        })
    }

    public fun customerInfo(completion: (Result<JSONObject>) -> Unit) {
        val id = ensureCustomerId()
        request("/sdk/v1/customers/bootstrap", "POST", JSONObject().put("customer_id", id)) { result ->
            result.onSuccess(::publishSnapshot)
            completion(result)
        }
    }

    public fun offerings(placement: String? = null, completion: (Result<JSONObject>) -> Unit) {
        val query = buildList {
            add("customer_id=${java.net.URLEncoder.encode(ensureCustomerId(), "UTF-8")}")
            placement?.takeIf(String::isNotBlank)?.let { add("placement=${java.net.URLEncoder.encode(it, "UTF-8")}") }
        }.joinToString("&")
        request("/sdk/v1/offerings?$query", "GET", null) { result ->
            result.fold(onSuccess = { hydrateOfferingPrices(it, completion) }, onFailure = { failure ->
                val cached = lastOfferings?.let { JSONObject(it.toString()) }
                if (cached != null) post(completion, Result.success(cached)) else post(completion, Result.failure(failure))
            })
        }
    }

    private data class ProductQuery(val productId: String, val productType: String)

    private fun hydrateOfferingPrices(body: JSONObject, completion: (Result<JSONObject>) -> Unit) {
        if (!billing.isReady) {
            val cached = lastOfferings?.let { JSONObject(it.toString()) }
            if (cached != null) return post(completion, Result.success(cached))
            return post(completion, Result.failure(error("billing_unavailable", "Connect Google Play Billing before loading localized prices.", true)))
        }
        val queries = mutableListOf<ProductQuery>()
        val offerings = body.optJSONArray("offerings") ?: JSONArray()
        for (i in 0 until offerings.length()) {
            val packages = offerings.optJSONObject(i)?.optJSONArray("packages") ?: continue
            for (j in 0 until packages.length()) {
                val product = packages.optJSONObject(j)?.optJSONObject("product") ?: continue
                val id = product.optString("product_id").takeIf(String::isNotBlank) ?: continue
                val type = if (product.optString("type") == "subscription" || product.optString("plan_id").isNotBlank()) BillingClient.ProductType.SUBS else BillingClient.ProductType.INAPP
                queries += ProductQuery(id, type)
            }
        }
        val unique = queries.distinctBy { "${it.productType}:${it.productId}" }
        val groups = unique.groupBy { it.productType }.toList()
        val details = mutableMapOf<String, ProductDetails>()
        queryOfferingProductGroup(groups, 0, details) { failure ->
            if (failure != null) post(completion, Result.failure(failure))
            else {
                val enriched = enrichOfferingBody(body, details)
                lastOfferings = JSONObject(enriched.toString())
                runCatching { encrypt(enriched.toString()) }.onSuccess { prefs.edit().putString(offeringsKey, it).apply() }
                post(completion, Result.success(enriched))
            }
        }
    }

    private fun queryOfferingProductGroup(
        groups: List<Pair<String, List<ProductQuery>>>,
        groupIndex: Int,
        details: MutableMap<String, ProductDetails>,
        completion: (Throwable?) -> Unit,
    ) {
        if (groupIndex >= groups.size) return completion(null)
        val (productType, queries) = groups[groupIndex]
        queryOfferingProductChunk(productType, queries, 0, details) { failure ->
            if (failure != null) completion(failure)
            else queryOfferingProductGroup(groups, groupIndex + 1, details, completion)
        }
    }

    private fun queryOfferingProductChunk(
        productType: String,
        queries: List<ProductQuery>,
        start: Int,
        details: MutableMap<String, ProductDetails>,
        completion: (Throwable?) -> Unit,
    ) {
        if (start >= queries.size) return completion(null)
        val chunk = queries.drop(start).take(20)
        val params = QueryProductDetailsParams.newBuilder().setProductList(chunk.map { query ->
            QueryProductDetailsParams.Product.newBuilder().setProductId(query.productId).setProductType(productType).build()
        }).build()
        billing.queryProductDetailsAsync(params) { result, response ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                completion(error("product_query_failed", result.debugMessage, result.responseCode == BillingClient.BillingResponseCode.SERVICE_DISCONNECTED))
                return@queryProductDetailsAsync
            }
            response.productDetailsList.forEach { details["$productType:${it.productId}"] = it }
            queryOfferingProductChunk(productType, queries, start + chunk.size, details, completion)
        }
    }

    private fun enrichOfferingBody(body: JSONObject, details: Map<String, ProductDetails>): JSONObject {
        val enriched = JSONObject(body.toString())
        val offerings = enriched.optJSONArray("offerings") ?: return enriched
        for (i in 0 until offerings.length()) {
            val packages = offerings.optJSONObject(i)?.optJSONArray("packages") ?: continue
            for (j in 0 until packages.length()) {
                val item = packages.optJSONObject(j) ?: continue
                val product = item.optJSONObject("product") ?: continue
                val productId = product.optString("product_id")
                val planId = product.optString("plan_id").takeIf { it.isNotBlank() && it != "null" }
                val type = if (product.optString("type") == "subscription" || planId != null) BillingClient.ProductType.SUBS else BillingClient.ProductType.INAPP
                val native = details["$type:$productId"] ?: continue
                product.put("display_name", native.name)
                if (type == BillingClient.ProductType.SUBS) {
                    val offer = native.subscriptionOfferDetails.orEmpty().firstOrNull { it.basePlanId == planId }
                    if (offer != null) {
                        product.put("offer_token", offer.offerToken)
                        val phases = JSONArray()
                        offer.pricingPhases.pricingPhaseList.forEach { phase ->
                            phases.put(JSONObject()
                                .put("formatted_price", phase.formattedPrice)
                                .put("price_amount_micros", phase.priceAmountMicros.toString())
                                .put("currency_code", phase.priceCurrencyCode)
                                .put("billing_period", phase.billingPeriod)
                                .put("recurrence_mode", phase.recurrenceMode)
                                .put("billing_cycle_count", phase.billingCycleCount))
                        }
                        product.put("pricing_phases", phases)
                        offer.pricingPhases.pricingPhaseList.firstOrNull()?.let { phase ->
                            product.put("localized_price", phase.formattedPrice)
                            product.put("price_amount", java.math.BigDecimal.valueOf(phase.priceAmountMicros, 6).stripTrailingZeros().toPlainString())
                            product.put("currency_code", phase.priceCurrencyCode)
                        }
                    }
                } else {
                    native.oneTimePurchaseOfferDetailsList?.firstOrNull()?.let { price ->
                        product.put("localized_price", price.formattedPrice)
                        product.put("price_amount", java.math.BigDecimal.valueOf(price.priceAmountMicros, 6).stripTrailingZeros().toPlainString())
                        product.put("currency_code", price.priceCurrencyCode)
                    }
                }
            }
        }
        return enriched
    }

    public fun identify(newCustomerId: String, completion: (Result<JSONObject>) -> Unit) {
        if (newCustomerId.isBlank() || newCustomerId.length > 100) {
            post(completion, Result.failure(error("invalid_customer_id", "Customer ID must contain 1–100 characters.", false)))
            return
        }
        val oldId = ensureCustomerId()
        request("/sdk/v1/customers/identify", "POST", JSONObject().put("current_customer_id", oldId).put("new_customer_id", newCustomerId)) { result ->
            result.onSuccess { customerId = newCustomerId; prefs.edit().putString(identityKey, newCustomerId).apply(); publishSnapshot(it) }
            completion(result)
        }
    }

    public fun setAttributes(attributes: JSONObject, completion: (Result<JSONObject>) -> Unit) {
        val id = encodePath(ensureCustomerId())
        request("/sdk/v1/customers/$id/attributes", "PATCH", JSONObject().put("attributes", attributes), completion)
    }

    /** Fetches the customer's localized Pushify Customer Center configuration. */
    public fun customerCenter(locale: String? = null, completion: (Result<JSONObject>) -> Unit) {
        val id = encodePath(ensureCustomerId())
        val query = locale?.takeIf(String::isNotBlank)?.let { "?locale=${java.net.URLEncoder.encode(it, "UTF-8")}" } ?: ""
        request("/sdk/v1/customers/$id/customer-center$query", "GET", null, completion)
    }

    /** Submits a Customer Center ticket subject to the project's configured support policy. */
    public fun createSupportTicket(email: String, message: String, completion: (Result<JSONObject>) -> Unit) {
        if (email.isBlank() || email.length > 320 || message.isBlank() || message.length > 5000) {
            post(completion, Result.failure(error("invalid_ticket", "A valid email and a message of at most 5,000 characters are required.", false)))
            return
        }
        val id = encodePath(ensureCustomerId())
        request("/sdk/v1/customers/$id/customer-center/tickets", "POST", JSONObject().put("email", email).put("message", message), completion)
    }

    /** Sends a customer event. Pass the same event ID again when retrying the same logical event. */
    public fun logEvent(name: String, properties: JSONObject = JSONObject(), eventId: String = UUID.randomUUID().toString(), completion: (Result<Int>) -> Unit) {
        if (name.isBlank() || name.length > 64 || eventId.isBlank() || eventId.length > 64) {
            post(completion, Result.failure(error("invalid_event", "Event name and ID must contain 1–64 characters.", false)))
            return
        }
        val event = JSONObject(properties.toString())
            .put("id", eventId)
            .put("type", name)
            .put("customer_id", ensureCustomerId())
            .put("occurred_at_ms", System.currentTimeMillis())
        request("/sdk/v1/events", "POST", JSONObject().put("events", JSONArray().put(event))) { result ->
            post(completion, result.map { it.optInt("accepted") })
        }
    }

    /** Atomically spends virtual currencies using a stable Idempotency-Key. */
    public fun spendVirtualCurrency(adjustments: JSONObject, idempotencyKey: String, reference: String? = null, completion: (Result<JSONObject>) -> Unit) {
        if (adjustments.length() == 0 || idempotencyKey.isBlank() || idempotencyKey.length > 200) {
            post(completion, Result.failure(error("invalid_spend", "Provide currency adjustments and an idempotency key.", false)))
            return
        }
        val id = encodePath(ensureCustomerId())
        val body = JSONObject().put("adjustments", adjustments)
        if (reference != null) body.put("reference", reference)
        request("/sdk/v1/customers/$id/virtual-currencies/spends", "POST", body, mapOf("Idempotency-Key" to idempotencyKey), completion)
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
                val offerToken = selectOfferToken(details, storePackage)
                if ((storePackage.type == "subscription" || storePackage.planId != null) && offerToken == null) {
                    completion(Result.failure(error("offer_unavailable", "The selected Google Play subscription plan is not available.", false)))
                    return@fold
                }
                pendingOffer = storePackage
                pendingPurchaseCompletion = completion
                val productParams = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(details)
                offerToken?.let(productParams::setOfferToken)
                val flow = BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(productParams.build())).build()
                val launch = billing.launchBillingFlow(activity, flow)
                if (launch.responseCode != BillingClient.BillingResponseCode.OK) {
                    val callback = pendingPurchaseCompletion
                    pendingPurchaseCompletion = null
                    pendingOffer = null
                    callback?.let { post(it, Result.failure(error("billing_flow_failed", launch.debugMessage, launch.responseCode == BillingClient.BillingResponseCode.SERVICE_DISCONNECTED))) }
                }
            }, onFailure = { completion(Result.failure(it)) }) }
        }, onFailure = { completion(Result.failure(it)) }) }
    }

    /** Restores and syncs current subscriptions and one-time products owned by this Play account. */
    public fun restorePurchases(completion: (Result<JSONObject>) -> Unit) = syncOwnedPurchases(completion)

    /** Reconciles current Play ownership without showing purchase UI. */
    public fun syncPurchases(completion: (Result<JSONObject>) -> Unit) = syncOwnedPurchases(completion)

    /** Starts a fresh anonymous customer without deleting server-side transaction history. */
    public fun logOut(completion: (Result<JSONObject>) -> Unit) {
        customerId = null
        lastSnapshot = null
        prefs.edit().remove(identityKey).remove(snapshotKey).apply()
        customerInfo(completion)
    }

    public fun addCustomerInfoListener(listener: CustomerInfoListener) { customerInfoListeners.add(listener) }
    public fun removeCustomerInfoListener(listener: CustomerInfoListener) { customerInfoListeners.remove(listener) }

    public fun close() {
        customerInfoListeners.clear()
        billing.endConnection()
    }

    public fun cachedCustomerInfo(): JSONObject? = lastSnapshot?.let { JSONObject(it.toString()) }

    private fun publishSnapshot(snapshot: JSONObject) {
        val copy = JSONObject(snapshot.toString())
        lastSnapshot = copy
        runCatching { encrypt(copy.toString()) }.onSuccess { prefs.edit().putString(snapshotKey, it).apply() }
        customerInfoListeners.forEach { listener -> runCatching { listener.onCustomerInfoUpdated(JSONObject(copy.toString())) } }
    }

    private fun readCachedSnapshot(): JSONObject? = runCatching {
        prefs.getString(snapshotKey, null)?.let { JSONObject(decrypt(it)) }
    }.getOrNull()

    private fun readCachedOfferings(): JSONObject? = runCatching {
        prefs.getString(offeringsKey, null)?.let { JSONObject(decrypt(it)) }
    }.getOrNull()

    private fun encrypt(plaintext: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val ciphertext = cipher.doFinal(plaintext.toByteArray(StandardCharsets.UTF_8))
        return Base64.encodeToString(cipher.iv + ciphertext, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String): String {
        val payload = Base64.decode(encoded, Base64.NO_WRAP)
        require(payload.size > GCM_IV_BYTES) { "Invalid Pushify cache entry." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(GCM_TAG_BITS, payload, 0, GCM_IV_BYTES))
        return String(cipher.doFinal(payload, GCM_IV_BYTES, payload.size - GCM_IV_BYTES), StandardCharsets.UTF_8)
    }

    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(keystoreAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(keystoreAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build())
        return generator.generateKey()
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                val items = purchases.orEmpty()
                if (items.isEmpty()) return completePurchase(Result.failure(error("empty_purchase_result", "Google Play returned no purchase data.", true)))
                val purchased = items.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }.distinctBy { it.purchaseToken }
                if (purchased.isEmpty()) {
                    return if (items.any { it.purchaseState == Purchase.PurchaseState.PENDING }) completePurchase(Result.success(PurchaseOutcome.Pending))
                    else completePurchase(Result.failure(error("invalid_purchase_state", "Google Play returned an unsupported purchase state.", true)))
                }
                syncPurchaseCallbackItems(purchased, 0, null)
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

    private fun syncPurchaseCallbackItems(items: List<Purchase>, index: Int, latest: JSONObject?) {
        if (index >= items.size) {
            val finish: (Result<JSONObject>) -> Unit = { refreshed ->
                refreshed.fold(onSuccess = { snapshot ->
                    publishSnapshot(snapshot)
                    completePurchase(Result.success(PurchaseOutcome.Purchased(snapshot)))
                }, onFailure = { failure ->
                    val snapshot = latest
                    if (snapshot != null) completePurchase(Result.success(PurchaseOutcome.Purchased(snapshot)))
                    else completePurchase(Result.failure(failure))
                })
            }
            return customerInfo(finish)
        }
        val purchase = items[index]
        val matchingOffer = pendingOffer?.takeIf { it.productId in purchase.products }
        syncPurchase(purchase, matchingOffer) { result ->
            result.fold(
                onSuccess = { snapshot -> syncPurchaseCallbackItems(items, index + 1, snapshot) },
                onFailure = { failure -> completePurchase(Result.failure(failure)) },
            )
        }
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
        if (index >= items.size) return customerInfo { refreshed -> refreshed.onSuccess(::publishSnapshot); completion(refreshed) }
        val purchase = items[index]
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) return syncList(items, index + 1, completion)
        syncPurchase(purchase, null) { result -> result.fold(onSuccess = { syncList(items, index + 1, completion) }, onFailure = { post(completion, Result.failure(it)) }) }
    }

    private fun syncPurchase(purchase: Purchase, knownPackage: StorePackage?, completion: (Result<JSONObject>) -> Unit) {
        val productId = purchase.products.firstOrNull()
        if (productId == null) return post(completion, Result.failure(error("invalid_purchase", "Google Play purchase contains no product ID.", false)))
        val selected = knownPackage?.takeIf { it.productId == productId } ?: StorePackage("", productId, null, null)
        val body = JSONObject().put("customer_id", ensureCustomerId()).put("product_id", productId).put("proof", purchase.purchaseToken)
        selected.planId?.let { body.put("plan_id", it) }
        request("/sdk/v1/transactions/sync", "POST", body) { result ->
            result.fold(onSuccess = { snapshot ->
                val accepted: (Result<Unit>) -> Unit = { fulfillment ->
                    fulfillment.fold(onSuccess = { post(completion, Result.success(snapshot)) }, onFailure = { post(completion, Result.failure(it)) })
                }
                val products = snapshot.optJSONArray("synced_products")
                val verified = (0 until (products?.length() ?: 0))
                    .mapNotNull { products?.optJSONObject(it) }
                    .firstOrNull { it.optString("product_id") == productId }
                val isConsumable = verified?.optBoolean("is_consumable") ?: (selected.type == "consumable")
                if (isConsumable) consume(purchase, accepted) else acknowledge(purchase, accepted)
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
        if (item.type == "subscription" || item.planId != null) {
            val matched = subscription.firstOrNull { it.basePlanId == item.planId && (item.offerId == null || it.offerId == item.offerId) }
            return matched?.offerToken
        }
        return details.oneTimePurchaseOfferDetailsList?.firstOrNull()?.offerToken
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

    private fun request(path: String, method: String, body: JSONObject?, completion: (Result<JSONObject>) -> Unit) =
        request(path, method, body, emptyMap(), completion)

    private fun request(path: String, method: String, body: JSONObject?, headers: Map<String, String>, completion: (Result<JSONObject>) -> Unit) {
        executor.execute {
            val result = runCatching {
                val connection = (URL("$endpoint$path").openConnection() as HttpURLConnection).apply {
                    requestMethod = method
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    setRequestProperty("Authorization", "Bearer $publicApiKey")
                    setRequestProperty("Accept", "application/json")
                    setRequestProperty("X-Platform", "android")
                    setRequestProperty("X-Preferred-Locales", java.util.Locale.getDefault().toLanguageTag())
                    headers.forEach { (name, value) -> setRequestProperty(name, value) }
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

    private fun <T> post(completion: (Result<T>) -> Unit, result: Result<T>) { main.post { completion(result) } }
    private fun error(code: String, message: String?, retryable: Boolean) = PushifyApiException(0, code, message ?: code, retryable)
    private fun encodePath(value: String) = java.net.URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")

    public sealed interface PurchaseOutcome {
        public data class Purchased(val customer: JSONObject) : PurchaseOutcome
        public data object Pending : PurchaseOutcome
        public data object Cancelled : PurchaseOutcome
    }

    public fun interface CustomerInfoListener { public fun onCustomerInfoUpdated(snapshot: JSONObject) }

    public class PushifyApiException(public val status: Int, public val code: String, override val message: String, public val retryable: Boolean) : Exception(message)

    private companion object {
        const val TIMEOUT_MS = 20_000
        const val GCM_IV_BYTES = 12
        const val GCM_TAG_BITS = 128
    }
}

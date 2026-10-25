package app.pushify.sdk

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

/** A resolved Pushify acquisition link. The host app decides how to navigate to [destination]. */
public data class AcquisitionLink(
    public val status: String,
    public val linkId: String,
    public val name: String,
    public val slug: String,
    public val destination: String,
    public val appScheme: String,
    public val campaign: Map<String, String>,
    public val attributed: Boolean,
)

/** Resolves opaque link tokens using the public app key configured for this Pushify project. */
public class AcquisitionLinks(
    private val publicApiKey: String,
    apiBaseUrl: String = "https://api.pushify.app",
    private val executor: Executor = java.util.concurrent.ForkJoinPool.commonPool(),
) {
    private val endpoint = URL("${apiBaseUrl.trimEnd('/')}/v1/acquisition_links/resolve")
    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        require(publicApiKey.isNotBlank()) { "A Pushify public app key is required." }
        require(endpoint.protocol == "https") { "Pushify API URL must use HTTPS." }
    }

    /** Extracts the direct token (`rdt`) from an incoming Pushify app URL. */
    public fun tokenFromUrl(url: String): String? = try {
        val token = Uri.parse(url).getQueryParameter("rdt")
        token?.takeIf { TOKEN.matches(it) }
    } catch (_: Exception) {
        null
    }

    /** Extracts and resolves a direct URL in one call. Returns false when [url] is not a Pushify link. */
    public fun resolveUrl(
        url: String,
        appUserId: String? = null,
        completion: (Result<AcquisitionLink>) -> Unit,
    ): Boolean {
        val token = tokenFromUrl(url) ?: return false
        resolve(token, appUserId, completion)
        return true
    }

    /** Reads the opaque deferred token delivered by Google Play after an install. */
    public fun deferredToken(context: Context, completion: (String?) -> Unit) {
        val client = InstallReferrerClient.newBuilder(context.applicationContext).build()
        val completed = AtomicBoolean(false)
        client.startConnection(object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                val token = runCatching {
                    if (responseCode != InstallReferrerClient.InstallReferrerResponse.OK) return@runCatching null
                    val referrer = Uri.parse("https://pushify.invalid/?${client.installReferrer.installReferrer}")
                    referrer.getQueryParameter("rdit")?.takeIf { TOKEN.matches(it) }
                }.getOrNull()
                client.endConnection()
                if (completed.compareAndSet(false, true)) completion(token)
            }

            override fun onInstallReferrerServiceDisconnected() {
                client.endConnection()
                if (completed.compareAndSet(false, true)) completion(null)
            }
        })
    }

    /** Reads and resolves the Google Play deferred link in one call. */
    public fun resolveDeferred(
        context: Context,
        appUserId: String? = null,
        completion: (Result<AcquisitionLink>) -> Unit,
    ) {
        deferredToken(context) { token ->
            if (token == null) {
                mainHandler.post {
                    completion(Result.failure(NoDeferredAcquisitionLinkException()))
                }
            } else {
                resolve(token, appUserId, completion)
            }
        }
    }

    /** Resolves a direct or deferred token. Supplying [appUserId] associates an identified customer. */
    public fun resolve(
        token: String,
        appUserId: String? = null,
        completion: (Result<AcquisitionLink>) -> Unit,
    ) {
        require(TOKEN.matches(token)) { "The acquisition-link token is invalid." }
        executor.execute {
            val result = runCatching { resolveBlocking(token, appUserId) }
            mainHandler.post { completion(result) }
        }
    }

    private fun resolveBlocking(token: String, appUserId: String?): AcquisitionLink {
        val connection = (endpoint.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = TIMEOUT_MS
            readTimeout = TIMEOUT_MS
            doOutput = true
            setRequestProperty("Authorization", "Bearer $publicApiKey")
            setRequestProperty("Content-Type", "application/json")
        }
        try {
            val body = JSONObject().put("token", token).apply {
                if (!appUserId.isNullOrBlank()) put("app_user_id", appUserId)
            }.toString()
            connection.outputStream.use { it.write(body.toByteArray(StandardCharsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val response = stream?.use { readLimited(it) }.orEmpty()
            check(status in 200..299) { "Pushify acquisition-link resolution failed (HTTP $status)." }
            val json = JSONObject(response)
            val campaignJson = json.optJSONObject("campaign") ?: JSONObject()
            val campaign = campaignJson.keys().asSequence().associateWith { campaignJson.optString(it) }
            return AcquisitionLink(
                status = json.getString("status"),
                linkId = json.getString("link_id"),
                name = json.getString("name"),
                slug = json.getString("slug"),
                destination = json.getString("destination"),
                appScheme = json.getString("app_scheme"),
                campaign = campaign,
                attributed = json.optBoolean("attributed"),
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun readLimited(stream: InputStream): String {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (true) {
            val count = stream.read(buffer)
            if (count < 0) break
            require(output.size() + count <= MAX_RESPONSE_BYTES) { "Pushify response is too large." }
            output.write(buffer, 0, count)
        }
        return output.toString(StandardCharsets.UTF_8.name())
    }

    private companion object {
        val TOKEN = Regex("^(rdlt|rdit)_[A-Za-z0-9_-]{30,80}$")
        const val TIMEOUT_MS = 10_000
        const val MAX_RESPONSE_BYTES = 65_536
    }
}

/** There was no supported deferred acquisition token for this app launch. */
public class NoDeferredAcquisitionLinkException : Exception("No deferred Pushify link was found.")

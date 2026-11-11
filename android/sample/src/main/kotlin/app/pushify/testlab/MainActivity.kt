// Pushify: open-source, self-hostable alternative to RevenueCat. Same SDK API.
// This file: runs explicit Play sandbox purchase, restore and entitlement-refresh actions for the Test Lab.
// Docs: https://pushify.app/docs/sdks/android   Migrate from RevenueCat: https://pushify.app/docs/migrate
package app.pushify.testlab

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import app.pushify.sdk.PushifyPurchases
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

class MainActivity : Activity() {
    private lateinit var sdk: PushifyPurchases
    private lateinit var status: TextView
    private lateinit var packageList: LinearLayout
    private lateinit var reportView: TextView
    private var catalog: JSONObject? = null
    private var ready = false
    private var pendingRunnerIntent: Intent? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildScreen()
        val key = BuildConfig.PUSHIFY_PUBLIC_APP_KEY
        if (key.isBlank()) {
            status.text = "Build with -PPUSHIFY_PUBLIC_APP_KEY=<public app key>. This key is public and belongs to a sandbox app."
            return
        }
        sdk = PushifyPurchases(this, key, BuildConfig.PUSHIFY_API_BASE_URL)
        sdk.enableDebugInspector(true)
        status.text = "Connecting to Pushify…"
        sdk.configure { result ->
            result.fold(
                onSuccess = {
                    ready = true
                    status.text = "Connected. Choose a package or run restore and entitlement refresh."
                    loadOfferings()
                    pendingRunnerIntent?.let { pendingRunnerIntent = null; executeRunnerIntent(it) }
                },
                onFailure = { status.text = "SDK setup failed: ${it.message ?: "unknown error"}"; record("configure", "failed") },
            )
        }
        queueRunnerIntent(intent)
        showSavedReport()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        queueRunnerIntent(intent)
    }

    override fun onDestroy() {
        if (::sdk.isInitialized) sdk.close()
        super.onDestroy()
    }

    private fun buildScreen() {
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(20, 24, 20, 24)
        }
        content.addFullWidth(TextView(this).apply { text = "Pushify Purchase Test Lab"; textSize = 24f; setTypeface(null, Typeface.BOLD) })
        content.addFullWidth(TextView(this).apply {
            text = "Uses the current device's Google Play sandbox account. Store actions are developer-operated; this app cannot create Play transactions remotely."
            textSize = 14f
            setPadding(0, 8, 0, 12)
        })
        status = TextView(this).apply { textSize = 14f; setPadding(0, 8, 0, 12) }
        content.addFullWidth(status)
        content.addFullWidth(Button(this).apply { text = "Refresh offerings"; setOnClickListener { loadOfferings() } })
        content.addFullWidth(Button(this).apply { text = "Restore purchases"; setOnClickListener { restore() } })
        content.addFullWidth(Button(this).apply { text = "Refresh entitlements"; setOnClickListener { sync() } })
        packageList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(0, 8, 0, 8) }
        content.addFullWidth(packageList)
        content.addFullWidth(Button(this).apply { text = "Copy redacted run report"; setOnClickListener { copyReport() } })
        reportView = TextView(this).apply { textSize = 12f; typeface = Typeface.MONOSPACE; setTextIsSelectable(true); setPadding(0, 12, 0, 0) }
        content.addFullWidth(reportView)
        val scroll = ScrollView(this).apply { addView(content) }
        setContentView(scroll)
    }

    private fun loadOfferings() {
        if (!requireReady()) return
        sdk.offerings { result -> result.fold(
            onSuccess = { value -> catalog = value; renderPackages(); status.text = "Offerings loaded from Pushify."; record("offerings_refresh", "passed"); showSavedReport() },
            onFailure = { status.text = "Offerings failed: ${it.message ?: "unknown error"}"; record("offerings_refresh", "failed") },
        ) }
    }

    private fun renderPackages() {
        packageList.removeAllViews()
        val offerings = catalog?.optJSONArray("offerings") ?: JSONArray()
        for (i in 0 until offerings.length()) {
            val packages = offerings.optJSONObject(i)?.optJSONArray("packages") ?: continue
            for (j in 0 until packages.length()) {
                val item = packages.optJSONObject(j) ?: continue
                val id = item.optString("id").takeIf(String::isNotBlank) ?: continue
                val productId = item.optJSONObject("product")?.optString("product_id") ?: "Unknown product"
                packageList.addView(Button(this).apply { text = "Buy $productId"; setOnClickListener { purchase(id) } })
            }
        }
        if (packageList.childCount == 0) packageList.addView(TextView(this).apply { text = "No packages. Check the sandbox app's published offering and store products." })
    }

    private fun purchase(packageId: String) {
        if (!requireReady()) return
        status.text = "Waiting for the Google Play purchase sheet…"
        sdk.purchase(this, packageId) { result -> result.fold(
            onSuccess = { outcome ->
                val state = when (outcome) {
                    is PushifyPurchases.PurchaseOutcome.Purchased -> "purchased"
                    PushifyPurchases.PurchaseOutcome.Pending -> "pending"
                    PushifyPurchases.PurchaseOutcome.Cancelled -> "cancelled"
                }
                status.text = "Purchase result: $state"
                record("purchase", state)
            },
            onFailure = { status.text = "Purchase failed: ${it.message ?: "unknown error"}"; record("purchase", "failed") },
        ) }
    }

    private fun restore() = runSdkAction("restore") { done -> sdk.restorePurchases { result -> done(result) } }
    private fun sync() = runSdkAction("entitlement_refresh") { done -> sdk.syncPurchases { result -> done(result) } }

    private fun runSdkAction(name: String, action: (((Result<JSONObject>) -> Unit) -> Unit)) {
        if (!requireReady()) return
        status.text = "Running $name…"
        action { result -> result.fold(
            onSuccess = { status.text = "$name completed."; record(name, "passed") },
            onFailure = { status.text = "$name failed: ${it.message ?: "unknown error"}"; record(name, "failed") },
        ) }
    }

    private fun queueRunnerIntent(intent: Intent?) {
        if (intent?.hasExtra("pushify_scenario") != true) return
        if (!ready) {
            pendingRunnerIntent = intent
            return
        }
        executeRunnerIntent(intent)
    }

    private fun executeRunnerIntent(intent: Intent) {
        val scenario = intent.getStringExtra("pushify_scenario") ?: return
        val packageId = intent.getStringExtra("pushify_package_id")
        status.post { status.text = "CLI requested $scenario" }
        when (scenario) {
            "offerings_refresh" -> loadOfferings()
            "restore" -> restore()
            "entitlement_refresh" -> sync()
            "purchase" -> if (packageId.isNullOrBlank()) {
                record("purchase", "failed")
            } else purchase(packageId)
            else -> record(scenario, "unsupported")
        }
    }

    private fun requireReady(): Boolean {
        if (!::sdk.isInitialized || !ready) status.text = "Wait for SDK setup to finish first."
        return ::sdk.isInitialized && ready
    }

    private fun record(scenario: String, outcome: String) {
        val report = readReport()
        val operations = report.optJSONArray("operations") ?: JSONArray()
        val operation = JSONObject()
            .put("scenario", scenario)
            .put("status", when (outcome) {
                "passed", "purchased" -> "passed"
                "cancelled" -> "cancelled"
                "pending" -> "pending"
                else -> "failed"
            })
            .put("outcome", outcome)
            .put("occurred_at", System.currentTimeMillis())
            .put("correlation_ids", diagnosticCorrelationIds())
        operations.put(operation)
        report.put("schema", "pushify.mobile-test-run/v1")
            .put("environment", "play_sandbox")
            .put("platform", "android")
            .put("operations", operations)
        writeReport(report)
        showSavedReport()
    }

    private fun diagnosticCorrelationIds(): JSONArray {
        val ids = JSONArray()
        val events = sdk.debugExport()?.optJSONArray("events") ?: return ids
        for (i in 0 until events.length()) {
            val id = events.optJSONObject(i)?.optString("correlation_id")?.takeIf(String::isNotBlank) ?: continue
            ids.put(id)
        }
        return ids
    }

    private fun readReport(): JSONObject = runCatching { JSONObject(File(filesDir, REPORT_FILE).readText()) }
        .getOrElse { JSONObject().put("run_id", UUID.randomUUID().toString()).put("operations", JSONArray()) }

    private fun writeReport(report: JSONObject) {
        runCatching { File(filesDir, REPORT_FILE).writeText(report.toString()) }
            .onFailure { status.text = "Could not save the local run report." }
    }

    private fun showSavedReport() { if (::reportView.isInitialized) reportView.text = readReport().toString(2) }

    private fun copyReport() {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Pushify test report", readReport().toString(2)))
        status.text = "Redacted run report copied."
    }

    private fun LinearLayout.addFullWidth(view: android.view.View) = addView(view, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

    companion object { private const val REPORT_FILE = "pushify-test-run.json" }
}

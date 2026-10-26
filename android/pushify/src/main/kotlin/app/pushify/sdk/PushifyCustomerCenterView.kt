package app.pushify.sdk

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject

/** Native Android view for published Customer Center configuration and store actions. */
public class PushifyCustomerCenterView @JvmOverloads constructor(
    context: Context,
    private val purchases: PushifyPurchases,
    private val onCustomAction: ((String) -> Unit)? = null,
) : ScrollView(context) {
    private val main = android.os.Handler(android.os.Looper.getMainLooper())
    private val root = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(20), dp(20), dp(20))
        gravity = Gravity.CENTER_HORIZONTAL
    }
    private var configuration: JSONObject? = null
    private var customer: JSONObject? = null
    private var busy = false

    init {
        isFillViewport = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        addView(root, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        load()
    }

    private fun load() {
        busy = true
        root.removeAllViews()
        root.addView(TextView(context).apply { text = "Loading Customer Center…"; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }, lp(MATCH, WRAP))
        purchases.customerCenter { result ->
            result.fold(onSuccess = { response ->
                val config = response.optJSONObject("configuration")
                if (config == null) return@fold showError()
                purchases.customerInfo { customerResult ->
                    customerResult.fold(onSuccess = { snapshot ->
                        configuration = config
                        customer = snapshot
                        busy = false
                        main.post(::render)
                    }, onFailure = { showError() })
                }
            }, onFailure = { showError() })
        }
    }

    private fun render() {
        root.removeAllViews()
        val config = configuration ?: return showError()
        val snapshot = customer ?: return showError()
        val active = snapshot.optJSONObject("entitlements")?.optJSONArray("active")?.length()?.let { it > 0 } ?: false
        val screen = config.optJSONObject("screens")?.optJSONObject(if (active) "MANAGEMENT" else "NO_ACTIVE") ?: JSONObject()
        root.addView(TextView(context).apply { text = screen.optString("title", "Manage subscription"); textSize = 24f; setTypeface(typeface, android.graphics.Typeface.BOLD); contentDescription = text }, lp(MATCH, WRAP))
        screen.optString("subtitle").takeIf(String::isNotBlank)?.let { subtitle ->
            root.addView(TextView(context).apply { text = subtitle; textSize = 16f; setPadding(0, dp(8), 0, dp(12)) }, lp(MATCH, WRAP))
        }
        val paths = screen.optJSONArray("paths") ?: JSONArray()
        for (index in 0 until paths.length()) {
            val path = paths.optJSONObject(index) ?: continue
            root.addView(android.widget.Button(context).apply {
                text = path.optString("title", "Continue")
                contentDescription = text
                isEnabled = !busy
                setOnClickListener { perform(path) }
            }, lp(MATCH, WRAP))
        }
        val support = config.optJSONObject("support") ?: JSONObject()
        val policy = support.optJSONObject("support_tickets") ?: JSONObject()
        if (policy.optBoolean("allow_creation")) {
            root.addView(android.widget.Button(context).apply {
                text = config.optJSONObject("localization")?.optJSONObject("localized_strings")?.optString("contact_support", "Contact support") ?: "Contact support"
                setOnClickListener { showTicketDialog() }
            }, lp(MATCH, WRAP))
        }
    }

    private fun perform(path: JSONObject) {
        if (busy) return
        when (path.optString("type")) {
            "MISSING_PURCHASE" -> {
                busy = true
                purchases.restorePurchases { result -> result.fold(onSuccess = { main.post(::load) }, onFailure = { showError() }) }
            }
            "CANCEL" -> open("https://play.google.com/store/account/subscriptions")
            "REFUND_REQUEST" -> open("https://play.google.com/store/account/orderhistory")
            "CUSTOM_URL" -> open(path.optString("url"))
            "CUSTOM_ACTION" -> path.optString("action_identifier").takeIf(String::isNotBlank)?.let {
                if (onCustomAction != null) onCustomAction.invoke(it) else showMessage("This account action is not available.")
            }
        }
    }

    private fun open(raw: String) {
        val uri = runCatching { Uri.parse(raw) }.getOrNull()
        val scheme = uri?.scheme?.lowercase()
        if (uri == null || scheme.isNullOrBlank() || scheme in setOf("javascript", "data", "file", "blob", "about")) return showError()
        runCatching {
            val intent = Intent(Intent.ACTION_VIEW, uri)
            if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }.onFailure { showError() }
    }

    private fun showTicketDialog() {
        val fields = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), 0, dp(20), 0) }
        val email = EditText(context).apply { hint = "Email"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS }
        val message = EditText(context).apply { hint = "How can we help?"; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE; minLines = 3; maxLines = 6 }
        fields.addView(email, lp(MATCH, WRAP)); fields.addView(message, lp(MATCH, WRAP))
        AlertDialog.Builder(context).setTitle("Contact support").setView(fields)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Send", null)
            .create().also { dialog ->
                dialog.setOnShowListener {
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                        val emailValue = email.text.toString().trim()
                        val messageValue = message.text.toString().trim()
                        if (!emailValue.contains('@') || messageValue.isEmpty()) {
                            email.error = if (!emailValue.contains('@')) "Enter a valid email." else null
                            message.error = if (messageValue.isEmpty()) "Enter a message." else null
                            return@setOnClickListener
                        }
                        purchases.createSupportTicket(emailValue, messageValue) { result ->
                            result.fold(onSuccess = { main.post(::load) }, onFailure = { showError() })
                        }
                        dialog.dismiss()
                    }
                }
                dialog.show()
            }
    }

    private fun showError() {
        busy = false
        main.post {
            root.removeAllViews()
            root.addView(TextView(context).apply { text = "Customer Center is unavailable."; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }, lp(MATCH, WRAP))
            root.addView(android.widget.Button(context).apply { text = "Try again"; setOnClickListener { load() } }, lp(MATCH, WRAP))
        }
    }

    private fun showMessage(value: String) {
        main.post {
            root.addView(TextView(context).apply {
                text = value
                accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            }, lp(MATCH, WRAP))
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
    private fun lp(width: Int, height: Int) = LinearLayout.LayoutParams(width, height)
    private companion object { const val MATCH = LayoutParams.MATCH_PARENT; const val WRAP = LayoutParams.WRAP_CONTENT }
}

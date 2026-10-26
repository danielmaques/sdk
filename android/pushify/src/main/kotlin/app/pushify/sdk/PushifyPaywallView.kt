package app.pushify.sdk

import android.app.Activity
import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/** Native Android renderer for the core Pushify paywall component set. */
public class PushifyPaywallView @JvmOverloads constructor(
    context: Context,
    private val document: JSONObject,
    private val offering: JSONObject,
    private val purchases: PushifyPurchases,
    private val onDismiss: (() -> Unit)? = null,
) : ScrollView(context) {
    private val main = Handler(Looper.getMainLooper())
    private val imageExecutor = Executors.newFixedThreadPool(2)
    private val packages = offering.optJSONArray("packages") ?: JSONArray()
    private var selectedPackageId: String = findDefault(document.optJSONArray("screens")?.optJSONObject(0)?.optJSONObject("content"))
        ?: packages.optJSONObject(0)?.optString("id").orEmpty()
    private var activeScreenId: String = document.optJSONArray("screens")?.optJSONObject(0)?.optString("id").orEmpty()
    private val strings = document.optJSONObject("locales") ?: JSONObject()
    private val screens = document.optJSONArray("screens") ?: JSONArray()
    private var busy = false

    init {
        isFillViewport = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        render()
    }

    private fun render() {
        removeAllViews()
        val screen = (0 until screens.length()).mapNotNull(screens::optJSONObject).firstOrNull { it.optString("id") == activeScreenId }
            ?: screens.optJSONObject(0) ?: return
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(16))
            gravity = Gravity.CENTER_HORIZONTAL
            setBackgroundColor(backgroundColor(screen.optJSONObject("background")))
        }
        onDismiss?.let { close ->
            val row = LinearLayout(context).apply { gravity = Gravity.END }
            row.addView(Button(context).apply { text = "Close"; contentDescription = "Close paywall"; setOnClickListener { close() } }, lp(WRAP, dp(48)))
            root.addView(row, lp(MATCH, WRAP))
        }
        screen.optJSONObject("content")?.let { root.addView(renderNode(it, screen), lp(MATCH, 0, 1f)) }
        screen.optJSONObject("footer")?.let { root.addView(renderNode(it, screen), lp(MATCH, WRAP)) }
        addView(root, LayoutParams(MATCH, MATCH))
    }

    private fun renderNode(node: JSONObject, screen: JSONObject): View {
        val kind = node.optString("kind")
        val properties = node.optJSONObject("properties") ?: JSONObject()
        val children = node.optJSONArray("children") ?: JSONArray()
        return when (kind) {
            "stack", "hstack" -> LinearLayout(context).apply {
                orientation = if (kind == "hstack") LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
                gravity = if (kind == "hstack") Gravity.CENTER_VERTICAL else Gravity.CENTER_HORIZONTAL
                for (i in 0 until children.length()) children.optJSONObject(i)?.let { child -> addView(renderNode(child, screen), lp(if (kind == "hstack") 0 else MATCH, WRAP, if (kind == "hstack") 1f else 0f)) }
            }
            "text", "title" -> TextView(context).apply {
                text = localized(node, screen)
                textSize = properties.optDouble("font_size", 20.0).toFloat().coerceIn(10f, 72f)
                gravity = Gravity.CENTER
                setTypeface(typeface, if (properties.optString("font_weight") in listOf("bold", "semibold")) Typeface.BOLD else Typeface.NORMAL)
                setPadding(0, dp(6), 0, dp(6))
            }
            "package" -> packageView(node, screen, properties)
            "purchase_button", "cta" -> Button(context).apply {
                text = localized(node, screen).ifBlank { "Continue" }
                contentDescription = text
                setOnClickListener { purchaseSelected() }
            }
            "restore_button" -> Button(context).apply { text = localized(node, screen).ifBlank { "Restore purchases" }; setOnClickListener { restore() } }
            "button" -> Button(context).apply {
                text = localized(node, screen).ifBlank { "Continue" }
                setOnClickListener {
                    if (properties.optString("action") == "restore") restore()
                    else {
                        val next = properties.optString("next_screen_id")
                        if ((0 until screens.length()).any { screens.optJSONObject(it)?.optString("id") == next }) { activeScreenId = next; render() }
                        else purchaseSelected()
                    }
                }
            }
            "spacer" -> View(context).apply { layoutParams = lp(MATCH, dp(properties.optDouble("size", 8.0).toInt())) }
            "image" -> imageView(properties)
            else -> if (children.length() > 0) LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                for (i in 0 until children.length()) children.optJSONObject(i)?.let { addView(renderNode(it, screen), lp(MATCH, WRAP)) }
            } else TextView(context).apply { text = properties.optString("text") }
        }
    }

    private fun packageView(node: JSONObject, screen: JSONObject, props: JSONObject): View {
        val id = props.optString("package_id")
        val product = (0 until packages.length()).mapNotNull(packages::optJSONObject).firstOrNull { it.optString("id") == id }?.optJSONObject("product") ?: return View(context)
        val selected = id == selectedPackageId
        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isClickable = true
            isFocusable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            contentDescription = "${localized(node, screen).ifBlank { props.optString("label", product.optString("display_name", id)) }}, ${product.optString("localized_price")}"
            background = GradientDrawable().apply { setColor(Color.TRANSPARENT); cornerRadius = dp(14).toFloat(); setStroke(dp(if (selected) 2 else 1), if (selected) Color.rgb(49, 94, 232) else Color.LTGRAY) }
            setPadding(dp(12), dp(12), dp(12), dp(12))
            addView(TextView(context).apply { text = if (selected) "●" else "○"; textSize = 20f }, lp(dp(30), WRAP))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(TextView(context).apply { text = localized(node, screen).ifBlank { props.optString("label", product.optString("display_name", id)) }; textSize = 16f; setTypeface(typeface, Typeface.BOLD) })
                product.optString("localized_price").takeIf(String::isNotBlank)?.let { price -> addView(TextView(context).apply { text = price; textSize = 14f }) }
            }, lp(0, WRAP, 1f))
            setOnClickListener { selectedPackageId = id; render() }
        }
    }

    private fun imageView(properties: JSONObject): View {
        val source = properties.optJSONObject("source")?.optJSONObject("light")
        val url = source?.optString("url") ?: return View(context)
        if (!url.startsWith("https://")) return View(context)
        val image = ImageView(context).apply { contentDescription = properties.optString("accessibility_label"); adjustViewBounds = true; scaleType = ImageView.ScaleType.FIT_CENTER }
        imageExecutor.execute {
            runCatching {
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.connectTimeout = 5000; connection.readTimeout = 5000; connection.instanceFollowRedirects = false
                connection.inputStream.use { stream ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    var total = 0
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_IMAGE_BYTES) throw IllegalArgumentException("Paywall image exceeds the 8 MB limit.")
                        output.write(buffer, 0, count)
                    }
                    val bytes = output.toByteArray()
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }
            }.getOrNull()?.let { bitmap -> main.post { image.setImageBitmap(bitmap) } }
        }
        return image
    }

    private fun purchaseSelected() {
        if (busy || selectedPackageId.isBlank()) return
        val activity = context as? Activity ?: return
        busy = true
        purchases.purchase(activity, selectedPackageId) { result ->
            busy = false
            result.onSuccess { outcome -> if (outcome is PushifyPurchases.PurchaseOutcome.Purchased) onDismiss?.invoke() }
        }
    }

    private fun restore() {
        if (busy) return
        busy = true
        purchases.restorePurchases { busy = false }
    }

    private fun localized(node: JSONObject, screen: JSONObject): String {
        val key = node.optJSONObject("properties")?.optString("text_lid").orEmpty()
        if (key.isNotBlank()) {
            val perScreen = screen.optJSONObject("localizations") ?: JSONObject()
            val locale = document.optString("default_locale", "en_US")
            for (tag in listOf(java.util.Locale.getDefault().toLanguageTag(), locale, "en_US")) {
                val value = perScreen.optJSONObject(tag)?.optString(key) ?: strings.optJSONObject(tag)?.optString(key)
                if (!value.isNullOrBlank() && value != "null") return value
            }
        }
        return node.optJSONObject("properties")?.optString("text").orEmpty()
    }

    private fun backgroundColor(background: JSONObject?): Int {
        val hex = background?.optJSONObject("value")?.optJSONObject("light")?.optString("value") ?: return Color.WHITE
        return runCatching { Color.parseColor(hex.takeIf { it.length == 9 }?.let { "#${it.substring(7)}${it.substring(1, 7)}" } ?: hex) }.getOrDefault(Color.WHITE)
    }

    private fun findDefault(node: JSONObject?): String? {
        if (node == null) return null
        if (node.optString("kind") == "package") {
            val properties = node.optJSONObject("properties")
            if (properties?.optBoolean("is_selected_by_default") == true) return properties.optString("package_id")
        }
        val children = node.optJSONArray("children") ?: return null
        for (i in 0 until children.length()) findDefault(children.optJSONObject(i))?.let { return it }
        return null
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
    private fun lp(width: Int, height: Int, weight: Float = 0f) = LinearLayout.LayoutParams(width, height, weight)
    private companion object {
        const val MATCH = LayoutParams.MATCH_PARENT
        const val WRAP = LayoutParams.WRAP_CONTENT
        const val MAX_IMAGE_BYTES = 8 * 1024 * 1024
    }
}

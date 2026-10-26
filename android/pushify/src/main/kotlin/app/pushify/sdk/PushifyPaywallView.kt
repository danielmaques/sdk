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
import android.widget.HorizontalScrollView
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
            "icon" -> TextView(context).apply {
                text = iconGlyph(properties.optString("icon_name"))
                textSize = properties.optDouble("size", 24.0).toFloat().coerceIn(12f, 64f)
                gravity = Gravity.CENTER
                contentDescription = properties.optString("accessibility_label").ifBlank { properties.optString("icon_name") }
            }
            "timeline" -> LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                val items = properties.optJSONArray("items") ?: JSONArray()
                for (i in 0 until items.length()) {
                    val item = items.optJSONObject(i) ?: continue
                    val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.TOP; setPadding(0, 0, 0, dp(14)) }
                    val rail = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER_HORIZONTAL }
                    val icon = item.optJSONObject("icon")
                    rail.addView(TextView(context).apply { text = iconGlyph(icon?.optString("icon_name").orEmpty()); textSize = 18f; gravity = Gravity.CENTER; contentDescription = icon?.optString("accessibility_label") }, lp(dp(32), dp(32)))
                    if (i < items.length() - 1) rail.addView(View(context).apply { setBackgroundColor(Color.LTGRAY) }, lp(dp(2), dp(28)))
                    row.addView(rail, lp(dp(38), WRAP))
                    val copy = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(8), 0, 0, 0) }
                    nestedNode(item.optJSONObject("title"))?.let { copy.addView(renderNode(it, screen), lp(MATCH, WRAP)) }
                    nestedNode(item.optJSONObject("description"))?.let { copy.addView(renderNode(it, screen), lp(MATCH, WRAP)) }
                    row.addView(copy, lp(0, WRAP, 1f)); addView(row, lp(MATCH, WRAP))
                }
            }
            "carousel" -> HorizontalScrollView(context).apply {
                isHorizontalScrollBarEnabled = false
                val pages = properties.optJSONArray("pages") ?: JSONArray()
                val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
                for (i in 0 until pages.length()) nestedNode(pages.optJSONObject(i))?.let { page ->
                    val width = resources.displayMetrics.widthPixels - dp(32)
                    row.addView(renderNode(page, screen), LinearLayout.LayoutParams(width, WRAP).apply { rightMargin = dp(properties.optInt("page_spacing", 12)) })
                }
                addView(row)
            }
            "tabs" -> LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                val tabs = properties.optJSONArray("tabs") ?: JSONArray()
                val tabRow = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
                val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
                var selected = properties.optString("default_tab_id", tabs.optJSONObject(0)?.optString("id").orEmpty())
                fun showTab(id: String) {
                    selected = id; content.removeAllViews()
                    for (index in 0 until tabs.length()) { val tab = tabs.optJSONObject(index) ?: continue; if (tab.optString("id") == id) nestedNode(tab.optJSONObject("stack"))?.let { content.addView(renderNode(it, screen), lp(MATCH, WRAP)) } }
                    for (index in 0 until tabRow.childCount) (tabRow.getChildAt(index) as? Button)?.isSelected = (tabRow.getChildAt(index).tag == id)
                }
                for (index in 0 until tabs.length()) { val tab = tabs.optJSONObject(index) ?: continue; val id = tab.optString("id"); tabRow.addView(Button(context).apply { text = tab.optString("name"); tag = id; contentDescription = "${tab.optString("name")} tab"; setOnClickListener { showTab(id) } }, lp(0, WRAP, 1f)) }
                addView(tabRow, lp(MATCH, WRAP)); addView(content, lp(MATCH, WRAP)); showTab(selected)
            }
            "countdown" -> TextView(context).apply {
                val date = properties.optJSONObject("style")?.optString("date")
                val endMillis = runCatching { java.time.Instant.parse(date).toEpochMilli() }.getOrNull()
                if (endMillis != null && endMillis > System.currentTimeMillis()) {
                    val timer = object : android.os.CountDownTimer(endMillis - System.currentTimeMillis(), 1000) {
                        override fun onTick(millis: Long) { text = countdownText(millis) }
                        override fun onFinish() { text = "Offer ended" }
                    }
                    timer.start(); addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener { override fun onViewAttachedToWindow(view: View) = Unit; override fun onViewDetachedFromWindow(view: View) { timer.cancel() } })
                } else text = "Offer ended"
                gravity = Gravity.CENTER; textSize = 16f; setTypeface(typeface, Typeface.BOLD); contentDescription = "Offer countdown"
            }
            "tab_control" -> View(context)
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

    private fun nestedNode(value: JSONObject?): JSONObject? {
        if (value == null) return null
        val kind = value.optString("kind").ifBlank { value.optString("type") }
        if (kind.isBlank()) return null
        val properties = value.optJSONObject("properties") ?: JSONObject(value.toString()).apply { remove("kind"); remove("type"); remove("children"); remove("components"); remove("id") }
        val children = value.optJSONArray("children") ?: value.optJSONArray("components") ?: JSONArray()
        val normalized = JSONArray()
        for (i in 0 until children.length()) nestedNode(children.optJSONObject(i))?.let(normalized::put)
        return JSONObject().put("id", value.optString("id")).put("kind", kind).put("properties", properties).put("children", normalized)
    }
    private fun iconGlyph(name: String): String = when (name.lowercase()) { "check", "checkmark" -> "✓"; "star" -> "★"; "bell" -> "♢"; "unlock" -> "◇"; "heart" -> "♥"; "clock" -> "◷"; else -> "●" }
    private fun countdownText(millis: Long): String {
        val total = millis / 1000; val days = total / 86400; val hours = total / 3600 % 24; val minutes = total / 60 % 60; val seconds = total % 60
        return if (days > 0) "${days}d ${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}" else "${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}"
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
    private fun lp(width: Int, height: Int, weight: Float = 0f) = LinearLayout.LayoutParams(width, height, weight)
    private companion object {
        const val MATCH = LayoutParams.MATCH_PARENT
        const val WRAP = LayoutParams.WRAP_CONTENT
        const val MAX_IMAGE_BYTES = 8 * 1024 * 1024
    }
}

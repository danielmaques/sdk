package app.pushify.sdk

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.browser.customtabs.CustomTabsIntent
import android.widget.Button
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.MediaController
import android.widget.ScrollView
import android.widget.TextView
import android.widget.VideoView
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/** Native Android renderer for the core Pushify paywall component set. */
public class PushifyPaywallView @JvmOverloads constructor(
    context: Context,
    private var document: JSONObject,
    private var offering: JSONObject,
    private val purchases: PushifyPurchases,
    private val onDismiss: (() -> Unit)? = null,
    private val onCustomAction: ((String) -> Unit)? = null,
) : ScrollView(context) {
    private val main = Handler(Looper.getMainLooper())
    private val imageExecutor = Executors.newFixedThreadPool(2)
    private var packages = JSONArray()
    private var selectedPackageId = ""
    private var activeScreenId = ""
    private var strings = JSONObject()
    private var variableDeclarations = JSONObject()
    private val variables = JSONObject()
    private var screens = JSONArray()
    private var showingExitOffer = false
    private var dismissing = false
    private var busy = false
    private var message: String? = null

    init {
        isFillViewport = true
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        loadDocumentState()
        render()
    }

    private fun loadDocumentState() {
        packages = offering.optJSONArray("packages") ?: JSONArray()
        screens = document.optJSONArray("screens") ?: JSONArray()
        val entry = (0 until screens.length()).mapNotNull(screens::optJSONObject)
            .firstOrNull { it.optString("id") == document.optString("initial_screen_id") }
            ?: screens.optJSONObject(0)
        activeScreenId = entry?.optString("id").orEmpty()
        selectedPackageId = findDefault(entry?.optJSONObject("content"))
            ?: packages.optJSONObject(0)?.optString("id").orEmpty()
        strings = document.optJSONObject("locales") ?: JSONObject()
        variableDeclarations = document.optJSONObject("custom_variables") ?: JSONObject()
        variables.keys().asSequence().toList().forEach { key -> variables.remove(key) }
        val keys = variableDeclarations.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            variables.put(key, variableDeclarations.optJSONObject(key)?.opt("initial_value"))
        }
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
        onDismiss?.let {
            val row = LinearLayout(context).apply { gravity = Gravity.END }
            row.addView(Button(context).apply { text = "Close"; contentDescription = "Close paywall"; setOnClickListener { dismissManually() } }, lp(WRAP, dp(48)))
            root.addView(row, lp(MATCH, WRAP))
        }
        screen.optJSONObject("content")?.let { root.addView(renderNode(it, screen), lp(MATCH, 0, 1f)) }
        screen.optJSONObject("footer")?.let { root.addView(renderNode(it, screen), lp(MATCH, WRAP)) }
        message?.let { status -> root.addView(TextView(context).apply { text = status; gravity = Gravity.CENTER; contentDescription = status }, lp(MATCH, WRAP)) }
        addView(root, LayoutParams(MATCH, MATCH))
    }

    private fun dismissManually() {
        if (dismissing) return
        if (showingExitOffer) { onDismiss?.invoke(); return }
        val index = (0 until screens.length()).indexOfFirst { screens.optJSONObject(it)?.optString("id") == activeScreenId }
        val dismiss = document.optJSONObject("exit_offer")?.optJSONObject("dismiss")
        val destinationId = dismiss?.optString("offering_id").orEmpty()
        if (index >= 0 && index == screens.length() - 1 && destinationId.isNotBlank() && destinationId != offering.optString("id")) {
            dismissing = true
            purchases.offerings { result -> main.post {
                dismissing = false
                val catalog = result.getOrNull()
                val available = catalog?.optJSONArray("offerings")
                val destination = (0 until (available?.length() ?: 0))
                    .mapNotNull { available?.optJSONObject(it) }
                    .firstOrNull { it.optString("id") == destinationId && it.optJSONObject("paywall") != null }
                if (destination != null) {
                    val event = JSONObject()
                        .put("type", "dismiss")
                        .put("offering_id", destinationId)
                        .put("paywall_id", document.optString("id"))
                    purchases.logEvent("PAYWALL_EXIT_OFFER", event) {}
                    document = destination.optJSONObject("paywall")!!
                    offering = destination
                    showingExitOffer = true
                    loadDocumentState()
                    render()
                } else onDismiss?.invoke()
            } }
            return
        }
        onDismiss?.invoke()
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
                text = buttonLabel(node, screen).ifBlank { "Continue" }
                contentDescription = text
                setOnClickListener { purchaseSelected(screen = screen) }
            }
            "restore_button" -> Button(context).apply { text = localized(node, screen).ifBlank { "Restore purchases" }; setOnClickListener { restore() } }
            "button" -> Button(context).apply {
                text = buttonLabel(node, screen).ifBlank { "Continue" }
                setOnClickListener { performActionFeedback(this, properties.optJSONObject("action") ?: JSONObject()); handleButton(properties, screen) }
            }
            "spacer" -> View(context).apply { layoutParams = lp(MATCH, dp(properties.optDouble("size", 8.0).toInt())) }
            "image" -> imageView(properties)
            "video" -> videoView(properties)
            "icon" -> TextView(context).apply {
                text = iconGlyph(properties.optString("icon_name"))
                textSize = properties.optDouble("size", 24.0).toFloat().coerceIn(12f, 64f)
                gravity = Gravity.CENTER
                setTextColor(colorValue(properties.optJSONObject("color"), Color.rgb(49, 94, 232)))
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
                val template = findNodeText(properties.optJSONObject("countdown_stack"))
                val endedText = findNodeText(properties.optJSONObject("end_stack"))
                val endMillis = runCatching { java.time.Instant.parse(date).toEpochMilli() }.getOrNull()
                if (endMillis != null && endMillis > System.currentTimeMillis()) {
                    val timer = object : android.os.CountDownTimer(endMillis - System.currentTimeMillis(), 1000) {
                        override fun onTick(millis: Long) { text = countdownText(millis, template) }
                        override fun onFinish() { text = endedText ?: "Offer ended" }
                    }
                    timer.start(); addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener { override fun onViewAttachedToWindow(view: View) = Unit; override fun onViewDetachedFromWindow(view: View) { timer.cancel() } })
                } else text = "Offer ended"
                gravity = Gravity.CENTER; textSize = 16f; setTypeface(typeface, Typeface.BOLD); contentDescription = "Offer countdown"
            }
            "web_view" -> {
                val url = properties.optString("url")
                val origin = Uri.parse(url)
                val protocolVersion = properties.optInt("protocol_version", 1)
                val fallback = nestedNode(properties.optJSONObject("fallback"))?.let { renderNode(it, screen) }
                if (protocolVersion == 1 && origin.scheme == "https" && !origin.host.isNullOrBlank()) FrameLayout(context).apply {
                    val height = properties.optJSONObject("size")?.optJSONObject("height")?.optInt("value", 240) ?: 240
                    minimumHeight = dp(height)
                    setBackgroundColor(Color.BLACK)
                    fallback?.let { addView(it, FrameLayout.LayoutParams(MATCH, WRAP)); it.visibility = View.VISIBLE }
                    val status = TextView(context).apply {
                        text = "Loading interactive experience…"
                        contentDescription = "Loading interactive experience"
                        gravity = Gravity.CENTER
                        setTextColor(Color.WHITE)
                        visibility = if (fallback == null) View.VISIBLE else View.GONE
                    }
                    val experience = WebView(context).apply {
                        visibility = View.GONE
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        settings.allowFileAccess = false
                        settings.allowContentAccess = false
                        settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
                        settings.javaScriptCanOpenWindowsAutomatically = false
                        settings.setSupportMultipleWindows(false)
                        setBackgroundColor(Color.TRANSPARENT)
                        webViewClient = object : WebViewClient() {
                            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = !sameHttpsOrigin(request.url, origin)
                            override fun onPageFinished(view: WebView, pageUrl: String) { fallback?.visibility = View.GONE; status.visibility = View.GONE; view.visibility = View.VISIBLE }
                            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: android.webkit.WebResourceError) {
                                if (request.isForMainFrame) {
                                    view.visibility = View.GONE
                                    fallback?.visibility = View.VISIBLE
                                    status.text = "Interactive experience unavailable"
                                    status.contentDescription = "Interactive experience unavailable"
                                    status.visibility = if (fallback == null) View.VISIBLE else View.GONE
                                }
                            }
                            override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: android.webkit.WebResourceResponse) {
                                if (request.isForMainFrame && response.statusCode >= 400) {
                                    view.visibility = View.GONE
                                    fallback?.visibility = View.VISIBLE
                                    status.text = "Interactive experience unavailable"
                                    status.contentDescription = "Interactive experience unavailable"
                                    status.visibility = if (fallback == null) View.VISIBLE else View.GONE
                                }
                            }
                        }
                        loadUrl(url)
                    }
                    addView(experience, FrameLayout.LayoutParams(MATCH, MATCH))
                    addView(status, FrameLayout.LayoutParams(MATCH, MATCH))
                } else fallback ?: View(context)
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
        loadImage(url) { image.setImageBitmap(it) }
        return image
    }

    private fun videoView(properties: JSONObject): View {
        val dark = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        val sources = properties.optJSONObject("source") ?: JSONObject()
        val source = (if (dark) sources.optJSONObject("dark") else null) ?: sources.optJSONObject("light")
        val url = source?.optString("url").orEmpty()
        if (!url.startsWith("https://")) return videoFailure(properties, dark)

        val autoplay = properties.optBoolean("auto_play", true)
        val loop = properties.optBoolean("loop", true)
        val muted = properties.optBoolean("mute_audio", true)
        val controls = properties.optBoolean("show_controls", false)
        val posterSource = properties.optJSONObject("fallback_source")?.let { themedMedia(it, dark) }
        val frame = FrameLayout(context).apply { setBackgroundColor(Color.BLACK); contentDescription = properties.optString("accessibility_label").ifBlank { "Video" } }
        var poster: ImageView? = null
        val placeholder = TextView(context).apply {
            text = if (posterSource == null) "Loading video…" else ""
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.BLACK)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            contentDescription = if (posterSource == null) "Loading video" else null
        }
        val video = VideoView(context).apply {
            visibility = View.INVISIBLE
            importantForAccessibility = if (controls) View.IMPORTANT_FOR_ACCESSIBILITY_AUTO else View.IMPORTANT_FOR_ACCESSIBILITY_NO
            if (controls) setMediaController(MediaController(context).also { it.setAnchorView(this) })
            setOnPreparedListener { player ->
                if (muted) player.setVolume(0f, 0f)
                visibility = View.VISIBLE
                placeholder.visibility = View.GONE
                poster?.visibility = View.GONE
                if (autoplay) start() else if (controls) seekTo(1)
            }
            setOnCompletionListener {
                if (loop) { seekTo(0); start() }
            }
            setOnErrorListener { _, _, _ ->
                visibility = View.GONE
                placeholder.text = if (posterSource == null) "Video unavailable" else ""
                placeholder.contentDescription = "Video unavailable"
                placeholder.visibility = View.VISIBLE
                poster?.visibility = if (posterSource == null) View.GONE else View.VISIBLE
                true
            }
            setVideoURI(Uri.parse(url))
        }
        poster = posterSource?.let { sourceUrl ->
            ImageView(context).apply {
                scaleType = if (properties.optString("fit_mode") == "fit") ImageView.ScaleType.FIT_CENTER else ImageView.ScaleType.CENTER_CROP
                contentDescription = properties.optString("accessibility_label").ifBlank { "Video preview" }
                loadImage(sourceUrl) { bitmap -> setImageBitmap(bitmap) }
            }
        }
        frame.addView(video, FrameLayout.LayoutParams(MATCH, dp(properties.optJSONObject("size")?.optJSONObject("height")?.optInt("value", 220) ?: 220)))
        poster?.let { frame.addView(it, FrameLayout.LayoutParams(MATCH, MATCH)) }
        frame.addView(placeholder, FrameLayout.LayoutParams(MATCH, MATCH))
        placeholder.visibility = if (poster != null) View.GONE else View.VISIBLE
        frame.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            private var released = false
            override fun onViewAttachedToWindow(view: View) {
                if (released) video.setVideoURI(Uri.parse(url))
                released = false
                if (autoplay && video.visibility == View.VISIBLE) video.start()
            }
            override fun onViewDetachedFromWindow(view: View) { video.stopPlayback(); released = true }
        })
        return frame
    }

    private fun videoFailure(properties: JSONObject, dark: Boolean): View {
        val posterUrl = properties.optJSONObject("fallback_source")?.let { themedMedia(it, dark) }
        if (posterUrl == null) return TextView(context).apply {
            text = "Video unavailable"; gravity = Gravity.CENTER; contentDescription = text; setTextColor(Color.WHITE); setBackgroundColor(Color.BLACK)
        }
        return ImageView(context).apply {
            scaleType = if (properties.optString("fit_mode") == "fit") ImageView.ScaleType.FIT_CENTER else ImageView.ScaleType.CENTER_CROP
            contentDescription = properties.optString("accessibility_label").ifBlank { "Video preview" }
            loadImage(posterUrl) { setImageBitmap(it) }
        }
    }

    private fun themedMedia(sources: JSONObject, dark: Boolean): String? {
        val theme = (if (dark) sources.optJSONObject("dark") else null) ?: sources.optJSONObject("light") ?: return null
        return theme.optString("url").takeIf(String::isNotBlank) ?: theme.optString("original").takeIf(String::isNotBlank)
    }

    private fun loadImage(url: String, onLoaded: (android.graphics.Bitmap) -> Unit) {
        if (!url.startsWith("https://")) return
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
            }.getOrNull()?.let { bitmap -> main.post { onLoaded(bitmap) } }
        }
    }

    private fun purchaseSelected(packageId: String? = null, action: JSONObject = JSONObject(), screen: JSONObject? = null) {
        val productId = packageId ?: selectedPackageId
        if (busy) return
        if (productId.isBlank() || (0 until packages.length()).none { packages.optJSONObject(it)?.optString("id") == productId }) {
            message = "This purchase option is unavailable."; render(); return
        }
        val activity = context as? Activity ?: return
        busy = true
        purchases.purchase(activity, productId) { result ->
            busy = false
            result.onSuccess { outcome ->
                when (outcome) {
                    is PushifyPurchases.PurchaseOutcome.Purchased -> runPurchaseOutcome("after_purchase", "close", action, screen)
                    PushifyPurchases.PurchaseOutcome.Cancelled -> runPurchaseOutcome("on_abandon", "none", action, screen)
                    PushifyPurchases.PurchaseOutcome.Pending -> { message = "Purchase is pending approval."; render() }
                }
            }.onFailure { message = "Purchase could not be completed. Please try again."; render() }
        }
    }

    private fun runPurchaseOutcome(key: String, fallback: String, action: JSONObject, screen: JSONObject?) {
        val steps = action.optJSONObject("pushify_actions")?.optJSONArray(key) ?: JSONArray()
        fun finish() {
            val type = action.optJSONObject(key)?.optString("type")?.takeIf(String::isNotBlank) ?: fallback
            if (type == "none") return
            if (type == "close") { onDismiss?.invoke(); return }
            val index = (0 until screens.length()).indexOfFirst { screens.optJSONObject(it)?.optString("id") == screen?.optString("id") }
            when (type) {
                "navigate_back" -> if (index > 0) { activeScreenId = screens.optJSONObject(index - 1)?.optString("id").orEmpty(); render() } else onDismiss?.invoke()
                "workflow" -> if (index >= 0 && index + 1 < screens.length()) { activeScreenId = screens.optJSONObject(index + 1)?.optString("id").orEmpty(); render() } else { message = "This flow has no next screen."; render() }
                else -> { message = "This purchase outcome is not supported by this SDK version."; render() }
            }
        }
        fun runStep(at: Int) {
            if (at >= steps.length()) { finish(); return }
            val step = steps.optJSONObject(at) ?: run { runStep(at + 1); return }
            when (step.optString("type")) {
                "update_variable" -> {
                    val name = step.optString("variable").removePrefix("state.")
                    val definition = variableDeclarations.optJSONObject(name)
                    if (definition == null) { message = "This state variable is not declared."; render(); return }
                    val before = variables.opt(name) ?: definition.opt("initial_value")
                    val value = step.opt("value")
                    val next: Any? = when (definition.optString("value_type")) {
                        "number" -> { val amount = (value as? Number)?.toDouble() ?: 0.0; val current = (before as? Number)?.toDouble() ?: 0.0; when (step.optString("operation")) { "increment" -> current + amount; "decrement" -> current - amount; else -> amount } }
                        "boolean" -> if (step.optString("operation") == "toggle") !(before as? Boolean ?: false) else value as? Boolean ?: false
                        else -> value as? String ?: before?.toString().orEmpty()
                    }
                    variables.put(name, next); render(); runStep(at + 1)
                }
                "navigate_to" -> {
                    if (screen == null) { message = "This link is unavailable."; render(); return }
                    openActionLink(step, screen)
                    runStep(at + 1)
                }
                "set_user_attributes" -> {
                    val attributes = step.optJSONObject("attributes")
                    if (attributes == null || attributes.length() == 0) { message = "No user attributes are configured."; render(); return }
                    val valid = attributes.keys().asSequence().all { key -> val value = attributes.opt(key); key.isNotBlank() && key.length <= 100 && (value == JSONObject.NULL || value is String || value is Number || value is Boolean) }
                    if (!valid) { message = "This user attribute is invalid."; render(); return }
                    busy = true
                    purchases.setAttributes(attributes) { result -> main.post {
                        busy = false
                        if (result.isSuccess) runStep(at + 1) else { message = "User attributes could not be updated. Please try again."; render() }
                    } }
                }
                else -> runStep(at + 1)
            }
        }
        runStep(0)
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
            val deviceLocale = java.util.Locale.getDefault().toLanguageTag()
            for (tag in listOf(deviceLocale.replace('-', '_'), deviceLocale, locale, "en_US")) {
                val value = perScreen.optJSONObject(tag)?.optString(key) ?: strings.optJSONObject(tag)?.optString(key)
                if (!value.isNullOrBlank() && value != "null") return interpolate(value)
            }
        }
        return interpolate(node.optJSONObject("properties")?.optString("text").orEmpty())
    }

    private fun interpolate(value: String): String = Regex("\\{\\{\\s*state\\.([A-Za-z_][A-Za-z0-9_]*)\\s*}}")
        .replace(value) { match -> if (variables.has(match.groupValues[1])) variables.opt(match.groupValues[1])?.toString() ?: "null" else match.value }

    private fun localizedValue(key: String, screen: JSONObject): String? {
        val perScreen = screen.optJSONObject("localizations") ?: JSONObject()
        val locale = document.optString("default_locale", "en_US")
        val deviceLocale = java.util.Locale.getDefault().toLanguageTag()
        for (tag in listOf(deviceLocale.replace('-', '_'), deviceLocale, locale, "en_US")) {
            val value = perScreen.optJSONObject(tag)?.optString(key) ?: strings.optJSONObject(tag)?.optString(key)
            if (!value.isNullOrBlank() && value != "null") return value
        }
        return null
    }

    private fun buttonLabel(node: JSONObject, screen: JSONObject): String {
        node.optJSONArray("children")?.let { children ->
            for (i in 0 until children.length()) {
                val child = children.optJSONObject(i) ?: continue
                val value = localizedNodeText(child, screen)
                if (!value.isNullOrBlank()) return value
            }
        }
        return localized(node, screen)
    }

    private fun localizedNodeText(node: JSONObject, screen: JSONObject): String? {
        val properties = node.optJSONObject("properties") ?: JSONObject()
        val key = properties.optString("text_lid")
        if (key.isNotBlank()) localizedValue(key, screen)?.let { return it }
        properties.optString("text").takeIf(String::isNotBlank)?.let { return it }
        val children = node.optJSONArray("children") ?: return null
        for (i in 0 until children.length()) localizedNodeText(children.optJSONObject(i) ?: continue, screen)?.let { return it }
        return null
    }

    private fun handleButton(properties: JSONObject, screen: JSONObject) {
        val action = properties.optJSONObject("action") ?: JSONObject()
        val kind = action.optString("type").ifBlank { properties.optString("action") }
        when (kind) {
            "update_variable" -> {
                val variable = action.optString("variable").removePrefix("state.")
                val definition = variableDeclarations.optJSONObject(variable)
                if (definition == null) { message = "This state variable is not declared."; return }
                val before = variables.opt(variable) ?: definition.opt("initial_value")
                val value = action.opt("value")
                val next: Any? = when (definition.optString("value_type")) {
                    "number" -> { val amount = (value as? Number)?.toDouble() ?: 0.0; val current = (before as? Number)?.toDouble() ?: 0.0; when (action.optString("operation")) { "increment" -> current + amount; "decrement" -> current - amount; else -> amount } }
                    "boolean" -> if (action.optString("operation") == "toggle") !(before as? Boolean ?: false) else value as? Boolean ?: false
                    else -> value as? String ?: before?.toString().orEmpty()
                }
                variables.put(variable, next); render()
            }
            "restore_purchases", "restore" -> restore()
            "set_user_attributes" -> setUserAttributes(action)
            "navigate_to" -> openActionLink(action, screen)
            "custom_action" -> {
                val name = action.optString("name").trim()
                val callback = onCustomAction
                if (name.isEmpty()) message = "This custom action has no name."
                else if (callback == null) message = "This app action is unavailable."
                else { message = null; callback(name) }
                render()
            }
            "navigate_back" -> {
                val index = (0 until screens.length()).indexOfFirst { screens.optJSONObject(it)?.optString("id") == activeScreenId }
                if (index > 0) { activeScreenId = screens.optJSONObject(index - 1)?.optString("id").orEmpty(); render() }
                else dismissManually()
            }
            "workflow" -> {
                val routes = action.optJSONArray("routes")
                var target = ""
                for (routeIndex in 0 until (routes?.length() ?: 0)) {
                    val route = routes?.optJSONObject(routeIndex) ?: continue
                    val key = route.optString("variable").removePrefix("state.")
                    val current = variables.opt(key)
                    val expected = route.opt("value")
                    val matched = when (route.optString("operator")) {
                        "equals" -> current == expected
                        "not_equals" -> current != expected
                        "greater_than" -> (current as? Number)?.toDouble()?.let { left -> (expected as? Number)?.toDouble()?.let { left > it } } == true
                        "less_than" -> (current as? Number)?.toDouble()?.let { left -> (expected as? Number)?.toDouble()?.let { left < it } } == true
                        else -> false
                    }
                    if (matched) { target = route.optString("screen_id"); break }
                }
                if (target.isNotBlank() && (0 until screens.length()).any { screens.optJSONObject(it)?.optString("id") == target }) {
                    activeScreenId = target
                    render()
                    return
                }
                val index = (0 until screens.length()).indexOfFirst { screens.optJSONObject(it)?.optString("id") == screen.optString("id") }
                if (index >= 0 && index + 1 < screens.length()) {
                    activeScreenId = screens.optJSONObject(index + 1)?.optString("id").orEmpty()
                } else {
                    message = "This flow has no next screen."
                }
                render()
            }
            "close", "close_workflow" -> dismissManually()
            "purchase", "purchase_with_outcome", "purchase_product" -> purchaseSelected(action.optString("package_id").takeIf(String::isNotBlank), action, screen)
            else -> {
                val next = properties.optString("next_screen_id")
                if ((0 until screens.length()).any { screens.optJSONObject(it)?.optString("id") == next }) { activeScreenId = next; render() }
                else { message = "This button action is not supported by this SDK version."; render() }
            }
        }
    }

    private fun performActionFeedback(view: View, action: JSONObject) {
        when (action.optString("animation")) {
            "shrink" -> view.animate().scaleX(0.96f).scaleY(0.96f).setDuration(80).withEndAction { view.animate().scaleX(1f).scaleY(1f).setDuration(100).start() }.start()
            "grow" -> view.animate().scaleX(1.04f).scaleY(1.04f).setDuration(80).withEndAction { view.animate().scaleX(1f).scaleY(1f).setDuration(100).start() }.start()
            "fade" -> view.animate().alpha(0.55f).setDuration(80).withEndAction { view.animate().alpha(1f).setDuration(100).start() }.start()
        }
        val feedback = when (action.optString("haptics")) {
            "light", "selection" -> HapticFeedbackConstants.KEYBOARD_TAP
            "medium" -> HapticFeedbackConstants.CONTEXT_CLICK
            "heavy", "warning", "error" -> HapticFeedbackConstants.LONG_PRESS
            "success" -> HapticFeedbackConstants.VIRTUAL_KEY
            else -> return
        }
        view.performHapticFeedback(feedback)
    }

    private fun setUserAttributes(action: JSONObject) {
        val attributes = action.optJSONObject("attributes")
        if (attributes == null || attributes.length() == 0) { message = "No user attributes are configured."; render(); return }
        val valid = attributes.keys().asSequence().all { key ->
            val value = attributes.opt(key)
            key.isNotBlank() && key.length <= 100 && (value == JSONObject.NULL || value is String || value is Number || value is Boolean)
        }
        if (!valid) { message = "This user attribute is invalid."; render(); return }
        if (busy) return
        busy = true; message = null
        purchases.setAttributes(attributes) { result ->
            main.post {
                busy = false
                message = if (result.isSuccess) "User attributes updated." else "User attributes could not be updated. Please try again."
                render()
            }
        }
    }

    private fun openActionLink(action: JSONObject, screen: JSONObject) {
        val ref = action.optJSONObject("url") ?: JSONObject()
        val key = ref.optString("url_lid")
        val raw = if (key.isNotBlank()) localizedValue(key, screen) else ref.optString("url")
        val uri = raw?.let { runCatching { Uri.parse(it) }.getOrNull() }
        val method = ref.optString("method", "in_app_browser")
        val scheme = uri?.scheme?.lowercase()
        val browser = method == "in_app_browser" || method == "external_browser"
        val safeDeepLink = scheme != null && scheme !in setOf("javascript", "data", "file", "content", "intent")
        if (uri == null || !safeDeepLink || method !in setOf("in_app_browser", "external_browser", "deep_link") ||
            (browser && scheme !in setOf("http", "https")) || ((browser || scheme in setOf("http", "https")) && uri.host.isNullOrBlank())) {
            message = "This link is unavailable."; render(); return
        }
        runCatching {
            if (method == "in_app_browser") {
                val activity = context as? Activity ?: error("An activity is required to open the in-app browser.")
                CustomTabsIntent.Builder().build().launchUrl(activity, uri)
            } else {
                val intent = Intent(Intent.ACTION_VIEW, uri)
                if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
            }
        }.onFailure {
            message = "This link could not be opened."
            render()
        }
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
        if (!properties.has("fallback") && value.has("fallback")) properties.put("fallback", value.optJSONObject("fallback"))
        val children = value.optJSONArray("children") ?: value.optJSONArray("components") ?: JSONArray()
        val normalized = JSONArray()
        for (i in 0 until children.length()) nestedNode(children.optJSONObject(i))?.let(normalized::put)
        return JSONObject().put("id", value.optString("id")).put("kind", kind).put("properties", properties).put("children", normalized)
    }
    private fun iconGlyph(name: String): String = when (name.lowercase()) { "check", "checkmark" -> "✓"; "star" -> "★"; "bell" -> "♢"; "unlock" -> "◇"; "heart" -> "♥"; "clock" -> "◷"; else -> "●" }
    private fun colorValue(value: JSONObject?, fallback: Int): Int {
        val light = value?.optJSONObject("light") ?: value?.optJSONObject("value")?.optJSONObject("light")
        val hex = light?.optString("value")?.takeIf(String::isNotBlank) ?: return fallback
        return runCatching { Color.parseColor(hex) }.getOrDefault(fallback)
    }
    private fun findNodeText(node: JSONObject?): String? {
        if (node == null) return null
        val properties = node.optJSONObject("properties")
        properties?.optString("text")?.takeIf(String::isNotBlank)?.let { return it }
        node.optString("text").takeIf(String::isNotBlank)?.let { return it }
        val children = node.optJSONArray("children") ?: node.optJSONArray("components") ?: return null
        for (i in 0 until children.length()) findNodeText(children.optJSONObject(i))?.let { return it }
        return null
    }
    private fun countdownText(millis: Long, template: String?): String {
        val total = millis / 1000; val days = total / 86400; val hours = total / 3600 % 24; val minutes = total / 60 % 60; val seconds = total % 60
        val fallback = if (days > 0) "${days}d ${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}" else "${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}"
        return (template ?: fallback).replace("{{ count_days_without_zero }}", days.toString()).replace("{{ count_hours_with_zero }}", hours.toString().padStart(2, '0')).replace("{{ count_minutes_with_zero }}", minutes.toString().padStart(2, '0')).replace("{{ count_seconds_with_zero }}", seconds.toString().padStart(2, '0'))
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
    private fun lp(width: Int, height: Int, weight: Float = 0f) = LinearLayout.LayoutParams(width, height, weight)
    private companion object {
        const val MATCH = LayoutParams.MATCH_PARENT
        const val WRAP = LayoutParams.WRAP_CONTENT
        const val MAX_IMAGE_BYTES = 8 * 1024 * 1024
    }
}

private fun sameHttpsOrigin(candidate: Uri, origin: Uri): Boolean {
    if (!candidate.scheme.equals("https", ignoreCase = true) ||
        !origin.scheme.equals("https", ignoreCase = true) ||
        !candidate.host.equals(origin.host, ignoreCase = true)) return false
    val candidatePort = if (candidate.port == -1) 443 else candidate.port
    val originPort = if (origin.port == -1) 443 else origin.port
    return candidatePort == originPort
}

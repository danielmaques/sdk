package app.pushify.sdk

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.ColorFilter
import android.graphics.PixelFormat
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Rect
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.ColorDrawable
import android.content.res.Configuration
import android.text.Editable
import android.text.InputFilter
import android.text.InputType
import android.text.TextWatcher
import android.os.Handler
import android.os.Looper
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.MotionEvent
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import androidx.browser.customtabs.CustomTabsIntent
import com.airbnb.lottie.LottieAnimationView
import com.airbnb.lottie.LottieDrawable
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.MediaController
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.RadioButton
import kotlin.math.roundToInt
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
import java.util.Random

public data class PushifyCustomCallbackResult(
    val status: String,
    val data: Map<String, Any?> = emptyMap(),
)

/** Native Android renderer for the core Pushify paywall component set. */
public class PushifyPaywallView @JvmOverloads constructor(
    context: Context,
    private var document: JSONObject,
    private var offering: JSONObject,
    private val purchases: PushifyPurchases,
    private val onDismiss: (() -> Unit)? = null,
    private val onCustomAction: ((String) -> Unit)? = null,
    private val onCustomPlacement: ((String, JSONObject) -> Unit)? = null,
    private val onCustomCallback: ((String, JSONObject, (PushifyCustomCallbackResult) -> Unit) -> Unit)? = null,
) : ScrollView(context) {
    private data class TapActionRun(var waiting: Boolean = false, var interruptible: Boolean = false, var cancelled: Boolean = false, var runnable: Runnable? = null)
    private data class EligibleDiscountWheelPrize(val prize: JSONObject, val packageItem: JSONObject, val offer: JSONObject)
    private val main = Handler(Looper.getMainLooper())
    private val tapActionRuns = mutableMapOf<String, TapActionRun>()
    private val imageExecutor = Executors.newFixedThreadPool(2)
    private var packages = JSONArray()
    private var selectedPackageId = ""
    private var activeScreenId = ""
    private var strings = JSONObject()
    private var variableDeclarations = JSONObject()
    private val variables = JSONObject()
    private val callbackData = JSONObject()
    private val transactionProducts = mutableMapOf<String, JSONObject>()
    private val carouselPages = mutableMapOf<String, Int>()
    private val countdownStartedAtMs = mutableMapOf<String, Long>()
    private var screens = JSONArray()
    private var showingExitOffer = false
    private var dismissing = false
    private var busy = false
    private var discountWheelUsed = false
    private var discountWheelPrize: JSONObject? = null
    private var discountWheelRotation = 0f
    private var message: String? = null
    private var focusedInputVariable: String? = null
    private var focusedInputSelection = 0
    private val surveyedTriggers = mutableSetOf<String>()
    private val randomizationSeed = System.nanoTime()

    override fun onDetachedFromWindow() {
        tapActionRuns.values.forEach { run -> run.cancelled = true; run.runnable?.let(main::removeCallbacks) }
        tapActionRuns.clear()
        super.onDetachedFromWindow()
    }

    override fun onInterceptTouchEvent(event: MotionEvent): Boolean = false

    override fun onTouchEvent(event: MotionEvent): Boolean = false

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
        if (!variableDeclarations.has("didCompleteTransaction")) variables.put("didCompleteTransaction", false)
        if (!variableDeclarations.has("didAbandonTransaction")) variables.put("didAbandonTransaction", false)
    }

    private fun render() {
        (findFocus() as? EditText)?.let { field ->
            focusedInputVariable = field.tag as? String
            focusedInputSelection = field.selectionStart.coerceAtLeast(0)
        }
        removeAllViews()
        val screen = (0 until screens.length()).mapNotNull(screens::optJSONObject).firstOrNull { it.optString("id") == activeScreenId }
            ?: screens.optJSONObject(0) ?: return
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(16))
            gravity = Gravity.CENTER_HORIZONTAL
            background = paywallBackground(screen.optJSONObject("background"))
        }
        onDismiss?.let {
            val row = LinearLayout(context).apply { gravity = Gravity.END }
            row.addView(Button(context).apply { text = "Close"; contentDescription = "Close paywall"; setOnClickListener { dismissManually() } }, lp(WRAP, dp(48)))
            root.addView(row, lp(MATCH, WRAP))
        }
        screen.optJSONObject("content")?.let { content ->
            val body = object : ScrollView(context) {
                private fun allowsScroll() = document.optBoolean("scroll_enabled", true)
                override fun onInterceptTouchEvent(event: MotionEvent): Boolean = if (allowsScroll()) super.onInterceptTouchEvent(event) else false
                override fun onTouchEvent(event: MotionEvent): Boolean = if (allowsScroll()) super.onTouchEvent(event) else false
                override fun performAccessibilityAction(action: Int, arguments: Bundle?): Boolean =
                    if (!allowsScroll() && action in setOf(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD, AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)) false
                    else super.performAccessibilityAction(action, arguments)
            }.apply { isFillViewport = true; isVerticalScrollBarEnabled = false }
            body.addView(renderNode(content, screen), lp(MATCH, WRAP))
            root.addView(body, lp(MATCH, 0, 1f))
        }
        screen.optJSONObject("footer")?.let { root.addView(renderNode(it, screen), lp(MATCH, WRAP)) }
        message?.let { status -> root.addView(TextView(context).apply { text = status; gravity = Gravity.CENTER; contentDescription = status }, lp(MATCH, WRAP)) }
        addView(root, LayoutParams(MATCH, MATCH))
        focusedInputVariable?.let { name -> post {
            val field = root.findViewWithTag<EditText>(name) ?: return@post
            field.requestFocus()
            field.setSelection(focusedInputSelection.coerceIn(0, field.text.length))
        } }
    }

    private fun dismissManually() {
        dismissManually(skipCloseSurvey = false)
    }

    private fun dismissManually(skipCloseSurvey: Boolean) {
        if (dismissing) return
        if (showingExitOffer) { onDismiss?.invoke(); return }
        val index = (0 until screens.length()).indexOfFirst { screens.optJSONObject(it)?.optString("id") == activeScreenId }
        val screen = screens.optJSONObject(index)
        val closeSurvey = document.optJSONObject("surveys")?.optJSONObject("close")
        if (!skipCloseSurvey && index >= 0 && screen != null && closeSurvey != null && surveyedTriggers.add("close")) {
            presentSurvey("close", closeSurvey, screen) { dismissManually(skipCloseSurvey = true) }
            return
        }
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
        dismissing = true
        onDismiss?.invoke()
    }

    private fun presentSurvey(trigger: String, survey: JSONObject, screen: JSONObject, onContinue: () -> Unit) {
        val options = survey.optJSONArray("options") ?: JSONArray()
        val labels = (0 until options.length()).map { index ->
            val option = options.optJSONObject(index) ?: JSONObject()
            localizedValue(option.optString("label_lid"), screen) ?: "Answer ${index + 1}"
        }.toTypedArray()
        val activity = context as? Activity
        if (activity == null || activity.isFinishing || activity.isDestroyed) { onContinue(); return }
        var completed = false
        fun finish(optionId: String? = null) {
            if (completed) return
            completed = true
            if (optionId != null) {
                val event = JSONObject().put("paywall_id", document.optString("id")).put("survey_id", survey.optString("id"))
                    .put("trigger", trigger).put("option_id", optionId)
                purchases.logEvent("paywall_survey_response", event) {}
            }
            onContinue()
        }
        AlertDialog.Builder(activity)
            .setTitle(localizedValue(survey.optString("question_lid"), screen) ?: "Paywall survey")
            .setItems(labels) { _, index -> finish(options.optJSONObject(index)?.optString("id")) }
            .setNegativeButton(localizedValue(survey.optString("skip_label_lid"), screen) ?: "Skip") { _, _ -> finish() }
            .setOnCancelListener { finish() }
            .show()
    }

    private fun visibilityMatches(condition: JSONObject?): Boolean {
        if (condition == null) return true
        val mode = condition.optString("mode")
        val rules = condition.optJSONArray("rules") ?: return true
        if (mode !in setOf("all", "any") || rules.length() !in 1..8) return true
        val results = (0 until rules.length()).map { index ->
            val rule = rules.optJSONObject(index) ?: return true
            val reference = rule.optString("variable")
            if (!reference.startsWith("state.")) return true
            val name = reference.removePrefix("state.")
            val declaration = variableDeclarations.optJSONObject(name)
            val systemState = name in setOf("didCompleteTransaction", "didAbandonTransaction") && declaration == null
            if (declaration == null && !systemState) return true
            val current = variables.opt(name) ?: if (systemState) false else declaration?.opt("initial_value")
            val expected = rule.opt("value") ?: return true
            when (rule.optString("operator")) {
                "equals" -> if (current is Number && expected is Number) current.toDouble() == expected.toDouble() else current == expected
                "not_equals" -> if (current is Number && expected is Number) current.toDouble() != expected.toDouble() else current != expected
                "greater_than" -> (current as? Number)?.toDouble()?.let { left -> (expected as? Number)?.toDouble()?.let { left > it } } ?: return true
                "less_than" -> (current as? Number)?.toDouble()?.let { left -> (expected as? Number)?.toDouble()?.let { left < it } } ?: return true
                "greater_than_or_equal" -> (current as? Number)?.toDouble()?.let { left -> (expected as? Number)?.toDouble()?.let { left >= it } } ?: return true
                "contains" -> when (current) {
                    is JSONArray -> (0 until current.length()).any { current.optString(it) == expected.toString() }
                    is String -> current == expected.toString()
                    else -> false
                }
                "not_contains" -> when (current) {
                    is JSONArray -> (0 until current.length()).none { current.optString(it) == expected.toString() }
                    is String -> current != expected.toString()
                    else -> true
                }
                "less_than_or_equal" -> (current as? Number)?.toDouble()?.let { left -> (expected as? Number)?.toDouble()?.let { left <= it } } ?: return true
                else -> return true
            }
        }
        return if (mode == "all") results.all { it } else results.any { it }
    }

    private fun renderNode(node: JSONObject, screen: JSONObject): View {
        val kind = node.optString("kind")
        val properties = node.optJSONObject("properties") ?: JSONObject()
        if (!visibilityMatches(properties.optJSONObject("pushify_visibility"))) return View(context).apply { visibility = View.GONE; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        val children = node.optJSONArray("children") ?: JSONArray()
        val rendered = when (kind) {
            "stack", "hstack" -> LinearLayout(context).apply {
                orientation = if (kind == "hstack") LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
                val dimension = properties.optJSONObject("dimension") ?: JSONObject()
                gravity = if (kind == "hstack") {
                    when (dimension.optString("alignment")) {
                        "top" -> Gravity.TOP
                        "bottom" -> Gravity.BOTTOM
                        else -> Gravity.CENTER_VERTICAL
                    }
                } else {
                    when (dimension.optString("alignment")) {
                        "leading" -> Gravity.START
                        "trailing" -> Gravity.END
                        else -> Gravity.CENTER_HORIZONTAL
                    }
                }
                val padding = properties.optJSONObject("padding") ?: JSONObject()
                setPadding(dp(padding.optInt("leading")), dp(padding.optInt("top")), dp(padding.optInt("trailing")), dp(padding.optInt("bottom")))
                val shape = properties.optJSONObject("shape") ?: JSONObject()
                val corners = shape.optJSONObject("corners") ?: JSONObject()
                val radius = if (shape.optString("type") == "pill") 999 else listOf("top_leading", "top_trailing", "bottom_leading", "bottom_trailing").maxOfOrNull { corners.optDouble(it, 0.0) }?.toInt() ?: 0
                val border = properties.optJSONObject("border")
                val backgroundSpec = properties.optJSONObject("background")
                if (backgroundSpec != null || border?.optDouble("width", 0.0)?.let { it > 0 } == true) {
                    val base = backgroundSpec?.let(::paywallBackground) ?: ColorDrawable(Color.TRANSPARENT)
                    val drawable = when (base) {
                        is GradientDrawable -> base
                        is ColorDrawable -> GradientDrawable().apply { setColor(base.color) }
                        else -> GradientDrawable()
                    }
                    drawable.cornerRadius = dp(radius).toFloat()
                    if (border != null && border.optDouble("width", 0.0) > 0) {
                        drawable.setStroke(dp(border.optDouble("width").toInt().coerceIn(1, 12)), colorValue(border.optJSONObject("color"), Color.TRANSPARENT))
                    }
                    background = drawable
                }
                val spacing = dp(properties.optDouble("spacing", 0.0).toInt().coerceIn(0, 80))
                for (i in 0 until children.length()) children.optJSONObject(i)?.let { child ->
                    if (i > 0 && spacing > 0) addView(View(context), if (kind == "hstack") LinearLayout.LayoutParams(spacing, 1) else LinearLayout.LayoutParams(1, spacing))
                    val childView = renderNode(child, screen)
                    val childMargin = child.optJSONObject("properties")?.optJSONObject("margin") ?: JSONObject()
                    val params = lp(if (kind == "hstack") 0 else MATCH, WRAP, if (kind == "hstack") 1f else 0f).apply {
                        leftMargin = dp(childMargin.optInt("leading"))
                        topMargin = dp(childMargin.optInt("top"))
                        rightMargin = dp(childMargin.optInt("trailing"))
                        bottomMargin = dp(childMargin.optInt("bottom"))
                    }
                    addView(childView, params)
                }
            }
            "text", "title" -> TextView(context).apply {
                text = localized(node, screen)
                textSize = properties.optDouble("font_size", 20.0).toFloat().coerceIn(10f, 72f)
                gravity = Gravity.CENTER
                properties.optJSONObject("color")?.let { setTextColor(colorValue(it, currentTextColor, isDarkTheme())) }
                setTypeface(typeface, if (properties.optString("font_weight") in listOf("bold", "semibold")) Typeface.BOLD else Typeface.NORMAL)
                setPadding(0, dp(6), 0, dp(6))
            }
            "input" -> {
                val reference = properties.optString("state_variable")
                val name = reference.removePrefix("state.")
                val declaration = variableDeclarations.optJSONObject(name)
                if (!reference.startsWith("state.") || declaration == null || declaration.optString("type") != "state" || declaration.optString("value_type") != "text") return View(context)
                val labelKey = properties.optString("label_lid")
                val placeholderKey = properties.optString("placeholder_lid")
                val label = localizedValue(labelKey, screen)?.let(::interpolate).orEmpty().ifBlank { "Your response" }
                val maxLength = properties.optInt("max_length", 100).coerceIn(1, 500)
                LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(TextView(context).apply { text = label; contentDescription = label; textSize = 13f; setPadding(0, 0, 0, dp(4)) }, lp(MATCH, WRAP))
                    addView(EditText(context).apply {
                        tag = name
                        hint = localizedValue(placeholderKey, screen)?.let(::interpolate).orEmpty()
                        setText(variables.opt(name)?.toString() ?: declaration.optString("initial_value"))
                        filters = arrayOf(InputFilter.LengthFilter(maxLength))
                        inputType = when (properties.optString("keyboard")) {
                            "email" -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
                            "number" -> InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
                            else -> InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                        }
                        contentDescription = label
                        addTextChangedListener(object : TextWatcher {
                            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
                            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                                variables.put(name, s?.toString().orEmpty())
                                focusedInputVariable = name
                                focusedInputSelection = selectionStart.coerceAtLeast(0)
                                render()
                            }
                            override fun afterTextChanged(s: Editable?) = Unit
                        })
                    }, lp(MATCH, WRAP))
                }
            }
            "slider" -> {
                val reference = properties.optString("state_variable")
                val name = reference.removePrefix("state.")
                val declaration = variableDeclarations.optJSONObject(name)
                if (!reference.startsWith("state.") || declaration == null || declaration.optString("type") != "state" || declaration.optString("value_type") != "number") return View(context)
                val minimum = properties.optDouble("minimum", 0.0)
                val maximum = properties.optDouble("maximum", 100.0)
                val step = properties.optDouble("step", 1.0)
                val initial = variables.opt(name)?.let { it as? Number }?.toDouble() ?: declaration.optDouble("initial_value", minimum)
                val value = initial.coerceIn(minimum, maximum)
                val label = localizedValue(properties.optString("label_lid"), screen)?.let(::interpolate).orEmpty().ifBlank { "Choose a value" }
                val vertical = properties.optString("orientation") == "vertical"
                val divisions = if (step > 0) ((maximum - minimum) / step).roundToInt().coerceIn(1, 100_000) else 1000
                LinearLayout(context).apply {
                    orientation = if (vertical) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
                    if (!vertical) addView(LinearLayout(context).apply {
                        orientation = LinearLayout.HORIZONTAL
                        addView(TextView(context).apply { text = label; contentDescription = label }, LinearLayout.LayoutParams(0, WRAP, 1f))
                        addView(TextView(context).apply { text = value.toString(); contentDescription = value.toString() }, lp(WRAP, WRAP))
                    }, lp(MATCH, WRAP))
                    val seek = SeekBar(context).apply {
                        contentDescription = label
                        max = divisions
                        progress = if (step > 0) ((value - minimum) / step).roundToInt().coerceIn(0, divisions) else (((value - minimum) / (maximum - minimum)) * divisions).roundToInt().coerceIn(0, divisions)
                        if (vertical) rotation = -90f
                        setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                            override fun onProgressChanged(bar: SeekBar?, progress: Int, fromUser: Boolean) {
                                if (fromUser) {
                                    val next = if (step > 0) minimum + progress * step else minimum + (maximum - minimum) * progress / divisions
                                    variables.put(name, next.coerceIn(minimum, maximum))
                                }
                            }
                            override fun onStartTrackingTouch(bar: SeekBar?) = Unit
                            override fun onStopTrackingTouch(bar: SeekBar?) { render() }
                        })
                    }
                    if (vertical) addView(FrameLayout(context).apply { addView(seek, FrameLayout.LayoutParams(dp(180), dp(48), Gravity.CENTER)) }, lp(dp(48), dp(180)))
                    else addView(seek, lp(MATCH, WRAP))
                }
            }
            "multiple_choice" -> {
                val valueReference = properties.optString("state_variable")
                val labelReference = properties.optString("label_state_variable")
                val valueName = valueReference.removePrefix("state.")
                val labelName = labelReference.removePrefix("state.")
                val valueDeclaration = variableDeclarations.optJSONObject(valueName)
                val labelDeclaration = variableDeclarations.optJSONObject(labelName)
                val mode = properties.optString("mode", "single")
                if (!valueReference.startsWith("state.") || !labelReference.startsWith("state.") || valueDeclaration?.optString("value_type") != "selection" || labelDeclaration?.optString("value_type") != "text" || mode !in setOf("single", "multiple")) return View(context)
                val raw = variables.opt(valueName) ?: valueDeclaration.opt("initial_value")
                val selected = if (mode == "multiple") {
                    (raw as? JSONArray)?.let { array -> (0 until array.length()).map(array::optString).toSet() } ?: emptySet()
                } else setOfNotNull(raw as? String).filter(String::isNotEmpty).toSet()
                val options = properties.optJSONArray("options") ?: JSONArray()
                val ordered = (0 until options.length()).mapNotNull(options::optJSONObject).toMutableList()
                if (properties.optBoolean("randomize_order")) ordered.shuffle(Random(randomizationSeed xor node.optString("id").hashCode().toLong()))
                LinearLayout(context).apply {
                    orientation = if (properties.optString("layout") == "horizontal") LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
                    ordered.forEach { option ->
                        val optionValue = option.optString("value")
                        val label = localizedValue(option.optString("label_lid"), screen)?.let(::interpolate).orEmpty().ifBlank { optionValue }
                        val checked = optionValue in selected
                        val choice: TextView = if (mode == "multiple") CheckBox(context) else RadioButton(context)
                        choice.text = label
                        choice.contentDescription = label
                        choice.isSelected = checked
                        if (choice is CheckBox) choice.isChecked = checked
                        if (choice is RadioButton) choice.isChecked = checked
                        choice.setOnClickListener {
                            val next = if (mode == "multiple") {
                                if (checked) selected - optionValue else selected + optionValue
                            } else setOf(optionValue)
                            val nextValue: Any = if (mode == "multiple") JSONArray(next.toList()) else next.firstOrNull().orEmpty()
                            val labels = next.map { selectedValue ->
                                val selectedOption = ordered.firstOrNull { it.optString("value") == selectedValue }
                                selectedOption?.let { localizedValue(it.optString("label_lid"), screen)?.let(::interpolate)?.ifBlank { selectedValue } } ?: selectedValue
                            }
                            variables.put(valueName, nextValue)
                            variables.put(labelName, labels.joinToString(", "))
                            render()
                        }
                        addView(choice, lp(if (orientation == LinearLayout.HORIZONTAL) 0 else MATCH, WRAP, if (orientation == LinearLayout.HORIZONTAL) 1f else 0f))
                    }
                }
            }
            "picker" -> {
                val valueReference = properties.optString("state_variable")
                val labelReference = properties.optString("label_state_variable")
                val valueName = valueReference.removePrefix("state.")
                val labelName = labelReference.removePrefix("state.")
                if (!valueReference.startsWith("state.") || !labelReference.startsWith("state.") || variableDeclarations.optJSONObject(valueName)?.optString("value_type") != "selection" || variableDeclarations.optJSONObject(labelName)?.optString("value_type") != "text") return View(context)
                val options = properties.optJSONArray("options") ?: JSONArray()
                val entries = (0 until options.length()).mapNotNull(options::optJSONObject)
                val current = variables.optString(valueName)
                val selectedIndex = entries.indexOfFirst { it.optString("value") == current }
                val prompt = localizedValue(properties.optString("label_lid"), screen)?.let(::interpolate).orEmpty().ifBlank { "Choose an option" }
                val selectedLabel = entries.firstOrNull { it.optString("value") == current }
                    ?.let { localizedValue(it.optString("label_lid"), screen)?.let(::interpolate)?.ifBlank { current } } ?: "Choose an option"
                LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(TextView(context).apply { text = prompt; textSize = 12f }, lp(MATCH, WRAP))
                    addView(Button(context).apply {
                        text = selectedLabel
                        contentDescription = "$prompt, $selectedLabel"
                        setOnClickListener {
                            val labels = entries.map { option ->
                                localizedValue(option.optString("label_lid"), screen)?.let(::interpolate)?.ifBlank { option.optString("value") } ?: option.optString("value")
                            }
                            AlertDialog.Builder(context).setTitle(prompt).setSingleChoiceItems(labels.toTypedArray(), selectedIndex) { dialog, which ->
                                val option = entries.getOrNull(which)
                                if (option != null) {
                                    variables.put(valueName, option.optString("value"))
                                    variables.put(labelName, labels.getOrNull(which).orEmpty())
                                    dialog.dismiss()
                                    render()
                                }
                            }.setNegativeButton("Cancel", null).show()
                        }
                    }, lp(MATCH, WRAP))
                }
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
                setOnClickListener { performActionFeedback(this, properties.optJSONObject("action") ?: JSONObject()); runTapActions(node, properties, screen) }
            }
            "spacer" -> View(context).apply { layoutParams = lp(MATCH, dp(properties.optDouble("size", 8.0).toInt())) }
            "image" -> imageView(properties)
            "video" -> videoView(properties)
            "lottie" -> lottieView(properties)
            "icon" -> TextView(context).apply {
                text = iconGlyph(properties.optString("icon_name"))
                textSize = properties.optDouble("size", 24.0).toFloat().coerceIn(12f, 64f)
                gravity = Gravity.CENTER
                setTextColor(colorValue(properties.optJSONObject("color"), Color.rgb(49, 94, 232), isDarkTheme()))
                properties.optJSONObject("icon_background")?.let { iconBackground ->
                    val shape = iconBackground.optJSONObject("shape")?.optString("type")
                    background = GradientDrawable().apply {
                        this.shape = if (shape == "circle") GradientDrawable.OVAL else GradientDrawable.RECTANGLE
                        cornerRadius = dp(8).toFloat()
                        setColor(colorValue(iconBackground.optJSONObject("color"), Color.TRANSPARENT, isDarkTheme()))
                    }
                    setPadding(dp(6), dp(6), dp(6), dp(6))
                }
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
                    rail.addView(TextView(context).apply {
                        text = iconGlyph(icon?.optString("icon_name").orEmpty()); textSize = 18f; gravity = Gravity.CENTER
                        icon?.optJSONObject("color")?.let { setTextColor(colorValue(it, currentTextColor, isDarkTheme())) }
                        icon?.optJSONObject("icon_background")?.optJSONObject("color")?.let { color ->
                            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(colorValue(color, Color.TRANSPARENT, isDarkTheme())) }
                        }
                        contentDescription = icon?.optString("accessibility_label")
                    }, lp(dp(32), dp(32)))
                    if (i < items.length() - 1) rail.addView(View(context).apply {
                        val connector = item.optJSONObject("connector")?.optJSONObject("color")
                        setBackgroundColor(colorValue(connector, if (isDarkTheme()) Color.DKGRAY else Color.LTGRAY, isDarkTheme()))
                    }, lp(dp(2), dp(28)))
                    row.addView(rail, lp(dp(38), WRAP))
                    val copy = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(8), 0, 0, 0) }
                    nestedNode(item.optJSONObject("title"))?.let { copy.addView(renderNode(it, screen), lp(MATCH, WRAP)) }
                    nestedNode(item.optJSONObject("description"))?.let { copy.addView(renderNode(it, screen), lp(MATCH, WRAP)) }
                    row.addView(copy, lp(0, WRAP, 1f)); addView(row, lp(MATCH, WRAP))
                }
            }
            "carousel" -> LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                val pages = properties.optJSONArray("pages") ?: JSONArray()
                val pageNodes = (0 until pages.length()).mapNotNull { pages.optJSONObject(it)?.let(::nestedNode) }
                val carouselId = node.optString("id").ifBlank { "carousel" }
                val spacing = dp(properties.optInt("page_spacing", 12).coerceIn(0, 80))
                val pageWidth = (resources.displayMetrics.widthPixels - dp(32)).coerceAtLeast(dp(1))
                val pageControl = properties.optJSONObject("page_control")
                val defaultStyle = pageControl?.optJSONObject("default")
                val activeStyle = pageControl?.optJSONObject("active")
                val dots = LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                    setPadding(dp(pageControl?.optJSONObject("padding")?.optInt("leading") ?: 0), dp(pageControl?.optJSONObject("padding")?.optInt("top") ?: 8), dp(pageControl?.optJSONObject("padding")?.optInt("trailing") ?: 0), dp(pageControl?.optJSONObject("padding")?.optInt("bottom") ?: 8))
                }
                val dotViews = pageNodes.indices.map { index ->
                    View(context).also { dot ->
                        val style = if (index == (carouselPages[carouselId] ?: properties.optInt("initial_page_index", 0))) activeStyle else defaultStyle
                        dot.background = GradientDrawable().apply {
                            shape = GradientDrawable.OVAL
                            setColor(colorValue(style?.optJSONObject("color"), if (index == 0) Color.DKGRAY else Color.LTGRAY, isDarkTheme()))
                        }
                        val dotWidth = dp((style?.optInt("width") ?: 6).coerceIn(2, 32))
                        val dotHeight = dp((style?.optInt("height") ?: 6).coerceIn(2, 32))
                        dots.addView(dot, LinearLayout.LayoutParams(dotWidth, dotHeight).apply {
                            marginStart = dp(pageControl?.optInt("spacing", 6)?.coerceIn(0, 32) ?: 6)
                            marginEnd = dp(pageControl?.optInt("spacing", 6)?.coerceIn(0, 32) ?: 6)
                        })
                    }
                }
                fun updateDots(selected: Int) {
                    dotViews.forEachIndexed { index, dot ->
                        val style = if (index == selected) activeStyle else defaultStyle
                        val width = dp((style?.optInt("width") ?: if (index == selected) 18 else 6).coerceIn(2, 32))
                        val height = dp((style?.optInt("height") ?: 6).coerceIn(2, 32))
                        dot.layoutParams = (dot.layoutParams as LinearLayout.LayoutParams).apply { this.width = width; this.height = height }
                        dot.background = GradientDrawable().apply {
                            shape = GradientDrawable.OVAL
                            setColor(colorValue(style?.optJSONObject("color"), if (index == selected) Color.DKGRAY else Color.LTGRAY, isDarkTheme()))
                        }
                    }
                }
                val auto = properties.optJSONObject("auto_advance")
                val interval = auto?.optInt("ms_time_per_page", 0)?.coerceIn(1000, 60000) ?: 0
                val animationScale = android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
                val reducedMotion = animationScale <= 0f || (android.os.Build.VERSION.SDK_INT >= 26 && !android.animation.ValueAnimator.areAnimatorsEnabled())
                val scroll = object : HorizontalScrollView(context) {
                    private val advance = object : Runnable {
                        override fun run() {
                            if (pageNodes.size < 2 || interval == 0 || reducedMotion) return
                            val width = getChildAt(0)?.width?.coerceAtLeast(1) ?: pageWidth
                            val current = (carouselPages[carouselId] ?: properties.optInt("initial_page_index", 0)).coerceIn(0, pageNodes.lastIndex)
                            if (current == pageNodes.lastIndex && !properties.optBoolean("loop", false)) return
                            val next = if (current == pageNodes.lastIndex) 0 else current + 1
                            carouselPages[carouselId] = next
                            updateDots(next)
                            smoothScrollTo(next * (width + spacing), 0)
                            postDelayed(this, interval.toLong())
                        }
                    }
                    override fun onAttachedToWindow() {
                        super.onAttachedToWindow()
                        val selected = (carouselPages[carouselId] ?: properties.optInt("initial_page_index", 0)).coerceIn(0, (pageNodes.size - 1).coerceAtLeast(0))
                        post { scrollTo(selected * (pageWidth + spacing), 0) }
                        if (pageNodes.size > 1 && interval > 0 && !reducedMotion) postDelayed(advance, interval.toLong())
                    }
                    override fun onDetachedFromWindow() {
                        removeCallbacks(advance)
                        super.onDetachedFromWindow()
                    }
                }.apply {
                    isHorizontalScrollBarEnabled = false
                    clipToPadding = false
                    for (page in pageNodes) addView(renderNode(page, screen), LinearLayout.LayoutParams(pageWidth, WRAP).apply { rightMargin = spacing })
                    setOnScrollChangeListener { _, scrollX, _, _, _ ->
                        val stride = (pageWidth + spacing).coerceAtLeast(1)
                        val selected = (scrollX + stride / 2) / stride
                        if (pageNodes.isNotEmpty()) {
                            val bounded = selected.coerceIn(0, pageNodes.lastIndex)
                            carouselPages[carouselId] = bounded
                            updateDots(bounded)
                        }
                    }
                }
                addView(scroll, lp(MATCH, WRAP))
                if (pageNodes.size > 1 && pageControl != null) addView(dots, lp(MATCH, WRAP))
                updateDots((carouselPages[carouselId] ?: properties.optInt("initial_page_index", 0)).coerceIn(0, (pageNodes.size - 1).coerceAtLeast(0)))
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
            "countdown" -> FrameLayout(context).apply {
                val duration = properties.optLong("duration_seconds", 0L)
                val id = node.optString("id", "countdown")
                val endMillis = if (duration > 0) {
                    countdownStartedAtMs.getOrPut(id) { System.currentTimeMillis() } + duration * 1000
                } else {
                    val date = properties.optJSONObject("style")?.optString("date")
                    runCatching { java.time.Instant.parse(date).toEpochMilli() }.getOrNull()
                }
                val template = findNodeText(properties.optJSONObject("countdown_stack"))
                val endedText = findNodeText(properties.optJSONObject("end_stack"))
                val timerText = TextView(context).apply {
                    gravity = Gravity.CENTER
                    textSize = 16f
                    setTypeface(typeface, Typeface.BOLD)
                    contentDescription = "Offer countdown"
                }
                if (endMillis != null && endMillis > System.currentTimeMillis()) {
                    val timer = object : android.os.CountDownTimer(endMillis - System.currentTimeMillis(), 1000) {
                        override fun onTick(millis: Long) { timerText.text = countdownText(millis, template) }
                        override fun onFinish() {
                            removeAllViews()
                            val ended = nestedNode(properties.optJSONObject("end_stack"))?.let { renderNode(it, screen) }
                            if (ended != null) addView(ended, lp(MATCH, WRAP))
                            else { timerText.text = endedText ?: "Offer ended"; addView(timerText, lp(MATCH, WRAP)) }
                        }
                    }
                    timerText.text = countdownText(endMillis - System.currentTimeMillis(), template)
                    addView(timerText, lp(MATCH, WRAP))
                    timer.start(); addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener { override fun onViewAttachedToWindow(view: View) = Unit; override fun onViewDetachedFromWindow(view: View) { timer.cancel() } })
                } else {
                    val ended = nestedNode(properties.optJSONObject("end_stack"))?.let { renderNode(it, screen) }
                    if (ended != null) addView(ended, lp(MATCH, WRAP))
                    else { timerText.text = endedText ?: "Offer ended"; addView(timerText, lp(MATCH, WRAP)) }
                }
            }
            "web_view" -> {
                val wheel = properties.optJSONObject("pushify_discount_wheel")
                if (wheel?.optInt("version") == 1) renderDiscountWheel(node, wheel, screen) else {
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
            }
            "tab_control" -> View(context)
            else -> if (children.length() > 0) LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                for (i in 0 until children.length()) children.optJSONObject(i)?.let { addView(renderNode(it, screen), lp(MATCH, WRAP)) }
            } else TextView(context).apply { text = properties.optString("text") }
        }
        val accessibility = properties.optJSONObject("pushify_accessibility")
        val role = accessibility?.optString("role").orEmpty()
        if (accessibility?.optBoolean("hidden", false) == true || role == "presentation") {
            rendered.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        } else {
            accessibility?.optString("label")?.takeIf { it.isNotBlank() }?.let { rendered.contentDescription = it }
            val className = when (role) {
                "button" -> "android.widget.Button"
                "link" -> "android.widget.TextView"
                "image" -> "android.widget.ImageView"
                "heading" -> "android.widget.TextView"
                "alert" -> "android.widget.TextView"
                "dialog" -> "android.app.Dialog"
                else -> null
            }
            if (className != null || role == "heading" || role == "alert") {
                rendered.accessibilityDelegate = object : android.view.View.AccessibilityDelegate() {
                    override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfo) {
                        super.onInitializeAccessibilityNodeInfo(host, info)
                        if (className != null) info.className = className
                        if (role == "heading" && android.os.Build.VERSION.SDK_INT >= 28) info.isHeading = true
                        if (role == "alert" && android.os.Build.VERSION.SDK_INT >= 19) info.liveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
                    }
                }
            }
        }
        val motion = properties.optJSONObject("pushify_motion")
        if (motion?.optBoolean("enabled", false) == true) {
            val density = resources.displayMetrics.density
            val x = motion.optDouble("x", 0.0).toFloat() * density
            val y = motion.optDouble("y", 16.0).toFloat() * density
            val rotation = motion.optDouble("rotation", 0.0).toFloat()
            val scale = motion.optDouble("scale", 1.0).toFloat()
            val opacity = motion.optDouble("opacity", 0.0).toFloat()
            val animationScale = android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
            val reducedMotion = animationScale <= 0f || (android.os.Build.VERSION.SDK_INT >= 26 && !android.animation.ValueAnimator.areAnimatorsEnabled())
            if (reducedMotion) {
                rendered.translationX = 0f; rendered.translationY = 0f; rendered.rotation = 0f
                rendered.scaleX = 1f; rendered.scaleY = 1f; rendered.alpha = 1f
            } else {
                rendered.translationX = x; rendered.translationY = y; rendered.rotation = rotation
                rendered.scaleX = scale; rendered.scaleY = scale; rendered.alpha = opacity
                val duration = motion.optLong("duration_ms", 400L).coerceIn(0L, 5000L)
                val delay = motion.optLong("delay_ms", 0L).coerceIn(0L, 10000L)
                val interpolator = when (motion.optString("easing")) {
                    "linear" -> android.view.animation.LinearInterpolator()
                    "ease_in" -> android.view.animation.AccelerateInterpolator()
                    "ease_in_out" -> android.view.animation.AccelerateDecelerateInterpolator()
                    else -> android.view.animation.DecelerateInterpolator()
                }
                rendered.post {
                    rendered.animate().translationX(0f).translationY(0f).rotation(0f).scaleX(1f).scaleY(1f).alpha(1f)
                        .setStartDelay(delay).setDuration(duration).setInterpolator(interpolator).start()
                }
            }
        }
        return rendered
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

    private fun lottieView(properties: JSONObject): View {
        val url = properties.optString("url")
        val height = properties.optJSONObject("size")?.optJSONObject("height")?.optDouble("value", 180.0)?.toInt()?.coerceIn(1, 2000) ?: 180
        val label = properties.optString("accessibility_label", "Animation")
        if (!url.startsWith("https://")) return TextView(context).apply {
            text = "Animation unavailable"
            contentDescription = "$label unavailable"
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(8), dp(8), dp(8))
            layoutParams = lp(MATCH, dp(height))
        }
        return LottieAnimationView(context).apply {
            contentDescription = label
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            scaleType = if (properties.optString("fit_mode") == "fill") ImageView.ScaleType.CENTER_CROP else ImageView.ScaleType.FIT_CENTER
            repeatCount = if (properties.optBoolean("loop", true)) LottieDrawable.INFINITE else 0
            setFailureListener {
                main.post {
                    contentDescription = "$label unavailable"
                    val fallback = TextView(context).apply { text = "Animation unavailable"; gravity = Gravity.CENTER; contentDescription = "$label unavailable" }
                    (parent as? ViewGroup)?.let { group -> val index = group.indexOfChild(this); group.removeView(this); group.addView(fallback, index, layoutParams) }
                }
            }
            setAnimationFromUrl(url)
            val animationsAllowed = android.os.Build.VERSION.SDK_INT < 26 || android.animation.ValueAnimator.areAnimatorsEnabled()
            if (properties.optBoolean("auto_play", true) && animationsAllowed) playAnimation() else progress = 0f
            layoutParams = lp(MATCH, dp(height))
        }
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

    private fun eligibleDiscountWheelPrizes(config: JSONObject): List<EligibleDiscountWheelPrize> {
        val prizes = config.optJSONArray("prizes") ?: return emptyList()
        val result = mutableListOf<EligibleDiscountWheelPrize>()
        for (index in 0 until prizes.length()) {
            val prize = prizes.optJSONObject(index) ?: continue
            val packageId = prize.optString("package_id").takeIf(String::isNotBlank) ?: continue
            val packageItem = (0 until packages.length()).mapNotNull(packages::optJSONObject).firstOrNull { it.optString("id") == packageId } ?: continue
            val product = packageItem.optJSONObject("product") ?: continue
            val offerID = prize.optString("android_offer_id").takeIf(String::isNotBlank) ?: continue
            val offers = product.optJSONArray("eligible_store_offers") ?: continue
            val offer = (0 until offers.length()).mapNotNull(offers::optJSONObject).firstOrNull {
                it.optString("offer_id") == offerID && it.optString("offer_type") == "google_play_subscription" && it.optBoolean("eligible") &&
                    (product.optString("plan_id").isBlank() || it.optString("base_plan_id") == product.optString("plan_id"))
            } ?: continue
            result += EligibleDiscountWheelPrize(prize, packageItem, offer)
        }
        return result
    }

    private fun renderDiscountWheel(node: JSONObject, config: JSONObject, screen: JSONObject): View {
        val eligible = eligibleDiscountWheelPrizes(config)
        if (eligible.isEmpty()) return nestedNode(node.optJSONObject("fallback"))?.let { renderNode(it, screen) }
            ?: TextView(context).apply { text = "No Google Play introductory offers are currently eligible."; gravity = Gravity.CENTER; setPadding(dp(12), dp(12), dp(12), dp(12)); contentDescription = text }
        val wheelSectors = (0 until 8).map { sectorIndex -> minOf(eligible.size - 1, sectorIndex * eligible.size / 8) }
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }
        val size = dp(300)
        val wheel = object : View(context) {
            private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            override fun onDraw(canvas: Canvas) {
                super.onDraw(canvas)
                val diameter = minOf(width, height).toFloat() - dp(8)
                val left = (width - diameter) / 2f
                val top = (height - diameter) / 2f
                val bounds = RectF(left, top, left + diameter, top + diameter)
                val sweep = 360f / wheelSectors.size
                wheelSectors.forEachIndexed { index, eligibleIndex ->
                    val item = eligible[eligibleIndex]
                    paint.color = if (index == (discountWheelPrize?.optInt("wheel_index") ?: -1)) Color.rgb(255, 135, 60) else Color.rgb(251, 248, 227)
                    canvas.drawArc(bounds, -90f + index * sweep, sweep, true, paint)
                    paint.style = Paint.Style.STROKE
                    paint.strokeWidth = dp(2).toFloat()
                    paint.color = Color.WHITE
                    canvas.drawArc(bounds, -90f + index * sweep, sweep, true, paint)
                    paint.style = Paint.Style.FILL
                    val label = localizedValue(item.prize.optString("label_lid"), screen)?.take(16) ?: "Offer ${index + 1}"
                    paint.color = Color.rgb(25, 29, 35)
                    paint.textSize = dp(12).toFloat()
                    paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                    val angle = Math.toRadians((-90f + index * sweep + sweep / 2).toDouble())
                    val radius = diameter * .34f
                    val x = (width / 2f + kotlin.math.cos(angle) * radius - paint.measureText(label) / 2).toFloat()
                    val y = (height / 2f + kotlin.math.sin(angle) * radius + paint.textSize / 3).toFloat()
                    canvas.drawText(label, x, y, paint)
                }
                paint.color = Color.rgb(32, 180, 90)
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = dp(7).toFloat()
                canvas.drawCircle(width / 2f, height / 2f, diameter / 2f, paint)
                paint.style = Paint.Style.FILL
            }
        }.apply {
            rotation = discountWheelRotation
            contentDescription = "Eight-sector wheel with ${eligible.size} eligible Google Play offers"
        }
        val wheelFrame = FrameLayout(context).apply {
            addView(wheel, FrameLayout.LayoutParams(size, size, Gravity.CENTER))
            addView(TextView(context).apply { text = "▼"; textSize = 18f; gravity = Gravity.CENTER; setTextColor(Color.rgb(255, 135, 60)); contentDescription = "Wheel pointer" }, FrameLayout.LayoutParams(dp(28), dp(24), Gravity.TOP or Gravity.CENTER_HORIZONTAL))
        }
        root.addView(wheelFrame, lp(size, size))
        val result = TextView(context).apply { gravity = Gravity.CENTER; textSize = 12f; setPadding(dp(4), dp(8), dp(4), dp(6)); contentDescription = "Discount wheel result" }
        val spin = Button(context).apply {
            text = if (discountWheelPrize == null) "SPIN" else "✓"
            textSize = 10f
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.rgb(32, 180, 90)); setStroke(dp(4), Color.WHITE) }
            contentDescription = "Spin once among the current eligible Google Play subscription offers"
            setOnClickListener {
                if (discountWheelUsed || busy) return@setOnClickListener
                val prizeIndex = eligible.indices.random()
                val selected = eligible[prizeIndex]
                val matchingSectors = wheelSectors.indices.filter { wheelSectors[it] == prizeIndex }
                val wheelIndex = matchingSectors.randomOrNull() ?: 0
                val label = localizedValue(selected.prize.optString("label_lid"), screen)?.ifBlank { null } ?: "Selected offer"
                discountWheelPrize = JSONObject().put("package_id", selected.packageItem.optString("id")).put("offer_id", selected.offer.optString("offer_id"))
                    .put("wheel_index", wheelIndex)
                    .put("label", label).put("intro_price", selected.offer.optString("localized_price"))
                    .put("intro_period", selected.offer.optString("billing_period")).put("renewal_price", selected.offer.optString("renewal_price"))
                    .put("renewal_period", selected.offer.optString("renewal_period"))
                selectedPackageId = selected.packageItem.optString("id")
                discountWheelUsed = true
                busy = true
                isEnabled = false
                text = "Spinning…"
                val target = discountWheelRotation + 360f * 5 + 360f - (wheelIndex + .5f) * (360f / wheelSectors.size)
                val duration = if (android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f) 0L else 8000L
                wheel.animate().rotation(target).setDuration(duration).withEndAction {
                    discountWheelRotation = target % 360f
                    busy = false
                    val prize = discountWheelPrize ?: JSONObject()
                    val intro = listOf(prize.optString("intro_price"), prize.optString("intro_period")).filter(String::isNotBlank).joinToString(" for ")
                    val renewal = listOf(prize.optString("renewal_price"), prize.optString("renewal_period")).filter(String::isNotBlank).joinToString(" / ")
                    result.text = listOf(prize.optString("label"), listOf(intro, renewal).filter(String::isNotBlank).joinToString(", then "), "Continue below to purchase with Google Play.").filter(String::isNotBlank).joinToString(" · ")
                    render()
                }.start()
            }
        }
        root.addView(result, lp(MATCH, WRAP))
        wheelFrame.addView(spin, FrameLayout.LayoutParams(dp(58), dp(58), Gravity.CENTER))
        if (discountWheelPrize != null) {
            val prize = discountWheelPrize!!
            val intro = listOf(prize.optString("intro_price"), prize.optString("intro_period")).filter(String::isNotBlank).joinToString(" for ")
            val renewal = listOf(prize.optString("renewal_price"), prize.optString("renewal_period")).filter(String::isNotBlank).joinToString(" / ")
            result.text = listOf(prize.optString("label"), listOf(intro, renewal).filter(String::isNotBlank).joinToString(", then "), "Continue below to purchase with Google Play.").filter(String::isNotBlank).joinToString(" · ")
            spin.isEnabled = false
            spin.text = "Offer selected"
        }
        if (discountWheelPrize == null || android.provider.Settings.Global.getFloat(context.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f) return root
        return FrameLayout(context).apply {
            addView(root, FrameLayout.LayoutParams(MATCH, WRAP))
            addView(DiscountWheelConfetti(context), FrameLayout.LayoutParams(MATCH, MATCH))
        }
    }

    private inner class DiscountWheelConfetti(context: Context) : View(context) {
        private val startedAt = SystemClock.uptimeMillis()
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val colors = intArrayOf(Color.rgb(112, 208, 0), Color.rgb(245, 230, 99), Color.rgb(255, 155, 53), Color.rgb(181, 235, 50), Color.WHITE)

        init { isClickable = false; importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO; postInvalidateOnAnimation() }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val progress = ((SystemClock.uptimeMillis() - startedAt) / 6000f).coerceIn(0f, 1f)
            for (index in 0 until 42) {
                val angle = index * 2.3999632
                val spread = 18f + (index % 7) * 3f
                val x = width * .5f + kotlin.math.cos(angle).toFloat() * (spread + progress * 105f)
                val y = height * .46f + kotlin.math.sin(angle).toFloat() * spread - (index % 4) * progress * 42f + progress * progress * 380f
                paint.color = colors[index % colors.size]
                paint.alpha = ((1f - progress) * 255).toInt().coerceIn(0, 255)
                canvas.save()
                canvas.rotate((angle * 180 / Math.PI + progress * 460).toFloat(), x, y)
                canvas.drawRect(x - dp(2), y - dp(4), x + dp(2), y + dp(4), paint)
                canvas.restore()
            }
            if (progress < 1f) postInvalidateOnAnimation()
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
        val reminder = trialReminderRequest(screen)
        val wheelOffer = discountWheelPrize?.takeIf { it.optString("package_id") == productId }?.optString("offer_id")?.takeIf(String::isNotBlank)
        purchases.purchase(activity, productId, reminder, wheelOffer) { result ->
            busy = false
            result.onSuccess { outcome ->
                when (outcome) {
                    is PushifyPurchases.PurchaseOutcome.Purchased -> {
                        transactionProducts.clear()
                        (0 until packages.length()).mapNotNull(packages::optJSONObject).firstOrNull { it.optString("id") == productId }
                            ?.optJSONObject("product")?.let { transactionProducts["purchased"] = JSONObject(it.toString()) }
                        setTransactionState(completed = true)
                        val survey = document.optJSONObject("surveys")?.optJSONObject("post_purchase")
                        if (survey != null && surveyedTriggers.add("post_purchase") && screen != null) presentSurvey("post_purchase", survey, screen) { runPurchaseOutcome("after_purchase", "close", action, screen) }
                        else runPurchaseOutcome("after_purchase", "close", action, screen)
                    }
                    PushifyPurchases.PurchaseOutcome.Cancelled -> {
                        transactionProducts.clear()
                        (0 until packages.length()).mapNotNull(packages::optJSONObject).firstOrNull { it.optString("id") == productId }
                            ?.optJSONObject("product")?.let { transactionProducts["abandoned"] = JSONObject(it.toString()) }
                        setTransactionState(completed = false)
                        runPurchaseOutcome("on_abandon", "none", action, screen)
                    }
                    PushifyPurchases.PurchaseOutcome.Pending -> { message = "Purchase is pending approval."; render() }
                }
            }.onFailure { error ->
                if (wheelOffer != null && (error as? PushifyPurchases.PushifyApiException)?.code == "offer_unavailable") {
                    discountWheelPrize = null
                    discountWheelUsed = false
                    message = "That offer is no longer available. Spin again or continue with the regular package price."
                } else message = "Purchase could not be completed. Please try again."
                render()
            }
        }
    }

    private fun setTransactionState(completed: Boolean) {
        if (!variableDeclarations.has("didCompleteTransaction")) variables.put("didCompleteTransaction", completed)
        if (!variableDeclarations.has("didAbandonTransaction")) variables.put("didAbandonTransaction", !completed)
        render()
    }

    private fun trialReminderRequest(screen: JSONObject?): JSONObject? {
        val reminder = document.optJSONObject("trial_reminder") ?: return null
        if (screen == null) return null
        val titleKey = reminder.optString("title_lid").takeIf(String::isNotBlank) ?: return null
        val bodyKey = reminder.optString("body_lid").takeIf(String::isNotBlank) ?: return null
        val title = localizedValue(titleKey, screen) ?: return null
        val body = localizedValue(bodyKey, screen) ?: return null
        val subtitleKey = reminder.optString("subtitle_lid").takeIf(String::isNotBlank)
        return JSONObject(reminder.toString())
            .put("title", title)
            .put("body", body)
            .put("subtitle", subtitleKey?.let { localizedValue(it, screen).orEmpty() }.orEmpty())
    }

    private fun runPurchaseOutcome(key: String, fallback: String, action: JSONObject, screen: JSONObject?) {
        val steps = action.optJSONObject("pushify_actions")?.optJSONArray(key) ?: JSONArray()
        fun finish() {
            val type = action.optJSONObject(key)?.optString("type")?.takeIf(String::isNotBlank) ?: fallback
            if (type == "none") return
            if (type == "close") { dismissing = true; onDismiss?.invoke(); return }
            val index = (0 until screens.length()).indexOfFirst { screens.optJSONObject(it)?.optString("id") == screen?.optString("id") }
            when (type) {
                "navigate_back" -> if (index > 0) { activeScreenId = screens.optJSONObject(index - 1)?.optString("id").orEmpty(); render() } else { dismissing = true; onDismiss?.invoke() }
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
                "custom_placement" -> { dispatchCustomPlacement(step); runStep(at + 1) }
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

    private fun interpolate(value: String): String = Regex("\\{\\{\\s*(?:state\\.([A-Za-z_][A-Za-z0-9_]*)|callbacks\\.([A-Za-z_][A-Za-z0-9_]*)\\.data\\.([A-Za-z_][A-Za-z0-9_.-]*)|products\\.(purchased|abandoned)\\.([A-Za-z_][A-Za-z0-9_]*))\\s*}}")
        .replace(value) { match ->
            val stateName = match.groupValues[1]
            if (stateName.isNotEmpty()) when (val state = variables.opt(stateName)) {
                is JSONArray -> (0 until state.length()).joinToString(", ") { state.optString(it) }
                null, JSONObject.NULL -> match.value
                else -> state.toString()
            } else if (match.groupValues[4].isNotEmpty()) {
                val product = transactionProducts[match.groupValues[4]] ?: return@replace match.value
                val peers = offering.optJSONArray("packages")?.let { packages -> (0 until packages.length()).mapNotNull { packages.optJSONObject(it)?.optJSONObject("product") } }.orEmpty()
                val result = productAliasValue(match.groupValues[5], product, peers)
                if (result == null || result == JSONObject.NULL) match.value else result.toString()
            } else when (val result = callbackData.optJSONObject(match.groupValues[2])?.opt(match.groupValues[3])) {
                null, JSONObject.NULL -> match.value
                is JSONArray -> (0 until result.length()).joinToString(", ") { result.optString(it) }
                else -> result.toString()
            }
        }

    private data class AliasPeriod(val count: Int, val unit: String, val days: Int)

    private fun productAliasValue(field: String, product: JSONObject, peers: List<JSONObject>): Any? {
        val deviceLocale = java.util.Locale.getDefault().toLanguageTag()
        val wordsByLocale = offering.optJSONObject("variable_localizations") ?: JSONObject()
        val words = wordsByLocale.optJSONObject(deviceLocale)
            ?: wordsByLocale.optJSONObject(deviceLocale.replace('-', '_'))
            ?: wordsByLocale.optJSONObject(document.optString("default_locale", "en_US"))
            ?: wordsByLocale.optJSONObject("en_US") ?: JSONObject()
        val period = parseAliasPeriod(product.optString("duration").takeIf(String::isNotBlank))
        val trial = parseAliasPeriod(product.optString("trial_duration").takeIf(String::isNotBlank))
        val amount = product.optString("price_amount").toDoubleOrNull()
        val currencyCode = product.optString("currency_code").takeIf(String::isNotBlank)
        fun currencyFormatter(): java.text.NumberFormat? = currencyCode?.let { code ->
            java.text.NumberFormat.getCurrencyInstance(java.util.Locale.forLanguageTag(deviceLocale)).apply { currency = java.util.Currency.getInstance(code) }
        }
        fun money(value: Double): String? = currencyFormatter()?.format(value)
        fun periodCount(unit: String): Double? = period?.let { aliasUnitsIn(it, unit) }
        fun count(value: AliasPeriod): String = (words.optString("num_${value.unit}_${if (value.count == 1) "one" else "other"}", "%d ${value.unit}${if (value.count == 1) "" else "s"}")).replace("%d", value.count.toString())
        fun unit(value: AliasPeriod, short: Boolean = false): String {
            if (value.count > 1) return words.optString(if (short) "num_${value.unit}s_short" else "num_${value.unit}_other", if (short) "%d${value.unit.first()}" else "%d ${value.unit}s").replace("%d", value.count.toString())
            return words.optString(if (short) "${value.unit}_short" else value.unit, value.unit)
        }
        return when (field) {
            "price", "localized_price" -> product.opt("localized_price")
            "product_id" -> product.opt("product_id")
            "store_product_name" -> product.opt("display_name")
            "currency_code" -> product.opt("currency_code")
            "currency_symbol" -> currencyFormatter()?.currency?.symbol
            "period" -> period?.let { unit(it) } ?: ""
            "period_abbreviated" -> period?.let { unit(it, true) } ?: ""
            "periodly" -> if (period == null) "" else if (period.count > 1) count(period) else words.optString(mapOf("day" to "daily", "week" to "weekly", "month" to "monthly", "year" to "yearly")[period.unit], "")
            "period_with_unit" -> period?.let(::count) ?: ""
            "period_in_days", "period_in_weeks", "period_in_months", "period_in_years" -> period?.let { aliasPeriodIn(it, field.removePrefix("period_in_").removeSuffix("s"))?.toString() } ?: ""
            "price_per_period", "price_per_period_abbreviated" -> product.optString("localized_price").takeIf(String::isNotBlank)?.let { price -> period?.let { "$price/${unit(it, field.endsWith("abbreviated"))}" } ?: price }
            "price_per_day", "price_per_week", "price_per_month", "price_per_year" -> {
                val target = field.removePrefix("price_per_")
                val units = periodCount(target)
                val formatter = currencyFormatter()
                if (amount == null || formatter == null) null else {
                    val scale = Math.pow(10.0, formatter.maximumFractionDigits.toDouble())
                    money(if (units == null || units <= 0) amount else kotlin.math.floor(amount / units * scale) / scale)
                }
            }
            "relative_discount" -> {
                if (amount == null || period == null || currencyCode == null) "" else {
                    val monthly = amount / aliasUnitsIn(period, "month")
                    val top = peers.asSequence().filter { it.optString("currency_code") == currencyCode }
                        .mapNotNull { peer ->
                            val peerAmount = peer.optString("price_amount").toDoubleOrNull()
                            val peerPeriod = parseAliasPeriod(peer.optString("duration").takeIf(String::isNotBlank))
                            if (peerAmount == null || peerPeriod == null) null else peerAmount / aliasUnitsIn(peerPeriod, "month")
                        }.maxOrNull() ?: 0.0
                    if (top <= monthly) "" else words.optString("percent", "%d%%").replace("%d", (((1 - monthly / top) * 100).roundToInt()).toString()).replace("%%", "%")
                }
            }
            "offer_price", "offer_price_per_day", "offer_price_per_week", "offer_price_per_month", "offer_price_per_year" -> if (trial != null) words.optString("free_price", "free") else product.opt("localized_price")
            "offer_price_with_zero" -> if (trial != null) money(0.0) else product.opt("localized_price")
            "offer_period" -> trial?.let { unit(AliasPeriod(1, it.unit, it.days)) } ?: ""
            "offer_period_abbreviated" -> trial?.let { unit(AliasPeriod(1, it.unit, it.days), true) } ?: ""
            "offer_period_with_unit" -> trial?.let(::count) ?: ""
            "offer_period_in_days", "offer_period_in_weeks", "offer_period_in_months", "offer_period_in_years" -> trial?.let { aliasPeriodIn(it, field.removePrefix("offer_period_in_").removeSuffix("s"))?.toString() } ?: ""
            "offer_end_date" -> trial?.let { "in ${it.days} day${if (it.days == 1) "" else "s"}" } ?: ""
            "secondary_offer_price", "secondary_offer_period", "secondary_offer_period_abbreviated" -> ""
            else -> null
        }
    }

    private fun parseAliasPeriod(raw: String?): AliasPeriod? {
        if (raw == null) return null
        val match = Regex("^P(?:(\\d+)Y)?(?:(\\d+)M)?(?:(\\d+)W)?(?:(\\d+)D)?$").matchEntire(raw) ?: return null
        val units = listOf("year", "month", "week", "day")
        val days = listOf(365, 30, 7, 1)
        val parts = (1..4).mapNotNull { index -> match.groupValues[index].toIntOrNull()?.takeIf { it > 0 }?.let { Triple(it, units[index - 1], days[index - 1]) } }
        if (parts.isEmpty()) return null
        if (parts.size == 1) return AliasPeriod(parts[0].first, parts[0].second, parts[0].first * parts[0].third)
        val total = parts.sumOf { it.first * it.third }
        return AliasPeriod(total, "day", total)
    }

    private fun aliasUnitsIn(period: AliasPeriod, unit: String): Double {
        val factors = mapOf(
            "day" to mapOf("day" to 1.0, "week" to 1.0 / 7, "month" to 1.0 / 30, "year" to 1.0 / 365),
            "week" to mapOf("day" to 7.0, "week" to 1.0, "month" to 7.0 * 12 / 365, "year" to 7.0 / 365),
            "month" to mapOf("day" to 30.0, "week" to 365.0 / 12 / 7, "month" to 1.0, "year" to 1.0 / 12),
            "year" to mapOf("day" to 365.0, "week" to 365.0 / 7, "month" to 12.0, "year" to 1.0),
        )
        return period.count * factors.getValue(period.unit).getValue(unit)
    }

    private fun aliasPeriodIn(period: AliasPeriod, unit: String): Int = aliasUnitsIn(period, unit).roundToInt()

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

    private fun runTapActions(node: JSONObject, properties: JSONObject, screen: JSONObject) {
        val action = properties.optJSONObject("action") ?: JSONObject()
        val steps = action.optJSONObject("pushify_actions")?.optJSONArray("on_tap") ?: JSONArray()
        if (steps.length() == 0) { handleButton(properties, screen); return }
        val id = node.optString("id")
        if (id.isBlank()) { message = "This button action sequence has no component id."; render(); return }
        val active = tapActionRuns[id]
        if (active != null) {
            if (!active.waiting || !active.interruptible) return
            active.cancelled = true
            active.runnable?.let(main::removeCallbacks)
            tapActionRuns.remove(id)
        }
        val run = TapActionRun()
        tapActionRuns[id] = run
        fun current() = tapActionRuns[id] === run && !run.cancelled
        fun finish() {
            if (current()) {
                handleButton(properties, screen)
                if (tapActionRuns[id] === run) tapActionRuns.remove(id)
            }
        }
        fun runStep(index: Int) {
            if (!current()) return
            if (index >= steps.length()) { finish(); return }
            val step = steps.optJSONObject(index)
            if (step == null) { runStep(index + 1); return }
            when (step.optString("type")) {
                "delay" -> {
                    val rawSeconds = step.opt("seconds")
                    val seconds = (rawSeconds as? Number)?.toDouble()
                    val interruptible = step.opt("interruptible")
                    if (seconds == null || !seconds.isFinite() || seconds < 0 || seconds > 60 || interruptible !is Boolean) {
                        message = "This delay action is invalid."; render(); tapActionRuns.remove(id); return
                    }
                    run.waiting = true
                    run.interruptible = interruptible
                    run.runnable = Runnable { run.waiting = false; run.runnable = null; runStep(index + 1) }
                    main.postDelayed(run.runnable!!, (seconds * 1000).roundToInt().toLong())
                }
                "update_variable" -> {
                    val variable = step.optString("variable").removePrefix("state.")
                    val definition = variableDeclarations.optJSONObject(variable)
                    if (definition == null) { message = "This state variable is not declared."; render(); tapActionRuns.remove(id); return }
                    val before = variables.opt(variable) ?: definition.opt("initial_value")
                    val raw = step.opt("value")
                    val value: Any? = when (definition.optString("value_type")) {
                        "number" -> { val amount = (raw as? Number)?.toDouble() ?: 0.0; val currentValue = (before as? Number)?.toDouble() ?: 0.0; when (step.optString("operation")) { "increment" -> currentValue + amount; "decrement" -> currentValue - amount; else -> amount } }
                        "boolean" -> if (step.optString("operation") == "toggle") !(before as? Boolean ?: false) else raw as? Boolean ?: false
                        else -> raw as? String ?: before?.toString().orEmpty()
                    }
                    variables.put(variable, value); render(); runStep(index + 1)
                }
                "set_user_attributes" -> {
                    val attributes = step.optJSONObject("attributes")
                    val valid = attributes != null && attributes.length() > 0 && attributes.keys().asSequence().all { key -> val value = attributes.opt(key); key.isNotBlank() && key.length <= 100 && (value == JSONObject.NULL || value is String || value is Number && value.toDouble().isFinite() || value is Boolean) }
                    if (!valid) { message = if (attributes == null || attributes.length() == 0) "No user attributes are configured." else "This user attribute is invalid."; render(); tapActionRuns.remove(id); return }
                    purchases.setAttributes(attributes!!) { result -> main.post {
                        if (!current()) return@post
                        if (result.isSuccess) runStep(index + 1) else { message = "User attributes could not be updated. Please try again."; render(); tapActionRuns.remove(id) }
                    } }
                }
                "navigate_to" -> { openActionLink(step, screen); runStep(index + 1) }
                "custom_action" -> {
                    val name = step.optString("name").trim()
                    val callback = onCustomAction
                    if (name.isBlank()) { message = "This custom action has no name."; render(); tapActionRuns.remove(id) }
                    else if (callback == null) { message = "This app action is unavailable."; render(); tapActionRuns.remove(id) }
                    else { callback(name); runStep(index + 1) }
                }
                "custom_callback" -> {
                    val name = step.optString("name").trim()
                    if (name.isBlank()) { message = "This callback has no name."; render(); tapActionRuns.remove(id); return }
                    val callback = onCustomCallback
                    if (callback == null) {
                        message = "This app callback is unavailable."; render(); tapActionRuns.remove(id); return
                    }
                    val arguments = JSONObject()
                    val configured = step.optJSONObject("variables") ?: JSONObject()
                    configured.keys().forEach { key ->
                        val reference = configured.optString(key)
                        if (reference.startsWith("state.") && variables.has(reference.removePrefix("state."))) arguments.put(key, variables.opt(reference.removePrefix("state.")))
                    }
                    val blocking = step.optString("behavior", "blocking") != "non_blocking"
                    try { callback(name, arguments) { result -> main.post {
                        if (run.cancelled || dismissing || !isAttachedToWindow) return@post
                        val safeData = result.data.size <= 20 && result.data.all { (key, value) ->
                            Regex("^[A-Za-z_][A-Za-z0-9_.-]{0,99}$").matches(key) &&
                                (value == null || value is Boolean || value is Number && value.toDouble().isFinite() || value is String && value.length <= 500)
                        }
                        val status = if (result.status == "success" && safeData) "success" else "failure"
                        if (!safeData || result.status !in setOf("success", "failure")) { message = "This app callback returned an invalid result."; render() }
                        callbackData.put(name, JSONObject(result.data.filterValues { value -> value == null || value is Boolean || value is Number && value.toDouble().isFinite() || value is String }.filterValues { value -> value !is String || value.length <= 500 }))
                        val branch = step.optJSONArray(if (status == "success") "on_success" else "on_failure") ?: JSONArray()
                        runCallbackBranch(branch, screen, { !run.cancelled && !dismissing && isAttachedToWindow }) {
                            if (blocking && current()) runStep(index + 1) else render()
                        }
                    } } } catch (_: Throwable) {
                        message = "This app callback could not be completed. Please try again."; render()
                        val failure = step.optJSONArray("on_failure") ?: JSONArray()
                        runCallbackBranch(failure, screen, { !run.cancelled && !dismissing && isAttachedToWindow }) {
                            if (blocking && current()) runStep(index + 1)
                        }
                        if (!blocking) runStep(index + 1)
                        else return
                    }
                    if (!blocking) runStep(index + 1)
                }
                "custom_placement" -> { dispatchCustomPlacement(step); runStep(index + 1) }
                else -> { message = "This tap action is not supported by this SDK version."; render(); tapActionRuns.remove(id) }
            }
        }
        runStep(0)
    }

    private fun runCallbackBranch(steps: JSONArray, screen: JSONObject, active: () -> Boolean, done: () -> Unit) {
        fun next(index: Int) {
            if (!active()) return
            if (index >= steps.length()) { done(); return }
            val step = steps.optJSONObject(index) ?: run { next(index + 1); return }
            when (step.optString("type")) {
                "update_variable" -> {
                    val name = step.optString("variable").removePrefix("state.")
                    val definition = variableDeclarations.optJSONObject(name)
                    if (definition == null) { message = "This state variable is not declared."; render(); return }
                    val before = variables.opt(name) ?: definition.opt("initial_value")
                    val raw = step.opt("value")
                    val value: Any? = when (definition.optString("value_type")) {
                        "number" -> { val amount = (raw as? Number)?.toDouble() ?: 0.0; val current = (before as? Number)?.toDouble() ?: 0.0; when (step.optString("operation")) { "increment" -> current + amount; "decrement" -> current - amount; else -> amount } }
                        "boolean" -> if (step.optString("operation") == "toggle") !(before as? Boolean ?: false) else raw as? Boolean ?: false
                        else -> raw as? String ?: before?.toString().orEmpty()
                    }
                    variables.put(name, value); render(); next(index + 1)
                }
                "set_user_attributes" -> {
                    val attributes = step.optJSONObject("attributes")
                    if (attributes == null || attributes.length() == 0) { message = "No user attributes are configured."; render(); return }
                    purchases.setAttributes(attributes) { result -> main.post { if (!active()) return@post; if (result.isSuccess) next(index + 1) else { message = "User attributes could not be updated. Please try again."; render() } } }
                }
                "navigate_to" -> { openActionLink(step, screen); next(index + 1) }
                "custom_action" -> { val name = step.optString("name").trim(); val callback = onCustomAction; if (name.isBlank() || callback == null) { message = "This app action is unavailable."; render() } else { callback(name); next(index + 1) } }
                "custom_placement" -> { dispatchCustomPlacement(step); next(index + 1) }
                "delay" -> { val seconds = step.optDouble("seconds", Double.NaN); if (!seconds.isFinite() || seconds !in 0.0..60.0) { message = "This callback delay is invalid."; render() } else main.postDelayed({ next(index + 1) }, (seconds * 1000).roundToInt().toLong()) }
                else -> { message = "This callback action is not supported by this SDK version."; render() }
            }
        }
        next(0)
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
            "navigate_to" -> if (action.optString("destination") == "offer_code") redeemOfferCode(screen) else openActionLink(action, screen)
            "custom_action" -> {
                val name = action.optString("name").trim()
                val callback = onCustomAction
                if (name.isEmpty()) message = "This custom action has no name."
                else if (callback == null) message = "This app action is unavailable."
                else { message = null; callback(name) }
                render()
            }
            "custom_placement" -> dispatchCustomPlacement(action)
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
                        "contains" -> when (current) { is JSONArray -> (0 until current.length()).any { current.optString(it) == expected?.toString() }; is String -> current == expected?.toString(); else -> false }
                        "not_contains" -> when (current) { is JSONArray -> (0 until current.length()).none { current.optString(it) == expected?.toString() }; is String -> current != expected?.toString(); else -> true }
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

    private fun dispatchCustomPlacement(action: JSONObject) {
        val name = action.optString("name").trim()
        val parameters = action.optJSONObject("parameters") ?: JSONObject()
        val valid = name.isNotEmpty() && name.length <= 100 && parameters.length() <= 20 && parameters.keys().asSequence().all { key ->
            key.matches(Regex("^[A-Za-z_][A-Za-z0-9_.-]{0,99}$")) && when (val value = parameters.opt(key)) {
                null, JSONObject.NULL, is Boolean, is String -> value !is String || value.length <= 500
                is Number -> value.toDouble().isFinite()
                else -> false
            }
        }
        if (!valid) message = "This custom placement has invalid parameters."
        else if (onCustomPlacement == null) message = "This app placement is unavailable."
        else {
            message = null
            onCustomPlacement.invoke(name, JSONObject(parameters.toString()))
        }
        render()
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

    private fun redeemOfferCode(screen: JSONObject) {
        val activity = context as? Activity
        if (activity == null) {
            message = "Offer code redemption is unavailable right now."
            render()
            return
        }
        AlertDialog.Builder(activity)
            .setTitle("Redeem a promo code")
            .setMessage("Google Play opens the selected plan's checkout. Choose Redeem in the payment options to enter your code.")
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Continue") { _, _ -> purchaseSelected(screen = screen) }
            .show()
    }

    private fun backgroundColor(background: JSONObject?): Int {
        val values = background?.optJSONObject("value") ?: return Color.WHITE
        val selected = (if (isDarkTheme()) values.optJSONObject("dark") else null) ?: values.optJSONObject("light") ?: return Color.WHITE
        val hex = selected.optString("value").takeIf(String::isNotBlank)
            ?: selected.optJSONArray("points")?.optJSONObject(0)?.optString("color")
            ?: return Color.WHITE
        return runCatching { Color.parseColor(hex.takeIf { it.length == 9 }?.let { "#${it.substring(7)}${it.substring(1, 7)}" } ?: hex) }.getOrDefault(Color.WHITE)
    }

    private fun paywallBackground(background: JSONObject?): Drawable {
        val values = background?.optJSONObject("value") ?: return ColorDrawable(Color.WHITE)
        val selected = (if (isDarkTheme()) values.optJSONObject("dark") else null)
            ?: values.optJSONObject("light") ?: return ColorDrawable(Color.WHITE)
        if (selected.optString("type") == "radial") {
            val points = selected.optJSONArray("points") ?: return ColorDrawable(backgroundColor(background))
            val stops = (0 until points.length()).mapNotNull { index ->
                val point = points.optJSONObject(index) ?: return@mapNotNull null
                val color = point.optString("color").takeIf(String::isNotBlank)
                    ?.let { raw -> runCatching { Color.parseColor(if (raw.length == 9) "#${raw.substring(7)}${raw.substring(1, 7)}" else raw) }.getOrNull() }
                    ?: return@mapNotNull null
                color to (point.optDouble("percent", index * 100.0 / (points.length() - 1).coerceAtLeast(1)).toFloat() / 100f).coerceIn(0f, 1f)
            }.sortedBy { it.second }
            if (stops.size < 2) return ColorDrawable(stops.firstOrNull()?.first ?: backgroundColor(background))
            val focalPoint = selected.optJSONObject("pushify_center")
            val centerX = (focalPoint?.optDouble("x", 0.5) ?: 0.5).toFloat().coerceIn(0f, 1f)
            val centerY = (focalPoint?.optDouble("y", 0.5) ?: 0.5).toFloat().coerceIn(0f, 1f)
            return PushifyRadialGradientDrawable(stops.map { it.first }.toIntArray(), stops.map { it.second }.toFloatArray(), centerX, centerY)
        }
        if (selected.optString("type") != "linear") return ColorDrawable(backgroundColor(background))
        val points = selected.optJSONArray("points") ?: return ColorDrawable(backgroundColor(background))
        val colors = (0 until points.length()).mapNotNull { index ->
            points.optJSONObject(index)?.optString("color")?.takeIf(String::isNotBlank)
                ?.let { raw -> runCatching { Color.parseColor(if (raw.length == 9) "#${raw.substring(7)}${raw.substring(1, 7)}" else raw) }.getOrNull() }
        }.toIntArray()
        if (colors.size < 2) return ColorDrawable(colors.firstOrNull() ?: backgroundColor(background))
        val degrees = ((selected.optInt("degrees", 180) % 360) + 360) % 360
        val orientation = when (degrees) {
            in 23..67 -> GradientDrawable.Orientation.BL_TR
            in 68..112 -> GradientDrawable.Orientation.LEFT_RIGHT
            in 113..157 -> GradientDrawable.Orientation.TL_BR
            in 158..202 -> GradientDrawable.Orientation.TOP_BOTTOM
            in 203..247 -> GradientDrawable.Orientation.TR_BL
            in 248..292 -> GradientDrawable.Orientation.RIGHT_LEFT
            in 293..337 -> GradientDrawable.Orientation.BR_TL
            else -> GradientDrawable.Orientation.BOTTOM_TOP
        }
        return GradientDrawable(orientation, colors)
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
    private fun isDarkTheme(): Boolean = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private fun colorValue(value: JSONObject?, fallback: Int, dark: Boolean = isDarkTheme()): Int {
        val colors = value?.optJSONObject("value") ?: value
        val selected = (if (dark) colors?.optJSONObject("dark") else null) ?: colors?.optJSONObject("light")
        val hex = selected?.optString("value")?.takeIf(String::isNotBlank) ?: return fallback
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

private class PushifyRadialGradientDrawable(
    private val colors: IntArray,
    private val stops: FloatArray,
    private val centerX: Float,
    private val centerY: Float,
) : Drawable() {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun draw(canvas: Canvas) {
        val bounds = bounds
        if (bounds.isEmpty) return
        if (paint.shader == null) updateShader(bounds)
        canvas.drawRect(bounds, paint)
    }

    override fun onBoundsChange(bounds: Rect) {
        updateShader(bounds)
    }

    private fun updateShader(bounds: Rect) {
        val focalX = bounds.left + bounds.width() * centerX
        val focalY = bounds.top + bounds.height() * centerY
        val radius = bounds.height() * 0.36f
        if (radius <= 0f || colors.size < 2) return
        paint.shader = RadialGradient(focalX, focalY, radius, colors, stops, Shader.TileMode.CLAMP)
    }

    override fun setAlpha(alpha: Int) { paint.alpha = alpha; invalidateSelf() }
    override fun setColorFilter(colorFilter: ColorFilter?) { paint.colorFilter = colorFilter; invalidateSelf() }
    @Deprecated("Deprecated in Android")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT
}

private fun sameHttpsOrigin(candidate: Uri, origin: Uri): Boolean {
    if (!candidate.scheme.equals("https", ignoreCase = true) ||
        !origin.scheme.equals("https", ignoreCase = true) ||
        !candidate.host.equals(origin.host, ignoreCase = true)) return false
    val candidatePort = if (candidate.port == -1) 443 else candidate.port
    val originPort = if (origin.port == -1) 443 else origin.port
    return candidatePort == originPort
}

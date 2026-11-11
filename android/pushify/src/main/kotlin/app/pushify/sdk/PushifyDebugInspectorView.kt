package app.pushify.sdk

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Opt-in local inspector that previews and copies a redacted SDK support bundle. */
public class PushifyDebugInspectorView(context: Context, private val purchases: PushifyPurchases) : LinearLayout(context) {
    private val report = TextView(context).apply {
        textSize = 12f
        typeface = android.graphics.Typeface.MONOSPACE
        setTextIsSelectable(true)
        text = "Enable diagnostics to collect a local support bundle."
    }

    init {
        orientation = VERTICAL
        setPadding(20, 16, 20, 16)
        purchases.enableDebugInspector(true)
        val title = TextView(context).apply { text = "Pushify diagnostics"; textSize = 18f }
        val note = TextView(context).apply { text = "Stored on this device. Nothing is uploaded automatically."; textSize = 12f }
        val actions = LinearLayout(context).apply { gravity = Gravity.END }
        actions.addView(Button(context).apply {
            text = "Refresh"
            setOnClickListener { report.text = purchases.debugExport()?.toString(2) ?: "No diagnostic report is available." }
        })
        actions.addView(Button(context).apply {
            text = "Copy"
            setOnClickListener {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("Pushify diagnostics", report.text))
                text = "Copied"
            }
        })
        val scroll = ScrollView(context).apply { addView(report) }
        addView(title)
        addView(note)
        addView(actions)
        addView(scroll, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        report.text = purchases.debugExport()?.toString(2) ?: report.text
    }

    override fun onDetachedFromWindow() {
        purchases.enableDebugInspector(false)
        super.onDetachedFromWindow()
    }
}

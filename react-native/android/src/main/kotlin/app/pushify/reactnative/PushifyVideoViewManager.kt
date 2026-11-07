package app.pushify.reactnative

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.media.MediaPlayer
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.MediaController
import android.widget.TextView
import android.widget.VideoView
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.annotations.ReactProp
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

internal class PushifyVideoViewManager : SimpleViewManager<PushifyNativeVideoView>() {
    override fun getName(): String = "PushifyVideoView"
    override fun createViewInstance(reactContext: ThemedReactContext): PushifyNativeVideoView = PushifyNativeVideoView(reactContext)

    @ReactProp(name = "videoUrl") fun setVideoUrl(view: PushifyNativeVideoView, value: String?) { view.videoUrl = value }
    @ReactProp(name = "posterUrl") fun setPosterUrl(view: PushifyNativeVideoView, value: String?) { view.posterUrl = value }
    @ReactProp(name = "autoPlay", defaultBoolean = true) fun setAutoPlay(view: PushifyNativeVideoView, value: Boolean) { view.autoPlay = value }
    @ReactProp(name = "loops", defaultBoolean = true) fun setLoop(view: PushifyNativeVideoView, value: Boolean) { view.loops = value }
    @ReactProp(name = "muted", defaultBoolean = true) fun setMuted(view: PushifyNativeVideoView, value: Boolean) { view.muted = value }
    @ReactProp(name = "showControls") fun setShowControls(view: PushifyNativeVideoView, value: Boolean) { view.controls = value }
    @ReactProp(name = "fitMode") fun setFitMode(view: PushifyNativeVideoView, value: String?) { view.fitMode = value ?: "fill" }
    @ReactProp(name = "accessibilityLabel") override fun setAccessibilityLabel(view: PushifyNativeVideoView, value: String?) { view.accessibilityLabel = value ?: "Video" }

    override fun onDropViewInstance(view: PushifyNativeVideoView) {
        view.dispose()
        super.onDropViewInstance(view)
    }
}

internal class PushifyNativeVideoView(context: Context) : FrameLayout(context) {
    private val player = VideoView(context)
    private val poster = ImageView(context)
    private val status = TextView(context)
    private val mediaController = MediaController(context)
    private val executor = Executors.newSingleThreadExecutor()
    private var prepared = false
    private var currentPlayer: MediaPlayer? = null
    private var configuredUrl: String? = null
    private var configuredPoster: String? = null
    var videoUrl: String? = null
        set(value) { field = value; update() }
    var posterUrl: String? = null
        set(value) { field = value; update() }
    var autoPlay = true
        set(value) { field = value; updatePlayback() }
    var loops = true
    var muted = true
        set(value) { field = value; currentPlayer?.setVolume(if (value) 0f else 1f, if (value) 0f else 1f) }
    var controls = false
        set(value) { field = value; updateControls() }
    var fitMode = "fill"
        set(value) { field = value; poster.scaleType = posterScale(value) }
    var accessibilityLabel = "Video"
        set(value) { field = value; player.contentDescription = value; poster.contentDescription = "$value preview" }

    init {
        setBackgroundColor(Color.BLACK)
        player.visibility = View.INVISIBLE
        player.contentDescription = accessibilityLabel
        addView(player, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        poster.scaleType = posterScale(fitMode)
        poster.contentDescription = "$accessibilityLabel preview"
        addView(poster, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        status.gravity = Gravity.CENTER
        status.setTextColor(Color.WHITE)
        status.setBackgroundColor(Color.BLACK)
        status.text = "Loading video…"
        status.contentDescription = "Loading video"
        addView(status, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        updateControls()
        player.setOnPreparedListener { mediaPlayer ->
            prepared = true
            currentPlayer = mediaPlayer
            mediaPlayer.setVolume(if (muted) 0f else 1f, if (muted) 0f else 1f)
            player.visibility = View.VISIBLE
            status.visibility = View.GONE
            poster.visibility = if (autoPlay || controls) View.GONE else View.VISIBLE
            if (autoPlay) player.start() else if (controls) player.seekTo(1)
        }
        player.setOnCompletionListener { if (loops) { player.seekTo(0); player.start() } }
        player.setOnErrorListener { _, _, _ ->
            player.visibility = View.GONE
            status.text = if (posterUrl == null) "Video unavailable" else ""
            status.contentDescription = "Video unavailable"
            status.visibility = if (posterUrl == null) View.VISIBLE else View.GONE
            poster.visibility = if (posterUrl == null || poster.drawable == null) View.GONE else View.VISIBLE
            true
        }
        addOnAttachStateChangeListener(object : OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) { update() }
            override fun onViewDetachedFromWindow(view: View) { player.stopPlayback(); currentPlayer = null; prepared = false; configuredUrl = null }
        })
    }

    private fun update() {
        updatePoster()
        val target = videoUrl?.takeIf { it.startsWith("https://") } ?: run {
            player.stopPlayback(); player.visibility = View.GONE
            status.text = if (posterUrl == null) "Video unavailable" else ""
            status.contentDescription = "Video unavailable"
            status.visibility = if (posterUrl == null && poster.drawable == null) View.VISIBLE else View.GONE
            poster.visibility = if (poster.drawable == null) View.GONE else View.VISIBLE
            return
        }
        if (target == configuredUrl) { updatePlayback(); return }
        configuredUrl = target
        prepared = false
        player.visibility = View.INVISIBLE
        status.text = if (poster.drawable == null) "Loading video…" else ""
        status.contentDescription = if (poster.drawable == null) "Loading video" else null
        status.visibility = if (poster.drawable == null) View.VISIBLE else View.GONE
        poster.visibility = if (poster.drawable == null) View.GONE else View.VISIBLE
        player.setVideoURI(Uri.parse(target))
    }

    private fun updatePoster() {
        val target = posterUrl?.takeIf { it.startsWith("https://") }
        if (target == null) { configuredPoster = null; poster.setImageDrawable(null); return }
        if (target == configuredPoster) return
        configuredPoster = target
        executor.execute {
            val bitmap = runCatching {
                (URL(target).openConnection() as HttpURLConnection).apply { connectTimeout = 5000; readTimeout = 5000 }.inputStream.use { BitmapFactory.decodeStream(it) }
            }.getOrNull()
            if (bitmap != null) post {
                poster.setImageBitmap(bitmap)
                if (!prepared || !autoPlay && !controls) { poster.visibility = View.VISIBLE; status.visibility = View.GONE }
            }
        }
    }

    private fun updatePlayback() {
        if (!prepared) return
        if (autoPlay) player.start() else player.pause()
    }

    private fun updateControls() {
        if (controls) {
            mediaController.setAnchorView(player)
            player.setMediaController(mediaController)
        } else player.setMediaController(null)
    }

    private fun posterScale(value: String) = if (value == "fit") ImageView.ScaleType.FIT_CENTER else ImageView.ScaleType.CENTER_CROP
    fun dispose() { player.stopPlayback(); currentPlayer = null; mediaController.hide(); executor.shutdownNow() }
}

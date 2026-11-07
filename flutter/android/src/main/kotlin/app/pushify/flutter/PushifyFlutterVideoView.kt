package app.pushify.flutter

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.MediaController
import android.widget.TextView
import android.widget.VideoView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

internal class PushifyFlutterVideoFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView = PushifyFlutterVideoPlatformView(context, args as? Map<*, *> ?: emptyMap<Any, Any>())
}

private class PushifyFlutterVideoPlatformView(context: Context, args: Map<*, *>) : PlatformView {
    private val root = FrameLayout(context).apply { setBackgroundColor(Color.BLACK) }
    private val executor = Executors.newSingleThreadExecutor()
    private val video: VideoView
    private val poster: ImageView?
    private val status: TextView
    private var released = false

    init {
        val url = args["url"] as? String
        val posterUrl = args["posterUrl"] as? String
        val autoPlay = args["autoPlay"] as? Boolean ?: true
        val loop = args["loop"] as? Boolean ?: true
        val muted = args["muted"] as? Boolean ?: true
        val controls = args["showControls"] as? Boolean ?: false
        val label = args["accessibilityLabel"] as? String ?: "Video"
        status = TextView(context).apply {
            text = "Loading video…"
            contentDescription = "Loading video"
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.BLACK)
        }
        poster = posterUrl?.takeIf { it.startsWith("https://") }?.let {
            ImageView(context).apply {
                contentDescription = "$label preview"
                scaleType = if (args["fitMode"] == "fit") ImageView.ScaleType.FIT_CENTER else ImageView.ScaleType.CENTER_CROP
                load(it) { status.visibility = View.GONE }
            }
        }
        video = VideoView(context).apply {
            contentDescription = label
            visibility = View.INVISIBLE
            if (controls) setMediaController(MediaController(context).also { it.setAnchorView(this) })
            setOnPreparedListener { player ->
                if (muted) player.setVolume(0f, 0f)
                visibility = View.VISIBLE
                if (autoPlay || controls) {
                    status.visibility = View.GONE
                    poster?.visibility = View.GONE
                } else {
                    val hasPoster = poster?.drawable != null
                    status.text = if (hasPoster) "" else "Video paused"
                    status.contentDescription = "Video paused"
                    status.visibility = if (hasPoster) View.GONE else View.VISIBLE
                    poster?.visibility = View.VISIBLE
                }
                if (autoPlay) start() else if (controls) seekTo(1)
            }
            setOnCompletionListener { if (loop) { seekTo(0); start() } }
            setOnErrorListener { _, _, _ ->
                visibility = View.GONE
                status.text = "Video unavailable"
                status.contentDescription = "Video unavailable"
                status.visibility = if (poster == null) View.VISIBLE else View.GONE
                poster?.visibility = View.VISIBLE
                true
            }
        }
        poster?.let { root.addView(it, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)) }
        root.addView(video, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(status, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        status.visibility = View.VISIBLE
        if (url?.startsWith("https://") == true) video.setVideoURI(Uri.parse(url))
        else {
            status.text = "Video unavailable"
            status.contentDescription = "Video unavailable"
            status.visibility = if (poster == null) View.VISIBLE else View.GONE
            poster?.visibility = View.VISIBLE
        }
        root.addOnAttachStateChangeListener(object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) {
                if (released && url?.startsWith("https://") == true) video.setVideoURI(Uri.parse(url.orEmpty()))
                released = false
                if (autoPlay && video.visibility == View.VISIBLE) video.start()
            }
            override fun onViewDetachedFromWindow(view: View) { video.stopPlayback(); released = true }
        })
    }

    private fun ImageView.load(url: String, onLoaded: () -> Unit) {
        executor.execute {
            runCatching {
                (URL(url).openConnection() as HttpURLConnection).apply { connectTimeout = 5000; readTimeout = 5000 }.inputStream.use { BitmapFactory.decodeStream(it) }
            }.getOrNull()?.let { bitmap -> post { setImageBitmap(bitmap); onLoaded() } }
        }
    }

    override fun getView(): View = root
    override fun dispose() { video.stopPlayback(); executor.shutdownNow() }
}

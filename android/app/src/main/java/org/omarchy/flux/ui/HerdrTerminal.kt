package org.omarchy.flux.ui

import android.annotation.SuppressLint
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.viewinterop.AndroidView
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.HerdrTerminalEvent
import org.omarchy.flux.core.HerdrTerminalSession

/**
 * The live terminal of a herdr pane. It draws the ANSI frames of the
 * pane in xterm.js inside a WebView, at the terminal size that the pane
 * has on the computer. The page is part of the app and loads nothing
 * from the network, so the terminal content never reaches a browser and
 * no terminal query goes back to the program.
 *
 * The touches of the page come back here: one finger scrolls the
 * terminal of the computer while [control] is on and pans the view
 * otherwise, two fingers zoom and pan locally, and a wheel step goes out
 * through [onWheel]. With [sample] the view draws that screen instead of
 * opening a stream, for screenshots.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun HerdrTerminalView(
    session: HerdrTerminalSession?,
    onReady: () -> Unit,
    modifier: Modifier = Modifier,
    sample: TerminalSample? = null,
    control: Boolean = false,
    onWheel: (column: Int, row: Int, direction: String) -> Unit = { _, _, _ -> },
) {
    val feeder = remember { TerminalFeeder() }
    feeder.onReady = {
        if (sample != null) feeder.draw(sample) else onReady()
    }
    feeder.onWheel = onWheel
    feeder.control = control
    DisposableEffect(feeder) {
        HerdrSync.terminalSink = feeder
        onDispose {
            if (HerdrSync.terminalSink === feeder) HerdrSync.terminalSink = null
            feeder.detach()
        }
    }
    AndroidView(
        modifier = modifier.semantics {
            contentDescription = "The terminal of ${session?.pane ?: "the pane"}" +
                if (control) ", controlled from this phone" else ", watching only"
        },
        factory = { context ->
            WebView(context).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = false
                // The page is part of the APK and must always be the one
                // of this build, never a cached copy.
                settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
                clearCache(true)
                // The page needs no network at all.
                settings.blockNetworkLoads = true
                // The gestures of the terminal are its own, so the
                // browser scrolls and zooms nothing here.
                settings.setSupportZoom(false)
                settings.builtInZoomControls = false
                // The terminal takes no keys here, so a tap must not
                // open the keyboard.
                isFocusable = false
                isFocusableInTouchMode = false
                addJavascriptInterface(TerminalBridge(feeder), "FluxBridge")
                feeder.webView = this
                loadUrl("file:///android_asset/terminal/index.html")
            }
        },
        onRelease = { feeder.detach() },
    )
}

/**
 * Hands terminal events to the WebView on its main thread. The stream
 * delivers the events in order, and so does the handler, so the terminal
 * always sees the grid of a frame before the frame itself. The touches
 * of the page arrive here too and become wheel steps, zoom, and pan.
 */
private class TerminalFeeder : (HerdrTerminalEvent) -> Unit {
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    /** The view that draws the terminal, or null while it is gone. */
    @Volatile
    var webView: WebView? = null

    /** Called on the main thread once the xterm page is ready for frames. */
    @Volatile
    var onReady: (() -> Unit)? = null

    /** Called on the main thread for each wheel step of a gesture. */
    @Volatile
    var onWheel: ((column: Int, row: Int, direction: String) -> Unit)? = null

    private var ready = false
    private var cols = 0
    private var rows = 0

    /** True after a full frame drew the screen: only then may input go out. */
    private var baseline = false

    /** The touches of the page, in CSS pixels. Main thread only. */
    val gestures = TerminalGestures(
        onWheel = { column, row, direction ->
            // The gesture is already control-only. A screen that has no
            // baseline yet takes no input either.
            if (baseline) onWheel?.invoke(column, row, direction)
        },
        onFont = { size, x, y -> eval("FluxTerminal.zoom($size, $x, $y)") },
        onPan = { dx, dy -> eval("FluxTerminal.pan($dx, $dy)") },
    )

    /** True while the phone controls the terminal. Main thread. */
    var control: Boolean
        get() = gestures.control
        set(value) {
            gestures.control = value
        }

    /** The JS page finished loading. Any thread. */
    fun pageReady() {
        handler.post {
            if (!ready) {
                ready = true
                onReady?.invoke()
            }
        }
    }

    /** Feeds one event of the stream. Any thread. */
    override fun invoke(event: HerdrTerminalEvent) {
        handler.post {
            val view = webView ?: return@post
            if (!ready) return@post
            when (event) {
                is HerdrTerminalEvent.Opened -> {
                    baseline = false
                    gestures.reset()
                    resize(view, event.width, event.height)
                }
                is HerdrTerminalEvent.Frame -> {
                    // A frame draws into its own grid, so a new size of
                    // the terminal resets it first.
                    if (event.width != cols || event.height != rows) resize(view, event.width, event.height)
                    if (event.full) baseline = true
                    view.evaluateJavascript("FluxTerminal.write('${event.bytes}')", null)
                }
                // The screen shows the reason; the terminal keeps its
                // last screen until a new stream opens.
                is HerdrTerminalEvent.Closed -> Unit
            }
        }
    }

    /** One touch of the page, in CSS pixels. Any thread. */
    fun touch(action: String, id: Int, x: Double, y: Double) {
        handler.post { gestures.touch(action, id, x, y) }
    }

    /** The grid of the page as it draws it. Any thread. */
    fun geometry(cellW: Double, cellH: Double, originX: Double, originY: Double, cols: Int, rows: Int, font: Int) {
        handler.post {
            gestures.geometry = TerminalGeometry(cellW, cellH, originX, originY, cols, rows, font)
        }
    }

    private fun resize(view: WebView, width: Int, height: Int) {
        if (width < 1 || height < 1) return
        cols = width
        rows = height
        // The page fits the grid into the view, and the layout viewport
        // of a WebView is not its visible size. Pass the real CSS size.
        val density = view.resources.displayMetrics.density
        val cssW = view.width / density
        val cssH = view.height / density
        view.evaluateJavascript("FluxTerminal.reset($width, $height, $cssW, $cssH)", null)
    }

    /** Runs one call in the page. Main thread. */
    private fun eval(js: String) {
        webView?.evaluateJavascript(js, null)
    }

    /** Draws a sample screen instead of a stream. Any thread. */
    fun draw(sample: TerminalSample) {
        handler.post {
            val view = webView ?: return@post
            if (!ready) return@post
            resize(view, sample.cols, sample.rows)
            val bytes = android.util.Base64.encodeToString(
                sample.ansi.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP,
            )
            view.evaluateJavascript("FluxTerminal.write('$bytes')", null)
        }
    }

    /** Drops the view and the callbacks after the terminal is gone. */
    fun detach() {
        handler.post {
            webView = null
            onReady = null
            onWheel = null
            ready = false
            baseline = false
            gestures.reset()
        }
    }
}

/** The calls of the xterm page into the app. */
private class TerminalBridge(private val feeder: TerminalFeeder) {
    @JavascriptInterface
    fun ready(cols: Int, rows: Int) {
        feeder.pageReady()
    }

    @JavascriptInterface
    fun touch(action: String, id: Int, x: Double, y: Double) {
        feeder.touch(action, id, x, y)
    }

    @JavascriptInterface
    fun geometry(cellW: Double, cellH: Double, originX: Double, originY: Double, cols: Int, rows: Int, font: Int) {
        feeder.geometry(cellW, cellH, originX, originY, cols, rows, font)
    }
}

/** A screen that the terminal view draws instead of a stream, for screenshots. */
data class TerminalSample(val ansi: String, val cols: Int, val rows: Int)

/**
 * Debug builds only: the sample screen of [org.omarchy.flux.core.DebugDemo]
 * for reproducible terminal screenshots, or null when none was given.
 */
internal fun terminalDebugSample(): TerminalSample? {
    val ansi = org.omarchy.flux.core.DebugDemo.terminalSample ?: return null
    val grid = org.omarchy.flux.core.DebugDemo.terminalGrid?.split('x').orEmpty()
    val cols = grid.getOrNull(0)?.toIntOrNull() ?: 100
    val rows = grid.getOrNull(1)?.toIntOrNull() ?: 30
    return TerminalSample(ansi, cols, rows)
}

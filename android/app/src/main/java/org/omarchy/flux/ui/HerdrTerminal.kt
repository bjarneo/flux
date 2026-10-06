package org.omarchy.flux.ui

import android.annotation.SuppressLint
import android.content.Context
import android.view.MotionEvent
import android.view.ViewGroup
import android.view.accessibility.AccessibilityManager
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.ime
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.viewinterop.AndroidView
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.HerdrTerminalEvent
import org.omarchy.flux.core.HerdrTerminalSession
import org.omarchy.flux.theme.OmarchyTheme

/**
 * Keeps the page of a live terminal: the WebView with xterm.js and the
 * feeder of the stream events. The caller keeps it above the layout of
 * the screen, so that a move of [HerdrTerminalView], for example at a
 * rotation, keeps the page, its zoom, and its stream. The page goes away
 * when the caller leaves the composition.
 */
@Composable
internal fun rememberTerminalFeeder(deviceId: String): TerminalFeeder {
    val context = LocalContext.current
    val feeder = remember {
        TerminalFeeder(reader = context.getSystemService(AccessibilityManager::class.java)?.isTouchExplorationEnabled == true)
    }
    feeder.deviceId = deviceId
    DisposableEffect(feeder) {
        HerdrSync.terminalSink = feeder
        onDispose {
            if (HerdrSync.terminalSink === feeder) HerdrSync.terminalSink = null
            feeder.detach()
        }
    }
    return feeder
}

/**
 * The live terminal of a herdr pane. It draws the ANSI frames of the
 * pane in xterm.js inside a WebView. The view measures the grid that fits
 * the phone and gives it to [onGrid]. In control mode, the computer
 * resizes the pane to that grid, so the program draws its screen for the
 * phone. The page is part of the app and loads nothing from the network,
 * so the terminal content never reaches a browser and no terminal query
 * goes back to the program.
 *
 * The touches of the page come back here: one finger scrolls the
 * terminal of the computer while [control] is on and pans the view
 * otherwise, two fingers zoom and pan locally, and a wheel step goes out
 * through [onWheel]. While the keyboard shows, a change of the view
 * height keeps the grid on the computer, and the view shows the bottom
 * rows of the grid. With [sample], the view draws that screen and opens
 * no stream, for screenshots. When the renderer of the page stops, the
 * view goes away and [onGone] runs, so that the app keeps its process.
 */
@Composable
internal fun HerdrTerminalView(
    feeder: TerminalFeeder,
    session: HerdrTerminalSession?,
    onReady: () -> Unit,
    modifier: Modifier = Modifier,
    sample: TerminalSample? = null,
    control: Boolean = false,
    theme: OmarchyTheme? = null,
    onWheel: (column: Int, row: Int, direction: String) -> Unit = { _, _, _ -> },
    onGrid: (cols: Int, rows: Int) -> Unit = { _, _ -> },
    onDrawn: (session: String) -> Unit = {},
    inputEnabled: Boolean = true,
    onTap: (column: Int, row: Int) -> Unit = { _, _ -> },
    onGone: () -> Unit = {},
) {
    feeder.onReady = {
        if (sample != null) feeder.draw(sample) else onReady()
    }
    feeder.onGone = onGone
    feeder.onWheel = onWheel
    feeder.onTap = onTap
    feeder.onGrid = onGrid
    feeder.onDrawn = onDrawn
    feeder.control = control
    feeder.inputEnabled = inputEnabled
    // The keyboard takes height from the view while it shows or moves.
    val ime = WindowInsets.ime
    val density = LocalDensity.current
    val keyboard by remember(ime, density) { derivedStateOf { ime.getBottom(density) > 0 } }
    feeder.keepRows = keyboard
    // After the keyboard closed, the grid fits the full height again.
    LaunchedEffect(keyboard) { if (!keyboard) feeder.prepare() }
    // The theme of the computer colors the default and indexed colors of
    // the frames. The page takes it before the first frame and on each change.
    DisposableEffect(theme) {
        feeder.setTheme(theme)
        onDispose { }
    }
    AndroidView(
        modifier = modifier.semantics {
            // With TalkBack on, the page shows the rows of the terminal to
            // TalkBack, and a description would hide them.
            if (!feeder.reader) {
                contentDescription = "The terminal of ${session?.pane ?: "the pane"}. " +
                    if (control) "This phone controls it." else "This phone only shows it."
            }
        },
        factory = { context -> feeder.view(context) },
    )
}

/**
 * Hands terminal events to the WebView on its main thread. The stream
 * delivers the events in order, and so does the handler, so the terminal
 * always sees the grid of a frame before the frame itself. The touches
 * of the page arrive here too and become wheel steps, zoom, and pan.
 */
internal class TerminalFeeder(
    /** True when TalkBack explored by touch as the terminal opened. The page then keeps its rows for TalkBack. */
    val reader: Boolean = false,
) : (String, HerdrTerminalEvent) -> Unit {
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    /**
     * The computer whose terminal this feeder draws. Events of another
     * computer are dropped, so a late frame or close of one never reaches
     * the terminal of another, whose session can share the same name.
     */
    @Volatile
    var deviceId: String = ""

    /** The view that draws the terminal, or null while it is gone. */
    @Volatile
    var webView: WebView? = null

    /** Called on the main thread once the xterm page is ready for frames. */
    @Volatile
    var onReady: (() -> Unit)? = null

    /** Called on the main thread for each wheel step of a gesture. */
    @Volatile
    var onWheel: ((column: Int, row: Int, direction: String) -> Unit)? = null

    /** Called on the main thread for a tap on a cell. */
    var onTap: ((column: Int, row: Int) -> Unit)? = null

    /** Called on the main thread with the phone grid of the view. */
    @Volatile
    var onGrid: ((cols: Int, rows: Int) -> Unit)? = null

    /** Called on the main thread when the first full frame of a session shows. */
    var onDrawn: ((String) -> Unit)? = null

    /** Called on the main thread after the renderer of the page stopped and the view went away. */
    var onGone: (() -> Unit)? = null
    private var sessionId = ""

    /** True while the touches go to the gestures. Main thread. */
    var inputEnabled = true

    /** True while the keyboard shows. A change of the view height then keeps the grid. Main thread. */
    var keepRows = false

    /** The xterm theme JSON of the computer, or null while it sent none. */
    @Volatile
    private var themeJson: String? = null

    private var ready = false
    private var cols = 0
    private var rows = 0

    /** True after a full frame drew the screen. Only then can input go out. */
    private var baseline = false

    /** The touches of the page, in CSS pixels. Main thread only. */
    val gestures = TerminalGestures(
        onWheel = { column, row, direction ->
            // The gesture is already control-only. A screen that has no
            // first full frame yet takes no input either.
            if (baseline) onWheel?.invoke(column, row, direction)
        },
        onFont = { size, x, y -> eval("FluxTerminal.zoom($size, $x, $y)") },
        onPan = { dx, dy -> eval("FluxTerminal.pan($dx, $dy)") },
        onTap = { column, row ->
            if (baseline && inputEnabled) onTap?.invoke(column, row)
        },
        // The fling ticks run on the same main thread as the touches.
        post = { delay, action -> handler.postDelayed(action, delay) },
    )

    /** True while the phone controls the terminal. Main thread. */
    var control: Boolean
        get() = gestures.control
        set(value) {
            gestures.control = value
        }

    /**
     * The WebView of the page. The first call makes it. A later call
     * moves the same view to its new place, so the page keeps its state.
     * Main thread.
     */
    fun view(context: Context): WebView {
        webView?.let { view ->
            (view.parent as? ViewGroup)?.removeView(view)
            return view
        }
        return makeView(context).also { webView = it }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun makeView(context: Context): WebView = WebView(context).apply {
        // The page paints the theme background itself.
        setBackgroundColor(android.graphics.Color.TRANSPARENT)
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = false
        // The page is part of the APK and must always be the one
        // of this build, never a cached copy.
        settings.cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
        clearCache(true)
        // The page needs no network and no files. The assets of the app
        // still load.
        settings.blockNetworkLoads = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        // The page never goes to another address, and no link opens an app.
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean = true

            // The renderer crashed, or the system stopped it to get memory.
            // Without this handler, Android stops the app and its links.
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                rendererGone(view)
                return true
            }
        }
        // The gestures of the terminal are its own, so the
        // browser scrolls and zooms nothing here.
        settings.setSupportZoom(false)
        settings.builtInZoomControls = false
        // The terminal takes no keys here, so a tap must not
        // open the keyboard.
        isFocusable = false
        isFocusableInTouchMode = false
        setOnTouchListener { view, event ->
            // Claim the entire drag before the enclosing Compose
            // scroll column can intercept it and cancel the WebView.
            if (event.actionMasked == MotionEvent.ACTION_DOWN) {
                view.parent?.requestDisallowInterceptTouchEvent(true)
            }
            touch(event, resources.displayMetrics.density.toDouble())
            if (event.actionMasked == MotionEvent.ACTION_UP ||
                event.actionMasked == MotionEvent.ACTION_CANCEL
            ) {
                view.parent?.requestDisallowInterceptTouchEvent(false)
                if (event.actionMasked == MotionEvent.ACTION_UP) view.performClick()
            }
            true
        }
        addJavascriptInterface(TerminalBridge(this@TerminalFeeder, reader), "FluxBridge")
        addOnLayoutChangeListener { _, left, top, right, bottom,
            oldLeft, oldTop, oldRight, oldBottom ->
            if (right - left != oldRight - oldLeft ||
                bottom - top != oldBottom - oldTop
            ) prepare()
        }
        loadUrl("file:///android_asset/terminal/index.html")
    }

    /** The JS page finished loading. Any thread. */
    fun pageReady() {
        handler.post {
            if (!ready) {
                ready = true
                applyTheme()
                prepare()
                onReady?.invoke()
            }
        }
    }

    /** Measures the phone grid of the view. The page gives it to [onGrid]. Main thread. */
    fun prepare() {
        val view = webView ?: return
        if (!ready || view.width == 0 || view.height == 0) return
        val density = view.resources.displayMetrics.density
        eval("FluxTerminal.prepare(${view.width / density}, ${view.height / density}, $keepRows)")
    }

    /** Sets the theme of the computer to draw default and indexed colors. Any thread. */
    fun setTheme(theme: OmarchyTheme?) {
        val json = theme?.let { terminalTheme(it).toString() }
        handler.post {
            themeJson = json
            if (ready) applyTheme()
        }
    }

    /** Sends the last theme to the page. Main thread. */
    private fun applyTheme() {
        val json = themeJson ?: return
        // The page takes the theme as a JSON string literal.
        val quoted = kotlinx.serialization.json.JsonPrimitive(json).toString()
        eval("FluxTerminal.theme($quoted)")
    }

    /** Feeds one event of the stream. Any thread. */
    override fun invoke(deviceId: String, event: HerdrTerminalEvent) {
        if (deviceId != this.deviceId) return
        handler.post {
            val view = webView ?: return@post
            if (!ready) return@post
            when (event) {
                is HerdrTerminalEvent.Opened -> {
                    sessionId = event.session
                    baseline = false
                    gestures.reset()
                    resize(view, event.width, event.height)
                }
                is HerdrTerminalEvent.Frame -> {
                    // A frame draws into its own grid, so a new size of
                    // the terminal resets it first.
                    if (event.width != cols || event.height != rows) {
                        baseline = false
                        gestures.reset()
                        resize(view, event.width, event.height)
                    }
                    val id = kotlinx.serialization.json.JsonPrimitive(sessionId).toString()
                    // The parser accepts only base64 bytes, so they cannot
                    // end the string literal.
                    view.evaluateJavascript(
                        "FluxTerminal.write('${event.bytes}', ${event.full}, $id)", null,
                    )
                }
                // The screen shows the reason. The terminal keeps its
                // last screen until a new stream opens.
                is HerdrTerminalEvent.Closed -> {
                    sessionId = ""
                    baseline = false
                    gestures.reset()
                }
            }
        }
    }

    /** Native touches on the main thread, mapped to the page's CSS pixels. */
    fun touch(event: MotionEvent, density: Double) {
        if (!inputEnabled) {
            gestures.reset()
            return
        }
        fun send(action: String, index: Int, history: Int? = null) {
            val x = history?.let { event.getHistoricalX(index, it) } ?: event.getX(index)
            val y = history?.let { event.getHistoricalY(index, it) } ?: event.getY(index)
            val time = history?.let { event.getHistoricalEventTime(it) } ?: event.eventTime
            gestures.touch(action, event.getPointerId(index), x / density, y / density, time)
        }
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN ->
                send("down", event.actionIndex)
            MotionEvent.ACTION_MOVE -> {
                // Android can batch several positions into one delivery.
                // Keep their original order and times, not just the last.
                for (history in 0 until event.historySize) {
                    for (index in 0 until event.pointerCount) send("move", index, history)
                }
                for (index in 0 until event.pointerCount) send("move", index)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> send("up", event.actionIndex)
            MotionEvent.ACTION_CANCEL -> {
                for (index in 0 until event.pointerCount) send("cancel", index)
                gestures.reset()
            }
        }
    }

    /** The grid of the page as it draws it. Any thread. */
    fun geometry(cellW: Double, cellH: Double, originX: Double, originY: Double, cols: Int, rows: Int, font: Int) {
        handler.post {
            gestures.geometry = TerminalGeometry(cellW, cellH, originX, originY, cols, rows, font)
        }
    }

    /** The phone grid that the page measured. Any thread. */
    fun grid(cols: Int, rows: Int) {
        handler.post { onGrid?.invoke(cols, rows) }
    }

    /** The page drew the first full frame of [id]. Any thread. */
    fun drawn(id: String) {
        handler.post {
            webView?.postVisualStateCallback(0, object : WebView.VisualStateCallback() {
                override fun onComplete(requestId: Long) {
                    if (id == sessionId && ready) {
                        baseline = true
                        onDrawn?.invoke(id)
                    }
                }
            })
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

    /**
     * Drops [view] after its renderer stopped. The view cannot draw again,
     * so it leaves the layout, and [onGone] tells the screen. Main thread.
     */
    private fun rendererGone(view: WebView) {
        val current = view === webView
        if (current) {
            webView = null
            ready = false
            baseline = false
            sessionId = ""
            gestures.reset()
        }
        (view.parent as? ViewGroup)?.removeView(view)
        view.destroy()
        if (current) onGone?.invoke()
    }

    /** Drops the view and the callbacks after the terminal is gone. */
    fun detach() {
        handler.post {
            val view = webView
            webView = null
            onReady = null
            onWheel = null
            onTap = null
            onGrid = null
            onDrawn = null
            onGone = null
            ready = false
            baseline = false
            gestures.reset()
            // The page and its renderer go away with the terminal.
            view?.let {
                (it.parent as? ViewGroup)?.removeView(it)
                it.destroy()
            }
        }
    }
}

/** The calls of the xterm page into the app. */
private class TerminalBridge(private val feeder: TerminalFeeder, private val reader: Boolean) {
    @JavascriptInterface
    fun ready(cols: Int, rows: Int) {
        feeder.pageReady()
    }

    /** True when the page must keep its rows for TalkBack. */
    @JavascriptInterface
    fun screenReader(): Boolean = reader

    @JavascriptInterface
    fun geometry(cellW: Double, cellH: Double, originX: Double, originY: Double, cols: Int, rows: Int, font: Int) {
        feeder.geometry(cellW, cellH, originX, originY, cols, rows, font)
    }

    @JavascriptInterface
    fun grid(cols: Int, rows: Int) {
        feeder.grid(cols, rows)
    }

    @JavascriptInterface
    fun drawn(session: String) {
        feeder.drawn(session)
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

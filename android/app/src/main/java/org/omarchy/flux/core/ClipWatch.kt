package org.omarchy.flux.core

import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader

private const val TAG = "FluxClipWatch"

/** The state of the automatic clipboard sync, for the UI and the service notification. */
enum class ClipAutoState {
    /** The sync clipboard switch is off. */
    Off,

    /** The switch is on, but READ_LOGS is not granted, so only the open app syncs. */
    Unavailable,

    /** READ_LOGS is granted, but the log reader needs the user to allow log access again. */
    NeedsConsent,

    /** The log reader runs and reads the copy signal. */
    Active,
}

/**
 * The pure decisions of the automatic clipboard reader. They take the time
 * as an argument, so the tests need no clock. All times are in
 * milliseconds, from [SystemClock.elapsedRealtime].
 */
object ClipGate {
    /** The wait that merges the lines of 1 copy, which come 1 per registered listener. */
    const val DEBOUNCE_MS = 250L

    /** How long the reader ignores the lines after Flux writes the clipboard. */
    const val SELF_WRITE_MS = 2_000L

    /** The shortest time between 2 focus grabs. A denied read by Flux makes the same line. */
    const val RATE_MS = 1_000L

    /**
     * True when [line] is the ClipboardService line that denies clipboard
     * access to [pkg]. The comma after the name stops a package with a
     * suffix, for example `org.omarchy.flux.debug`, from a match.
     */
    fun isDenial(line: String, pkg: String): Boolean =
        line.contains("Denying clipboard access to $pkg,")

    /** True when a line at [now] comes from a Flux write at [lastSelfWrite]. */
    fun isSelfWrite(now: Long, lastSelfWrite: Long): Boolean =
        lastSelfWrite != 0L && now - lastSelfWrite < SELF_WRITE_MS

    /** True when a read at [now] is too soon after the grab at [lastGrab]. */
    fun rateLimited(now: Long, lastGrab: Long): Boolean =
        lastGrab != 0L && now - lastGrab < RATE_MS

    /** True when a line at [now] falls in the merge window that started at [firstLine]. */
    fun debounced(now: Long, firstLine: Long): Boolean =
        firstLine != 0L && now - firstLine < DEBOUNCE_MS
}

/**
 * The automatic clipboard trigger. It reads the system log for the
 * ClipboardService denial line of Flux, which the system writes for each
 * copy while Flux has no focus. On a match, [ClipReader] takes focus for a
 * moment and reads the new clip. See docs/features.md and the research in
 * option 1 of the clipboard design.
 *
 * The reader needs READ_LOGS, which the user grants with adb. Android 13
 * and later ask for log access with a dialog that shows only while Flux is
 * on top, so the reader starts only from [refresh], which the service runs
 * for ACTION_REFRESH after MainActivity.onResume.
 */
object ClipWatch {
    private val main = Handler(Looper.getMainLooper())
    private val listener = ClipboardManager.OnPrimaryClipChangedListener { Plugins.onLocalClipboard(FluxCore) }

    // The main thread uses these.
    private var registered = false
    @Volatile private var foreground = false

    /** True while the reader runs, or should run. */
    @Volatile var armed = false
        private set

    // The reader thread sets these, the main thread reads them.
    @Volatile private var readerState = ClipAutoState.NeedsConsent
    @Volatile private var reader: Thread? = null
    @Volatile private var proc: Process? = null

    // The self-test: Flux reads the clipboard while it goes to the background,
    // which makes 1 denial line. The reader confirms the access when it sees it.
    @Volatile private var probeUntil = 0L
    @Volatile private var probeSeen = false

    /**
     * Reports the state for the UI. [syncOn] is the sync clipboard switch,
     * [hasReadLogs] is the READ_LOGS permission.
     */
    fun uiState(syncOn: Boolean, hasReadLogs: Boolean): ClipAutoState = when {
        !syncOn -> ClipAutoState.Off
        !hasReadLogs -> ClipAutoState.Unavailable
        else -> readerState
    }

    /** Follows the app between the front and the background, from [FluxApp]. */
    fun setForeground(context: Context, on: Boolean) {
        main.post {
            foreground = on
            reconcileListener(context)
            // On the way to the background, the clipboard read is denied and
            // makes a line, so the reader can confirm the log access.
            if (!on && armed) selfTest(context)
        }
    }

    /**
     * Starts or stops the reader to match the state. The service calls it
     * for ACTION_REFRESH, when Flux is on top, so the log-access dialog can
     * show. It also arms the process-life clipboard listener.
     */
    fun refresh(context: Context) {
        val app = context.applicationContext
        val want = FluxCore.settings.syncClipboard && FluxCore.enabled && Android.hasReadLogs(app)
        main.post {
            if (want && !armed) {
                armed = true
                reconcileListener(app)
                startReader(app)
                FluxCore.publish()
            } else if (!want && armed) {
                stop()
            } else if (want && reader == null) {
                // Armed, but the reader died, for example after a decline.
                startReader(app)
            }
        }
    }

    /** Stops the reader and drops the process-life listener. The service calls it in onDestroy. */
    fun stop() {
        main.post {
            armed = false
            readerState = ClipAutoState.NeedsConsent
            stopReader()
            reconcileListener(FluxCore.app)
            FluxCore.publish()
        }
    }

    // ------------------------------------------------------------- internals

    /** Keeps the listener registered while the app is in front or while the reader is armed. */
    private fun reconcileListener(context: Context) {
        val want = foreground || armed
        val cm = context.getSystemService(ClipboardManager::class.java) ?: return
        if (want && !registered) {
            cm.addPrimaryClipChangedListener(listener)
            registered = true
        } else if (!want && registered) {
            cm.removePrimaryClipChangedListener(listener)
            registered = false
        }
    }

    private fun startReader(app: Context) {
        if (reader != null) return
        val t = Thread({ runReader(app) }, "flux-cliplog").apply { isDaemon = true }
        reader = t
        t.start()
    }

    private fun stopReader() {
        proc?.let { runCatching { it.destroy() } }
        proc = null
        reader = null
    }

    /**
     * Reads the log on a thread. A declined reader keeps running but sees
     * only the lines of Flux, so the process does not exit on a decline.
     * The self-test tells an active reader from a declined one.
     */
    private fun runReader(app: Context) {
        val pkg = app.packageName
        val time = timeArg()
        val cmd = listOf("logcat", "-T", time, "ClipboardService:V", "*:S")
        val p = runCatching { ProcessBuilder(cmd).redirectErrorStream(true).start() }.getOrElse {
            Log.w(TAG, "logcat did not start", it)
            readerState = ClipAutoState.NeedsConsent
            reader = null
            main.post { FluxCore.publish() }
            return
        }
        proc = p
        runCatching {
            BufferedReader(InputStreamReader(p.inputStream)).use { r ->
                while (true) {
                    val line = r.readLine() ?: break
                    if (ClipGate.isDenial(line, pkg)) onDenialLine(app)
                }
            }
        }.onFailure { Log.w(TAG, "log read stopped", it) }
        proc = null
        if (reader === Thread.currentThread()) reader = null
    }

    private fun onDenialLine(app: Context) {
        val now = SystemClock.elapsedRealtime()
        if (probeUntil != 0L && now < probeUntil) {
            // The self-test read made this line, so do not grab focus for it.
            probeSeen = true
            return
        }
        main.post { ClipReader.request(app) }
    }

    /**
     * Confirms the log access. Flux reads the clipboard once, which is
     * denied in the background and makes 1 line. The reader marks
     * [ClipAutoState.Active] when it sees the line within the window.
     */
    private fun selfTest(context: Context) {
        if (!armed || reader == null) return
        val app = context.applicationContext
        probeSeen = false
        probeUntil = SystemClock.elapsedRealtime() + PROBE_MS
        // A read without focus makes the denial line for the reader.
        runCatching { app.getSystemService(ClipboardManager::class.java)?.hasPrimaryClip() }
        main.postDelayed({ finishSelfTest(app) }, PROBE_MS)
    }

    private fun finishSelfTest(app: Context) {
        probeUntil = 0L
        if (!armed) return
        if (probeSeen) {
            readerState = ClipAutoState.Active
        } else {
            readerState = ClipAutoState.NeedsConsent
            stopReader()
        }
        FluxCore.publish()
    }

    /** The `-T` time for logcat, in the format that the reader expects: `MM-DD HH:MM:SS.mmm`. */
    private fun timeArg(): String {
        val f = java.text.SimpleDateFormat("MM-dd HH:mm:ss.SSS", java.util.Locale.US)
        return f.format(java.util.Date())
    }

    /** The self-test waits this long for the reader to see the probe line. */
    private const val PROBE_MS = 2_000L
}

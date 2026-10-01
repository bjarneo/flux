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

    /**
     * The sync clipboard switch is on, but the automatic sync is off, or
     * READ_LOGS or the overlay access is missing, so only the open app
     * syncs. The setup sheet turns the automatic sync on.
     */
    Unavailable,

    /** READ_LOGS is granted, but the log reader needs the user to allow log access again. */
    NeedsConsent,

    /**
     * The log reader started while Flux was on top. The self-test runs the
     * next time Flux goes to the background and sets [Active] or
     * [NeedsConsent].
     */
    Checking,

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

    /** The answer of [grabDelay] for a line that needs no focus grab of its own. */
    const val NO_GRAB = -1L

    /**
     * True when the log reader must run. [syncOn] is the sync clipboard
     * switch, [autoOn] is the automatic sync that the user turns on in the
     * setup sheet, and [enabled] is false while Flux is off. Without
     * [overlayAccess], a copy line cannot lead to a read, so Flux does not
     * ask for log access then either.
     */
    fun wantsReader(syncOn: Boolean, autoOn: Boolean, enabled: Boolean, hasReadLogs: Boolean, overlayAccess: Boolean): Boolean =
        syncOn && autoOn && enabled && hasReadLogs && overlayAccess

    /**
     * The first value of the automatic sync switch, for a store that does not
     * hold it yet. Earlier versions started the reader when both accesses
     * were in place, with no switch. So an update ([updated]) from such a
     * version keeps the sync on when Flux has [hasReadLogs] and
     * [overlayAccess]. A new install starts with the switch off, also when
     * the user ran the adb commands before the first start.
     */
    fun keepsAutoSync(updated: Boolean, hasReadLogs: Boolean, overlayAccess: Boolean): Boolean =
        updated && hasReadLogs && overlayAccess

    /**
     * The state for the UI. [reader] is the state of the log reader, which
     * counts only when the automatic sync can run.
     */
    fun autoState(syncOn: Boolean, autoOn: Boolean, hasReadLogs: Boolean, overlayAccess: Boolean, reader: ClipAutoState): ClipAutoState = when {
        !syncOn -> ClipAutoState.Off
        !autoOn || !hasReadLogs || !overlayAccess -> ClipAutoState.Unavailable
        else -> reader
    }

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

    /**
     * The wait before the focus grab for a line at [now], or [NO_GRAB]. A
     * line within [SELF_WRITE_MS] of a Flux write needs no grab. A line
     * while a grab waits ([pending]) needs no grab either, because that
     * grab reads the newest clip. Otherwise the grab waits [DEBOUNCE_MS], so
     * the lines of 1 copy merge, and it runs no sooner than [RATE_MS] after
     * [lastGrab]. The rate limit thus moves a line to a later grab and does
     * not drop it.
     */
    fun grabDelay(now: Long, pending: Boolean, lastGrab: Long, lastSelfWrite: Long): Long = when {
        isSelfWrite(now, lastSelfWrite) -> NO_GRAB
        pending -> NO_GRAB
        rateLimited(now + DEBOUNCE_MS, lastGrab) -> lastGrab + RATE_MS - now
        else -> DEBOUNCE_MS
    }

    /**
     * True when a trip to the background must run the self-test for a
     * reader in [state]. Only a new reader needs the test, and only 1 test
     * runs at a time ([probing]). The test ignores a line, so a test on each
     * trip would drop the line of a real copy.
     */
    fun needsSelfTest(state: ClipAutoState, probing: Boolean): Boolean =
        state == ClipAutoState.Checking && !probing

    /**
     * True when a line at [now] comes from the self-test read. Only the
     * first line before [probeUntil] is the probe line. A later line in the
     * window ([probeSeen] is true) comes from a real copy.
     */
    fun isProbeLine(now: Long, probeUntil: Long, probeSeen: Boolean): Boolean =
        !probeSeen && probeUntil != 0L && now < probeUntil
}

/**
 * The automatic clipboard trigger. It reads the system log for the
 * ClipboardService denial line of Flux, which the system writes for each
 * copy while Flux has no focus. On a match, [ClipReader] takes focus for a
 * moment and reads the new clip. See docs/features.md and the research in
 * option 1 of the clipboard design.
 *
 * The reader needs READ_LOGS, which the user grants with adb, and the
 * overlay access, which [ClipReader] needs to take focus. It starts only
 * after the user turns on the automatic sync in the setup sheet, see
 * [Settings.autoClipboard]. Android 13 and later ask for log access with a
 * dialog that shows only while Flux is on top, so the reader starts only
 * from [refresh], which the service runs for ACTION_REFRESH after
 * MainActivity.onResume and after the switch turns on.
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

    // The reader thread sets these, the main thread reads them. [lock] guards
    // the handover of the logcat process, so a stop never misses a process.
    private val lock = Any()
    @Volatile private var readerState = ClipAutoState.NeedsConsent
    @Volatile private var reader: Thread? = null
    @Volatile private var proc: Process? = null

    // The self-test: Flux reads the clipboard while it goes to the background,
    // which makes 1 denial line. The reader confirms the access when it sees it.
    @Volatile private var probeUntil = 0L
    @Volatile private var probeSeen = false

    /**
     * Reports the state for the UI. [syncOn] is the sync clipboard switch,
     * [autoOn] is the automatic sync switch of the setup sheet,
     * [hasReadLogs] is the READ_LOGS permission, and [overlayAccess] is the
     * permission to draw over other apps. Without the overlay access, the
     * reader cannot take focus, so the UI shows the setup hint.
     */
    fun uiState(syncOn: Boolean, autoOn: Boolean, hasReadLogs: Boolean, overlayAccess: Boolean): ClipAutoState =
        ClipGate.autoState(syncOn, autoOn, hasReadLogs, overlayAccess, readerState)

    /** Follows the app between the front and the background, from [FluxApp]. */
    fun setForeground(context: Context, on: Boolean) {
        main.post {
            foreground = on
            reconcileListener(context)
            // On the way to the background, the clipboard read is denied and
            // makes a line, so a new reader can confirm the log access.
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
        // Without the switch of the setup sheet, Flux starts no reader, so Android shows no log access dialog.
        val s = FluxCore.settings
        val want = ClipGate.wantsReader(s.syncClipboard, s.autoClipboard, FluxCore.enabled, Android.hasReadLogs(app), Android.canDrawOverlays(app))
        main.post {
            if (want && !armed) {
                armed = true
                reconcileListener(app)
                startReader(app)
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
        // The self-test confirms the log access when Flux goes to the background.
        readerState = ClipAutoState.Checking
        FluxCore.publish()
        t.start()
    }

    private fun stopReader() {
        synchronized(lock) {
            proc?.let { runCatching { it.destroy() } }
            proc = null
            reader = null
        }
    }

    /**
     * Reads the log on a thread. A declined reader keeps running but sees
     * only the lines of Flux, so the process does not exit on a decline.
     * The self-test tells an active reader from a declined one.
     */
    private fun runReader(app: Context) {
        val me = Thread.currentThread()
        val pkg = app.packageName
        val time = timeArg()
        val cmd = listOf("logcat", "-T", time, "ClipboardService:V", "*:S")
        val p = runCatching { ProcessBuilder(cmd).redirectErrorStream(true).start() }.getOrElse {
            Log.w(TAG, "logcat did not start", it)
            onReaderExit(me)
            return
        }
        synchronized(lock) {
            // A stop that came before this point found no process to end.
            if (reader !== me) {
                runCatching { p.destroy() }
                return
            }
            proc = p
        }
        runCatching {
            BufferedReader(InputStreamReader(p.inputStream)).use { r ->
                while (true) {
                    val line = r.readLine() ?: break
                    if (reader !== me) break
                    if (ClipGate.isDenial(line, pkg)) onDenialLine(app)
                }
            }
        }.onFailure { Log.i(TAG, "log read stopped: ${it.message}") }
        synchronized(lock) { if (proc === p) proc = null }
        runCatching { p.destroy() }
        onReaderExit(me)
    }

    /**
     * Handles the end of the reader thread [me]. A stop clears [reader]
     * first, so a match here means that logcat exited by itself, for
     * example after a logd restart or a kill by the phantom process limit.
     * The user must open Flux to start the reader again.
     */
    private fun onReaderExit(me: Thread) {
        synchronized(lock) {
            if (reader !== me) return
            reader = null
        }
        readerState = ClipAutoState.NeedsConsent
        main.post { FluxCore.publish() }
    }

    private fun onDenialLine(app: Context) {
        // A line that comes after the user turned off the sync starts no read.
        if (!armed) return
        val now = SystemClock.elapsedRealtime()
        if (ClipGate.isProbeLine(now, probeUntil, probeSeen)) {
            // The self-test read made this line, so do not grab focus for it.
            // A copy in the window makes a later line, which still gets a grab.
            probeSeen = true
            return
        }
        main.post { ClipReader.request(app) }
    }

    /**
     * Confirms the log access of a new reader. Flux reads the clipboard
     * once, which is denied in the background and makes 1 line. The reader
     * marks [ClipAutoState.Active] when it sees the line within the window.
     * After that, [onReaderExit] finds a reader that stops, so the test runs
     * only in [ClipAutoState.Checking]. See [ClipGate.needsSelfTest].
     */
    private fun selfTest(context: Context) {
        if (!armed) return
        if (reader == null) {
            // The reader ended, so only a start from the open app resumes the sync.
            if (readerState != ClipAutoState.NeedsConsent) {
                readerState = ClipAutoState.NeedsConsent
                FluxCore.publish()
            }
            return
        }
        if (!ClipGate.needsSelfTest(readerState, probing = probeUntil != 0L)) return
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

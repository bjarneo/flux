package org.omarchy.flux.net

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Runs the userspace tailnet node. It joins the tailnet without a VPN
 * interface, so Google VPN and other VPN apps keep the VPN slot, and it
 * forwards the Flux ports to the listeners of this app on loopback.
 */
object TsnetNode {
    private const val TAG = "FluxTsnet"
    private const val BINARY = "libflux_tsnet.so"

    sealed interface State {
        data object Off : State
        data object Starting : State
        data class Ready(val address: String) : State
        data class Failed(val reason: String) : State
    }

    private val _state = MutableStateFlow<State>(State.Off)
    val state: StateFlow<State> = _state.asStateFlow()

    @Volatile private var process: Process? = null
    @Volatile private var stopped = false
    @Volatile private var lastError: String? = null

    /** Starts the node, or restarts it with a new key. */
    @Synchronized
    fun start(context: Context, authKey: String, hostname: String) {
        stopLocked()
        stopped = false
        lastError = null
        if (authKey.isBlank()) {
            _state.value = State.Off
            return
        }
        val binary = File(context.applicationInfo.nativeLibraryDir, BINARY)
        if (!binary.exists()) {
            _state.value = State.Failed("This build has no tailnet helper.")
            return
        }
        val dir = File(context.filesDir, "tsnet").apply { mkdirs() }
        _state.value = State.Starting
        val builder = ProcessBuilder(
            binary.absolutePath,
            "-state-dir", dir.absolutePath,
            "-hostname", hostname,
            "-parent-pid", android.os.Process.myPid().toString(),
        )
        builder.environment()["TS_AUTHKEY"] = authKey
        val p = try {
            builder.start()
        } catch (e: Exception) {
            _state.value = State.Failed(e.message ?: "Could not start the tailnet helper.")
            return
        }
        process = p
        val output = Thread({ readReady(p) }, "flux-tsnet-out").apply { isDaemon = true }
        output.start()
        Thread({ readLog(p) }, "flux-tsnet-log").apply { isDaemon = true }.start()
        Thread({ awaitExit(p, output) }, "flux-tsnet-wait").apply { isDaemon = true }.start()
    }

    /** Stops the node. */
    @Synchronized
    fun stop() {
        stopped = true
        stopLocked()
        _state.value = State.Off
    }

    private fun stopLocked() {
        val p = process ?: return
        process = null
        p.destroy()
        if (!p.waitFor(3, TimeUnit.SECONDS)) p.destroyForcibly()
    }

    private fun readReady(p: Process) {
        p.inputStream.bufferedReader().useLines { lines ->
            for (line in lines) {
                when {
                    line.startsWith("error ") -> {
                        val reason = line.removePrefix("error ").trim()
                        if (reason.isNotEmpty()) {
                            lastError = reason
                            _state.value = State.Failed(reason)
                        }
                    }
                    line.startsWith("ready ") -> {
                        val address = line.removePrefix("ready ").trim()
                        if (address.isNotEmpty() && process === p) _state.value = State.Ready(address)
                    }
                }
            }
        }
    }

    private fun readLog(p: Process) {
        p.errorStream.bufferedReader().useLines { lines ->
            for (line in lines) Log.i(TAG, line)
        }
    }

    private fun awaitExit(p: Process, output: Thread) {
        val code = runCatching { p.waitFor() }.getOrDefault(-1)
        // The last stdout line can arrive after the process exits. Let the
        // reader take it before the link is marked dead.
        output.join(1500)
        synchronized(this) {
            if (process !== p) return
            process = null
            if (!stopped) _state.value = State.Failed(lastError ?: "The tailnet helper stopped ($code).")
        }
    }
}

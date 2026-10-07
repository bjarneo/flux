package org.omarchy.flux.core

import android.net.Uri
import android.util.Log
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.omarchy.flux.net.Payload
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

private const val TAG = "FluxHerdr"

/** How long a finished agent must stay ready before the phone posts it. Status can flap between tool calls. */
private const val FINISH_HOLD_MS = 2_000L

/** How long a read waits for the output. fluxd can take 10 seconds to collect the history of an agent. */
private const val READ_TIMEOUT_MS = 15_000L

/** How long a new agent or terminal waits. fluxd waits up to 45 seconds for herdr to start an agent. */
private const val CREATE_TIMEOUT_MS = 60_000L

/** How long a reply waits for the answer of the computer. */
private const val REPLY_TIMEOUT_MS = 10_000L

/** How long a terminal open waits for terminal_opened. fluxd answers each open within 15 seconds. */
private const val TERMINAL_OPEN_TIMEOUT_MS = 20_000L

/** How long the phone waits after a reply before it reads the output again. The agent needs a moment to draw. */
private const val REREAD_DELAY_MS = 700L

/** The number of lines that a read asks for. fluxd allows 1 to 1000. */
const val HERDR_READ_LINES = 1000

/**
 * Shows the herdr agents of a computer with flux.herdr. The computer sends
 * the agent list, and this phone asks for the recent output of a pane.
 * When the computer allows it, the phone also sends keys and prompts to an
 * agent, starts agents, and closes them. When the computer allows
 * terminals, the phone also opens terminals and types in them. The UI
 * asks for the phone lock before the first reply.
 */
object HerdrSync {
    /**
     * The finished notifications that wait for [FINISH_HOLD_MS], by device
     * ID and pane. Only the thread of [FluxCore.scheduler] uses it.
     */
    private val pending = HashMap<String, ScheduledFuture<*>>()

    /** Counts the reads, so that a late timeout does not replace a newer read. The core lock guards it. */
    private var reads = 0L
    private val reviews = HashMap<String, String>()
    private val readRequests = HashMap<String, HerdrReadRequest>()

    /** Counts the replies, so that a late timeout does not replace a newer reply. The core lock guards it. */
    private var replies = 0L

    /** Counts the terminal opens and releases, so that a late answer matches its request. */
    private var terminalSeq = 0L

    /**
     * The sink of the terminal events of an open stream. It takes the
     * device ID and the event, so a late event of one computer never
     * reaches the terminal of another, whose session can share the same
     * name. It runs on the network thread with the core lock held, so it
     * must only hand the event over.
     */
    @Volatile
    var terminalSink: ((deviceId: String, event: HerdrTerminalEvent) -> Unit)? = null

    /** Counts the creates and closes, so that a late timeout does not replace a newer one. The core lock guards it. */
    private var actions = 0L

    private fun key(deviceId: String, pane: String) = "$deviceId|$pane"

    /** Makes the next agent list set the start values. The core lock is held. */
    fun onConnected(d: Device) {
        d.herdrTracker.restart()
    }

    /** Handles flux.herdr from a computer. The core lock is held. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        when (p.string("kind")) {
            "state" -> {
                val state = parseHerdrState(p.body) ?: return
                d.herdr = state
                val alerts = d.herdrTracker.update(state.agents)
                if (alerts.isNotEmpty()) {
                    val name = d.identity.deviceName
                    val id = d.id
                    // The scheduler has 1 thread, so the alerts keep their order.
                    core.scheduler.execute { alert(core, id, name, alerts) }
                }
            }
            "output" -> onOutput(d, parseHerdrOutput(p.body) ?: return)
            "sent" -> {
                val sent = parseHerdrSent(p.body) ?: return
                val reply = d.herdrReply
                if (reply == null || !sent.answers(reply)) return
                // The error text of fluxd goes to the screen as it is, for
                // example when the agent waits for a choice.
                d.herdrReply = reply.copy(sending = false, error = sent.error, code = sent.code)
                if (sent.error == null) {
                    val id = d.id
                    core.scheduler.schedule({ read(core, id, sent.pane) }, REREAD_DELAY_MS, TimeUnit.MILLISECONDS)
                }
            }
            "created", "closed" -> {
                val done = parseHerdrDone(p.body) ?: return
                val action = d.herdrAction
                if (action == null || !done.answers(action)) return
                d.herdrAction = action.copy(sending = false, pane = done.pane ?: action.pane, error = done.error)
            }
            "terminal_opened" -> onTerminalOpened(d, p.body)
            "terminal_frame" -> {
                val frame = parseHerdrTerminalFrame(p.body) ?: return
                // Only the stream of this phone gets its frames.
                if (d.herdrTerminal?.session != frame.session) return
                terminalSink?.invoke(d.id, frame)
            }
            "terminal_closed" -> onTerminalClosed(d, p.body)
            "terminal_input_error" -> onTerminalInputError(d, p.body)
            else -> Log.d(TAG, "ignored flux.herdr kind ${p.string("kind")}")
        }
    }

    /**
     * Keeps the output of a pane that [parseHerdrOutput] read. The core lock
     * is held. The core parses the output before it takes the lock.
     */
    fun onOutput(d: Device, out: HerdrOutput) {
        // Only the pane on screen keeps its output.
        if (d.herdrOutput?.pane != out.pane) return
        val expected = readRequests[key(d.id, out.pane)]
        if (expected != null && !expected.accepts(out, d.herdr?.review == true)) return
        d.herdrOutput = out
    }

    /** Asks the computer for its agent list now. */
    fun request(core: FluxCore, id: String) {
        core.device(id)?.send(Packet(Types.FLUX_HERDR, bodyOf("kind" to "request")))
    }

    /**
     * Asks the computer for the recent output of [pane]. The output of the
     * last read stays on screen until the answer comes.
     */
    fun read(core: FluxCore, id: String, pane: String, review: Boolean? = null, path: String = "") {
        val token = core.locked {
            val d = core.device(id) ?: return@locked null
            val reviewKey = key(id, pane)
            if (review == true) reviews[reviewKey] = path
            if (review == false) reviews.remove(reviewKey)
            val view = if (reviews.containsKey(reviewKey)) "diff" else "ansi"
            val selectedPath = reviews[reviewKey].orEmpty()
            val request = HerdrReadRequest(++reads, view, selectedPath)
            readRequests[reviewKey] = request
            val old = d.herdrOutput?.takeIf { it.pane == pane && it.view == view && it.path == selectedPath }
            d.herdrOutput = (old ?: HerdrOutput(pane)).copy(loading = true, error = null)
            val sent = d.send(
                Packet(Types.FLUX_HERDR, bodyOf("kind" to "read", "pane" to pane, "lines" to HERDR_READ_LINES,
                    "format" to view, "path" to selectedPath, "request" to request.id)),
            )
            if (!sent) {
                d.herdrOutput = d.herdrOutput?.copy(loading = false, error = "${d.identity.deviceName} is not reachable")
                return@locked null
            }
            request.id
        } ?: return
        core.scheduler.schedule({
            core.locked {
                val d = core.device(id) ?: return@locked
                val out = d.herdrOutput
                if (token == readRequests[key(id, pane)]?.id && out != null && out.pane == pane && out.loading) {
                    d.herdrOutput = out.copy(loading = false, error = "${d.identity.deviceName} did not answer")
                }
            }
        }, READ_TIMEOUT_MS, TimeUnit.MILLISECONDS)
    }

    /** Forgets the output and the last reply when the agent screen closes. */
    fun closeOutput(core: FluxCore, id: String, pane: String) {
        core.locked {
            reviews.remove(key(id, pane))
            readRequests.remove(key(id, pane))
            val d = core.device(id) ?: return@locked
            if (d.herdrOutput?.pane == pane) d.herdrOutput = null
            if (d.herdrReply?.pane == pane) d.herdrReply = null
        }
    }

    /**
     * Opens a terminal session on [pane]. With [mode] "observe" the
     * phone only shows the terminal of the pane. "control" also sends
     * gestures and keys, and needs `herdr_control` on the computer. The
     * answer sets [Device.herdrTerminal], and [terminalSink] gets the
     * events of the stream in the order they arrive. An open stream of
     * this phone is released first. It returns the number of the open,
     * which the answer carries, or 0 for an unknown device.
     */
    fun terminalOpen(core: FluxCore, id: String, pane: String, mode: String, cols: Int = 0, rows: Int = 0): Long {
        val token = core.locked {
            val d = core.device(id) ?: return@locked null
            val seq = ++terminalSeq
            val change = terminalOpenChange(d.herdrTerminal, pane, mode, seq)
            change.release?.let { d.send(Packet(Types.FLUX_HERDR, herdrTerminalReleaseBody(it, ++terminalSeq))) }
            d.herdrTerminal = change.slot
            if (!d.send(Packet(Types.FLUX_HERDR, herdrTerminalOpenBody(pane, mode, seq, cols, rows)))) {
                d.herdrTerminal = change.slot?.copy(
                    sending = false, error = "${d.identity.deviceName} is not reachable", retry = true,
                )
            }
            seq
        } ?: return 0
        core.scheduler.schedule({
            core.locked {
                val d = core.device(id) ?: return@locked
                terminalOpenTimeout(d.herdrTerminal, token, "${d.identity.deviceName} did not answer")?.let { d.herdrTerminal = it }
            }
        }, TERMINAL_OPEN_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        return token
    }

    /**
     * Releases the terminal session of [pane]. A session of another pane
     * stays, because it belongs to another screen. The computer answers
     * with terminal_closed after the last frame of the stream.
     */
    fun terminalRelease(core: FluxCore, id: String, pane: String) {
        core.locked {
            val d = core.device(id) ?: return@locked
            val change = terminalReleaseChange(d.herdrTerminal, pane) ?: return@locked
            d.herdrTerminal = change.slot
            val session = change.release ?: return@locked
            if (!d.send(Packet(Types.FLUX_HERDR, herdrTerminalReleaseBody(session, ++terminalSeq)))) {
                // The link is gone, so the end of the stream can never
                // arrive. The computer ended the stream with the link, so
                // no released session stays for a reconnect to wait for.
                d.herdrTerminal = null
            }
        }
    }

    /**
     * Forgets the released [session] of [pane] when its terminal_closed did
     * not arrive in time. A new open on the pane then does not wait for it.
     */
    fun terminalDrop(core: FluxCore, id: String, pane: String, session: String) {
        core.locked {
            val d = core.device(id) ?: return@locked
            val t = d.herdrTerminal
            if (t != null && t.pane == pane && t.session == session && terminalClosePending(t)) d.herdrTerminal = null
        }
    }

    /**
     * Sends one wheel step to the terminal of [session] at the
     * zero-based cell ([column], [row]). The computer routes it to the
     * program in the pane or to its history.
     *
     * A step changes no state of the phone, so it goes out without the
     * core lock and its full publish: at 90 steps a second a publish per
     * step would rebuild and recompose the whole screen.
     */
    fun terminalScroll(core: FluxCore, id: String, session: String, direction: String, column: Int, row: Int) {
        if (session.isEmpty() || (direction != "up" && direction != "down")) return
        val d = core.device(id) ?: return
        d.send(Packet(Types.FLUX_HERDR, herdrTerminalScrollBody(session, direction, column, row)))
    }

    /** Sends one pointer event to the terminal of [session]. */
    fun terminalMouse(core: FluxCore, id: String, session: String, action: String, button: String, column: Int, row: Int) {
        if (session.isEmpty() || action !in setOf("down", "up", "drag", "move")) return
        core.locked {
            val d = core.device(id) ?: return@locked
            d.send(Packet(Types.FLUX_HERDR, herdrTerminalMouseBody(session, action, button, column, row)))
        }
    }

    /** Resizes the PTY of the active phone-controlled terminal session. */
    fun terminalResize(core: FluxCore, id: String, session: String, cols: Int, rows: Int) {
        if (session.isEmpty() || cols !in 1..1000 || rows !in 1..1000) return
        val d = core.device(id) ?: return
        d.send(Packet(Types.FLUX_HERDR, herdrTerminalResizeBody(session, cols, rows)))
    }

    /**
     * Types one text event in the active controller session. The text goes
     * as it is. fluxd does not trim it or press Enter, and it refuses an
     * empty text or a text with a control character. A step changes no
     * phone state, so it goes out without the core lock and its publish. A
     * publish for each character would build the whole screen again.
     * Returns false when the packet did not go out.
     */
    fun terminalInput(core: FluxCore, id: String, session: String, text: String): Boolean {
        if (session.isEmpty() || text.isEmpty()) return false
        val d = core.device(id) ?: return false
        return sendInput(d, Packet(Types.FLUX_HERDR, herdrTerminalInputBody(session, text)))
    }

    /** Sends one named key to the active controller session. Returns false when the packet did not go out. */
    fun terminalInputKey(core: FluxCore, id: String, session: String, key: String): Boolean {
        if (session.isEmpty() || key !in HERDR_TERMINAL_INPUT_KEYS) return false
        val d = core.device(id) ?: return false
        return sendInput(d, Packet(Types.FLUX_HERDR, herdrTerminalKeyBody(session, key)))
    }

    /**
     * Pastes [text] as one bracketed paste in the active controller
     * session. The program reads it as pasted content and applies its own
     * paste handling, so its line breaks do not submit. fluxd wraps the
     * text, bounds its size, and drops control characters. It does not
     * press Enter. Returns false when the packet did not go out.
     */
    fun terminalPaste(core: FluxCore, id: String, session: String, text: String): Boolean {
        if (session.isEmpty() || text.isEmpty()) return false
        val d = core.device(id) ?: return false
        return sendInput(d, Packet(Types.FLUX_HERDR, herdrTerminalPasteBody(session, text)))
    }

    /**
     * The typed packets of each device that wait while an image of the
     * device turns into a PNG, by device ID. The image packet goes first,
     * and fluxd keeps the order after it. Without this wait, an Enter
     * typed after the paste would submit the prompt before the image.
     */
    private val waitingInput = HashMap<String, MutableList<Packet>>()

    /** Sends one typed packet, or keeps it while an image of the device turns into a PNG. */
    private fun sendInput(d: Device, p: Packet): Boolean = synchronized(waitingInput) {
        val waiting = waitingInput[d.id]
        if (waiting != null) {
            waiting += p
            true
        } else {
            d.send(p)
        }
    }

    /**
     * Ends the wait [wait] of the typed packets of the device. [first] goes
     * out before them, for example the image packet. The sends only queue
     * the packets, so they run under the lock, and no new packet can pass
     * them. A wait that already ended changes nothing, so the wait of a
     * newer image stays. Returns false when [first] did not go out.
     */
    private fun endInputWait(d: Device?, id: String, wait: MutableList<Packet>, first: Packet?): Boolean = synchronized(waitingInput) {
        if (waitingInput[id] !== wait) return@synchronized false
        waitingInput.remove(id)
        if (d == null) return@synchronized false
        val sent = first == null || d.send(first)
        for (p in wait) d.send(p)
        sent
    }

    /** An image paste that waits for fluxd to fetch it. A refusal or the end of the session closes its [server]. */
    private class ImageUpload(val session: String, val server: java.net.ServerSocket) {
        @Volatile var cancelled = false
    }

    /** The image paste of each device that waits for fluxd, by device ID. */
    private val imageUploads = java.util.concurrent.ConcurrentHashMap<String, ImageUpload>()

    /**
     * Pastes the image at [uri] into the active controller session. The
     * phone turns the image into a PNG of at most [TERMINAL_IMAGE_SIDE]
     * pixels on its long side, in its upright orientation. The PNG travels
     * as the payload of the packet, so fluxd can put it on the clipboard of
     * the computer before it sends the paste key. The program then reads
     * the image as an attachment instead of typed text. [release] ends the
     * read grant of the keyboard after the read.
     *
     * The decode and the send block, so they run on the IO pool and not on
     * the caller. A failure on the phone shows a toast, because the
     * terminal cannot name an image that never left the phone.
     */
    fun terminalPasteImage(core: FluxCore, id: String, session: String, uri: Uri, release: () -> Unit): Boolean {
        if (session.isEmpty()) {
            release()
            return false
        }
        // The typed packets wait from now until the image packet went out.
        // One image of a device turns into a PNG at a time.
        val wait = mutableListOf<Packet>()
        val started = synchronized(waitingInput) { waitingInput.putIfAbsent(id, wait) == null }
        if (!started) {
            release()
            core.toast("Flux still pastes an image. Paste again when it ends")
            return false
        }
        core.io.execute {
            try {
                val png = try {
                    terminalPng(core.app.contentResolver, uri)
                } catch (e: Exception) {
                    Log.w(TAG, "read the pasted image failed", e)
                    null
                } finally {
                    release()
                }
                val d = core.device(id) ?: return@execute
                when {
                    png == null -> core.toast("Flux could not read that image")
                    png.size > ClipImage.MAX_BYTES -> core.toast("That image is larger than ${ClipImage.MAX_BYTES shr 20} MiB as a PNG")
                    else -> sendTerminalImage(core, d, session, png, wait)
                }
            } finally {
                // A failure lets the typed packets go without the image.
                endInputWait(core.device(id), id, wait, null)
            }
        }
        return true
    }

    /**
     * Sends [png] as the payload of a terminal_paste_image. The typed
     * packets that waited go out after the image packet. Runs on the IO pool.
     */
    private fun sendTerminalImage(core: FluxCore, d: Device, session: String, png: ByteArray, wait: MutableList<Packet>) {
        val name = d.identity.deviceName
        val cert = d.certificate
        val tls = FluxCore.tls
        if (cert == null || tls == null) {
            core.toast("$name is not ready for an image")
            return
        }
        val server = try {
            Payload.openServer()
        } catch (e: Exception) {
            Log.w(TAG, "open a payload port for the image failed", e)
            core.toast("Flux could not send the image to $name")
            return
        }
        val upload = ImageUpload(session, server)
        imageUploads.put(d.id, upload)?.let { old ->
            old.cancelled = true
            runCatching { old.server.close() }
        }
        try {
            val p = Packet(
                Types.FLUX_HERDR, herdrTerminalPasteImageBody(session),
                payloadSize = png.size.toLong(), payloadPort = server.localPort,
            )
            if (!endInputWait(d, d.id, wait, p)) {
                core.toast("$name is not reachable")
                return
            }
            val sent = runCatching { Payload.send(tls, server, png.inputStream(), png.size.toLong(), cert) }
            // A refusal of fluxd closes the server and shows its own reason.
            if (sent.isFailure && !upload.cancelled) {
                Log.w(TAG, "send the pasted image failed", sent.exceptionOrNull())
                core.toast("Flux could not send the image to $name")
            }
        } finally {
            imageUploads.remove(d.id, upload)
            runCatching { server.close() }
        }
    }

    /** Stops the image paste of the device that waits for [session], because fluxd will not fetch it. */
    private fun cancelImageUpload(d: Device, session: String) {
        val upload = imageUploads[d.id] ?: return
        if (upload.session != session) return
        upload.cancelled = true
        runCatching { upload.server.close() }
    }

    /**
     * Reads the output of [pane] again after a short wait. A choice that
     * went through the live terminal gets no sent answer, so the tiles get
     * the next dialog this way.
     */
    fun rereadSoon(core: FluxCore, id: String, pane: String) {
        core.scheduler.schedule({ read(core, id, pane) }, REREAD_DELAY_MS, TimeUnit.MILLISECONDS)
    }

    /** Clears the input error [seq] of the terminal of the device after the screen showed it. */
    fun clearTerminalInputError(core: FluxCore, id: String, seq: Int) {
        core.locked {
            val d = core.device(id) ?: return@locked
            val t = d.herdrTerminal ?: return@locked
            if (t.inputErrorSeq == seq) d.herdrTerminal = t.copy(inputError = null)
        }
    }

    /** Handles terminal_input_error: why an event did not reach the terminal. The core lock is held. */
    private fun onTerminalInputError(d: Device, body: JsonObject) {
        val e = parseHerdrTerminalInputError(body) ?: return
        val t = d.herdrTerminal ?: return
        if (t.session != e.session) return
        if (e.image) cancelImageUpload(d, e.session)
        d.herdrTerminal = t.copy(inputError = e.error, inputErrorSeq = t.inputErrorSeq + 1)
    }

    /** Handles terminal_opened, the answer to a terminal_open. The core lock is held. */
    private fun onTerminalOpened(d: Device, body: JsonObject) {
        val opened = parseHerdrTerminalOpened(body) ?: return
        // The screen that asked can be gone by now. The phone releases its
        // session at once, because it would otherwise run for nobody.
        if (staleTerminalAnswer(d.herdrTerminal, opened)) {
            if (opened.open) {
                d.send(Packet(Types.FLUX_HERDR, herdrTerminalReleaseBody(opened.session, ++terminalSeq)))
            }
            return
        }
        d.herdrTerminal = opened
        if (opened.open) terminalSink?.invoke(d.id, HerdrTerminalEvent.Opened(opened.session, opened.width, opened.height))
    }

    /** Handles terminal_closed, the end of a stream. The core lock is held. */
    private fun onTerminalClosed(d: Device, body: JsonObject) {
        val closed = parseHerdrTerminalClosed(body) ?: return
        val t = d.herdrTerminal ?: return
        if (t.session != closed.session) return
        cancelImageUpload(d, closed.session)
        d.herdrTerminal = t.copy(sending = false, open = false, code = closed.code, reason = closed.reason, closed = true)
        terminalSink?.invoke(d.id, closed)
    }

    /**
     * Sends key presses to the agent in [pane], for example "2" to select
     * the second choice of a dialog. Only the keys in [HERDR_KEYS] go out.
     */
    fun sendKeys(core: FluxCore, id: String, pane: String, keys: List<String>) {
        if (keys.isEmpty() || keys.size > HERDR_MAX_KEYS || keys.any { it !in HERDR_KEYS }) return
        reply(core, id, pane, "keys", bodyOf("kind" to "keys", "pane" to pane, "keys" to keys))
    }

    /**
     * Types [text] in the terminal [pane], then sends [keys], for example
     * "ls" and "enter". Only the keys in [HERDR_TERMINAL_KEYS] go out.
     */
    fun sendInput(core: FluxCore, id: String, pane: String, text: String, keys: List<String>) {
        if (keys.size > HERDR_MAX_KEYS || keys.any { it !in HERDR_TERMINAL_KEYS }) return
        if (text.isEmpty() && keys.isEmpty()) return
        if (text.toByteArray(Charsets.UTF_8).size > HERDR_MAX_PROMPT) {
            core.locked {
                val d = core.device(id) ?: return@locked
                d.herdrReply = HerdrReply(pane, "input", ++replies, sending = false, error = "The text is too long. The limit is 16 KB.")
            }
            return
        }
        reply(core, id, pane, "input", bodyOf("kind" to "input", "pane" to pane, "text" to text, "keys" to keys))
    }

    /**
     * Asks the computer to open a pane: an agent of [kind] when [what] is
     * "agent", or a shell when it is "terminal". The pane opens in [cwd]
     * and in a new tab of [workspace], or in a new workspace when
     * [workspace] is empty.
     */
    fun create(core: FluxCore, id: String, what: String, kind: String, cwd: String, workspace: String) {
        action(core, id, HerdrAction("create", 0, what = what), CREATE_TIMEOUT_MS) { seq ->
            bodyOf("kind" to "create", "what" to what, "agent" to kind, "cwd" to cwd.trim(), "workspace" to workspace, "request" to seq)
        }
    }

    /** Asks the computer to close [pane]. The agent or the shell in it ends. */
    fun close(core: FluxCore, id: String, pane: String) {
        action(core, id, HerdrAction("close", 0, pane = pane), REPLY_TIMEOUT_MS) { seq -> bodyOf("kind" to "close", "pane" to pane, "request" to seq) }
    }

    /** Forgets the last create or close, after the UI used its answer. */
    fun clearAction(core: FluxCore, id: String, seq: Long) {
        core.locked {
            val d = core.device(id) ?: return@locked
            if (d.herdrAction?.seq == seq) d.herdrAction = null
        }
    }

    /**
     * Sends a create or a close. [body] gets the number of the action, which
     * a newer fluxd sends back in its answer.
     */
    private fun action(core: FluxCore, id: String, start: HerdrAction, timeout: Long, body: (seq: Long) -> JsonObject) {
        val token = core.locked {
            val d = core.device(id) ?: return@locked null
            val seq = ++actions
            d.herdrAction = start.copy(seq = seq)
            if (!d.send(Packet(Types.FLUX_HERDR, body(seq)))) {
                d.herdrAction = start.copy(seq = seq, sending = false, error = "${d.identity.deviceName} is not reachable")
                return@locked null
            }
            seq
        } ?: return
        core.scheduler.schedule({
            core.locked {
                val d = core.device(id) ?: return@locked
                val a = d.herdrAction
                if (a != null && a.seq == token && a.sending) {
                    d.herdrAction = a.copy(sending = false, error = "${d.identity.deviceName} did not answer")
                }
            }
        }, timeout, TimeUnit.MILLISECONDS)
    }

    /**
     * Sends [text] to the agent in [pane]. The computer submits it as a
     * prompt. An agent that waits for a choice refuses a prompt, unless
     * [answer] is true: then the computer types the text as the answer.
     */
    fun sendPrompt(core: FluxCore, id: String, pane: String, text: String, answer: Boolean = false) {
        val t = text.trim()
        if (t.isEmpty()) return
        if (t.toByteArray(Charsets.UTF_8).size > HERDR_MAX_PROMPT) {
            core.locked {
                val d = core.device(id) ?: return@locked
                d.herdrReply = HerdrReply(pane, "prompt", ++replies, sending = false, error = "The text is too long. The limit is 16 KB.")
            }
            return
        }
        reply(core, id, pane, "prompt", herdrPromptBody(pane, t, answer))
    }

    /**
     * Sends a reply to a pane. The body gets the number of the reply, which
     * a newer fluxd sends back in its answer.
     */
    private fun reply(core: FluxCore, id: String, pane: String, action: String, body: JsonObject) {
        val token = core.locked {
            val d = core.device(id) ?: return@locked null
            val seq = ++replies
            d.herdrReply = HerdrReply(pane, action, seq)
            if (!d.send(Packet(Types.FLUX_HERDR, JsonObject(body + ("request" to JsonPrimitive(seq)))))) {
                d.herdrReply = HerdrReply(pane, action, seq, sending = false, error = "${d.identity.deviceName} is not reachable")
                return@locked null
            }
            seq
        } ?: return
        core.scheduler.schedule({
            core.locked {
                val d = core.device(id) ?: return@locked
                val r = d.herdrReply
                if (r != null && r.seq == token && r.sending) {
                    d.herdrReply = r.copy(sending = false, error = "${d.identity.deviceName} did not answer")
                }
            }
        }, REPLY_TIMEOUT_MS, TimeUnit.MILLISECONDS)
    }

    /** Posts and removes the notifications for [alerts]. It runs on the scheduler thread. */
    private fun alert(core: FluxCore, id: String, computer: String, alerts: List<AgentAlert>) {
        for (a in alerts) {
            val k = key(id, a.pane)
            pending.remove(k)?.cancel(false)
            when (a) {
                is AgentAlert.Clear -> Android.cancelAgent(core.app, id, a.pane)
                is AgentAlert.NeedsInput -> {
                    if (core.settings.agentInputAlerts) Android.showAgent(core.app, id, computer, a.agent)
                }
                is AgentAlert.Finished -> {
                    if (!core.settings.agentDoneAlerts) {
                        Android.cancelAgent(core.app, id, a.pane)
                        continue
                    }
                    val job = core.scheduler.schedule({ finish(core, id, computer, a.pane, k) }, FINISH_HOLD_MS, TimeUnit.MILLISECONDS)
                    pending[k] = job
                }
            }
        }
    }

    /** Posts a finished notification when the agent is still ready after the hold. It runs on the scheduler thread. */
    private fun finish(core: FluxCore, id: String, computer: String, pane: String, k: String) {
        pending.remove(k)
        val agent = core.locked { core.device(id)?.herdr?.agent(pane) } ?: return
        if (!agent.status.ready || !core.settings.agentDoneAlerts) return
        Android.showAgent(core.app, id, computer, agent)
    }
}

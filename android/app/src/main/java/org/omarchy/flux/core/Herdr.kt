package org.omarchy.flux.core

import android.util.Log
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
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

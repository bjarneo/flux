package org.omarchy.flux.core

import android.util.Log
import kotlinx.serialization.json.JsonObject
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

private const val TAG = "FluxHerdr"

/** How long a finished agent must stay ready before the phone posts it. Status can flap between tool calls. */
private const val FINISH_HOLD_MS = 2_000L

/** How long a read waits for the output. */
private const val READ_TIMEOUT_MS = 10_000L

/** How long a reply waits for the answer of the computer. */
private const val REPLY_TIMEOUT_MS = 10_000L

/** How long the phone waits after a reply before it reads the output again. The agent needs a moment to draw. */
private const val REREAD_DELAY_MS = 700L

/** The number of lines that a read asks for. fluxd allows 1 to 400. */
const val HERDR_READ_LINES = 200

/**
 * Shows the herdr agents of a computer with flux.herdr. The computer sends
 * the agent list, and this phone asks for the recent output of a pane.
 * When the computer allows it, the phone also sends keys and prompts to an
 * agent. The UI asks for the phone lock before the first reply.
 */
object HerdrSync {
    /**
     * The finished notifications that wait for [FINISH_HOLD_MS], by device
     * ID and pane. Only the thread of [FluxCore.scheduler] uses it.
     */
    private val pending = HashMap<String, ScheduledFuture<*>>()

    /** Counts the reads, so that a late timeout does not replace a newer read. The core lock guards it. */
    private var reads = 0L

    /** Counts the replies, so that a late timeout does not replace a newer reply. The core lock guards it. */
    private var replies = 0L

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
            "output" -> {
                val out = parseHerdrOutput(p.body) ?: return
                // Only the pane on screen keeps its output.
                if (d.herdrOutput?.pane == out.pane) d.herdrOutput = out
            }
            "sent" -> {
                val sent = parseHerdrSent(p.body) ?: return
                val reply = d.herdrReply
                if (reply == null || reply.pane != sent.pane || !reply.sending) return
                d.herdrReply = reply.copy(sending = false, error = sent.error)
                if (sent.error == null) {
                    val id = d.id
                    core.scheduler.schedule({ read(core, id, sent.pane) }, REREAD_DELAY_MS, TimeUnit.MILLISECONDS)
                }
            }
            else -> Log.d(TAG, "ignored flux.herdr kind ${p.string("kind")}")
        }
    }

    /** Asks the computer for its agent list now. */
    fun request(core: FluxCore, id: String) {
        core.device(id)?.send(Packet(Types.FLUX_HERDR, bodyOf("kind" to "request")))
    }

    /**
     * Asks the computer for the recent output of [pane]. The output of the
     * last read stays on screen until the answer comes.
     */
    fun read(core: FluxCore, id: String, pane: String) {
        val token = core.locked {
            val d = core.device(id) ?: return@locked null
            val old = d.herdrOutput?.takeIf { it.pane == pane }
            d.herdrOutput = (old ?: HerdrOutput(pane)).copy(loading = true, error = null)
            val sent = d.send(
                Packet(Types.FLUX_HERDR, bodyOf("kind" to "read", "pane" to pane, "lines" to HERDR_READ_LINES, "format" to "ansi")),
            )
            if (!sent) {
                d.herdrOutput = d.herdrOutput?.copy(loading = false, error = "${d.identity.deviceName} is not reachable")
                return@locked null
            }
            ++reads
        } ?: return
        core.scheduler.schedule({
            core.locked {
                val d = core.device(id) ?: return@locked
                val out = d.herdrOutput
                if (token == reads && out != null && out.pane == pane && out.loading) {
                    d.herdrOutput = out.copy(loading = false, error = "${d.identity.deviceName} did not answer")
                }
            }
        }, READ_TIMEOUT_MS, TimeUnit.MILLISECONDS)
    }

    /** Forgets the output and the last reply when the agent screen closes. */
    fun closeOutput(core: FluxCore, id: String, pane: String) {
        core.locked {
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

    /** Sends [text] to the agent in [pane]. The computer submits it as a prompt, or types it into a dialog. */
    fun sendPrompt(core: FluxCore, id: String, pane: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        if (t.toByteArray(Charsets.UTF_8).size > HERDR_MAX_PROMPT) {
            core.locked {
                val d = core.device(id) ?: return@locked
                d.herdrReply = HerdrReply(pane, "prompt", ++replies, sending = false, error = "The text is too long. The limit is 16 KB.")
            }
            return
        }
        reply(core, id, pane, "prompt", bodyOf("kind" to "prompt", "pane" to pane, "text" to t))
    }

    private fun reply(core: FluxCore, id: String, pane: String, action: String, body: JsonObject) {
        val token = core.locked {
            val d = core.device(id) ?: return@locked null
            val seq = ++replies
            d.herdrReply = HerdrReply(pane, action, seq)
            if (!d.send(Packet(Types.FLUX_HERDR, body))) {
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

package org.omarchy.flux.core

import org.omarchy.flux.net.Link
import org.omarchy.flux.protocol.Identity
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.verificationKey
import java.security.cert.X509Certificate
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** How long a pairing request from this phone waits for an answer. */
const val OUTGOING_TIMEOUT_SECONDS = 30L

/** How long an incoming pairing request stays open. */
const val INCOMING_TIMEOUT_SECONDS = 25L

/** The largest clock difference that a pairing request may have. */
private const val MAX_TIMESTAMP_DIFFERENCE_SECONDS = 1800L

/**
 * One remote device. The core holds one object per device ID. All fields
 * are guarded by the core lock.
 */
class Device(private val core: FluxCore, var identity: Identity) {
    val id: String get() = identity.deviceId
    var link: Link? = null
    var certificate: X509Certificate? = null
    var lastIp: String = ""

    var pairState = PairState.None
    var pairTimestamp = 0L
    var pairKey = ""
    private var pairTimer: ScheduledFuture<*>? = null

    var battery: Int? = null
    var charging = false
    var players: List<String> = emptyList()
    val playerStates = HashMap<String, PlayerState>()
    var currentPlayer: String? = null
    var commands: List<RemoteCommand> = emptyList()
    var commandsLoaded = false
    var keyboardAvailable = false

    val online: Boolean get() = link?.isOpen == true
    val paired: Boolean get() = pairState == PairState.Paired

    /**
     * Sends a packet. It returns false when the device is not paired or has
     * no open link. A peer that gets a plugin packet before pairing answers
     * with an unpair, so only pair packets go to an unpaired device.
     */
    fun send(p: Packet): Boolean {
        if (!paired && p.type != Types.PAIR) return false
        val l = link ?: return false
        if (!l.isOpen) return false
        l.send(p)
        return true
    }

    fun snapshot(): DeviceUi = DeviceUi(
        id = id,
        name = identity.deviceName,
        type = identity.deviceType,
        ip = link?.address?.hostAddress ?: lastIp,
        isFlux = identity.isFlux,
        paired = paired,
        online = online,
        pairState = pairState,
        pairKey = pairKey,
        pairOutgoing = pairState == PairState.Requested,
        battery = battery,
        charging = charging,
        players = players,
        player = currentPlayer?.let { playerStates[it] },
        commands = commands,
        commandsLoaded = commandsLoaded,
        keyboardAvailable = keyboardAvailable,
    )

    // ---------------------------------------------------------------- pairing

    /** Returns the key that a request with the timestamp shows, before it is sent. */
    fun previewKey(timestamp: Long): String {
        val peer = certificate ?: return ""
        return verificationKey(core.local.certificate, peer, if (identity.protocolVersion >= 8) timestamp else 0L)
    }

    /** Sends a pairing request with the timestamp that the dialog showed. */
    fun requestPair(timestamp: Long) {
        if (!online || paired) return
        pairTimestamp = timestamp
        pairState = PairState.Requested
        pairKey = computeKey()
        send(Packet(Types.PAIR, bodyOf("pair" to true, "timestamp" to pairTimestamp)))
        armTimer(OUTGOING_TIMEOUT_SECONDS)
    }

    /** The user accepted an incoming request. */
    fun acceptPair() {
        if (pairState != PairState.Incoming) return
        send(Packet(Types.PAIR, bodyOf("pair" to true)))
        pairingDone()
    }

    /** The user canceled a request or rejected an incoming request. */
    fun cancelPair() {
        if (pairState == PairState.Requested || pairState == PairState.Incoming) {
            send(Packet(Types.PAIR, bodyOf("pair" to false)))
            resetPair()
        }
    }

    fun unpair() {
        send(Packet(Types.PAIR, bodyOf("pair" to false)))
        core.trust.remove(id)
        resetPair()
    }

    /** Handles a kdeconnect.pair packet. */
    fun onPairPacket(p: Packet) {
        val wants = p.bool("pair") ?: false
        if (!wants) {
            val wasPaired = paired
            if (wasPaired) core.trust.remove(id)
            if (pairState == PairState.Requested) core.toast("${identity.deviceName} rejected the pairing")
            else if (wasPaired) core.toast("${identity.deviceName} unpaired this phone")
            resetPair()
            return
        }
        when (pairState) {
            PairState.Requested -> pairingDone()
            PairState.Incoming -> Unit
            PairState.Paired -> {
                // The peer lost the pairing, for example after a reinstall.
                // Forget the old trust and show the request again.
                core.trust.remove(id)
                pairState = PairState.None
                incoming(p)
            }
            PairState.None -> incoming(p)
        }
    }

    private fun incoming(p: Packet) {
        val ts = p.long("timestamp")
        val now = System.currentTimeMillis() / 1000
        if (identity.protocolVersion >= 8) {
            if (ts == null || abs(now - ts) > MAX_TIMESTAMP_DIFFERENCE_SECONDS) {
                send(Packet(Types.PAIR, bodyOf("pair" to false)))
                core.toast(if (ts == null) "Pairing refused: ${identity.deviceName} sent no timestamp" else "Pairing refused: the clock of ${identity.deviceName} is wrong")
                return
            }
        }
        pairTimestamp = ts ?: 0L
        pairKey = computeKey()
        pairState = PairState.Incoming
        armTimer(INCOMING_TIMEOUT_SECONDS)
        core.notifyPairRequest(this)
    }

    private fun pairingDone() {
        pairTimer?.cancel(false)
        val cert = certificate ?: return
        pairState = PairState.Paired
        core.trust.put(
            TrustedDevice(
                id = id,
                name = identity.deviceName,
                type = identity.deviceType,
                certificate = TrustStore.encode(cert),
                lastIp = link?.address?.hostAddress ?: "",
                isFlux = identity.isFlux,
            ),
        )
        core.toast("Paired with ${identity.deviceName}")
        core.onPaired(this)
    }

    private fun resetPair() {
        pairTimer?.cancel(false)
        pairState = PairState.None
        pairKey = ""
    }

    private fun armTimer(seconds: Long) {
        pairTimer?.cancel(false)
        pairTimer = core.scheduler.schedule({
            core.locked {
                if (pairState == PairState.Requested) {
                    send(Packet(Types.PAIR, bodyOf("pair" to false)))
                    core.toast("Pairing with ${identity.deviceName} timed out")
                }
                if (pairState == PairState.Requested || pairState == PairState.Incoming) resetPair()
            }
        }, seconds, TimeUnit.SECONDS)
    }

    private fun computeKey(): String {
        val peer = certificate ?: return ""
        val stamp = if (identity.protocolVersion >= 8) pairTimestamp else 0L
        return verificationKey(core.local.certificate, peer, stamp)
    }
}

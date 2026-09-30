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

    /** The current link. A new link gets the limits of the pair state. */
    var link: Link? = null
        set(value) {
            field = value
            value?.paired = paired
        }
    var certificate: X509Certificate? = null
    var lastIp: String = ""

    /** The pair state. The link reads long lines only while the device is paired. */
    var pairState = PairState.None
        set(value) {
            field = value
            link?.paired = value == PairState.Paired
        }
    var pairTimestamp = 0L
    var pairKey = ""
    private var pairTimer: ScheduledFuture<*>? = null

    /** The link on which the phone told the device that it is not paired. */
    private var refusedLink: Link? = null

    var battery: Int? = null
    var charging = false
    var players: List<String> = emptyList()
    val playerStates = HashMap<String, PlayerState>()
    var currentPlayer: String? = null
    var commands: List<RemoteCommand> = emptyList()
    var commandsLoaded = false

    /** The herdr agents of the computer, or null before the first agent list. */
    var herdr: HerdrState? = null
    /** The output of the pane on the agent screen, or null when no agent screen is open. */
    var herdrOutput: HerdrOutput? = null
    /** The last reply to an agent from the agent screen, or null when none is open. */
    var herdrReply: HerdrReply? = null
    /** The last new agent, new terminal, or close from this phone. */
    var herdrAction: HerdrAction? = null
    val herdrTracker = HerdrTracker()

    /** True when the computer accepts remote input, or null before it tells. */
    var remoteInput: Boolean? = null

    /** True when the computer shows its screen on this phone, or null before it tells. */
    var remoteDesktop: Boolean? = null

    /** The key bindings and workspaces of the computer, or null before the first answer. */
    var shortcuts: ShortcutsState? = null

    /**
     * The certificate from which [pairKey] came, while a pairing is open. A
     * new link must present it, and pairing pins it.
     */
    var pairCertificate: X509Certificate? = null
        private set

    /** The certificate from which the last [previewKey] came. */
    private var previewCertificate: X509Certificate? = null

    val online: Boolean get() = link?.isOpen == true
    val paired: Boolean get() = pairState == PairState.Paired

    /** True while a pairing request waits for an answer. */
    val pairing: Boolean get() = pairState == PairState.Requested || pairState == PairState.Incoming

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
        herdrSupported = Types.FLUX_HERDR in identity.incoming,
        herdr = herdr,
        herdrOutput = herdrOutput,
        herdrReply = herdrReply,
        herdrAction = herdrAction,
        inputSupported = Types.MOUSEPAD_REQUEST in identity.incoming,
        remoteInput = remoteInput,
        desktopSupported = Types.FLUX_DESKTOP in identity.incoming,
        remoteDesktop = remoteDesktop,
        shortcutsSupported = Types.FLUX_SHORTCUTS in identity.incoming,
        shortcuts = shortcuts,
    )

    // ---------------------------------------------------------------- pairing

    /** Returns the key that a request with the timestamp shows, before it is sent. */
    fun previewKey(timestamp: Long): String {
        val peer = certificate ?: return ""
        previewCertificate = peer
        return verificationKey(core.local.certificate, peer, timestamp)
    }

    /**
     * Sends a pairing request with the timestamp that the dialog showed. The
     * request uses the certificate of the key that the dialog showed. When a
     * new link brought another certificate, the request does not go out.
     */
    fun requestPair(timestamp: Long) {
        if (!online || paired) return
        val peer = certificate ?: return
        val shown = previewCertificate
        previewCertificate = null
        if (shown != null && !shown.encoded.contentEquals(peer.encoded)) {
            core.toast("${identity.deviceName} connected again with another certificate. Start the pairing again")
            return
        }
        pairTimestamp = timestamp
        pairCertificate = peer
        pairState = PairState.Requested
        pairKey = computeKey()
        send(Packet(Types.PAIR, bodyOf("pair" to true, "timestamp" to pairTimestamp)))
        armTimer(OUTGOING_TIMEOUT_SECONDS)
    }

    /** The user accepted an incoming request. */
    fun acceptPair() {
        if (pairState != PairState.Incoming) return
        // Check the certificate first, so the computer never gets pair true
        // and then pair false.
        val cert = pinnableCertificate() ?: return
        send(Packet(Types.PAIR, bodyOf("pair" to true)))
        pairingDone(cert)
    }

    /** The user canceled a request or rejected an incoming request. */
    fun cancelPair() {
        if (pairState == PairState.Requested || pairState == PairState.Incoming) {
            send(Packet(Types.PAIR, bodyOf("pair" to false)))
            resetPair()
        }
    }

    fun unpair() {
        val wasPaired = paired
        send(Packet(Types.PAIR, bodyOf("pair" to false)))
        refusedLink = link
        core.trust.remove(id)
        resetPair()
        if (wasPaired) core.revoke(this)
    }

    /** Handles a flux.pair packet from the current link. */
    fun onPairPacket(p: Packet) {
        val wants = p.bool("pair") ?: false
        if (!wants) {
            val wasPaired = paired
            if (wasPaired) core.trust.remove(id)
            if (pairState == PairState.Requested) core.toast("${identity.deviceName} rejected the pairing")
            else if (wasPaired) core.toast("${identity.deviceName} unpaired this phone")
            resetPair()
            if (wasPaired) core.revoke(this)
            return
        }
        when (pairState) {
            PairState.Requested -> pinnableCertificate()?.let { pairingDone(it) }
            PairState.Incoming -> Unit
            PairState.Paired -> {
                // The peer lost the pairing, for example after a reinstall.
                // Forget the old trust and show the request again.
                core.trust.remove(id)
                resetPair()
                core.revoke(this)
                incoming(p)
            }
            PairState.None -> incoming(p)
        }
    }

    private fun incoming(p: Packet) {
        val ts = p.long("timestamp")
        val now = System.currentTimeMillis() / 1000
        if (ts == null || abs(now - ts) > MAX_TIMESTAMP_DIFFERENCE_SECONDS) {
            send(Packet(Types.PAIR, bodyOf("pair" to false)))
            core.toast(if (ts == null) "Pairing refused: ${identity.deviceName} sent no timestamp" else "Pairing refused: the clock of ${identity.deviceName} is wrong")
            return
        }
        val peer = certificate ?: return
        pairTimestamp = ts
        pairCertificate = peer
        pairKey = computeKey()
        pairState = PairState.Incoming
        armTimer(INCOMING_TIMEOUT_SECONDS)
        core.notifyPairRequest(this)
    }

    /**
     * Returns the certificate from which the shown key came, when the current
     * link presents the same certificate. Else it refuses the pairing and
     * returns null.
     */
    private fun pinnableCertificate(): X509Certificate? {
        val cert = pairCertificate
        val current = link?.peerCertificate
        if (cert != null && current != null && cert.encoded.contentEquals(current.encoded)) return cert
        send(Packet(Types.PAIR, bodyOf("pair" to false)))
        core.toast("Pairing with ${identity.deviceName} failed: the certificate changed")
        resetPair()
        return null
    }

    /** Pins [cert], which [pinnableCertificate] checked. */
    private fun pairingDone(cert: X509Certificate) {
        pairTimer?.cancel(false)
        pairState = PairState.Paired
        pairCertificate = null
        core.trust.put(
            TrustedDevice(
                id = id,
                name = identity.deviceName,
                type = identity.deviceType,
                certificate = TrustStore.encode(cert),
                lastIp = link?.address?.hostAddress ?: "",
            ),
        )
        core.toast("Paired with ${identity.deviceName}")
        core.onPaired(this)
    }

    /** Ends an open pairing without a message, for example when its link closes. */
    fun dropPairing() {
        if (pairing) resetPair()
    }

    /**
     * Handles a packet other than a pair packet while the device is not
     * paired. Such a device still trusts this phone, for example after an
     * unpair on the phone while the computer was away. The phone answers
     * pair false once for each link, so that the device drops its trust and
     * the next link is unpaired on both sides. An open pairing gets no
     * answer, so that the answer does not end it.
     */
    fun refuseUnpaired() {
        val l = link ?: return
        if (!refusesUnpaired(paired, pairing, refused = refusedLink === l)) return
        refusedLink = l
        send(Packet(Types.PAIR, bodyOf("pair" to false)))
    }

    private fun resetPair() {
        pairTimer?.cancel(false)
        pairState = PairState.None
        pairKey = ""
        pairCertificate = null
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
        val peer = pairCertificate ?: return ""
        return verificationKey(core.local.certificate, peer, pairTimestamp)
    }
}

/**
 * Reports whether the phone answers pair false to a packet other than a
 * pair packet. Only a device that is not paired and has no open pairing
 * gets the answer. [refused] is true when the phone already sent pair false
 * on the link, as an answer or as an unpair.
 */
internal fun refusesUnpaired(paired: Boolean, pairing: Boolean, refused: Boolean): Boolean =
    !paired && !pairing && !refused

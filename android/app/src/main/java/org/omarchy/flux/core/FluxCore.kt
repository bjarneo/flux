package org.omarchy.flux.core

import android.annotation.SuppressLint
import android.content.Context
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import org.omarchy.flux.net.LanBackend
import org.omarchy.flux.net.Link
import org.omarchy.flux.protocol.Identity
import org.omarchy.flux.protocol.LocalCertificate
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import java.io.File
import java.net.InetAddress
import java.security.cert.X509Certificate
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

private const val TAG = "FluxCore"

/**
 * The most links of devices that are not paired. A new device closes the
 * link of the oldest one that has no open pairing.
 */
const val MAX_UNPAIRED_LINKS = 8

/**
 * The process-wide state of Flux: the certificate, the paired devices, the
 * live links, and the actions that the UI calls. All device state changes
 * happen inside [locked], which publishes a new [UiState] at the end.
 */
@SuppressLint("StaticFieldLeak")
object FluxCore {
    lateinit var app: Context
        private set
    lateinit var local: LocalCertificate
        private set
    lateinit var trust: TrustStore
        private set
    lateinit var settings: Settings
        private set

    val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { Thread(it, "flux-timer").apply { isDaemon = true } }
    val io = Executors.newCachedThreadPool { Thread(it, "flux-io").apply { isDaemon = true } }

    private val lock = Any()
    private val devices = LinkedHashMap<String, Device>()
    @Volatile private var backend: LanBackend? = null
    private var browse: BrowseState? = null
    private var scanning = false
    private var ringingFrom: String? = null
    private var initialized = false

    /** The time of the last connection attempt, for [inConnectGrace], or 0. */
    @Volatile private var connectFrom = 0L

    /** The publish at the end of the connect grace. The core lock guards it. */
    private var graceEnd: ScheduledFuture<*>? = null

    /**
     * True while an activity of the app is on screen. When the app comes to
     * the front, the phone sends its identity. A new computer then connects
     * and shows in the list at once, because the phone takes new devices now.
     */
    @Volatile var foreground = false
        set(value) {
            val cameToFront = value && !field
            field = value
            if (cameToFront) backend?.broadcast()
        }

    // The flags of the state that need calls to the system. publish() runs
    // for each packet, so it reads these copies. refreshWifi() and
    // refreshAccess() read the flags again when they can change.
    @Volatile private var onWifi = false
    @Volatile private var dndAccess = false
    @Volatile private var mediaAccess = false
    @Volatile private var notificationAccess = false
    @Volatile private var callAccess = false
    @Volatile private var smsAccess = false
    @Volatile private var smsSupported = false

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state
    private val _listenPort = MutableStateFlow(0)

    /** The TCP port of the link listener, or 0 while the network is off. */
    val listenPort: StateFlow<Int> = _listenPort
    private val _toasts = MutableSharedFlow<String>(extraBufferCapacity = 16)
    val toasts: SharedFlow<String> = _toasts
    private val _rediscovered = MutableSharedFlow<Unit>(extraBufferCapacity = 1)

    /**
     * Sends a value after each [rediscover]. The service then holds the
     * Wi-Fi multicast lock for a short time, so that a computer can find
     * the phone.
     */
    val rediscovered: SharedFlow<Unit> = _rediscovered
    private val _newPairing = MutableStateFlow<String?>(null)

    /**
     * The device ID of the last new pairing, until the UI takes it with
     * [takeNewPairing]. The Inbox then shows a short success state for that
     * computer. It waits while no UI shows.
     */
    val newPairing: StateFlow<String?> = _newPairing

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        app = context.applicationContext
        // The keys of the stream request notifications were in the memory of the last process.
        StreamRequests.removeStale(app)
        local = LocalCertificate.loadOrCreate(File(app.filesDir, "identity")) { e ->
            Log.e(TAG, "the identity of this phone did not load. Flux made a new one.", e)
            Android.createChannels(app)
            Android.showEvent(app, "Flux has a new identity", "The saved identity did not load. Pair this phone with your computers again.")
        }
        trust = TrustStore(app)
        settings = Settings(app)
        // The trust store holds only entries with a readable certificate.
        for (t in trust.all()) {
            val identity = Identity(t.id, t.name, t.type, 8, emptyList(), emptyList())
            val d = Device(this, identity)
            d.pairState = PairState.Paired
            d.lastIp = t.lastIp
            d.certificate = trust.certificate(t.id)
            devices[t.id] = d
        }
        // The saved computer themes draw at once. The system keeps the night
        // mode of the app, but a restore or a data clear can change the setting.
        ComputerThemes.load(settings) { it in devices }
        ComputerThemes.applyNightMode(app)
        smsSupported = SmsSync.supported(app)
        refreshWifi()
        refreshAccess()
        // The service starts the network after the first frame, so the paired computers show as connecting until then.
        if (settings.enabled) startConnectGrace()
        publish()
    }

    /**
     * Starts the time in which the paired computers that are not online show
     * as connecting, see [UiState.connecting]. At its end, the state
     * publishes again, so that the UI shows the computers that did not
     * connect.
     */
    private fun startConnectGrace() {
        connectFrom = SystemClock.elapsedRealtime()
        synchronized(lock) {
            graceEnd?.cancel(false)
            graceEnd = scheduler.schedule({ publish() }, CONNECT_GRACE_MS, TimeUnit.MILLISECONDS)
        }
    }

    /** Reads again whether the phone is on Wi-Fi. The network callback of the service calls it. */
    fun refreshWifi() {
        onWifi = Android.onWifi(app)
    }

    /**
     * Reads the permissions and the other accesses of the phone again. Call
     * it when they can change: when the app comes to the front, when the
     * system reports a change, and before a switch publishes.
     */
    fun refreshAccess() {
        dndAccess = DndSync.hasAccess(app)
        mediaAccess = CaptureWatch.hasAccess(app)
        notificationAccess = Android.hasNotificationAccess(app)
        callAccess = Android.hasPhoneState(app)
        smsAccess = SmsSync.hasAccess(app)
    }

    /** Reads all system flags again and publishes the state. */
    fun refresh() {
        refreshWifi()
        refreshAccess()
        publish()
    }

    val deviceName: String get() = Android.deviceName(app)

    /** The TLS context of the running backend, for payload transfers. */
    val tls: org.omarchy.flux.net.Tls? get() = backend?.tls

    fun identity(tcpPort: Int): Identity =
        Identity.self(local.deviceId, deviceName, tcpPort, sms = SmsSync.enabled(app), clipboardImages = settings.syncClipboard)

    /**
     * Sends the identity again to each connected computer. The SMS packet
     * types in it follow the Text messages switch, and a computer shows its
     * Messages page from them. The clipboard image type follows the Sync
     * clipboard switch.
     */
    fun sendIdentity() {
        val p = identity(0).toPacket()
        connectedPaired().forEach { it.send(p) }
    }

    // ---------------------------------------------------------------- network

    fun startNetwork() {
        if (backend != null) return
        startConnectGrace()
        lateinit var b: LanBackend
        b = LanBackend(local, ::identity, object : LanBackend.Callbacks {
            override fun trustedCertificate(deviceId: String): X509Certificate? = trust.certificate(deviceId)

            override fun hasLink(deviceId: String): Boolean = synchronized(lock) { devices[deviceId]?.online == true }

            override fun acceptsNewDevices(): Boolean = discoverable()

            override fun onLink(link: Link) = attach(link, b)

            override fun knownAddresses(): List<InetAddress> = trust.all()
                .mapNotNull { t -> t.lastIp.takeIf { it.isNotEmpty() }?.let { runCatching { InetAddress.getByName(it) }.getOrNull() } }
        })
        backend = b
        io.execute {
            b.start()
            if (backend === b) _listenPort.value = b.tcpPort
            locked { }
        }
    }

    fun stopNetwork() {
        backend?.stop()
        backend = null
        connectFrom = 0L
        _listenPort.value = 0
        // Close the links outside the lock: each close removes an unpaired
        // device from the map. A close can write to the network, so it does
        // not run on the main thread.
        val links = synchronized(lock) { devices.values.mapNotNull { it.link } }
        io.execute { links.forEach { it.close() } }
        publish()
    }

    /**
     * True while a new computer can connect: while the app is on screen, or
     * while the phone scans. A paired computer connects at any time.
     */
    private fun discoverable(): Boolean = foreground || synchronized(lock) { scanning }

    /**
     * Sends the identity again, for example after the Wi-Fi network changes
     * or after a tap on Retry. The paired computers that are not online then
     * show as connecting for [CONNECT_GRACE_MS].
     */
    fun rediscover() {
        val b = backend
        if (b != null) {
            startConnectGrace()
            b.broadcast()
            _rediscovered.tryEmit(Unit)
        }
        publish()
    }

    /**
     * Looks for computers on the network for a short time. The service sends
     * the identity and browses mDNS, then stops. Computers still find the
     * phone after the scan, through its mDNS announcement.
     */
    fun scan() = org.omarchy.flux.service.FluxService.start(app, org.omarchy.flux.service.FluxService.ACTION_SCAN)

    fun setScanning(on: Boolean) {
        synchronized(lock) { scanning = on }
        publish()
    }

    /** Sends the identity to one host, for example one that mDNS found. */
    fun announceTo(address: InetAddress) {
        backend?.announceTo(address)
    }

    private fun attach(link: Link, from: LanBackend) {
        locked {
            // A handshake that ends after Turn off gets no device.
            if (backend !== from) {
                link.close()
                return@locked
            }
            val id = link.identity.deviceId
            val existing = devices[id]
            val pinned = trust.get(id)?.let { trust.certificate(id) }
            val pairing = existing?.pairCertificate?.takeIf { existing.pairing }
            if (!linkAllowed(link.peerCertificate.encoded, trust.get(id) != null, pinned?.encoded, pairing?.encoded)) {
                Log.i(TAG, "refused a link for ${link.identity.deviceName}: another certificate")
                link.close()
                return@locked
            }
            if (existing == null && pinned == null && !makeRoomForNewDevice()) {
                Log.i(TAG, "refused a link from the new device ${link.identity.deviceName}")
                link.close()
                return@locked
            }
            val old = existing?.link
            // A pairing stays on the link on which it started, as in fluxd,
            // which ends the pairing when a new link comes.
            if (existing != null && endsPairing(existing.pairing, hasOldLink = old != null, sameLink = old === link)) {
                existing.dropPairing()
                toast("Pairing with ${link.identity.deviceName} stopped: the connection changed. Pair again")
            }
            val d = existing ?: Device(this, link.identity).also { devices[id] = it }
            d.identity = link.identity
            d.link = link
            // Set the new link first, so that closing the old link does not
            // mark the device offline.
            if (old != null && old !== link) old.close()
            d.certificate = link.peerCertificate
            d.lastIp = link.address.hostAddress ?: ""
            if (pinned != null) {
                d.pairState = PairState.Paired
                trust.update(id) { it.copy(name = link.identity.deviceName, lastIp = d.lastIp) }
            }
            link.start(
                onPacket = { p -> receive(d, link, p) },
                onClose = { detach(d, link) },
                idleClose = { idleClose(d, link) },
                // Only paired packets are that long, so the line counts as a packet from a device that still trusts the phone.
                onLongLine = { synchronized(lock) { if (d.link === link) d.refuseUnpaired() } },
            )
            if (d.paired) onConnected(d)
        }
    }

    /**
     * Makes room for the link of a new device that is not paired. It returns
     * false when the phone does not take new devices now, or when each
     * unpaired link has an open pairing. The core lock is held.
     */
    private fun makeRoomForNewDevice(): Boolean {
        if (!discoverable()) return false
        val unpaired = devices.values.filter { !it.paired && it.online }
        if (unpaired.size < MAX_UNPAIRED_LINKS) return true
        // The map keeps the order in which the devices came, so the first one is the oldest.
        val oldest = unpaired.firstOrNull { !it.pairing } ?: return false
        oldest.link?.close()
        return true
    }

    /**
     * True when an unpaired link that sent nothing for a while can close. It
     * runs on the read thread. While the app is on screen, the link stays,
     * so that the computer stays in the list of computers to pair.
     */
    private fun idleClose(d: Device, link: Link): Boolean =
        synchronized(lock) { d.link === link && !d.paired && !d.pairing && !discoverable() }

    /**
     * Handles 1 packet on the read thread of the link. Only the current link
     * of a device counts. The output of a herdr pane can have 1000 lines, so
     * its parse runs before the core lock, and only for a paired device.
     */
    private fun receive(d: Device, link: Link, p: Packet) {
        val paired = synchronized(lock) { d.link === link && d.paired }
        val output = herdrOutputOf(paired, p)
        locked {
            if (d.link !== link) return@locked
            if (output != null && d.paired) HerdrSync.onOutput(d, output) else dispatch(d, p)
        }
    }

    private fun detach(d: Device, link: Link) {
        locked {
            if (d.link !== link) return@locked
            d.link = null
            d.dropPairing()
            if (!d.paired) devices.remove(d.id)
        }
    }

    /**
     * Ends each session, stream, and request of a device that is no longer
     * paired. [Device] calls it under the core lock when either side
     * unpairs. The stops run on [io], because a stop can wait for a thread.
     * The fingerprint approval key stays. Only an unpair on this phone
     * deletes it.
     */
    fun revoke(d: Device) {
        val id = d.id
        val name = d.identity.deviceName
        d.herdrOutput = null
        d.herdrReply = null
        d.herdrAction = null
        // The computer can no longer dismiss, answer, or press a button on a phone notification.
        NotificationSync.forgetDevice(id)
        ComputerThemes.forget(this, id)
        val browsing = browse?.deviceId == id
        if (browsing) browse = null
        io.execute {
            val message = "$name is no longer paired"
            org.omarchy.flux.screen.ScreenSession.stopFor(id, message)
            org.omarchy.flux.webcam.WebcamSession.stopFor(this, id, message)
            org.omarchy.flux.mic.MicSession.stopFor(this, id, message)
            org.omarchy.flux.desktop.DesktopSession.stopFor(id, message)
            if (browsing) Browse.close()
            Approvals.current.value?.takeIf { it.computerId == id }?.let { Approvals.clear(app, it.id) }
            Android.cancelFromComputer(app, id)
            StreamRequests.forget(app, id)
        }
    }

    /** Runs the block under the core lock and publishes the new state. */
    fun <T> locked(block: () -> T): T {
        val r = synchronized(lock) { block() }
        publish()
        return r
    }

    fun publish() {
        val snapshot = synchronized(lock) {
            UiState(
                phoneName = deviceName,
                onWifi = onWifi,
                devices = devices.values.map { it.snapshot() } + DebugDemo.devices(),
                shareNotifications = settings.shareNotifications,
                syncClipboard = settings.syncClipboard,
                syncDnd = settings.syncDnd,
                dndAccess = dndAccess,
                sendScreenshots = settings.sendScreenshots,
                sendPhotos = settings.sendPhotos,
                mediaAccess = mediaAccess,
                notificationAccess = notificationAccess,
                callAlerts = settings.callAlerts,
                callAccess = callAccess,
                smsSync = settings.syncSms,
                smsAccess = smsAccess,
                smsSupported = smsSupported,
                agentInputAlerts = settings.agentInputAlerts,
                agentDoneAlerts = settings.agentDoneAlerts,
                ringingFrom = ringingFrom,
                browse = browse,
                listeningUdp = backend?.listeningUdp ?: true,
                scanning = scanning,
                connecting = inConnectGrace(connectFrom, SystemClock.elapsedRealtime()),
                enabled = settings.enabled,
                theme = settings.theme,
                computerTheme = ComputerThemes.current(),
                themeScope = ComputerThemes.scope,
                computerThemes = ComputerThemes.names(),
            )
        }
        _state.value = snapshot
    }

    fun toast(message: String) {
        _toasts.tryEmit(message)
    }

    fun device(id: String): Device? = synchronized(lock) { devices[id] }

    fun connectedPaired(): List<Device> = synchronized(lock) { devices.values.filter { it.paired && it.online } }

    /** True when the phone is paired with at least 1 computer, online or not. */
    fun hasPaired(): Boolean = synchronized(lock) { devices.values.any { it.paired } }

    // ---------------------------------------------------------------- events

    /** Handles one packet from a device. The core lock is held. */
    fun dispatch(d: Device, p: Packet) {
        if (p.type == Types.PAIR) {
            d.onPairPacket(p)
            return
        }
        if (!d.paired) {
            Log.d(TAG, "ignored ${p.type} from unpaired ${d.identity.deviceName}")
            d.refuseUnpaired()
            return
        }
        Plugins.handle(this, d, p)
    }

    fun onPaired(d: Device) {
        notePairing(d.id)
        onConnected(d)
    }

    /** Records a new pairing for the UI. [onPaired] calls it. Debug builds call it for a sample computer. */
    fun notePairing(id: String) {
        _newPairing.value = id
    }

    /** Clears the new pairing [id] after the UI showed it. A newer pairing stays. */
    fun takeNewPairing(id: String) {
        _newPairing.compareAndSet(id, null)
    }

    /** Sends the packets that a paired device expects after it connects. */
    private fun onConnected(d: Device) {
        Plugins.onConnected(this, d)
    }

    fun notifyPairRequest(d: Device) {
        if (!foreground) Android.showPairNotification(app, d.identity.deviceName, d.pairKey)
    }

    fun setBrowse(state: BrowseState?) {
        synchronized(lock) { browse = state }
        publish()
    }

    fun browseState(): BrowseState? = synchronized(lock) { browse }

    fun setRinging(from: String?) {
        synchronized(lock) { ringingFrom = from }
        publish()
    }

    // ---------------------------------------------------------------- actions

    fun previewKey(id: String, timestamp: Long): String = synchronized(lock) { device(id)?.previewKey(timestamp) ?: "" }
    fun pair(id: String, timestamp: Long) = locked { device(id)?.requestPair(timestamp) }
    fun acceptPair(id: String) = locked { device(id)?.acceptPair() }
    fun cancelPair(id: String) = locked { device(id)?.cancelPair() }
    fun unpair(id: String) = locked {
        val d = device(id) ?: return@locked
        d.unpair()
        if (!d.online) devices.remove(id)
    }

    fun setShareNotifications(on: Boolean) {
        settings.shareNotifications = on
        refreshAccess()
        publish()
    }

    /** True unless the user turned Flux off. Call [init] first. */
    val enabled: Boolean get() = settings.enabled

    /**
     * Turns Flux on or off. Off stops the service, which closes every link,
     * stops discovery, and removes the notification. Flux stays off after a
     * restart of the phone, until the user turns it on.
     */
    fun setEnabled(on: Boolean) {
        settings.enabled = on
        publish()
        if (on) {
            org.omarchy.flux.service.FluxService.start(app)
        } else {
            org.omarchy.flux.screen.ScreenSession.stop()
            app.stopService(android.content.Intent(app, org.omarchy.flux.service.FluxService::class.java))
        }
    }

    fun setTheme(mode: ThemeMode) {
        settings.theme = mode
        ComputerThemes.applyNightMode(app)
        publish()
    }

    fun setSyncClipboard(on: Boolean) {
        settings.syncClipboard = on
        sendIdentity()
        publish()
    }

    fun setCallAlerts(on: Boolean) {
        settings.callAlerts = on
        refreshAccess()
        publish()
    }

    fun setSyncSms(on: Boolean) {
        settings.syncSms = on
        refreshAccess()
        publish()
    }

    fun setSyncDnd(on: Boolean) {
        settings.syncDnd = on
        refreshAccess()
        publish()
    }

    fun setAgentInputAlerts(on: Boolean) {
        settings.agentInputAlerts = on
        publish()
    }

    fun setAgentDoneAlerts(on: Boolean) {
        settings.agentDoneAlerts = on
        publish()
    }

    /** Turns on or off the sending of new images of [kind]. */
    fun setSendCaptures(kind: CaptureKind, on: Boolean) {
        when (kind) {
            CaptureKind.Screenshot -> settings.sendScreenshots = on
            CaptureKind.Photo -> settings.sendPhotos = on
        }
        CaptureWatch.setKind(app, kind, on)
        CaptureWatch.refresh(app)
        refreshAccess()
        publish()
    }
}

/**
 * Reports whether a new link for a device ID can take the place of the
 * current link. A device with a trust entry must present the pinned
 * certificate: [trusted] is true when the entry exists, and [pinned] is its
 * certificate, or null when it does not parse. A device with an open
 * pairing must present [pairing], the certificate from which the key came.
 * Otherwise any certificate can replace the link, so that a device that is
 * not paired cannot keep the device ID from another one.
 */
internal fun linkAllowed(cert: ByteArray, trusted: Boolean, pinned: ByteArray?, pairing: ByteArray?): Boolean = when {
    trusted -> pinned != null && pinned.contentEquals(cert)
    pairing != null -> pairing.contentEquals(cert)
    else -> true
}

/**
 * Reports whether a new link of a device ends its open pairing. A pairing
 * stays on the link on which it started, as in fluxd. [hasOldLink] is true
 * when the device has a link, and [sameLink] is true when the new link is
 * that link.
 */
internal fun endsPairing(pairing: Boolean, hasOldLink: Boolean, sameLink: Boolean): Boolean =
    pairing && hasOldLink && !sameLink

/**
 * Parses the output of a herdr pane before the core lock. Only a paired
 * device gets the parse, so that a device that is not paired cannot make
 * the phone do the work. It returns null for another packet.
 */
internal fun herdrOutputOf(paired: Boolean, p: Packet): HerdrOutput? =
    if (paired && p.type == Types.FLUX_HERDR) parseHerdrOutput(p.body) else null

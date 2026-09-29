package org.omarchy.flux.core

import android.annotation.SuppressLint
import android.content.Context
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

private const val TAG = "FluxCore"

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
    private var backend: LanBackend? = null
    private var browse: BrowseState? = null
    private var scanning = false
    private var ringingFrom: String? = null
    private var initialized = false

    /** True while an activity of the app is on screen. */
    @Volatile var foreground = false

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

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        app = context.applicationContext
        local = LocalCertificate.loadOrCreate(File(app.filesDir, "identity"))
        trust = TrustStore(app)
        settings = Settings(app)
        // The system keeps the night mode of the app, but a restore or a data clear can change the setting.
        Android.setNightMode(app, settings.theme)
        for (t in trust.all()) {
            val identity = Identity(t.id, t.name, t.type, 8, if (t.isFlux) listOf(Types.FLUX_TUNNEL) else emptyList(), emptyList())
            val d = Device(this, identity)
            d.pairState = PairState.Paired
            d.lastIp = t.lastIp
            d.certificate = runCatching { t.cert() }.getOrNull()
            devices[t.id] = d
        }
        smsSupported = SmsSync.supported(app)
        refreshWifi()
        refreshAccess()
        publish()
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
        val b = LanBackend(local, ::identity, object : LanBackend.Callbacks {
            override fun trustedCertificate(deviceId: String): X509Certificate? =
                trust.get(deviceId)?.let { runCatching { it.cert() }.getOrNull() }

            override fun hasLink(deviceId: String): Boolean = synchronized(lock) { devices[deviceId]?.online == true }

            override fun onLink(link: Link) = attach(link)

            override fun knownAddresses(): List<InetAddress> = trust.all()
                .mapNotNull { t -> t.lastIp.takeIf { it.isNotEmpty() }?.let { runCatching { InetAddress.getByName(it) }.getOrNull() } }
        })
        backend = b
        io.execute {
            b.start()
            _listenPort.value = b.tcpPort
            locked { }
        }
    }

    fun stopNetwork() {
        backend?.stop()
        backend = null
        _listenPort.value = 0
        locked { devices.values.forEach { it.link?.close() } }
    }

    /** Sends the identity again, for example after the Wi-Fi network changes. */
    fun rediscover() {
        backend?.broadcast()
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

    private fun attach(link: Link) {
        locked {
            val id = link.identity.deviceId
            val existing = devices[id]
            val old = existing?.link
            if (old != null && old.isOpen && old !== link && !old.peerCertificate.encoded.contentEquals(link.peerCertificate.encoded)) {
                // Only the same certificate may replace a live link.
                link.close()
                return@locked
            }
            val d = existing ?: Device(this, link.identity).also { devices[id] = it }
            d.identity = link.identity
            d.link = link
            // Set the new link first, so that closing the old link does not
            // mark the device offline.
            if (old != null && old !== link) old.close()
            d.certificate = link.peerCertificate
            d.lastIp = link.address.hostAddress ?: ""
            if (trust.get(id) != null) {
                d.pairState = PairState.Paired
                trust.update(id) { it.copy(name = link.identity.deviceName, lastIp = d.lastIp, isFlux = link.identity.isFlux) }
            }
            link.start(onPacket = { p -> receive(d, p) }, onClose = { detach(d, link) })
            if (d.paired) onConnected(d)
        }
    }

    /**
     * Handles 1 packet on the read thread of the link. The output of a herdr
     * pane can have 1000 lines, so its parse runs before the core lock.
     */
    private fun receive(d: Device, p: Packet) {
        val output = if (p.type == Types.FLUX_HERDR) parseHerdrOutput(p.body) else null
        locked {
            if (output != null && d.paired) HerdrSync.onOutput(d, output) else dispatch(d, p)
        }
    }

    private fun detach(d: Device, link: Link) {
        locked {
            if (d.link !== link) return@locked
            d.link = null
            if (d.pairState == PairState.Requested || d.pairState == PairState.Incoming) d.pairState = PairState.None
            if (!d.paired) devices.remove(d.id)
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
                enabled = settings.enabled,
                theme = settings.theme,
            )
        }
        _state.value = snapshot
    }

    fun toast(message: String) {
        _toasts.tryEmit(message)
    }

    fun device(id: String): Device? = synchronized(lock) { devices[id] }

    fun connectedPaired(): List<Device> = synchronized(lock) { devices.values.filter { it.paired && it.online } }

    // ---------------------------------------------------------------- events

    /** Handles one packet from a device. The core lock is held. */
    fun dispatch(d: Device, p: Packet) {
        if (p.type == Types.PAIR) {
            d.onPairPacket(p)
            return
        }
        if (!d.paired) {
            Log.d(TAG, "ignored ${p.type} from unpaired ${d.identity.deviceName}")
            return
        }
        Plugins.handle(this, d, p)
    }

    fun onPaired(d: Device) {
        onConnected(d)
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
        Android.setNightMode(app, mode)
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

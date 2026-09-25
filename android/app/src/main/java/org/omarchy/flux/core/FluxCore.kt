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
    private var ringingFrom: String? = null
    private var initialized = false

    /** True while an activity of the app is on screen. */
    @Volatile var foreground = false

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
        for (t in trust.all()) {
            val identity = Identity(t.id, t.name, t.type, 8, if (t.isFlux) listOf(Types.FLUX_TUNNEL) else emptyList(), emptyList())
            val d = Device(this, identity)
            d.pairState = PairState.Paired
            d.lastIp = t.lastIp
            d.certificate = runCatching { t.cert() }.getOrNull()
            devices[t.id] = d
        }
        publish()
    }

    val deviceName: String get() = Android.deviceName(app)

    /** The TLS context of the running backend, for payload transfers. */
    val tls: org.omarchy.flux.net.Tls? get() = backend?.tls

    fun identity(tcpPort: Int): Identity = Identity.self(local.deviceId, deviceName, tcpPort)

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
            link.start(onPacket = { p -> locked { dispatch(d, p) } }, onClose = { detach(d, link) })
            if (d.paired) onConnected(d)
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
                onWifi = Android.onWifi(app),
                devices = devices.values.map { it.snapshot() },
                shareNotifications = settings.shareNotifications,
                syncClipboard = settings.syncClipboard,
                notificationAccess = Android.hasNotificationAccess(app),
                ringingFrom = ringingFrom,
                browse = browse,
                listeningUdp = backend?.listeningUdp ?: true,
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
        publish()
    }

    fun setSyncClipboard(on: Boolean) {
        settings.syncClipboard = on
        publish()
    }
}

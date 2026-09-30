package org.omarchy.flux.net

import android.util.Log
import org.omarchy.flux.protocol.Identity
import org.omarchy.flux.protocol.LocalCertificate
import org.omarchy.flux.protocol.MAX_IDENTITY_LINE
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.commonName
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket

private const val TAG = "FluxLan"

/** The UDP port for identity broadcasts. */
const val UDP_PORT = 1716

/** The TCP port range for links. */
val TCP_PORTS = 1716..1764

/**
 * The time for the plain identity, the TLS handshake, and the identity after
 * TLS together. A peer that is slower loses its connection.
 */
private const val HANDSHAKE_MS = 10_000L

/** The most handshakes at a time. More connections close at once. */
private const val MAX_HANDSHAKES = 16

/** The most handshakes of incoming connections at a time from one address. */
private const val MAX_HANDSHAKES_PER_SOURCE = 4

/** The most connects at a time that UDP identities start. */
private const val MAX_UDP_CONNECTS = 4

/** The shortest time between 2 connects that UDP identities start, for one device ID or one address. */
private const val UDP_CONNECT_GAP_MS = 1_000L

/** The most entries in each map of the last connects. Older entries go first. */
private const val MAX_ATTEMPTS = 256

/** How long a listen loop waits after an error before it tries again. */
private const val RETRY_MS = 500L

/**
 * The LAN backend. It broadcasts the identity over UDP, accepts
 * TCP links, connects to devices that broadcast, and runs the TLS handshake.
 * The work before a device is known runs on small pools with a deadline,
 * so that a flood of connections cannot use up the threads of the app.
 */
class LanBackend(
    private val local: LocalCertificate,
    private val identity: (tcpPort: Int) -> Identity,
    private val callbacks: Callbacks,
) {
    interface Callbacks {
        /** Returns the pinned certificate of a trusted device, or null. */
        fun trustedCertificate(deviceId: String): X509Certificate?

        /** Reports whether a live link to the device exists. */
        fun hasLink(deviceId: String): Boolean

        /** Reports whether the phone takes a link from a device that is not paired now. */
        fun acceptsNewDevices(): Boolean

        /** Receives a new link after TLS and the identity check. */
        fun onLink(link: Link)

        /** Returns the addresses of trusted devices to contact directly. */
        fun knownAddresses(): List<InetAddress>
    }

    val tls = Tls(local)
    var tcpPort = 0
        private set

    /** True when this app owns UDP 1716 and hears broadcasts. */
    var listeningUdp = false
        private set

    /** Runs the handshakes of incoming connections. A full pool closes a new connection. */
    private val handshakes = ThreadPoolExecutor(0, MAX_HANDSHAKES, 30, TimeUnit.SECONDS, SynchronousQueue()) {
        Thread(it, "flux-lan").apply { isDaemon = true }
    }

    /**
     * Runs the connects that UDP identities start. A full pool skips a new
     * connect. A UDP identity can come from a forged address that does not
     * answer, so these connects take no slot of [handshakes] and no slot of
     * an address in [perSource].
     */
    private val udpConnects = ThreadPoolExecutor(0, MAX_UDP_CONNECTS, 30, TimeUnit.SECONDS, SynchronousQueue()) {
        Thread(it, "flux-lan-connect").apply { isDaemon = true }
    }

    /** Sends the identity over UDP, apart from the handshakes, so that a flood cannot delay it. */
    private val announcer = Executors.newSingleThreadExecutor { Thread(it, "flux-announce").apply { isDaemon = true } }

    /** Closes the sockets of handshakes that pass [HANDSHAKE_MS]. */
    private val deadlines = Executors.newSingleThreadScheduledExecutor { Thread(it, "flux-lan-timer").apply { isDaemon = true } }

    private var server: ServerSocket? = null
    private var udp: DatagramSocket? = null

    /** The sockets of the handshakes that run, so that [stop] can close them. */
    private val pending = ConcurrentHashMap.newKeySet<Socket>()

    /** The number of handshakes of incoming connections that run for each address. */
    private val perSource = ConcurrentHashMap<InetAddress, Int>()
    @Volatile private var running = false

    /** True after [stop]. A stopped backend does not start again, and it gives no more links. */
    @Volatile private var stopped = false

    @Synchronized
    fun start() {
        if (running || stopped) return
        running = true
        val srv = openServer()
        server = srv
        tcpPort = srv?.localPort ?: 0
        val u = openUdp()
        udp = u
        if (srv != null) Thread({ acceptLoop(srv) }, "flux-accept").apply { isDaemon = true }.start()
        if (listeningUdp && u != null) Thread({ udpLoop(u) }, "flux-udp").apply { isDaemon = true }.start()
        broadcast()
    }

    /** Stops the listeners and the handshakes that run. The backend does not start again. */
    @Synchronized
    fun stop() {
        stopped = true
        running = false
        runCatching { server?.close() }
        runCatching { udp?.close() }
        server = null
        udp = null
        pending.forEach { runCatching { it.close() } }
        handshakes.shutdown()
        udpConnects.shutdown()
        announcer.shutdown()
        deadlines.shutdown()
    }

    private fun openServer(): ServerSocket? {
        for (port in TCP_PORTS) {
            try {
                return ServerSocket().apply {
                    reuseAddress = true
                    bind(InetSocketAddress(port))
                }
            } catch (_: Exception) {
            }
        }
        Log.e(TAG, "no free TCP port in $TCP_PORTS")
        return null
    }

    private fun openUdp(): DatagramSocket? {
        try {
            val s = DatagramSocket(null)
            s.reuseAddress = true
            s.broadcast = true
            s.bind(InetSocketAddress(UDP_PORT))
            listeningUdp = true
            return s
        } catch (e: Exception) {
            Log.w(TAG, "UDP $UDP_PORT is in use: ${e.message}. Flux only announces itself.")
        }
        listeningUdp = false
        return runCatching { DatagramSocket().apply { broadcast = true } }.getOrNull()
    }

    /**
     * Sends the identity to every broadcast address and to the known devices
     * that the phone can reach now: on a network of the phone, or through
     * Tailscale. A stored address on another network can belong to a stranger.
     */
    fun broadcast() {
        announce {
            val data = identity(tcpPort).toPacket(withPort = true).serialize().toByteArray()
            val nets = interfaceAddresses()
            val targets = LinkedHashSet<InetAddress>()
            targets += InetAddress.getByName("255.255.255.255")
            targets += nets.filter { it.address is Inet4Address }.mapNotNull { it.broadcast }
            targets += callbacks.knownAddresses().filter { a ->
                isTailscale(a) || nets.any { samePrefix(a, it.address, it.networkPrefixLength.toInt()) }
            }
            val socket = udp ?: return@announce
            for (t in targets) {
                runCatching { socket.send(DatagramPacket(data, data.size, t, UDP_PORT)) }
                    .onFailure { Log.d(TAG, "UDP send to $t failed: ${it.message}") }
            }
        }
    }

    /** Sends the identity to one address, for example a host that mDNS found. */
    fun announceTo(address: InetAddress) {
        announce {
            val data = identity(tcpPort).toPacket(withPort = true).serialize().toByteArray()
            runCatching { udp?.send(DatagramPacket(data, data.size, address, UDP_PORT)) }
        }
    }

    private fun announce(work: () -> Unit) {
        if (!running || tcpPort == 0) return
        runCatching { announcer.execute { runCatching(work) } }
    }

    private fun interfaceAddresses(): List<InterfaceAddress> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.interfaceAddresses }
    }.getOrDefault(emptyList())

    private fun udpLoop(socket: DatagramSocket) {
        val buf = ByteArray(64 * 1024)
        val byDevice = HashMap<String, Long>()
        val bySource = HashMap<InetAddress, Long>()
        while (running) {
            try {
                val dp = DatagramPacket(buf, buf.size)
                socket.receive(dp)
                onDatagram(dp, byDevice, bySource)
            } catch (e: Throwable) {
                if (!running || socket.isClosed) return
                Log.w(TAG, "UDP receive failed: $e")
                pause()
            }
        }
    }

    /**
     * Connects to a device that sent its identity over UDP. The connect goes
     * only to a port of the link range, at most once a second for each
     * device ID and each address, and at most [MAX_UDP_CONNECTS] run at a
     * time. A device that is not paired gets a connect only while the phone
     * takes new devices.
     */
    private fun onDatagram(dp: DatagramPacket, byDevice: HashMap<String, Long>, bySource: HashMap<InetAddress, Long>) {
        val line = String(dp.data, dp.offset, dp.length, Charsets.UTF_8)
        val id = Packet.parse(line)?.let { Identity.from(it) } ?: return
        if (id.deviceId == local.deviceId || id.tcpPort !in TCP_PORTS) return
        val address = dp.address ?: return
        if (address.isMulticastAddress || address.isAnyLocalAddress) return
        if (callbacks.hasLink(id.deviceId)) return
        if (callbacks.trustedCertificate(id.deviceId) == null && !callbacks.acceptsNewDevices()) return
        val now = System.nanoTime() / 1_000_000
        prune(byDevice, now)
        prune(bySource, now)
        if (now - (byDevice[id.deviceId] ?: Long.MIN_VALUE / 2) < UDP_CONNECT_GAP_MS) return
        if (now - (bySource[address] ?: Long.MIN_VALUE / 2) < UDP_CONNECT_GAP_MS) return
        byDevice[id.deviceId] = now
        bySource[address] = now
        submit(udpConnects, null, address, slot = false) { connect(address, id.tcpPort, id) }
    }

    /** Keeps a map of the last connects small. */
    private fun <K> prune(map: HashMap<K, Long>, now: Long) {
        if (map.size < MAX_ATTEMPTS) return
        map.entries.removeIf { now - it.value >= UDP_CONNECT_GAP_MS }
        if (map.size >= MAX_ATTEMPTS) map.clear()
    }

    private fun acceptLoop(server: ServerSocket) {
        while (running) {
            val socket = try {
                server.accept()
            } catch (e: Throwable) {
                if (!running || server.isClosed) return
                // For example, the app has no free file descriptor. Try again soon.
                Log.w(TAG, "accept failed: $e")
                pause()
                continue
            }
            val source = socket.inetAddress
            if (!reserve(source)) {
                runCatching { socket.close() }
                continue
            }
            submit(handshakes, socket, source, slot = true) { handleIncoming(socket) }
        }
    }

    private fun pause() {
        try {
            Thread.sleep(RETRY_MS)
        } catch (_: InterruptedException) {
        }
    }

    /** Counts a handshake of an incoming connection for [source]. It returns false when the address has too many. */
    private fun reserve(source: InetAddress): Boolean {
        var ok = false
        perSource.compute(source) { _, n ->
            val count = n ?: 0
            ok = count < MAX_HANDSHAKES_PER_SOURCE
            if (ok) count + 1 else count
        }
        return ok
    }

    private fun release(source: InetAddress) {
        perSource.compute(source) { _, n -> if (n == null || n <= 1) null else n - 1 }
    }

    /**
     * Runs a handshake on [pool]. When the pool is full, or when no thread
     * can start, the socket closes and the loop goes on. With [slot], the
     * handshake holds a slot of [reserve] for [source] and gives it back at
     * the end.
     */
    private fun submit(pool: ThreadPoolExecutor, socket: Socket?, source: InetAddress, slot: Boolean, work: () -> Unit) {
        try {
            pool.execute {
                try {
                    work()
                } catch (e: Throwable) {
                    Log.i(TAG, "handshake with $source failed: $e")
                } finally {
                    if (slot) release(source)
                }
            }
        } catch (e: Throwable) {
            if (slot) release(source)
            runCatching { socket?.close() }
        }
    }

    /** Closes [socket] when the handshake passes [HANDSHAKE_MS]. [finish] cancels it. */
    private fun deadline(socket: Socket): ScheduledFuture<*> {
        pending += socket
        return deadlines.schedule({ runCatching { socket.close() } }, HANDSHAKE_MS, TimeUnit.MILLISECONDS)
    }

    /**
     * Handles a TCP connection that a device opened. The device sends its
     * identity in plain text. This side is then the TLS client.
     */
    private fun handleIncoming(socket: Socket) {
        var timer: ScheduledFuture<*>? = null
        try {
            timer = deadline(socket)
            keepAlive(socket)
            socket.soTimeout = HANDSHAKE_MS.toInt()
            val line = readLine(socket.getInputStream(), MAX_IDENTITY_LINE) ?: throw SocketTimeoutException("no identity")
            val packet = Packet.parse(line) ?: throw IllegalStateException("bad identity")
            val plain = Identity.from(packet) ?: throw IllegalStateException("bad identity")
            if (plain.deviceId == local.deviceId) {
                socket.close(); return
            }
            // A device that answers a broadcast names the device it wants.
            val target = packet.string("targetDeviceId")
            if (target != null && target != local.deviceId) throw IllegalStateException("identity is for $target")
            // A device that is not paired connects only while the phone takes
            // new devices, so the phone skips the TLS work for it at other times.
            if (callbacks.trustedCertificate(plain.deviceId) == null && !callbacks.hasLink(plain.deviceId) && !callbacks.acceptsNewDevices()) {
                throw IllegalStateException("the phone takes no new devices now")
            }
            val ssl = tls.wrap(socket, server = false)
            finish(ssl, plain, timer)
        } catch (e: Throwable) {
            Log.i(TAG, "incoming link from ${socket.inetAddress} failed: $e")
            runCatching { socket.close() }
        } finally {
            timer?.cancel(false)
            pending -= socket
        }
    }

    /**
     * Connects to a device that sent its identity over UDP. This side sends
     * its identity in plain text and is then the TLS server.
     */
    private fun connect(address: InetAddress, port: Int, udpIdentity: Identity) {
        val socket = Socket()
        var timer: ScheduledFuture<*>? = null
        try {
            timer = deadline(socket)
            socket.connect(InetSocketAddress(address, port), HANDSHAKE_MS.toInt())
            keepAlive(socket)
            socket.soTimeout = HANDSHAKE_MS.toInt()
            val out = socket.getOutputStream()
            out.write(identity(0).toPacket(target = udpIdentity).serialize().toByteArray())
            out.flush()
            val ssl = tls.wrap(socket, server = true)
            finish(ssl, udpIdentity, timer)
        } catch (e: Throwable) {
            Log.i(TAG, "link to $address:$port failed: $e")
            runCatching { socket.close() }
        } finally {
            timer?.cancel(false)
            pending -= socket
        }
    }

    /**
     * Checks the peer certificate and exchanges the identity again over
     * TLS. The identity inside TLS is the one to trust. A device with a
     * trust entry must present the pinned certificate.
     */
    private fun finish(ssl: SSLSocket, plain: Identity?, timer: ScheduledFuture<*>) {
        val cert = Tls.peerCertificate(ssl) ?: throw IllegalStateException("peer sent no certificate")
        val cn = commonName(cert)
        // Both sides write the identity at once, so that neither side
        // waits for the other.
        val out = ssl.outputStream
        out.write(identity(0).toPacket().serialize().toByteArray())
        out.flush()
        ssl.soTimeout = HANDSHAKE_MS.toInt()
        val line = readLine(ssl.inputStream, MAX_IDENTITY_LINE) ?: throw SocketTimeoutException("no identity after TLS")
        ssl.soTimeout = 0
        val identity = Packet.parse(line)?.let { Identity.from(it) } ?: throw IllegalStateException("bad identity after TLS")
        if (plain != null && plain.deviceId != identity.deviceId) throw IllegalStateException("device ID changed after TLS")
        if (plain != null && plain.protocolVersion != identity.protocolVersion) throw IllegalStateException("protocol version changed after TLS")
        if (cn != identity.deviceId) throw IllegalStateException("certificate CN $cn does not match ${identity.deviceId}")
        val pinned = callbacks.trustedCertificate(identity.deviceId)
        if (pinned != null && !pinned.encoded.contentEquals(cert.encoded)) {
            throw IllegalStateException("${identity.deviceName} presented a different certificate")
        }
        // The deadline closed the socket when cancel fails.
        if (!timer.cancel(false)) throw SocketTimeoutException("the handshake took too long")
        if (stopped) throw IllegalStateException("Flux is off")
        callbacks.onLink(Link(ssl, identity, cert))
    }
}

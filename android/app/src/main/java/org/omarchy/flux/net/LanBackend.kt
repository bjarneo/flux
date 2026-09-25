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
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import javax.net.ssl.SSLSocket

private const val TAG = "FluxLan"

/** The UDP port for identity broadcasts. */
const val UDP_PORT = 1716

/** The TCP port range for links. */
val TCP_PORTS = 1716..1764

/**
 * The KDE Connect LAN backend. It broadcasts the identity over UDP, accepts
 * TCP links, connects to devices that broadcast, and runs the TLS handshake.
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

    private val pool = Executors.newCachedThreadPool { Thread(it, "flux-lan").apply { isDaemon = true } }
    private var server: ServerSocket? = null
    private var udp: DatagramSocket? = null
    private val lastAttempt = ConcurrentHashMap<String, Long>()
    @Volatile private var running = false

    fun start() {
        if (running) return
        running = true
        server = openServer()
        tcpPort = server?.localPort ?: 0
        udp = openUdp()
        pool.execute { acceptLoop() }
        if (listeningUdp) pool.execute { udpLoop() }
        broadcast()
    }

    fun stop() {
        running = false
        runCatching { server?.close() }
        runCatching { udp?.close() }
        server = null
        udp = null
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

    /** Sends the identity to every broadcast address and to known devices. */
    fun broadcast() {
        if (!running || tcpPort == 0) return
        pool.execute {
            val data = identity(tcpPort).toPacket(withPort = true).serialize().toByteArray()
            val targets = LinkedHashSet<InetAddress>()
            targets += InetAddress.getByName("255.255.255.255")
            targets += broadcastAddresses()
            targets += callbacks.knownAddresses()
            val socket = udp ?: return@execute
            for (t in targets) {
                runCatching { socket.send(DatagramPacket(data, data.size, t, UDP_PORT)) }
                    .onFailure { Log.d(TAG, "UDP send to $t failed: ${it.message}") }
            }
        }
    }

    /** Sends the identity to one address, for example a host that mDNS found. */
    fun announceTo(address: InetAddress) {
        if (!running || tcpPort == 0) return
        pool.execute {
            val data = identity(tcpPort).toPacket(withPort = true).serialize().toByteArray()
            runCatching { udp?.send(DatagramPacket(data, data.size, address, UDP_PORT)) }
        }
    }

    private fun broadcastAddresses(): List<InetAddress> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.interfaceAddresses }
            .filter { it.address is Inet4Address }
            .mapNotNull { it.broadcast }
    }.getOrDefault(emptyList())

    private fun udpLoop() {
        val buf = ByteArray(64 * 1024)
        while (running) {
            val socket = udp ?: return
            val dp = DatagramPacket(buf, buf.size)
            try {
                socket.receive(dp)
            } catch (e: Exception) {
                if (running) Log.w(TAG, "UDP receive failed: ${e.message}")
                return
            }
            val line = String(dp.data, dp.offset, dp.length, Charsets.UTF_8)
            val id = Packet.parse(line)?.let { Identity.from(it) } ?: continue
            if (id.deviceId == local.deviceId || id.tcpPort <= 0) continue
            if (callbacks.hasLink(id.deviceId)) continue
            val now = System.currentTimeMillis()
            val last = lastAttempt[id.deviceId] ?: 0
            if (now - last < 1_000) continue
            lastAttempt[id.deviceId] = now
            val address = dp.address
            pool.execute { connect(address, id.tcpPort, id) }
        }
    }

    private fun acceptLoop() {
        while (running) {
            val s = server ?: return
            val socket = try {
                s.accept()
            } catch (e: Exception) {
                if (running) Log.w(TAG, "accept failed: ${e.message}")
                return
            }
            pool.execute { handleIncoming(socket) }
        }
    }

    /**
     * Handles a TCP connection that a device opened. The device sends its
     * identity in plain text. This side is then the TLS client.
     */
    private fun handleIncoming(socket: Socket) {
        try {
            socket.soTimeout = 10_000
            socket.keepAlive = true
            socket.tcpNoDelay = true
            val line = readLine(socket.getInputStream(), MAX_IDENTITY_LINE) ?: throw SocketTimeoutException("no identity")
            val packet = Packet.parse(line) ?: throw IllegalStateException("bad identity")
            val plain = Identity.from(packet) ?: throw IllegalStateException("bad identity")
            if (plain.deviceId == local.deviceId) {
                socket.close(); return
            }
            // A device that answers a broadcast names the device it wants.
            val target = packet.string("targetDeviceId")
            if (target != null && target != local.deviceId) throw IllegalStateException("identity is for $target")
            val ssl = tls.wrap(socket, server = false)
            finish(ssl, plain)
        } catch (e: Exception) {
            Log.i(TAG, "incoming link from ${socket.inetAddress} failed: ${e.message}")
            runCatching { socket.close() }
        }
    }

    /**
     * Connects to a device that sent its identity over UDP. This side sends
     * its identity in plain text and is then the TLS server.
     */
    fun connect(address: InetAddress, port: Int, udpIdentity: Identity? = null) {
        val socket = Socket()
        try {
            socket.connect(InetSocketAddress(address, port), 5_000)
            socket.keepAlive = true
            socket.tcpNoDelay = true
            val out = socket.getOutputStream()
            out.write(identity(0).toPacket(target = udpIdentity).serialize().toByteArray())
            out.flush()
            val ssl = tls.wrap(socket, server = true)
            finish(ssl, udpIdentity)
        } catch (e: Exception) {
            Log.i(TAG, "link to $address:$port failed: ${e.message}")
            runCatching { socket.close() }
        }
    }

    /**
     * Checks the peer certificate and, for protocol version 8, exchanges the
     * identity again over TLS. The identity inside TLS is the one to trust.
     */
    private fun finish(ssl: SSLSocket, plain: Identity?) {
        val cert = Tls.peerCertificate(ssl) ?: throw IllegalStateException("peer sent no certificate")
        val cn = commonName(cert)
        var id = plain
        if (plain == null || plain.protocolVersion >= 8) {
            // Both sides write the identity at once. KDE Connect closes the
            // link when it does not arrive within 1 second.
            val out = ssl.outputStream
            out.write(identity(0).toPacket().serialize().toByteArray())
            out.flush()
            ssl.soTimeout = 10_000
            val line = readLine(ssl.inputStream, MAX_IDENTITY_LINE) ?: throw SocketTimeoutException("no identity after TLS")
            ssl.soTimeout = 0
            id = Packet.parse(line)?.let { Identity.from(it) } ?: throw IllegalStateException("bad identity after TLS")
            if (plain != null && plain.deviceId != id.deviceId) throw IllegalStateException("device ID changed after TLS")
            if (plain != null && plain.protocolVersion != id.protocolVersion) throw IllegalStateException("protocol version changed after TLS")
        }
        val identity = id ?: throw IllegalStateException("no identity")
        if (cn != identity.deviceId) throw IllegalStateException("certificate CN $cn does not match ${identity.deviceId}")
        val pinned = callbacks.trustedCertificate(identity.deviceId)
        if (pinned != null && !pinned.encoded.contentEquals(cert.encoded)) {
            throw IllegalStateException("${identity.deviceName} presented a different certificate")
        }
        callbacks.onLink(Link(ssl, identity, cert))
    }
}

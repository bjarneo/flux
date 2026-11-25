package org.omarchy.flux.core

import android.util.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import org.omarchy.flux.protocol.Packet
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

/**
 * A network card of a computer that can wake it from sleep: its MAC
 * address, and the IPv4 broadcast address of its network when the
 * computer had one.
 */
@Serializable
data class WakeTarget(val mac: String, val broadcast: String = "", val wireless: Boolean = false)

/**
 * Wake-on-LAN. A computer sends its network cards in a flux.wake packet
 * after it connects. The phone keeps them with the pairing, and sends a
 * magic packet to a computer that is offline. The computer must allow
 * Wake-on-LAN in its firmware and on its network card.
 */
object Wake {
    private const val TAG = "FluxWake"
    private const val MAX_TARGETS = 8
    private val MAC = Regex("^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")
    private val IPV4 = Regex("^\\d{1,3}(\\.\\d{1,3}){3}$")

    /** The UDP ports that network cards listen on for a magic packet. */
    private val PORTS = listOf(9, 7)

    /** Reads the targets of a flux.wake packet. It drops each entry that is not valid. */
    fun parse(p: Packet): List<WakeTarget> =
        p.array("targets").orEmpty().mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val mac = (o["mac"] as? JsonPrimitive)?.contentOrNull?.lowercase()?.takeIf { MAC.matches(it) } ?: return@mapNotNull null
            val broadcast = (o["broadcast"] as? JsonPrimitive)?.contentOrNull?.takeIf { IPV4.matches(it) }.orEmpty()
            val wireless = (o["wireless"] as? JsonPrimitive)?.booleanOrNull == true
            WakeTarget(mac, broadcast, wireless)
        }.distinctBy { it.mac }.take(MAX_TARGETS)

    /** Keeps the targets of computer [d], also for the next start of the app. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        val targets = parse(p)
        if (targets == d.wake) return
        d.wake = targets
        if (d.paired) core.trust.update(d.id) { it.copy(wake = targets) }
    }

    /** The magic packet for [mac]: 6 bytes of 0xFF, then the MAC address 16 times. */
    fun magic(mac: String): ByteArray {
        val bytes = mac.split(':').map { it.toInt(16).toByte() }
        require(bytes.size == 6)
        return ByteArray(6) { 0xFF.toByte() } + ByteArray(16 * 6) { bytes[it % 6] }
    }

    /**
     * The addresses that a magic packet goes to: the broadcast address of
     * each target, the broadcast address of each network of this phone,
     * 255.255.255.255, and the last address of the computer.
     */
    fun destinations(targets: List<WakeTarget>, phoneBroadcasts: List<String>, lastIp: String): List<String> =
        (targets.map { it.broadcast } + phoneBroadcasts + "255.255.255.255" + lastIp)
            .filter { IPV4.matches(it) }.distinct()

    /**
     * Sends a magic packet for each target of computer [d], on a background
     * thread. It shows a toast with the result.
     */
    fun send(core: FluxCore, d: Device) {
        val targets = d.wake
        val name = d.identity.deviceName
        if (targets.isEmpty()) {
            core.toast("$name did not send its network cards. Connect it 1 time with a new Flux.")
            return
        }
        val lastIp = d.lastIp
        core.io.execute {
            val sent = runCatching { sendNow(targets, lastIp) }.onFailure { Log.w(TAG, "wake $name failed", it) }.getOrDefault(0)
            core.toast(if (sent > 0) "Sent a wake signal to $name" else "Could not send a wake signal. Connect the phone to the network of $name.")
        }
    }

    private fun sendNow(targets: List<WakeTarget>, lastIp: String): Int {
        val addresses = destinations(targets, phoneBroadcasts(), lastIp)
        var sent = 0
        DatagramSocket().use { socket ->
            socket.broadcast = true
            for (t in targets) {
                val data = magic(t.mac)
                for (a in addresses) for (port in PORTS) {
                    runCatching {
                        socket.send(DatagramPacket(data, data.size, InetAddress.getByName(a), port))
                        sent++
                    }
                }
            }
        }
        return sent
    }

    /** The IPv4 broadcast addresses of the networks of this phone. */
    private fun phoneBroadcasts(): List<String> =
        runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.interfaceAddresses }
                .filter { it.address is Inet4Address }
                .mapNotNull { it.broadcast?.hostAddress }
        }.getOrDefault(emptyList())
}

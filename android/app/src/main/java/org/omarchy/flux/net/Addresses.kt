package org.omarchy.flux.net

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

/**
 * Address checks for the listeners. The code has no Android imports, so the
 * JVM tests can load it.
 */

/** Tailscale gives each device an address in 100.64.0.0/10 and in fd7a:115c:a1e0::/48. */
private val tailscale4: InetAddress = InetAddress.getByAddress(byteArrayOf(100, 64, 0, 0))
private val tailscale6: InetAddress = InetAddress.getByName("fd7a:115c:a1e0::")

/** Reports whether the first [bits] bits of [a] and [b] are the same. Addresses of 2 families never match. */
fun samePrefix(a: InetAddress, b: InetAddress, bits: Int): Boolean {
    val x = a.address
    val y = b.address
    if (x.size != y.size || bits < 0 || bits > x.size * 8) return false
    val whole = bits / 8
    for (i in 0 until whole) if (x[i] != y[i]) return false
    val rest = bits % 8
    if (rest == 0) return true
    val mask = (0xff shl (8 - rest)) and 0xff
    return (x[whole].toInt() and mask) == (y[whole].toInt() and mask)
}

/** Reports whether the address is a Tailscale address. */
fun isTailscale(a: InetAddress): Boolean = when (a) {
    is Inet4Address -> samePrefix(a, tailscale4, 10)
    is Inet6Address -> samePrefix(a, tailscale6, 48)
    else -> false
}

/**
 * Reports whether a connection from [from] can come from the device of a
 * link with the address [link]. The address must be the same. A /64 network
 * is not enough, because other hosts on the same LAN share it. fluxd finds
 * the phone over IPv4, and Tailscale gives each device 1 fixed IPv6 address.
 */
fun samePeer(from: InetAddress, link: InetAddress): Boolean = from.address.contentEquals(link.address)

package org.omarchy.flux.net

import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.net.Socket

/** Linux TCP options that android.system.OsConstants does not name. */
private const val TCP_KEEPIDLE = 4
private const val TCP_KEEPINTVL = 5
private const val TCP_KEEPCNT = 6

/** How long sent data can wait for an answer before the kernel closes the connection, as in fluxd. */
private const val USER_TIMEOUT_MS = 30_000

/**
 * Makes the kernel find a dead peer on a connection. Data that waits 30
 * seconds for an answer closes the connection. An idle connection sends a
 * probe after 60 seconds, then 1 every 10 seconds, and closes after 3
 * probes without an answer. Without these options, a computer that sleeps
 * stays connected on the phone for up to 2 hours.
 */
fun keepAlive(socket: Socket) {
    runCatching {
        socket.keepAlive = true
        socket.tcpNoDelay = true
    }
    // The file descriptor is a copy, so its close does not close the socket.
    runCatching {
        ParcelFileDescriptor.fromSocket(socket).use { pfd ->
            val fd = pfd.fileDescriptor
            Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, OsConstants.TCP_USER_TIMEOUT, USER_TIMEOUT_MS)
            Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, TCP_KEEPIDLE, 60)
            Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, TCP_KEEPINTVL, 10)
            Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, TCP_KEEPCNT, 3)
        }
    }
}

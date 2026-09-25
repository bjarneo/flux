package org.omarchy.flux.protocol

/**
 * Flux tunnels. When the computer blocks incoming connections, it asks this
 * phone to listen. The phone opens a TLS listener and answers with
 * flux.tunnel {id, port}, or {id, error}. The computer then connects.
 */
object TunnelPackets {
    fun ready(token: String, port: Int): Packet = Packet(Types.FLUX_TUNNEL, bodyOf("id" to token, "port" to port))

    fun failed(token: String, error: String): Packet = Packet(Types.FLUX_TUNNEL, bodyOf("id" to token, "error" to error))
}

/**
 * The body of kdeconnect.sftp. A computer that accepts connections sends
 * [ip] and [port]. A computer behind a firewall sends [tunnel] instead.
 */
data class SftpOffer(
    val ip: String?,
    val port: Int,
    val tunnel: String?,
    val user: String,
    val password: String,
    val path: String,
    val roots: List<Pair<String, String>>,
) {
    val viaTunnel: Boolean get() = tunnel != null && (ip == null || port <= 0)

    companion object {
        /** Parses kdeconnect.sftp. It returns null for an error answer or a packet with no way to connect. */
        fun parse(p: Packet): SftpOffer? {
            if (p.type != Types.SFTP || p.has("errorMessage")) return null
            val user = p.string("user") ?: return null
            val password = p.string("password") ?: return null
            val ip = p.string("ip")?.takeIf { it.isNotEmpty() }
            val port = p.int("port") ?: 0
            val tunnel = p.string("tunnel")?.takeIf { it.isNotEmpty() }
            if (tunnel == null && port <= 0) return null
            val path = p.string("path") ?: "/"
            val paths = p.strings("multiPaths")
            val names = p.strings("pathNames")
            val roots = if (paths.isNotEmpty() && paths.size == names.size) names.zip(paths) else listOf("Home" to path)
            return SftpOffer(ip, port, tunnel, user, password, path, roots)
        }
    }
}

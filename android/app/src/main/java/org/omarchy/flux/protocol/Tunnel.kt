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
 * The body of flux.sftp. The phone opens a listener for [tunnel], and the
 * computer connects to it. [roots] pairs each folder name with its path.
 */
data class SftpOffer(
    val tunnel: String,
    val user: String,
    val password: String,
    val path: String,
    val roots: List<Pair<String, String>>,
) {
    companion object {
        /**
         * Parses flux.sftp. It returns null for an error answer, a packet
         * without a tunnel, or root lists that are empty or differ in length.
         */
        fun parse(p: Packet): SftpOffer? {
            if (p.type != Types.SFTP || p.has("errorMessage")) return null
            val tunnel = p.string("tunnel")?.takeIf { it.isNotEmpty() } ?: return null
            val user = p.string("user") ?: return null
            val password = p.string("password") ?: return null
            val path = p.string("path") ?: "/"
            val paths = p.strings("multiPaths")
            val names = p.strings("pathNames")
            if (paths.isEmpty() || paths.size != names.size) return null
            return SftpOffer(tunnel, user, password, path, names.zip(paths))
        }
    }
}

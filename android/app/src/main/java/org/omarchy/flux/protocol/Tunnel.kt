package org.omarchy.flux.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

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
 * [search] tells that the computer answers a search of the session.
 */
data class SftpOffer(
    val tunnel: String,
    val user: String,
    val password: String,
    val path: String,
    val roots: List<Pair<String, String>>,
    val search: Boolean = false,
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
            return SftpOffer(tunnel, user, password, path, names.zip(paths), search = p.bool("search") == true)
        }
    }
}

/** 1 file or folder that a search found. [modified] is in Unix seconds. */
data class SftpMatch(val path: String, val dir: Boolean, val size: Long, val modified: Long)

/**
 * The search answer in flux.sftp. [results] are the matches, the best
 * first. [more] tells that more names match than the answer holds.
 * [partial] tells that the search stopped at its time limit.
 */
data class SftpFound(
    val id: Long,
    val results: List<SftpMatch>,
    val more: Boolean,
    val partial: Boolean,
    val error: String?,
) {
    companion object {
        /**
         * Asks for the files and folders whose names hold each word of
         * [query], in [path] and its subfolders. An empty [path] searches
         * each shared folder.
         */
        fun request(id: Long, query: String, path: String): Packet =
            Packet(Types.SFTP_REQUEST, bodyOf("search" to mapOf("id" to id, "query" to query, "path" to path)))

        /**
         * Reports whether flux.sftp is a search answer. A search answer has a
         * search object. An offer has the search flag, which is true or false.
         */
        fun isAnswer(p: Packet): Boolean = p.type == Types.SFTP && p.obj("search") != null

        /** Parses the search answer of flux.sftp. It returns null for an offer or an error of the session. */
        fun parse(p: Packet): SftpFound? {
            if (!isAnswer(p)) return null
            val s = p.obj("search")!!
            val id = s.long("id") ?: return null
            val results = (s["results"] as? JsonArray).orEmpty().mapNotNull { e ->
                val o = e as? JsonObject ?: return@mapNotNull null
                val path = o.str("path")?.takeIf { it.startsWith("/") } ?: return@mapNotNull null
                SftpMatch(path, o.bool("dir") == true, o.long("size") ?: 0, o.long("modified") ?: 0)
            }
            return SftpFound(id, results, s.bool("more") == true, s.bool("partial") == true, s.str("error")?.takeIf { it.isNotEmpty() })
        }
    }
}

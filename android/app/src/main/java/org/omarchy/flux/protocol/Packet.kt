package org.omarchy.flux.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** The protocol version that Flux speaks. */
const val PROTOCOL_VERSION = 8

val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

/**
 * One Flux network packet. On the wire, a packet is one JSON object
 * followed by a newline.
 */
data class Packet(
    val type: String,
    val body: JsonObject = JsonObject(emptyMap()),
    val id: Long = System.currentTimeMillis(),
    val payloadSize: Long = 0,
    /**
     * The port of the payload server of this phone. Only packets that this
     * phone sends carry it, and the computer connects to the port.
     */
    val payloadPort: Int = 0,
    /**
     * The token of a tunnel payload from the computer. This phone listens,
     * and the computer connects.
     */
    val payloadTunnel: String? = null,
) {
    /** Returns the packet as one line with a trailing newline. */
    fun serialize(): String {
        val obj = buildJsonObject {
            put("id", id)
            put("type", type)
            put("body", body)
            if (payloadSize != 0L && payloadPort > 0) {
                put("payloadSize", payloadSize)
                put("payloadTransferInfo", buildJsonObject { put("port", payloadPort) })
            } else if (payloadSize != 0L && payloadTunnel != null) {
                put("payloadSize", payloadSize)
                put("payloadTransferInfo", buildJsonObject { put("tunnel", payloadTunnel) })
            }
        }
        return json.encodeToString(JsonObject.serializer(), obj) + "\n"
    }

    val hasPayload: Boolean get() = payloadSize != 0L && (payloadPort > 0 || payloadTunnel != null)

    fun string(key: String): String? = (body[key] as? JsonPrimitive)?.contentOrNull
    fun bool(key: String): Boolean? = (body[key] as? JsonPrimitive)?.booleanOrNull
        ?: (body[key] as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull()
    fun int(key: String): Int? = (body[key] as? JsonPrimitive)?.let { it.intOrNull ?: it.doubleOrNull?.toInt() ?: it.contentOrNull?.toIntOrNull() }
    fun long(key: String): Long? = (body[key] as? JsonPrimitive)?.let { it.longOrNull ?: it.doubleOrNull?.toLong() ?: it.contentOrNull?.toLongOrNull() }
    fun double(key: String): Double? = (body[key] as? JsonPrimitive)?.let { it.doubleOrNull ?: it.contentOrNull?.toDoubleOrNull() }
    fun has(key: String): Boolean = body.containsKey(key)
    fun obj(key: String): JsonObject? = body[key] as? JsonObject
    fun array(key: String): JsonArray? = body[key] as? JsonArray
    fun strings(key: String): List<String> =
        array(key)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull } ?: emptyList()

    companion object {
        /**
         * Parses one packet line. It returns null for a line that is not a
         * packet. The computer sends each payload through a tunnel, so the
         * parse ignores a payload port. An Error, for example an
         * OutOfMemoryError, goes to the caller, so that the link closes.
         */
        fun parse(line: String): Packet? {
            val obj = try {
                json.parseToJsonElement(line.trim()).jsonObject
            } catch (_: Exception) {
                return null
            }
            val type = (obj["type"] as? JsonPrimitive)?.contentOrNull ?: return null
            val id = (obj["id"] as? JsonPrimitive)?.let { it.longOrNull ?: it.contentOrNull?.toLongOrNull() } ?: 0L
            val body = obj["body"] as? JsonObject ?: JsonObject(emptyMap())
            val size = (obj["payloadSize"] as? JsonPrimitive)?.longOrNull ?: 0L
            val info = obj["payloadTransferInfo"] as? JsonObject
            val tunnel = (info?.get("tunnel") as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotEmpty() }
            return Packet(type, body, id, size, payloadTunnel = tunnel)
        }

        /** Builds a packet from a map of simple values. */
        fun of(type: String, vararg fields: Pair<String, Any?>): Packet = Packet(type, bodyOf(*fields))
    }
}

/** Builds a JSON object from simple Kotlin values. */
fun bodyOf(vararg fields: Pair<String, Any?>): JsonObject = JsonObject(fields.associate { (k, v) -> k to toJson(v) })

fun toJson(v: Any?): JsonElement = when (v) {
    null -> JsonNull
    is JsonElement -> v
    is String -> JsonPrimitive(v)
    is Number -> JsonPrimitive(v)
    is Boolean -> JsonPrimitive(v)
    is Map<*, *> -> JsonObject(v.entries.associate { (k, value) -> k.toString() to toJson(value) })
    is Iterable<*> -> JsonArray(v.map { toJson(it) })
    is Array<*> -> JsonArray(v.map { toJson(it) })
    else -> JsonPrimitive(v.toString())
}

fun JsonElement.str(): String? = (this as? JsonPrimitive)?.contentOrNull
fun JsonObject.str(key: String): String? = this[key]?.str()
fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.let { it.longOrNull ?: it.doubleOrNull?.toLong() ?: it.contentOrNull?.toLongOrNull() }
fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
fun JsonObject.strings(key: String): List<String> = (this[key] as? JsonArray)?.mapNotNull { it.str() } ?: emptyList()
fun JsonElement.asArray(): JsonArray? = runCatching { jsonArray }.getOrNull()

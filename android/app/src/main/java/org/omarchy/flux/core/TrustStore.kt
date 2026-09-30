package org.omarchy.flux.core

import android.content.Context
import android.util.Base64
import android.util.Log
import kotlinx.serialization.Serializable
import org.omarchy.flux.protocol.json
import org.omarchy.flux.protocol.parseCertificate
import java.security.cert.X509Certificate

/** A paired device. Flux pins its certificate. */
@Serializable
data class TrustedDevice(
    val id: String,
    val name: String,
    val type: String,
    val certificate: String,
    val lastIp: String = "",
) {
    fun cert(): X509Certificate = parseCertificate(Base64.decode(certificate, Base64.NO_WRAP))
}

/**
 * The list of paired devices, stored in shared preferences. An entry whose
 * certificate does not parse is not a pairing: the device is not trusted
 * and must pair again.
 */
class TrustStore(context: Context) {
    private val prefs = context.getSharedPreferences("trusted", Context.MODE_PRIVATE)
    private val devices = HashMap<String, TrustedDevice>()
    private val certificates = HashMap<String, X509Certificate>()

    init {
        for ((key, v) in prefs.all) {
            val d = runCatching { json.decodeFromString(TrustedDevice.serializer(), v as String) }.getOrNull()
            val cert = d?.let { runCatching { it.cert() }.getOrNull() }
            if (d == null || cert == null) {
                Log.w("FluxTrust", "ignored the pairing $key: it does not parse")
                continue
            }
            devices[d.id] = d
            certificates[d.id] = cert
        }
    }

    @Synchronized fun get(id: String): TrustedDevice? = devices[id]
    @Synchronized fun all(): List<TrustedDevice> = devices.values.toList()

    /** Returns the pinned certificate of a trusted device, or null. */
    @Synchronized fun certificate(id: String): X509Certificate? = certificates[id]

    /** Stores a pairing. An entry whose certificate does not parse is not stored. */
    @Synchronized fun put(d: TrustedDevice) {
        val cert = certificates[d.id]?.takeIf { devices[d.id]?.certificate == d.certificate }
            ?: runCatching { d.cert() }.getOrNull()
            ?: return
        devices[d.id] = d
        certificates[d.id] = cert
        prefs.edit().putString(d.id, json.encodeToString(TrustedDevice.serializer(), d)).apply()
    }

    @Synchronized fun update(id: String, fn: (TrustedDevice) -> TrustedDevice) {
        val d = devices[id] ?: return
        put(fn(d))
    }

    @Synchronized fun remove(id: String) {
        devices.remove(id)
        certificates.remove(id)
        prefs.edit().remove(id).apply()
    }

    companion object {
        fun encode(cert: X509Certificate): String = Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
    }
}

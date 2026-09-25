package org.omarchy.flux.core

import android.content.Context
import android.util.Base64
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
    val isFlux: Boolean = false,
) {
    fun cert(): X509Certificate = parseCertificate(Base64.decode(certificate, Base64.NO_WRAP))
}

/** The list of paired devices, stored in shared preferences. */
class TrustStore(context: Context) {
    private val prefs = context.getSharedPreferences("trusted", Context.MODE_PRIVATE)
    private val devices = HashMap<String, TrustedDevice>()

    init {
        for ((_, v) in prefs.all) {
            val d = runCatching { json.decodeFromString(TrustedDevice.serializer(), v as String) }.getOrNull() ?: continue
            devices[d.id] = d
        }
    }

    @Synchronized fun get(id: String): TrustedDevice? = devices[id]
    @Synchronized fun all(): List<TrustedDevice> = devices.values.toList()

    @Synchronized fun put(d: TrustedDevice) {
        devices[d.id] = d
        prefs.edit().putString(d.id, json.encodeToString(TrustedDevice.serializer(), d)).apply()
    }

    @Synchronized fun update(id: String, fn: (TrustedDevice) -> TrustedDevice) {
        val d = devices[id] ?: return
        put(fn(d))
    }

    @Synchronized fun remove(id: String) {
        devices.remove(id)
        prefs.edit().remove(id).apply()
    }

    companion object {
        fun encode(cert: X509Certificate): String = Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
    }
}

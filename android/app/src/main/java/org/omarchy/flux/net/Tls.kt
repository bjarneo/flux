package org.omarchy.flux.net

import org.omarchy.flux.protocol.LocalCertificate
import java.net.Socket
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509ExtendedTrustManager

/**
 * TLS for KDE Connect links. Both sides present a self-signed certificate.
 * The handshake accepts any certificate. The link code checks the peer
 * certificate against the device ID and the pinned certificate after the
 * handshake.
 */
class Tls(private val local: LocalCertificate) {
    // KDE Connect for Android uses TLS 1.2 because TLS 1.3 caused problems
    // with some peers. Flux does the same.
    private val context: SSLContext = SSLContext.getInstance("TLSv1.2").apply {
        init(arrayOf(SingleKeyManager(local)), arrayOf(AcceptAllTrustManager), null)
    }

    /**
     * Wraps a connected TCP socket. When [server] is true, this side acts as
     * the TLS server. The function returns after the handshake.
     */
    fun wrap(socket: Socket, server: Boolean): SSLSocket {
        val ssl = context.socketFactory.createSocket(
            socket, socket.inetAddress.hostAddress, socket.port, true,
        ) as SSLSocket
        ssl.enabledProtocols = arrayOf("TLSv1.2")
        ssl.useClientMode = !server
        if (server) ssl.needClientAuth = true
        ssl.soTimeout = 10_000
        ssl.startHandshake()
        ssl.soTimeout = 0
        return ssl
    }

    companion object {
        fun peerCertificate(ssl: SSLSocket): X509Certificate? =
            runCatching { ssl.session.peerCertificates.firstOrNull() as? X509Certificate }.getOrNull()
    }
}

/** A key manager that always offers the one certificate of this phone. */
private class SingleKeyManager(private val local: LocalCertificate) : X509ExtendedKeyManager() {
    private val alias = "flux"
    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(alias)
    override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = alias
    override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(alias)
    override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = alias
    override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = alias
    override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?) = alias
    override fun getCertificateChain(alias: String?): Array<X509Certificate> = arrayOf(local.certificate)
    override fun getPrivateKey(alias: String?): PrivateKey = local.privateKey
}

/** Accepts every certificate. The link code pins certificates after the handshake. */
private object AcceptAllTrustManager : X509ExtendedTrustManager() {
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = Unit
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = Unit
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = Unit
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = Unit
    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

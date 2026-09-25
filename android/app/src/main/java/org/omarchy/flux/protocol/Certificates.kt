package org.omarchy.flux.protocol

import org.bouncycastle.asn1.x500.X500NameBuilder
import org.bouncycastle.asn1.x500.style.BCStyle
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Calendar
import java.util.UUID
import javax.security.auth.x500.X500Principal

/** The key and the self-signed certificate of this phone. */
class LocalCertificate(val privateKey: PrivateKey, val certificate: X509Certificate) {
    /** The device ID is the common name of the certificate. */
    val deviceId: String get() = commonName(certificate) ?: error("certificate has no CN")

    companion object {
        private const val KEY_FILE = "privateKey.der"
        private const val CERT_FILE = "certificate.der"

        /**
         * Loads the certificate from the directory. The first call generates a
         * new RSA 2048 key and a certificate with CN set to a new device ID.
         */
        fun loadOrCreate(dir: File): LocalCertificate {
            val keyFile = File(dir, KEY_FILE)
            val certFile = File(dir, CERT_FILE)
            if (keyFile.exists() && certFile.exists()) {
                runCatching {
                    val key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
                    return LocalCertificate(key, parseCertificate(certFile.readBytes()))
                }
            }
            val created = generate(UUID.randomUUID().toString().replace("-", ""))
            dir.mkdirs()
            keyFile.writeBytes(created.privateKey.encoded)
            certFile.writeBytes(created.certificate.encoded)
            return created
        }

        /** Generates a self-signed certificate in the KDE Connect format. */
        fun generate(deviceId: String): LocalCertificate {
            val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
            val name = X500NameBuilder(BCStyle.INSTANCE)
                .addRDN(BCStyle.CN, deviceId)
                .addRDN(BCStyle.OU, "KDE Connect")
                .addRDN(BCStyle.O, "KDE")
                .build()
            val now = Calendar.getInstance()
            val notBefore = (now.clone() as Calendar).apply { add(Calendar.YEAR, -1) }.time
            val notAfter = (now.clone() as Calendar).apply { add(Calendar.YEAR, 10) }.time
            val builder = JcaX509v3CertificateBuilder(name, BigInteger.ONE, notBefore, notAfter, name, pair.public)
                .addExtension(Extension.basicConstraints, true, BasicConstraints(false))
            val signer = JcaContentSignerBuilder("SHA256WithRSA").build(pair.private)
            val cert = JcaX509CertificateConverter().getCertificate(builder.build(signer))
            return LocalCertificate(pair.private, cert)
        }
    }
}

fun parseCertificate(der: ByteArray): X509Certificate =
    CertificateFactory.getInstance("X.509").generateCertificate(der.inputStream()) as X509Certificate

/** Returns the CN of the certificate subject. */
fun commonName(cert: X509Certificate): String? {
    val dn = cert.subjectX500Principal.getName(X500Principal.RFC2253)
    return dn.split(',').map { it.trim() }.firstOrNull { it.startsWith("CN=") }?.removePrefix("CN=")
}

/** Returns the SubjectPublicKeyInfo DER bytes exactly as the certificate holds them. */
fun subjectPublicKeyInfo(cert: X509Certificate): ByteArray =
    org.bouncycastle.asn1.x509.Certificate.getInstance(cert.encoded).subjectPublicKeyInfo.encoded

/**
 * Returns the 8-character key that both devices show while they pair. It
 * hashes the 2 public keys, larger first, then the pairing timestamp in
 * seconds as decimal text.
 */
fun verificationKey(own: X509Certificate, peer: X509Certificate, timestamp: Long): String =
    verificationKey(subjectPublicKeyInfo(own), subjectPublicKeyInfo(peer), timestamp)

fun verificationKey(ownKey: ByteArray, peerKey: ByteArray, timestamp: Long): String {
    var a = ownKey
    var b = peerKey
    if (compareBytes(a, b) < 0) {
        val t = a; a = b; b = t
    }
    val md = MessageDigest.getInstance("SHA-256")
    md.update(a)
    md.update(b)
    if (timestamp > 0) md.update(timestamp.toString().toByteArray())
    return md.digest().joinToString("") { "%02x".format(it) }.substring(0, 8).uppercase()
}

/** Compares bytes as unsigned values, the same way Go bytes.Compare does. */
fun compareBytes(a: ByteArray, b: ByteArray): Int {
    val n = minOf(a.size, b.size)
    for (i in 0 until n) {
        val x = a[i].toInt() and 0xff
        val y = b[i].toInt() and 0xff
        if (x != y) return x - y
    }
    return a.size - b.size
}

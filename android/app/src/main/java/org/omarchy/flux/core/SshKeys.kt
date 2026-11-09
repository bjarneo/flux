package org.omarchy.flux.core

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/** The SSH key of this phone as the screens show it. */
data class SshKeyInfo(
    /** The public key in DER. */
    val spki: ByteArray,
    /** The line for authorized_keys. */
    val line: String,
    /** The SHA-256 fingerprint, as ssh-add -l shows it. */
    val fingerprint: String,
    /** Where Android keeps the private key. */
    val storage: Storage,
) {
    enum class Storage { StrongBox, SecureHardware, Software, Unknown }

    override fun equals(other: Any?): Boolean = other is SshKeyInfo && other.spki.contentEquals(spki) && other.storage == storage

    override fun hashCode(): Int = spki.contentHashCode()
}

/**
 * The SSH key of this phone in the Android Keystore: 1 EC P-256 key for all
 * paired computers. Each use needs a new check of a strong biometric or of
 * the screen lock, so the phone signs only through BiometricPrompt. The
 * private key never leaves the Keystore. docs/ssh.md is the design.
 */
object SshKeys {
    private const val STORE = "AndroidKeyStore"
    private const val ALIAS = "flux-ssh"

    private val _info = MutableStateFlow<SshKeyInfo?>(null)

    /** The key, or null when SSH key is off. */
    val info: StateFlow<SshKeyInfo?> = _info

    @Volatile private var loaded = false

    private fun store(): KeyStore = KeyStore.getInstance(STORE).apply { load(null) }

    /** Reads the key from the Keystore once. */
    fun load() {
        if (loaded) return
        loaded = true
        refresh()
    }

    private fun refresh() {
        _info.value = runCatching { read(store()) }.getOrNull()
    }

    private fun read(ks: KeyStore): SshKeyInfo? {
        val spki = ks.getCertificate(ALIAS)?.publicKey?.encoded ?: return null
        val blob = SshMessage.keyBlob(spki) ?: return null
        val name = runCatching { FluxCore.deviceName }.getOrDefault("this phone")
        return SshKeyInfo(spki, SshMessage.authorizedKey(blob, "Flux on $name"), SshMessage.fingerprint(blob), storage(ks))
    }

    private fun storage(ks: KeyStore): SshKeyInfo.Storage = runCatching {
        val key = ks.getKey(ALIAS, null) as PrivateKey
        val info = KeyFactory.getInstance(key.algorithm, STORE).getKeySpec(key, KeyInfo::class.java)
        if (Build.VERSION.SDK_INT >= 31) {
            when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> SshKeyInfo.Storage.StrongBox
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> SshKeyInfo.Storage.SecureHardware
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> SshKeyInfo.Storage.Software
                else -> SshKeyInfo.Storage.Unknown
            }
        } else {
            @Suppress("DEPRECATION")
            if (info.isInsideSecureHardware) SshKeyInfo.Storage.SecureHardware else SshKeyInfo.Storage.Software
        }
    }.getOrDefault(SshKeyInfo.Storage.Unknown)

    /** The public key in DER, or null when SSH key is off. */
    fun spki(): ByteArray? {
        load()
        return _info.value?.spki
    }

    /**
     * Makes a new key, in StrongBox when the phone has it. The phone must
     * have a screen lock. It replaces no key: call it only while SSH key is
     * off. It throws when Android cannot make the key.
     */
    fun create() {
        val ks = store()
        runCatching { ks.deleteEntry(ALIAS) }
        try {
            generate(strongBox = true)
        } catch (e: StrongBoxUnavailableException) {
            generate(strongBox = false)
        }
        loaded = true
        refresh()
    }

    /** Deletes the key. Nobody can get it back. */
    fun delete() {
        runCatching { store().deleteEntry(ALIAS) }
        loaded = true
        _info.value = null
    }

    private fun generate(strongBox: Boolean) {
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            // The screen lock can sign too, so a new fingerprint does not make the key invalid.
            .setInvalidatedByBiometricEnrollment(false)
            .setIsStrongBoxBacked(strongBox)
            .apply {
                if (Build.VERSION.SDK_INT >= 30) {
                    // 0 seconds: each signature needs a new check.
                    setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
                } else {
                    // Android 10 has no screen lock check for each use. -1 seconds: each signature needs a new biometric check.
                    @Suppress("DEPRECATION")
                    setUserAuthenticationValidityDurationSeconds(-1)
                }
            }
            .build()
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, STORE)
        gen.initialize(spec)
        gen.generateKeyPair()
    }

    /**
     * Returns a Signature for the key, ready for a BiometricPrompt
     * CryptoObject. It throws KeyPermanentlyInvalidatedException after the
     * screen lock was removed.
     */
    fun signer(): Signature {
        val key = store().getKey(ALIAS, null) as? PrivateKey ?: throw IllegalStateException("SSH key is off on this phone")
        return Signature.getInstance("SHA256withECDSA").apply { initSign(key) }
    }
}

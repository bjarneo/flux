package org.omarchy.flux.core

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * The approval keys in the Android Keystore, 1 for each paired computer.
 * Each use of a key needs a strong biometric, with no time window, so the
 * phone can sign only through BiometricPrompt. A new fingerprint in the
 * phone settings makes the key invalid. An enrollment replaces the key only
 * after the computer got the new key. docs/approve.md is the design.
 */
object ApproveKeys {
    private const val STORE = "AndroidKeyStore"

    /**
     * The 2 aliases of the keys of [computerId]. An enrollment makes its key
     * under the alias that the current key does not use, so the current key
     * works until the new key reaches the computer.
     */
    private fun aliases(computerId: String) = listOf("flux-approve-$computerId", "flux-approve-$computerId.b")

    private fun store(): KeyStore = KeyStore.getInstance(STORE).apply { load(null) }

    /**
     * The alias of the current key of [computerId], or null. With 2 keys,
     * an enrollment did not end, and the older key is the current key.
     */
    private fun current(ks: KeyStore, computerId: String): String? =
        aliases(computerId).filter { ks.containsAlias(it) }.minByOrNull { ks.getCreationDate(it)?.time ?: 0L }

    fun has(computerId: String): Boolean = runCatching { current(store(), computerId) != null }.getOrDefault(false)

    /** Deletes every key of [computerId]. */
    fun delete(computerId: String) {
        runCatching {
            val ks = store()
            for (a in aliases(computerId)) runCatching { ks.deleteEntry(a) }
        }
    }

    /** A new key of an enrollment that did not end yet. [spki] is its public key in DER. */
    class Pending(val computerId: String, val alias: String, val spki: ByteArray)

    /**
     * Makes a new key for [computerId] next to the current key. The current
     * key stays until [commit], so a cancelled or failed enrollment keeps
     * the approvals working. The phone must have a strong biometric set up.
     */
    fun create(computerId: String): Pending {
        val ks = store()
        val now = current(ks, computerId)
        val alias = aliases(computerId).first { it != now }
        runCatching { ks.deleteEntry(alias) }
        val spki = try {
            generate(alias, strongBox = true)
        } catch (e: StrongBoxUnavailableException) {
            generate(alias, strongBox = false)
        }
        return Pending(computerId, alias, spki)
    }

    /** Makes the key of [p] the current key and deletes the old key. Call it after the computer got the new key. */
    fun commit(p: Pending) {
        runCatching {
            val ks = store()
            for (a in aliases(p.computerId)) if (a != p.alias) runCatching { ks.deleteEntry(a) }
        }
    }

    /** Deletes the key of an enrollment that did not end. */
    fun discard(p: Pending) {
        runCatching { store().deleteEntry(p.alias) }
    }

    private fun generate(alias: String, strongBox: Boolean): ByteArray {
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            .setIsStrongBoxBacked(strongBox)
            .apply {
                if (Build.VERSION.SDK_INT >= 30) {
                    // 0 seconds: each use needs a new fingerprint.
                    setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                } else {
                    // -1 seconds: each use needs a new biometric authentication.
                    @Suppress("DEPRECATION")
                    setUserAuthenticationValidityDurationSeconds(-1)
                }
            }
            .build()
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, STORE)
        gen.initialize(spec)
        return gen.generateKeyPair().public.encoded
    }

    /**
     * Returns a Signature for the current key of [computerId], ready for a
     * BiometricPrompt CryptoObject. It throws
     * KeyPermanentlyInvalidatedException after a fingerprint change.
     */
    fun signer(computerId: String): Signature {
        val ks = store()
        val alias = current(ks, computerId) ?: throw IllegalStateException("No approval key for this computer")
        return signer(ks, alias)
    }

    /** Returns a Signature for the new key of an enrollment. */
    fun signer(p: Pending): Signature = signer(store(), p.alias)

    private fun signer(ks: KeyStore, alias: String): Signature {
        val key = ks.getKey(alias, null) as? PrivateKey
            ?: throw IllegalStateException("No approval key for this computer")
        return Signature.getInstance("SHA256withECDSA").apply { initSign(key) }
    }
}

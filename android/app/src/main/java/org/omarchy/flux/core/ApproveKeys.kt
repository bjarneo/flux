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
 * phone settings makes the key invalid. docs/approve.md is the design.
 */
object ApproveKeys {
    private const val STORE = "AndroidKeyStore"

    fun alias(computerId: String) = "flux-approve-$computerId"

    private fun store(): KeyStore = KeyStore.getInstance(STORE).apply { load(null) }

    fun has(computerId: String): Boolean = runCatching { store().containsAlias(alias(computerId)) }.getOrDefault(false)

    fun delete(computerId: String) {
        runCatching { store().deleteEntry(alias(computerId)) }
    }

    /**
     * Makes a new key for [computerId] and returns its public key in DER.
     * An old key for the computer goes away. The phone must have a strong
     * biometric set up.
     */
    fun create(computerId: String): ByteArray {
        delete(computerId)
        return try {
            generate(computerId, strongBox = true)
        } catch (e: StrongBoxUnavailableException) {
            generate(computerId, strongBox = false)
        }
    }

    private fun generate(computerId: String, strongBox: Boolean): ByteArray {
        val spec = KeyGenParameterSpec.Builder(alias(computerId), KeyProperties.PURPOSE_SIGN)
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
     * Returns a Signature for the key of [computerId], ready for a
     * BiometricPrompt CryptoObject. It throws
     * KeyPermanentlyInvalidatedException after a fingerprint change.
     */
    fun signer(computerId: String): Signature {
        val key = store().getKey(alias(computerId), null) as? PrivateKey
            ?: throw IllegalStateException("No approval key for this computer")
        return Signature.getInstance("SHA256withECDSA").apply { initSign(key) }
    }
}

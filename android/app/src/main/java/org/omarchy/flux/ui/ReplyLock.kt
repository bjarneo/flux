package org.omarchy.flux.ui

import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock

/**
 * Asks for the phone lock before a reply to an agent. A reply can make an
 * agent run commands on the computer, so a person who holds the unlocked
 * phone must confirm first. An unlock stays valid for 5 minutes while the
 * app process runs.
 */
object ReplyLock {
    private const val VALID_MS = 5 * 60_000L

    /** The end of the unlock, in elapsed realtime. */
    @Volatile private var until = 0L

    /**
     * Runs [action] after the phone lock, or at once while an unlock is
     * valid. [onError] gets a message when the phone has no lock or the
     * check fails. A cancel calls neither. [title] heads the lock prompt,
     * and [purpose] completes the message for a phone without a lock.
     */
    fun run(
        context: Context,
        action: () -> Unit,
        title: String = "Answer an agent",
        purpose: String = "answer agents",
        onError: (String) -> Unit,
    ) {
        if (SystemClock.elapsedRealtime() < until) {
            action()
            return
        }
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        if (keyguard == null || !keyguard.isDeviceSecure) {
            onError("Set a screen lock on this phone to $purpose")
            return
        }
        val builder = BiometricPrompt.Builder(context)
            .setTitle(title)
            .setDescription("Confirm that you send input to the computer.")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
        } else {
            @Suppress("DEPRECATION")
            builder.setDeviceCredentialAllowed(true)
        }
        builder.build().authenticate(
            CancellationSignal(),
            context.mainExecutor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    until = SystemClock.elapsedRealtime() + VALID_MS
                    action()
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    when (errorCode) {
                        BiometricPrompt.BIOMETRIC_ERROR_CANCELED,
                        BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                        -> Unit
                        else -> onError(errString.toString())
                    }
                }
            },
        )
    }
}

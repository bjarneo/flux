package org.omarchy.flux.ui

import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.os.SystemClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import org.omarchy.flux.core.FluxCore

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

    /** True while an unlock is valid. */
    fun valid(): Boolean = unlocked(SystemClock.elapsedRealtime(), until)

    /** True when an unlock that ends at [until] is valid at [now]. Both are in elapsed realtime. */
    internal fun unlocked(now: Long, until: Long): Boolean = now < until

    /**
     * Runs [action] after the phone lock, or at once while an unlock is
     * valid. [onError] gets a message when the phone has no lock or the
     * check fails. A cancel calls [onCancel]. [title] heads the lock
     * prompt, and [purpose] completes the message for a phone without a
     * lock.
     */
    fun run(
        context: Context,
        action: () -> Unit,
        title: String = "Answer an agent",
        purpose: String = "answer agents",
        onCancel: () -> Unit = {},
        onError: (String) -> Unit,
    ) {
        if (valid()) {
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
                        -> onCancel()
                        else -> onError(errString.toString())
                    }
                }
            },
        )
    }
}

/**
 * Keeps a page that controls the computer behind the phone lock. The page
 * asks for the lock each time [ready] turns true without a valid unlock,
 * and again when the app comes back to the front after the unlock ends. A
 * cancel or a phone without a lock calls [onLeave]. It returns true while
 * the page can show the computer and send input. A [sample] computer of a
 * debug build takes no input, so its page needs no lock.
 */
@Composable
fun rememberRemoteUnlock(ready: Boolean, title: String, purpose: String, onLeave: () -> Unit, sample: Boolean = false): Boolean {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val leave by rememberUpdatedState(onLeave)
    var open by remember { mutableStateOf(sample || ReplyLock.valid()) }
    var asking by remember { mutableStateOf(false) }
    var started by remember { mutableStateOf(lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    // The value of ready in the last composition. An earlier unlock does not open the page when ready
    // turns true after the unlock ended, for example when the computer turns its switch on later.
    var wasReady by remember { mutableStateOf(ready) }
    if (ready && !wasReady && !sample && !ReplyLock.valid()) open = false
    SideEffect { wasReady = ready }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> {
                    started = true
                    // The phone can change hands while the app is in the background.
                    if (!sample && !ReplyLock.valid()) open = false
                }
                Lifecycle.Event.ON_STOP -> started = false
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(ready, open, started, asking) {
        if (!ready || open || !started || asking) return@LaunchedEffect
        asking = true
        ReplyLock.run(
            context,
            action = {
                asking = false
                open = true
            },
            title = title,
            purpose = purpose,
            onCancel = {
                asking = false
                leave()
            },
            onError = {
                asking = false
                FluxCore.toast(it)
                leave()
            },
        )
    }
    return open
}

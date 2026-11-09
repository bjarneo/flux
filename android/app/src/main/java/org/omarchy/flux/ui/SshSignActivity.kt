package org.omarchy.flux.ui

import android.os.Build
import android.os.Bundle
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.util.Log
import android.view.MotionEvent
import androidx.activity.compose.setContent
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.SshAgent
import org.omarchy.flux.core.SshKeys
import org.omarchy.flux.core.SshMessage
import org.omarchy.flux.core.SshRequest
import java.security.Signature

/**
 * The SSH key screen: 1 sign request from a computer, with Approve and
 * Deny. Approve opens BiometricPrompt, and the phone signs only after a
 * strong biometric or the screen lock. It shows over the lock screen, like
 * the approval screen. Windows of other apps hide while it shows, and a tap
 * that such a window covered does not approve. docs/ssh.md is the design.
 */
class SshSignActivity : FragmentActivity() {
    private sealed interface Phase {
        data object Ask : Phase
        data object Working : Phase
        data class Failed(val message: String) : Phase
    }

    private val phase = mutableStateOf<Phase>(Phase.Ask)
    private lateinit var prompt: BiometricPrompt

    // The request of the open check. A failure of the check or of the signature goes to its computer.
    private var signing: SshRequest? = null

    // True when a window of another app covered this window during the last touch.
    private var touchObscured = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        Overlays.hide(window, true)
        // BiometricPrompt must exist before the activity starts.
        prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val r = signing ?: return
                signing = null
                val s = result.cryptoObject?.signature
                if (s == null) {
                    fail(r, "The check gave no key")
                    return
                }
                try {
                    s.update(r.data)
                    SshAgent.signed(FluxCore, r, s.sign())
                    finish()
                } catch (e: Exception) {
                    Log.w(TAG, "signing failed", e)
                    fail(r, "The phone could not sign: ${e.message ?: e.javaClass.simpleName}")
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                val r = signing
                signing = null
                when (errorCode) {
                    // A cancel keeps the request open, so the user can approve or deny it again.
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_USER_CANCELED, BiometricPrompt.ERROR_CANCELED -> phase.value = Phase.Ask
                    else -> if (r != null) fail(r, errString.toString()) else phase.value = Phase.Failed(errString.toString())
                }
            }
        })
        setContent { TiledTheme { Screen() } }
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> touchObscured = Overlays.obscured(ev)
            MotionEvent.ACTION_UP -> touchObscured = touchObscured || Overlays.obscured(ev)
        }
        return super.dispatchTouchEvent(ev)
    }

    @Composable
    private fun Screen() {
        val current by SshAgent.current.collectAsStateWithLifecycle()
        val shown = track(current)
        val p by phase
        // The request ends: signed, denied, cancelled by the computer, or timed out.
        LaunchedEffect(current, p) {
            if (current == null && p !is Phase.Failed) finish()
        }
        Box(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), contentAlignment = Alignment.Center) {
            when (val ph = p) {
                is Phase.Failed -> FailedView(ph.message)
                else -> shown?.let { AskView(it, working = ph == Phase.Working) }
            }
        }
    }

    // The request that the screen shows. It stays while the flow updates.
    private var last: SshRequest? = null

    private fun track(r: SshRequest?): SshRequest? {
        if (r != null) last = r
        return last
    }

    @Composable
    private fun AskView(r: SshRequest, working: Boolean) {
        val scheme = MaterialTheme.colorScheme
        // At a large font size, the request scrolls. The warning, Approve, and Deny stay on screen below it.
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(
                Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                IconBadge(Ic.key, size = 88.dp)
                Spacer(Modifier.height(4.dp))
                Text(SshMessage.question(r), style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
                Text("Computer: ${r.computerName}", style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant, textAlign = TextAlign.Center)
                // The program comes from the computer. It is mono text in a box, so it cannot look like a part of the question.
                Surface(shape = RoundedCornerShape(8.dp), color = scheme.surfaceContainerHighest, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        r.program.ifEmpty { "An unknown program" },
                        Modifier.padding(horizontal = 12.dp, vertical = 10.dp),
                        style = MaterialTheme.typography.bodyMedium.copy(fontFamily = Mono),
                        maxLines = 6,
                    )
                }
            }
            Text(
                "Approve only if you just started this program.",
                style = MaterialTheme.typography.bodyMedium,
                color = scheme.error,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = { deny(r) }, enabled = !working) { Text("Deny") }
                Button(onClick = { start(r) }, enabled = !working, contentPadding = ButtonDefaults.ButtonWithIconContentPadding) {
                    Sym(Ic.key, size = ButtonDefaults.IconSize)
                    Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                    Text("Approve")
                }
            }
        }
    }

    @Composable
    private fun FailedView(message: String) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            IconBadge(Ic.error, size = 72.dp)
            Text(message, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            Button(onClick = { finish() }) { Text("Close") }
        }
    }

    private fun deny(r: SshRequest) {
        SshAgent.deny(FluxCore, r)
        finish()
    }

    private fun fail(r: SshRequest, message: String) {
        SshAgent.fail(FluxCore, r, message)
        phase.value = Phase.Failed(message)
    }

    private fun start(r: SshRequest) {
        if (touchObscured) {
            FluxCore.toast("Another app draws over Flux. Close that app, then approve.")
            return
        }
        // Android 10 has no screen lock check with a key, so only a biometric can sign there.
        val allowed = if (Build.VERSION.SDK_INT >= 30) BIOMETRIC_STRONG or DEVICE_CREDENTIAL else BIOMETRIC_STRONG
        if (BiometricManager.from(this).canAuthenticate(allowed) != BiometricManager.BIOMETRIC_SUCCESS) {
            fail(r, if (Build.VERSION.SDK_INT >= 30) "Set a screen lock on the phone first." else "Set up a fingerprint in the phone settings first.")
            return
        }
        phase.value = Phase.Working
        val signature: Signature
        try {
            signature = SshKeys.signer()
        } catch (e: KeyPermanentlyInvalidatedException) {
            // Android makes the key invalid when the screen lock goes away.
            SshKeys.delete()
            SshAgent.sendKey(FluxCore)
            fail(r, "The screen lock of the phone changed, so the SSH key is gone. Turn on SSH key again, and add the new key to your servers.")
            return
        } catch (e: Exception) {
            Log.w(TAG, "the SSH key failed", e)
            fail(r, "The phone could not use its SSH key: ${e.message ?: e.javaClass.simpleName}")
            return
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(SshMessage.action(r.what))
            .setSubtitle("On ${r.computerName}")
            .apply { if (r.program.isNotEmpty()) setDescription(r.program) }
            .setAllowedAuthenticators(allowed)
            // A prompt that allows the screen lock has its own button for it, and no Cancel button.
            .apply { if (allowed and DEVICE_CREDENTIAL == 0) setNegativeButtonText("Cancel") }
            .setConfirmationRequired(true)
            .build()
        signing = r
        prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
    }

    private companion object {
        const val TAG = "FluxSsh"
    }
}

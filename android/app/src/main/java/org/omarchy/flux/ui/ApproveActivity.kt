package org.omarchy.flux.ui

import android.os.Bundle
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.util.Log
import androidx.activity.compose.setContent
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
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
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.omarchy.flux.R
import org.omarchy.flux.core.ApproveKeys
import org.omarchy.flux.core.ApproveMessage
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.Approvals
import org.omarchy.flux.core.FluxCore
import java.security.Signature
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The Approve screen: 1 request from a computer, with Approve and Deny.
 * Approve opens BiometricPrompt, and the phone signs only after a strong
 * biometric. It shows over the lock screen, like the ring screen.
 * docs/approve.md is the security design.
 */
class ApproveActivity : FragmentActivity() {
    private sealed interface Phase {
        data object Ask : Phase
        data object Working : Phase
        data class Enrolled(val code: String) : Phase
        data class Failed(val message: String) : Phase
    }

    private val phase = mutableStateOf<Phase>(Phase.Ask)
    private lateinit var prompt: BiometricPrompt
    private var onSigned: ((Signature) -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        // BiometricPrompt must exist before the activity starts.
        prompt = BiometricPrompt(this, ContextCompat.getMainExecutor(this), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                val s = result.cryptoObject?.signature
                val done = onSigned
                onSigned = null
                if (s == null || done == null) {
                    phase.value = Phase.Failed("The fingerprint check gave no key. Try again.")
                    return
                }
                try {
                    done(s)
                } catch (e: Exception) {
                    Log.w(TAG, "signing failed", e)
                    phase.value = Phase.Failed("The phone could not sign the request.")
                }
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                onSigned = null
                phase.value = when (errorCode) {
                    BiometricPrompt.ERROR_NEGATIVE_BUTTON, BiometricPrompt.ERROR_USER_CANCELED, BiometricPrompt.ERROR_CANCELED -> Phase.Ask
                    else -> Phase.Failed(errString.toString())
                }
            }
        })
        setContent { TiledTheme { Screen() } }
    }

    @Composable
    private fun Screen() {
        val current by Approvals.current.collectAsStateWithLifecycle()
        val shown = track(current)
        val p by phase
        // The request ends: approved, denied, cancelled by the computer, or
        // timed out. The key code of an enrollment stays on screen.
        LaunchedEffect(current, p) {
            if (current == null && p !is Phase.Enrolled && p !is Phase.Failed) finish()
        }
        Box(Modifier.fillMaxSize().systemBarsPadding().padding(24.dp), contentAlignment = Alignment.Center) {
            when (val ph = p) {
                is Phase.Enrolled -> EnrolledView(ph.code)
                is Phase.Failed -> FailedView(ph.message)
                else -> shown?.let { AskView(it, working = ph == Phase.Working) }
            }
        }
    }

    // The request that the screen shows. It stays while the flow updates.
    private var last: ApproveRequest? = null

    private fun track(r: ApproveRequest?): ApproveRequest? {
        if (r != null) last = r
        return last
    }

    @Composable
    private fun AskView(r: ApproveRequest, working: Boolean) {
        val scheme = MaterialTheme.colorScheme
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            IconBadge(R.drawable.ic_fingerprint, size = 88.dp)
            Spacer(Modifier.height(4.dp))
            Text(ApproveMessage.question(r), style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
            val details = buildList {
                if (r.kind == ApproveRequest.Kind.Approve) {
                    if (r.tty.isNotEmpty()) add("Terminal: ${r.tty}")
                    if (r.rhost.isNotEmpty()) add("From: ${r.rhost}")
                    add("Asked at ${SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date(r.time * 1000))} by ${r.computerName}")
                } else {
                    add("Flux makes a key for ${r.computerName}. Each approval then needs your fingerprint.")
                }
            }
            for (d in details) {
                Text(d, style = MaterialTheme.typography.bodyMedium, color = scheme.onSurfaceVariant, textAlign = TextAlign.Center)
            }
            if (r.kind == ApproveRequest.Kind.Approve) {
                Text(
                    "Approve only if you just typed the command.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = scheme.error,
                    textAlign = TextAlign.Center,
                )
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = { deny(r) }, enabled = !working) { Text("Deny") }
                Button(onClick = { start(r) }, enabled = !working, contentPadding = ButtonDefaults.ButtonWithIconContentPadding) {
                    Sym(R.drawable.ic_fingerprint, size = ButtonDefaults.IconSize)
                    Spacer(Modifier.size(ButtonDefaults.IconSpacing))
                    Text(if (r.kind == ApproveRequest.Kind.Approve) "Approve" else "Enroll")
                }
            }
        }
    }

    @Composable
    private fun EnrolledView(code: String) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            IconBadge(R.drawable.ic_fingerprint, size = 88.dp)
            Text("Compare the key code", style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
            Text(
                "Check that the terminal shows this code. Then type y in the terminal.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surfaceContainerHighest, modifier = Modifier.fillMaxWidth()) {
                Text(
                    code,
                    Modifier.padding(vertical = 16.dp),
                    style = MaterialTheme.typography.headlineMedium.copy(fontFamily = Mono, letterSpacing = 2.sp),
                    color = MaterialTheme.colorScheme.primary,
                    textAlign = TextAlign.Center,
                )
            }
            Button(onClick = { finish() }) { Text("Done") }
        }
    }

    @Composable
    private fun FailedView(message: String) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            IconBadge(Ic.error, size = 72.dp)
            Text(message, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            Text(
                "The computer asks for the password.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Button(onClick = { finish() }) { Text("Close") }
        }
    }

    private fun deny(r: ApproveRequest) {
        Approvals.deny(FluxCore, r)
        finish()
    }

    private fun fail(r: ApproveRequest, message: String) {
        Approvals.fail(FluxCore, r, message)
        phase.value = Phase.Failed(message)
    }

    private fun start(r: ApproveRequest) {
        if (BiometricManager.from(this).canAuthenticate(BIOMETRIC_STRONG) != BiometricManager.BIOMETRIC_SUCCESS) {
            fail(r, "Set up a fingerprint in the phone settings first.")
            return
        }
        phase.value = Phase.Working
        val spki: ByteArray?
        val signature: Signature
        try {
            spki = if (r.kind == ApproveRequest.Kind.Enroll) ApproveKeys.create(r.computerId) else null
            signature = ApproveKeys.signer(r.computerId)
        } catch (e: KeyPermanentlyInvalidatedException) {
            ApproveKeys.delete(r.computerId)
            fail(r, "The fingerprints on the phone changed. Enroll again with: sudo flux approve enroll")
            return
        } catch (e: Exception) {
            Log.w(TAG, "the approval key failed", e)
            fail(r, "The phone could not use its approval key.")
            return
        }
        onSigned = { s ->
            if (spki == null) {
                s.update(ApproveMessage.approval(r))
                Approvals.approve(FluxCore, r, s.sign())
                finish()
            } else {
                s.update(ApproveMessage.enrollment(r, spki))
                Approvals.enrolled(FluxCore, r, spki, s.sign())
                phase.value = Phase.Enrolled(ApproveMessage.fingerprint(spki))
            }
        }
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(if (spki == null) "Approve ${r.service}" else "Enroll this phone")
            .setSubtitle("For ${r.user} on ${r.host}")
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(true)
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
    }

    private companion object {
        const val TAG = "FluxApprove"
    }
}

package org.omarchy.flux.ui

import android.app.KeyguardManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.font.FontWeight
import androidx.core.app.RemoteInput
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.omarchy.flux.core.AgentDialog
import org.omarchy.flux.core.AgentDialogs
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.QuestionChanged
import org.omarchy.flux.core.replyMatches
import org.omarchy.flux.service.FluxService

/**
 * Answers an agent from its notification: no UI. A choice action or Reply
 * starts it. From Android 12, Android asks for the unlock before it starts.
 * When the device is still locked, it asks Android to dismiss the lock screen
 * and sends only after the dismiss succeeds. When the dismiss fails or the
 * user cancels it, it sends nothing and opens the thread. It reads the pane again and sends only when the dialog is still the one
 * of the notification. Else it sends nothing and opens the thread, with the
 * line that says the question changed. It uses Theme.Flux.Invisible, as
 * [ClipboardSendActivity] does.
 */
class AgentAnswerActivity : ComponentActivity() {
    private var started = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        FluxService.start(this)
        // A recreation must not send a second answer.
        if (savedInstanceState != null || started) {
            finish()
            return
        }
        started = true
        val device = intent.getStringExtra(EXTRA_DEVICE).orEmpty()
        val pane = intent.getStringExtra(EXTRA_PANE).orEmpty()
        if (device.isEmpty() || !PANE_ID.matches(pane)) {
            finish()
            return
        }
        // Only SystemUI enforces the unlock of the action. A caller that skips it meets the lock screen here.
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard == null || keyguard.isDeviceLocked) {
            if (keyguard == null) {
                openThread(device, pane, changed = false)
                return
            }
            keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() = proceed(device, pane)
                override fun onDismissCancelled() = openThread(device, pane, changed = false)
                override fun onDismissError() = openThread(device, pane, changed = false)
            })
            return
        }
        proceed(device, pane)
    }

    private fun proceed(device: String, pane: String) {
        val choice = intent.getStringExtra(EXTRA_CHOICE).orEmpty()
        val dialog = intent.getStringExtra(EXTRA_DIALOG).orEmpty()
        val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(KEY_TEXT)?.toString()?.trim()
        // A Reply with an empty field sends nothing.
        if (choice.isEmpty() && text != null && text.isEmpty()) {
            finish()
            return
        }
        answer(device, pane, choice, dialog, text)
    }

    /** True when the agent still waits and the computer accepts input from this phone. */
    private fun ready(device: String, pane: String): Boolean = FluxCore.locked {
        val d = FluxCore.device(device)
        d?.herdr?.control == true && d.herdr?.agent(pane)?.status == AgentStatus.Blocked
    }

    private fun answer(device: String, pane: String, choice: String, dialogId: String, text: String?) {
        val app = applicationContext
        if (!ready(device, pane)) {
            openThread(device, pane, changed = false)
            return
        }
        if (choice.isNotEmpty()) {
            AgentDialogs.verify(
                FluxCore, device, pane, dialogId,
                onSame = { d -> sendChoice(app, device, pane, choice, d) },
                onChanged = { d -> openThread(device, pane, changed = d != null) },
            )
        } else if (text != null) {
            AgentDialogs.peek(FluxCore, device, pane) { d ->
                // Reply sends only while the dialog is the one of the notification.
                if (replyMatches(d, dialogId) && ready(device, pane)) {
                    HerdrSync.sendPrompt(FluxCore, device, pane, text, answer = true)
                    done(app, device, pane)
                } else {
                    openThread(device, pane, changed = d != null)
                }
            }
        } else {
            openThread(device, pane, changed = false)
        }
    }

    private fun sendChoice(app: android.content.Context, device: String, pane: String, choice: String, d: AgentDialog) {
        val c = d.choices.firstOrNull { it.key == choice }
        if (c == null || !ready(device, pane)) {
            openThread(device, pane, changed = true)
            return
        }
        HerdrSync.sendKeys(FluxCore, device, pane, c.keys)
        done(app, device, pane)
    }

    /** Removes the notification after a send. A send that failed opens the thread. */
    private fun done(app: android.content.Context, device: String, pane: String) {
        val failed = FluxCore.locked { FluxCore.device(device)?.herdrReply?.let { !it.sending && it.error != null } == true }
        if (failed) {
            openThread(device, pane, changed = false)
            return
        }
        Android.cancelAgent(app, device, pane)
        runOnUiThread { finish() }
    }

    private fun openThread(device: String, pane: String, changed: Boolean) {
        Android.cancelAgent(applicationContext, device, pane)
        val open = Intent(this, MainActivity::class.java)
            .setAction(MainActivity.ACTION_OPEN_AGENT)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(MainActivity.EXTRA_DEVICE, device)
            .putExtra(MainActivity.EXTRA_PANE, pane)
            .putExtra(MainActivity.EXTRA_CHANGED, changed)
        runOnUiThread {
            startActivity(open)
            finish()
        }
    }

    companion object {
        const val EXTRA_DEVICE = "flux.answer.device"
        const val EXTRA_PANE = "flux.answer.pane"
        const val EXTRA_CHOICE = "flux.answer.choice"
        const val EXTRA_DIALOG = "flux.answer.dialog"

        /** The key of the RemoteInput of Reply. */
        const val KEY_TEXT = "flux.answer.text"

        private val PANE_ID = Regex("^[A-Za-z0-9_.:-]{1,64}$")
    }
}

/**
 * The line that the dock of an agent thread shows after a notification
 * answer found a new question: "The question changed. Pick again." It goes
 * when the thread closes.
 */
@Composable
internal fun QuestionChangedNote(deviceId: String, pane: String) {
    val shown by QuestionChanged.flow.collectAsStateWithLifecycle()
    DisposableEffect(deviceId, pane) { onDispose { QuestionChanged.clear(deviceId, pane) } }
    if (!QuestionChanged.isShown(shown, deviceId, pane)) return
    val shape = RoundedCornerShape(16.dp)
    Box(Modifier.fillMaxWidth().background(Tn.bg, shape).border(BorderStroke(1.dp, Tn.lineHi), shape).padding(horizontal = 16.dp, vertical = 14.dp)) {
        T("The question changed. Pick again.", size = 15, weight = FontWeight.SemiBold, color = Tn.text)
    }
}

package org.omarchy.flux.ui

import android.app.Activity
import android.app.KeyguardManager
import android.os.SystemClock
import android.view.MotionEvent
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.motionEventSpy
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.withResumed
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.core.StreamRequest
import org.omarchy.flux.core.StreamRequests
import kotlin.coroutines.resume

/**
 * The prompt of a request from a computer to start the webcam or the mic
 * of this phone. Start is the consent of the user. The prompt hides the
 * windows of other apps, and it refuses a tap while another app draws over
 * it, because an overlay can hide the prompt so that the user taps Start.
 *
 * The computer chooses when the prompt shows. So Start takes a tap only
 * [StreamRequests.ARM_MS] after the sheet is fully open and Flux is in
 * front, and only a tap that starts after that time. A tap that the user
 * already makes when the prompt shows does not start the stream.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun StreamRequestSheet(r: StreamRequest, onStart: () -> Unit, onDismiss: () -> Unit) {
    HideOverlays()
    var fullyOpen by remember { mutableStateOf(false) }
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsState()
    val inFront = lifecycle.isAtLeast(Lifecycle.State.RESUMED)
    // The uptime from which Start takes a tap. MotionEvent.getEventTime uses the same clock.
    var armedAt by remember { mutableLongStateOf(Long.MAX_VALUE) }
    LaunchedEffect(fullyOpen, inFront) {
        armedAt = Long.MAX_VALUE
        if (!fullyOpen || !inFront) return@LaunchedEffect
        delay(StreamRequests.ARM_MS)
        armedAt = SystemClock.uptimeMillis()
    }
    // The sheet has its own window, so the touch check of MainActivity does not see its touches.
    var obscured by remember { mutableStateOf(false) }
    // The uptime of the last touch down that no tap used yet. A click of TalkBack has no touch.
    var downAt by remember { mutableLongStateOf(Long.MAX_VALUE) }
    val icon = when (r.kind) {
        StreamKind.Webcam -> Ic.videocam
        StreamKind.Mic -> Ic.micFill
    }
    val body = when (r.kind) {
        StreamKind.Webcam -> "The camera stays off until you tap Start webcam. Flux then opens the Webcam page and streams to ${r.computer}."
        StreamKind.Mic -> "The microphone stays off until you tap Start the mic. Flux then opens the Mic page and streams to ${r.computer}."
    }
    FluxSheet(onDismiss, onFullyOpen = { fullyOpen = it }) {
        Column(
            Modifier.fillMaxWidth()
                .motionEventSpy { ev ->
                    when (ev.actionMasked) {
                        MotionEvent.ACTION_DOWN -> {
                            downAt = ev.eventTime
                            obscured = Overlays.obscured(ev)
                        }
                        MotionEvent.ACTION_UP -> obscured = obscured || Overlays.obscured(ev)
                    }
                }
                .padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                IconBadge(icon, container = Tn.accentTile, content = Tn.blue, size = 48.dp)
                T(
                    r.kind.title(r.computer), Modifier.weight(1f).semantics { heading() },
                    size = 20, weight = FontWeight.SemiBold, lineHeight = 1.2f,
                )
            }
            T(body, size = 14, color = Tn.sub, lineHeight = 1.35f)
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                FluxButton("Not now", onDismiss, Modifier.weight(1f).fillMaxHeight(), kind = ButtonKind.Outlined)
                FluxButton(
                    r.kind.startLabel(),
                    {
                        val down = downAt
                        downAt = Long.MAX_VALUE
                        when {
                            // The finger was down before Start was ready.
                            down < armedAt -> Unit
                            obscured -> FluxCore.toast("Another app draws over Flux. Close that app, then try again.")
                            else -> onStart()
                        }
                    },
                    Modifier.weight(1f).fillMaxHeight(),
                    icon = icon,
                    enabled = armedAt != Long.MAX_VALUE,
                )
            }
        }
    }
}

/**
 * The start after a tap on Start in a stream request, for the page of
 * [deviceId] and [kind]. The value is true from the tap until the page
 * starts the stream. It lives only as long as the page, and at most
 * [StreamRequests.START_WAIT_MS].
 */
@Composable
fun rememberStreamStart(deviceId: String, kind: StreamKind): MutableState<Boolean> {
    val wanted = remember(deviceId) { mutableStateOf(false) }
    LaunchedEffect(deviceId) {
        StreamRequests.start.collect { if (StreamRequests.take(deviceId, kind)) wanted.value = true }
    }
    // A start that cannot run in time, for example while the computer is not reachable, goes away.
    LaunchedEffect(wanted.value) {
        if (!wanted.value) return@LaunchedEffect
        delay(StreamRequests.START_WAIT_MS)
        wanted.value = false
    }
    return wanted
}

/**
 * Starts the stream of a tap on Start when the page is [ready]. [start] is
 * the start path of the Start button of the page. The start waits until
 * the activity is in front and the phone is unlocked. On a locked phone,
 * Android asks the user to unlock it, and Flux does not bypass the lock.
 * A change of [key], such as new settings, starts the wait again.
 */
@Composable
fun StartAfterTap(wanted: MutableState<Boolean>, ready: Boolean, kind: StreamKind, key: Any? = null, start: () -> Unit) {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val activity = LocalActivity.current
    val run by rememberUpdatedState(start)
    LaunchedEffect(wanted.value, ready, key) {
        if (!wanted.value || !ready) return@LaunchedEffect
        // The saved settings reach the page before the start.
        withFrameNanos { }
        if (awaitStreamStart(lifecycle, activity)) {
            run()
        } else {
            FluxCore.toast("Unlock the phone, then press ${kind.startLabel()}")
        }
        wanted.value = false
    }
}

/**
 * Waits until the activity is in front and the phone is unlocked. Android
 * gives the camera and the microphone to a foreground service only while
 * the app is visible or after an action of the user, so the stream starts
 * from the visible page. It returns false when the user does not unlock
 * the phone.
 */
suspend fun awaitStreamStart(lifecycle: Lifecycle, activity: Activity?): Boolean {
    lifecycle.withResumed { }
    val keyguard = activity?.getSystemService(KeyguardManager::class.java) ?: return false
    if (keyguard.isKeyguardLocked && !unlock(activity, keyguard)) return false
    lifecycle.withResumed { }
    return !keyguard.isKeyguardLocked
}

/** Asks Android to show the unlock screen. It returns true after the user unlocks the phone. */
private suspend fun unlock(activity: Activity, keyguard: KeyguardManager): Boolean = suspendCancellableCoroutine { c ->
    keyguard.requestDismissKeyguard(
        activity,
        object : KeyguardManager.KeyguardDismissCallback() {
            override fun onDismissSucceeded() {
                if (c.isActive) c.resume(true)
            }

            override fun onDismissCancelled() {
                if (c.isActive) c.resume(false)
            }

            override fun onDismissError() {
                if (c.isActive) c.resume(false)
            }
        },
    )
}

package org.omarchy.flux.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.FlowRowScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.InboxReach
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.stream.LiveStream
import org.omarchy.flux.stream.LiveStreams
import org.omarchy.flux.stream.streamSentence

/** A webcam or mic stream in the Inbox. [name] is the name of its computer. */
class StreamNotice(val stream: LiveStream, val name: String)

/**
 * What the Inbox tells next to its items: the webcam and the mic streams
 * of this phone, a new pairing, the computers in scope that are not
 * reachable, the items on other computers that need the user, and the
 * notification question. [streams] show in each scope. [scopeName] is the name of the
 * computer in scope, or null for all computers. [elsewhere] counts the
 * items out of scope that need the user. [paired] is the name of the
 * computer in scope while the Inbox shows its success state after a new
 * pairing, or null. [connecting] is true while the computers in scope that
 * are not online can still connect, see [org.omarchy.flux.core.UiState.connecting].
 */
class InboxNotices(
    val reach: InboxReach,
    val onWifi: Boolean,
    val scopeName: String?,
    val elsewhere: Int,
    val notify: NotifyAsk,
    val paired: String? = null,
    val connecting: Boolean = false,
    val streams: List<StreamNotice> = emptyList(),
)

/** The line of a stream in the Inbox, for example "The mic streams to omarchy. It keeps running when you leave Flux." */
internal fun streamLine(s: StreamNotice): String =
    streamSentence(listOf(s.stream.kind), s.name, s.stream.live) + ". It keeps running when you leave Flux."

/** The title of an Inbox with nothing to do. In a scope, it names the computer. */
internal fun nothingText(n: InboxNotices): String = n.scopeName?.let { "Nothing on $it needs you" } ?: "Nothing needs you"

/** The title of an Inbox while the computers in scope connect. */
internal fun connectingTitle(reach: InboxReach): String =
    reach.offline.singleOrNull()?.let { "Connecting to ${it.name}" } ?: "Connecting to your computers"

/** The title of an Inbox with no computer online. */
internal fun offlineTitle(reach: InboxReach): String =
    reach.offline.singleOrNull()?.let { "${it.name} is not reachable" } ?: "No computer is reachable"

/** The next step when a computer is not reachable. */
internal fun offlineHint(onWifi: Boolean): String =
    if (onWifi) {
        "Check that Flux runs on the computer, and that this phone can reach it on this network or on Tailscale."
    } else {
        "This phone is not on Wi-Fi. Connect to the network of the computer, or turn on Tailscale."
    }

/**
 * True when the Inbox tells that computers in scope are not reachable.
 * While the computers connect, the Inbox does not call them not reachable.
 */
internal fun offlineShows(n: InboxNotices): Boolean = !n.connecting && n.reach.offline.isNotEmpty()

/** The line for the computers in scope that are not reachable while the Inbox shows other items. */
internal fun offlineLine(n: InboxNotices): String {
    val wifi = if (n.onWifi) "" else "This phone is not on Wi-Fi. "
    val off = n.reach.offline
    return wifi + (off.singleOrNull()?.let { "${it.name} is not reachable. Its agents do not show here." }
        ?: "${off.size} computers are not reachable. Their agents do not show here.")
}

/** Why Flux asks for the notification permission. */
internal const val NOTIFY_WHY = "Allow notifications, so that Flux can show when an agent needs you."

/** The line for the items on other computers that need the user. */
internal fun elsewhereText(count: Int): String =
    if (count == 1) "1 item on another computer needs you" else "$count items on other computers need you"

/**
 * The notices of the Inbox, each with its next step. [offline] is false
 * when the large tile or the status line already tells that computers are
 * not reachable. [paired] is false when the large tile already shows the
 * success state of a new pairing, and with it the notification question.
 * While the computers connect, the Inbox does not call them not reachable.
 */
@Composable
internal fun InboxNoticeList(n: InboxNotices, actions: InboxActions, offline: Boolean = true, paired: Boolean = true) {
    // Green marks a live camera or microphone, as the privacy dot of Android does.
    for (s in n.streams) {
        val kind = s.stream.kind
        Notice(
            { Sym(if (kind == StreamKind.Webcam) Ic.videocam else Ic.micFill, tint = Tn.green, size = 18.dp) },
            streamLine(s),
            Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            color = Tn.text,
        ) {
            FluxButton("Open", { actions.open(Route(s.stream.deviceId, streamPage(kind))) }, kind = ButtonKind.Text)
            FluxButton(if (kind == StreamKind.Webcam) "Stop webcam" else "Stop the mic", { LiveStreams.stop(kind) }, kind = ButtonKind.Text)
        }
    }
    if (paired && n.paired != null) {
        Notice(
            { Sym(Ic.checkCircle, tint = Tn.green, size = 18.dp) },
            "${n.paired} is paired. What waits for you on ${n.paired} shows here first.",
            Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            color = Tn.text,
        ) {}
    }
    if (n.elsewhere > 0) {
        Notice({ Dot(Tn.red) }, elsewhereText(n.elsewhere), color = Tn.text) {
            FluxButton("Show all computers", actions.showAll, kind = ButtonKind.Text)
        }
    }
    if (offline && offlineShows(n)) {
        Notice({ LinkDot(false) }, offlineLine(n), inline = true) {
            FluxButton("Retry", { FluxCore.rediscover() }, kind = ButtonKind.Text)
        }
    }
    when (n.notify) {
        NotifyAsk.None -> Unit
        NotifyAsk.Allow -> if (paired) {
            Notice({ Sym(Ic.notifications, tint = Tn.yellow, size = 18.dp) }, NOTIFY_WHY) {
                FluxButton("Allow", actions.allowNotifications, kind = ButtonKind.Text)
                FluxButton("Hide", actions.hideNotifications, kind = ButtonKind.Text)
            }
        }
        NotifyAsk.Settings -> Notice(
            { Sym(Ic.notifications, tint = Tn.yellow, size = 18.dp) },
            "Notifications are off for Flux, so sudo approvals and agent alerts do not reach this phone. Turn them on in the settings of Android.",
        ) {
            FluxButton("Open settings", actions.allowNotifications, kind = ButtonKind.Text)
            FluxButton("Hide", actions.hideNotifications, kind = ButtonKind.Text)
        }
    }
}

/**
 * 1 notice: a mark, the text, and the actions under the text. The actions
 * wrap at a large font size. An [inline] notice shows its actions at the
 * end of the text, in the same row.
 */
@Composable
private fun Notice(
    mark: @Composable () -> Unit,
    text: String,
    modifier: Modifier = Modifier,
    color: Color = Tn.sub,
    inline: Boolean = false,
    actions: @Composable FlowRowScope.() -> Unit,
) {
    if (inline) {
        Row(modifier.fillMaxWidth().padding(start = 4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.padding(top = 5.dp), contentAlignment = Alignment.Center) { mark() }
                T(text, size = 13, color = color, lineHeight = 1.35f)
            }
            FlowRow(content = actions)
        }
        return
    }
    Row(modifier.fillMaxWidth().padding(horizontal = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.padding(top = 5.dp), contentAlignment = Alignment.Center) { mark() }
        Column(Modifier.weight(1f)) {
            T(text, size = 13, color = color, lineHeight = 1.35f)
            // The buttons line up with the text. The padding of a text button holds the offset.
            FlowRow(Modifier.offset(x = (-12).dp), content = actions)
        }
    }
}

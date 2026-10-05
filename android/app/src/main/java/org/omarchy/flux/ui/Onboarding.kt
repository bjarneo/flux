package org.omarchy.flux.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.UiState

/** The install guide of Flux on GitHub. It covers the package and `flux-cli setup`. */
private const val INSTALL_GUIDE = "https://github.com/bjarneo/flux/blob/master/docs/install.md"

/** The command that sets up Flux for the desktop user and starts fluxd. */
private const val SETUP_COMMAND = "flux-cli setup"

/**
 * The large tile of an empty Inbox. It takes the place of the master tile,
 * so it has the active border.
 */
@Composable
internal fun EmptyTile(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Tile(
        modifier.fillMaxWidth(),
        border = activeBorder(),
        padding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        content = content,
    )
}

/**
 * The Inbox before the first pairing: what Flux is, how to set up Flux on
 * the Omarchy computer, and the computers on the network with their pair
 * action. A tap on a computer starts the same pairing as in Computers.
 * When the phone already found a computer, the pair step comes first, and
 * the setup shrinks to the command and the guide.
 */
@Composable
internal fun PairGuide(state: UiState, actions: InboxActions) {
    val available = state.devices.filter { !it.paired && it.online }
    EmptyTile {
        T("Pair your Omarchy computer", Modifier.semantics { heading() }, size = 22, weight = FontWeight.SemiBold)
        T(
            "Flux lets this phone answer agents, approve sudo, and send files to your Omarchy computer.",
            size = 14, color = Tn.sub, lineHeight = 1.35f,
        )
        if (available.isEmpty()) {
            GuideStep("1. Set up Flux on the computer") {
                T("Install the Flux package on the computer. Then start fluxd for your desktop user:", size = 14, color = Tn.sub, lineHeight = 1.35f)
                CommandBlock(SETUP_COMMAND)
                InstallGuideButton()
            }
            GuideStep("2. Pair this phone") { PairStep(state, available, actions) }
        } else {
            GuideStep("Pair this phone") { PairStep(state, available, actions) }
            GuideStep("Another computer") {
                SetupLine()
                InstallGuideButton()
            }
        }
    }
}

/**
 * The pair step of the guide: the computers on the network, and the scan.
 * The hint of the scan names the setup command. When the phone is not on
 * Wi-Fi, the warning above already tells what to do.
 */
@Composable
private fun PairStep(state: UiState, available: List<DeviceUi>, actions: InboxActions) {
    T("Tap the computer. Then compare the key on both screens.", size = 14, color = Tn.sub, lineHeight = 1.35f)
    if (!state.onWifi) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(Ic.wifiOff, tint = Tn.yellow, size = 18.dp)
            T("This phone is not on Wi-Fi. Connect it to the network of the computer.", Modifier.weight(1f), size = 13, color = Tn.sub)
        }
    }
    for (d in available) AvailableRow(d) { actions.pair(d) }
    ScanRow(
        state, none = available.isEmpty(), first = true,
        hint = if (state.onWifi) "Check that you ran $SETUP_COMMAND on the computer, and that both are on the same Wi-Fi." else null,
    ) { FluxCore.scan() }
}

/** 1 line that names the setup command, with the command in mono. */
@Composable
private fun SetupLine() {
    val text = buildAnnotatedString {
        append("To add a computer, run ")
        withStyle(SpanStyle(fontFamily = Mono, color = Tn.text)) { append(SETUP_COMMAND) }
        append(" on it.")
    }
    BasicText(text, style = TextStyle(color = Tn.sub, fontSize = 14.sp, lineHeight = (14 * 1.35f).sp))
}

/** Opens the install guide on GitHub. The text of the button lines up with the text above. */
@Composable
private fun InstallGuideButton() {
    val context = LocalContext.current
    // The padding of a text button holds the offset.
    FluxButton(
        "Read the install guide",
        { openLink(context, INSTALL_GUIDE) },
        Modifier.offset(x = (-12).dp),
        kind = ButtonKind.Text,
        icon = Ic.openInNew,
    )
}

/** 1 step of the pairing guide: a heading and its content. */
@Composable
private fun GuideStep(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T(title, Modifier.semantics { heading() }, size = 16, weight = FontWeight.SemiBold)
        content()
    }
}

/**
 * The success state of a new pairing. It takes the place of the empty
 * Inbox of the new computer for a short time. TalkBack reads it when it
 * shows. While Android can ask for the notification permission, the tile
 * also tells why, because the tile stays above the dialog of Android.
 */
@Composable
internal fun PairedTile(name: String, notify: NotifyAsk, actions: InboxActions) {
    EmptyTile {
        Column(
            Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Sym(Ic.checkCircle, tint = Tn.green, size = 28.dp)
            T("$name is paired", size = 22, weight = FontWeight.SemiBold)
            T(
                "What waits for you on $name shows here first. Send and Control have the tools for $name.",
                size = 14, color = Tn.sub, lineHeight = 1.35f,
            )
        }
        if (notify == NotifyAsk.Allow) {
            Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Sym(Ic.notifications, tint = Tn.yellow, size = 18.dp, modifier = Modifier.padding(top = 2.dp))
                Column(Modifier.weight(1f)) {
                    T(NOTIFY_WHY, size = 14, lineHeight = 1.35f)
                    // The buttons line up with the text, and they wrap at a large font size.
                    FlowRow(Modifier.offset(x = (-12).dp)) {
                        FluxButton("Allow", actions.allowNotifications, kind = ButtonKind.Text)
                        FluxButton("Hide", actions.hideNotifications, kind = ButtonKind.Text)
                    }
                }
            }
        }
    }
}

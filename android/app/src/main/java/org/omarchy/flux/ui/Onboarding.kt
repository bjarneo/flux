package org.omarchy.flux.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
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
 */
@Composable
internal fun PairGuide(state: UiState, actions: InboxActions) {
    val context = LocalContext.current
    val available = state.devices.filter { !it.paired && it.online }
    EmptyTile {
        T("Pair your Omarchy computer", Modifier.semantics { heading() }, size = 22, weight = FontWeight.SemiBold)
        T(
            "Flux lets this phone answer agents, approve sudo, and send files on your Omarchy computer.",
            size = 14, color = Tn.sub, lineHeight = 1.35f,
        )
        GuideStep("1. Set up Flux on the computer") {
            T("Install the Flux package on the computer. Then start fluxd for your desktop user:", size = 14, color = Tn.sub, lineHeight = 1.35f)
            CommandLine(SETUP_COMMAND)
            // The text of the button lines up with the text above. The padding of a text button holds the offset.
            TextButton(
                onClick = {
                    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, INSTALL_GUIDE.toUri())) }
                        .onFailure { FluxCore.toast("No app on this phone opens web links") }
                },
                modifier = Modifier.offset(x = (-12).dp),
            ) {
                Sym(Ic.openInNew, size = 18.dp)
                Text("Read the install guide", Modifier.padding(start = 8.dp))
            }
        }
        GuideStep("2. Pair this phone") {
            T("Tap the computer. Then compare the key on both screens.", size = 14, color = Tn.sub, lineHeight = 1.35f)
            if (!state.onWifi) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Sym(Ic.wifiOff, tint = Tn.yellow, size = 18.dp)
                    T("This phone is not on Wi-Fi. Connect it to the network of the computer.", Modifier.weight(1f), size = 13, color = Tn.sub)
                }
            }
            for (d in available) AvailableRow(d) { actions.pair(d) }
            ScanRow(state, none = available.isEmpty(), first = true) { FluxCore.scan() }
        }
    }
}

/** 1 step of the pairing guide: a numbered heading and its content. */
@Composable
private fun GuideStep(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T(title, Modifier.semantics { heading() }, size = 16, weight = FontWeight.SemiBold)
        content()
    }
}

/** A command to type in a terminal on the computer. */
@Composable
private fun CommandLine(command: String) {
    val shape = RoundedCornerShape(8.dp)
    T(
        command,
        Modifier.fillMaxWidth().clip(shape).background(Tn.bg).border(1.dp, Tn.line, shape).padding(horizontal = 12.dp, vertical = 12.dp),
        size = 15, family = Mono,
    )
}

/**
 * The success state of a new pairing. It takes the place of the empty
 * Inbox of the new computer for a short time. TalkBack reads it when it
 * shows.
 */
@Composable
internal fun PairedTile(name: String) {
    EmptyTile(Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite }) {
        Sym(Ic.checkCircle, tint = Tn.green, size = 28.dp)
        T("$name is paired", size = 22, weight = FontWeight.SemiBold)
        T(
            "What waits for you on $name shows here first. Send and Control have the tools for $name.",
            size = 14, color = Tn.sub, lineHeight = 1.35f,
        )
    }
}

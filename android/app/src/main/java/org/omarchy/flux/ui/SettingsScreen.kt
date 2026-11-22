package org.omarchy.flux.ui

import android.os.Build
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.omarchy.flux.BuildConfig
import org.omarchy.flux.R
import org.omarchy.flux.core.ApproveAtOnce
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.ScrollMode
import org.omarchy.flux.core.SshKeys
import org.omarchy.flux.core.ThemeMode
import org.omarchy.flux.core.UiState

/**
 * The settings of the app, above Chats. Each row is a setting of this
 * phone, and it applies to every computer: Sync, the SSH key, the theme,
 * the touchpad scrolling, the fingerprint check, Turn off Flux, and About
 * Flux. They moved here from Computers. A wide window shows the rows in 2
 * columns.
 */
@Composable
fun SettingsScreen(state: UiState, onBack: () -> Unit, onSync: () -> Unit, onSsh: () -> Unit, onAbout: () -> Unit) {
    var turningOff by remember { mutableStateOf(false) }
    val (on, total) = syncSummary(state)
    val ssh by SshKeys.info.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { SshKeys.load() } }
    val wide = rememberWideWindow()
    val left: List<@Composable () -> Unit> = listOf(
        { SettingRow(Ic.sync, "Sync", "$on of $total switches on. They apply to every computer.", onClick = onSync) },
        { SettingRow(Ic.key, "SSH key", sshSummary(ssh), onClick = onSsh) },
        { ThemeRow(state) },
    )
    val right: List<@Composable () -> Unit> = listOf(
        { ScrollRow(state) },
        { AtOnceRow(state) },
        // The row runs an action and opens no screen, so it has no chevron. A dialog asks first.
        { SettingRow(Ic.power, "Turn off Flux", "This phone stops all connections until you turn Flux on again.", chevron = false) { turningOff = true } },
        { SettingRow(Ic.info, "About Flux", aboutVersion(BuildConfig.VERSION_NAME, BuildConfig.DEBUG), onClick = onAbout) },
    )
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.statusBarsPadding()) { ScreenHeader("Settings", "", onBack = onBack) }
        val pad = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = 28.dp)
        if (wide) {
            Row(pad, horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TileGap)) { for (r in left) r() }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TileGap)) { for (r in right) r() }
            }
        } else {
            Column(pad, verticalArrangement = Arrangement.spacedBy(TileGap)) { for (r in left + right) r() }
        }
    }
    if (turningOff) {
        ConfirmDialog(
            "Turn off Flux?",
            "This phone stops all connections to the computers. Approvals, agent alerts, and the clipboard do not reach this phone until you turn Flux on again.",
            "Turn off",
            onCancel = { turningOff = false },
            onConfirm = {
                turningOff = false
                FluxCore.setEnabled(false)
            },
            icon = Ic.power,
            destructive = true,
        )
    }
}

/** A row that opens a setting, with a chevron, or that runs an action, with no chevron. */
@Composable
private fun SettingRow(@DrawableRes icon: Int, title: String, detail: String, chevron: Boolean = true, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(start = 14.dp, end = 10.dp, top = 10.dp, bottom = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(icon, tint = Tn.blue, size = 22.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, size = 15, weight = FontWeight.SemiBold)
            T(detail, size = 13, color = Tn.sub, lineHeight = 1.3f)
        }
        if (chevron) Sym(Ic.chevron, tint = Tn.sub, size = 20.dp)
    }
}

/** 1 choice of a [ChoiceGroup]. [detail] shows under the label. */
private class Choice(val label: String, @DrawableRes val icon: Int, val selected: Boolean, val detail: String?, val onSelect: () -> Unit)

/** A setting with 1 choice of [choices], as radio rows under [title]. */
@Composable
private fun ChoiceGroup(title: String, choices: List<Choice>) {
    Column(
        Modifier.fillMaxWidth().clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape).padding(vertical = 6.dp),
    ) {
        T(
            title, Modifier.padding(start = 14.dp, end = 14.dp, top = 8.dp, bottom = 4.dp).semantics { heading() },
            size = 15, weight = FontWeight.SemiBold,
        )
        Column(Modifier.selectableGroup()) {
            for (c in choices) {
                val tint = if (c.selected) Tn.blue else Tn.sub
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 52.dp)
                        .selectable(selected = c.selected, role = Role.RadioButton, onClick = c.onSelect)
                        .padding(horizontal = 14.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Sym(c.icon, tint = tint, size = 22.dp)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        T(c.label, size = 15, weight = if (c.selected) FontWeight.SemiBold else FontWeight.Normal)
                        c.detail?.let { T(it, size = 13, color = Tn.sub, lineHeight = 1.3f) }
                    }
                    // The row takes the tap and gives the state to TalkBack, so the mark only shows it.
                    Sym(if (c.selected) Ic.radioOn else Ic.radioOff, tint = tint, size = 22.dp)
                }
            }
        }
    }
}

/**
 * The theme of the app, as 1 choice of [ThemeChoices]. The Computer choice
 * names the theme that it draws now and the computer that sent it.
 */
@Composable
private fun ThemeRow(state: UiState) {
    val computerLine = computerThemeLine(state, isSystemInDarkTheme())
    ChoiceGroup(
        "Theme",
        ThemeChoices.map { (mode, label, icon) ->
            Choice(label, icon, mode == state.theme, if (mode == ThemeMode.Computer) computerLine else null) { FluxCore.setTheme(mode) }
        },
    )
}

/** The scroll direction of the touchpad screen, see [ScrollMode]. */
@Composable
private fun ScrollRow(state: UiState) {
    fun choice(mode: ScrollMode, label: String, @DrawableRes icon: Int, detail: String) =
        Choice(label, icon, mode == state.touchpadScroll, detail) { FluxCore.setTouchpadScroll(mode) }
    ChoiceGroup(
        "Touchpad scrolling",
        listOf(
            choice(ScrollMode.Computer, "Computer", Ic.desktop, "Scrolls like the touchpad of the computer."),
            choice(ScrollMode.Natural, "Natural", Ic.touchApp, "The content moves with the fingers."),
            choice(ScrollMode.Traditional, "Traditional", Ic.south, "Fingers down scroll down, like a scroll wheel."),
        ),
    )
}

/** The switch that opens the fingerprint prompt at once. It stays off on Android 10 and 11. */
@Composable
private fun AtOnceRow(state: UiState) {
    val supported = ApproveAtOnce.supported(Build.VERSION.SDK_INT)
    val on = supported && state.approveAtOnce
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
            .alpha(if (supported) 1f else DimAlpha)
            .toggleable(value = on, enabled = supported, role = Role.Switch, onValueChange = { FluxCore.setApproveAtOnce(it) })
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(R.drawable.ic_fingerprint, tint = if (on) Tn.blue else Tn.sub, size = 22.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T("Open the fingerprint check at once", size = 15, weight = FontWeight.SemiBold)
            T(
                if (supported) "Opens the fingerprint prompt over the approval screen when a sudo request arrives." else "Needs Android 12 or later.",
                size = 13, color = Tn.sub, lineHeight = 1.3f,
            )
        }
        // The row takes the tap and gives the state to TalkBack, so the switch only shows it.
        Switch(checked = on, onCheckedChange = null, enabled = supported)
    }
}

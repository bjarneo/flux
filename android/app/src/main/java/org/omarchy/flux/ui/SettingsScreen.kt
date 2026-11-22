package org.omarchy.flux.ui

import android.os.Build
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
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
import org.omarchy.flux.core.SettingsContext
import org.omarchy.flux.core.SettingsGroup
import org.omarchy.flux.core.GroupModel
import org.omarchy.flux.core.SshKeyInfo
import org.omarchy.flux.core.settingsGroups
import org.omarchy.flux.core.SshKeys
import org.omarchy.flux.core.ThemeMode
import org.omarchy.flux.core.UiState

/** A tile with a border, or nothing when [on] is false. A row inside an open group draws no tile of its own. */
@Composable
internal fun Modifier.tile(on: Boolean = true): Modifier =
    if (on) clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape) else this

/** The icon of each group row. */
private fun groupIcon(group: SettingsGroup): Int = when (group) {
    SettingsGroup.Send -> Ic.sync
    SettingsGroup.Alerts -> Ic.notifications
    SettingsGroup.Phone -> Ic.phone
    SettingsGroup.Security -> R.drawable.ic_shield
    SettingsGroup.Look -> R.drawable.ic_palette
}

/** The window height from which Turn off Flux and About Flux stay at the bottom of the window. */
private val PinFooterHeight = 560.dp

/**
 * The settings of the app, above Chats. They are settings of this phone,
 * and they apply to every computer. 5 groups hold them, and a tap on a
 * group row opens the group in place. Only 1 group is open. Turn off Flux
 * and About Flux stand apart at the end. A wide window in landscape shows the groups
 * in 2 columns. The SSH key and About open above Settings.
 */
@Composable
fun SettingsScreen(state: UiState, onBack: () -> Unit, onSsh: () -> Unit, onAbout: () -> Unit) {
    var turningOff by remember { mutableStateOf(false) }
    var openGroup by rememberSaveable { mutableStateOf<String?>(null) }
    val ssh by SshKeys.info.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { SshKeys.load() } }
    // 2 columns need a wide window in landscape. A tablet in portrait has the layout of a phone.
    val size = LocalWindowInfo.current.containerSize
    val wide = rememberWideWindow() && size.width > size.height
    val switches = rememberSyncSwitches(state)
    val groups = settingsGroups(state, SettingsContext(atOnceSupported = ApproveAtOnce.supported(Build.VERSION.SDK_INT)))
    val card: @Composable (GroupModel) -> Unit = { m ->
        val open = openGroup == m.group.name
        GroupCard(m, open, onToggle = { openGroup = if (open) null else m.group.name }) {
            GroupBody(m, state, switches, ssh, onSsh)
        }
    }
    val footer: @Composable () -> Unit = {
        FooterRows(wide, onTurnOff = { turningOff = true }, onAbout = onAbout)
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.statusBarsPadding()) { ScreenHeader("Settings", "", onBack = onBack) }
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val pin = maxHeight >= PinFooterHeight
            Column(Modifier.fillMaxSize()) {
                val side = Modifier.padding(horizontal = 10.dp)
                Column(
                    Modifier.weight(1f).verticalScroll(rememberScrollState()).then(side).padding(top = 6.dp, bottom = if (pin) 12.dp else 28.dp),
                    verticalArrangement = Arrangement.spacedBy(TileGap),
                ) {
                    if (wide) {
                        Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TileGap)) { for (m in groups.take(3)) card(m) }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(TileGap)) { for (m in groups.drop(3)) card(m) }
                        }
                    } else {
                        for (m in groups) card(m)
                    }
                    if (!pin) {
                        Spacer(Modifier.height(12.dp))
                        footer()
                    }
                }
                if (pin) Column(side.padding(bottom = 16.dp)) { footer() }
            }
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

/** The group row, with its summary, and the entries under it while the group is [open]. */
@Composable
private fun GroupCard(model: GroupModel, open: Boolean, onToggle: () -> Unit, body: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().tile()) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp)
                .clickable(role = Role.Button, onClick = onToggle)
                .semantics { stateDescription = if (open) "Open" else "Closed" }
                .padding(start = 14.dp, end = 10.dp, top = 10.dp, bottom = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Sym(groupIcon(model.group), tint = Tn.blue, size = 22.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(model.group.title, size = 15, weight = FontWeight.SemiBold)
                T(model.summary, size = 13, color = Tn.sub, lineHeight = 1.3f)
            }
            Sym(if (open) R.drawable.ic_expand_more else Ic.chevron, tint = Tn.sub, size = 20.dp)
        }
        if (open) {
            Column(Modifier.background(Tn.bg)) { body() }
        }
    }
}

/** A line between the entries of an open group. */
@Composable
private fun EntryDivider() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Tn.line))
}

/** The entries of an open group. Each switch keeps its permission request and its notice. */
@Composable
private fun GroupBody(model: GroupModel, state: UiState, switches: SyncSwitches, ssh: SshKeyInfo?, onSsh: () -> Unit) {
    EntryDivider()
    when (model.group) {
        SettingsGroup.Send, SettingsGroup.Alerts, SettingsGroup.Phone -> {
            if (model.keys.isEmpty()) {
                T(
                    "These alerts show when a paired computer sends agents.",
                    Modifier.padding(horizontal = 14.dp, vertical = 14.dp), size = 13, color = Tn.sub, lineHeight = 1.3f,
                )
            }
            model.keys.forEachIndexed { i, key ->
                if (i > 0) EntryDivider()
                switches.Row(key, flat = true)
            }
        }
        SettingsGroup.Security -> {
            AtOnceRow(state, flat = true)
            EntryDivider()
            SettingRow(Ic.key, "SSH key", sshSummary(ssh), flat = true, onClick = onSsh)
        }
        SettingsGroup.Look -> {
            ThemeRow(state, flat = true)
            EntryDivider()
            ScrollRow(state, flat = true)
        }
    }
}

/**
 * Turn off Flux and About Flux, apart from the groups. Turn off Flux
 * runs an action, so a dialog asks first. A wide window shows them side by
 * side.
 */
@Composable
private fun FooterRows(wide: Boolean, onTurnOff: () -> Unit, onAbout: () -> Unit) {
    val turnOff: @Composable (Modifier) -> Unit = { m ->
        FooterRow(m, "Turn off Flux", Tn.red, null, onTurnOff)
    }
    val about: @Composable (Modifier) -> Unit = { m ->
        FooterRow(m, "About Flux", Tn.text, aboutVersion(BuildConfig.VERSION_NAME, BuildConfig.DEBUG), onAbout)
    }
    Box(Modifier.fillMaxWidth().height(1.dp).background(Tn.line))
    Spacer(Modifier.height(TileGap))
    if (wide) {
        Row(horizontalArrangement = Arrangement.spacedBy(TileGap)) {
            turnOff(Modifier.weight(1f))
            about(Modifier.weight(1f))
        }
    } else {
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            turnOff(Modifier)
            about(Modifier)
        }
    }
}

@Composable
private fun FooterRow(modifier: Modifier, title: String, color: Color, trailing: String?, onClick: () -> Unit) {
    Row(
        modifier.fillMaxWidth().heightIn(min = 64.dp).tile().clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T(title, size = 15, weight = FontWeight.SemiBold, color = color)
        if (trailing != null) T(trailing, size = 13, color = Tn.sub)
    }
}

/** A row that opens a setting, with a chevron. [flat] draws it with no tile of its own. */
@Composable
private fun SettingRow(@DrawableRes icon: Int, title: String, detail: String, flat: Boolean = false, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).tile(!flat)
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
        Sym(Ic.chevron, tint = Tn.sub, size = 20.dp)
    }
}

/** 1 choice of a [ChoiceGroup]. [detail] shows under the label. */
private class Choice(val label: String, @DrawableRes val icon: Int, val selected: Boolean, val detail: String?, val onSelect: () -> Unit)

/** A setting with 1 choice of [choices], as radio rows under [title]. */
@Composable
private fun ChoiceGroup(title: String, choices: List<Choice>, flat: Boolean = false) {
    Column(Modifier.fillMaxWidth().tile(!flat).padding(vertical = 6.dp)) {
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
private fun ThemeRow(state: UiState, flat: Boolean = false) {
    val computerLine = computerThemeLine(state, isSystemInDarkTheme())
    ChoiceGroup(
        "Theme",
        ThemeChoices.map { (mode, label, icon) ->
            Choice(label, icon, mode == state.theme, if (mode == ThemeMode.Computer) computerLine else null) { FluxCore.setTheme(mode) }
        },
        flat,
    )
}

/** The scroll direction of the touchpad screen, see [ScrollMode]. */
@Composable
private fun ScrollRow(state: UiState, flat: Boolean = false) {
    fun choice(mode: ScrollMode, label: String, @DrawableRes icon: Int, detail: String) =
        Choice(label, icon, mode == state.touchpadScroll, detail) { FluxCore.setTouchpadScroll(mode) }
    ChoiceGroup(
        "Touchpad scrolling",
        listOf(
            choice(ScrollMode.Computer, "Computer", Ic.desktop, "Scrolls like the touchpad of the computer."),
            choice(ScrollMode.Natural, "Natural", Ic.touchApp, "The content moves with the fingers."),
            choice(ScrollMode.Traditional, "Traditional", Ic.south, "Fingers down scroll down, like a scroll wheel."),
        ),
        flat,
    )
}

/** The switch that opens the fingerprint prompt at once. It stays off on Android 10 and 11. */
@Composable
private fun AtOnceRow(state: UiState, flat: Boolean = false) {
    val supported = ApproveAtOnce.supported(Build.VERSION.SDK_INT)
    val on = supported && state.approveAtOnce
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).tile(!flat)
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

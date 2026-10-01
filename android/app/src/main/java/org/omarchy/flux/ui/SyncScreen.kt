package org.omarchy.flux.ui

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.CaptureKind
import org.omarchy.flux.core.CaptureWatch
import org.omarchy.flux.core.ClipAutoState
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.NotificationSync
import org.omarchy.flux.core.SmsSync
import org.omarchy.flux.core.UiState
import org.omarchy.flux.service.FluxNotificationListener

/** 1 sync switch: what it does, and its state. [key] names the switch, so that a refused permission shows under it. */
private class SyncItem(
    val key: String,
    @DrawableRes val icon: Int,
    val title: String,
    val detail: String,
    val on: Boolean,
    val onToggle: () -> Unit,
)

/** The keys of the switches that ask for a permission in a dialog. The capture switches use the name of their [CaptureKind]. */
private const val CALLS = "calls"
private const val SMS = "sms"

/** True when a paired computer sends herdr agents. Only then do the agent alerts show. */
private fun hasAgents(state: UiState) = state.devices.any { it.paired && it.herdrSupported }

/**
 * The number of sync switches that are on, and the number of switches. A
 * switch that needs an Android permission counts as on only with it.
 */
fun syncSummary(state: UiState): Pair<Int, Int> {
    val on = buildList {
        add(state.shareNotifications && state.notificationAccess)
        add(state.syncClipboard)
        add(state.callAlerts && state.callAccess)
        if (state.smsSupported) add(state.smsSync && state.smsAccess)
        add(state.syncDnd && state.dndAccess)
        add(state.sendScreenshots && state.mediaAccess)
        add(state.sendPhotos && state.mediaAccess)
        if (hasAgents(state)) {
            add(state.agentInputAlerts)
            add(state.agentDoneAlerts)
        }
    }
    return on.count { it } to on.size
}

/**
 * The sync switches. They are settings of this phone, so they apply to
 * every paired computer. Each switch says what it sends. A switch that
 * needs an Android permission asks for it first.
 */
@Composable
fun SyncScreen(state: UiState, onBack: () -> Unit) {
    val context = LocalContext.current
    // A permission that the user refused, and the switch that asked for it. The notice under
    // that switch tells what the permission is for and opens the app settings.
    var refused by rememberSaveable { mutableStateOf<String?>(null) }
    var refusedKey by rememberSaveable { mutableStateOf<String?>(null) }
    fun refuse(key: String, text: String) {
        refusedKey = key
        refused = text
    }
    fun clearRefused() {
        refusedKey = null
        refused = null
    }
    // Call alerts need the phone state. The call log and the contacts add
    // the number and the name, and the user can refuse them.
    val askPhone = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted[Manifest.permission.READ_PHONE_STATE] == true) {
            clearRefused()
            FluxCore.setCallAlerts(true)
        } else {
            refuse(CALLS, "Call alerts need phone access. Allow it in the app settings.")
        }
    }
    // Text messages need to read and send SMS. The contacts add the names,
    // and the user can refuse them.
    val askSms = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (SmsSync.hasAccess(context)) {
            clearRefused()
            FluxCore.setSyncSms(true)
        } else {
            refuse(SMS, "Text messages need SMS access. Allow it in the app settings.")
        }
    }
    // The first capture switch that turns on asks for access to photos.
    var asking by remember { mutableStateOf<CaptureKind?>(null) }
    val askPhotos = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val kind = asking ?: return@rememberLauncherForActivityResult
        asking = null
        when {
            CaptureWatch.hasAccess(context) -> {
                clearRefused()
                FluxCore.setSendCaptures(kind, true)
            }
            // Access to selected photos only does not show new images.
            else -> refuse(kind.name, "Flux sees new images only with access to all photos. Allow it in the app settings.")
        }
    }
    fun captureToggle(kind: CaptureKind, current: Boolean) {
        when {
            current && state.mediaAccess -> FluxCore.setSendCaptures(kind, false)
            state.mediaAccess -> FluxCore.setSendCaptures(kind, true)
            else -> {
                asking = kind
                askPhotos.launch(CaptureWatch.permissions())
            }
        }
    }
    val sync = buildList {
        add(
            SyncItem("notifications", Ic.notifications, "Share notifications", "Shows the notifications of this phone on the computers.", state.shareNotifications && state.notificationAccess) {
                if (!state.notificationAccess) {
                    FluxCore.setShareNotifications(true)
                    val intent = if (Build.VERSION.SDK_INT >= 30) {
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                            .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, ComponentName(context, FluxNotificationListener::class.java).flattenToString())
                    } else {
                        Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
                    }
                    runCatching { context.startActivity(intent) }
                        .onFailure { runCatching { context.startActivity(Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")) } }
                } else {
                    // The computers drop the shared notifications, and their replies and buttons stop working.
                    if (state.shareNotifications) NotificationSync.stop()
                    FluxCore.setShareNotifications(!state.shareNotifications)
                }
            },
        )
        add(SyncItem("clipboard", Ic.paste, "Sync clipboard", "Copies text and images between this phone and the computers.", state.syncClipboard) {
            FluxCore.setSyncClipboard(!state.syncClipboard)
        })
        add(
            SyncItem(CALLS, Ic.call, "Call alerts", "Shows a call to this phone on the computers.", state.callAlerts && state.callAccess) {
                if (!state.callAccess) {
                    askPhone.launch(arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS))
                } else {
                    FluxCore.setCallAlerts(!state.callAlerts)
                }
            },
        )
        // A tablet without a SIM slot has no text messages.
        if (state.smsSupported) {
            add(SyncItem(SMS, Ic.sms, "Text messages", "Shows text messages on the computers, and sends the replies from them.", state.smsSync && state.smsAccess) {
                if (!state.smsAccess) askSms.launch(SmsSync.permissions()) else FluxCore.setSyncSms(!state.smsSync)
            })
        }
        add(
            SyncItem("dnd", Ic.dnd, "Sync Do Not Disturb", "Turns Do Not Disturb on and off on this phone and the computers together.", state.syncDnd && state.dndAccess) {
                if (!state.dndAccess) {
                    FluxCore.setSyncDnd(true)
                    runCatching { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) }
                } else {
                    FluxCore.setSyncDnd(!state.syncDnd)
                }
            },
        )
        add(SyncItem(CaptureKind.Screenshot.name, Ic.screenshot, "Send new screenshots", "Sends each new screenshot of this phone to the computers.", state.sendScreenshots && state.mediaAccess) {
            captureToggle(CaptureKind.Screenshot, state.sendScreenshots)
        })
        add(SyncItem(CaptureKind.Photo.name, Ic.gallery, "Send new photos", "Sends each new photo of this phone to the computers.", state.sendPhotos && state.mediaAccess) {
            captureToggle(CaptureKind.Photo, state.sendPhotos)
        })
        if (hasAgents(state)) {
            add(SyncItem("agentInput", Ic.notificationsActive, "Agent needs input", "Notifies this phone when an agent on a computer waits for you.", state.agentInputAlerts) {
                FluxCore.setAgentInputAlerts(!state.agentInputAlerts)
            })
            add(SyncItem("agentDone", Ic.checkCircle, "Agent finished", "Notifies this phone when an agent on a computer finishes.", state.agentDoneAlerts) {
                FluxCore.setAgentDoneAlerts(!state.agentDoneAlerts)
            })
        }
    }

    CappedScrollColumn(bottom = 48.dp) {
        TiledTopBar("Sync", onBack, context = "All computers")
        T("These switches apply to every paired computer.", Modifier.padding(start = 4.dp, bottom = 12.dp), size = 14, color = Tn.sub)
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            for (s in sync) {
                SyncRow(s)
                // The notice shows under the switch that asked, where the user looks after the tap.
                val text = refused
                if (text != null && refusedKey == s.key) PermissionNotice(text)
            }
        }
        if (state.syncClipboard) ClipAutoStatus(state)
    }
}

/** A sync switch. TalkBack reads it as a switch with its state. */
@Composable
private fun SyncRow(s: SyncItem) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
            .toggleable(value = s.on, role = Role.Switch, onValueChange = { s.onToggle() })
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Sym(s.icon, tint = if (s.on) Tn.blue else Tn.sub, size = 22.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(s.title, size = 15, weight = FontWeight.SemiBold)
            T(s.detail, size = 13, color = Tn.sub, lineHeight = 1.3f)
        }
        // The row takes the tap and gives the state to TalkBack, so the switch only shows it.
        Switch(checked = s.on, onCheckedChange = null)
    }
}

/** The state of the automatic clipboard sync in words, and true when it needs no action. */
fun clipAutoLine(state: UiState): Pair<String, Boolean> = when {
    !state.syncClipboard -> "Clipboard sync is off. Turn it on in Sync." to false
    state.clipAuto == ClipAutoState.Active -> "Automatic clipboard sync is on" to true
    state.clipAuto == ClipAutoState.Checking -> "Automatic sync starts when you leave Flux" to true
    state.clipAuto == ClipAutoState.NeedsConsent -> "Open Flux to resume automatic sync" to false
    else -> "Only while Flux is open. Set up automatic sync" to false
}

/**
 * The automatic clipboard state under the sync switches. Active needs no
 * action. A reader that the self-test did not check yet also shows as
 * automatic, and the self-test corrects it when Flux goes to the
 * background. A tap opens the setup sheet, which also turns the automatic
 * sync off.
 */
@Composable
private fun ClipAutoStatus(state: UiState) {
    var showSheet by remember { mutableStateOf(false) }
    val (label, active) = clipAutoLine(state)
    Row(
        Modifier.fillMaxWidth().padding(top = 8.dp).heightIn(min = 48.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClickLabel = if (active) "Change automatic sync" else "Set up automatic sync") { showSheet = true }
            .padding(horizontal = 4.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Sym(if (active) Ic.sync else Ic.paste, tint = if (active) Tn.green else Tn.sub, size = 18.dp)
        T(label, Modifier.weight(1f), size = 13, color = if (active) Tn.green else Tn.sub)
        Sym(Ic.chevron, tint = Tn.sub, size = 18.dp)
    }
    if (showSheet) ClipAutoSheet(state) { showSheet = false }
}

/** The commands that set up the automatic clipboard sync. */
private val CLIP_SETUP_COMMANDS = listOf(
    "adb shell pm grant org.omarchy.flux android.permission.READ_LOGS",
    "adb shell appops set org.omarchy.flux SYSTEM_ALERT_WINDOW allow",
    "adb shell am force-stop org.omarchy.flux",
)

/**
 * The setup sheet for the automatic clipboard sync. It opens the overlay
 * permission screen and shows the adb commands with a copy button. The
 * switch at the end turns the sync on after the accesses are in place.
 * After each reboot or update, the user opens Flux once.
 */
@Composable
private fun ClipAutoSheet(state: UiState, onDismiss: () -> Unit) {
    val context = LocalContext.current
    FluxSheet(onDismiss) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter, vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            TileLabel("Automatic clipboard sync", Modifier.semantics { heading() }, color = Tn.sub)
            T(
                "Flux copies from other apps to the computer without the app open. Grant the access once with adb. " +
                    "Then turn on the switch at the end. Open Flux once after each reboot or update.",
                size = 13, color = Tn.sub, lineHeight = 1.3f,
            )
            if (!state.overlayAccess) {
                FluxButton(
                    "Allow drawing over apps",
                    {
                        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, "package:${context.packageName}".toUri())
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        runCatching { context.startActivity(intent) }
                            .onFailure { runCatching { context.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)) } }
                    },
                    Modifier.fillMaxWidth(),
                )
            }
            T("Run these on a computer with adb:", size = 13, color = Tn.sub)
            for (cmd in CLIP_SETUP_COMMANDS) CommandBlock(cmd)
            T(
                "The Appear on top switch in the Android app settings does the same as the second command.",
                size = 13, color = Tn.sub, lineHeight = 1.3f,
            )
            T(
                "The log access covers the system log of all apps. Flux reads only the lines of the clipboard service.",
                size = 13, color = Tn.sub, lineHeight = 1.3f,
            )
            ClipAutoSwitch(state)
            Spacer(Modifier.height(16.dp))
        }
    }
}

/**
 * The switch of the automatic clipboard sync. It is off by default, and it
 * turns on only after the log access and the overlay access are in place.
 * So Android shows its log access dialog only after the user asks for the
 * sync. The switch can always turn off.
 */
@Composable
private fun ClipAutoSwitch(state: UiState) {
    val on = state.autoClipboard
    val ready = state.readLogs && state.overlayAccess
    val enabled = ready || on
    val detail = when {
        on && !ready -> "Flux needs both accesses above. Then the automatic sync starts."
        !state.readLogs -> "Run the commands above first. Then turn on this switch."
        !state.overlayAccess -> "Allow drawing over apps first. Then turn on this switch."
        on -> clipAutoLine(state).first
        Build.VERSION.SDK_INT >= 33 -> "Android then asks for log access. Tap Allow one-time access."
        else -> "Flux then reads each copy from the system log."
    }
    Row(
        Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
            .toggleable(value = on, enabled = enabled, role = Role.Switch, onValueChange = { FluxCore.setAutoClipboard(it) })
            .padding(horizontal = 14.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T("Automatic sync", size = 15, weight = FontWeight.SemiBold, color = if (enabled) Tn.text else Tn.sub)
            T(detail, size = 13, color = Tn.sub, lineHeight = 1.3f)
        }
        // The row takes the tap and gives the state to TalkBack, so the switch only shows it.
        Switch(checked = on, onCheckedChange = null, enabled = enabled)
    }
}


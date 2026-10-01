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
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
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

/** 1 sync switch: what it does, and its state. */
private class SyncItem(@DrawableRes val icon: Int, val title: String, val detail: String, val on: Boolean, val onToggle: () -> Unit)

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
    // Call alerts need the phone state. The call log and the contacts add
    // the number and the name, and the user can refuse them.
    val askPhone = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted[Manifest.permission.READ_PHONE_STATE] == true) {
            FluxCore.setCallAlerts(true)
        } else {
            FluxCore.toast("Call alerts need phone access. Allow it in the app settings.")
        }
    }
    // Text messages need to read and send SMS. The contacts add the names,
    // and the user can refuse them.
    val askSms = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (SmsSync.hasAccess(context)) {
            FluxCore.setSyncSms(true)
        } else {
            FluxCore.toast("Text messages need SMS access. Allow it in the app settings.")
        }
    }
    // The first capture switch that turns on asks for access to photos.
    var asking by remember { mutableStateOf<CaptureKind?>(null) }
    val askPhotos = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val kind = asking ?: return@rememberLauncherForActivityResult
        asking = null
        when {
            CaptureWatch.hasAccess(context) -> FluxCore.setSendCaptures(kind, true)
            // Access to selected photos only does not show new images.
            else -> FluxCore.toast("Allow access to all photos, so that Flux sees new images")
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
            SyncItem(Ic.notifications, "Share notifications", "Shows the notifications of this phone on the computers.", state.shareNotifications && state.notificationAccess) {
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
        add(SyncItem(Ic.paste, "Sync clipboard", "Copies text and images between this phone and the computers.", state.syncClipboard) {
            FluxCore.setSyncClipboard(!state.syncClipboard)
        })
        add(
            SyncItem(Ic.call, "Call alerts", "Shows a call to this phone on the computers.", state.callAlerts && state.callAccess) {
                if (!state.callAccess) {
                    askPhone.launch(arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS))
                } else {
                    FluxCore.setCallAlerts(!state.callAlerts)
                }
            },
        )
        // A tablet without a SIM slot has no text messages.
        if (state.smsSupported) {
            add(SyncItem(Ic.sms, "Text messages", "Shows text messages on the computers, and sends the replies from them.", state.smsSync && state.smsAccess) {
                if (!state.smsAccess) askSms.launch(SmsSync.permissions()) else FluxCore.setSyncSms(!state.smsSync)
            })
        }
        add(
            SyncItem(Ic.dnd, "Sync Do Not Disturb", "Turns Do Not Disturb on and off on this phone and the computers together.", state.syncDnd && state.dndAccess) {
                if (!state.dndAccess) {
                    FluxCore.setSyncDnd(true)
                    runCatching { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS)) }
                } else {
                    FluxCore.setSyncDnd(!state.syncDnd)
                }
            },
        )
        add(SyncItem(Ic.screenshot, "Send new screenshots", "Sends each new screenshot of this phone to the computers.", state.sendScreenshots && state.mediaAccess) {
            captureToggle(CaptureKind.Screenshot, state.sendScreenshots)
        })
        add(SyncItem(Ic.gallery, "Send new photos", "Sends each new photo of this phone to the computers.", state.sendPhotos && state.mediaAccess) {
            captureToggle(CaptureKind.Photo, state.sendPhotos)
        })
        if (hasAgents(state)) {
            add(SyncItem(Ic.notificationsActive, "Agent needs input", "Notifies this phone when an agent on a computer waits for you.", state.agentInputAlerts) {
                FluxCore.setAgentInputAlerts(!state.agentInputAlerts)
            })
            add(SyncItem(Ic.checkCircle, "Agent finished", "Notifies this phone when an agent on a computer finishes.", state.agentDoneAlerts) {
                FluxCore.setAgentDoneAlerts(!state.agentDoneAlerts)
            })
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter)) {
        TiledTopBar("sync · all computers", onBack)
        T("These switches apply to every paired computer.", Modifier.padding(start = 4.dp, bottom = 12.dp), size = 14, color = Tn.sub)
        Column(verticalArrangement = Arrangement.spacedBy(TileGap)) {
            for (s in sync) SyncRow(s)
        }
        if (state.syncClipboard) ClipAutoStatus(state)
        Spacer(Modifier.height(48.dp))
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
 * background. The other states open the setup sheet on a tap.
 */
@Composable
private fun ClipAutoStatus(state: UiState) {
    var showSheet by remember { mutableStateOf(false) }
    val (label, active) = clipAutoLine(state)
    Row(
        Modifier.fillMaxWidth().padding(top = 8.dp).heightIn(min = 48.dp)
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = !active, onClickLabel = "Set up automatic sync") { showSheet = true }
            .padding(horizontal = 4.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Sym(if (active) Ic.sync else Ic.paste, tint = if (active) Tn.green else Tn.sub, size = 18.dp)
        T(label, Modifier.weight(1f), size = 13, color = if (active) Tn.green else Tn.sub)
        if (!active) Sym(Ic.chevron, tint = Tn.sub, size = 18.dp)
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
 * permission screen and shows the adb commands with a copy button. After
 * each reboot or update, the user opens Flux once.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ClipAutoSheet(state: UiState, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheet, containerColor = Tn.bg) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = TiledGutter, vertical = 4.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            TileLabel("Automatic clipboard sync", color = Tn.sub)
            T(
                "Flux copies from other apps to the computer without the app open. Grant the access once with adb. " +
                    "Open Flux once after each reboot or update.",
                size = 13, color = Tn.sub, lineHeight = 1.3f,
            )
            if (!state.overlayAccess) {
                Button(
                    onClick = {
                        val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, "package:${context.packageName}".toUri())
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        runCatching { context.startActivity(intent) }
                            .onFailure { runCatching { context.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)) } }
                    },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                ) { Text("Allow drawing over apps") }
            }
            T("Run these on a computer with adb:", size = 12, color = Tn.sub)
            for (cmd in CLIP_SETUP_COMMANDS) ClipCommandRow(cmd)
            T(
                "The Appear on top switch in the Android app settings does the same as the second command.",
                size = 12, color = Tn.sub, lineHeight = 1.3f,
            )
            Spacer(Modifier.height(16.dp))
        }
    }
}

/** One adb command with a copy button. */
@Composable
private fun ClipCommandRow(command: String) {
    val context = LocalContext.current
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Tn.tile).padding(start = 12.dp, end = 2.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        T(command, Modifier.weight(1f), size = 12, color = Tn.text, family = Mono, lineHeight = 1.3f)
        Box(
            Modifier.size(48.dp).clip(RoundedCornerShape(8.dp))
                .clickable(onClickLabel = "Copy the command") {
                    if (Android.setClipboard(context, command)) FluxCore.toast("Copied")
                },
            contentAlignment = Alignment.Center,
        ) { Sym(Ic.copy, "Copy", tint = Tn.blue, size = 20.dp) }
    }
}

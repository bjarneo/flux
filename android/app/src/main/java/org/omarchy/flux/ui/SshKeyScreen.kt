package org.omarchy.flux.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.SshAgent
import org.omarchy.flux.core.SshKeyInfo
import org.omarchy.flux.core.SshKeys

/** The command that prints the key and the agent socket on the computer. */
const val SSH_COMMAND = "flux-cli ssh"

/** The summary of the SSH key for the settings row, for example "On · SHA256:uk2D…". */
fun sshSummary(info: SshKeyInfo?): String =
    if (info == null) "Off. Use this phone for SSH logins and Git signatures." else "On · ${info.fingerprint.take(16)}…"

/**
 * The SSH key of this phone: the switch, the public key, and its
 * fingerprint. The key applies to every paired computer. A switch that
 * turns off deletes the key, so a dialog asks first. docs/ssh.md is the
 * design.
 */
@Composable
fun SshKeyScreen(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { SshKeys.load() } }
    val info by SshKeys.info.collectAsStateWithLifecycle()
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf(false) }
    fun turnOn() {
        busy = true
        problem = null
        scope.launch {
            val error = withContext(Dispatchers.IO) {
                runCatching { SshKeys.create() }.exceptionOrNull()
            }
            busy = false
            if (error != null) {
                problem = "Android could not make the key. Set a screen lock on the phone first. ${error.message ?: ""}".trim()
            } else {
                SshAgent.sendKey(FluxCore)
            }
        }
    }

    CappedScrollColumn(bottom = 48.dp) {
        TiledTopBar("SSH key", onBack, context = "All computers")
        T(
            "This phone keeps an SSH key in the Android Keystore. The paired computers use it through the ssh-agent of Flux, for SSH logins and Git signatures. Each signature needs your fingerprint or your screen lock.",
            Modifier.padding(start = 4.dp, bottom = 12.dp), size = 14, color = Tn.sub, lineHeight = 1.35f,
        )
        val on = info != null
        Row(
            Modifier.fillMaxWidth().heightIn(min = 64.dp).clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
                .toggleable(value = on, enabled = !busy, role = Role.Switch, onValueChange = { if (on) deleting = true else turnOn() })
                .padding(horizontal = 14.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Sym(Ic.key, tint = if (on) Tn.blue else Tn.sub, size = 22.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T("SSH key", size = 15, weight = FontWeight.SemiBold)
                T(
                    if (on) "On. Each paired computer can ask this phone to sign." else "Off. This phone has no SSH key.",
                    size = 13, color = Tn.sub, lineHeight = 1.3f,
                )
            }
            if (busy) Spinner(Modifier.size(24.dp)) else Switch(checked = on, onCheckedChange = null)
        }
        problem?.let { PermissionNotice(it) }
        val key = info
        if (key != null) {
            SectionLabel("Public key")
            Column(
                Modifier.fillMaxWidth().clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape).padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                SelectionContainer { T(key.line, size = 12, family = Mono, lineHeight = 1.35f) }
                TileLabel("Fingerprint")
                SelectionContainer { T(key.fingerprint, size = 12, family = Mono) }
                TileLabel(storageText(key.storage))
                FluxButton(
                    "Copy the public key",
                    { if (Android.setClipboard(context, key.line)) FluxCore.toast("Copied") },
                    kind = ButtonKind.Tonal, icon = Ic.copy,
                )
            }
            SectionLabel("On the computer")
            T(
                "This command prints the key and the agent socket. Compare the fingerprint with this screen.",
                Modifier.padding(start = 4.dp, bottom = 8.dp), size = 13, color = Tn.sub, lineHeight = 1.3f,
            )
            CommandBlock(SSH_COMMAND)
        }
    }
    if (deleting) {
        ConfirmDialog(
            "Delete the SSH key?",
            "Android deletes the key, and nobody can get it back. Servers and Git hosts that have the public key stop accepting this phone. A new key has a new public key.",
            "Delete key",
            onCancel = { deleting = false },
            onConfirm = {
                deleting = false
                SshKeys.delete()
                SshAgent.sendKey(FluxCore)
            },
            icon = Ic.key,
            destructive = true,
        )
    }
}

private fun storageText(s: SshKeyInfo.Storage): String = when (s) {
    SshKeyInfo.Storage.StrongBox -> "Android keeps the private key in StrongBox."
    SshKeyInfo.Storage.SecureHardware -> "Android keeps the private key in the secure hardware of the phone."
    SshKeyInfo.Storage.Software -> "This phone has no secure hardware for the key. Android keeps it in software."
    SshKeyInfo.Storage.Unknown -> "Android keeps the private key in its Keystore."
}

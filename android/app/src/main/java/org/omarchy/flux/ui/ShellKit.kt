package org.omarchy.flux.ui

import android.content.Context
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.Share
import org.omarchy.flux.core.Target
import org.omarchy.flux.core.target

// ───────────────────────── Motion ─────────────────────────

/** The duration of the shell transitions, in milliseconds. */
const val MOTION_MS = 200

/** True when the Remove animations setting of Android is on. Screens then change without motion. */
val LocalReduceMotion = compositionLocalOf { false }

private fun animationsOff(context: Context): Boolean =
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

/** Reads the Remove animations setting, and reads it again when the app comes back to the front. */
@Composable
fun rememberReduceMotion(): Boolean {
    val context = LocalContext.current
    var off by remember { mutableStateOf(animationsOff(context)) }
    LifecycleResumeEffect(context) {
        off = animationsOff(context)
        onPauseOrDispose { }
    }
    return off
}

/** The narrowest window width of the medium and expanded size classes. */
private val WideWindow = 600.dp

/**
 * True for a window of the medium or expanded width class, for example a
 * phone in landscape, a foldable, or a tablet. The shell then shows a
 * navigation rail in the place of the navigation bar.
 */
@Composable
fun rememberWideWindow(): Boolean {
    val width = LocalWindowInfo.current.containerSize.width
    return with(LocalDensity.current) { width.toDp() } >= WideWindow
}

/** The lowest window height of the medium and expanded height classes. */
private val TallWindow = 480.dp

/**
 * True for a window of the compact height class, for example a phone in
 * landscape. The top bar then takes less height.
 */
@Composable
fun rememberShortWindow(): Boolean {
    val height = LocalWindowInfo.current.containerSize.height
    return with(LocalDensity.current) { height.toDp() } < TallWindow
}

/** A tween with the standard easing, or null when motion is off. */
fun <T> shellMotion(reduce: Boolean, ms: Int = MOTION_MS): FiniteAnimationSpec<T>? =
    if (reduce) null else tween(ms, easing = FastOutSlowInEasing)

// ───────────────────────── Tiles ─────────────────────────

/** A row of tiles with the same height. The height grows with the font size. */
@Composable
fun EqualRow(content: @Composable RowScope.() -> Unit) {
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(TileGap), content = content)
}

/**
 * A tile that runs 1 action: an icon, a label, and an optional line under
 * it. A tile that is not [enabled] shows dimmed, takes no taps, and
 * TalkBack reads it as disabled. A [badge] above 0 shows the number of
 * items that need the user.
 */
@Composable
fun ActionTile(
    @DrawableRes icon: Int,
    label: String,
    modifier: Modifier = Modifier,
    accent: Color = Tn.blue,
    sub: String? = null,
    enabled: Boolean = true,
    badge: Int = 0,
    minHeight: Dp = 88.dp,
    onClick: () -> Unit,
) {
    Column(
        modifier.heightIn(min = minHeight).alpha(if (enabled) 1f else 0.55f).clip(TileShape).background(Tn.tile)
            .border(1.dp, Tn.line, TileShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box {
            Sym(icon, tint = if (enabled) accent else Tn.sub, size = 24.dp)
            if (badge > 0) {
                T(
                    if (badge > 9) "9+" else "$badge",
                    Modifier.align(Alignment.TopEnd).offset(x = 12.dp, y = (-6).dp)
                        .clip(RoundedCornerShape(7.dp)).background(Tn.red).padding(horizontal = 5.dp),
                    size = 11, color = Tn.onAccent, weight = FontWeight.Bold, family = Mono,
                )
            }
        }
        // The text wraps with no limit. At a large font size, the tile and its row grow.
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(label, size = 15, weight = FontWeight.SemiBold)
            if (sub != null) T(sub, size = 12, color = Tn.sub)
        }
    }
}

/** A dot for the link of a computer: filled while it is connected, a ring while it is not reachable. */
@Composable
fun LinkDot(online: Boolean, size: Dp = 8.dp) {
    if (online) Dot(Tn.green, size) else Box(Modifier.size(size).border(1.5.dp, Tn.sub, CircleShape))
}

/** The color of the battery dot. It is not red, because red means that something needs the user. */
@Composable
fun batteryColor(level: Int, charging: Boolean): Color = when {
    charging -> Tn.green
    level <= 20 -> Tn.orange
    level <= 50 -> Tn.yellow
    else -> Tn.cyan
}

/** The link and battery state of a computer in words, for TalkBack and the scope menu. */
fun linkText(d: DeviceUi): String = when {
    !d.online -> "Not reachable"
    d.battery != null -> "Connected, battery ${d.battery}%" + if (d.charging) ", charging" else ""
    else -> "Connected"
}

// ───────────────────────── Scope ─────────────────────────

/**
 * The scope chip: "All computers" or 1 computer, with a link dot and a
 * battery dot for each computer in scope. A tap opens the menu of scopes.
 */
@Composable
fun ScopeChip(devices: List<DeviceUi>, scope: String?, onScope: (String?) -> Unit, modifier: Modifier = Modifier) {
    val paired = devices.filter { it.paired }
    val current = paired.firstOrNull { it.id == scope }
    var open by remember { mutableStateOf(false) }
    val shown = (if (current != null) listOf(current) else paired).take(4)
    val name = current?.name ?: "All computers"
    val description = "Scope: $name. " + shown.joinToString(". ") { "${it.name}: ${linkText(it)}" }
    val shape = RoundedCornerShape(10.dp)
    Box(modifier) {
        // The clickable merges the description of the inner row. The inner row hides the dots from TalkBack.
        Box(
            Modifier.heightIn(min = 48.dp).clip(shape).background(Tn.tile).border(1.dp, Tn.line, shape)
                .clickable(onClickLabel = "Change the scope", role = Role.DropdownList) { open = true },
            contentAlignment = Alignment.CenterStart,
        ) {
            Row(
                Modifier.padding(start = 12.dp, end = 6.dp).clearAndSetSemantics { contentDescription = description },
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                T(name, Modifier.weight(1f, fill = false), size = 14, weight = FontWeight.SemiBold, maxLines = 1)
                for (d in shown) {
                    Row(horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.CenterVertically) {
                        LinkDot(d.online)
                        val b = d.battery
                        if (d.online && b != null) Dot(batteryColor(b, d.charging))
                    }
                }
                Sym(Ic.expand, tint = Tn.sub, size = 20.dp)
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { Text("All computers") },
                leadingIcon = { Sym(Ic.devices) },
                trailingIcon = { if (current == null) Sym(Ic.check, "Selected", tint = Tn.blue) },
                onClick = {
                    open = false
                    onScope(null)
                },
            )
            for (d in paired) {
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(d.name)
                            Text(linkText(d), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    },
                    leadingIcon = { Sym(deviceIcon(d.type)) },
                    trailingIcon = { if (current?.id == d.id) Sym(Ic.check, "Selected", tint = Tn.blue) },
                    onClick = {
                        open = false
                        onScope(d.id)
                    },
                )
            }
        }
    }
}

// ───────────────────────── Targets ─────────────────────────

/** A question for the computer of an action. */
class PickRequest(val title: String, val devices: List<DeviceUi>, val action: (DeviceUi) -> Unit)

/**
 * Runs an action on the computer of a [Target]. With more than 1 computer,
 * it asks which one first. [Dialog] shows the question.
 */
class TargetPicker {
    var request by mutableStateOf<PickRequest?>(null)
        private set

    /** Runs [action] for [t]. [title] asks for the computer, for example "Send the clipboard to". */
    fun run(t: Target, title: String, action: (DeviceUi) -> Unit) {
        when (t) {
            is Target.One -> action(t.device)
            is Target.Ask -> request = PickRequest(title, t.devices, action)
            is Target.None -> FluxCore.toast(noTargetText(t))
        }
    }

    fun dismiss() {
        request = null
    }
}

/** Why an action has no computer, in 1 sentence. */
fun noTargetText(t: Target.None): String {
    val d = t.device ?: return "No computer is online"
    return if (!d.online) "${d.name} is not reachable" else "Update Flux on ${d.name} to use this"
}

@Composable
fun rememberTargetPicker(): TargetPicker = remember { TargetPicker() }

/** The question for the computer of an action: 1 row for each computer. */
@Composable
fun TargetPickerDialog(picker: TargetPicker) {
    val r = picker.request ?: return
    AlertDialog(
        onDismissRequest = picker::dismiss,
        title = { Text(r.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                for (d in r.devices) {
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(10.dp))
                            .clickable(role = Role.Button) {
                                picker.dismiss()
                                r.action(d)
                            }
                            .padding(horizontal = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Sym(deviceIcon(d.type), tint = Tn.blue)
                        Column(Modifier.weight(1f)) {
                            T(d.name, size = 15, weight = FontWeight.SemiBold)
                            T(linkText(d), size = 12, color = Tn.sub)
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { FluxButton("Cancel", picker::dismiss, kind = ButtonKind.Text) },
    )
}

/** The 2 most used actions: send the clipboard and send files, to the computer in scope. */
class SendTools(val sendClipboard: () -> Unit, val sendFiles: () -> Unit)

@Composable
fun rememberSendTools(devices: List<DeviceUi>, scope: String?, picker: TargetPicker): SendTools {
    // The file picker is another activity, so the computer waits in the saved state.
    var filesFor by rememberSaveable { mutableStateOf<String?>(null) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        val id = filesFor
        filesFor = null
        if (id != null && uris.isNotEmpty()) Share.sendFiles(FluxCore, id, uris)
    }
    val all by rememberUpdatedState(devices)
    val inScope by rememberUpdatedState(scope)
    return remember(picker, pick) {
        SendTools(
            sendClipboard = { picker.run(target(inScope, all), "Send the clipboard to") { Plugins.sendClipboard(FluxCore, it.id) } },
            sendFiles = {
                picker.run(target(inScope, all), "Send files to") {
                    filesFor = it.id
                    pick.launch(arrayOf("*/*"))
                }
            },
        )
    }
}

/**
 * The line at the top of Send and Control: the computer that the actions
 * go to, or why no computer can take them, with the next step.
 */
@Composable
fun TargetLine(t: Target, devices: List<DeviceUi>, verb: String, onPair: () -> Unit) {
    val paired = devices.any { it.paired }
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when (t) {
            is Target.One -> {
                LinkDot(true)
                T("$verb ${t.device.name}", Modifier.weight(1f), size = 14, color = Tn.text, maxLines = 2)
            }
            is Target.Ask -> {
                Sym(Ic.devices, tint = Tn.sub, size = 18.dp)
                T("${t.devices.size} computers are online. Flux asks which one.", Modifier.weight(1f), size = 14, color = Tn.sub)
            }
            is Target.None -> {
                LinkDot(false)
                T(
                    if (!paired) "Pair a computer to use these tools." else noTargetText(t) + ".",
                    Modifier.weight(1f), size = 14, color = Tn.sub,
                )
                if (!paired) {
                    FluxButton("Pair", onPair, kind = ButtonKind.Text)
                } else {
                    FluxButton("Retry", { FluxCore.rediscover() }, kind = ButtonKind.Text)
                }
            }
        }
    }
}

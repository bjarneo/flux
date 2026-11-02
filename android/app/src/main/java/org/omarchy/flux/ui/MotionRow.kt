package org.omarchy.flux.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.ACTIVITY_PERMISSION
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Mount
import org.omarchy.flux.core.MotionCues
import org.omarchy.flux.core.UiState
import org.omarchy.flux.core.VehicleDetect

/** True when the Computers screen shows the motion cues row of [d]: the computer has motion cues on, or the cues run. */
internal fun showsMotion(d: DeviceUi): Boolean = d.paired && d.motionSupported && (d.motion.enabled == true || d.motion.running)

/** The state line of the motion cues row. */
internal fun motionLine(d: DeviceUi): String {
    val m = d.motion
    return when {
        m.running -> "On. The dots on ${d.name} move with the vehicle."
        m.error == MotionCues.NO_SENSOR -> "This phone has no accelerometer."
        m.error != null -> "Not running: ${m.error}."
        !d.online -> "Off. ${d.name} is offline."
        else -> "Off."
    }
}

/** The line under Automatic start. */
internal fun motionAutoLine(d: DeviceUi, phoneAuto: Boolean, detect: VehicleDetect): String = when {
    detect == VehicleDetect.Unavailable -> "Start by hand. This phone has no Google Play services to detect a vehicle."
    !phoneAuto && detect == VehicleDetect.NoPermission -> "Start by hand. To start in a vehicle, turn this on. Flux then asks for physical activity access."
    !phoneAuto -> "Start by hand. To start in a vehicle, turn this on."
    detect == VehicleDetect.NoPermission -> "Start by hand. Allow physical activity access to detect a vehicle."
    !d.motion.auto -> "Automatic start is off on ${d.name}. Start by hand."
    else -> "Starts and stops when this phone detects a vehicle."
}

/**
 * Motion cues with 1 computer: the state, Start or Stop, the mount of the
 * phone, and Automatic start. Start asks the computer, and the sensor
 * starts when the computer answers. Automatic start is a setting of this
 * phone. It asks for physical activity access when it turns on.
 */
@Composable
internal fun MotionRow(d: DeviceUi, state: UiState) {
    val m = d.motion
    var refused by rememberSaveable { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        refused = !granted
        MotionCues.setAuto(FluxCore, granted)
    }
    val detect = state.vehicleDetect
    val autoOn = state.motionAuto && detect != VehicleDetect.Unavailable
    Column(
        Modifier.fillMaxWidth().clip(TileShape).background(Tn.tile).border(1.dp, Tn.line, TileShape)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Sym(Ic.car, tint = if (m.running) Tn.blue else Tn.sub, size = 22.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T("Motion cues", size = 15, weight = FontWeight.SemiBold)
                T(motionLine(d), size = 13, color = if (m.error != null) Tn.yellow else Tn.sub, lineHeight = 1.3f)
            }
            if (m.running) {
                FluxButton("Stop", { MotionCues.requestStop(FluxCore, d.id) }, kind = ButtonKind.Tonal, icon = Ic.stop)
            } else {
                FluxButton("Start", { MotionCues.requestStart(FluxCore, d.id) }, kind = ButtonKind.Outlined, icon = Ic.play, enabled = d.online)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            T("Phone position", size = 13, color = Tn.sub)
            Row(Modifier.selectableGroup(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (mount in Mount.entries) {
                    ChoiceChip(mount.label, m.mount == mount, { MotionCues.setMount(FluxCore, d.id, mount) }, Modifier.weight(1f))
                }
            }
            T(
                if (m.mount == Mount.Flat) "The phone lies flat, screen up." else "The phone stands in a holder.",
                size = 12, color = Tn.sub, lineHeight = 1.3f,
            )
        }
        val canToggle = detect != VehicleDetect.Unavailable
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).alpha(if (canToggle) 1f else DimAlpha)
                .toggleable(value = autoOn, enabled = canToggle, role = Role.Switch, onValueChange = { on ->
                    when {
                        !on -> MotionCues.setAuto(FluxCore, false)
                        detect == VehicleDetect.NoPermission -> ask.launch(ACTIVITY_PERMISSION)
                        else -> {
                            refused = false
                            MotionCues.setAuto(FluxCore, true)
                        }
                    }
                }),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T("Automatic start", size = 14, weight = FontWeight.SemiBold)
                T(motionAutoLine(d, state.motionAuto, detect), size = 13, color = Tn.sub, lineHeight = 1.3f)
            }
            // The row takes the tap and gives the state to TalkBack, so the switch only shows it.
            Switch(checked = autoOn, onCheckedChange = null, enabled = canToggle)
        }
        if (refused && detect == VehicleDetect.NoPermission) {
            PermissionNotice("Automatic start needs physical activity access. Allow it in the app settings.")
        }
    }
}

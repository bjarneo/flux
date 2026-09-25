package org.omarchy.flux.ui

import android.graphics.drawable.AdaptiveIconDrawable
import android.os.Build
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import org.omarchy.flux.R

/**
 * Debug builds only: shows the launcher icon as Android gives it to launchers,
 * the themed monochrome layer, and the notification icon, so that the icons
 * can be checked on a locked test phone.
 */
@Composable
fun DebugIconsScreen() {
    val context = LocalContext.current
    val icon = context.packageManager.getApplicationIcon(context.packageName)
    val mono = if (Build.VERSION.SDK_INT >= 33) (icon as? AdaptiveIconDrawable)?.monochrome else null
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        T("Launcher icon", size = 16)
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
            for (s in listOf(48, 72, 120)) {
                Image(icon.toBitmap(s * 3, s * 3).asImageBitmap(), null, Modifier.size(s.dp))
            }
        }
        T("Themed monochrome layer", size = 16)
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            if (mono != null) {
                Image(
                    mono.toBitmap(360, 360).asImageBitmap(), null,
                    Modifier.size(120.dp).background(Palette.accentContainer),
                    colorFilter = ColorFilter.tint(Palette.onAccentContainer),
                )
            } else {
                T("none", color = Palette.secondary)
            }
        }
        T("Notification icon", size = 16)
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(painterResource(R.drawable.ic_stat_flux), null, Modifier.size(24.dp), colorFilter = ColorFilter.tint(Palette.text))
            Image(painterResource(R.drawable.ic_stat_flux), null, Modifier.size(72.dp), colorFilter = ColorFilter.tint(Palette.text))
        }
        T("In-app mark", size = 16)
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.CenterVertically) {
            FluxMark(28.dp)
            FluxMark(96.dp)
        }
    }
}

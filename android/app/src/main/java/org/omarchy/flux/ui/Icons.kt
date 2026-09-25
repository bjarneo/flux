package org.omarchy.flux.ui

import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.omarchy.flux.R

/**
 * The icons of the app: Material Symbols Rounded at the 24 dp optical size.
 * tools/fetch_icons.py fetches them into res/drawable.
 */
object Ic {
    val back = R.drawable.ic_arrow_back
    val up = R.drawable.ic_arrow_upward
    val chevron = R.drawable.ic_chevron_right
    val more = R.drawable.ic_more_vert
    val close = R.drawable.ic_close
    val check = R.drawable.ic_check
    val checkCircle = R.drawable.ic_check_circle
    val refresh = R.drawable.ic_refresh
    val search = R.drawable.ic_search
    val settings = R.drawable.ic_settings
    val tune = R.drawable.ic_tune
    val info = R.drawable.ic_info
    val error = R.drawable.ic_error
    val warning = R.drawable.ic_warning
    val link = R.drawable.ic_link
    val unlink = R.drawable.ic_link_off
    val key = R.drawable.ic_key
    val copy = R.drawable.ic_content_copy
    val paste = R.drawable.ic_content_paste
    val pasteGo = R.drawable.ic_content_paste_go
    val openInNew = R.drawable.ic_open_in_new
    val send = R.drawable.ic_send
    val download = R.drawable.ic_download
    val sync = R.drawable.ic_sync

    val phone = R.drawable.ic_smartphone
    val laptop = R.drawable.ic_computer
    val desktop = R.drawable.ic_desktop_windows
    val tablet = R.drawable.ic_tablet
    val tv = R.drawable.ic_tv
    val wifi = R.drawable.ic_wifi
    val wifiOff = R.drawable.ic_wifi_off
    val wifiFind = R.drawable.ic_wifi_find
    val charging = R.drawable.ic_battery_charging_full

    val sendFiles = R.drawable.ic_upload_file
    val camera = R.drawable.ic_photo_camera
    val music = R.drawable.ic_music_note
    val terminal = R.drawable.ic_terminal
    val folderOpen = R.drawable.ic_folder_open
    val ring = R.drawable.ic_ring_volume
    val notifications = R.drawable.ic_notifications
    val notificationsActive = R.drawable.ic_notifications_active
    val call = R.drawable.ic_call

    val previous = R.drawable.ic_skip_previous_fill
    val next = R.drawable.ic_skip_next_fill
    val play = R.drawable.ic_play_arrow_fill
    val pause = R.drawable.ic_pause_fill

    val folder = R.drawable.ic_folder_fill
    val file = R.drawable.ic_draft
    val textFile = R.drawable.ic_description
    val image = R.drawable.ic_image
    val movie = R.drawable.ic_movie
    val audio = R.drawable.ic_audio_file
    val pdf = R.drawable.ic_picture_as_pdf
    val archive = R.drawable.ic_folder_zip
    val codeFile = R.drawable.ic_code
    val home = R.drawable.ic_home
    val drive = R.drawable.ic_hard_drive

    val text = R.drawable.ic_text_fields
    val qr = R.drawable.ic_qr_code_scanner
    val document = R.drawable.ic_document_scanner
    val videocam = R.drawable.ic_videocam_fill
    val videocamOutline = R.drawable.ic_videocam
    val videocamOff = R.drawable.ic_videocam_off
    val switchCamera = R.drawable.ic_cameraswitch
    val flashOn = R.drawable.ic_flash_on
    val flashOff = R.drawable.ic_flash_off
    val flashAuto = R.drawable.ic_flash_auto
    val rotate = R.drawable.ic_rotate_right
    val stop = R.drawable.ic_stop_fill
    val live = R.drawable.ic_fiber_manual_record_fill
    val gallery = R.drawable.ic_photo_library
}

/** An icon from [Ic]. It takes the content color unless [tint] is set. */
@Composable
fun Sym(
    @DrawableRes id: Int,
    contentDescription: String? = null,
    modifier: Modifier = Modifier,
    tint: Color = LocalContentColor.current,
    size: Dp = 24.dp,
) {
    Icon(painterResource(id), contentDescription, modifier.size(size), tint)
}

/** An icon in a tonal circle, for list rows, tiles, and empty states. */
@Composable
fun IconBadge(
    @DrawableRes id: Int,
    modifier: Modifier = Modifier,
    container: Color = MaterialTheme.colorScheme.secondaryContainer,
    content: Color = MaterialTheme.colorScheme.onSecondaryContainer,
    size: Dp = 40.dp,
    shape: Shape = CircleShape,
) {
    Box(modifier.size(size).clip(shape).background(container), contentAlignment = Alignment.Center) {
        Sym(id, tint = content, size = size * 0.55f)
    }
}

/** The icon for a device type from the identity packet. */
@DrawableRes
fun deviceIcon(type: String): Int = when (type) {
    "desktop" -> Ic.desktop
    "phone" -> Ic.phone
    "tablet" -> Ic.tablet
    "tv" -> Ic.tv
    else -> Ic.laptop
}

/** The battery icon for a charge level in percent. */
@DrawableRes
fun batteryIcon(level: Int, charging: Boolean): Int = when {
    charging -> R.drawable.ic_battery_charging_full
    level >= 95 -> R.drawable.ic_battery_full
    level >= 80 -> R.drawable.ic_battery_6_bar
    level >= 65 -> R.drawable.ic_battery_5_bar
    level >= 50 -> R.drawable.ic_battery_4_bar
    level >= 35 -> R.drawable.ic_battery_3_bar
    level >= 20 -> R.drawable.ic_battery_2_bar
    level >= 8 -> R.drawable.ic_battery_1_bar
    else -> R.drawable.ic_battery_0_bar
}

/** The icon for a file on the computer, from its name. */
@DrawableRes
fun fileIcon(name: String, dir: Boolean): Int {
    if (dir) return Ic.folder
    return when (name.substringAfterLast('.', "").lowercase()) {
        "jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "svg", "bmp" -> Ic.image
        "mp4", "mkv", "mov", "webm", "avi" -> Ic.movie
        "mp3", "flac", "ogg", "opus", "wav", "m4a" -> Ic.audio
        "pdf" -> Ic.pdf
        "zip", "tar", "gz", "xz", "zst", "7z", "rar" -> Ic.archive
        "txt", "md", "rtf", "odt", "doc", "docx", "csv" -> Ic.textFile
        "kt", "go", "py", "js", "ts", "c", "h", "cpp", "rs", "sh", "json", "toml", "yaml", "yml", "lua", "qml", "html", "css" -> Ic.codeFile
        else -> Ic.file
    }
}

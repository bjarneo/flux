package org.omarchy.flux.service

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.ui.ClipboardSendActivity

/**
 * The "Send clipboard" Quick Settings tile. A tap starts
 * [ClipboardSendActivity], which reads the clipboard and sends it to each
 * connected paired computer. The tile is active while a paired computer is
 * online.
 */
class ClipboardTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        FluxCore.init(this)
        val online = FluxCore.enabled && FluxCore.connectedPaired().isNotEmpty()
        qsTile?.apply {
            state = if (online) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = "Send clipboard"
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, ClipboardSendActivity::class.java)
            .putExtra(ClipboardSendActivity.EXTRA_MANUAL, true)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // API 34 and later refuse the Intent overload and need a PendingIntent.
        if (Build.VERSION.SDK_INT >= 34) {
            val pi = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pi)
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(intent)
        }
    }
}

package org.omarchy.flux.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Ringer
import org.omarchy.flux.core.Share
import org.omarchy.flux.service.FluxService

/** Shows the Find my phone screen over the lock screen. */
class RingActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        setContent {
            val state by FluxCore.state.collectAsStateWithLifecycle()
            LaunchedEffect(state.ringingFrom) { if (state.ringingFrom == null) finish() }
            FluxTheme {
                RingOverlay(state.ringingFrom ?: "") {
                    Ringer.stop(this)
                    finish()
                }
            }
        }
    }
}

/**
 * The share sheet target. It sends files, text, or a link to a paired
 * computer and stays open until the transfer starts, because Android grants
 * read access to shared files only while this activity lives.
 */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FluxCore.init(this)
        FluxService.start(this)
        val uris = sharedUris(intent)
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        if (uris.isEmpty() && text.isNullOrEmpty()) {
            finish()
            return
        }
        setContent {
            val state by FluxCore.state.collectAsStateWithLifecycle()
            val targets = state.devices.filter { it.paired }
            FluxTheme {
                Box(Modifier.fillMaxSize().clickable { finish() }, contentAlignment = Alignment.Center) {
                    Column(
                        Modifier.width(312.dp).clip(RoundedCornerShape(28.dp)).background(Palette.dialog).clickable(enabled = false) { }.padding(vertical = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        T("Send with Flux", Modifier.padding(horizontal = 24.dp, vertical = 4.dp), size = 22)
                        if (targets.isEmpty()) {
                            T("Pair a computer in Flux first.", Modifier.padding(horizontal = 24.dp, vertical = 8.dp), color = Palette.body)
                        }
                        for (d in targets) {
                            PressRow(onClick = {
                                if (!d.online) {
                                    Toast.makeText(this@ShareActivity, "${d.name} is not reachable", Toast.LENGTH_SHORT).show()
                                } else {
                                    send(d.id, d.name, uris, text)
                                }
                            }) {
                                Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp)) {
                                    T(d.name, size = 16, color = if (d.online) Palette.text else Palette.secondary)
                                    T(if (d.online) "Connected" else "Not reachable", size = 13, color = Palette.secondary)
                                }
                            }
                        }
                        Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp), contentAlignment = Alignment.CenterEnd) {
                            Box(Modifier.clip(RoundedCornerShape(20.dp)).clickable { finish() }.padding(horizontal = 14.dp, vertical = 10.dp)) {
                                T("Cancel", color = Palette.accent, weight = FontWeight.Medium)
                            }
                        }
                    }
                }
            }
        }
    }

    private fun send(id: String, name: String, uris: List<Uri>, text: String?) {
        if (uris.isNotEmpty()) {
            Toast.makeText(this, "Sending to $name", Toast.LENGTH_SHORT).show()
            moveTaskToBack(true)
            // The activity stays alive until the transfer ends, so that the
            // read grant for the shared files stays valid.
            Share.sendFiles(FluxCore, id, uris) { runOnUiThread { finish() } }
        } else if (text != null) {
            Share.sendText(FluxCore, id, text)
            Toast.makeText(this, "Sent to $name", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    @Suppress("DEPRECATION")
    private fun sharedUris(i: Intent): List<Uri> = when (i.action) {
        Intent.ACTION_SEND -> listOfNotNull(
            if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java) else i.getParcelableExtra(Intent.EXTRA_STREAM),
        )
        Intent.ACTION_SEND_MULTIPLE ->
            (if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) else i.getParcelableArrayListExtra(Intent.EXTRA_STREAM))
                ?: emptyList()
        else -> emptyList()
    }
}

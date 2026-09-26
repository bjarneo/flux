package org.omarchy.flux.ui

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
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
            TiledTheme {
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
            val targets = if (state.enabled) state.devices.filter { it.paired } else emptyList()
            TiledTheme {
                val scheme = MaterialTheme.colorScheme
                Box(Modifier.fillMaxSize().clickable { finish() }, contentAlignment = Alignment.Center) {
                    Surface(
                        Modifier.width(328.dp).clickable(enabled = false) { },
                        shape = RoundedCornerShape(28.dp),
                        color = scheme.surfaceContainerHigh,
                    ) {
                        Column(Modifier.padding(vertical = 20.dp)) {
                            Row(
                                Modifier.padding(horizontal = 24.dp, vertical = 4.dp),
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Sym(Ic.send, tint = scheme.primary)
                                Text("Send with Flux", style = MaterialTheme.typography.headlineSmall)
                            }
                            Text(
                                when {
                                    !state.enabled -> "Flux is off. Turn it on in the Flux app to send."
                                    targets.isEmpty() -> "Pair a computer in Flux first."
                                    else -> "Choose a computer."
                                },
                                Modifier.padding(horizontal = 24.dp, vertical = 8.dp),
                                style = MaterialTheme.typography.bodyMedium,
                                color = scheme.onSurfaceVariant,
                            )
                            for (d in targets) {
                                ListItem(
                                    headlineContent = { Text(d.name) },
                                    supportingContent = { Text(if (d.online) "Connected" else "Not reachable") },
                                    leadingContent = {
                                        IconBadge(
                                            deviceIcon(d.type),
                                            container = if (d.online) scheme.primaryContainer else scheme.surfaceContainerHighest,
                                            content = if (d.online) scheme.onPrimaryContainer else scheme.onSurfaceVariant,
                                        )
                                    },
                                    modifier = Modifier.clickable {
                                        if (!d.online) {
                                            Toast.makeText(this@ShareActivity, "${d.name} is not reachable", Toast.LENGTH_SHORT).show()
                                        } else {
                                            send(d.id, d.name, uris, text)
                                        }
                                    }.padding(horizontal = 8.dp),
                                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                                )
                            }
                            Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), contentAlignment = Alignment.CenterEnd) {
                                TextButton(onClick = { finish() }) { Text("Cancel") }
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

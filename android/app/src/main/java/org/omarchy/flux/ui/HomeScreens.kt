package org.omarchy.flux.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.FluxCore

/** The screen while Flux is off. The phone then runs no service and uses no network. */
@Composable
fun FluxOffScreen() {
    val scheme = MaterialTheme.colorScheme
    Column(
        Modifier.fillMaxSize().padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
    ) {
        FluxMark(72.dp)
        Text("Flux is off", style = MaterialTheme.typography.headlineSmall)
        Text(
            "This phone does not connect to computers, uses no network, and shows no notification. Computers show it as not reachable.",
            style = MaterialTheme.typography.bodyMedium,
            color = scheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
        FluxButton("Turn on Flux", { FluxCore.setEnabled(true) }, icon = Ic.power)
    }
}

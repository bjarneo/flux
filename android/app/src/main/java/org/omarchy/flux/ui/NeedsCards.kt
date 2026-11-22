package org.omarchy.flux.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.omarchy.flux.core.AgentDialog
import org.omarchy.flux.core.AgentDialogs
import org.omarchy.flux.core.AgentRow
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.HerdrSync
import org.omarchy.flux.core.QuestionChanged
import org.omarchy.flux.core.answerNeedsKey
import org.omarchy.flux.core.needsCard
import org.omarchy.flux.core.parseDialog

/**
 * The card of a blocked agent in Needs you. It shows `<agent> in <project>
 * needs input`, the question line, and 1 numbered key for each choice when
 * the agent has 3 choices or fewer and the computer takes control. A key asks
 * the phone lock as the dock does, reads the pane again, and sends only when
 * the dialog is the same. Else it opens the agent thread. A tap on the card
 * opens the agent thread. While the computer is not reachable, the keys show
 * dim and take no tap. [many] adds the name of the computer.
 */
@Composable
internal fun AgentNeedsCard(r: AgentRow, device: DeviceUi?, many: Boolean, actions: ChatActions) {
    val context = LocalContext.current
    val demo = isDemo(r.deviceId)
    val pane = r.agent.pane
    var dialog by remember(r.deviceId, pane) {
        mutableStateOf<AgentDialog?>(
            if (demo) device?.herdrOutput?.takeIf { it.pane == pane }?.let { parseDialog(it, System.currentTimeMillis()) } else AgentDialogs.latest(r.deviceId, pane),
        )
    }
    // A new status or a link that comes back reads the pane again.
    LaunchedEffect(r.deviceId, pane, r.at, r.reachable) {
        if (demo || !r.reachable) return@LaunchedEffect
        AgentDialogs.peek(FluxCore, r.deviceId, pane) { d -> if (d != null) dialog = d }
    }
    val card = needsCard(r, dialog)
    var busy by remember(r.deviceId, pane, card.dialogId) { mutableStateOf(false) }
    val open = { actions.open(Route(r.deviceId, "$AGENT_PAGE$pane")) }
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(Tn.tile).border(1.dp, Tn.red, shape)
            .clickable(onClickLabel = "Open the chat", role = Role.Button, onClick = open)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(
            Modifier.fillMaxWidth().semantics(mergeDescendants = true) {},
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            T(card.title, size = 16, weight = FontWeight.SemiBold, maxLines = 2)
            // With agents on more than 1 computer, the card names its computer.
            if (many) T(r.computer, size = 12, color = Tn.sub, family = Mono, maxLines = 1)
            if (card.question.isNotEmpty()) T(card.question, size = 14, color = Tn.sub, maxLines = 3, lineHeight = 1.3f)
        }
        if (card.keys.isNotEmpty()) {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for (c in card.keys) {
                    AskChoice(c, primary = false, enabled = !card.dim && !busy, height = 48.dp, size = 14f) {
                        // A closed link takes no answer. This guard also stops a tap that races the dim.
                        if (!r.reachable) return@AskChoice
                        ReplyLock.run(context, {
                            busy = true
                            answerNeedsKey(
                                c.key, card.dialogId,
                                ready = { FluxCore.locked { FluxCore.device(r.deviceId)?.let { it.herdr?.control == true && it.herdr?.agent(pane)?.status == AgentStatus.Blocked } == true } },
                                verify = { id, same, changed -> AgentDialogs.verify(FluxCore, r.deviceId, pane, id, same, changed) },
                                send = { keys ->
                                    HerdrSync.sendKeys(FluxCore, r.deviceId, pane, keys)
                                    Android.cancelAgent(context.applicationContext, r.deviceId, pane)
                                    busy = false
                                },
                                open = { d ->
                                    busy = false
                                    if (d != null) QuestionChanged.show(r.deviceId, pane)
                                    Android.cancelAgent(context.applicationContext, r.deviceId, pane)
                                    open()
                                },
                            )
                        }, onError = { FluxCore.toast(it) })
                    }
                }
            }
        }
    }
}

/** The place of Needs you when nothing needs the user: a shield, `Nothing needs you`, and the line [line]. */
@Composable
internal fun NeedsEmpty(line: String) {
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(Tn.tile).padding(horizontal = 20.dp, vertical = 18.dp)
            .semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) { Sym(Ic.shield, tint = Tn.green, size = 32.dp) }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T("Nothing needs you", size = 17, weight = FontWeight.SemiBold)
            T(line, size = 14, color = Tn.sub, lineHeight = 1.3f)
        }
    }
}

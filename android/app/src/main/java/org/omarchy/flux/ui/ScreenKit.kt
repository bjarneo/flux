package org.omarchy.flux.ui

import androidx.annotation.DrawableRes
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.delay
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.FluxCore

/*
 * The parts of the destinations and the feature screens of the app design:
 * the header, the strip of pills under it, the progress line, the list
 * headers, and the tiles of the tool grids. The sizes come from the design
 * in dp and sp.
 */

// ───────────────────────── Header ─────────────────────────

/**
 * The header of a destination or a feature screen: the Flux mark, or Back
 * when [onBack] is set, the [title], and the [context] line in mono.
 */
@Composable
internal fun ScreenHeader(title: String, context: String, onBack: (() -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(start = 2.dp, end = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (onBack != null) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClickLabel = "Back", role = Role.Button, onClick = onBack)
                    .semantics { contentDescription = "Back" },
                contentAlignment = Alignment.Center,
            ) { Sym(Ic.back, tint = Tn.text, size = 24.dp) }
        } else {
            Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { FluxMark(22.dp, fg = Tn.text, accent = Tn.blue) }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, Modifier.semantics { heading() }, size = 16, weight = FontWeight.SemiBold, maxLines = 1)
            if (context.isNotEmpty()) LineText(context, size = 11f, lineHeight = MONO_LINE, color = Tn.sub, family = Mono, maxLines = 1)
        }
    }
}

/** "2 of 3 online" for the paired computers, or empty when none is paired. */
internal fun onlineText(devices: List<DeviceUi>): String {
    val paired = devices.filter { it.paired }
    if (paired.isEmpty()) return ""
    return "${paired.count { it.online }} of ${paired.size} online"
}

/** The name of the computer in [scope], or "all computers". */
internal fun scopeName(devices: List<DeviceUi>, scope: String?): String =
    devices.firstOrNull { it.paired && it.id == scope }?.name ?: "all computers"

// ───────────────────────── Pills ─────────────────────────

/** A row of pills under a header. It scrolls to the side. */
@Composable
internal fun PillStrip(content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 10.dp, end = 10.dp, bottom = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        content = content,
    )
}

/**
 * A pill of a [PillStrip]: a [mark], the [label], and [meta] in mono. The
 * [selected] pill has the accent. A [dim] pill shows at 55%, for a
 * computer that is offline. It is 36 dp high and takes taps on 48 dp.
 */
@Composable
internal fun Pill(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    meta: String = "",
    dim: Boolean = false,
    clickLabel: String? = null,
    state: String? = null,
    mark: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(18.dp)
    Row(
        Modifier.overhang(6.dp).alpha(if (dim) DimAlpha else 1f).clip(shape)
            .clickable(onClickLabel = clickLabel, role = Role.Tab, onClick = onClick)
            .semantics { if (state != null) stateDescription = state }
            .padding(vertical = 6.dp).height(36.dp).clip(shape)
            .background(if (selected) Tn.accentTile else Tn.tile).border(1.dp, if (selected) Tn.blue else Tn.line, shape)
            .padding(start = 11.dp, end = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        mark()
        T(label, size = 13, weight = FontWeight.Medium, maxLines = 1)
        if (meta.isNotEmpty()) T(meta, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
    }
}

/** The mark of something that is off or paused: a ring of 10 dp. */
@Composable
internal fun RingMark(size: Dp = 10.dp) {
    Box(Modifier.size(size).border(2.dp, Tn.lineHi, CircleShape))
}

/**
 * The paired computers as pills. The pill of the computer in [scope] has
 * the accent, and a tap on it shows all computers again. A tap on another
 * pill makes that computer the scope. A computer that is offline shows
 * dimmed and does not take the scope.
 */
@Composable
internal fun ComputerStrip(devices: List<DeviceUi>, scope: String?, onScope: (String?) -> Unit) {
    val paired = devices.filter { it.paired }
    if (paired.isEmpty()) return
    PillStrip {
        for (d in paired) {
            val on = d.id == scope
            Pill(
                d.name, on,
                onClick = {
                    when {
                        on -> onScope(null)
                        d.online -> onScope(d.id)
                        else -> FluxCore.toast("${d.name} is not reachable")
                    }
                },
                meta = when {
                    !d.online -> "offline"
                    d.battery != null -> "${d.battery}%"
                    else -> ""
                },
                dim = !d.online,
                clickLabel = if (on) "Show all computers" else "Show only ${d.name}",
                state = listOfNotNull(if (on) "In scope" else null, linkText(d)).joinToString(", "),
            ) {
                if (d.online) Dot(Tn.green, 8.dp) else RingMark()
            }
        }
    }
}

// ───────────────────────── Lines ─────────────────────────

/** The line of 2 dp under the pills. [content] draws the progress on it. */
@Composable
internal fun ProgressLine(content: @Composable BoxScope.() -> Unit = {}) {
    Box(Modifier.fillMaxWidth().height(2.dp).background(Tn.line), content = content)
}

/** The part [fraction] of a [ProgressLine] or a bar in [color]. It moves in 400 ms. */
@Composable
internal fun LineFill(fraction: Float, color: Color, modifier: Modifier = Modifier) {
    val reduce = LocalReduceMotion.current
    val f by animateFloatAsState(fraction.coerceIn(0f, 1f), if (reduce) tween(0) else tween(400), label = "fill")
    Box(modifier.fillMaxHeight().fillMaxWidth(f).background(color))
}

// ───────────────────────── Lists ─────────────────────────

/**
 * The heading of a group of rows: the [title], and [trailing] in mono at
 * the end, such as a count. [action] draws at the end, for example a text
 * action. TalkBack reads the title as a heading.
 */
@Composable
internal fun ListHeader(title: String, trailing: String? = null, action: (@Composable () -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth().padding(start = 4.dp, end = 4.dp, top = 12.dp, bottom = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        T(title, Modifier.weight(1f).semantics { heading() }, size = 14, weight = FontWeight.Medium)
        if (!trailing.isNullOrEmpty()) T(trailing, size = 11, color = Tn.sub, family = Mono, maxLines = 1)
        action?.invoke()
    }
}

/** Lays out [items] in rows of [columns] with the gap [gap]. Each row takes the height of its highest item. */
@Composable
internal fun <T> GridRows(items: List<T>, columns: Int, gap: Dp = TileGap, item: @Composable (T, Modifier) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(gap)) {
        for (row in items.chunked(columns)) {
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(gap)) {
                for (x in row) item(x, Modifier.weight(1f).fillMaxHeight())
                repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

// ───────────────────────── Tools ─────────────────────────

/**
 * A tool of a 2-column grid: the icon at the top, then the [label] and the
 * [sub] line. A tool that is not [enabled] shows dimmed and takes no taps.
 */
@Composable
internal fun GridTool(@DrawableRes icon: Int, label: String, sub: String?, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Tile(
        modifier.heightIn(min = 92.dp), onClick = onClick, enabled = enabled,
        padding = PaddingValues(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Sym(icon, tint = Tn.blue, size = 22.dp)
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(label, size = 14, weight = FontWeight.SemiBold)
            if (!sub.isNullOrEmpty()) T(sub, size = 12, color = Tn.sub, lineHeight = 1.3f)
        }
    }
}

/** A tool of a 3-column grid: the icon over the [label], in the center. */
@Composable
internal fun SmallTool(@DrawableRes icon: Int, label: String, enabled: Boolean, modifier: Modifier, onClick: () -> Unit) {
    Tile(
        modifier.heightIn(min = 64.dp), onClick = onClick, enabled = enabled,
        padding = PaddingValues(horizontal = 6.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Sym(icon, tint = Tn.blue, size = 22.dp)
        T(label, size = 13, weight = FontWeight.SemiBold, align = TextAlign.Center)
    }
}

/**
 * A key of a dock on the page color, such as a tool of Send or an arrow
 * of the Omarchy panel. [description] is the label for TalkBack.
 */
@Composable
internal fun DockKey(
    description: String,
    modifier: Modifier,
    enabled: Boolean = true,
    border: Color? = null,
    radius: Dp = 12.dp,
    onLongClick: (() -> Unit)? = null,
    onClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(radius)
    var m = modifier.alpha(if (enabled) 1f else DimAlpha).clip(shape).background(Tn.bg)
    if (border != null) m = m.border(1.dp, border, shape)
    m = m.combinedClickable(enabled = enabled, onClickLabel = description, role = Role.Button, onLongClick = onLongClick, onClick = onClick)
    Box(m.clearAndSetSemantics { contentDescription = description }, contentAlignment = Alignment.Center) { content() }
}

// ───────────────────────── Time ─────────────────────────

/**
 * The time in milliseconds since the epoch. It changes each [stepMs] while
 * the screen is in the foreground, and when it comes back.
 */
@Composable
internal fun rememberTicker(stepMs: Long): State<Long> {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    return produceState(System.currentTimeMillis(), lifecycle, stepMs) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                value = System.currentTimeMillis()
                delay(stepMs)
            }
        }
    }
}

/** How long ago [at] was, at the time [now]: "just now", "3 min ago", "2 h ago", or "4 days ago". */
internal fun agoText(at: Long, now: Long): String {
    val min = (now - at) / 60_000
    return when {
        min < 1 -> "just now"
        min < 60 -> "$min min ago"
        min < 24 * 60 -> "${min / 60} h ago"
        min < 2 * 24 * 60 -> "1 day ago"
        else -> "${min / (24 * 60)} days ago"
    }
}

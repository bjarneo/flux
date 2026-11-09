package org.omarchy.flux.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.SizeF
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import androidx.core.os.BundleCompat
import org.omarchy.flux.R
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.Approvals
import org.omarchy.flux.ui.isDemo
import java.text.DateFormat
import java.util.Calendar
import java.util.Date

/** The size of a widget when the launcher gives none: the default size of 4 by 2 cells, in dp. */
private val DEFAULT_SIZE = SizeF(250f, 110f)

/**
 * The sizes of 1 widget in dp. Android 12 and later give each size that
 * the launcher shows, for example in portrait and in landscape. An earlier
 * Android gives the least and the most width and height: a phone in
 * portrait uses the least width and the most height.
 */
internal fun sizesOf(options: Bundle?): List<SizeF> {
    if (Build.VERSION.SDK_INT >= 31 && options != null) {
        val sizes = BundleCompat.getParcelableArrayList(options, AppWidgetManager.OPTION_APPWIDGET_SIZES, SizeF::class.java)
        if (!sizes.isNullOrEmpty()) return sizes.distinct().take(MAX_SIZES)
    }
    val minWidth = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH) ?: 0
    val maxWidth = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH) ?: 0
    val minHeight = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT) ?: 0
    val maxHeight = options?.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT) ?: 0
    if (minWidth <= 0 || maxHeight <= 0) return listOf(DEFAULT_SIZE)
    return listOf(SizeF(minWidth.toFloat(), maxHeight.toFloat()), SizeF(maxWidth.toFloat(), minHeight.toFloat())).distinct()
}

/** The most layouts that 1 update can hold, a limit of Android. */
private const val MAX_SIZES = 16

/**
 * The views of 1 widget for its [sizes]. Android 12 and later get 1 layout
 * for each size, and the launcher picks the layout that fits. An earlier
 * Android gets the layout of the first size.
 */
internal fun widgetViews(context: Context, input: WidgetInput, sizes: List<SizeF>): RemoteViews {
    if (Build.VERSION.SDK_INT >= 31 && sizes.size > 1) return RemoteViews(sizes.associateWith { viewsAt(context, input, it) })
    return viewsAt(context, input, sizes.firstOrNull() ?: DEFAULT_SIZE)
}

/**
 * Sets the colors of the views. Android 12 and later get the color of the
 * light and of the dark mode, and the launcher picks the color of its
 * mode. An earlier Android gets the color of the current mode.
 */
private class Paint(private val day: WidgetColors, private val night: WidgetColors, private val dark: Boolean) {
    fun text(v: RemoteViews, id: Int, role: (WidgetColors) -> Int) = color(v, id, "setTextColor", role)

    fun tint(v: RemoteViews, id: Int, role: (WidgetColors) -> Int) = color(v, id, "setColorFilter", role)

    private fun color(v: RemoteViews, id: Int, method: String, role: (WidgetColors) -> Int) {
        val d = OPAQUE or role(day)
        val n = OPAQUE or role(night)
        if (Build.VERSION.SDK_INT >= 31) v.setColorInt(id, method, d, n) else v.setInt(id, method, if (dark) n else d)
    }

    private companion object {
        /** The palette has 0xRRGGBB colors. A view needs the alpha too. */
        const val OPAQUE = 0xFF000000.toInt()
    }
}

private fun visible(show: Boolean) = if (show) View.VISIBLE else View.GONE

/**
 * The views of 1 widget at 1 [size]. The launcher can apply a new update
 * to the views of the last one, so each update sets each view again.
 */
private fun viewsAt(context: Context, input: WidgetInput, size: SizeF): RemoteViews {
    val m = input.model
    val quiet = m.quiet != null
    val config = context.resources.configuration
    // The real size of 12 sp text, because Android 14 and later grow large text less than the font scale.
    val metrics = context.resources.displayMetrics
    val textScale = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, 12f, metrics) / (12f * metrics.density)
    val fit = widgetFit(size.width, size.height, textScale, if (quiet) 1 else m.rows.size)
    val dark = (config.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    val paint = Paint(input.day, input.night, dark)
    val chats = Android.openChats(context)
    val v = RemoteViews(context.packageName, R.layout.widget_agents)
    paint.tint(v, R.id.widget_ground) { it.ground }

    // The header: the mark, the title on a wide widget, and what needs the user. It opens Chats.
    // The mark is dim while no computer can send agents.
    val away = m.quiet != null && m.quiet != WidgetQuiet.NoAgents
    paint.tint(v, R.id.widget_mark_ring) { if (away) it.dim else it.text }
    paint.tint(v, R.id.widget_mark_bar) { if (away) it.dim else it.accent }
    v.setViewVisibility(R.id.widget_title, visible(fit.wide))
    v.setViewVisibility(R.id.widget_spacer, visible(fit.wide))
    paint.text(v, R.id.widget_title) { it.text }
    val needs = m.needsText()
    v.setTextViewText(R.id.widget_needs, needs)
    v.setViewVisibility(R.id.widget_needs, visible(needs.isNotEmpty()))
    paint.text(v, R.id.widget_needs) { it.red }
    // The rows that do not fit show as a count, in the line under the rows or else in the header.
    val rows = if (quiet) emptyList() else m.rows.take(fit.rows)
    val hidden = if (quiet) 0 else m.rows.size - rows.size
    val line = m.contextText(fit.wide, if (fit.more) 0 else hidden)
    v.setTextViewText(R.id.widget_context, line)
    v.setViewVisibility(R.id.widget_context, visible(line.isNotEmpty()))
    paint.text(v, R.id.widget_context) { it.sub }
    v.setOnClickPendingIntent(R.id.widget_header, chats)
    val heard = listOf("Agents", needs, line.removePrefix(" · ")).filter { it.isNotBlank() }.joinToString(", ")
    v.setContentDescription(R.id.widget_header, "$heard. Opens Chats.")

    // The rows, what needs the user first. The views of a row are new in each update.
    v.removeAllViews(R.id.widget_rows)
    for (r in rows) v.addView(R.id.widget_rows, rowViews(context, r, fit, paint))
    v.setViewVisibility(R.id.widget_rows, visible(rows.isNotEmpty()))
    v.setTextViewText(R.id.widget_more, moreText(hidden))
    v.setViewVisibility(R.id.widget_more, visible(fit.more && hidden > 0))
    paint.text(v, R.id.widget_more) { it.sub }
    v.setOnClickPendingIntent(R.id.widget_more, chats)

    // The quiet state: a title and a line in the second ink, with no red and no fill.
    val (title, note) = m.quietText { seenText(context, it) }
    v.setViewVisibility(R.id.widget_quiet, visible(quiet && fit.rows > 0))
    v.setTextViewText(R.id.widget_quiet_title, title)
    v.setTextViewText(R.id.widget_quiet_line, note)
    v.setViewVisibility(R.id.widget_quiet_line, visible(note.isNotEmpty()))
    paint.text(v, R.id.widget_quiet_title) { it.sub }
    paint.text(v, R.id.widget_quiet_line) { it.sub }
    v.setOnClickPendingIntent(R.id.widget_quiet, chats)
    v.setContentDescription(R.id.widget_quiet, listOf(title, note).filter { it.isNotEmpty() }.joinToString(" "))
    return v
}

/**
 * 1 row: the dot, the title, the state word, and the source. A wide
 * widget shows the computer at the end of the title, and a narrow widget
 * puts it at the end of the source. A compact widget shows no source. A
 * row that needs the user takes the tile and a red border.
 */
private fun rowViews(context: Context, r: WidgetRow, fit: WidgetFit, paint: Paint): RemoteViews {
    val wide = fit.wide
    val v = RemoteViews(context.packageName, R.layout.widget_row)
    v.setViewVisibility(R.id.row_fill, visible(r.needs))
    v.setViewVisibility(R.id.row_edge, visible(r.needs))
    v.setImageViewResource(R.id.row_edge, if (r.strong) R.drawable.widget_edge_strong else R.drawable.widget_edge)
    paint.tint(v, R.id.row_fill) { it.tile }
    paint.tint(v, R.id.row_edge) { it.red }
    // An agent that works has a ring in the place of the dot, as the turning ring of the app.
    v.setImageViewResource(R.id.row_dot, if (r.tone == WidgetTone.Works) R.drawable.widget_ring else R.drawable.widget_dot)
    paint.tint(v, R.id.row_dot) { it.dot(r.tone) }
    v.setTextViewText(R.id.row_title, r.title)
    paint.text(v, R.id.row_title) { it.text }
    v.setTextViewText(R.id.row_computer, r.computer)
    v.setViewVisibility(R.id.row_computer, visible(wide && r.computer.isNotEmpty()))
    paint.text(v, R.id.row_computer) { it.sub }
    v.setTextViewText(R.id.row_status, r.status)
    paint.text(v, R.id.row_status) { it.ink(r.tone) }
    val source = if (wide) r.source else listOf(r.source, r.computer).filter { it.isNotBlank() }.joinToString(" · ")
    v.setTextViewText(R.id.row_source, if (source.isEmpty()) "" else " · $source")
    v.setViewVisibility(R.id.row_source, visible(!fit.compact && source.isNotEmpty()))
    paint.text(v, R.id.row_source) { it.sub }
    v.setOnClickPendingIntent(R.id.row_root, open(context, r.target))
    v.setContentDescription(R.id.row_root, listOf(r.title, r.status, r.source, r.computer).filter { it.isNotBlank() }.joinToString(", "))
    return v
}

/** What a tap on a row opens: the chat of the agent or the approval screen, with the same intents as the notifications. */
private fun open(context: Context, t: WidgetTarget): PendingIntent = when (t) {
    is WidgetTarget.Agent -> Android.openAgent(context, t.deviceId, t.pane)
    // The sample approval of a debug build has no approval screen.
    is WidgetTarget.Approval -> if (isDemo(t.computerId)) Android.openChats(context) else Approvals.openScreen(context)
    WidgetTarget.Chats -> Android.openChats(context)
}

/** "at 09:12" for a time today, or else "on" and the short date. */
private fun seenText(context: Context, at: Long): String {
    val day = Calendar.getInstance()
    val then = Calendar.getInstance().apply { timeInMillis = at }
    val today = day.get(Calendar.YEAR) == then.get(Calendar.YEAR) && day.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR)
    return if (today) "at " + android.text.format.DateFormat.getTimeFormat(context).format(Date(at))
    else "on " + DateFormat.getDateInstance(DateFormat.SHORT).format(Date(at))
}

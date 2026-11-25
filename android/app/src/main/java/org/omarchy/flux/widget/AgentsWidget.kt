package org.omarchy.flux.widget

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentCallbacks
import android.content.ComponentName
import android.content.Context
import android.content.res.Configuration
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import org.omarchy.flux.BuildConfig
import org.omarchy.flux.core.Approvals
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.ComputerThemes
import org.omarchy.flux.core.DebugFirstRun
import org.omarchy.flux.core.DebugInbox
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.SeenClock
import org.omarchy.flux.core.UiState
import org.omarchy.flux.theme.resolvePalette
import org.omarchy.flux.ui.demoShown

private const val TAG = "FluxWidget"

/**
 * The agents widget on the home screen. The system calls it when the user
 * adds a widget, changes its size, and after a restart or an update of the
 * app. [AgentsWidgets] draws it.
 */
class AgentsWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, appWidgetIds: IntArray) {
        AgentsWidgets.sync(context)
        AgentsWidgets.update(context, appWidgetIds)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, appWidgetId: Int, newOptions: Bundle) {
        AgentsWidgets.update(context, intArrayOf(appWidgetId))
    }

    override fun onEnabled(context: Context) = AgentsWidgets.sync(context)

    override fun onDisabled(context: Context) = AgentsWidgets.sync(context)
}

/**
 * Keeps the agents widgets current. While the home screen has a widget,
 * it watches the state of the app and draws the widgets again when what
 * they show changes, for example a new agent status or a computer that
 * connects. It sets no alarm and no periodic update, so the widget never
 * wakes the phone: an update comes only from a packet that the link of
 * the computer already received. A burst of changes gives 1 update, and
 * the updates come at most once each [GAP_MS].
 */
object AgentsWidgets {
    /** The wait before the first update after a quiet time, so that a burst of packets gives 1 update. */
    private const val SETTLE_MS = 300L

    /** The least time between 2 updates. */
    private const val GAP_MS = 1_000L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lock = Any()

    /** The watch of the state while a widget exists. The lock guards it. */
    private var watch: Job? = null

    /** The first time that the widget saw each row that has no time of its own. The lock guards it. */
    private val seen = SeenClock()

    /** The font scale, the night mode, and the density of the last drawing. */
    @Volatile private var lastConfig = 0

    @Volatile private var started = false

    /**
     * Starts the updates of the widgets. [org.omarchy.flux.FluxApp] calls
     * it when the app starts. Later calls do nothing.
     */
    fun start(context: Context) {
        if (started) return
        started = true
        val app = context.applicationContext
        lastConfig = configKey(app.resources.configuration)
        // A new font size changes the number of rows. Android 11 and earlier also need a new drawing for a new night mode.
        app.registerComponentCallbacks(object : ComponentCallbacks {
            override fun onConfigurationChanged(newConfig: Configuration) {
                val key = configKey(newConfig)
                if (key == lastConfig) return
                lastConfig = key
                update(app, ids(app))
            }

            @Deprecated("Deprecated in Java")
            override fun onLowMemory() = Unit
        })
        sync(app)
    }

    private fun configKey(c: Configuration): Int =
        listOf(c.fontScale, c.uiMode and Configuration.UI_MODE_NIGHT_MASK, c.densityDpi).hashCode()

    /** Starts the watch when the home screen has a widget, and stops it when the last widget goes. */
    fun sync(context: Context) {
        val app = context.applicationContext
        val any = ids(app).isNotEmpty()
        synchronized(lock) {
            if (any && watch?.isActive != true) watch = scope.launch { watch(app) }
            if (!any) {
                watch?.cancel()
                watch = null
            }
        }
    }

    /** Draws the widgets [ids] at once from the current state. */
    fun update(context: Context, ids: IntArray) {
        if (ids.isEmpty()) return
        val app = context.applicationContext
        draw(app, input(FluxCore.state.value, Approvals.current.value), ids)
    }

    /**
     * Asks the launcher to add the widget to the home screen. The launcher
     * shows its own dialog. It returns false when the launcher cannot do it.
     */
    fun requestPin(context: Context): Boolean {
        val manager = AppWidgetManager.getInstance(context) ?: return false
        if (!manager.isRequestPinAppWidgetSupported) return false
        return manager.requestPinAppWidget(ComponentName(context, AgentsWidget::class.java), null, null)
    }

    private fun ids(context: Context): IntArray = runCatching {
        AppWidgetManager.getInstance(context)?.getAppWidgetIds(ComponentName(context, AgentsWidget::class.java))
    }.getOrNull() ?: IntArray(0)

    private suspend fun watch(app: Context) {
        var last = 0L
        combine(FluxCore.state, Approvals.current) { state, approval -> input(state, approval) }
            .distinctUntilChanged()
            .collectLatest { input ->
                // A newer change cancels this wait, so the widget shows the newest state.
                delay(maxOf(SETTLE_MS, last + GAP_MS - SystemClock.elapsedRealtime()))
                draw(app, input, ids(app))
                last = SystemClock.elapsedRealtime()
            }
    }

    /**
     * What the widget shows for [state]. A debug build with the demo adds
     * the sample data, as the app does. The colors follow the theme setting
     * of the app with the theme of all computers. [WidgetInput.day] and
     * [WidgetInput.night] differ only when the palette follows the phone.
     */
    private fun input(state: UiState, approval: ApproveRequest?): WidgetInput {
        val s = if (BuildConfig.DEBUG) DebugInbox.decorate(DebugFirstRun.decorate(state)) else state
        val shown = approval ?: if (demoShown()) DebugInbox.approval() else null
        val model = synchronized(lock) { widgetModel(s.devices, shown, s.enabled, s.connecting, seen, System.currentTimeMillis()) }
        val computer = ComputerThemes.latest()?.palette
        return WidgetInput(
            model,
            day = WidgetColors.of(resolvePalette(s.theme, computer, systemDark = false)),
            night = WidgetColors.of(resolvePalette(s.theme, computer, systemDark = true)),
        )
    }

    private fun draw(context: Context, input: WidgetInput, ids: IntArray) {
        if (ids.isEmpty()) return
        val manager = AppWidgetManager.getInstance(context) ?: return
        for (id in ids) {
            runCatching { manager.updateAppWidget(id, widgetViews(context, input, sizesOf(manager.getAppWidgetOptions(id)))) }
                .onFailure { Log.w(TAG, "the widget $id did not update", it) }
        }
    }
}

package org.omarchy.flux.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bodyOf
import org.omarchy.flux.protocol.str

/** 1 key binding of Hyprland on the computer. [ref] runs it, and [keys] is its combination, such as "SUPER SHIFT RETURN". */
data class Shortcut(val ref: String, val keys: String, val description: String)

/** 1 workspace of the computer with its number of windows. */
data class WorkspaceInfo(val id: Int, val windows: Int)

/**
 * The key bindings and the workspaces of a computer, for the Omarchy panel.
 * [loaded] is false until the first answer.
 */
data class ShortcutsState(
    val shortcuts: List<Shortcut> = emptyList(),
    val workspaces: List<WorkspaceInfo> = emptyList(),
    val active: Int = 0,
    val error: String? = null,
    val loaded: Boolean = false,
)

/**
 * flux.shortcuts: the phone moves around Omarchy. The computer sends its
 * key bindings and workspaces, and it runs a binding or an action for the
 * phone. It needs remote_input on the computer.
 */
object Shortcuts {
    enum class Action(val key: String) {
        Close("close"), Fullscreen("fullscreen"), Float("float"), Split("split"), Scratchpad("scratchpad"),
        NextWindow("nextWindow"), NextWorkspace("nextWorkspace"), PreviousWorkspace("previousWorkspace"),
    }

    /** The directions of focus and swap. */
    enum class Direction(val key: String, val label: String) { Left("l", "←"), Up("u", "↑"), Down("d", "↓"), Right("r", "→") }

    /** The highest workspace that the phone can select. */
    const val MAX_WORKSPACE = 10

    /** The shortcuts that the Omarchy panel pins until the user pins others. */
    val DEFAULT_PINS = listOf("Omarchy menu", "Apps menu", "Terminal", "Browser", "File manager", "Screenshot")

    /** Asks for the key bindings and the workspaces. */
    fun request() = Packet(Types.FLUX_SHORTCUTS, bodyOf("request" to true))

    /** Asks for the workspaces only. */
    fun refresh() = Packet(Types.FLUX_SHORTCUTS)

    fun run(s: Shortcut) = Packet(Types.FLUX_SHORTCUTS, bodyOf("run" to s.ref))

    fun action(a: Action) = Packet(Types.FLUX_SHORTCUTS, bodyOf("action" to a.key))

    fun workspace(id: Int) = Packet(Types.FLUX_SHORTCUTS, bodyOf("action" to "workspace", "workspace" to id))

    fun moveToWorkspace(id: Int) = Packet(Types.FLUX_SHORTCUTS, bodyOf("action" to "moveToWorkspace", "workspace" to id))

    fun focus(d: Direction) = Packet(Types.FLUX_SHORTCUTS, bodyOf("action" to "focus", "direction" to d.key))

    fun swap(d: Direction) = Packet(Types.FLUX_SHORTCUTS, bodyOf("action" to "swap", "direction" to d.key))

    /**
     * The workspace action for a digit that the keyboard types with super,
     * as the Omarchy bindings do: super and a digit selects the workspace,
     * and super, shift, and a digit moves the window there. 0 is workspace
     * 10. It returns null for other keys.
     */
    fun forDigit(text: String, mods: RemoteInput.Mods): Packet? {
        val digit = text.singleOrNull()?.digitToIntOrNull() ?: return null
        if (!mods.meta || mods.ctrl || mods.alt) return null
        val id = if (digit == 0) MAX_WORKSPACE else digit
        return if (mods.shift) moveToWorkspace(id) else workspace(id)
    }

    /**
     * Returns the state after an answer. An answer without the list keeps
     * the list of [old]. An error keeps the rest of [old].
     */
    fun merge(old: ShortcutsState?, p: Packet): ShortcutsState {
        val base = old ?: ShortcutsState()
        p.string("error")?.takeIf { it.isNotEmpty() }?.let { return base.copy(error = it, loaded = true) }
        val list = p.array("shortcuts")?.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val ref = o.str("ref") ?: return@mapNotNull null
            val description = o.str("description") ?: return@mapNotNull null
            Shortcut(ref, o.str("keys") ?: "", description)
        }
        val workspaces = p.array("workspaces")?.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            val id = (o["id"] as? JsonPrimitive)?.intOrNull ?: return@mapNotNull null
            WorkspaceInfo(id, (o["windows"] as? JsonPrimitive)?.intOrNull ?: 0)
        }
        return base.copy(
            shortcuts = list ?: base.shortcuts,
            workspaces = workspaces ?: base.workspaces,
            active = p.int("active") ?: base.active,
            error = null,
            loaded = true,
        )
    }

    /** The shortcuts that the panel pins, in the order of [pins]. */
    fun pinned(all: List<Shortcut>, pins: List<String>): List<Shortcut> =
        pins.mapNotNull { name -> all.firstOrNull { it.description == name } }

    /** The shortcuts that match [query] in the description or the keys. */
    fun search(all: List<Shortcut>, query: String): List<Shortcut> {
        val words = query.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return all
        return all.filter { s ->
            val text = (s.description + " " + s.keys).lowercase()
            words.all { it in text }
        }
    }

    /** The keys of a shortcut for a label, such as "super shift return". */
    fun keysLabel(keys: String): String = keys.lowercase()
}

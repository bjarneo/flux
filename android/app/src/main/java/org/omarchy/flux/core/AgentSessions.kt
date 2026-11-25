package org.omarchy.flux.core

/**
 * The Agents group of Chats for the herdr sessions of the computers. A
 * computer with 2 or more herdr sessions shows only the agents of its
 * picked session. A computer with 1 session shows all its agents. The
 * Needs you group does not use this filter, so it keeps the blocked agents
 * of all sessions.
 */

/** The computers that get a session strip: paired, online, and with 2 or more herdr sessions. */
fun stripComputers(devices: List<DeviceUi>): List<DeviceUi> =
    devices.filter { it.paired && it.online && it.herdr?.let { h -> h.anyRunning && h.manySessions } == true }

/**
 * The rows of [agents] that the picked sessions allow. [picked] gives the
 * picked session of a computer, or null when the user picked none.
 */
fun agentsOfPickedSessions(agents: List<AgentRow>, devices: List<DeviceUi>, picked: (String) -> String?): List<AgentRow> {
    val many = stripComputers(devices).associate { it.id to it.herdr!! }
    return agents.filter { r ->
        val h = many[r.deviceId] ?: return@filter true
        r.agent.session == h.sessionOrDefault(picked(r.deviceId)).name
    }
}

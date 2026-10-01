package org.omarchy.flux.core

/**
 * Debug builds only: the first run and the pairing success state on an
 * emulator with no computer. It uses the sample computers of [DebugDemo],
 * so it works only while the demo is on. The debug pages `firstrun` and
 * `paired` set [mode]. See the Test section of docs/android.md.
 */
object DebugFirstRun {
    enum class Mode {
        /** The state stays as it is. */
        Off,

        /** No computer is paired. The sample computer to pair shows on the network. */
        FirstRun,

        /** The sample computer to pair is the only paired computer. */
        Paired,
    }

    @Volatile var mode = Mode.Off

    /** The state for [mode]. With the demo off, the state stays as it is. */
    fun decorate(state: UiState): UiState {
        if (!DebugDemo.on) return state
        return when (mode) {
            Mode.Off -> state
            Mode.FirstRun -> state.copy(devices = state.devices.filter { !it.paired })
            Mode.Paired -> state.copy(
                devices = state.devices.filter { it.id == DebugDemo.NEW }.map { it.copy(paired = true, pairState = PairState.Paired) },
            )
        }
    }
}

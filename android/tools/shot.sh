#!/usr/bin/env bash
# Takes a screenshot of one Flux page on a connected test phone. Debug builds only.
# Usage: tools/shot.sh <page> <out.png>
# Pages: see the Test section of docs/android.md.
set -euo pipefail
page=$1
out=$2
adb shell input keyevent KEYCODE_WAKEUP
# FLUX_DEMO=1 shows the sample computers, for an emulator with no computer.
# FLUX_THEME=<name> gives the sample computer a sample theme, or none.
# FLUX_SESSIONS=1 gives the sample computer named herdr sessions.
# FLUX_CONTROL=0 turns Agent control off on the sample computer.
# FLUX_BLOCKED=0 gives the sample computers no blocked agent, for the empty state of Chats.
# FLUX_SESSION=<name> picks one of them, or default.
extras=()
if [ -n "${FLUX_THEME:-}" ]; then extras=(--es flux.debug.theme "$FLUX_THEME"); fi
if [ "${FLUX_SESSIONS:-}" = 1 ]; then extras+=(--ez flux.debug.sessions true); fi
if [ "${FLUX_CONTROL:-}" = 0 ]; then extras+=(--ez flux.debug.control false); fi
if [ "${FLUX_BLOCKED:-}" = 0 ]; then extras+=(--ez flux.debug.blocked false); fi
if [ -n "${FLUX_SESSION:-}" ]; then extras+=(--es flux.debug.session "$FLUX_SESSION"); fi
adb shell am start -n org.omarchy.flux/.ui.MainActivity --ez flux.debug.showWhenLocked true \
    --ez flux.debug.demo "$([ "${FLUX_DEMO:-}" = 1 ] && echo true || echo false)" --es flux.debug.page "$page" \
    ${extras[@]+"${extras[@]}"} >/dev/null 2>&1
sleep "${FLUX_SHOT_DELAY:-2}"
adb exec-out screencap -p >"$out"

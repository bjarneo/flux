#!/usr/bin/env bash
# Takes a screenshot of one Flux page on a connected test phone. Debug builds only.
# Usage: tools/shot.sh <page> <out.png>
# Pages: see the Test section of android/README.md.
set -euo pipefail
page=$1
out=$2
adb shell input keyevent KEYCODE_WAKEUP
# FLUX_DEMO=1 shows the sample computers, for an emulator with no computer.
adb shell am start -n org.omarchy.flux/.ui.MainActivity --ez flux.debug.showWhenLocked true \
    --ez flux.debug.demo "$([ "${FLUX_DEMO:-}" = 1 ] && echo true || echo false)" --es flux.debug.page "$page" >/dev/null 2>&1
sleep "${FLUX_SHOT_DELAY:-2}"
adb exec-out screencap -p >"$out"

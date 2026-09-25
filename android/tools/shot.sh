#!/usr/bin/env bash
# Takes a screenshot of one Flux page on a connected test phone. Debug builds only.
# Usage: tools/shot.sh <page> <out.png>
# Pages: devices, home, media, commands, browse, camera, ring, icon
set -euo pipefail
page=$1
out=$2
adb shell input keyevent KEYCODE_WAKEUP
adb shell am start -n org.omarchy.flux/.ui.MainActivity --ez flux.debug.showWhenLocked true --es flux.debug.page "$page" >/dev/null 2>&1
sleep "${FLUX_SHOT_DELAY:-2}"
adb exec-out screencap -p >"$out"

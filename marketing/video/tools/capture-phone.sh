#!/bin/bash
# Takes the phone captures of the videos on the Android emulator, with the
# sample computers of the debug build and a fixed status bar. The captures
# go to assets/cap. Run tools/bake-phone.sh after this script.
#
#   ANDROID_SERIAL=emulator-5554 tools/capture-phone.sh
#
# Use an emulator, not a personal phone: the captures show the screen as it
# is. The emulator needs a debug build of Flux for Android and night mode.
# Set the device name of the emulator to Pixel 8 in the system settings.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ANDROID_SERIAL:?Set ANDROID_SERIAL to the emulator, for example emulator-5554}"
export ANDROID_SERIAL
REPO=$(git rev-parse --show-toplevel)
SHOT="$REPO/android/tools/shot.sh"
OUT=$PWD/assets/cap
mkdir -p "$OUT"

demo() { adb shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }
shot() { FLUX_DEMO=1 FLUX_SHOT_DELAY=3 "$SHOT" "$1" "$OUT/$2"; }

adb shell settings put global sysui_demo_allowed 1
trap 'demo exit; adb shell settings put global sysui_demo_allowed 0' EXIT
demo enter
demo clock -e hhmm 0941
demo battery -e level 100 -e plugged false
demo notifications -e visible false

# On Wi-Fi.
demo network -e wifi show -e level 4 -e fully true
demo network -e mobile show -e datatype none -e level 4
shot home herdr-home.png
shot agents herdr-agents.png
shot agent:w2:p1 herdr-agent_w2_p1.png
shot agent:w1:p1 herdr-agent_w1_p1.png
shot home@offline ts-home-offline-wifi.png

# On mobile data. The emulator shows no signal icon, so the bake adds it.
demo network -e wifi hide
demo network -e mobile show -e datatype 5g -e level 4
shot home ts-home-5g.png
shot home@offline ts-home-offline-5g.png
shot agents ts-agents-5g.png

ls "$OUT"

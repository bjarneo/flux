#!/usr/bin/env bash
# Takes the phone images of the website on an Android emulator, with the
# sample computers of the debug build. The status bar clock shows the time
# of each moment on the page. The images go to site/img/phone as WebP.
#
#   ANDROID_SERIAL=emulator-5582 site/tools/capture-phone.sh
#
# Use an emulator, not a personal phone: a capture shows the whole screen.
# The emulator needs a debug build of Flux for Android, night mode, and a
# 1080 x 2400 screen, such as the pixel_6 device. The taps use that size.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${ANDROID_SERIAL:?Set ANDROID_SERIAL to the emulator, for example emulator-5582}"
export ANDROID_SERIAL
RAW=${RAW:-$HOME/.cache/flux-site-caps/raw}
OUT=site/img/phone
mkdir -p "$RAW" "$OUT"

demo() { adb shell am broadcast -a com.android.systemui.demo -e command "$@" >/dev/null; }
at() { demo clock -e hhmm "$1"; }
page() { FLUX_DEMO=1 FLUX_SHOT_DELAY=${DELAY:-3} FLUX_THEME=${THEME:-} android/tools/shot.sh "$1" "$RAW/$2.png"; }
snap() { sleep "${1:-2}"; adb exec-out screencap -p >"$RAW/$2.png"; }
wifi() { demo network -e wifi show -e level 4 -e fully true; demo network -e mobile hide; }
mobile() { demo network -e wifi hide; demo network -e mobile show -e datatype lte -e level 3 -e slot 0 -e sims 1; }

adb shell settings put system time_12_24 24
adb shell settings put global sysui_demo_allowed 1
trap 'demo exit; adb shell settings put global sysui_demo_allowed 0' EXIT
demo enter
demo battery -e level 86 -e plugged false
demo notifications -e visible false
wifi

# The Inbox of omarchy-xps from a new start, so that no earlier swipe stays.
xps() {
    adb shell am force-stop org.omarchy.flux
    page inbox "$1"
    for _ in 1 2 3; do
        adb shell input tap 377 207 # the scope chip
        sleep 1.5
        adb shell input tap 365 443 # omarchy-xps
        sleep 1.5
        adb shell uiautomator dump /sdcard/ui.xml >/dev/null
        adb exec-out cat /sdcard/ui.xml | grep -q 'Scope: omarchy-xps' && break
    done
    snap 1 "$1"
}

# 14:07. The agent that waits is in the master tile.
at 1407
xps inbox-agent
at 1409
page agent:w2:p1 agent-output

# 14:22. Later on the agent moves the approval into the master tile.
at 1422
xps inbox-approval
adb shell input tap 936 501 # Later
snap 2 inbox-approval

# Away from the desk, on mobile data through Tailscale.
mobile
at 1540
page send send
at 1612
page browse browse
wifi

# Back home and at the desk.
at 1730
page media media
at 1802
page omarchy omarchy
at 1834
page touchpad touchpad
at 1851
page ring ring
at 0941
page pair pair

# The same Inbox in other Omarchy themes.
at 1407
for t in catppuccin-latte neon futurism cotton-candy; do
    THEME=$t xps "theme-$t"
done
adb shell am force-stop org.omarchy.flux

for f in "$RAW"/*.png; do
    n=$(basename "$f" .png)
    magick "$f" -resize 720x -quality 84 -define webp:method=6 "$OUT/$n.webp"
done
ls -l "$OUT"

#!/bin/sh
# Take a screenshot of one Flux for iOS page on the booted simulator.
# Mirrors android/tools/shot.sh. Uses FLUX_DEMO=1 sample computers, so no
# computer is needed.
#
# Usage: ios/tools/shot.sh <page> <output.png> [device]
# Pages: devices home media commands browse mic camera camera:<mode>
#        ring pair unpair <page>@offline empty icon
set -eu
PAGE="${1:?usage: shot.sh <page> <output.png> [device]}"
OUT="${2:?usage: shot.sh <page> <output.png> [device]}"
DEVICE="${3:-iPhone 16}"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl terminate "$DEVICE" org.omarchy.flux 2>/dev/null || true
# The app reads -FLUX_DEMO and the page from launch args (M1+ UI).
xcrun simctl launch "$DEVICE" org.omarchy.flux -FLUX_DEMO 1 -FLUX_PAGE "$PAGE" >/dev/null
sleep 2
xcrun simctl io "$DEVICE" screenshot "$OUT"
echo "saved $OUT ($PAGE on $DEVICE)"

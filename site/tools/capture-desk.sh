#!/usr/bin/env bash
# Renders the desktop window images of the website from the snapshot mode
# of flux-gui, at 2x scale. The images go to site/img/desk as WebP.
#
#   site/tools/capture-desk.sh
#
# Run `make build-gui` first.
set -euo pipefail
cd "$(dirname "$0")/../.."
RAW=${RAW:-$HOME/.cache/flux-site-caps/desk}
OUT=site/img/desk
mkdir -p "$RAW" "$OUT"
# The device page of Pixel 8, with all 4 parts. It needs a tall window.
QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=2 FLUX_SNAPSHOT_SIZE=1180x1250 gui/app/build/flux-gui --snapshot "$RAW"
magick "$RAW/10-device.png" -resize 1600x -quality 86 -define webp:method=6 "$OUT/remote-live.webp"
# The Access card of the device page, at full 2x size.
magick "$RAW/10-device.png" -crop 1768x758+556+488 +repage -quality 86 -define webp:method=6 "$OUT/device-access.webp"
ls -l "$OUT"

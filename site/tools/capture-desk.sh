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
QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=2 gui/app/build/flux-gui --snapshot "$RAW"
magick "$RAW/47-remote-live.png" -resize 1600x -quality 86 -define webp:method=6 "$OUT/remote-live.webp"
# The Device access panel of the Overview, at full 2x size. It needs a
# taller window to show all its switches.
mkdir -p "$RAW/tall"
QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR=2 FLUX_SNAPSHOT_SIZE=1180x1100 gui/app/build/flux-gui --snapshot "$RAW/tall"
magick "$RAW/tall/01-overview.png" -crop 880x948+560+924 +repage -quality 86 -define webp:method=6 "$OUT/device-access.webp"
ls -l "$OUT"

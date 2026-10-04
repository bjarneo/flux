#!/usr/bin/env bash
# Renders the social preview of the website from site/tools/og.html into
# site/img/og.png, at 1200 x 630.
#
#   site/tools/render-og.sh
#
# It needs Chromium at /usr/bin/chromium, or set CHROMIUM.
set -euo pipefail
cd "$(dirname "$0")/../.."
"${CHROMIUM:-/usr/bin/chromium}" --headless --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --window-size=1200,630 --virtual-time-budget=4000 \
    --allow-file-access-from-files \
    --screenshot="$PWD/site/img/og.png" "file://$PWD/site/tools/og.html" 2>/dev/null
magick site/img/og.png -strip -define png:compression-level=9 site/img/og.png
magick identify site/img/og.png

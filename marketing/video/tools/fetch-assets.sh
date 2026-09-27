#!/bin/bash
# Copies the fonts and the wallpaper of the videos into assets/. Git does
# not keep these files. Run npm ci first, and start the Android emulator.
#
#   ANDROID_SERIAL=emulator-5554 tools/fetch-assets.sh
#
# Sources:
#   JetBrains Mono Nerd Font   the ttf-jetbrains-mono-nerd package, as on Omarchy
#   Inter                      the @fontsource-variable/inter npm package
#   Roboto, Droid Sans         /system/fonts of the Android emulator, through adb
#   3-sunset-lake              the Tokyo Night background of Omarchy
set -euo pipefail
cd "$(dirname "$0")/.."
: "${ANDROID_SERIAL:?Set ANDROID_SERIAL to the emulator, for example emulator-5554}"
export ANDROID_SERIAL
F=assets/fonts
W=assets/wallpapers
mkdir -p "$F" "$W"

need() {
  [[ -f $1 ]] || { echo "Missing $1. $2" >&2; exit 1; }
}

JB=/usr/share/fonts/TTF/JetBrainsMonoNerdFont
need "$JB-Regular.ttf" "Install it: sudo pacman -S ttf-jetbrains-mono-nerd"
cp "$JB-Regular.ttf" "$JB-Bold.ttf" "$F/"

INTER=node_modules/@fontsource-variable/inter/files/inter-latin-wght-normal.woff2
need "$INTER" "Run npm ci first."
cp "$INTER" "$F/inter.woff2"

adb pull -q /system/fonts/DroidSansMono.ttf "$F/DroidSansMono.ttf"
adb pull -q /system/fonts/DroidSans-Bold.ttf "$F/DroidSans-Bold.ttf"
adb pull -q /system/fonts/RobotoStatic-Regular.ttf "$F/RobotoStatic-Regular.ttf"
adb pull -q /system/fonts/Roboto-Regular.ttf "$F/Roboto-Var.ttf"

BG=/usr/share/omarchy/themes/tokyo-night/backgrounds/3-sunset-lake.webp
need "$BG" "Omarchy installs it with the Tokyo Night theme."
magick "$BG" -resize '3200x2000^' -gravity center -extent 3200x2000 -quality 92 "$W/3-sunset-lake.jpg"

ls "$F" "$W"

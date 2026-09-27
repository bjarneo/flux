#!/bin/bash
# Bakes the phone screens of both videos from the emulator captures in
# assets/cap into assets/phone. Run tools/capture-phone.sh first. The patches use the fonts of the app:
# Droid Sans Mono is the Android monospace font.
#   ip TEXT     the header "Omarchy · TEXT"
#   mpv         the player label on the media tile, in place of Spotify
#   5g          a 5G label and full signal bars in the status bar, for a phone
#               without Wi-Fi. It first clears the icons left of the battery,
#               because the emulator shows no mobile icon or a 3G icon.
#   nobadge     the Agents tile with no blocked count: the badge area gets the
#               tile color, and the left half of the symmetric robot icon,
#               mirrored at x 933.5, replaces its right half
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p assets/phone
MONO=assets/fonts/DroidSansMono.ttf
BOLD=assets/fonts/DroidSans-Bold.ttf

bake() {
  local src=$1 out=$2; shift 2
  local args=()
  while (($#)); do
    case $1 in
      ip) args+=(-fill '#16161E' -draw 'rectangle 150,176 620,224' -font "$MONO" -pointsize 31.5 -fill '#565F89' -annotate +153+207 "Omarchy · $2"); shift 2 ;;
      mpv) args+=(-fill '#1F2335' -draw 'rectangle 540,1060 670,1100' -font "$MONO" -pointsize 26.5 -fill '#565F89' -annotate +611.6+1088 'mpv'); shift ;;
      5g) args+=(-fill '#16161E' -draw 'rectangle 840,40 979,88' -fill white -draw 'polygon 944,80 977,80 977,47' -font "$BOLD" -pointsize 27 -annotate +896+75 '5G'); shift ;;
      nobadge) args+=(-fill '#1F2335' -draw 'rectangle 944,1394 992,1430' '(' "assets/cap/$src" -crop 29x70+905+1395 +repage -flop ')' -geometry +934+1395 -composite); shift ;;
      *) echo "unknown patch $1" >&2; exit 1 ;;
    esac
  done
  magick "assets/cap/$src" "${args[@]}" "assets/phone/$out"
}

# herdr video. The phone is on the home Wi-Fi.
bake herdr-home.png home.png ip 192.168.1.20 mpv
bake herdr-home.png home-nobadge.png ip 192.168.1.20 mpv nobadge
bake herdr-agents.png agents.png
bake herdr-agent_w2_p1.png agent-codex.png

# Tailscale video. At home on Wi-Fi, then away on 5G through Tailscale.
bake herdr-home.png ts-home-wifi.png ip 192.168.1.20 mpv
bake ts-home-offline-5g.png ts-offline-5g.png ip 192.168.1.20 5g
bake ts-home-5g.png ts-home-5g.png ip 100.101.102.10 mpv 5g
bake ts-agents-5g.png ts-agents-5g.png 5g
echo baked: $(ls assets/phone)

# The screens that only the herdr video uses.
scenes/herdr/make.sh

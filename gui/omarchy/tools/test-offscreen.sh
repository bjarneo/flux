#!/usr/bin/env bash
# Starts an isolated, offscreen omarchy-shell with the Flux plugin, for tests.
# It never touches the running shell, ~/.config/omarchy, or the session bus:
#   - a copy of the Omarchy shell tree, so the Quickshell instance ID differs
#   - a separate HOME with its own shell.json, plugins, and theme
#   - a private D-Bus session, and no Wayland or Hyprland connection
#   - the first-party services that own system resources stay off
#
# Usage: test-offscreen.sh WORKDIR [copy|link] [FLUX_SOCKET]
#   copy  installs the plugin as a copy with the test wrappers (default)
#   link  installs the plugin as a symlink to this checkout, unchanged
# To stop the shell, run: pkill -f "qs -p WORKDIR/omarchy/shell"
set -euo pipefail

work=${1:?Usage: test-offscreen.sh WORKDIR [copy|link] [FLUX_SOCKET]}
mode=${2:-copy}
socket=${3:-${XDG_RUNTIME_DIR:-/tmp}/flux/fluxd.sock}
plugin_src=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/..
plugin_src=$(realpath -- "$plugin_src")
omarchy_src=${OMARCHY_SOURCE:-/usr/share/omarchy}

root="$work/omarchy"
home="$work/home"
shots="$work/shots"
plugins="$home/.config/omarchy/plugins"
mkdir -p "$root" "$home/.config/omarchy" "$home/.local/state/omarchy/current/theme" "$plugins" "$shots"

rm -rf "$root/shell" "$root/config"
cp -r "$omarchy_src/shell" "$omarchy_src/config" "$root/"
cp "$omarchy_src/themes/tokyo-night/colors.toml" "$home/.local/state/omarchy/current/theme/colors.toml"

# The offscreen platform has no layer-shell backend, so PanelWindow does not
# load. In this copy only, a FloatingWindow stands in for it, and the bar
# renders in a normal offscreen window.
cat > "$root/shell/Commons/OffscreenEdges.qml" <<'QML'
import QtQuick

// Test only: the anchors and margins groups of OffscreenPanelWindow.
QtObject {
  property var top: 0
  property var bottom: 0
  property var left: 0
  property var right: 0
}
QML
cat > "$root/shell/Commons/OffscreenPanelWindow.qml" <<'QML'
import QtQuick
import Quickshell

// Test only: stands in for PanelWindow under QT_QPA_PLATFORM=offscreen.
FloatingWindow {
  property int exclusionMode: 0
  property int exclusiveZone: 0
  property bool aboveWindows: true
  property bool focusable: false
  property OffscreenEdges anchors: OffscreenEdges {}
  property OffscreenEdges margins: OffscreenEdges {}
}
QML
printf '%s\n' "OffscreenEdges 1.0 OffscreenEdges.qml" "OffscreenPanelWindow 1.0 OffscreenPanelWindow.qml" >> "$root/shell/Commons/qmldir"
grep -rlw --include='*.qml' PanelWindow "$root/shell" | xargs sed -i 's/\bPanelWindow\b/OffscreenPanelWindow/g'

rm -rf "$plugins/flux"
if [[ $mode == link ]]; then
  ln -s "$plugin_src" "$plugins/flux"
else
  # The install layout: the plugin files, with the shared QML copied into Flux/.
  mkdir -p "$plugins/flux"
  cp "$plugin_src"/*.qml "$plugin_src/manifest.json" "$plugins/flux/"
  cp -rL "$plugin_src/Flux" "$plugins/flux/Flux"
  cp -r "$plugin_src/tools" "$plugins/flux/tools"
  python3 - "$plugins/flux/manifest.json" <<'EOF'
import json, sys
path = sys.argv[1]
m = json.load(open(path))
m["entryPoints"]["panel"] = "tools/TestPanel.qml"
m["entryPoints"]["barWidget"] = "tools/TestBarWidget.qml"
json.dump(m, open(path, "w"), indent=2)
EOF
fi

cat > "$home/.config/omarchy/shell.json" <<'EOF'
{
  "version": 1,
  "bar": {
    "position": "top",
    "layout": {
      "left": [],
      "center": [{ "id": "omarchy.clock", "format": "ddd MMM d HH:mm" }],
      "right": [{ "id": "flux" }]
    }
  },
  "disabledPlugins": [
    "omarchy.background", "omarchy.clipboard", "omarchy.emojis", "omarchy.idle",
    "omarchy.image-picker", "omarchy.lock", "omarchy.media", "omarchy.menu",
    "omarchy.nightlight", "omarchy.notifications", "omarchy.osd", "omarchy.polkit",
    "omarchy.reminders"
  ],
  "plugins": []
}
EOF

# The gtk3 platform theme exits the process when it has no display.
env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY -u QT_QPA_PLATFORMTHEME -u QT_IM_MODULE \
  HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" \
  XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
  OMARCHY_PATH="$root" FLUX_SOCKET="$socket" FLUX_TEST_SHOTS="$shots" \
  QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  dbus-run-session -- qs -p "$root/shell" > "$work/shell.log" 2>&1 &
echo "Started. Log: $work/shell.log. Stop: pkill -f \"qs -p $root/shell\""

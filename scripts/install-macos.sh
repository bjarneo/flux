#!/bin/sh
# Builds the macOS app in Release and installs it in /Applications.
# It quits a running Flux first and opens the new one at the end.
# Needs Xcode and XcodeGen (brew install xcodegen).
#
#   scripts/install-macos.sh            build, install, and open
#   scripts/install-macos.sh --no-open  build and install only
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
app=/Applications/Flux.app
bundle_id=org.omarchy.flux.mac
open_after=1
[ "${1:-}" = "--no-open" ] && open_after=0

cd "$root/macos"
xcodegen generate --quiet
xcodebuild -project Flux.xcodeproj -scheme Flux -configuration Release \
	-derivedDataPath build -destination "platform=macOS,arch=$(uname -m)" -quiet build

if pgrep -xq Flux; then
	osascript -e "quit app id \"$bundle_id\"" >/dev/null 2>&1 || true
	i=0
	while pgrep -xq Flux && [ $i -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	pgrep -xq Flux && pkill -x Flux || true
fi

rm -rf "$app"
ditto build/Build/Products/Release/Flux.app "$app"
codesign --verify --deep --strict "$app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed $app $(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)"

[ $open_after -eq 1 ] && open "$app"
exit 0

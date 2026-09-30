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

# f.lux also installs as /Applications/Flux.app. The script replaces only
# an app with the bundle ID of Omarchy Flux.
if [ -e "$app" ]; then
	id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
	if [ "$id" != "$bundle_id" ]; then
		echo "$app has the bundle ID ${id:-unknown}, not $bundle_id. It can be f.lux." >&2
		echo "The script does not replace another app. Move or rename $app, then run the script again." >&2
		exit 1
	fi
fi

# The app version is the last release tag without v. fluxd shows it.
version=$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')

# The copy of Package.resolved and -onlyUsePackageVersionsFromResolvedFile
# give the app the package versions that swift test tests.
cd "$root/macos"
xcodegen generate --quiet
mkdir -p Flux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Flux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
xcodebuild -project Flux.xcodeproj -scheme Flux -configuration Release \
	-derivedDataPath build -destination "platform=macOS,arch=$(uname -m)" -quiet \
	-onlyUsePackageVersionsFromResolvedFile \
	MARKETING_VERSION="${version:-0.1.0}" build

# Stop only the installed Omarchy Flux: by bundle ID, then by the path of
# its executable. Another process with the name Flux keeps running.
exe="^$app/Contents/MacOS/Flux( |\$)"
if pgrep -qf "$exe"; then
	osascript -e "quit app id \"$bundle_id\"" >/dev/null 2>&1 || true
	i=0
	while pgrep -qf "$exe" && [ $i -lt 50 ]; do
		sleep 0.1
		i=$((i + 1))
	done
	pgrep -qf "$exe" && pkill -f "$exe" || true
fi

rm -rf "$app"
ditto build/Build/Products/Release/Flux.app "$app"
codesign --verify --deep --strict "$app"
# The hardened runtime keeps injected libraries out of the app.
if ! codesign -dv "$app" 2>&1 | grep 'flags=.*runtime' >/dev/null; then
	echo "$app has no hardened runtime" >&2
	exit 1
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed $app $(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)"

[ $open_after -eq 1 ] && open "$app"
exit 0

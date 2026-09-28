#!/bin/sh
# Prints the id of an iPhone simulator for xcodebuild: the booted iPhone,
# else the first available one. Set IOS_SIMULATOR to choose another.
set -eu
if [ -n "${IOS_SIMULATOR:-}" ]; then
	echo "$IOS_SIMULATOR"
	exit 0
fi
list=$(xcrun simctl list devices available)
id=$(printf '%s\n' "$list" | grep -E '^ +iPhone .*\(Booted\)' | head -n 1 | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' || true)
if [ -z "$id" ]; then
	id=$(printf '%s\n' "$list" | grep -E '^ +iPhone ' | head -n 1 | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' || true)
fi
if [ -z "$id" ]; then
	echo "No iPhone simulator found. Add one in Xcode > Window > Devices and Simulators." >&2
	exit 1
fi
echo "$id"

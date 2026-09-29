#!/bin/sh
# Prints the id of an iPhone simulator for xcodebuild, on iOS 17 or later,
# the deployment target: the booted iPhone, else the first iPhone of the
# newest iOS runtime. Set IOS_SIMULATOR to choose another.
set -eu
if [ -n "${IOS_SIMULATOR:-}" ]; then
	echo "$IOS_SIMULATOR"
	exit 0
fi
xcrun simctl list devices available -j | python3 -c '
import json, re, sys

def version(runtime):
    m = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    return tuple(int(p or 0) for p in m.groups()) if m else None

phones = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    v = version(runtime)
    if v is None or v < (17,):
        continue
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            phones.append((d["state"] == "Booted", v, d["udid"]))
if not phones:
    sys.exit("No iPhone simulator with iOS 17 or later found. Add one in Xcode > Window > Devices and Simulators.")
# Booted first, then the newest runtime, in the order of the list.
phones.sort(key=lambda p: (not p[0], tuple(-n for n in p[1])))
print(phones[0][2])
'

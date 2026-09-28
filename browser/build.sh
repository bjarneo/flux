#!/bin/sh
# Build the Flux browser extension as 2 zip files: one for the Chromium
# browsers, and one for Firefox and Zen, which need another background and
# an add-on ID. The Flux version goes into the manifest, because a browser
# shows the version of the extension in its own list.
#
# The Arch package does not use this. It installs the extension unpacked,
# which a browser can load without a signature.
set -eu

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
src=$root/browser/extension
out=$root/browser/dist

version=${VERSION:-$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)}
# A browser wants 1 to 4 numbers, so v0.3.0-59-gabc123 becomes 0.3.0.
version=$(printf '%s' "$version" | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/; t; s/.*/0.0.0/')

rm -rf "$out"
mkdir -p "$out/chromium" "$out/firefox"

# The files that both builds share. The icons stay binary, so they are
# copied and not rewritten.
cd "$src"
find . -type f ! -name 'manifest*.json' -exec install -Dm644 {} "$out/chromium/{}" \;
find . -type f ! -name 'manifest*.json' -exec install -Dm644 {} "$out/firefox/{}" \;

stamp() {
	sed "s/\"version\": *\"[^\"]*\"/\"version\": \"$version\"/" "$1" >"$2"
}

stamp manifest.json "$out/chromium/manifest.json"
stamp manifest.firefox.json "$out/firefox/manifest.json"

# A browser reads manifest.json, so the Firefox build carries its manifest
# under that name and leaves the Chromium one out.
rm -f "$out/firefox/manifest.firefox.json"

for flavor in chromium firefox; do
	(cd "$out/$flavor" && zip -q -r -X "../flux-$flavor.zip" .)
	echo "$out/flux-$flavor.zip ($version)"
done

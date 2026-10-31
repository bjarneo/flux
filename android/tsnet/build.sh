#!/bin/sh
# Builds the userspace tailnet node for Android. Usage: build.sh OUT_DIR [ABI...]
set -eu

out=$1
shift
[ -n "$out" ] || { echo "usage: $0 OUT_DIR [ABI...]" >&2; exit 2; }
[ $# -gt 0 ] || set -- arm64-v8a

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$out"

for abi in "$@"; do
	case $abi in
	arm64-v8a) goarch=arm64 ;;
	armeabi-v7a) goarch=arm ;;
	x86_64) goarch=amd64 ;;
	x86) goarch=386 ;;
	*) echo "unsupported ABI: $abi" >&2; exit 2 ;;
	esac
	dir="$out/$abi"
	mkdir -p "$dir"
	echo "building libflux_tsnet.so for $abi ($goarch)" >&2
	(cd "$here" && CGO_ENABLED=0 GOOS=android GOARCH=$goarch \
		go build -trimpath -ldflags='-s -w' -o "$dir/libflux_tsnet.so" .)
done

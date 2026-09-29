package main

import (
	"testing"

	"flux/internal/release"
)

func TestPackageAsset(t *testing.T) {
	r := release.Release{Tag: "v0.7.0", Assets: []release.Asset{
		{Name: "omarchy-flux-debug-0.7.0-1-x86_64.pkg.tar.zst", URL: "debug"},
		{Name: "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst", URL: "pkg"},
		{Name: "omarchy-flux-0.7.0-aur.tar.gz", URL: "aur"},
		{Name: "flux-android-0.7.0.apk", URL: "apk"},
	}}
	if a, ok := packageAsset(r, "omarchy-flux", "x86_64"); !ok || a.URL != "pkg" {
		t.Errorf("x86_64: %+v, %v", a, ok)
	}
	if a, ok := packageAsset(r, "omarchy-flux", "aarch64"); ok {
		t.Errorf("aarch64: %+v", a)
	}
}

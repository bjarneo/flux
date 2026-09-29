package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
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

func TestVerify(t *testing.T) {
	dir := t.TempDir()
	pkg := filepath.Join(dir, "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst")
	if err := os.WriteFile(pkg, []byte("package"), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("package"))
	sums := filepath.Join(dir, "SHA256SUMS")
	write := func(text string) {
		if err := os.WriteFile(sums, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	write(hex.EncodeToString(sum[:]) + "  omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst\nabc  flux-android-0.7.0.apk\n")
	if err := verify(pkg, sums); err != nil {
		t.Errorf("a matching checksum: %v", err)
	}
	write("0000  omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst\n")
	if err := verify(pkg, sums); err == nil {
		t.Error("no error for a wrong checksum")
	}
	write("abc  flux-android-0.7.0.apk\n")
	if err := verify(pkg, sums); err == nil {
		t.Error("no error for a missing line")
	}
}

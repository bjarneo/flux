package main

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

// TestRootInstall runs the root part of the package install as the user,
// with a fake pacman. pacman gets a private copy with the checked content
// in a new folder. A file that changed after the check does not reach
// pacman.
func TestRootInstall(t *testing.T) {
	bin := t.TempDir()
	log := filepath.Join(t.TempDir(), "pacman.log")
	fake := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + log + "\nstat -c %a \"$2\" >> " + log + "\ncat \"$2\" >> " + log + "\n"
	if err := os.WriteFile(filepath.Join(bin, "pacman"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	// The script sets its own PATH. The test puts the fake pacman first.
	const path = "PATH=/usr/bin:/bin\n"
	if !strings.Contains(rootInstall, path) {
		t.Fatalf("the script does not set %q", path)
	}
	script := strings.Replace(rootInstall, path, "PATH="+bin+":/usr/bin:/bin\n", 1)
	name := "omarchy-flux-0.7.0-1-x86_64.pkg.tar.zst"
	pkg := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(pkg, []byte("package"), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte("package"))
	install := func() error {
		out, err := exec.Command("/bin/sh", "-c", script, "flux-update", pkg, hex.EncodeToString(sum[:]), name).CombinedOutput()
		if err != nil {
			t.Logf("output: %s", out)
		}
		return err
	}

	if err := install(); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(got)), "\n")
	if len(lines) != 4 || lines[0] != "-U" || lines[2] != "600" || lines[3] != "package" {
		t.Fatalf("pacman got %q", lines)
	}
	if dst := lines[1]; !strings.HasPrefix(dst, "/tmp/flux-update.") || filepath.Base(dst) != name {
		t.Errorf("pacman read %s, want a copy in a new folder", dst)
	} else if _, err := os.Stat(filepath.Dir(dst)); !os.IsNotExist(err) {
		t.Errorf("the folder of the copy stays: %v", err)
	}

	os.Remove(log)
	if err := os.WriteFile(pkg, []byte("changed"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := install(); err == nil {
		t.Error("no error for a file that changed after the check")
	}
	if _, err := os.Stat(log); !os.IsNotExist(err) {
		t.Errorf("pacman ran for a changed file: %v", err)
	}
}

// TestInstallPackageNoAUR checks that a release that flux-cli cannot check
// does not switch to an AUR build. A fake yay records each run.
func TestInstallPackageNoAUR(t *testing.T) {
	bin := t.TempDir()
	mark := filepath.Join(t.TempDir(), "yay.ran")
	fake := "#!/bin/sh\n: > '" + mark + "'\n"
	if err := os.WriteFile(filepath.Join(bin, "yay"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	const dir = "https://github.com/bjarneo/flux/releases/download/v0.7.0/"
	name := "omarchy-flux-0.7.0-1-" + packageArch() + ".pkg.tar.zst"
	sums := release.Asset{Name: "SHA256SUMS", URL: dir + "SHA256SUMS", Size: 100}
	cases := []struct {
		what string
		r    release.Release
	}{
		{"the package without SHA256SUMS", release.Release{Tag: "v0.7.0", Assets: []release.Asset{{Name: name, URL: dir + name, Size: 7}}}},
		{"a package that Latest removed", release.Release{Tag: "v0.7.0", Assets: []release.Asset{sums}, Dropped: []string{name}}},
	}
	for _, c := range cases {
		if err := installPackage(c.r, "omarchy-flux"); err == nil {
			t.Errorf("%s: no error", c.what)
		}
		if _, err := os.Stat(mark); !os.IsNotExist(err) {
			t.Fatalf("%s: yay ran", c.what)
		}
	}

	// A complete release without a package for this architecture gets an
	// AUR build. This case shows that the fake yay works.
	if err := installPackage(release.Release{Tag: "v0.7.0", Assets: []release.Asset{sums}}, "omarchy-flux"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(mark); err != nil {
		t.Errorf("yay did not run for a release without the package: %v", err)
	}
}

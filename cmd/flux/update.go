package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"flux/internal/config"
	"flux/internal/release"
)

// update asks GitHub for the latest release and installs it. A pacman
// package gets the release package after a SHA-256 check. A source
// install gets the commands for its checkout.
func update(args []string) error {
	checkOnly := false
	for _, a := range args {
		switch a {
		case "--check", "-n":
			checkOnly = true
		default:
			return fmt.Errorf("unknown option %q. Use --check", a)
		}
	}
	r, err := release.Latest(context.Background(), release.URL(), version)
	if err != nil {
		return fmt.Errorf("cannot reach GitHub: %v\nFlux works without the internet. To update, connect to a network and run flux-cli update again", err)
	}
	latest, current := r.Version(), strings.TrimPrefix(version, "v")
	switch {
	case !release.Valid(version):
		fmt.Printf("flux-cli %s is a development build. The latest release is %s: %s\n", current, latest, r.Page)
		if checkOnly {
			return nil
		}
		return sourceUpdate()
	case !release.Newer(latest, version):
		fmt.Printf("Flux %s is the latest release, and this computer has %s\n", latest, current)
		return nil
	}
	fmt.Printf("Flux %s is available. This computer has %s\n%s\n", latest, current, r.Page)
	if checkOnly {
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	pkg := pacmanOwner(exe)
	if pkg == "" {
		return sourceUpdate()
	}
	if err := installPackage(r, pkg); err != nil {
		return err
	}
	waitForDaemon(latest)
	return nil
}

// pacmanOwner returns the package that owns path, or "".
func pacmanOwner(path string) string {
	out, err := exec.Command("pacman", "-Qqo", path).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// packageArch returns the pacman name of this architecture.
func packageArch() string {
	if runtime.GOARCH == "arm64" {
		return "aarch64"
	}
	return "x86_64"
}

// installPackage installs the release package with pacman. Without a
// package for this architecture, an AUR helper builds it.
func installPackage(r release.Release, pkg string) error {
	asset, ok := packageAsset(r, pkg, packageArch())
	sums, okSums := r.Find(func(n string) bool { return n == "SHA256SUMS" })
	if !ok || !okSums {
		for _, helper := range []string{"yay", "paru"} {
			if _, err := exec.LookPath(helper); err == nil {
				fmt.Printf("The release has no %s package. %s builds it from AUR\n", packageArch(), helper)
				return run(helper, "-S", pkg)
			}
		}
		return fmt.Errorf("the release has no %s package. To build it, run: yay -S %s", packageArch(), pkg)
	}

	dir := filepath.Join(config.CacheDir(), "update")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	path := filepath.Join(dir, asset.Name)
	fmt.Printf("Downloading %s (%.1f MB)\n", asset.Name, float64(asset.Size)/1e6)
	if err := download(asset.URL, path); err != nil {
		return err
	}
	sumsPath := filepath.Join(dir, "SHA256SUMS")
	if err := download(sums.URL, sumsPath); err != nil {
		return err
	}
	if err := verify(path, sumsPath); err != nil {
		os.Remove(path)
		return err
	}
	fmt.Println("✓ The SHA-256 checksum matches SHA256SUMS")
	if err := run("sudo", "pacman", "-U", path); err != nil {
		return fmt.Errorf("pacman did not install %s: %w", asset.Name, err)
	}
	os.Remove(path)
	os.Remove(sumsPath)
	return nil
}

// packageAsset returns the package of pkg for arch in the release. The
// debug package has another name, so it does not match.
func packageAsset(r release.Release, pkg, arch string) (release.Asset, bool) {
	return r.Find(func(n string) bool {
		return strings.HasPrefix(n, pkg+"-"+r.Version()+"-") && strings.HasSuffix(n, "-"+arch+".pkg.tar.zst")
	})
}

func download(url, path string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "flux/"+version)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("download %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: %s", url, resp.Status)
	}
	f, err := os.Create(path + ".part")
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(path + ".part")
		return fmt.Errorf("download %s: %w", url, err)
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(path+".part", path)
}

// verify compares the SHA-256 checksum of path with its line in sums.
func verify(path, sums string) error {
	f, err := os.Open(sums)
	if err != nil {
		return err
	}
	defer f.Close()
	name := filepath.Base(path)
	want := ""
	s := bufio.NewScanner(f)
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == name {
			want = fields[0]
		}
	}
	if want == "" {
		return fmt.Errorf("SHA256SUMS has no line for %s", name)
	}
	in, err := os.Open(path)
	if err != nil {
		return err
	}
	defer in.Close()
	h := sha256.New()
	if _, err := io.Copy(h, in); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		return fmt.Errorf("the SHA-256 checksum of %s is %s, and SHA256SUMS gives %s. flux-cli removed the file", name, got, want)
	}
	return nil
}

// sourceUpdate prints the commands for a source install.
func sourceUpdate() error {
	install := "sudo make install"
	if exe, err := os.Executable(); err == nil {
		if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(exe, filepath.Join(home, ".local")+"/") {
			install = "make install-user"
		}
	}
	return errors.New("this Flux is a source install, so update it from the checkout:\n  git pull --ff-only && make build && " + install)
}

// waitForDaemon waits until fluxd runs the new version.
func waitForDaemon(want string) {
	if _, err := dial(); err != nil {
		return
	}
	fmt.Println("fluxd restarts into the new version when no transfer or stream runs")
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		var s State
		if callInto("state", nil, &s) == nil && sameVersion(s.Self.Version, want) {
			fmt.Println("✓ fluxd", s.Self.Version, "runs")
			return
		}
		time.Sleep(time.Second)
	}
	fmt.Println("fluxd still runs the earlier version. To see why, run: flux-cli version")
}

func run(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

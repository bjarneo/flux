package main

import (
	"context"
	"errors"
	"fmt"
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
// package gets the release package after a check against SHA256SUMS and
// its signature. A source install gets the commands for its checkout.
func update(args []string, device string) error {
	checkOnly := false
	for _, a := range args {
		switch a {
		case "--check", "-n":
			checkOnly = true
		case "--phone":
			return updatePhone(device)
		default:
			return fmt.Errorf("unknown option %q. Use --check or --phone", a)
		}
	}
	r, err := release.Latest(context.Background(), release.URL(), version)
	if err != nil {
		return fmt.Errorf("cannot reach GitHub: %v\nFlux works without the internet. To update, connect to a network and run flux-cli update again", err)
	}
	latest, current := r.Version(), strings.TrimPrefix(version, "v")
	// The tag and the page come from GitHub, so safe cleans them for the
	// terminal.
	shown, page := safe(latest), safe(r.Page)
	switch {
	case !release.Valid(version):
		fmt.Printf("flux-cli %s is a development build. The latest release is %s: %s\n", current, shown, page)
		if checkOnly {
			return nil
		}
		return sourceUpdate()
	case !release.Newer(latest, version):
		fmt.Printf("Flux %s is the latest release, and this computer has %s\n", shown, current)
		return nil
	}
	fmt.Printf("Flux %s is available. This computer has %s\n%s\n", shown, current, page)
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

// updatePhone asks fluxd to send the Android app of the latest release to
// the phone. fluxd downloads it and checks it against SHA256SUMS and its
// signature first.
func updatePhone(device string) error {
	if err := call("update.sendApp", map[string]any{"device": device}); err != nil {
		return err
	}
	fmt.Println("fluxd downloads Flux for Android and sends it to the phone. To install it, open its notification on the phone")
	fmt.Println("To follow the transfer, run: flux-cli status --json")
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
// package for this architecture, an AUR helper builds it. A release with
// the package but without SHA256SUMS is an error, because the upload of the
// release can be incomplete. A release with files that Latest removed is
// also an error, because a removed file can be the package.
func installPackage(r release.Release, pkg string) error {
	asset, ok := packageAsset(r, pkg, packageArch())
	if !ok && len(r.Dropped) > 0 {
		return fmt.Errorf("GitHub gives %s of the release %s at an address outside the Flux repository, so flux-cli does not install this release. See %s", strings.Join(r.Dropped, ", "), r.Tag, r.Page)
	}
	if !ok {
		for _, helper := range []string{"yay", "paru"} {
			if _, err := exec.LookPath(helper); err == nil {
				fmt.Printf("The release has no %s package. %s builds it from AUR\n", packageArch(), helper)
				return run(helper, "-S", pkg)
			}
		}
		return fmt.Errorf("the release has no %s package. To build it, run: yay -S %s", packageArch(), pkg)
	}
	sums, ok := r.Find(func(n string) bool { return n == "SHA256SUMS" })
	if !ok {
		return fmt.Errorf("the release %s has %s but no SHA256SUMS, so flux-cli cannot check the package. The upload of the release can be incomplete. Try again later", r.Tag, asset.Name)
	}
	sig, _ := r.Find(func(n string) bool { return n == "SHA256SUMS.sig" })

	fmt.Printf("Downloading %s (%.1f MB)\n", safe(asset.Name), float64(asset.Size)/1e6)
	path, sum, err := release.Fetch(context.Background(), asset, sums.URL, sig.URL, filepath.Join(config.CacheDir(), "update"), version)
	if err != nil {
		return err
	}
	defer os.Remove(path)
	if release.Signed() {
		fmt.Println("✓ The release key signed SHA256SUMS, and the SHA-256 checksum of the package matches it")
	} else {
		fmt.Println("✓ The SHA-256 checksum matches SHA256SUMS. This flux-cli has no release key, so the check finds a damaged download but cannot show who made the release")
	}
	if err := run(sudoPath(), "/bin/sh", "-c", rootInstall, "flux-update", path, sum, asset.Name); err != nil {
		return fmt.Errorf("pacman did not install %s: %w", asset.Name, err)
	}
	return nil
}

// rootInstall runs as root with the arguments PATH SHA256 NAME. It copies
// the package into a new folder that only root can read, checks the copy
// against the checksum from SHA256SUMS, and gives the copy to pacman. So a
// change of the downloaded file after the check does not reach pacman.
// The script sets its own PATH, so the PATH of the user cannot give
// another pacman.
const rootInstall = `set -eu
PATH=/usr/bin:/bin
dir=$(mktemp -d /tmp/flux-update.XXXXXX)
trap 'rm -rf "$dir"' EXIT
pkg="$dir/$3"
install -m 0600 -- "$1" "$pkg"
if ! printf '%s  %s\n' "$2" "$pkg" | sha256sum --check --status -; then
	echo "$3 changed after the check, so pacman does not install it" >&2
	exit 1
fi
pacman -U "$pkg"
`

// sudoPath returns /usr/bin/sudo, or sudo from PATH when that file does
// not exist.
func sudoPath() string {
	if _, err := os.Stat("/usr/bin/sudo"); err == nil {
		return "/usr/bin/sudo"
	}
	return "sudo"
}

// packageAsset returns the package of pkg for arch in the release. The
// debug package has another name, so it does not match.
func packageAsset(r release.Release, pkg, arch string) (release.Asset, bool) {
	return r.Find(func(n string) bool {
		return strings.HasPrefix(n, pkg+"-"+r.Version()+"-") && strings.HasSuffix(n, "-"+arch+".pkg.tar.zst")
	})
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

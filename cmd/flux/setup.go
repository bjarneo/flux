package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"

	"flux/internal/config"
)

// setup does the per-user part of the install: the fluxd service and the
// omarchy-shell plugin. The system part (udev rules, kernel modules) is done
// by post-install.sh, which the package runs as root. setup reports any
// system part that is missing and prints the command that adds it.
func setup(args []string) error {
	dry, noPlugin := false, false
	for _, a := range args {
		switch a {
		case "--dry-run", "-n":
			dry = true
		case "--no-plugin":
			noPlugin = true
		default:
			return fmt.Errorf("unknown option %q. Use --dry-run or --no-plugin", a)
		}
	}
	run := func(what string, name string, args ...string) error {
		if dry {
			fmt.Printf("  would run: %s %s\n", name, strings.Join(args, " "))
			return nil
		}
		out, err := exec.Command(name, args...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s: %v: %s", what, err, strings.TrimSpace(string(out)))
		}
		return nil
	}

	fmt.Println("1. The fluxd service")
	if err := setupService(dry, run); err != nil {
		fmt.Println("  ✗", err)
	}

	fmt.Println("2. The omarchy-shell plugin")
	switch {
	case noPlugin:
		fmt.Println("  - skipped")
	default:
		if err := setupPlugin(dry, run); err != nil {
			fmt.Println("  ✗", err)
		}
	}

	fmt.Println("3. System parts")
	setupSystemReport()
	return nil
}

func setupService(dry bool, run func(string, string, ...string) error) error {
	unitDir := filepath.Join(config.ConfigDir(), "..", "systemd", "user")
	if _, err := os.Stat("/usr/lib/systemd/user/fluxd.service"); err != nil {
		// A checkout: write a user unit that runs the fluxd next to this flux.
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		fluxd := filepath.Join(filepath.Dir(exe), "fluxd")
		if _, err := os.Stat(fluxd); err != nil {
			return fmt.Errorf("fluxd is not installed and not next to flux (%s). Run make first", fluxd)
		}
		unit := "[Unit]\nDescription=Flux daemon that connects this computer to your phone\nPartOf=graphical-session.target\nAfter=graphical-session.target\n\n" +
			"[Service]\nExecStart=" + fluxd + "\nExecReload=/bin/kill -HUP $MAINPID\nRestart=on-failure\nRestartSec=2\n\n" +
			"[Install]\nWantedBy=graphical-session.target\n"
		path := filepath.Join(unitDir, "fluxd.service")
		if dry {
			fmt.Println("  would write:", path, "for", fluxd)
		} else {
			if err := os.MkdirAll(unitDir, 0o755); err != nil {
				return err
			}
			if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
				return err
			}
			fmt.Println("  ✓ wrote", path)
		}
	}
	if err := run("reload systemd", "systemctl", "--user", "daemon-reload"); err != nil {
		return err
	}
	// A fluxd that runs outside systemd holds the socket, and the service
	// would fail. Enable the service, and start it only when no fluxd runs.
	if err := run("enable fluxd", "systemctl", "--user", "enable", "fluxd.service"); err != nil {
		return err
	}
	if dry {
		fmt.Println("  would start fluxd.service when no other fluxd runs")
		return nil
	}
	if exec.Command("systemctl", "--user", "is-active", "--quiet", "fluxd.service").Run() == nil {
		fmt.Println("  ✓ fluxd.service is enabled and runs")
		return nil
	}
	if c, err := dial(); err == nil {
		c.Close()
		fmt.Println("  ✓ fluxd.service is enabled. A fluxd outside systemd runs now, so the service starts at the next login.")
		fmt.Println("    To switch now: pkill -x fluxd && systemctl --user start fluxd")
		return nil
	}
	if err := run("start fluxd", "systemctl", "--user", "start", "fluxd.service"); err != nil {
		return err
	}
	if !dry {
		fmt.Println("  ✓ fluxd.service is enabled and started")
	}
	return nil
}

// pluginSource returns the files of the plugin: the installed copy, or the
// checkout next to this flux.
func pluginSource() (plugin, views string, err error) {
	if _, err := os.Stat("/usr/share/flux/omarchy-plugin/manifest.json"); err == nil {
		return "/usr/share/flux/omarchy-plugin", "", nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", "", err
	}
	root := filepath.Join(filepath.Dir(exe), "..")
	if _, err := os.Stat(filepath.Join(root, "gui", "omarchy", "manifest.json")); err != nil {
		return "", "", errors.New("the plugin files are missing. Install Flux, or run flux from its checkout")
	}
	return filepath.Join(root, "gui", "omarchy"), filepath.Join(root, "gui", "qml"), nil
}

func setupPlugin(dry bool, run func(string, string, ...string) error) error {
	if _, err := exec.LookPath("omarchy-shell"); err != nil {
		fmt.Println("  - omarchy-shell is not installed, so flux open uses flux-gui")
		return nil
	}
	src, views, err := pluginSource()
	if err != nil {
		return err
	}
	dest := filepath.Join(config.ConfigDir(), "..", "omarchy", "plugins", "flux")
	if dry {
		fmt.Println("  would copy:", src, "to", dest)
	} else {
		if err := os.RemoveAll(dest); err != nil {
			return err
		}
		if err := copyPlugin(src, views, dest); err != nil {
			return err
		}
		fmt.Println("  ✓ copied the plugin to", dest)
	}
	if err := run("rescan plugins", "omarchy-shell", "shell", "rescanPlugins"); err != nil {
		return err
	}
	if err := run("enable the plugin", "omarchy", "plugin", "enable", "flux", "--section", "right"); err != nil {
		return err
	}
	if !dry {
		fmt.Println("  ✓ the plugin is enabled, with the bar item on the right")
	}
	return nil
}

// copyPlugin copies the plugin as `omarchy plugin validate` wants it: real
// files, no symlinks, and no tools folder. From a checkout, the shared
// views go into Flux/.
func copyPlugin(src, views, dest string) error {
	skip := func(rel string) bool {
		return rel == "tools" || strings.HasPrefix(rel, "tools/") || rel == "Flux"
	}
	if err := copyTree(src, dest, skip); err != nil {
		return err
	}
	if views == "" {
		return nil
	}
	return copyTree(views, filepath.Join(dest, "Flux"), func(rel string) bool {
		return rel == "tools" || strings.HasPrefix(rel, "tools/") || strings.HasSuffix(rel, ".md") || strings.HasPrefix(filepath.Base(rel), ".")
	})
}

func copyTree(src, dest string, skip func(rel string) bool) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, path)
		if rel == "." {
			return os.MkdirAll(dest, 0o755)
		}
		if skip(rel) {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		target := filepath.Join(dest, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		in, err := os.Open(path)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, in); err != nil {
			out.Close()
			return err
		}
		return out.Close()
	})
}

// setupSystemReport checks the parts that need root and prints the command
// that adds them.
func setupSystemReport() {
	script := "/usr/share/flux/post-install.sh"
	if _, err := os.Stat(script); err != nil {
		script = "dist/post-install.sh (from the checkout, after sudo make install)"
	}
	missing := false
	if unix.Access("/dev/uinput", unix.W_OK) != nil {
		missing = true
		fmt.Println("  ✗ The phone touchpad has no access to /dev/uinput")
	} else {
		fmt.Println("  ✓ The phone touchpad can use /dev/uinput")
	}
	switch {
	case unix.Access("/dev/v4l2loopback", unix.W_OK) == nil:
		fmt.Println("  ✓ The phone can be a webcam")
	case unix.Access("/dev/v4l2loopback", unix.F_OK) == nil:
		missing = true
		fmt.Println("  ✗ The phone as webcam has no access to /dev/v4l2loopback")
	default:
		fmt.Println("  - The phone as webcam is off. To add it: sudo pacman -S ffmpeg v4l2loopback-dkms")
	}
	if missing {
		fmt.Println("  To fix the parts above, run: sudo sh", script)
	}
}

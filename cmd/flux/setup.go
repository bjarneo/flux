package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"

	"flux/internal/config"
	"flux/internal/plugin"
)

// setup does the per-user part of the install: the fluxd service and the
// omarchy-shell plugin. The system part (the udev rule and the kernel
// module for the webcam) is done by post-install.sh, which the package runs as root. setup reports any
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
			"[Service]\nExecStart=" + fluxd + "\nExecReload=/bin/kill -HUP $MAINPID\nRestart=on-failure\nRestartSec=2\n" +
			"# fluxd exits with 75 after an update replaced its binary.\nSuccessExitStatus=75\nRestartForceExitStatus=75\n\n" +
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

func setupPlugin(dry bool, run func(string, string, ...string) error) error {
	if _, err := exec.LookPath("omarchy-shell"); err != nil {
		fmt.Println("  - omarchy-shell is not installed, so flux-cli open uses flux-gui")
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	src, views, err := plugin.Source(exe)
	if err != nil {
		return err
	}
	dest := plugin.UserDir()
	if dry {
		fmt.Println("  would copy:", src, "to", dest)
	} else {
		// A symlink to a checkout is a development plugin. Replace it
		// with real files, as `omarchy plugin validate` wants them.
		if fi, err := os.Lstat(dest); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			if err := os.Remove(dest); err != nil {
				return err
			}
		}
		files, err := plugin.Files(src, views)
		if err != nil {
			return err
		}
		changed, err := plugin.Sync(files, dest)
		if err != nil {
			return err
		}
		if changed {
			fmt.Println("  ✓ copied the plugin to", dest)
		} else {
			fmt.Println("  ✓ the plugin in", dest, "is up to date")
		}
	}
	if err := run("rescan plugins", "omarchy-shell", "shell", "rescanPlugins"); err != nil {
		return err
	}

	// omarchy-shell shell rescanPlugins runs asynchronously and flux may
	// not be listed immediately, so retry enabling the plugin on a delay a
	// limited number of times.
	for i := 0; i < 50; i++ {
		if i > 0 {
			time.Sleep(100 * time.Millisecond)
		}
		if err = run("enable the plugin", "omarchy", "plugin", "enable", "flux", "--section", "right"); err == nil {
			break
		}
	}
	if err != nil {
		return err
	}
	if !dry {
		fmt.Println("  ✓ the plugin is enabled, with the bar item on the right")
	}
	return nil
}

// setupSystemReport checks the parts that need root and prints the command
// that adds them.
func setupSystemReport() {
	script := "/usr/share/flux/post-install.sh"
	if _, err := os.Stat(script); err != nil {
		script = "dist/post-install.sh (from the checkout, after sudo make install)"
	}
	switch {
	case unix.Access("/dev/v4l2loopback", unix.W_OK) == nil:
		fmt.Println("  ✓ The phone can be a webcam")
	case unix.Access("/dev/v4l2loopback", unix.F_OK) == nil:
		fmt.Println("  ✗ The phone as webcam has no access to /dev/v4l2loopback")
		fmt.Println("  To fix it, run: sudo sh", script)
	default:
		fmt.Println("  - The phone as webcam is off. To add it: sudo pacman -S ffmpeg v4l2loopback-dkms")
	}
}

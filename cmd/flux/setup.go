package main

import (
	"errors"
	"fmt"
	"io/fs"
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
// system part that is missing and prints the command that adds it. It
// returns an error when a step fails, so that the exit code is 1.
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

	failed := 0
	fmt.Println("1. The fluxd service")
	if err := setupService(dry, run); err != nil {
		fmt.Println("  ✗", err)
		failed++
	}

	fmt.Println("2. The omarchy-shell plugin")
	switch {
	case noPlugin:
		fmt.Println("  - skipped")
	default:
		if err := setupPlugin(dry, run); err != nil {
			fmt.Println("  ✗", err)
			failed++
		}
	}

	fmt.Println("3. System parts")
	setupSystemReport()
	switch failed {
	case 0:
		return nil
	case 1:
		return errors.New("1 step failed")
	default:
		return fmt.Errorf("%d steps failed", failed)
	}
}

// systemUnit is the fluxd unit of the package and of `sudo make install`.
var systemUnit = "/usr/lib/systemd/user/fluxd.service"

// unitDescription is the description of the fluxd unit. setup finds its own
// user unit by it.
const unitDescription = "Flux daemon that connects this computer to your phone"

// userUnit returns the path of the fluxd unit of the user. systemd uses it
// before the unit of the package.
func userUnit() string {
	return filepath.Join(config.ConfigDir(), "..", "systemd", "user", "fluxd.service")
}

// serviceUnit returns the user unit that runs fluxd. systemd splits
// ExecStart at spaces and replaces % specifiers, so the path is in quotes,
// with each % doubled. systemd does not replace $ in the path of the
// program. It refuses a path with a quote, a backslash, or a control
// character, so serviceUnit refuses it too.
func serviceUnit(fluxd string) (string, error) {
	for _, r := range fluxd {
		switch {
		case r < 0x20 || r == 0x7f:
			return "", fmt.Errorf("the path %q has a control character, so systemd cannot run it", fluxd)
		case r == '"' || r == '\'' || r == '\\':
			return "", fmt.Errorf("the path %q has a quote or a backslash, so systemd cannot run it. Move fluxd to a path without these characters", fluxd)
		}
	}
	quoted := strings.ReplaceAll(fluxd, "%", "%%")
	return "[Unit]\nDescription=" + unitDescription + "\nPartOf=graphical-session.target\nAfter=graphical-session.target\n\n" +
		"[Service]\nType=exec\nExecStart=\"" + quoted + "\"\nExecReload=/bin/kill -HUP $MAINPID\nRestart=on-failure\nRestartSec=2\n" +
		"# fluxd exits with 75 after an update replaced its binary.\nSuccessExitStatus=75\nRestartForceExitStatus=75\n\n" +
		"[Install]\nWantedBy=graphical-session.target\n", nil
}

// oldUnits are the units that earlier versions of setup wrote. @FLUXD@ is
// the path of fluxd, without quotes.
var oldUnits = []string{
	"[Unit]\nDescription=" + unitDescription + "\nPartOf=graphical-session.target\nAfter=graphical-session.target\n\n" +
		"[Service]\nExecStart=@FLUXD@\nExecReload=/bin/kill -HUP $MAINPID\nRestart=on-failure\nRestartSec=2\n" +
		"# fluxd exits with 75 after an update replaced its binary.\nSuccessExitStatus=75\nRestartForceExitStatus=75\n\n" +
		"[Install]\nWantedBy=graphical-session.target\n",
	"[Unit]\nDescription=" + unitDescription + "\nPartOf=graphical-session.target\nAfter=graphical-session.target\n\n" +
		"[Service]\nExecStart=@FLUXD@\nExecReload=/bin/kill -HUP $MAINPID\nRestart=on-failure\nRestartSec=2\n\n" +
		"[Install]\nWantedBy=graphical-session.target\n",
}

// setupWrote reports whether unit is a unit that this or an earlier setup
// wrote, with no change. A unit that the user changed is not one.
func setupWrote(unit string) bool {
	exe := ""
	for _, line := range strings.Split(unit, "\n") {
		if v, ok := strings.CutPrefix(line, "ExecStart="); ok {
			exe = v
			break
		}
	}
	if exe == "" {
		return false
	}
	if inner, ok := strings.CutPrefix(exe, `"`); ok {
		path := strings.ReplaceAll(strings.TrimSuffix(inner, `"`), "%%", "%")
		want, err := serviceUnit(path)
		return err == nil && want == unit
	}
	for _, old := range oldUnits {
		if strings.Replace(old, "@FLUXD@", exe, 1) == unit {
			return true
		}
	}
	return false
}

// removeUserUnit removes a user unit that an earlier `flux-cli setup` of a
// checkout or of `make install-user` wrote. That unit hides the unit of
// the package, so the service would run the earlier fluxd. setup does not
// remove a unit that the user wrote, and it prints the fix instead. It
// reports whether it removed the unit.
func removeUserUnit(path string, dry bool, run func(string, string, ...string) error) (bool, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !setupWrote(string(b)) {
		fmt.Printf("  - %s hides %s. To use the unit of the package, remove it. To change the service, use: systemctl --user edit fluxd\n", path, systemUnit)
		return false, nil
	}
	if dry {
		fmt.Println("  would remove:", path, "which hides", systemUnit)
		return false, nil
	}
	// disable removes the links to the old unit, while the unit exists.
	if err := run("disable the old user unit", "systemctl", "--user", "disable", "fluxd.service"); err != nil {
		return false, err
	}
	if err := os.Remove(path); err != nil {
		return false, err
	}
	fmt.Println("  ✓ removed", path, "which hid", systemUnit)
	return true, nil
}

func setupService(dry bool, run func(string, string, ...string) error) error {
	path := userUnit()
	restart := false
	if _, err := os.Stat(systemUnit); err == nil {
		removed, err := removeUserUnit(path, dry, run)
		if err != nil {
			return err
		}
		restart = removed
	} else {
		// A checkout: write a user unit that runs the fluxd next to this flux.
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		fluxd := filepath.Join(filepath.Dir(exe), "fluxd")
		if _, err := os.Stat(fluxd); err != nil {
			return fmt.Errorf("fluxd is not installed and not next to flux (%s). Run make first", fluxd)
		}
		unit, err := serviceUnit(fluxd)
		if err != nil {
			return err
		}
		old, _ := os.ReadFile(path)
		switch {
		case string(old) == unit:
		case dry:
			fmt.Println("  would write:", path, "for", fluxd)
		default:
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return err
			}
			if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
				return err
			}
			fmt.Println("  ✓ wrote", path)
			restart = old != nil
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
	if config.IsOff() {
		fmt.Println("  - fluxd.service is enabled, but fluxd is off. To turn it on, run: flux-cli on")
		return nil
	}
	active := exec.Command("systemctl", "--user", "is-active", "--quiet", "fluxd.service").Run() == nil
	switch {
	case active && !restart:
		fmt.Println("  ✓ fluxd.service is enabled and runs")
		return nil
	case active:
		// The service still runs the fluxd of the old unit.
		if err := run("restart fluxd", "systemctl", "--user", "restart", "fluxd.service"); err != nil {
			return err
		}
	default:
		if c, err := dial(); err == nil {
			c.Close()
			fmt.Println("  ✓ fluxd.service is enabled. A fluxd outside systemd runs now, so the service starts at the next login.")
			fmt.Println("    To switch now: pkill -x fluxd && systemctl --user start fluxd")
			return nil
		}
		if err := run("start fluxd", "systemctl", "--user", "start", "fluxd.service"); err != nil {
			return err
		}
	}
	if err := waitForFluxd(10 * time.Second); err != nil {
		return err
	}
	fmt.Println("  ✓ fluxd.service is enabled and started")
	return nil
}

// waitForFluxd waits until fluxd answers a request on its socket.
// systemctl start returns before fluxd reads config.toml, so a fluxd that
// stops at once looks like a success to it. fluxd makes the socket before
// it starts the network, and it answers only after the network runs. So a
// connection alone does not show that the start worked, but an answer does.
func waitForFluxd(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		if c, err := dial(); err == nil {
			answer := make(chan error, 1)
			go func() { answer <- c.Call("state", nil, nil) }()
			select {
			case err = <-answer:
			case <-time.After(time.Until(deadline)):
				err = errors.New("fluxd did not answer")
			}
			c.Close()
			if err == nil {
				return nil
			}
		}
		if !time.Now().Before(deadline) || exec.Command("systemctl", "--user", "is-failed", "--quiet", "fluxd.service").Run() == nil {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	msg := "fluxd.service did not start"
	if err := config.Check(); err != nil {
		msg += ": " + err.Error()
	}
	return errors.New(msg + ". To see why, run: journalctl --user -u fluxd -e")
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
		if errors.Is(err, plugin.ErrLinked) {
			return fmt.Errorf("%w. For the installed plugin, remove the symlink, then run: flux-cli setup", err)
		}
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

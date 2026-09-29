package main

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"

	"flux/internal/config"
	"flux/internal/core"
	"flux/internal/plugin"
	"flux/internal/upgrade"
)

// exitUpgrade is the exit code after a new binary replaced this fluxd.
// fluxd.service starts fluxd again on this code.
const exitUpgrade = 75

// underSystemd reports whether this process is the main process of a
// systemd service. A child of another service also inherits INVOCATION_ID,
// but its SYSTEMD_EXEC_PID names another process.
func underSystemd() bool {
	if os.Getenv("INVOCATION_ID") == "" {
		return false
	}
	pid := os.Getenv("SYSTEMD_EXEC_PID")
	return pid == "" || pid == strconv.Itoa(os.Getpid())
}

// markSelfRestart writes the marker that tells post-install.sh that this
// fluxd restarts by itself after an update. The script then leaves it to
// fluxd, so that the restart waits for the end of a transfer. The function
// returns a function that removes the marker.
func markSelfRestart(logger *log.Logger) func() {
	if !underSystemd() {
		return func() {}
	}
	path := filepath.Join(config.RuntimeDir(), "self-restart")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err == nil {
		err = os.WriteFile(path, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644)
		if err != nil {
			logger.Printf("self-restart marker: %v", err)
		}
	}
	return func() { _ = os.Remove(path) }
}

// watchBinary returns the version of a new fluxd binary after it replaced
// this one, when no transfer or stream runs. It returns "" when ctx ends.
// Only a fluxd of systemd stops, because systemd starts it again. A fluxd
// that the user started reports the new binary and keeps running.
// FLUX_BINARY_POLL changes the interval of the check for tests.
func watchBinary(ctx context.Context, d *core.Daemon, logger *log.Logger) string {
	bin, err := upgrade.Self()
	if err != nil {
		logger.Printf("the check for a new fluxd binary is off: %v", err)
		return ""
	}
	interval := 5 * time.Second
	if v, err := time.ParseDuration(os.Getenv("FLUX_BINARY_POLL")); err == nil && v > 0 {
		interval = v
	}
	service := underSystemd()
	waiting := ""
	w := upgrade.Watcher{
		Binary:   bin,
		Interval: interval,
		Logf:     logger.Printf,
		Found: func(v string) {
			d.SetPendingVersion(v)
			if service {
				logger.Printf("fluxd %s is in %s. fluxd restarts when no transfer or stream runs", v, bin.Path)
			} else {
				logger.Printf("fluxd %s is in %s. To use it, restart fluxd", v, bin.Path)
			}
		},
		Ready: func() bool {
			if !service {
				return false
			}
			what := d.Busy()
			if what != "" && what != waiting {
				logger.Printf("the restart waits for %s", what)
			}
			waiting = what
			return what == ""
		},
	}
	return w.Run(ctx)
}

// refreshPlugin updates the omarchy-shell plugin of the user to the plugin
// that was installed with this fluxd. It changes only a plugin that the
// user added. It does not change a symlink to a checkout.
func refreshPlugin(logger *log.Logger) {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	src := plugin.Installed(exe)
	if src == "" {
		return
	}
	dest := plugin.UserDir()
	if fi, err := os.Lstat(dest); err != nil || !fi.IsDir() {
		return
	}
	files, err := plugin.Files(src, "")
	if err != nil {
		logger.Printf("plugin: %v", err)
		return
	}
	changed, err := plugin.Sync(files, dest)
	if err != nil {
		logger.Printf("plugin: %v", err)
		return
	}
	if !changed {
		return
	}
	logger.Printf("updated the omarchy-shell plugin in %s from %s", dest, src)
	// The file watcher of omarchy-shell reloads the plugin. A rescan also
	// covers a shell that does not watch. The shell can still be down at
	// login, and then it loads the new files when it starts.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, "omarchy-shell", "shell", "rescanPlugins").Run()
}

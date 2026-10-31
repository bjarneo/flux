package desktop

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// makoMode is the mako mode that Omarchy and the mako docs use for Do Not
// Disturb.
const makoMode = "do-not-disturb"

// dndTimeout limits each run of omarchy-shell and makoctl.
const dndTimeout = 5 * time.Second

// DND reads and sets Do Not Disturb of the desktop notification service.
// It supports the notification service of the Omarchy shell, and mako.
type DND struct {
	kind string
}

// NewDND picks the notification service of this desktop. Kind returns an
// empty string when Flux supports none of the services on this desktop.
func NewDND() *DND {
	d := &DND{}
	switch {
	case onPath("omarchy-shell"):
		d.kind = "omarchy-shell"
	case onPath("makoctl"):
		d.kind = "mako"
	}
	return d
}

// dndCommand returns a command that stops after the context ends. WaitDelay
// makes Wait return also when a child keeps the output open.
func dndCommand(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = time.Second
	return cmd
}

func onPath(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// Kind returns "omarchy-shell", "mako", or an empty string.
func (d *DND) Kind() string { return d.kind }

// Get returns the Do Not Disturb state. ok is false when the service does
// not answer.
func (d *DND) Get() (on, ok bool) {
	switch d.kind {
	case "omarchy-shell":
		ctx, cancel := context.WithTimeout(context.Background(), dndTimeout)
		defer cancel()
		out, err := dndCommand(ctx, "omarchy-shell", "notifications", "dndState").Output()
		if err != nil {
			return false, false
		}
		return omarchyDND(string(out))
	case "mako":
		ctx, cancel := context.WithTimeout(context.Background(), dndTimeout)
		defer cancel()
		out, err := dndCommand(ctx, "makoctl", "mode").Output()
		if err != nil {
			return false, false
		}
		return makoDND(string(out)), true
	}
	return false, false
}

// Set turns Do Not Disturb on or off.
func (d *DND) Set(on bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), dndTimeout)
	defer cancel()
	switch d.kind {
	case "omarchy-shell":
		value := "off"
		if on {
			value = "on"
		}
		if out, err := dndCommand(ctx, "omarchy-shell", "notifications", "setDnd", value).CombinedOutput(); err != nil {
			return fmt.Errorf("omarchy-shell: %w: %s", err, strings.TrimSpace(string(out)))
		}
		// The bar shows the state. omarchy-toggle-notification-silencing
		// refreshes it the same way.
		_ = dndCommand(ctx, "omarchy-shell", "-q", "omarchy.indicators", "refresh").Run()
		return nil
	case "mako":
		flag := "-r"
		if on {
			flag = "-a"
		}
		if out, err := dndCommand(ctx, "makoctl", "mode", flag, makoMode).CombinedOutput(); err != nil {
			return fmt.Errorf("makoctl: %w: %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	return errors.New("no supported notification service")
}

// omarchyDND reads the output of `omarchy-shell notifications dndState`.
// The shell answers through the notification service that is running, so it
// also works when a plugin replaces the built-in one.
func omarchyDND(out string) (on, ok bool) {
	switch strings.TrimSpace(out) {
	case "on":
		return true, true
	case "off":
		return false, true
	}
	return false, false
}

// makoDND reports whether the output of `makoctl mode` has the Do Not
// Disturb mode.
func makoDND(modes string) bool {
	for _, m := range strings.Fields(modes) {
		if m == makoMode {
			return true
		}
	}
	return false
}

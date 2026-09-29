package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// systemd splits ExecStart at spaces and replaces % and $, so the unit
// quotes the path of a checkout such as ~/My Code/flux.
func TestServiceUnitQuotesThePath(t *testing.T) {
	unit, err := serviceUnit(`/home/u/My Code/100% "a"\b/$HOME/fluxd`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(unit, "\nExecStart=\"/home/u/My Code/100%% \\\"a\\\"\\\\b/$$HOME/fluxd\"\n") {
		t.Fatalf("unit:\n%s", unit)
	}
	if !strings.Contains(unit, "\nType=exec\n") {
		t.Fatal("the unit must use Type=exec, so that a missing binary fails the start")
	}
	if !setupWrote(unit) {
		t.Fatal("setup does not know its own unit")
	}
	if _, err := serviceUnit("/home/u/flux\n/fluxd"); err == nil {
		t.Fatal("a path with a newline must fail")
	}
}

// setup removes only a unit that it wrote with no change: the unit of
// this version or of an earlier version.
func TestSetupWrote(t *testing.T) {
	for i, old := range oldUnits {
		if !setupWrote(strings.Replace(old, "@FLUXD@", "/home/u/.local/bin/fluxd", 1)) {
			t.Errorf("the unit of earlier setup %d", i)
		}
	}
	unit, _ := serviceUnit("/home/u/My Code/flux/bin/fluxd")
	if !setupWrote(unit) {
		t.Error("the unit of this setup")
	}
	changed := strings.Replace(unit, "RestartSec=2", "RestartSec=10", 1)
	if setupWrote(changed) {
		t.Error("a unit that the user changed")
	}
	own := "[Unit]\nDescription=My fluxd\n[Service]\nExecStart=/home/u/.local/bin/fluxd\n"
	if setupWrote(own) {
		t.Error("a unit of the user")
	}
	if setupWrote("") {
		t.Error("an empty file")
	}
}

// A user unit from a checkout hides the unit of the package. setup removes
// it, but it keeps a unit that the user wrote.
func TestRemoveUserUnit(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "fluxd.service")
	var ran []string
	run := func(what, name string, args ...string) error {
		ran = append(ran, name+" "+strings.Join(args, " "))
		return nil
	}
	if removed, err := removeUserUnit(path, false, run); err != nil || removed {
		t.Fatalf("no unit: %v %v", removed, err)
	}

	unit, _ := serviceUnit("/home/u/.local/bin/fluxd")
	if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
		t.Fatal(err)
	}
	if removed, err := removeUserUnit(path, true, run); err != nil || removed || len(ran) != 0 {
		t.Fatalf("--dry-run: %v %v %q", removed, err, ran)
	}
	if removed, err := removeUserUnit(path, false, run); err != nil || !removed {
		t.Fatalf("the unit of setup: %v %v", removed, err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("the unit stays")
	}
	if len(ran) != 1 || ran[0] != "systemctl --user disable fluxd.service" {
		t.Fatalf("commands %q", ran)
	}

	own := "[Unit]\nDescription=My fluxd\n[Service]\nExecStart=/opt/fluxd\n"
	if err := os.WriteFile(path, []byte(own), 0o644); err != nil {
		t.Fatal(err)
	}
	if removed, err := removeUserUnit(path, false, run); err != nil || removed {
		t.Fatalf("a unit of the user: %v %v", removed, err)
	}
	if b, _ := os.ReadFile(path); string(b) != own {
		t.Fatal("setup changed a unit of the user")
	}
}

// A failed step gives an error, so that `flux-cli setup && echo done`
// does not report a success.
func TestSetupFailsWhenAStepFails(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	old := systemUnit
	systemUnit = filepath.Join(t.TempDir(), "none.service")
	defer func() { systemUnit = old }()
	// The test binary has no fluxd next to it, so the service step fails.
	err := setup([]string{"--no-plugin"})
	if err == nil || err.Error() != "1 step failed" {
		t.Fatalf("got %v", err)
	}
}

func TestExecPath(t *testing.T) {
	v := "{ path=/home/u/My Code/bin/fluxd ; argv[]=/home/u/My Code/bin/fluxd ; ignore_errors=no ; start_time=[n/a] }"
	if got := execPath(v); got != "/home/u/My Code/bin/fluxd" {
		t.Errorf("got %q", got)
	}
	if got := execPath(""); got != "" {
		t.Errorf("empty: %q", got)
	}
}

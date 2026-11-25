package desktop

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseOmarchyDND(t *testing.T) {
	cases := map[string]bool{
		`{"version": 3, "dnd": true}`:  true,
		`{"version": 3, "dnd": false}`: false,
		`{"version": 3}`:               false,
	}
	for in, want := range cases {
		got, err := parseOmarchyDND([]byte(in))
		if err != nil || got != want {
			t.Errorf("%s: got %v, %v, want %v", in, got, err, want)
		}
	}
	if _, err := parseOmarchyDND([]byte(`{"dnd": tr`)); err == nil {
		t.Error("a partial file must fail, so that the next poll reads it again")
	}
}

func TestDNDStateFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notifications.json")
	d := &DND{kind: "omarchy-shell", statePath: path}
	fakeShell(t, `exit 1`)
	if _, ok := d.Get(); ok {
		t.Fatal("no answer and no file: the state must be unknown")
	}
	if err := os.WriteFile(path, []byte(`{"version": 3, "dnd": true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if on, ok := d.Get(); !ok || !on {
		t.Fatalf("dnd true: got %v, %v", on, ok)
	}
	// The shell replaces the file. A new time is a new state, also at the
	// same size.
	if err := os.WriteFile(path, []byte(`{"version": 3, "dnd":false}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, time.Now(), time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if on, ok := d.Get(); !ok || on {
		t.Fatalf("dnd false: got %v, %v", on, ok)
	}
}

func TestMakoDND(t *testing.T) {
	if !makoDND("default\ndo-not-disturb\n") {
		t.Error("the do-not-disturb mode is on")
	}
	if makoDND("default\n") || makoDND("") {
		t.Error("no do-not-disturb mode is off")
	}
}

func TestOmarchyDND(t *testing.T) {
	cases := map[string][2]bool{
		"on\n":                {true, true},
		"off\n":               {false, true},
		"":                    {false, false},
		"Function not found.": {false, false},
	}
	for in, want := range cases {
		on, ok := omarchyDND(in)
		if on != want[0] || ok != want[1] {
			t.Errorf("%q: got %v, %v, want %v, %v", in, on, ok, want[0], want[1])
		}
	}
}

// fakeShell puts an omarchy-shell script on the PATH. The script runs body.
func fakeShell(t *testing.T, body string) {
	t.Helper()
	dir := t.TempDir()
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(filepath.Join(dir, "omarchy-shell"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// The current Omarchy shell keeps Do Not Disturb in notifications/quiet.json
// and writes no notifications.json. Get must use the isDnd call.
func TestDNDShellCall(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "notifications.json")
	d := &DND{kind: "omarchy-shell", statePath: missing}

	fakeShell(t, `[ "$1 $2" = "notifications isDnd" ] && echo on`)
	if on, ok := d.Get(); !ok || !on {
		t.Fatalf("isDnd on: got %v, %v", on, ok)
	}
	fakeShell(t, `[ "$1 $2" = "notifications isDnd" ] && echo off`)
	if on, ok := d.Get(); !ok || on {
		t.Fatalf("isDnd off: got %v, %v", on, ok)
	}
}

// An older shell has no isDnd call and writes notifications.json.
func TestDNDShellCallFallback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notifications.json")
	if err := os.WriteFile(path, []byte(`{"version": 3, "dnd": true}`), 0o644); err != nil {
		t.Fatal(err)
	}
	d := &DND{kind: "omarchy-shell", statePath: path}
	fakeShell(t, `echo "Function not found." >&2; exit 1`)
	if on, ok := d.Get(); !ok || !on {
		t.Fatalf("fallback: got %v, %v", on, ok)
	}
}

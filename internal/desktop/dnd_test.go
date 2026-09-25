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
	if on, ok := d.Get(); !ok || on {
		t.Fatalf("no file: got %v, %v, want off", on, ok)
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

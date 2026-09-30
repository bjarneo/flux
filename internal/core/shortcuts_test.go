package core

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"flux/internal/proto"
)

func TestParseShortcuts(t *testing.T) {
	data := []byte(`[
		{"modmask":64,"key":"W","description":"Close window","has_description":true,"dispatcher":"__lua","arg":"68","submap":""},
		{"modmask":64,"key":"Q","description":"Close window","has_description":true,"dispatcher":"__lua","arg":"70","submap":""},
		{"modmask":65,"key":"RETURN","description":"Browser","has_description":true,"dispatcher":"__lua","arg":"317","submap":""},
		{"modmask":64,"key":"","keycode":0,"description":"Switch to workspace 3","has_description":true,"dispatcher":"__lua","arg":"114","submap":""},
		{"modmask":13,"key":"comma","description":"All modifiers","has_description":true,"dispatcher":"__lua","arg":"9","submap":""},
		{"modmask":64,"key":"mouse:272","description":"Move window","has_description":true,"mouse":true,"dispatcher":"__lua","arg":"200","submap":""},
		{"modmask":64,"key":"R","description":"Resize mode","has_description":true,"dispatcher":"__lua","arg":"201","submap":"resize"},
		{"modmask":64,"key":"E","description":"","has_description":false,"dispatcher":"__lua","arg":"202","submap":""},
		{"modmask":64,"key":"X","description":"Old style","has_description":true,"dispatcher":"exec","arg":"kitty","submap":""},
		{"modmask":64,"key":"Y","description":"Bad reference","has_description":true,"dispatcher":"__lua","arg":"1); os.exit(","submap":""}
	]`)
	got, err := parseShortcuts(data)
	if err != nil {
		t.Fatal(err)
	}
	want := []Shortcut{
		{Ref: "68", Keys: "SUPER W", Description: "Close window"},
		{Ref: "317", Keys: "SUPER SHIFT RETURN", Description: "Browser"},
		{Ref: "114", Keys: "SUPER", Description: "Switch to workspace 3"},
		{Ref: "9", Keys: "CTRL ALT SHIFT comma", Description: "All modifiers"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("shortcuts:\n got %+v\nwant %+v", got, want)
	}
	if _, err := parseShortcuts([]byte("not json")); err == nil {
		t.Fatal("no error for bad JSON")
	}
}

func TestParseWorkspaces(t *testing.T) {
	got, err := parseWorkspaces([]byte(`[{"id":-98,"windows":1},{"id":2,"windows":3},{"id":10,"windows":0}]`))
	if err != nil {
		t.Fatal(err)
	}
	if want := []Workspace{{2, 3}, {10, 0}}; !reflect.DeepEqual(got, want) {
		t.Fatalf("workspaces %+v, want %+v", got, want)
	}
}

func TestActionLua(t *testing.T) {
	cases := []struct {
		body shortcutBody
		want string
	}{
		{shortcutBody{Action: "workspace", Workspace: 3}, `hl.dsp.focus({ workspace = "3" })`},
		{shortcutBody{Action: "moveToWorkspace", Workspace: 10}, `hl.dsp.window.move({ workspace = "10" })`},
		{shortcutBody{Action: "focus", Direction: "l"}, `hl.dsp.focus({ direction = "l" })`},
		{shortcutBody{Action: "swap", Direction: "d"}, `hl.dsp.window.swap({ direction = "d" })`},
		{shortcutBody{Action: "close"}, `hl.dsp.window.close()`},
		{shortcutBody{Action: "scratchpad"}, `hl.dsp.workspace.toggle_special("scratchpad")`},
	}
	for _, c := range cases {
		got, err := actionLua(c.body)
		if err != nil || got != c.want {
			t.Errorf("%+v: got %q, %v, want %q", c.body, got, err, c.want)
		}
	}
	for _, bad := range []shortcutBody{
		{Action: "workspace", Workspace: 0},
		{Action: "workspace", Workspace: 11},
		{Action: "focus", Direction: "x"},
		{Action: "swap", Direction: `l" }) os.exit() --`},
		{Action: "exec"},
	} {
		if lua, err := actionLua(bad); err == nil {
			t.Errorf("%+v: no error, Lua %q", bad, lua)
		}
	}
}

func TestRunShortcutRefusesAnInvalidReference(t *testing.T) {
	d, _ := inputDaemon(t, true)
	for _, ref := range []string{"abc", "1)", "12345678901", "-1"} {
		err := d.runShortcut(shortcutBody{Run: ref})
		if err == nil || !strings.Contains(err.Error(), "not valid") {
			t.Errorf("run %q: %v", ref, err)
		}
	}
}

// A long value from the phone gives a short error for the journal and the
// answer.
func TestShortcutErrorsCutTheValue(t *testing.T) {
	d, _ := inputDaemon(t, true)
	long := strings.Repeat("x", 1<<20)
	short := func(what string, err error) {
		t.Helper()
		if err == nil {
			t.Errorf("%s: no error", what)
		} else if n := len(err.Error()); n > 300 {
			t.Errorf("%s: an error of %d bytes", what, n)
		}
	}
	short("run", d.runShortcut(shortcutBody{Run: long}))
	_, err := actionLua(shortcutBody{Action: long})
	short("action", err)
	_, err = actionLua(shortcutBody{Action: "focus", Direction: long})
	short("direction", err)
}

// fakeHyprctl puts a hyprctl on PATH that writes its arguments to the
// returned file and waits for delay seconds.
func fakeHyprctl(t *testing.T, delay string) string {
	t.Helper()
	dir := t.TempDir()
	calls := filepath.Join(dir, "calls")
	script := "#!/bin/sh\n" +
		"echo \"$*\" >> " + calls + "\n" +
		"/usr/bin/sleep " + delay + "\n" +
		"case \"$*\" in\n" +
		"'-j workspaces') echo '[{\"id\":1,\"windows\":2}]' ;;\n" +
		"'-j activeworkspace') echo '{\"id\":1}' ;;\n" +
		"'-j binds') echo '[]' ;;\n" +
		"esac\n"
	if err := os.WriteFile(filepath.Join(dir, "hyprctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	return calls
}

func hyprctlCalls(t *testing.T, path string) []string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return strings.Fields(strings.ReplaceAll(strings.TrimSpace(string(b)), " ", "_"))
}

func shortcutPacket(body map[string]any) *proto.Packet {
	return proto.New(proto.TypeFluxShortcuts, body)
}

// While the screen is locked, the phone gets the workspaces and nothing
// else: no binding, no window action, and no binding list.
func TestShortcutsWhileLocked(t *testing.T) {
	calls := fakeHyprctl(t, "0")
	locked := screenLocked
	screenLocked = func(context.Context) bool { return true }
	t.Cleanup(func() { screenLocked = locked })
	d, _ := inputDaemon(t, true)
	dev := inputDevice("phone", "Pixel 8")
	l := newFakeStreamLink()
	for _, body := range []map[string]any{
		{"run": "12"},
		{"action": "close"},
		{"action": "workspace", "workspace": 3},
		{"request": true},
	} {
		d.handleShortcuts(dev, l, shortcutPacket(body))
		waitFor(t, "the answer", func() bool { return len(l.states()) > 0 })
		l.mu.Lock()
		answer := l.sent[len(l.sent)-1]
		l.sent = nil
		l.mu.Unlock()
		if answer["error"] != lockedText {
			t.Fatalf("%v: answer %v", body, answer)
		}
	}
	if got := hyprctlCalls(t, calls); len(got) != 0 {
		t.Fatalf("hyprctl ran while the screen is locked: %q", got)
	}
	d.handleShortcuts(dev, l, shortcutPacket(map[string]any{}))
	waitFor(t, "the workspaces", func() bool { return len(l.states()) > 0 })
	l.mu.Lock()
	answer := l.sent[0]
	l.mu.Unlock()
	if answer["error"] != nil || answer["workspaces"] == nil || answer["shortcuts"] != nil {
		t.Fatalf("answer %v", answer)
	}
}

// A device has 1 request in flight. The requests that come during it join
// into 1 next request.
func TestShortcutsOneRequestInFlight(t *testing.T) {
	calls := fakeHyprctl(t, "0.2")
	locked := screenLocked
	screenLocked = func(context.Context) bool { return false }
	t.Cleanup(func() { screenLocked = locked })
	d, _ := inputDaemon(t, true)
	dev := inputDevice("phone", "Pixel 8")
	l := newFakeStreamLink()
	for range 50 {
		d.handleShortcuts(dev, l, shortcutPacket(map[string]any{}))
	}
	waitFor(t, "2 answers", func() bool { return len(l.states()) >= 2 })
	waitFor(t, "the end of the requests", func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		_, busy := d.sessions.shortcuts[dev.ID]
		return !busy
	})
	time.Sleep(100 * time.Millisecond)
	if n := len(l.states()); n != 2 {
		t.Fatalf("%d answers, want 2", n)
	}
	if got := hyprctlCalls(t, calls); len(got) != 4 {
		t.Fatalf("hyprctl ran %d times: %q", len(got), got)
	}
}

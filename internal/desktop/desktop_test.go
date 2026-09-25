package desktop

import (
	"os"
	"path/filepath"
	"testing"
	"time"
	"unsafe"
)

func TestShortNames(t *testing.T) {
	if got := shortName("org.mpris.MediaPlayer2.firefox.instance_1_42"); got != "firefox" {
		t.Errorf("firefox: got %q", got)
	}
	if got := shortName("org.mpris.MediaPlayer2.chromium.instance12345"); got != "chromium" {
		t.Errorf("chromium: got %q", got)
	}
	if got := shortName("org.mpris.MediaPlayer2.spotify"); got != "spotify" {
		t.Errorf("spotify: got %q", got)
	}
	names := shortNames([]string{
		"org.mpris.MediaPlayer2.firefox.instance_1_99",
		"org.mpris.MediaPlayer2.spotify",
		"org.mpris.MediaPlayer2.firefox.instance_1_42",
	})
	want := map[string]string{
		"firefox":   "org.mpris.MediaPlayer2.firefox.instance_1_42",
		"firefox 2": "org.mpris.MediaPlayer2.firefox.instance_1_99",
		"spotify":   "org.mpris.MediaPlayer2.spotify",
	}
	if len(names) != len(want) {
		t.Fatalf("got %v", names)
	}
	for k, v := range want {
		if names[k] != v {
			t.Errorf("%s: got %q, want %q", k, names[k], v)
		}
	}
}

func writeSupply(t *testing.T, root, name string, files map[string]string) {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for k, v := range files {
		if err := os.WriteFile(filepath.Join(dir, k), []byte(v+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestReadBattery(t *testing.T) {
	old := powerSupplyRoot
	t.Cleanup(func() { powerSupplyRoot = old })

	root := t.TempDir()
	powerSupplyRoot = root
	if b := ReadBattery(); b.Present {
		t.Fatalf("empty dir: got %+v", b)
	}

	writeSupply(t, root, "AC", map[string]string{"type": "Mains", "online": "0"})
	writeSupply(t, root, "BAT0", map[string]string{"type": "Battery", "capacity": "80", "status": "Discharging"})
	writeSupply(t, root, "BAT1", map[string]string{"type": "Battery", "capacity": "60", "status": "Discharging"})
	writeSupply(t, root, "hid-mouse-battery", map[string]string{"type": "Battery", "scope": "Device", "capacity": "5", "status": "Discharging"})
	if b := ReadBattery(); !b.Present || b.Charge != 70 || b.Charging {
		t.Fatalf("2 batteries: got %+v", b)
	}

	writeSupply(t, root, "BAT1", map[string]string{"status": "Charging"})
	if b := ReadBattery(); !b.Charging {
		t.Fatalf("charging: got %+v", b)
	}

	root = t.TempDir()
	powerSupplyRoot = root
	writeSupply(t, root, "BAT0", map[string]string{"type": "Battery", "capacity": "100", "status": "Full"})
	writeSupply(t, root, "ucsi-source-psy-USBC000:001", map[string]string{"type": "USB", "online": "1"})
	if b := ReadBattery(); !b.Charging || b.Charge != 100 {
		t.Fatalf("full on USB power: got %+v", b)
	}
}

func TestClipboardObserve(t *testing.T) {
	c := NewClipboard()
	if _, ok := c.observe("start"); ok {
		t.Fatal("the first selection must not be reported")
	}
	if text, ok := c.observe("new"); !ok || text != "new" {
		t.Fatal("a new selection must be reported")
	}
	if _, ok := c.observe("new"); ok {
		t.Fatal("the same text must not be reported again")
	}
	c.mu.Lock()
	c.lastSeen = "from phone"
	c.mu.Unlock()
	if _, ok := c.observe("from phone"); ok {
		t.Fatal("the echo of Set must not be reported")
	}
}

func TestLoopbackABI(t *testing.T) {
	if got := unsafe.Sizeof(loopbackConfig{}); got != 72 {
		t.Fatalf("struct v4l2_loopback_config has %d bytes, want 72", got)
	}
	if loopbackAdd != 0x40487e01 || loopbackRemove != 0x40047e02 {
		t.Fatalf("ioctl numbers %#x %#x", loopbackAdd, loopbackRemove)
	}
}

func TestFindLoopback(t *testing.T) {
	dir := t.TempDir()
	old := sysfsVideo
	sysfsVideo = dir
	defer func() { sysfsVideo = old }()
	for nr, name := range map[string]string{"video50": "Hardware ISP Camera", "video51": "Flux Camera"} {
		if err := os.MkdirAll(filepath.Join(dir, nr), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, nr, "name"), []byte(name+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if nr, ok := findLoopback("Flux Camera"); !ok || nr != 51 {
		t.Fatalf("findLoopback = %d, %v", nr, ok)
	}
	if _, ok := findLoopback("Nothing"); ok {
		t.Fatal("found a device that does not exist")
	}
}

// TestClipboardSetReturnsWhileWlCopyServes uses a fake wl-copy that, like
// the real one, leaves a background process that keeps its stdout and
// stderr open. Set must return at once and not wait for that process.
func TestClipboardSetReturnsWhileWlCopyServes(t *testing.T) {
	dir := t.TempDir()
	fake := "#!/bin/sh\ncat >/dev/null\n(sleep 30) &\nexit 0\n"
	if err := os.WriteFile(filepath.Join(dir, "wl-copy"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	done := make(chan error, 1)
	go func() { done <- NewClipboard().Set("hello") }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Set waits for the background wl-copy process")
	}
}

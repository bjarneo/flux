package config

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestNewConfigHasNoCommands(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Commands) != 0 {
		t.Fatalf("a new config has %d commands, want 0", len(c.Commands))
	}
}

func TestCommandsRoundTrip(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "flux"), 0o755); err != nil {
		t.Fatal(err)
	}
	own := "[[commands]]\nid = \"a\"\nname = \"A\"\ncommand = \"true\"\n"
	if err := os.WriteFile(filepath.Join(dir, "flux", "config.toml"), []byte(own), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Commands) != 1 || c.Commands[0].ID != "a" {
		t.Fatalf("own commands: %+v", c.Commands)
	}
	c.Commands = []Command{}
	if err := Save(c); err != nil {
		t.Fatal(err)
	}
	if c, _ = Load(); len(c.Commands) != 0 {
		t.Fatalf("an empty list did not stay empty: %d commands", len(c.Commands))
	}
}

func TestScanPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	c := &Config{}
	if got, want := c.ScanPath(), filepath.Join(home, "Documents", "flux", "scanned"); got != want {
		t.Errorf("default: %s, want %s", got, want)
	}
	if err := os.MkdirAll(filepath.Join(home, ".config"), 0o755); err != nil {
		t.Fatal(err)
	}
	dirs := "XDG_DOCUMENTS_DIR=\"$HOME/Dokumenter\"\n"
	if err := os.WriteFile(filepath.Join(home, ".config", "user-dirs.dirs"), []byte(dirs), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, want := c.ScanPath(), filepath.Join(home, "Dokumenter", "flux", "scanned"); got != want {
		t.Errorf("user-dirs: %s, want %s", got, want)
	}
	c.ScanDir = "~/scans"
	if got, want := c.ScanPath(), filepath.Join(home, "scans"); got != want {
		t.Errorf("scan_dir: %s, want %s", got, want)
	}
}

func TestPhotoPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	c := &Config{}
	if got, want := c.PhotoPath(), filepath.Join(home, "Pictures", "flux"); got != want {
		t.Errorf("default: %s, want %s", got, want)
	}
	c.PhotoDir = "~/phone"
	if got, want := c.PhotoPath(), filepath.Join(home, "phone"); got != want {
		t.Errorf("photo_dir: %s, want %s", got, want)
	}
}

func TestOffMarker(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	if IsOff() {
		t.Fatal("a new config must be on")
	}
	if err := os.MkdirAll(filepath.Dir(OffPath()), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(OffPath(), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if !IsOff() {
		t.Fatal("the marker must turn fluxd off")
	}
}

// A command without an ID in config.toml keeps the same ID at each load,
// so a key binding with `flux-cli run ID` keeps working.
func TestCommandIDsAreStable(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "flux"), 0o755); err != nil {
		t.Fatal(err)
	}
	own := "[[commands]]\nname = \"Lock\"\ncommand = \"omarchy-system-lock\"\n" +
		"[[commands]]\nname = \"Lock\"\ncommand = \"omarchy-system-lock\"\n" +
		"[[commands]]\nid = \"own\"\nname = \"Own\"\ncommand = \"true\"\n"
	if err := os.WriteFile(Path(), []byte(own), 0o644); err != nil {
		t.Fatal(err)
	}
	first, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	second, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	ids := map[string]bool{}
	for i, c := range first.Commands {
		if c.ID == "" || c.ID != second.Commands[i].ID {
			t.Fatalf("command %d: ID %q, then %q", i, c.ID, second.Commands[i].ID)
		}
		ids[c.ID] = true
	}
	if len(ids) != 3 || !ids["own"] {
		t.Fatalf("IDs %v, want 3 different IDs with own", ids)
	}
}

func TestRuntimeDir(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/test")
	if got := RuntimeDir(); got != "/run/user/test/flux" {
		t.Errorf("with XDG_RUNTIME_DIR: %s", got)
	}
	t.Setenv("FLUX_SOCKET", "")
	if got := SocketPath(); got != "/run/user/test/flux/fluxd.sock" {
		t.Errorf("socket: %s", got)
	}
	t.Setenv("FLUX_SOCKET", "/custom/fluxd.sock")
	if got := SocketPath(); got != "/custom/fluxd.sock" {
		t.Errorf("FLUX_SOCKET: %s", got)
	}
	// Without XDG_RUNTIME_DIR, Flux uses the runtime folder of the user,
	// never the shared temporary folder.
	t.Setenv("XDG_RUNTIME_DIR", "")
	want := "/run/user/" + strconv.Itoa(os.Getuid()) + "/flux"
	if got := RuntimeDir(); got != want {
		t.Errorf("without XDG_RUNTIME_DIR: %s, want %s", got, want)
	}
	if strings.HasPrefix(RuntimeDir(), os.TempDir()) {
		t.Errorf("the runtime folder %s is in the temporary folder", RuntimeDir())
	}
}

func TestWriteAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "devices.json")
	for _, data := range []string{"first", "second"} {
		if err := writeAtomic(path, []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
		if b, _ := os.ReadFile(path); string(b) != data {
			t.Fatalf("content %q, want %q", b, data)
		}
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Errorf("mode %v", st.Mode())
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Errorf("the folder has %d entries, want 1", len(entries))
	}
}

func TestCheckReportsAParseError(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	if err := Check(); err != nil {
		t.Fatalf("no file: %v", err)
	}
	if _, err := os.Stat(Path()); !os.IsNotExist(err) {
		t.Fatal("Check wrote a file")
	}
	if err := os.MkdirAll(ConfigDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(Path(), []byte("name = \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := Check(); err == nil || !strings.Contains(err.Error(), Path()) {
		t.Fatalf("a bad file: %v", err)
	}
}

// A devices.json that does not parse moves aside, and fluxd starts with an
// empty trust store.
func TestLoadTrustMovesABrokenFile(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	path := filepath.Join(DataDir(), "devices.json")
	if err := os.MkdirAll(DataDir(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(`[{"id":"phone"`), 0o600); err != nil {
		t.Fatal(err)
	}
	ts, err := LoadTrust()
	if err != nil {
		t.Fatal(err)
	}
	if len(ts.All()) != 0 || ts.BrokenErr == nil || !strings.HasPrefix(ts.Broken, path+".broken-") {
		t.Fatalf("store with %d devices, broken %q, error %v", len(ts.All()), ts.Broken, ts.BrokenErr)
	}
	if data, err := os.ReadFile(ts.Broken); err != nil || string(data) != `[{"id":"phone"` {
		t.Fatalf("moved file %q: %v", data, err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("devices.json stays: %v", err)
	}
	// The store works, and the next start finds the new file.
	if err := ts.Put(TrustedDevice{ID: "tablet"}); err != nil {
		t.Fatal(err)
	}
	ts, err = LoadTrust()
	if err != nil || ts.Broken != "" || len(ts.All()) != 1 {
		t.Fatalf("second load: %v, broken %q, %d devices", err, ts.Broken, len(ts.All()))
	}
}

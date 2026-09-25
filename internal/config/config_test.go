package config

import (
	"os"
	"path/filepath"
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

package main

import (
	"bytes"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A plugin folder with a Flux symlink to a checkout is a development
// layout. fluxd logs it and changes nothing, so the checkout keeps its
// edits.
func TestUpdatePluginSkipsLinkedFolder(t *testing.T) {
	src := t.TempDir()
	for _, f := range []string{"manifest.json", "Panel.qml", "Flux/Main.qml"} {
		p := filepath.Join(src, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("installed version"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	checkout := t.TempDir()
	if err := os.WriteFile(filepath.Join(checkout, "Main.qml"), []byte("my uncommitted edit"), 0o644); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "flux")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(checkout, filepath.Join(dest, "Flux")); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if updatePlugin(log.New(&out, "", 0), src, dest) {
		t.Fatal("fluxd changed a plugin with a symlink")
	}
	if b, _ := os.ReadFile(filepath.Join(checkout, "Main.qml")); string(b) != "my uncommitted edit" {
		t.Fatalf("the checkout file has %q", b)
	}
	if _, err := os.Lstat(filepath.Join(dest, "Flux")); err != nil {
		t.Fatalf("the link is gone: %v", err)
	}
	if !strings.Contains(out.String(), "is a symlink") {
		t.Fatalf("log %q", out.String())
	}

	// A plugin folder of real files gets the installed version.
	if err := os.Remove(filepath.Join(dest, "Flux")); err != nil {
		t.Fatal(err)
	}
	if !updatePlugin(log.New(&out, "", 0), src, dest) {
		t.Fatal("fluxd did not update the plugin")
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "Flux", "Main.qml")); string(b) != "installed version" {
		t.Fatalf("the plugin file has %q", b)
	}
}

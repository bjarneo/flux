package main

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestCopyPluginLayout copies the plugin from the checkout and checks the
// layout that `omarchy plugin validate` accepts: real files, the shared
// views in Flux/, and no tools folder.
func TestCopyPluginLayout(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "flux")
	if err := copyPlugin("../../gui/omarchy", "../../gui/qml", dest); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"manifest.json", "Panel.qml", "BarWidget.qml", "Service.qml", "Backend.qml", "Flux/qmldir", "Flux/FluxView.qml", "Flux/pages/qmldir", "Flux/components/qmldir"} {
		if _, err := os.Stat(filepath.Join(dest, want)); err != nil {
			t.Errorf("missing %s", want)
		}
	}
	_ = filepath.WalkDir(dest, func(path string, d fs.DirEntry, err error) error {
		rel, _ := filepath.Rel(dest, path)
		if d.Type()&fs.ModeSymlink != 0 {
			t.Errorf("symlink %s", rel)
		}
		if strings.Contains(rel, "tools") {
			t.Errorf("tools file %s", rel)
		}
		return nil
	})
	// The real validator, when this machine has Omarchy.
	if _, err := exec.LookPath("omarchy"); err == nil {
		if out, err := exec.Command("omarchy", "plugin", "validate", dest).CombinedOutput(); err != nil {
			t.Fatalf("omarchy plugin validate: %v\n%s", err, out)
		}
	}
}

package plugin

import (
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, root string, files ...string) {
	t.Helper()
	for _, f := range files {
		p := filepath.Join(root, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("// "+f), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func sync(t *testing.T, src, views, dest string) bool {
	t.Helper()
	files, err := Files(src, views)
	if err != nil {
		t.Fatal(err)
	}
	changed, err := Sync(files, dest)
	if err != nil {
		t.Fatal(err)
	}
	return changed
}

// TestCheckoutLayout copies the plugin from the checkout and checks the
// layout that `omarchy plugin validate` accepts: real files, the shared
// views in Flux/, and no tools folder.
func TestCheckoutLayout(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "flux")
	sync(t, "../../gui/omarchy", "../../gui/qml", dest)
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
		if strings.HasSuffix(rel, ".tmp") {
			t.Errorf("temporary file %s", rel)
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

// TestSystemLayout copies the plugin from the system install layout,
// where Flux/ already holds the real shared views. The copy must keep
// them, or the bar widget and panel fail to load while summon still
// answers "ok".
func TestSystemLayout(t *testing.T) {
	src := t.TempDir()
	write(t, src, "manifest.json", "Panel.qml", "BarWidget.qml", "Service.qml", "Backend.qml", "Flux/qmldir", "Flux/FluxView.qml", "Flux/components/FluxMark.qml")
	dest := filepath.Join(t.TempDir(), "flux")
	sync(t, src, "", dest)
	for _, want := range []string{"manifest.json", "Panel.qml", "BarWidget.qml", "Flux/qmldir", "Flux/FluxView.qml", "Flux/components/FluxMark.qml"} {
		if _, err := os.Stat(filepath.Join(dest, want)); err != nil {
			t.Errorf("missing %s", want)
		}
	}
}

// TestSyncUpdates checks an update: a changed file gets the new content,
// a removed file and its empty folder go away, and a second sync changes
// nothing.
func TestSyncUpdates(t *testing.T) {
	src := t.TempDir()
	write(t, src, "manifest.json", "Panel.qml", "Flux/old/Gone.qml")
	dest := filepath.Join(t.TempDir(), "flux")
	if !sync(t, src, "", dest) {
		t.Fatal("the first sync changed nothing")
	}

	if err := os.RemoveAll(filepath.Join(src, "Flux")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(src, "Panel.qml"), []byte("// new"), 0o644); err != nil {
		t.Fatal(err)
	}
	write(t, src, "Flux/New.qml")
	if !sync(t, src, "", dest) {
		t.Fatal("the update changed nothing")
	}
	if b, _ := os.ReadFile(filepath.Join(dest, "Panel.qml")); string(b) != "// new" {
		t.Errorf("Panel.qml has %q", b)
	}
	if _, err := os.Stat(filepath.Join(dest, "Flux", "old")); !os.IsNotExist(err) {
		t.Errorf("the old folder stays: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dest, "Flux", "New.qml")); err != nil {
		t.Errorf("the new file is missing: %v", err)
	}
	if sync(t, src, "", dest) {
		t.Error("a second sync changed files")
	}
}

func TestInstalledNextToBinary(t *testing.T) {
	prefix := t.TempDir()
	exe := filepath.Join(prefix, "bin", "fluxd")
	if got := Installed(exe); got != "" {
		t.Fatalf("Installed = %q with no plugin", got)
	}
	write(t, filepath.Join(prefix, "share", "flux", "omarchy-plugin"), "manifest.json")
	want := filepath.Join(prefix, "share", "flux", "omarchy-plugin")
	if got := Installed(exe); got != want {
		t.Fatalf("Installed = %q, want %q", got, want)
	}
	if src, views, err := Source(exe); err != nil || src != want || views != "" {
		t.Fatalf("Source = %q, %q, %v", src, views, err)
	}
}

// Sync keeps the files that the user added, and it removes only the files
// that an earlier Sync wrote.
func TestSyncKeepsUserFiles(t *testing.T) {
	src := t.TempDir()
	write(t, src, "manifest.json", "Panel.qml", "Flux/Old.qml")
	dest := filepath.Join(t.TempDir(), "flux")
	write(t, dest, "notes.txt", "Flux/Mine.qml")
	sync(t, src, "", dest)
	if err := os.Remove(filepath.Join(src, "Flux", "Old.qml")); err != nil {
		t.Fatal(err)
	}
	sync(t, src, "", dest)
	for _, keep := range []string{"notes.txt", "Flux/Mine.qml", "Panel.qml"} {
		if _, err := os.Stat(filepath.Join(dest, keep)); err != nil {
			t.Errorf("%s is gone: %v", keep, err)
		}
	}
	if _, err := os.Stat(filepath.Join(dest, "Flux", "Old.qml")); !os.IsNotExist(err) {
		t.Errorf("the file of the earlier version stays: %v", err)
	}
}

// Sync does not write through a Flux folder that links to a checkout, and
// it does not remove the link.
func TestSyncRefusesLinkedFolder(t *testing.T) {
	src := t.TempDir()
	write(t, src, "manifest.json", "Flux/Main.qml")
	checkout := t.TempDir()
	if err := os.WriteFile(filepath.Join(checkout, "Main.qml"), []byte("my edit"), 0o644); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "flux")
	if err := os.MkdirAll(dest, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(checkout, filepath.Join(dest, "Flux")); err != nil {
		t.Fatal(err)
	}
	files, err := Files(src, "")
	if err != nil {
		t.Fatal(err)
	}
	changed, err := Sync(files, dest)
	if !errors.Is(err, ErrLinked) || changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	if b, _ := os.ReadFile(filepath.Join(checkout, "Main.qml")); string(b) != "my edit" {
		t.Fatalf("the checkout file has %q", b)
	}
	if fi, err := os.Lstat(filepath.Join(dest, "Flux")); err != nil || fi.Mode()&fs.ModeSymlink == 0 {
		t.Fatalf("the link is gone: %v", err)
	}
}

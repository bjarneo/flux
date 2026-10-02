package omarchytheme

import (
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestRevisionStableAcrossReaderRestartButDetectsABA(t *testing.T) {
	r, _ := selectionFixture(t)
	first, ok := r.ReadRevision()
	if !ok || !ValidRevision(first.Revision) {
		t.Fatal("missing revision")
	}
	restarted := Reader{Home: r.Home, SystemThemes: r.SystemThemes, RuntimeDir: r.RuntimeDir}
	second, ok := restarted.ReadRevision()
	if !ok || first.Revision != second.Revision {
		t.Fatal("unchanged state revision changed on restart")
	}
	name := filepath.Join(r.Home, ".local/state/omarchy/current/theme.name")
	put(t, name, "gruvbox\n")
	put(t, name, "tokyo-night\n")
	after, ok := r.ReadRevision()
	if !ok || first.Revision == after.Revision {
		t.Fatal("A→B→A reused old revision")
	}
	legacy, ok := r.Read()
	if !ok || legacy.Version != 1 || legacy.Revision != "" {
		t.Fatal("legacy catalog shape changed")
	}
	for _, theme := range legacy.Themes {
		if theme.Palette.Geometry != nil {
			t.Fatal("legacy palette gained geometry")
		}
	}
}

func TestRevisionProjectsLiteralGeometryAndDefaults(t *testing.T) {
	r, _ := selectionFixture(t)
	c, ok := r.ReadRevision()
	currentGeometry := func(c Catalog) *Geometry {
		for _, theme := range c.Themes {
			if theme.ID == c.Current {
				return theme.Palette.Geometry
			}
		}
		return nil
	}
	if !ok || currentGeometry(c) == nil || currentGeometry(c).CornerRadius != 0 {
		t.Fatal("default geometry unavailable")
	}
	put(t, filepath.Join(r.Home, ".config/hypr/looknfeel.lua"), "-- rounding = 88,\ndecoration = {\n  rounding = 8, -- user override\n}\n")
	c, ok = r.ReadRevision()
	if !ok || currentGeometry(c) == nil || currentGeometry(c).CornerRadius != 8 {
		t.Fatal("literal geometry was not projected")
	}
}

func TestHeldLockRevisionVerifiesCanonicalLockInode(t *testing.T) {
	r, _ := selectionFixture(t)
	first, ok := r.ReadRevision()
	if !ok {
		t.Fatal("missing revision")
	}
	fd, err := unix.Open(filepath.Join(r.RuntimeDir, "omarchy-theme-set.lock"), unix.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)
	if err := unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	held, ok := r.ReadUnderHeldLock(fd)
	if !ok || held.Revision != first.Revision {
		t.Fatal("held-lock reader did not retain exact revision")
	}
	if _, ok := r.ReadRevision(); ok {
		t.Fatal("shared reader bypassed held exclusive lock")
	}
	other, err := os.CreateTemp(t.TempDir(), "not-canonical")
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if _, ok := r.ReadUnderHeldLock(int(other.Fd())); ok {
		t.Fatal("unrelated fd received CAS authority")
	}
}

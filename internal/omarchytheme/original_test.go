package omarchytheme

import (
	"bytes"
	"errors"
	"flux/internal/wallpaper"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func originalFixture(t *testing.T) (Reader, Catalog, wallpaper.Meta, []byte, string) {
	r, c, old := backgroundFixture(t)
	var b bytes.Buffer
	png.Encode(&b, image.NewRGBA(image.Rect(0, 0, 3840, 2160)))
	data := b.Bytes()
	m := wallpaper.Meta{Operation: strings.Repeat("a", 32), Origin: "phone", Revision: c.Revision, Theme: c.Current, SHA256: wallpaper.Digest(data), MIME: "image/png", Size: len(data), Width: 3840, Height: 2160}
	return r, c, m, data, old
}
func TestOriginalCommitRetryAndRoundTrip(t *testing.T) {
	r, c, m, data, old := originalFixture(t)
	calls := 0
	notify := func(string) error { calls++; return nil }
	revision, e := r.CommitOriginal(m, data, func() bool { return true }, notify)
	if e != nil || revision == c.Revision || calls != 1 {
		t.Fatal(revision, e, calls)
	}
	next, ok := r.ReadRevision()
	if !ok {
		t.Fatal("catalog")
	}
	got, e := r.Original(next)
	if e != nil || !bytes.Equal(got, data) {
		t.Fatal("roundtrip lost original", e)
	}
	if _, e = os.Stat(old); e != nil {
		t.Fatal("old image lost")
	}
	again, e := r.CommitOriginal(m, data, func() bool { return true }, notify)
	if e != nil || again != revision || calls != 1 {
		t.Fatal("retry reapplied", e, calls)
	}
}
func TestOriginalFailureRollbackAndStaleConflict(t *testing.T) {
	for _, mode := range []string{"notify", "stale", "revoked", "corrupt"} {
		t.Run(mode, func(t *testing.T) {
			r, _, m, data, old := originalFixture(t)
			if mode == "stale" {
				m.Revision = strings.Repeat("f", 64)
			}
			if mode == "corrupt" {
				data = append([]byte{}, data...)
				data[len(data)-1] ^= 1
			}
			_, e := r.CommitOriginal(m, data, func() bool { return mode != "revoked" }, func(string) error { return errors.New("IPC failed") })
			if e == nil {
				t.Fatal("accepted invalid commit")
			}
			target, e := os.Readlink(filepath.Join(r.Home, ".local/state/omarchy/current/background"))
			if e != nil || target != old {
				t.Fatal("rollback lost old selection", e, target)
			}
		})
	}
}

func TestOperationReuseAndLostAckDoNotRewrite(t *testing.T) {
	r, _, m, data, _ := originalFixture(t)
	calls := 0
	notify := func(string) error { calls++; return nil }
	revision, e := r.CommitOriginal(m, data, func() bool { return true }, notify)
	if e != nil {
		t.Fatal(e)
	}
	// A different operation ID may choose the same original; it still does not run IPC.
	retry := m
	retry.Operation = strings.Repeat("b", 32)
	retry.Revision = revision
	if _, e = r.CommitOriginal(retry, data, func() bool { return true }, notify); e != nil || calls != 1 {
		t.Fatal("same pixels changed", e, calls)
	}
	reused := m
	reused.Revision = revision
	if _, e = r.CommitOriginal(reused, data, func() bool { return true }, notify); e == nil {
		t.Fatal("operation metadata reused")
	}
	// Reopening Reader simulates process restart: ledger survives and ACK is historical.
	reopened := Reader{Home: r.Home, SystemThemes: r.SystemThemes, RuntimeDir: r.RuntimeDir}
	if got, e := reopened.CommitOriginal(m, data, func() bool { return true }, notify); e != nil || got != revision || calls != 1 {
		t.Fatal("durable retry", e, calls)
	}
}

func TestOriginalCommitLeavesThemeAlbumAndPublicBackgroundIntact(t *testing.T) {
	r, _, m, data, public := originalFixture(t)
	publicBefore, err := os.ReadFile(public)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.CommitOriginal(m, data, func() bool { return true }, func(string) error { return nil }); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(r.Home, ".local/state/omarchy/current")
	link := filepath.Join(state, "background")
	selected, err := os.Readlink(link)
	cache := filepath.Join(r.Home, ".local/state/omarchy/flux-wallpapers", m.SHA256+".png")
	if err != nil || selected != cache {
		t.Fatal("original was not selected from the separate cache", selected, err)
	}
	album := filepath.Join(r.Home, ".config/omarchy/backgrounds", m.Theme)
	if _, err := os.Stat(album); !os.IsNotExist(err) {
		t.Fatal("receiving a selection created a theme album", err)
	}
	publicAfter, err := os.ReadFile(public)
	if err != nil || !bytes.Equal(publicBefore, publicAfter) {
		t.Fatal("receiving an image altered the theme background", err)
	}
	// A canonical theme application chooses among its album and staged
	// backgrounds. With the received image outside both roots, this fixture's
	// sole staged background remains the theme choice. Simulate its link commit.
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(public, link); err != nil {
		t.Fatal(err)
	}
	catalog, ok := r.ReadRevision()
	if !ok {
		t.Fatal("theme background revision")
	}
	got, err := r.Original(catalog)
	if err != nil || !bytes.Equal(got, publicBefore) {
		t.Fatal("theme selection kept the received original", err)
	}
	cached, err := os.ReadFile(cache)
	if err != nil || !bytes.Equal(cached, data) {
		t.Fatal("theme selection discarded the received image", err)
	}
}

func TestOriginalCommitRejectsSymlinkCache(t *testing.T) {
	r, _, m, data, old := originalFixture(t)
	cache := filepath.Join(r.Home, ".local/state/omarchy/flux-wallpapers")
	outside := t.TempDir()
	if err := os.Symlink(outside, cache); err != nil {
		t.Fatal(err)
	}
	if _, err := r.CommitOriginal(m, data, func() bool { return true }, func(string) error { return nil }); err == nil {
		t.Fatal("symlink cache was accepted")
	}
	entries, err := os.ReadDir(outside)
	if err != nil || len(entries) != 0 {
		t.Fatal("original was staged outside its cache", err)
	}
	selected, err := os.Readlink(filepath.Join(r.Home, ".local/state/omarchy/current/background"))
	if err != nil || selected != old {
		t.Fatal("unsafe storage changed the current selection", err)
	}
}

func TestOriginalSharedCacheDoesNotBypassThemeConflict(t *testing.T) {
	r, _, m, data, _ := originalFixture(t)
	calls := 0
	notify := func(string) error { calls++; return nil }
	if _, err := r.CommitOriginal(m, data, func() bool { return true }, notify); err != nil {
		t.Fatal(err)
	}
	// The pixels can stay selected while a new theme becomes active. A fresh
	// operation for the old theme must not take the same-file retry shortcut.
	put(t, filepath.Join(r.Home, ".local/state/omarchy/current/theme.name"), "other-theme\n")
	current, ok := r.ReadRevision()
	if !ok {
		t.Fatal("changed theme revision")
	}
	retry := m
	retry.Operation = strings.Repeat("b", 32)
	retry.Revision = current.Revision
	if _, err := r.CommitOriginal(retry, data, func() bool { return true }, notify); err == nil {
		t.Fatal("shared cached pixels bypassed the current theme guard")
	}
	if calls != 1 {
		t.Fatal("theme conflict reapplied a background", calls)
	}
}

func TestOriginalManualExternalSelectionTracksOnlyCanonicalTarget(t *testing.T) {
	r, previous, old := backgroundFixture(t)
	external := filepath.Join(r.Home, "Pictures", "manual.png")
	writeBackground(t, external, image.NewUniform(color.White))
	wanted, err := os.ReadFile(external)
	if err != nil {
		t.Fatal(err)
	}
	// Creating another image never grants that image any transfer authority.
	before, err := r.Original(previous)
	oldBytes, _ := os.ReadFile(old)
	if err != nil || !bytes.Equal(before, oldBytes) {
		t.Fatal("unselected image changed the original", err)
	}
	link := filepath.Join(r.Home, ".local/state/omarchy/current/background")
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(external, link); err != nil {
		t.Fatal(err)
	}
	selected, ok := r.ReadRevision()
	if !ok || selected.Revision == previous.Revision {
		t.Fatal("manual selection did not change the revision")
	}
	if _, err := r.Original(previous); err == nil {
		t.Fatal("old revision read a newly selected image")
	}
	got, err := r.Original(selected)
	if err != nil || !bytes.Equal(got, wanted) {
		t.Fatal("manual image original was not preserved", err)
	}
	// The legacy preview API retains its original theme-root restriction.
	if _, ok := r.Background(selected, selected.Revision); ok {
		t.Fatal("external original unexpectedly widened the preview API")
	}
	writeBackground(t, external, image.NewUniform(color.Black))
	changed, ok := r.ReadRevision()
	if !ok || changed.Revision == selected.Revision {
		t.Fatal("in-place manual image edit did not change the revision")
	}
	if _, err := r.Original(selected); err == nil {
		t.Fatal("stale revision read an in-place image edit")
	}
	got, err = r.Original(changed)
	wanted, _ = os.ReadFile(external)
	if err != nil || !bytes.Equal(got, wanted) {
		t.Fatal("updated manual image unavailable", err)
	}
}

func TestOriginalManualSelectionRejectsUnsafeOrNonImageSources(t *testing.T) {
	for _, kind := range []string{"non-image", "symlink-file", "symlink-directory", "oversized", "wrong-current"} {
		t.Run(kind, func(t *testing.T) {
			r, _, _ := backgroundFixture(t)
			path := filepath.Join(r.Home, "Pictures", "manual.png")
			writeBackground(t, path, image.NewUniform(color.White))
			switch kind {
			case "non-image":
				if err := os.WriteFile(path, []byte("not an image"), 0600); err != nil {
					t.Fatal(err)
				}
			case "symlink-file":
				outside := filepath.Join(t.TempDir(), "image.png")
				writeBackground(t, outside, image.NewUniform(color.White))
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, path); err != nil {
					t.Fatal(err)
				}
			case "symlink-directory":
				outside := t.TempDir()
				writeBackground(t, filepath.Join(outside, "manual.png"), image.NewUniform(color.White))
				if err := os.RemoveAll(filepath.Dir(path)); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, filepath.Dir(path)); err != nil {
					t.Fatal(err)
				}
			case "oversized":
				if err := os.Truncate(path, wallpaper.MaxBytes+1); err != nil {
					t.Fatal(err)
				}
			}
			link := filepath.Join(r.Home, ".local/state/omarchy/current/background")
			if err := os.Remove(link); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(path, link); err != nil {
				t.Fatal(err)
			}
			catalog, ok := r.ReadRevision()
			if !ok {
				t.Fatal("catalog missing")
			}
			if kind == "wrong-current" {
				catalog.Current = "other-theme"
			}
			if _, err := r.Original(catalog); err == nil {
				t.Fatal("unsafe original source accepted")
			}
		})
	}
}

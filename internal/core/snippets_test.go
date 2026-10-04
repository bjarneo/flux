package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSavedSnippetsSurviveAndExpire(t *testing.T) {
	d, clip := clipDaemon(t, true)
	d.snippetsDir = t.TempDir()
	d.clipboard = []ClipEntry{{ID: "note", Text: "A complete searchable note"}}
	if _, err := d.pinClip("note", time.Now().Add(time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	d.clipboard, d.snippets = nil, nil
	if err := d.loadSnippets(); err != nil {
		t.Fatal(err)
	}
	if len(d.searchClips("SEARCHABLE")) != 1 {
		t.Fatal("saved text is not searchable")
	}
	if err := d.CopyClip("note"); err != nil {
		t.Fatal(err)
	}
	if clip.text != "A complete searchable note" {
		t.Fatal(clip.text)
	}
	if err := d.expireSnippetsLocked(time.Now().Add(2 * time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	if len(d.searchClips("")) != 0 {
		t.Fatal("expired snippet remains")
	}
	if err := d.loadSnippets(); err != nil || len(d.snippets) != 0 {
		t.Fatal("expiry did not persist", err)
	}
}

func TestSaveClipboardImageCopiesRuntimeFile(t *testing.T) {
	d, _ := clipDaemon(t, true)
	d.snippetsDir = t.TempDir()
	path := filepath.Join(t.TempDir(), "clip.png")
	if err := os.WriteFile(path, testPNG(4), 0o600); err != nil {
		t.Fatal(err)
	}
	d.clipboard = []ClipEntry{{ID: "image", Image: path}}
	e, err := d.pinClip("image", 0)
	if err != nil {
		t.Fatal(err)
	}
	if e.Image == path {
		t.Fatal("saved image uses the runtime file")
	}
	os.Remove(path)
	d.clipboard = nil
	if err := d.CopyClip("image"); err != nil {
		t.Fatal(err)
	}
	if err := d.unpinClip("image"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(e.Image); !os.IsNotExist(err) {
		t.Fatal("saved image remains", err)
	}
}

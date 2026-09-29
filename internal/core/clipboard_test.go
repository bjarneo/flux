package core

import (
	"bytes"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"

	"flux/internal/config"
)

// testPNG returns the start of a PNG file with the byte b after it, so
// that each value makes a different image.
func testPNG(b byte) []byte {
	return append([]byte("\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR"), b)
}

func clipDaemon(t *testing.T, auto bool) (*Daemon, *memClipboard) {
	clip := &memClipboard{}
	return &Daemon{
		cfg:     &config.Config{AutoClipboard: auto},
		clip:    clip,
		clipDir: t.TempDir(),
		devices: map[string]*Device{},
		logger:  log.New(io.Discard, "", 0),
	}, clip
}

func clipFiles(t *testing.T, dir string) int {
	names, err := filepath.Glob(filepath.Join(dir, "clip-*"))
	if err != nil {
		t.Fatal(err)
	}
	return len(names)
}

func TestClipImageHistory(t *testing.T) {
	d, _ := clipDaemon(t, true)
	for i := range maxClipImages + 2 {
		d.addClipLocked(ClipEntry{Text: fmt.Sprint("text ", i), Dir: "out"})
		if err := d.addClipImage(ClipEntry{Dir: "in"}, testPNG(byte(i)), "image/png"); err != nil {
			t.Fatal(err)
		}
	}
	images := 0
	for _, e := range d.clipboard {
		if e.Image != "" {
			images++
			if e.Text != "" {
				t.Errorf("image entry has text %q", e.Text)
			}
		}
	}
	if images != maxClipImages {
		t.Errorf("history has %d images, want %d", images, maxClipImages)
	}
	if n := clipFiles(t, d.clipDir); n != maxClipImages {
		t.Errorf("folder has %d images, want %d", n, maxClipImages)
	}
	if len(d.clipboard) != maxClipImages+maxClipImages+2 {
		t.Errorf("history has %d entries", len(d.clipboard))
	}

	// The same image again changes only the time of the top entry.
	top := d.clipboard[0]
	if err := d.addClipImage(ClipEntry{Dir: "in", Time: 99}, testPNG(maxClipImages+1), "image/png"); err != nil {
		t.Fatal(err)
	}
	if d.clipboard[0].Image != top.Image || d.clipboard[0].Time != 99 {
		t.Errorf("top entry %+v", d.clipboard[0])
	}
	if n := clipFiles(t, d.clipDir); n != maxClipImages {
		t.Errorf("folder has %d images after a repeat, want %d", n, maxClipImages)
	}
}

func TestClipHistoryDropsOldImages(t *testing.T) {
	d, _ := clipDaemon(t, true)
	if err := d.addClipImage(ClipEntry{Dir: "in"}, testPNG(1), "image/png"); err != nil {
		t.Fatal(err)
	}
	for i := range maxClipboard {
		d.addClipLocked(ClipEntry{Text: fmt.Sprint(i), Dir: "out"})
	}
	if len(d.clipboard) != maxClipboard {
		t.Fatalf("history has %d entries", len(d.clipboard))
	}
	if n := clipFiles(t, d.clipDir); n != 0 {
		t.Errorf("the image of a dropped entry stays on disk")
	}
}

func TestReceiveClipImage(t *testing.T) {
	d, clip := clipDaemon(t, true)
	dev := &Device{ID: "phone", Name: "Pixel 8"}
	jpeg := []byte("\xff\xd8\xff\xe0\x00\x10JFIF\x00")
	d.receiveClipImage(dev, jpeg)
	if clip.mime != "image/jpeg" || !bytes.Equal(clip.image, jpeg) {
		t.Errorf("clipboard has %q as %s", clip.image, clip.mime)
	}
	if len(d.clipboard) != 1 || d.clipboard[0].Dir != "in" || d.clipboard[0].DeviceName != "Pixel 8" {
		t.Fatalf("history %+v", d.clipboard)
	}
	if filepath.Ext(d.clipboard[0].Image) != ".jpg" {
		t.Errorf("image path %s", d.clipboard[0].Image)
	}

	// Data that is not an image stays off the clipboard.
	clip.image, clip.mime = nil, ""
	d.receiveClipImage(dev, []byte("#!/bin/sh\nrm -rf ~\n"))
	if clip.image != nil || len(d.clipboard) != 1 {
		t.Errorf("clipboard has %q, history has %d entries", clip.image, len(d.clipboard))
	}

	// Without automatic sync, the image goes only into the history.
	d.cfg.AutoClipboard = false
	d.receiveClipImage(dev, testPNG(2))
	if clip.image != nil || len(d.clipboard) != 2 {
		t.Errorf("clipboard has %q, history has %d entries", clip.image, len(d.clipboard))
	}
}

func TestCopyClipImage(t *testing.T) {
	d, clip := clipDaemon(t, true)
	if err := d.addClipImage(ClipEntry{Dir: "in"}, testPNG(1), "image/png"); err != nil {
		t.Fatal(err)
	}
	if err := d.CopyClipImage(d.clipboard[0].Image); err != nil {
		t.Fatal(err)
	}
	if clip.mime != "image/png" || !bytes.Equal(clip.image, testPNG(1)) {
		t.Errorf("clipboard has %q as %s", clip.image, clip.mime)
	}

	// A path that is not in the history is refused.
	other := filepath.Join(t.TempDir(), "secret.png")
	if err := os.WriteFile(other, testPNG(2), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := d.CopyClipImage(other); err == nil {
		t.Error("copied a file that is not in the history")
	}
}

func TestRemoveClipImages(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"clip-a.png", "clip-b.jpg", "keep.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	removeClipImages(dir)
	if n := clipFiles(t, dir); n != 0 {
		t.Errorf("%d images stay", n)
	}
	if _, err := os.Stat(filepath.Join(dir, "keep.txt")); err != nil {
		t.Error("removed a file that is not a clipboard image")
	}
}

func TestClipPreview(t *testing.T) {
	d, clip := clipDaemon(t, true)
	long := strings.Repeat("é", maxClipPreview)
	d.addClipLocked(ClipEntry{Text: long, Dir: "out"})
	d.addClipLocked(ClipEntry{Text: "short", Dir: "out"})
	view := d.clipPreviewLocked()
	if view[0].Text != "short" || view[0].Truncated || view[0].Size != 0 {
		t.Errorf("short entry = %+v", view[0])
	}
	if !view[1].Truncated || view[1].Size != len(long) || len(view[1].Text) > maxClipPreview || !utf8.ValidString(view[1].Text) {
		t.Errorf("long entry: truncated %v, size %d, %d text bytes", view[1].Truncated, view[1].Size, len(view[1].Text))
	}
	if d.clipboard[1].Text != long {
		t.Error("the preview changed the history")
	}
	if view[0].ID == "" || view[0].ID == view[1].ID {
		t.Errorf("entry IDs %q and %q", view[0].ID, view[1].ID)
	}
	if err := d.CopyClip(view[1].ID); err != nil {
		t.Fatal(err)
	}
	if clip.text != long {
		t.Errorf("CopyClip put %d bytes on the clipboard, want %d", len(clip.text), len(long))
	}
	if err := d.CopyClip("missing"); err == nil {
		t.Error("CopyClip of a missing ID returned no error")
	}
}

package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"flux/internal/config"
)

func TestDestDir(t *testing.T) {
	cfg := &config.Config{DownloadDir: "/tmp/dl", ScanDir: "/tmp/scan", PhotoDir: "/tmp/pics"}
	cases := map[fileDest]string{
		destDownload:   "/tmp/dl",
		destScan:       "/tmp/scan",
		destPhoto:      "/tmp/pics",
		destScreenshot: "/tmp/pics/screenshots",
		destSignature:  "/tmp/pics/signatures",
	}
	for kind, want := range cases {
		if got := destDir(cfg, kind); got != want {
			t.Errorf("kind %d: got %s, want %s", kind, got, want)
		}
	}
}

func TestCopyImage(t *testing.T) {
	dir := t.TempDir()
	clip := &memClipboard{}
	d := &Daemon{clip: clip}

	png := filepath.Join(dir, "signature.png")
	data := append([]byte("\x89PNG\r\n\x1a\n"), 1, 2, 3)
	if err := os.WriteFile(png, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := d.copyImage(png); err != nil {
		t.Fatal(err)
	}
	if clip.mime != "image/png" || string(clip.image) != string(data) {
		t.Errorf("clipboard has %q as %s", clip.image, clip.mime)
	}

	// A file that is not an image stays off the clipboard.
	other := filepath.Join(dir, "signature.txt")
	if err := os.WriteFile(other, []byte("not an image"), 0o644); err != nil {
		t.Fatal(err)
	}
	clip.image, clip.mime = nil, ""
	if err := d.copyImage(other); err == nil {
		t.Error("copied a file that is not an image")
	}
	if clip.image != nil {
		t.Errorf("clipboard has %q", clip.image)
	}
}

func TestCopyFile(t *testing.T) {
	dir := t.TempDir()
	clip := &memClipboard{}
	d := &Daemon{clip: clip}

	// An image goes on the clipboard as image data.
	png := filepath.Join(dir, "shot.png")
	data := append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 16)...)
	if err := os.WriteFile(png, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := d.copyFile(png); err != nil {
		t.Fatal(err)
	}
	if clip.mime != "image/png" || string(clip.image) != string(data) {
		t.Errorf("clipboard has %q as %s", clip.image, clip.mime)
	}

	// Any other file goes on the clipboard as a file URI.
	doc := filepath.Join(dir, "a b.pdf")
	if err := os.WriteFile(doc, []byte("%PDF-1.7"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := d.copyFile(doc); err != nil {
		t.Fatal(err)
	}
	want := "file://" + filepath.ToSlash(dir) + "/a%20b.pdf\r\n"
	if clip.mime != "text/uri-list" || string(clip.image) != want {
		t.Errorf("clipboard has %q as %s, want %q", clip.image, clip.mime, want)
	}
}

func TestTransferPath(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "IMG_1.jpg")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	d := &Daemon{transfers: []*Transfer{
		{ID: "done", Name: "IMG_1.jpg", Path: file, State: "done"},
		{ID: "active", Name: "VID.mp4", Path: filepath.Join(dir, "VID.mp4"), State: "active"},
		{ID: "gone", Name: "old.txt", Path: filepath.Join(dir, "old.txt"), State: "done"},
	}}
	if got, err := d.transferPath("done"); err != nil || got != file {
		t.Errorf("done: got %q, %v", got, err)
	}
	for _, id := range []string{"active", "gone", "missing"} {
		if _, err := d.transferPath(id); err == nil {
			t.Errorf("%s: no error", id)
		}
	}
}

func TestWriteScan(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "flux", "scanned")
	now := time.Date(2026, 9, 25, 11, 15, 30, 0, time.Local)
	first, err := writeScan(dir, "Gate B14\nBoarding 15:40", now)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(first) != "scan-2026-09-25-111530.txt" {
		t.Errorf("name %s", filepath.Base(first))
	}
	b, _ := os.ReadFile(first)
	if string(b) != "Gate B14\nBoarding 15:40\n" {
		t.Errorf("content %q", b)
	}
	second, err := writeScan(dir, "more", now)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(second) != "scan-2026-09-25-111530 (2).txt" {
		t.Errorf("second scan in the same second: %s", filepath.Base(second))
	}
}

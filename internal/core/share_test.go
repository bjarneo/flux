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
	}
	for kind, want := range cases {
		if got := destDir(cfg, kind); got != want {
			t.Errorf("kind %d: got %s, want %s", kind, got, want)
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

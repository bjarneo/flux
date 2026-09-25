package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

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

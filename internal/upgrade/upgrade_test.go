package upgrade

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// fakeBinary writes a script at path that prints out for -version, and
// returns a Binary that runs the first file at path. The test keeps the
// first file open, as the running fluxd keeps its binary. Otherwise the
// file system can give its inode to a later install, and the watcher then
// sees no change.
func fakeBinary(t *testing.T, path, out string) *Binary {
	t.Helper()
	install(t, path, out)
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	var st unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &st); err != nil {
		t.Fatal(err)
	}
	return &Binary{Path: path, dev: uint64(st.Dev), ino: st.Ino}
}

// install replaces path with a new file, as a package manager does.
func install(t *testing.T, path, out string) {
	t.Helper()
	tmp := path + ".new"
	if err := os.WriteFile(tmp, []byte("#!/bin/sh\necho '"+out+"'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

type result struct {
	mu    sync.Mutex
	found []string
	// logs gets each log line of the watcher.
	logs chan string
}

func (r *result) add(v string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.found = append(r.found, v)
}

func (r *result) get() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.found...)
}

func watch(t *testing.T, b *Binary, ready func() bool) (*result, chan string, context.CancelFunc) {
	t.Helper()
	r := &result{logs: make(chan string, 16)}
	logf := func(format string, args ...any) {
		line := fmt.Sprintf(format, args...)
		t.Log(line)
		select {
		case r.logs <- line:
		default:
		}
	}
	w := &Watcher{Binary: b, Interval: 10 * time.Millisecond, Found: r.add, Ready: ready, Logf: logf}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan string, 1)
	go func() { done <- w.Run(ctx) }()
	return r, done, cancel
}

func TestNewBinaryEndsTheWatch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fluxd")
	b := fakeBinary(t, path, "fluxd v1.0.0")
	var ready atomic.Bool
	r, done, cancel := watch(t, b, ready.Load)
	defer cancel()

	time.Sleep(50 * time.Millisecond)
	if got := r.get(); len(got) != 0 {
		t.Fatalf("found %v before an install", got)
	}
	install(t, path, "fluxd v1.1.0")
	deadline := time.Now().Add(5 * time.Second)
	for len(r.get()) == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := r.get(); len(got) != 1 || got[0] != "v1.1.0" {
		t.Fatalf("found %v, want [v1.1.0]", got)
	}
	select {
	case v := <-done:
		t.Fatalf("the watch ended with %q while the process was busy", v)
	case <-time.After(50 * time.Millisecond):
	}
	ready.Store(true)
	select {
	case v := <-done:
		if v != "v1.1.0" {
			t.Fatalf("the watch returned %q, want v1.1.0", v)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the watch did not end after the process became ready")
	}
}

func TestBrokenBinaryIsIgnored(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fluxd")
	b := fakeBinary(t, path, "fluxd v1.0.0")
	r, done, cancel := watch(t, b, func() bool { return true })
	defer cancel()

	install(t, path, "not fluxd")
	// The watcher logs a file that does not run after it ran the file.
	select {
	case line := <-r.logs:
		if !strings.Contains(line, "does not run") {
			t.Fatalf("log line %q", line)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the watcher did not check the file that is not fluxd")
	}
	if got := r.get(); len(got) != 0 {
		t.Fatalf("found %v for a file that is not fluxd", got)
	}
	install(t, path, "fluxd v2.0.0")
	select {
	case v := <-done:
		if v != "v2.0.0" {
			t.Fatalf("the watch returned %q, want v2.0.0", v)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the watch did not find the complete binary")
	}
}

func TestWaitForPackageManager(t *testing.T) {
	var busy atomic.Bool
	busy.Store(true)
	old := packageManagerBusy
	packageManagerBusy = busy.Load
	defer func() { packageManagerBusy = old }()

	path := filepath.Join(t.TempDir(), "fluxd")
	b := fakeBinary(t, path, "fluxd v1.0.0")
	r, done, cancel := watch(t, b, func() bool { return true })
	defer cancel()

	install(t, path, "fluxd v1.1.0")
	time.Sleep(100 * time.Millisecond)
	if got := r.get(); len(got) != 0 {
		t.Fatalf("found %v during a pacman transaction", got)
	}
	busy.Store(false)
	select {
	case v := <-done:
		if v != "v1.1.0" {
			t.Fatalf("the watch returned %q, want v1.1.0", v)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the watch did not end after the transaction")
	}
}

func TestSelfIsThisProcess(t *testing.T) {
	b, err := Self()
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(b.Path) {
		t.Fatalf("Path %q is not absolute", b.Path)
	}
	if key, ok := b.changed(); ok {
		t.Fatalf("the test binary counts as replaced: %s", key)
	}
}

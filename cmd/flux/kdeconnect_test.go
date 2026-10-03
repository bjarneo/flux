package main

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"syscall"
	"testing"

	"flux/internal/desktop"
)

func kdeConnectIn(t *testing.T, pids ...int) (kdeConnect, *[]int) {
	t.Helper()
	dir := t.TempDir()
	var stopped []int
	return kdeConnect{
		files:     desktop.KDEConnectOverrides(dir+"/config", dir+"/data"),
		pids:      pids,
		installed: true,
		stop: func(pid int) error {
			stopped = append(stopped, pid)
			return nil
		},
	}, &stopped
}

// setup writes both files before it stops kdeconnectd, so D-Bus cannot
// start it again in between.
func TestSetupKDEConnectWritesTheFilesAndStopsTheDaemon(t *testing.T) {
	k, stopped := kdeConnectIn(t, 41, 42)
	k.stop = func(pid int) error {
		for _, f := range k.files {
			if _, err := os.Stat(f.Path); err != nil {
				t.Errorf("stopped %d before %s existed", pid, f.Path)
			}
		}
		*stopped = append(*stopped, pid)
		return nil
	}
	if err := setupKDEConnect(k, false); err != nil {
		t.Fatal(err)
	}
	for _, f := range k.files {
		b, err := os.ReadFile(f.Path)
		if err != nil || string(b) != f.Content {
			t.Errorf("%s: %q %v", f.Path, b, err)
		}
	}
	if !slices.Equal(*stopped, []int{41, 42}) {
		t.Errorf("stopped: %v", *stopped)
	}
}

func TestSetupKDEConnectDryRunChangesNothing(t *testing.T) {
	k, stopped := kdeConnectIn(t, 41)
	if err := setupKDEConnect(k, true); err != nil {
		t.Fatal(err)
	}
	for _, f := range k.files {
		if _, err := os.Stat(f.Path); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("dry run wrote %s", f.Path)
		}
	}
	if len(*stopped) != 0 {
		t.Errorf("dry run stopped %v", *stopped)
	}
}

// A file that the user wrote stays as it is.
func TestSetupKDEConnectKeepsAFileOfTheUser(t *testing.T) {
	k, _ := kdeConnectIn(t)
	own := k.files[0]
	if err := os.MkdirAll(filepath.Dir(own.Path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(own.Path, []byte("[Desktop Entry]\nExec=kdeconnectd --my-flag\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := setupKDEConnect(k, false); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(own.Path); string(b) != "[Desktop Entry]\nExec=kdeconnectd --my-flag\n" {
		t.Errorf("setup changed the file of the user: %q", b)
	}
	if b, _ := os.ReadFile(k.files[1].Path); string(b) != k.files[1].Content {
		t.Errorf("setup skipped the other file: %q", b)
	}
}

func TestSetupKDEConnectWithoutKDEConnectWritesNothing(t *testing.T) {
	k, _ := kdeConnectIn(t)
	k.installed = false
	if err := setupKDEConnect(k, false); err != nil {
		t.Fatal(err)
	}
	for _, f := range k.files {
		if _, err := os.Stat(f.Path); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("wrote %s without KDE Connect", f.Path)
		}
	}
}

// A kdeconnectd of another user, or one that stopped by itself, is not a
// failure of setup.
func TestSetupKDEConnectToleratesADaemonItCannotStop(t *testing.T) {
	k, _ := kdeConnectIn(t, 41, 42)
	k.stop = func(pid int) error {
		if pid == 41 {
			return syscall.EPERM
		}
		return syscall.ESRCH
	}
	if err := setupKDEConnect(k, false); err != nil {
		t.Fatal(err)
	}
	k.stop = func(int) error { return syscall.EINVAL }
	if err := setupKDEConnect(k, false); err == nil {
		t.Fatal("another error must fail the step")
	}
}

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"flux/internal/config"
	"flux/internal/desktop"
)

// kdeConnect is what setup needs to turn KDE Connect off. Tests give
// their own.
type kdeConnect struct {
	files     []desktop.File
	pids      []int
	installed bool
	stop      func(pid int) error
}

func systemKDEConnect() kdeConnect {
	_, lookErr := exec.LookPath("kdeconnectd")
	_, statErr := os.Stat("/usr/share/dbus-1/services/org.kde.kdeconnect.service")
	return kdeConnect{
		files:     desktop.KDEConnectOverrides(filepath.Dir(config.ConfigDir()), filepath.Dir(config.DataDir())),
		pids:      desktop.KDEConnectPIDs(desktop.SystemProcs{}),
		installed: lookErr == nil || statErr == nil,
		stop:      func(pid int) error { return syscall.Kill(pid, syscall.SIGTERM) },
	}
}

// setupKDEConnect keeps kdeconnectd off, because it uses UDP port 1716
// like fluxd. It writes the files first and then stops kdeconnectd, so
// D-Bus cannot start it again in between. It leaves a file that the user
// wrote as it is.
func setupKDEConnect(k kdeConnect, dry bool) error {
	if !k.installed && len(k.pids) == 0 {
		fmt.Println("  - KDE Connect is not installed")
		return nil
	}
	for _, f := range k.files {
		old, err := os.ReadFile(f.Path)
		switch {
		case err == nil && string(old) == f.Content:
		case err == nil:
			fmt.Printf("  - %s exists, so setup leaves it as it is\n", f.Path)
		case !errors.Is(err, fs.ErrNotExist):
			return err
		case dry:
			fmt.Println("  would write:", f.Path)
		default:
			if err := os.MkdirAll(filepath.Dir(f.Path), 0o755); err != nil {
				return err
			}
			if err := os.WriteFile(f.Path, []byte(f.Content), 0o644); err != nil {
				return err
			}
			fmt.Println("  ✓ wrote", f.Path)
		}
	}
	for _, pid := range k.pids {
		if dry {
			fmt.Printf("  would stop kdeconnectd (PID %d)\n", pid)
			continue
		}
		switch err := k.stop(pid); {
		case err == nil:
			fmt.Printf("  ✓ stopped kdeconnectd (PID %d)\n", pid)
		case errors.Is(err, syscall.ESRCH):
		case errors.Is(err, syscall.EPERM):
			fmt.Printf("  - kdeconnectd of another user runs (PID %d). That user can run: flux-cli setup\n", pid)
		default:
			return fmt.Errorf("stop kdeconnectd (PID %d): %w", pid, err)
		}
	}
	if !dry {
		paths := make([]string, len(k.files))
		for i, f := range k.files {
			paths[i] = f.Path
		}
		fmt.Println("  ✓ KDE Connect stays off. To turn it on again, remove:", strings.Join(paths, " "))
	}
	return nil
}

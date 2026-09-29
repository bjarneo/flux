// Package upgrade finds a new fluxd binary that replaces the running one,
// so that fluxd can restart into the new version after an update.
package upgrade

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// Binary is the file that started this process.
type Binary struct {
	// Path is the file that the next start runs.
	Path string
	dev  uint64
	ino  uint64
}

// Self returns the binary of this process. Path is argv[0] when it is
// absolute, as systemd gives it, so that a link such as
// ~/.local/bin/fluxd stays the path to watch. Else Path is the resolved
// executable.
func Self() (*Binary, error) {
	path := os.Args[0]
	if !filepath.IsAbs(path) {
		exe, err := os.Executable()
		if err != nil {
			return nil, err
		}
		path = exe
	}
	// /proc/self/exe is the file that runs, also after a new file
	// replaced it on disk.
	var st unix.Stat_t
	if err := unix.Stat("/proc/self/exe", &st); err != nil {
		return nil, err
	}
	return &Binary{Path: path, dev: uint64(st.Dev), ino: st.Ino}, nil
}

// changed returns a key of the file at Path when it is not the file that
// runs. The key changes while an install writes the file. A package
// manager, install(1), and go build write a new file, so a new binary
// always has a new inode.
func (b *Binary) changed() (string, bool) {
	var st unix.Stat_t
	if err := unix.Stat(b.Path, &st); err != nil {
		return "", false
	}
	if uint64(st.Dev) == b.dev && st.Ino == b.ino {
		return "", false
	}
	return fmt.Sprintf("%d:%d:%d:%d", st.Dev, st.Ino, st.Size, st.Mtim.Nano()), true
}

// version runs the file at Path with -version and returns the version
// that it prints. An error means that the file is not a complete fluxd.
func (b *Binary) version(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, b.Path, "-version").Output()
	if err != nil {
		return "", err
	}
	f := strings.Fields(string(out))
	if len(f) != 2 || f[0] != "fluxd" {
		return "", fmt.Errorf("%s -version printed %q", b.Path, strings.TrimSpace(string(out)))
	}
	return f[1], nil
}

// packageManagerBusy reports whether pacman runs a transaction. A restart
// waits for its end, so that the new fluxd finds all the new files.
var packageManagerBusy = func() bool {
	_, err := os.Stat("/var/lib/pacman/db.lck")
	return err == nil
}

// Watcher checks the binary at an interval.
type Watcher struct {
	Binary   *Binary
	Interval time.Duration
	// Found gets the version of a new binary. The file did not change for
	// 1 interval, and it runs. Found gets a call again when a later
	// install replaces the new binary.
	Found func(version string)
	// Ready reports whether the process can stop now.
	Ready func() bool
	Logf  func(format string, args ...any)
}

// Run returns the version of the new binary when Ready returns true. It
// returns "" when ctx ends.
func (w *Watcher) Run(ctx context.Context) string {
	tick := time.NewTicker(w.Interval)
	defer tick.Stop()
	var last, found, failed, version string
	for {
		select {
		case <-ctx.Done():
			return ""
		case <-tick.C:
		}
		key, ok := w.Binary.changed()
		if !ok {
			last = ""
			continue
		}
		if key != last {
			last = key
			continue
		}
		if packageManagerBusy() {
			continue
		}
		if key != found {
			v, err := w.Binary.version(ctx)
			if err != nil {
				if key != failed {
					w.Logf("the new %s does not run: %v", w.Binary.Path, err)
					failed = key
				}
				continue
			}
			found, version = key, v
			w.Found(v)
		}
		if w.Ready() {
			return version
		}
	}
}

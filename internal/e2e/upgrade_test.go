package e2e

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

type versionState struct {
	Self struct {
		Version        string `json:"version"`
		PendingVersion string `json:"pendingVersion"`
	} `json:"self"`
}

func buildVersion(t *testing.T, path, version string) {
	t.Helper()
	out, err := exec.Command("go", "build", "-ldflags", "-X main.version="+version, "-o", path, "flux/cmd/fluxd").CombinedOutput()
	if err != nil {
		t.Fatalf("build fluxd %s: %v\n%s", version, err, out)
	}
}

// replace puts a new file at path, as a package manager does.
func replace(t *testing.T, src, path string) {
	t.Helper()
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path+".new", data, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(path+".new", path); err != nil {
		t.Fatal(err)
	}
}

func (n *node) versions(t *testing.T) versionState {
	t.Helper()
	var s versionState
	n.call(t, "state", nil, &s)
	return s
}

// TestNewBinary replaces the binary of a running fluxd, as an update does.
// A fluxd that the user started reports the new version and keeps
// running. A fluxd of systemd stops with code 75, so that systemd starts
// the new binary.
func TestNewBinary(t *testing.T) {
	if testing.Short() {
		t.Skip("builds fluxd 2 times")
	}
	dir := t.TempDir()
	oldBin, newBin := filepath.Join(dir, "old"), filepath.Join(dir, "new")
	buildVersion(t, oldBin, "v1.0.0")
	buildVersion(t, newBin, "v1.1.0")

	for _, service := range []bool{false, true} {
		name := "by-hand"
		env := []string{"FLUX_BINARY_POLL=100ms", "INVOCATION_ID=", "SYSTEMD_EXEC_PID="}
		if service {
			name = "service"
			env[1] = "INVOCATION_ID=e2e"
		}
		t.Run(name, func(t *testing.T) {
			bin := filepath.Join(t.TempDir(), "fluxd")
			replace(t, oldBin, bin)
			n := newNode(t, name)
			n.env = env
			n.udpPort = freePort(t, "udp")
			n.launch(t, bin, freePort(t, "tcp"))

			if s := n.versions(t); s.Self.Version != "v1.0.0" || s.Self.PendingVersion != "" {
				t.Fatalf("before the update: version %q, pending %q", s.Self.Version, s.Self.PendingVersion)
			}
			// A fluxd of systemd tells post-install.sh that it restarts
			// by itself.
			marker := filepath.Join(n.dir, "run", "flux", "self-restart")
			if _, err := os.Stat(marker); (err == nil) != service {
				t.Fatalf("the self-restart marker: %v", err)
			}
			replace(t, newBin, bin)

			if !service {
				deadline := time.Now().Add(10 * time.Second)
				for n.versions(t).Self.PendingVersion != "v1.1.0" {
					if time.Now().After(deadline) {
						t.Fatalf("no pending version\n%s", n.log)
					}
					time.Sleep(100 * time.Millisecond)
				}
				time.Sleep(500 * time.Millisecond)
				if s := n.versions(t); s.Self.Version != "v1.0.0" {
					t.Fatalf("the running version changed to %q", s.Self.Version)
				}
				return
			}

			done := make(chan error, 1)
			go func() { done <- n.cmd.Wait() }()
			select {
			case err := <-done:
				n.cmd = nil
				var exit *exec.ExitError
				if !errors.As(err, &exit) || exit.ExitCode() != 75 {
					t.Fatalf("fluxd ended with %v, want exit code 75\n%s", err, n.log)
				}
				if _, err := os.Stat(marker); !os.IsNotExist(err) {
					t.Fatalf("the marker stays after the exit: %v", err)
				}
			case <-time.After(10 * time.Second):
				t.Fatalf("fluxd did not stop after the update\n%s", n.log)
			}
		})
	}
}

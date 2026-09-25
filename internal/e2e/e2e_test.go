// Package e2e runs 2 headless fluxd processes that discover each other on
// loopback, pair, and exchange data through the public IPC API.
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/ipc"
)

type node struct {
	name    string
	dir     string
	cmd     *exec.Cmd
	client  *ipc.Client
	log     *syncBuffer
	udpPort int
}

// syncBuffer collects the process output. The test reads it while the
// process writes it.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

type state struct {
	Devices []struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		Online    bool   `json:"online"`
		Paired    bool   `json:"paired"`
		PairState string `json:"pairState"`
		PairKey   string `json:"pairKey"`
	} `json:"devices"`
	Clipboard []struct {
		Text string `json:"text"`
		Dir  string `json:"dir"`
	} `json:"clipboard"`
	Transfers []struct {
		Name  string `json:"name"`
		Dir   string `json:"dir"`
		State string `json:"state"`
		Error string `json:"error"`
	} `json:"transfers"`
	Ringing bool `json:"ringing"`
}

func buildFluxd(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "fluxd")
	out, err := exec.Command("go", "build", "-o", bin, "flux/cmd/fluxd").CombinedOutput()
	if err != nil {
		t.Fatalf("build fluxd: %v\n%s", err, out)
	}
	return bin
}

// freePort returns a port that is free for the network now.
func freePort(t *testing.T, network string) int {
	t.Helper()
	if network == "udp" {
		c, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		return c.LocalAddr().(*net.UDPAddr).Port
	}
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func start(t *testing.T, bin, name string, udpPort, tcpPort int) *node {
	t.Helper()
	dir := t.TempDir()
	n := &node{name: name, dir: dir, log: &syncBuffer{}}
	cfgDir := filepath.Join(dir, "config", "flux")
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := fmt.Sprintf("name = %q\ndownload_dir = %q\nauto_clipboard = true\nnotifications = false\n",
		name, filepath.Join(dir, "downloads"))
	if err := os.WriteFile(filepath.Join(cfgDir, "config.toml"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
	n.udpPort = udpPort
	n.launch(t, bin, tcpPort)
	return n
}

func (n *node) launch(t *testing.T, bin string, tcpPort int) {
	t.Helper()
	sock := filepath.Join(n.dir, "fluxd.sock")
	n.cmd = exec.Command(bin, "-headless", "-udp-port", fmt.Sprint(n.udpPort), "-tcp-port", fmt.Sprint(tcpPort))
	n.cmd.Env = append(os.Environ(),
		"XDG_CONFIG_HOME="+filepath.Join(n.dir, "config"),
		"XDG_DATA_HOME="+filepath.Join(n.dir, "data"),
		"XDG_CACHE_HOME="+filepath.Join(n.dir, "cache"),
		"FLUX_SOCKET="+sock,
	)
	n.cmd.Stdout, n.cmd.Stderr = n.log, n.log
	if err := n.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(n.stop)
	deadline := time.Now().Add(5 * time.Second)
	for {
		c, err := ipc.Dial(sock)
		if err == nil {
			n.client = c
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s did not open its socket: %v\n%s", n.name, err, n.log)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (n *node) stop() {
	if n.client != nil {
		n.client.Close()
		n.client = nil
	}
	if n.cmd != nil && n.cmd.Process != nil {
		_ = n.cmd.Process.Signal(os.Interrupt)
		done := make(chan struct{})
		go func() { _ = n.cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = n.cmd.Process.Kill()
		}
		n.cmd = nil
	}
}

func (n *node) call(t *testing.T, method string, params any, result any) {
	t.Helper()
	if err := n.client.Call(method, params, result); err != nil {
		t.Fatalf("%s %s: %v\n%s", n.name, method, err, n.log)
	}
}

func (n *node) state(t *testing.T) state {
	t.Helper()
	var s state
	n.call(t, "state", nil, &s)
	return s
}

// wait polls the state until ok returns true.
func (n *node) wait(t *testing.T, what string, ok func(state) bool) state {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		s := n.state(t)
		if ok(s) {
			return s
		}
		if time.Now().After(deadline) {
			b, _ := json.MarshalIndent(s, "", "  ")
			t.Fatalf("%s: timed out waiting for %s\nstate: %s\nlog:\n%s", n.name, what, b, n.log)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func device(s state, name string) (id string, online, paired bool, pairState, key string) {
	for _, d := range s.Devices {
		if d.Name == name {
			return d.ID, d.Online, d.Paired, d.PairState, d.PairKey
		}
	}
	return "", false, false, "", ""
}

func TestTwoDaemons(t *testing.T) {
	if testing.Short() {
		t.Skip("starts 2 processes")
	}
	bin := buildFluxd(t)
	udp := freePort(t, "udp")
	tcpA, tcpB := freePort(t, "tcp"), freePort(t, "tcp")
	alpha := start(t, bin, "alpha", udp, tcpA)
	beta := start(t, bin, "beta", udp, tcpB)
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("alpha log:\n%s\nbeta log:\n%s", alpha.log, beta.log)
		}
	})

	// Discovery: each daemon broadcasts on start, so they find each other.
	alpha.wait(t, "beta online", func(s state) bool { _, on, _, _, _ := device(s, "beta"); return on })
	beta.wait(t, "alpha online", func(s state) bool { _, on, _, _, _ := device(s, "alpha"); return on })

	// Pairing: both sides must show the same verification key.
	alpha.call(t, "pair.request", map[string]any{"device": "beta"}, nil)
	sa := alpha.wait(t, "request state", func(s state) bool { _, _, _, ps, _ := device(s, "beta"); return ps == "requested" })
	sb := beta.wait(t, "incoming request", func(s state) bool { _, _, _, ps, _ := device(s, "alpha"); return ps == "incoming" })
	_, _, _, _, keyA := device(sa, "beta")
	_, _, _, _, keyB := device(sb, "alpha")
	if keyA == "" || keyA != keyB {
		t.Fatalf("verification keys differ: %q and %q", keyA, keyB)
	}
	beta.call(t, "pair.accept", map[string]any{"device": "alpha"}, nil)
	alpha.wait(t, "paired", func(s state) bool { _, _, p, _, _ := device(s, "beta"); return p })
	beta.wait(t, "paired", func(s state) bool { _, _, p, _, _ := device(s, "alpha"); return p })

	// Clipboard.
	alpha.call(t, "clipboard.send", map[string]any{"device": "beta", "text": "yay -S flux-git"}, nil)
	beta.wait(t, "clipboard entry", func(s state) bool {
		return len(s.Clipboard) > 0 && s.Clipboard[0].Text == "yay -S flux-git" && s.Clipboard[0].Dir == "in"
	})

	// File transfer.
	src := filepath.Join(t.TempDir(), "IMG_2041.jpg")
	data := bytes.Repeat([]byte("flux"), 300_000)
	if err := os.WriteFile(src, data, 0o644); err != nil {
		t.Fatal(err)
	}
	alpha.call(t, "share.files", map[string]any{"device": "beta", "paths": []string{src}}, nil)
	beta.wait(t, "received file", func(s state) bool {
		return len(s.Transfers) > 0 && s.Transfers[0].State == "done"
	})
	got, err := os.ReadFile(filepath.Join(beta.dir, "downloads", "IMG_2041.jpg"))
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("received file differs: %v, %d bytes", err, len(got))
	}
	alpha.wait(t, "sent file", func(s state) bool { return len(s.Transfers) > 0 && s.Transfers[0].State == "done" })

	// Find my device.
	alpha.call(t, "ring", map[string]any{"device": "beta"}, nil)
	beta.wait(t, "ringing", func(s state) bool { return s.Ringing })
	beta.call(t, "ring.stop", nil, nil)
	beta.wait(t, "ring stopped", func(s state) bool { return !s.Ringing })

	// The trust survives a restart of both daemons.
	alpha.stop()
	beta.stop()
	alpha.launch(t, bin, tcpA)
	beta.launch(t, bin, tcpB)
	alpha.wait(t, "paired beta online after restart", func(s state) bool {
		_, on, p, _, _ := device(s, "beta")
		return on && p
	})

	// Unpair.
	alpha.call(t, "pair.unpair", map[string]any{"device": "beta"}, nil)
	beta.wait(t, "unpaired", func(s state) bool { _, _, p, _, _ := device(s, "alpha"); return !p })
	if strings.Contains(alpha.log.String(), "panic") || strings.Contains(beta.log.String(), "panic") {
		t.Fatalf("a daemon panicked:\n%s\n%s", alpha.log, beta.log)
	}
}

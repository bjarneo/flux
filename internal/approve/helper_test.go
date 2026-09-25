package approve

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeFluxd plays fluxd and the phone on a temporary socket. answer gets
// each approve.request and returns the result of approve.wait.
type fakeFluxd struct {
	path     string
	mu       sync.Mutex
	requests []map[string]any
	answer   func(params map[string]any) (state map[string]any, rpcErr map[string]any)
	// startErr, when set, is the error of approve.request.
	startErr map[string]any
	timeout  int
}

func newFakeFluxd(t *testing.T) *fakeFluxd {
	t.Helper()
	// Unix socket paths have a limit of 107 bytes, so the socket goes in a
	// short folder.
	base := os.Getenv("XDG_RUNTIME_DIR")
	if base == "" {
		base = os.TempDir()
	}
	dir, err := os.MkdirTemp(base, "fa")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	f := &fakeFluxd{path: filepath.Join(dir, "s"), timeout: 20}
	ln, err := net.Listen("unix", f.path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(c)
		}
	}()
	return f
}

func (f *fakeFluxd) serve(c net.Conn) {
	defer c.Close()
	s := bufio.NewScanner(c)
	var last map[string]any
	for s.Scan() {
		var req struct {
			ID     int64          `json:"id"`
			Method string         `json:"method"`
			Params map[string]any `json:"params"`
		}
		if json.Unmarshal(s.Bytes(), &req) != nil {
			return
		}
		reply := map[string]any{"id": req.ID}
		switch req.Method {
		case "approve.request", "approve.enroll":
			f.mu.Lock()
			f.requests = append(f.requests, req.Params)
			f.mu.Unlock()
			last = req.Params
			if f.startErr != nil {
				reply["error"] = f.startErr
			} else {
				reply["result"] = map[string]any{"id": "req1", "timeout": f.timeout, "device": "3f8e2a1c9b7d4e6fa0c5b8d2e1f47a93", "name": "Pixel 8"}
			}
		case "approve.wait":
			res, rpcErr := f.answer(last)
			if res == nil && rpcErr == nil {
				// No answer: the phone does not react.
				continue
			}
			if rpcErr != nil {
				reply["error"] = rpcErr
			} else {
				reply["result"] = res
			}
		default:
			reply["error"] = map[string]any{"code": "unknown", "message": "unknown method"}
		}
		b, _ := json.Marshal(reply)
		c.Write(append(b, '\n'))
	}
}

// requestFrom rebuilds the request that the helper sent.
func requestFrom(p map[string]any) Request {
	s := func(k string) string { v, _ := p[k].(string); return v }
	tm, _ := p["time"].(float64)
	return Request{Host: s("host"), User: s("user"), Service: s("service"), TTY: s("tty"), RHost: s("rhost"), Time: int64(tm), Nonce: s("nonce")}
}

func helperOptions(t *testing.T, keyPath, socket string, out *bytes.Buffer) Options {
	return Options{
		User: "alice", Service: "sudo", TTY: "/dev/pts/3", Host: "omarchy-xps",
		KeyPath: keyPath, KeyOwner: os.Getuid(),
		Socket: socket, PeerUID: os.Getuid(),
		MaxWait: 6 * time.Second,
		Out:     out,
	}
}

func TestHelperApproves(t *testing.T) {
	ph := newPhone(t)
	key := writeTestKey(t, ph)
	f := newFakeFluxd(t)
	f.answer = func(p map[string]any) (map[string]any, map[string]any) {
		sig := ph.signRequest(t, requestFrom(p))
		return map[string]any{"state": "approved", "signature": base64.StdEncoding.EncodeToString(sig)}, nil
	}
	var out bytes.Buffer
	if err := Run(context.Background(), helperOptions(t, key, f.path, &out)); err != nil {
		t.Fatalf("a valid approval: %v", err)
	}
	if out.String() != "Approve on Pixel 8, or wait for the password prompt.\n" {
		t.Fatalf("output %q", out.String())
	}
	p := f.requests[0]
	if p["device"] != "3f8e2a1c9b7d4e6fa0c5b8d2e1f47a93" || p["service"] != "sudo" || p["user"] != "alice" || len(p["nonce"].(string)) != 64 {
		t.Fatalf("request %v", p)
	}
}

func TestHelperRefusesAWrongKey(t *testing.T) {
	key := writeTestKey(t, newPhone(t))
	attacker := newPhone(t)
	f := newFakeFluxd(t)
	f.answer = func(p map[string]any) (map[string]any, map[string]any) {
		sig := attacker.signRequest(t, requestFrom(p))
		return map[string]any{"state": "approved", "signature": base64.StdEncoding.EncodeToString(sig)}, nil
	}
	err := Run(context.Background(), helperOptions(t, key, f.path, &bytes.Buffer{}))
	if !errors.Is(err, ErrBadSignature) {
		t.Fatalf("got %v", err)
	}
}

// fluxd cannot change a field of the request: the helper checks the
// signature over the request that it made itself.
func TestHelperRefusesAChangedField(t *testing.T) {
	ph := newPhone(t)
	key := writeTestKey(t, ph)
	f := newFakeFluxd(t)
	f.answer = func(p map[string]any) (map[string]any, map[string]any) {
		r := requestFrom(p)
		r.Service = "login"
		sig := ph.signRequest(t, r)
		return map[string]any{"state": "approved", "signature": base64.StdEncoding.EncodeToString(sig)}, nil
	}
	if err := Run(context.Background(), helperOptions(t, key, f.path, &bytes.Buffer{})); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("got %v", err)
	}
}

// A signature from an earlier approval is not valid for a new one.
func TestHelperRefusesAReplay(t *testing.T) {
	ph := newPhone(t)
	key := writeTestKey(t, ph)
	f := newFakeFluxd(t)
	var saved string
	f.answer = func(p map[string]any) (map[string]any, map[string]any) {
		if saved == "" {
			saved = base64.StdEncoding.EncodeToString(ph.signRequest(t, requestFrom(p)))
		}
		return map[string]any{"state": "approved", "signature": saved}, nil
	}
	if err := Run(context.Background(), helperOptions(t, key, f.path, &bytes.Buffer{})); err != nil {
		t.Fatalf("the first approval: %v", err)
	}
	if err := Run(context.Background(), helperOptions(t, key, f.path, &bytes.Buffer{})); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("a replayed signature: %v", err)
	}
}

func TestHelperDenied(t *testing.T) {
	key := writeTestKey(t, newPhone(t))
	f := newFakeFluxd(t)
	f.answer = func(map[string]any) (map[string]any, map[string]any) {
		return map[string]any{"state": "denied"}, nil
	}
	if err := Run(context.Background(), helperOptions(t, key, f.path, &bytes.Buffer{})); !errors.Is(err, ErrDenied) {
		t.Fatalf("got %v", err)
	}
}

func TestHelperTimesOut(t *testing.T) {
	key := writeTestKey(t, newPhone(t))
	f := newFakeFluxd(t)
	// The phone does not answer. The deadline of the context ends the wait.
	f.answer = func(map[string]any) (map[string]any, map[string]any) { return nil, nil }
	o := helperOptions(t, key, f.path, &bytes.Buffer{})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	start := time.Now()
	err := Run(ctx, o)
	if !errors.Is(err, ErrTimeout) {
		t.Fatalf("got %v", err)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("the helper waited %v", d)
	}
}

func TestHelperTimeoutFromFluxd(t *testing.T) {
	key := writeTestKey(t, newPhone(t))
	f := newFakeFluxd(t)
	f.answer = func(map[string]any) (map[string]any, map[string]any) {
		return nil, map[string]any{"code": "timeout", "message": "the phone did not answer"}
	}
	if err := Run(context.Background(), helperOptions(t, key, f.path, &bytes.Buffer{})); !errors.Is(err, ErrTimeout) {
		t.Fatalf("got %v", err)
	}
}

func TestHelperStopsAtOnce(t *testing.T) {
	ph := newPhone(t)
	key := writeTestKey(t, ph)

	// No key file: the helper does not connect.
	var out bytes.Buffer
	o := helperOptions(t, filepath.Join(t.TempDir(), "none.pub"), "/nonexistent/socket", &out)
	if err := Run(context.Background(), o); !errors.Is(err, ErrNoKey) {
		t.Fatalf("no key: %v", err)
	}

	// No fluxd.
	start := time.Now()
	o = helperOptions(t, key, filepath.Join(t.TempDir(), "s"), &out)
	if err := Run(context.Background(), o); err == nil {
		t.Fatal("no fluxd: want an error")
	}

	// The phone is not connected.
	f := newFakeFluxd(t)
	f.startErr = map[string]any{"code": "offline", "message": "Pixel 8 is offline"}
	o = helperOptions(t, key, f.path, &out)
	if err := Run(context.Background(), o); err == nil || !strings.Contains(err.Error(), "offline") {
		t.Fatalf("offline: %v", err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatalf("the helper did not stop at once: %v", time.Since(start))
	}
	if out.Len() != 0 {
		t.Fatalf("the helper printed %q", out.String())
	}
}

func TestHelperChecksThePeer(t *testing.T) {
	key := writeTestKey(t, newPhone(t))
	f := newFakeFluxd(t)
	f.answer = func(map[string]any) (map[string]any, map[string]any) { return map[string]any{"state": "denied"}, nil }
	o := helperOptions(t, key, f.path, &bytes.Buffer{})
	o.PeerUID = os.Getuid() + 1
	err := Run(context.Background(), o)
	if err == nil || !strings.Contains(err.Error(), "belongs to user") {
		t.Fatalf("got %v", err)
	}
	if len(f.requests) != 0 {
		t.Fatal("the helper sent a request to a server of another user")
	}
}

func TestHelperRefusesServicesAndUsers(t *testing.T) {
	key := writeTestKey(t, newPhone(t))
	o := helperOptions(t, key, "/nonexistent", &bytes.Buffer{})
	o.Service = "sshd"
	if err := Run(context.Background(), o); !errors.Is(err, ErrService) {
		t.Fatalf("sshd: %v", err)
	}
	for _, u := range []string{"", "../root", "Alice", "a/b", strings.Repeat("a", 40)} {
		o := helperOptions(t, key, "/nonexistent", &bytes.Buffer{})
		o.User = u
		if err := Run(context.Background(), o); err == nil {
			t.Errorf("user %q: want an error", u)
		}
	}
}

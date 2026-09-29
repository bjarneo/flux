package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/ipc"
	"flux/internal/nativemsg"
)

// seen is one request that the fake daemon received.
type seen struct {
	Method string
	Params map[string]any
}

// fakeDaemon answers like fluxd, over the real IPC socket, so that the
// test covers the framing and the socket and not only the host logic.
type fakeDaemon struct {
	mu    sync.Mutex
	calls []seen
	// fails holds the error for a method, as fluxd would send it.
	fails map[string]*ipc.Error
}

func (d *fakeDaemon) Call(ctx context.Context, method string, raw json.RawMessage) (any, error) {
	var p map[string]any
	json.Unmarshal(raw, &p)
	d.mu.Lock()
	d.calls = append(d.calls, seen{Method: method, Params: p})
	err := d.fails[method]
	d.mu.Unlock()
	if err != nil {
		return nil, err
	}
	switch method {
	case "state":
		return map[string]any{"devices": []map[string]any{
			{"id": "a1", "name": "Pixel 11 Pro", "paired": true, "online": true},
			{"id": "b2", "name": "Old Phone", "paired": true, "online": false},
			{"id": "c3", "name": "Guest", "paired": false, "online": true},
		}}, nil
	case "share.url", "share.text":
		return map[string]any{}, nil
	}
	return nil, &ipc.Error{Code: "unknown_method", Message: "Unknown method " + method}
}

func (d *fakeDaemon) Subscribe(send func(event string, data any)) func() { return func() {} }

func (d *fakeDaemon) sent() []seen {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]seen{}, d.calls...)
}

// start runs a fake daemon on a socket for the test and points the host at
// it with FLUX_SOCKET.
func start(t *testing.T) *fakeDaemon {
	t.Helper()
	d := &fakeDaemon{fails: map[string]*ipc.Error{}}
	path := t.TempDir() + "/fluxd.sock"
	ctx, cancel := context.WithCancel(context.Background())
	errs := make(chan error, 1)
	go func() { errs <- ipc.Serve(ctx, path, d) }()
	t.Cleanup(func() {
		cancel()
		if err := <-errs; err != nil {
			t.Errorf("the fake daemon: %v", err)
		}
	})
	// The host dials the socket as soon as it runs, so wait for the
	// listener instead of racing it.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if c, err := ipc.Dial(path); err == nil {
			c.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the fake daemon did not start")
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Setenv("FLUX_SOCKET", path)
	return d
}

// ask sends one message as the browser does and returns the reply.
func ask(t *testing.T, req any) reply {
	t.Helper()
	var in bytes.Buffer
	if err := nativemsg.Write(&in, req); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := serve(&in, &out); err != nil {
		t.Fatalf("serve: %v", err)
	}
	raw, err := nativemsg.Read(&out)
	if err != nil {
		t.Fatal(err)
	}
	var rep reply
	if err := json.Unmarshal(raw, &rep); err != nil {
		t.Fatalf("reply %s: %v", raw, err)
	}
	return rep
}

func TestDevicesListsPairedPhones(t *testing.T) {
	start(t)
	rep := ask(t, map[string]any{"command": "devices"})
	if !rep.OK {
		t.Fatalf("reply: %+v", rep)
	}
	if len(rep.Devices) != 2 {
		t.Fatalf("got %d devices, want the 2 paired ones: %+v", len(rep.Devices), rep.Devices)
	}
	if rep.Devices[0].Name != "Pixel 11 Pro" || !rep.Devices[0].Online {
		t.Errorf("first device is %+v", rep.Devices[0])
	}
	if rep.Devices[1].Online {
		t.Error("an offline phone shows as online")
	}
}

func TestSendURL(t *testing.T) {
	d := start(t)
	rep := ask(t, map[string]any{"command": "send", "url": "https://omarchy.org"})
	if !rep.OK || rep.Error != nil {
		t.Fatalf("reply: %+v", rep)
	}
	sent := d.sent()
	if len(sent) != 1 || sent[0].Method != "share.url" {
		t.Fatalf("fluxd got %+v", sent)
	}
	if sent[0].Params["url"] != "https://omarchy.org" {
		t.Errorf("url param is %v", sent[0].Params["url"])
	}
}

// TestSendToChosenPhone checks that the device that the extension picked
// reaches fluxd, so that the extension can send to a phone that is not the
// only one.
func TestSendToChosenPhone(t *testing.T) {
	d := start(t)
	rep := ask(t, map[string]any{"command": "send", "device": "Old Phone", "url": "https://omarchy.org"})
	if !rep.OK {
		t.Fatalf("reply: %+v", rep)
	}
	if got := d.sent()[0].Params["device"]; got != "Old Phone" {
		t.Errorf("device param is %v", got)
	}
}

func TestEmptyLinkIsRefused(t *testing.T) {
	d := start(t)
	rep := ask(t, map[string]any{"command": "send", "url": "   "})
	if rep.OK || rep.Error == nil {
		t.Fatalf("reply: %+v", rep)
	}
	if len(d.sent()) != 0 {
		t.Errorf("fluxd got %+v, want nothing", d.sent())
	}
}

// TestLongURLIsRefused checks that a huge link is not cut, because half a
// link is a link that goes nowhere.
func TestLongURLIsRefused(t *testing.T) {
	d := start(t)
	rep := ask(t, map[string]any{"command": "send", "url": "https://omarchy.org/" + strings.Repeat("a", maxURL)})
	if rep.OK || rep.Error == nil {
		t.Fatalf("reply: %+v", rep)
	}
	if len(d.sent()) != 0 {
		t.Errorf("fluxd got %+v, want nothing", d.sent())
	}
}

// TestDaemonErrorKeepsCode checks that a fluxd error arrives with its code,
// so that the extension can tell an offline phone from a missing one.
func TestDaemonErrorKeepsCode(t *testing.T) {
	d := start(t)
	d.fails["share.url"] = &ipc.Error{Code: "offline", Message: "Pixel 11 Pro is offline"}
	rep := ask(t, map[string]any{"command": "send", "url": "https://omarchy.org"})
	if rep.OK || rep.Error == nil {
		t.Fatalf("reply: %+v", rep)
	}
	if rep.Error.Code != "offline" || rep.Error.Message != "Pixel 11 Pro is offline" {
		t.Errorf("error is %+v", rep.Error)
	}
}

// TestBadRequestsKeepTheHostUp checks that the extension can keep using one
// host after a message that Flux cannot use.
func TestBadRequestsKeepTheHostUp(t *testing.T) {
	start(t)
	cases := []struct {
		name string
		req  any
	}{
		{"no command", map[string]any{"url": "https://omarchy.org"}},
		{"unknown command", map[string]any{"command": "paste"}},
		{"empty url", map[string]any{"command": "send", "url": "   "}},
		{"not an object", []string{"devices"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rep := ask(t, c.req)
			if rep.OK || rep.Error == nil || rep.Error.Message == "" {
				t.Errorf("reply: %+v", rep)
			}
		})
	}
}

// TestNoFluxd checks the message that a user sees before fluxd runs.
func TestNoFluxd(t *testing.T) {
	t.Setenv("FLUX_SOCKET", t.TempDir()+"/missing.sock")
	rep := ask(t, map[string]any{"command": "devices"})
	if rep.OK || rep.Error == nil {
		t.Fatalf("reply: %+v", rep)
	}
	if !strings.Contains(rep.Error.Message, "fluxd") {
		t.Errorf("message is %q, want one that names fluxd", rep.Error.Message)
	}
}

// TestBrokenPipe checks that a browser that closes the port mid-message
// ends the host with a reason instead of a panic.
func TestBrokenPipe(t *testing.T) {
	var head [4]byte
	head[0], head[1] = 0x40, 0x00 // 64 bytes promised, 2 bytes given
	in := bytes.NewReader(append(head[:], '{', '}'))
	if err := serve(in, io.Discard); err == nil {
		t.Error("a cut message was accepted")
	}
}

// TestManyMessages checks that the host reads a new message after each
// reply, so that one browser port serves the whole session.
func TestManyMessages(t *testing.T) {
	d := start(t)
	var in bytes.Buffer
	for _, u := range []string{"https://omarchy.org", "https://github.com/bjarneo/flux"} {
		if err := nativemsg.Write(&in, map[string]any{"command": "send", "url": u}); err != nil {
			t.Fatal(err)
		}
	}
	var out bytes.Buffer
	if err := serve(&in, &out); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		raw, err := nativemsg.Read(&out)
		if err != nil {
			t.Fatal(err)
		}
		var rep reply
		json.Unmarshal(raw, &rep)
		if !rep.OK {
			t.Errorf("reply: %s", raw)
		}
	}
	if got := len(d.sent()); got != 2 {
		t.Errorf("fluxd got %d calls, want 2", got)
	}
}

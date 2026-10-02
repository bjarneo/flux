package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"flux/internal/ipc"
)

// recordHandler records each call and answers state with its state.
type recordHandler struct {
	mu    sync.Mutex
	calls []string
	state map[string]any

	// results and errs are the answers of the other methods, by the method
	// name. A method in neither returns an empty object.
	results map[string]any
	errs    map[string]error
}

func (h *recordHandler) Call(_ context.Context, method string, raw json.RawMessage) (any, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls = append(h.calls, method+" "+string(raw))
	if method == "state" {
		return h.state, nil
	}
	if err, ok := h.errs[method]; ok {
		return nil, err
	}
	if res, ok := h.results[method]; ok {
		return res, nil
	}
	return map[string]any{}, nil
}

// serveRecord serves h on a new socket that FLUX_SOCKET names.
func serveRecord(t *testing.T, h *recordHandler) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fluxd.sock")
	t.Setenv("FLUX_SOCKET", path)
	ln, err := ipc.Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go ipc.Serve(ctx, ln, h)
}

// TestStreamStart checks flux-cli webcam start and flux-cli mic start: the
// device flag in each place, the message, and the errors.
func TestStreamStart(t *testing.T) {
	h := &recordHandler{
		results: map[string]any{
			"webcam.start": map[string]any{"device": "p1", "name": "Pixel 8"},
			"mic.start":    map[string]any{"device": "p1", "name": "Pixel 8"},
		},
		errs: map[string]error{},
	}
	serveRecord(t, h)

	cases := []struct {
		kind, device string
		args         []string
		params       string
	}{
		{"webcam", "", []string{"start"}, `{"device":""}`},
		{"webcam", "Pixel 8", []string{"start"}, `{"device":"Pixel 8"}`},
		{"webcam", "", []string{"start", "--device", "Pixel 8"}, `{"device":"Pixel 8"}`},
		{"mic", "", []string{"start", "-d", "p1"}, `{"device":"p1"}`},
		{"mic", "other", []string{"start", "--device=Pixel 8"}, `{"device":"Pixel 8"}`},
	}
	for _, c := range cases {
		h.mu.Lock()
		h.calls = nil
		h.mu.Unlock()
		var out bytes.Buffer
		if err := streamStart(c.kind, c.args, c.device, &out); err != nil {
			t.Fatalf("%s %q: %v", c.kind, c.args, err)
		}
		what := "the webcam"
		if c.kind == "mic" {
			what = "the mic"
		}
		if want := "Asked Pixel 8 to start " + what + ". Confirm on Pixel 8.\n"; out.String() != want {
			t.Errorf("%s %q: printed %q, want %q", c.kind, c.args, out.String(), want)
		}
		h.mu.Lock()
		calls := h.calls
		h.mu.Unlock()
		if want := c.kind + ".start " + c.params; len(calls) != 1 || calls[0] != want {
			t.Errorf("%s %q: calls %q, want %q", c.kind, c.args, calls, want)
		}
	}

	// An unknown argument fails before a call.
	h.mu.Lock()
	h.calls = nil
	h.mu.Unlock()
	if err := streamStart("webcam", []string{"start", "now"}, "", &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "flux-cli webcam start [--device NAME]") {
		t.Fatalf("an unknown argument: %v", err)
	}
	h.mu.Lock()
	if len(h.calls) != 0 {
		t.Fatalf("an unknown argument called %q", h.calls)
	}
	h.errs["mic.start"] = &ipc.Error{Code: "no_device", Message: "No connected device can start the mic from this computer"}
	h.mu.Unlock()

	// An error of fluxd prints nothing and keeps its code.
	var out bytes.Buffer
	err := streamStart("mic", []string{"start"}, "", &out)
	var e *ipc.Error
	if !errors.As(err, &e) || e.Code != "no_device" || out.Len() != 0 {
		t.Fatalf("an error: %v, printed %q", err, out.String())
	}
}

func (h *recordHandler) Subscribe(func(string, any)) func() { return func() {} }

func TestBrowse(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fluxd.sock")
	t.Setenv("FLUX_SOCKET", path)
	ln, err := ipc.Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := &recordHandler{state: map[string]any{"browse": []any{map[string]any{"device": "p1", "name": "Pixel 8", "since": 1790000000}}}}
	go ipc.Serve(ctx, ln, h)

	if err := browse([]string{"stop"}, "Pixel 8"); err != nil {
		t.Fatal(err)
	}
	if err := browse(nil, ""); err != nil {
		t.Fatal(err)
	}
	if err := browse([]string{"start"}, ""); err == nil {
		t.Fatal("an unknown argument must fail")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.calls) != 2 || h.calls[0] != `browse.stop {"device":"Pixel 8"}` || !strings.HasPrefix(h.calls[1], "state ") {
		t.Fatalf("calls %q", h.calls)
	}
}

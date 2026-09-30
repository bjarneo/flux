package main

import (
	"context"
	"encoding/json"
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
}

func (h *recordHandler) Call(_ context.Context, method string, raw json.RawMessage) (any, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.calls = append(h.calls, method+" "+string(raw))
	if method == "state" {
		return h.state, nil
	}
	return map[string]any{}, nil
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

package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// testHandler keeps the send function of the last subscriber.
type testHandler struct {
	mu   sync.Mutex
	send func(event string, data any)
	subs chan struct{}
	gone chan struct{}
}

func (h *testHandler) Call(ctx context.Context, method string, params json.RawMessage) (any, error) {
	return map[string]string{"method": method}, nil
}

func (h *testHandler) Subscribe(send func(event string, data any)) func() {
	h.mu.Lock()
	h.send = send
	h.mu.Unlock()
	h.subs <- struct{}{}
	return func() { close(h.gone) }
}

func serveTest(t *testing.T) (*testHandler, string) {
	dir, err := os.MkdirTemp("", "ipc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, "s")
	h := &testHandler{subs: make(chan struct{}, 1), gone: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go Serve(ctx, path, h)
	for range 100 {
		if _, err := os.Stat(path); err == nil {
			return h, path
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the server did not start")
	return nil, ""
}

func subscribe(t *testing.T, h *testHandler, path string) net.Conn {
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	if _, err := conn.Write([]byte(`{"id":1,"method":"subscribe"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-h.subs:
	case <-time.After(2 * time.Second):
		t.Fatal("no subscription")
	}
	return conn
}

// A client that reads nothing must not block the sender of events, and it
// loses its connection when its queue is full.
func TestSlowClientDoesNotBlock(t *testing.T) {
	h, path := serveTest(t)
	subscribe(t, h, path)
	h.mu.Lock()
	send := h.send
	h.mu.Unlock()
	big := strings.Repeat("x", 16<<10)
	start := time.Now()
	for range 4 * maxQueued {
		send("toast", map[string]any{"text": big})
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("the events took %v", d)
	}
	select {
	case <-h.gone:
	case <-time.After(2 * time.Second):
		t.Error("the slow client kept its subscription")
	}
}

// fluxd sends only the newest state event to a client that reads slowly.
func TestStateEventsMerge(t *testing.T) {
	h, path := serveTest(t)
	conn := subscribe(t, h, path)
	h.mu.Lock()
	send := h.send
	h.mu.Unlock()
	for i := range 10 * maxQueued {
		send("state", map[string]int{"n": i})
	}
	r := bufio.NewReader(conn)
	last := -1
	deadline := time.Now().Add(2 * time.Second)
	for last != 10*maxQueued-1 && time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(deadline)
		line, err := r.ReadBytes('\n')
		if err != nil {
			t.Fatal(err)
		}
		var m struct {
			Event string `json:"event"`
			Data  struct {
				N int `json:"n"`
			} `json:"data"`
		}
		if json.Unmarshal(line, &m) != nil || m.Event != "state" {
			continue
		}
		if m.Data.N <= last {
			t.Fatalf("state %d came after state %d", m.Data.N, last)
		}
		last = m.Data.N
	}
	if last != 10*maxQueued-1 {
		t.Errorf("the last state is %d, want %d", last, 10*maxQueued-1)
	}
	select {
	case <-h.gone:
		t.Error("state events closed the connection")
	default:
	}
}

func TestCallAnswers(t *testing.T) {
	_, path := serveTest(t)
	c, err := Dial(path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var res map[string]string
	if err := c.Call("ping", nil, &res); err != nil {
		t.Fatal(err)
	}
	if res["method"] != "ping" {
		t.Errorf("result = %v", res)
	}
}

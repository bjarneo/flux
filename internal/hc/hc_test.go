package hc

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
)

// fakeCore answers each request line with the replies that reply
// returns. It records the requests on the channel.
func fakeCore(t *testing.T, reply func(req request) []string) (string, <-chan request) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "hc.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	reqs := make(chan request, 16)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				r := bufio.NewReader(conn)
				for {
					line, err := r.ReadBytes('\n')
					if err != nil {
						return
					}
					var req request
					if json.Unmarshal(line, &req) != nil {
						return
					}
					// Params come back as a map, so tests can check them.
					var raw struct {
						Params map[string]any `json:"params"`
					}
					_ = json.Unmarshal(line, &raw)
					req.Params = raw.Params
					reqs <- req
					for _, out := range reply(req) {
						if _, err := conn.Write([]byte(out + "\n")); err != nil {
							return
						}
					}
				}
			}()
		}
	}()
	return path, reqs
}

func TestHi(t *testing.T) {
	path, reqs := fakeCore(t, func(req request) []string {
		return []string{`{"jsonrpc":"2.0","id":1,"result":{"generation":1,"version":"0.1.15","core":{"id":"x","name":"osarchy"}}}`}
	})
	h, err := Hi(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	req := <-reqs
	if req.Method != "hello" || req.JSONRPC != "2.0" || req.Params.(map[string]any)["generation"] != float64(Generation) {
		t.Fatalf("request %+v", req)
	}
	if h.Version != "0.1.15" || h.Core.Name != "osarchy" {
		t.Fatalf("hello %+v", h)
	}
}

func TestHiOtherGeneration(t *testing.T) {
	path, _ := fakeCore(t, func(req request) []string {
		return []string{`{"jsonrpc":"2.0","id":1,"result":{"generation":2,"version":"1.0.0"}}`}
	})
	if _, err := Hi(context.Background(), path); err == nil {
		t.Fatal("Hi accepted protocol generation 2")
	}
}

func TestList(t *testing.T) {
	path, _ := fakeCore(t, func(req request) []string {
		return []string{`{"jsonrpc":"2.0","id":1,"result":{"hidden_finished":0,"terminals":[` +
			`{"address":"t4","state":"live","cwd":"/home/u/Work","title":"OC | Docs","labels":{"where":"Work / 1"},` +
			`"status":{"app":"opencode","state":"working","title":"Docs"},"foreground":{"pid":7,"cwd":"/home/u/Work/docs"}},` +
			`{"address":"yoga/t1","state":"live","cwd":"/home/u","title":"bash","labels":{},"status":null}]}}`}
	})
	terms, err := List(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	if len(terms) != 2 {
		t.Fatalf("terminals %+v", terms)
	}
	a := terms[0]
	if a.Address != "t4" || !a.Live() || a.Status == nil || a.Status.App != "opencode" || a.Dir() != "/home/u/Work/docs" {
		t.Fatalf("agent %+v", a)
	}
	if b := terms[1]; b.Address != "yoga/t1" || b.Status != nil || b.Dir() != "/home/u" {
		t.Fatalf("terminal %+v", b)
	}
}

func TestSendBlocked(t *testing.T) {
	path, reqs := fakeCore(t, func(req request) []string {
		return []string{`{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"t4 is blocked","data":{"kind":"blocked","hint":"answer it"}}}`}
	})
	err := Send(context.Background(), path, "t4", "hi", false)
	if Kind(err) != "blocked" {
		t.Fatalf("error %v, kind %q", err, Kind(err))
	}
	p := (<-reqs).Params.(map[string]any)
	if p["terminal"] != "t4" || p["text"] != "hi" || p["force"] != false {
		t.Fatalf("params %+v", p)
	}
}

func TestSubscribeSkipsToNotifications(t *testing.T) {
	path, _ := fakeCore(t, func(req request) []string {
		return []string{
			`{"jsonrpc":"2.0","id":1,"result":{"seq":3,"terminals":[]}}`,
			`{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":3}}`,
			`{"jsonrpc":"2.0","method":"event","params":{"seq":4,"type":"status","terminal":"t4","data":{}}}`,
		}
	})
	s, err := Subscribe(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, want := range []string{"heartbeat", "event"} {
		got, err := s.Next()
		if err != nil || got != want {
			t.Fatalf("Next = %q, %v; want %q", got, err, want)
		}
	}
}

func TestSocketPath(t *testing.T) {
	t.Setenv("HC_SOCKET", "")
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/1000")
	if got := SocketPath(); got != "/run/user/1000/herdr-core/default.sock" {
		t.Fatalf("SocketPath = %q", got)
	}
	t.Setenv("HC_SOCKET", "/tmp/x.sock")
	if got := SocketPath(); got != "/tmp/x.sock" {
		t.Fatalf("SocketPath with HC_SOCKET = %q", got)
	}
}

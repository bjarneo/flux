package herdr

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeServer answers each request line with the replies that reply
// returns. It records the requests on the channel.
func fakeServer(t *testing.T, reply func(req request) []string) (string, <-chan request) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "herdr.sock")
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

func TestSnapshot(t *testing.T) {
	path, reqs := fakeServer(t, func(req request) []string {
		return []string{`{"id":"flux","result":{"type":"session_snapshot","snapshot":{"version":"0.9.1","protocol":22,` +
			`"workspaces":[{"workspace_id":"w5","label":"cliamp","number":5}],` +
			`"agents":[{"pane_id":"w5:p1","workspace_id":"w5","agent":"claude","agent_status":"blocked",` +
			`"cwd":"/home/u/Code/cliamp","foreground_cwd":"/home/u/Code/cliamp","terminal_title_stripped":"Custom skin"}]}}}`}
	})
	snap, err := GetSnapshot(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	if req := <-reqs; req.Method != "session.snapshot" || req.ID != requestID {
		t.Fatalf("request %+v", req)
	}
	if snap.Protocol != 22 || len(snap.Workspaces) != 1 || snap.Workspaces[0].Label != "cliamp" {
		t.Fatalf("snapshot %+v", snap)
	}
	want := Agent{PaneID: "w5:p1", WorkspaceID: "w5", Agent: "claude", Status: StatusBlocked,
		Cwd: "/home/u/Code/cliamp", ForegroundCwd: "/home/u/Code/cliamp", Title: "Custom skin"}
	if len(snap.Agents) != 1 || snap.Agents[0] != want {
		t.Fatalf("agents %+v", snap.Agents)
	}
}

func TestReadAgentSendsParams(t *testing.T) {
	path, reqs := fakeServer(t, func(req request) []string {
		return []string{`{"id":"flux","result":{"type":"pane_read","read":{"pane_id":"w5:p1","text":"line 1\nline 2","truncated":true}}}`}
	})
	r, err := ReadAgent(context.Background(), path, "w5:p1", 120, false)
	if err != nil {
		t.Fatal(err)
	}
	if r.Text != "line 1\nline 2" || !r.Truncated || r.PaneID != "w5:p1" {
		t.Fatalf("read %+v", r)
	}
	req := <-reqs
	params, _ := json.Marshal(req.Params)
	var p struct {
		Target string `json:"target"`
		Source string `json:"source"`
		Lines  int    `json:"lines"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		t.Fatal(err)
	}
	if req.Method != "agent.read" || p.Target != "w5:p1" || p.Source != "recent_unwrapped" || p.Lines != 120 {
		t.Fatalf("request %s %s", req.Method, params)
	}
}

func TestControlRequests(t *testing.T) {
	path, reqs := fakeServer(t, func(req request) []string {
		return []string{`{"id":"flux","result":{"type":"ok"}}`}
	})
	ctx := context.Background()
	if _, err := ReadAgent(ctx, path, "w5:p1", 50, true); err != nil {
		t.Fatal(err)
	}
	if err := SendKeys(ctx, path, "w5:p1", []string{"2"}); err != nil {
		t.Fatal(err)
	}
	if err := Prompt(ctx, path, "w5:p1", "Run the tests"); err != nil {
		t.Fatal(err)
	}
	if err := SendInput(ctx, path, "w5:p1", "Use port 8080", []string{"enter"}); err != nil {
		t.Fatal(err)
	}
	want := []string{
		`agent.read {"format":"ansi","lines":50,"source":"recent_unwrapped","strip_ansi":false,"target":"w5:p1"}`,
		`agent.send_keys {"keys":["2"],"target":"w5:p1"}`,
		`agent.prompt {"target":"w5:p1","text":"Run the tests"}`,
		`pane.send_input {"keys":["enter"],"pane_id":"w5:p1","text":"Use port 8080"}`,
	}
	for _, w := range want {
		req := <-reqs
		params, _ := json.Marshal(req.Params)
		if got := req.Method + " " + string(params); got != w {
			t.Errorf("request %s, want %s", got, w)
		}
	}
}

func TestLayoutRequests(t *testing.T) {
	path, reqs := fakeServer(t, func(req request) []string {
		switch req.Method {
		case "workspace.create":
			return []string{`{"id":"flux","result":{"type":"workspace_created","workspace":{"workspace_id":"w2","label":"flux"},` +
				`"tab":{"tab_id":"w2:t1","workspace_id":"w2"},"root_pane":{"pane_id":"w2:p1","tab_id":"w2:t1","cwd":"/src/flux"}}}`}
		case "server.agent_manifests":
			return []string{`{"id":"flux","result":{"type":"agent_manifest_status","manifests":[{"agent":"claude"},{"agent":""},{"agent":"codex"}]}}`}
		case "agent.get":
			return []string{`{"id":"flux","result":{"type":"agent_info","agent":{"pane_id":"w2:p1","agent":null,"name":"claude-flux"}}}`}
		}
		return []string{`{"id":"flux","result":{"type":"ok"}}`}
	})
	ctx := context.Background()
	c, err := CreateWorkspace(ctx, path, "/src/flux")
	if err != nil || c.Workspace.ID != "w2" || c.Tab.ID != "w2:t1" || c.RootPane.ID != "w2:p1" || c.RootPane.Cwd != "/src/flux" {
		t.Fatalf("created %+v %v", c, err)
	}
	if _, err := CreateTab(ctx, path, "w2", "/src/web"); err != nil {
		t.Fatal(err)
	}
	if err := StartAgent(ctx, path, "claude-flux", "claude", "w2:p1"); err != nil {
		t.Fatal(err)
	}
	if a, err := GetAgent(ctx, path, "w2:p1"); err != nil || a.Agent != "" || a.Name != "claude-flux" {
		t.Fatalf("agent %+v %v", a, err)
	}
	if kinds, err := AgentKinds(ctx, path); err != nil || strings.Join(kinds, ",") != "claude,codex" {
		t.Fatalf("kinds %v %v", kinds, err)
	}
	if _, err := ReadPane(ctx, path, "w2:p1", 1000, true); err != nil {
		t.Fatal(err)
	}
	if err := ClosePane(ctx, path, "w2:p1"); err != nil {
		t.Fatal(err)
	}
	want := []string{
		`workspace.create {"cwd":"/src/flux","focus":false}`,
		`tab.create {"cwd":"/src/web","focus":false,"workspace_id":"w2"}`,
		`agent.start {"kind":"claude","name":"claude-flux","pane_id":"w2:p1"}`,
		`agent.get {"target":"w2:p1"}`,
		`server.agent_manifests {}`,
		`pane.read {"format":"ansi","lines":1000,"pane_id":"w2:p1","source":"recent_unwrapped","strip_ansi":false}`,
		`pane.close {"pane_id":"w2:p1"}`,
	}
	for _, w := range want {
		req := <-reqs
		params, _ := json.Marshal(req.Params)
		if got := req.Method + " " + string(params); got != w {
			t.Errorf("request %s, want %s", got, w)
		}
	}
}

func TestCode(t *testing.T) {
	if Code(fmt.Errorf("read: %w", &Error{Code: "agent_not_idle"})) != "agent_not_idle" || Code(errors.New("x")) != "" || Code(nil) != "" {
		t.Fatal("Code")
	}
}

func TestCallReturnsHerdrError(t *testing.T) {
	path, _ := fakeServer(t, func(req request) []string {
		return []string{`{"id":"flux","error":{"code":"agent_not_found","message":"agent target w9:p1 not found"}}`}
	})
	_, err := ReadAgent(context.Background(), path, "w9:p1", 10, false)
	var he *Error
	if !errors.As(err, &he) || he.Code != "agent_not_found" {
		t.Fatalf("error %v", err)
	}
}

func TestCallSkipsEventsAndEmptyLines(t *testing.T) {
	path, _ := fakeServer(t, func(req request) []string {
		return []string{``, `{"event":"pane_created","data":{}}`, `{"id":"flux","result":{"version":"0.9.1","protocol":22}}`}
	})
	p, err := Ping(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	if p.Protocol != 22 || p.Version != "0.9.1" {
		t.Fatalf("pong %+v", p)
	}
}

func TestCallWithoutServer(t *testing.T) {
	path := filepath.Join(t.TempDir(), "missing.sock")
	if _, err := Ping(context.Background(), path); err == nil {
		t.Fatal("a missing socket must return an error")
	}
}

func TestCallTimesOut(t *testing.T) {
	path, _ := fakeServer(t, func(req request) []string { return nil })
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := Ping(ctx, path); err == nil {
		t.Fatal("a server that does not answer must return an error")
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("the call must end at the context deadline")
	}
}

func TestSubscribe(t *testing.T) {
	path, reqs := fakeServer(t, func(req request) []string {
		return []string{
			`{"id":"flux","result":{"type":"subscription_started"}}`,
			`{"event":"pane_agent_status_changed","data":{"pane_id":"w5:p1","workspace_id":"w5","agent_status":"done"}}`,
		}
	})
	s, err := Subscribe(context.Background(), path, []Subscription{
		{Type: "pane.closed"},
		{Type: "pane.agent_status_changed", PaneID: "w5:p1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	req := <-reqs
	params, _ := json.Marshal(req.Params)
	if req.Method != "events.subscribe" ||
		string(params) != `{"subscriptions":[{"type":"pane.closed"},{"pane_id":"w5:p1","type":"pane.agent_status_changed"}]}` {
		t.Fatalf("request %s %s", req.Method, params)
	}
	ev, err := s.Next()
	if err != nil {
		t.Fatal(err)
	}
	if ev.Name != "pane_agent_status_changed" || !strings.Contains(string(ev.Data), `"done"`) {
		t.Fatalf("event %+v", ev)
	}
	s.Close()
	if _, err := s.Next(); err == nil {
		t.Fatal("Next must end after Close")
	}
}

func TestReadLineLimit(t *testing.T) {
	long := strings.Repeat("x", maxLine+1) + "\n"
	if _, err := readLine(bufio.NewReader(strings.NewReader(long))); !errors.Is(err, errLineTooLong) {
		t.Fatalf("error %v, want errLineTooLong", err)
	}
	line, err := readLine(bufio.NewReader(strings.NewReader("abc\nrest")))
	if err != nil || string(line) != "abc\n" {
		t.Fatalf("line %q, error %v", line, err)
	}
}

func TestSocketPath(t *testing.T) {
	t.Setenv("HERDR_SOCKET_PATH", "")
	t.Setenv("XDG_CONFIG_HOME", "/tmp/cfg")
	if got := SocketPath(); got != "/tmp/cfg/herdr/herdr.sock" {
		t.Fatalf("path %q", got)
	}
	t.Setenv("HERDR_SOCKET_PATH", "/run/herdr-test.sock")
	if got := SocketPath(); got != "/run/herdr-test.sock" {
		t.Fatalf("path %q", got)
	}
}

func TestCheckOwner(t *testing.T) {
	path := filepath.Join(t.TempDir(), "owner.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := checkOwner(conn, os.Getuid()); err != nil {
		t.Errorf("a socket of this user: %v", err)
	}
	if err := checkOwner(conn, os.Getuid()+1); err == nil || !strings.Contains(err.Error(), "belongs to user") {
		t.Errorf("a socket of another user: %v", err)
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	if err := checkOwner(a, os.Getuid()); err == nil {
		t.Error("a pipe is not a Unix socket")
	}
}

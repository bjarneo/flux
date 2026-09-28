package core

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/herdr"
	"flux/internal/proto"
)

func TestHerdrAgents(t *testing.T) {
	snap := herdr.Snapshot{
		Workspaces: []herdr.Workspace{
			{ID: "wB", Label: "flux", Number: 1},
			{ID: "wA", Label: "cliamp", Number: 2},
		},
		Agents: []herdr.Agent{
			{PaneID: "wA:p1", WorkspaceID: "wA", Agent: "claude", Status: "idle", Cwd: "/home/u/Code/cliamp"},
			{PaneID: "wZ:p1", WorkspaceID: "wZ", Agent: "codex", Status: "", Cwd: "/"},
			{PaneID: "", WorkspaceID: "wB", Agent: "claude", Status: "working"},
			{PaneID: "wB:p2", WorkspaceID: "wB", Agent: "claude", Status: "blocked",
				Cwd: "/home/u/Code/flux", ForegroundCwd: "/home/u/Code/flux/android", Title: "Agents screen"},
		},
	}
	got := herdrAgents(snap)
	want := []HerdrAgent{
		{Pane: "wB:p2", Agent: "claude", Status: "blocked", Title: "Agents screen", Project: "android", Workspace: "flux"},
		{Pane: "wA:p1", Agent: "claude", Status: "idle", Project: "cliamp", Workspace: "cliamp"},
		{Pane: "wZ:p1", Agent: "codex", Status: "unknown", Project: "/"},
	}
	if len(got) != len(want) {
		t.Fatalf("agents %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("agent %d: %+v, want %+v", i, got[i], want[i])
		}
	}
	if panes := herdrPanes(got); strings.Join(panes, ",") != "wA:p1,wB:p2,wZ:p1" {
		t.Errorf("panes %v", panes)
	}
}

func TestHerdrLines(t *testing.T) {
	for in, want := range map[int]int{-1: herdrDefaultLines, 0: herdrDefaultLines, 1: 1, 120: 120, 400: 400, 5000: herdrMaxLines} {
		if got := herdrLines(in); got != want {
			t.Errorf("herdrLines(%d) = %d, want %d", in, got, want)
		}
	}
}

func TestTrimLineEnds(t *testing.T) {
	if got := trimLineEnds("❯ \u00a0   \nok\t\n\n    right  "); got != "❯ \u00a0\nok\n\n    right" {
		t.Errorf("trimLineEnds: %q", got)
	}
}

func TestTailText(t *testing.T) {
	if got, cut := tailText("short", 10); got != "short" || cut {
		t.Errorf("short text: %q %v", got, cut)
	}
	if got, cut := tailText("line one\nline two\nline three", 15); got != "line three" || !cut {
		t.Errorf("cut at a line: %q %v", got, cut)
	}
	// "ø" is 2 bytes. The cut falls inside it, so the result starts after it.
	if got, cut := tailText("aaøbbbb", 5); got != "bbbb" || !cut {
		t.Errorf("cut inside a character: %q %v", got, cut)
	}
	if got, _ := tailText("abc\n", 3); got != "bc\n" {
		t.Errorf("a line break at the end only: %q", got)
	}
}

// fakeHerdr is a herdr API socket for tests. snapshot is the JSON of the
// session snapshot. read is the result or error member of the agent.read
// reply. readText replaces it for a plain read when it is set. queue
// holds that member for the next calls of a method, and replies holds it
// for the calls after the queue. The default is an ok result. calls
// records each other request as the method and its params. push sends an
// event to each subscription connection.
type fakeHerdr struct {
	path string

	mu       sync.Mutex
	snapshot string
	read     string
	readText string
	queue    map[string][]string
	replies  map[string]string
	calls    []string
	subs     []net.Conn
	subCalls []string
}

func newFakeHerdr(t *testing.T) *fakeHerdr {
	t.Helper()
	f := &fakeHerdr{path: filepath.Join(t.TempDir(), "herdr.sock"), snapshot: `{"protocol":22,"workspaces":[],"agents":[]}`}
	ln, err := net.Listen("unix", f.path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ln.Close()
		f.mu.Lock()
		for _, c := range f.subs {
			c.Close()
		}
		f.mu.Unlock()
	})
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go f.serve(conn)
		}
	}()
	return f
}

func (f *fakeHerdr) serve(conn net.Conn) {
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		conn.Close()
		return
	}
	var req struct {
		ID     string          `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if json.Unmarshal(line, &req) != nil {
		conn.Close()
		return
	}
	f.mu.Lock()
	var result string
	switch req.Method {
	case "ping":
		result = `"result":{"type":"pong","version":"0.9.1","protocol":22}`
	case "session.snapshot":
		result = `"result":{"type":"session_snapshot","snapshot":` + f.snapshot + `}`
	case "agent.read":
		result = f.read
		if f.readText != "" && !strings.Contains(string(req.Params), `"format":"ansi"`) {
			result = f.readText
		}
		f.calls = append(f.calls, req.Method+" "+string(req.Params))
	default:
		result = `"result":{"type":"ok"}`
		if r, ok := f.replies[req.Method]; ok {
			result = r
		}
		if q := f.queue[req.Method]; len(q) > 0 {
			result, f.queue[req.Method] = q[0], q[1:]
		}
		f.calls = append(f.calls, req.Method+" "+string(req.Params))
	case "events.subscribe":
		f.subs = append(f.subs, conn)
		f.subCalls = append(f.subCalls, string(req.Params))
		f.mu.Unlock()
		_, _ = conn.Write([]byte(`{"id":"` + req.ID + `","result":{"type":"subscription_started"}}` + "\n"))
		return
	}
	f.mu.Unlock()
	_, _ = conn.Write([]byte(`{"id":"` + req.ID + `",` + result + "}\n"))
	conn.Close()
}

func (f *fakeHerdr) set(snapshot string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.snapshot = snapshot
}

func (f *fakeHerdr) push(event string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, c := range f.subs {
		_, _ = c.Write([]byte(event + "\n"))
	}
}

func (f *fakeHerdr) takeCalls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	calls := f.calls
	f.calls = nil
	return calls
}

func (f *fakeHerdr) subscriptions() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.subCalls...)
}

func herdrDaemon(ctx context.Context, path string) *Daemon {
	return &Daemon{
		cfg: &config.Config{Herdr: true}, devices: map[string]*Device{}, logger: log.New(io.Discard, "", 0),
		dirty: make(chan struct{}, 1), ctx: ctx, herdrPath: path, herdrWake: make(chan struct{}, 1),
	}
}

func (d *Daemon) herdrStatus() (bool, []HerdrAgent) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.herdrRunning, d.herdrAgents
}

// waitFor polls cond for up to 3 seconds.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out: %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestHerdrLoopFollowsEvents(t *testing.T) {
	f := newFakeHerdr(t)
	f.set(`{"protocol":22,"workspaces":[{"workspace_id":"w1","label":"flux","number":1}],` +
		`"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent":"claude","agent_status":"working","cwd":"/src/flux"}]}`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d := herdrDaemon(ctx, f.path)
	done := make(chan struct{})
	go func() {
		d.herdrLoop(ctx)
		close(done)
	}()

	waitFor(t, "the first agent list", func() bool {
		running, agents := d.herdrStatus()
		return running && len(agents) == 1 && agents[0].Status == "working"
	})
	if subs := f.subscriptions(); len(subs) != 1 || !strings.Contains(subs[0], `"pane_id":"w1:p1"`) {
		t.Fatalf("subscriptions %v", subs)
	}

	// A status event makes fluxd read the session again.
	f.set(`{"protocol":22,"workspaces":[{"workspace_id":"w1","label":"flux","number":1}],` +
		`"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent":"claude","agent_status":"blocked","cwd":"/src/flux"}]}`)
	f.push(`{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p1","workspace_id":"w1","agent_status":"blocked"}}`)
	waitFor(t, "the blocked status", func() bool {
		_, agents := d.herdrStatus()
		return len(agents) == 1 && agents[0].Status == "blocked"
	})

	// A new agent pane needs a new subscription for its status.
	f.set(`{"protocol":22,"workspaces":[{"workspace_id":"w1","label":"flux","number":1}],` +
		`"agents":[{"pane_id":"w1:p1","workspace_id":"w1","agent":"claude","agent_status":"blocked","cwd":"/src/flux"},` +
		`{"pane_id":"w1:p2","workspace_id":"w1","agent":"codex","agent_status":"idle","cwd":"/src/flux"}]}`)
	f.push(`{"event":"pane_agent_detected","data":{"pane_id":"w1:p2"}}`)
	waitFor(t, "the second subscription", func() bool {
		subs := f.subscriptions()
		return len(subs) == 2 && strings.Contains(subs[1], `"pane_id":"w1:p2"`)
	})
	waitFor(t, "the second agent", func() bool {
		_, agents := d.herdrStatus()
		return len(agents) == 2
	})

	// Turning the feature off clears the state.
	d.mu.Lock()
	d.cfg.Herdr = false
	d.mu.Unlock()
	d.herdrChanged()
	waitFor(t, "the cleared state", func() bool {
		running, agents := d.herdrStatus()
		return !running && agents == nil
	})

	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("the loop must end with the context")
	}
}

func TestHerdrLoopWithoutServer(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d := herdrDaemon(ctx, filepath.Join(t.TempDir(), "missing.sock"))
	done := make(chan struct{})
	go func() {
		d.herdrLoop(ctx)
		close(done)
	}()
	time.Sleep(50 * time.Millisecond)
	if running, _ := d.herdrStatus(); running {
		t.Fatal("herdr cannot run without its socket")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("the loop must end with the context")
	}
}

func outputBody(t *testing.T, p *proto.Packet) map[string]any {
	t.Helper()
	if p.Type != proto.TypeFluxHerdr {
		t.Fatalf("packet type %s", p.Type)
	}
	var body map[string]any
	if err := p.Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["kind"] != "output" {
		t.Fatalf("body %v", body)
	}
	return body
}

func TestReadHerdr(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	d.herdrRunning = true
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "done"}}

	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"All tests pass   ","truncated":false}}`
	body := outputBody(t, d.readHerdr("w1:p1", 0, false))
	if body["text"] != "All tests pass" || body["truncated"] != false || body["error"] != nil {
		t.Errorf("read: %v", body)
	}

	// A pane without an agent is not readable, also when herdr has it.
	body = outputBody(t, d.readHerdr("w1:p9", 50, false))
	if body["error"] != "No agent runs in w1:p9" || body["text"] != nil {
		t.Errorf("unknown pane: %v", body)
	}

	f.read = `"error":{"code":"agent_not_found","message":"agent target w1:p1 not found"}`
	body = outputBody(t, d.readHerdr("w1:p1", 50, false))
	if body["error"] != "The agent in w1:p1 is gone" {
		t.Errorf("gone agent: %v", body)
	}

	d.cfg.Herdr = false
	body = outputBody(t, d.readHerdr("w1:p1", 50, false))
	if body["error"] != "herdr sync is off on this computer" {
		t.Errorf("feature off: %v", body)
	}
}

func TestHerdrViewWhenOff(t *testing.T) {
	d := herdrDaemon(context.Background(), "")
	d.herdrRunning = true
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1"}}
	d.cfg.Herdr = false
	v := d.herdrViewLocked()
	if v.Enabled || v.Running || len(v.Agents) != 0 || v.Agents == nil {
		t.Fatalf("view %+v", v)
	}
	var body map[string]any
	if err := herdrStatePacket(v).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["kind"] != "state" || body["enabled"] != false {
		t.Fatalf("body %v", body)
	}
	if agents, ok := body["agents"].([]any); !ok || len(agents) != 0 {
		t.Fatalf("agents must be an empty list: %v", body["agents"])
	}
}

func TestCleanANSI(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"line ends", "one  \r\ntwo\r\n", "one\ntwo\n"},
		{"styles stay", "\x1b[1m\x1b[38;5;1mred\x1b[0m plain", "\x1b[1m\x1b[38;5;1mred\x1b[0m plain"},
		{"blanks with a background stay", "\x1b[48;5;2m bg \x1b[0m   \x1b[0m  ", "\x1b[48;5;2m bg \x1b[0m\x1b[0m"},
		{"a panel keeps its blanks", "\x1b[38;2;9;9;9m┃\x1b[48;2;1;2;3m  text    \x1b[0m  ", "\x1b[38;2;9;9;9m┃\x1b[48;2;1;2;3m  text    \x1b[0m"},
		{"a foreground is not a background", "\x1b[38;2;48;49;50mx   \x1b[38;5;48m  \x1b[0m", "\x1b[38;2;48;49;50mx\x1b[38;5;48m\x1b[0m"},
		{"a background ends", "\x1b[44mx\x1b[49m   \x1b[0m", "\x1b[44mx\x1b[49m\x1b[0m"},
		{"a reset ends a background", "\x1b[1;104mx\x1b[m  ", "\x1b[1;104mx\x1b[m"},
		{"the colon form sets a background", "x\x1b[48:2::1:2:3m  \x1b[0m ", "x\x1b[48:2::1:2:3m  \x1b[0m"},
		{"cursor moves go", "a\x1b[2Kb\x1b[10;4Hc", "abc"},
		{"links go", "\x1b]8;;https://x.y\x07link\x1b]8;;\x1b\\ end", "link end"},
		{"other escapes go", "a\x1b(Bb\x1b=c", "abc"},
		{"control characters go", "a\x07b\x08c\x7fd\te", "abcd\te"},
		{"a cut sequence goes", "text\x1b[38;5", "text"},
		{"UTF-8 stays", "\x1b[38;2;215;119;87m●\x1b[0m Løst ❯", "\x1b[38;2;215;119;87m●\x1b[0m Løst ❯"},
	}
	for _, c := range cases {
		if got := cleanANSI(c.in); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestReadHerdrANSI(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "idle"}}
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","format":"ansi","text":"\u001b[1mok\u001b[0m  \r\n\u001b[2Knext","truncated":false}}`
	f.readText = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"ok\nnext","truncated":false}}`
	body := outputBody(t, d.readHerdr("w1:p1", 20, true))
	if body["format"] != "ansi" || body["text"] != "\x1b[1mok\x1b[0m\nnext" {
		t.Errorf("body %q", body)
	}
	calls := f.takeCalls()
	if len(calls) != 2 || !strings.Contains(calls[0], `"format":"ansi"`) || !strings.Contains(calls[0], `"strip_ansi":false`) ||
		strings.Contains(calls[1], `"format"`) {
		t.Errorf("calls %v", calls)
	}

	// A screen with all the lines needs no plain read.
	body = outputBody(t, d.readHerdr("w1:p1", 2, true))
	if body["text"] != "\x1b[1mok\x1b[0m\nnext" {
		t.Errorf("full screen: %q", body)
	}
	if calls := f.takeCalls(); len(calls) != 1 {
		t.Errorf("full screen calls %v", calls)
	}
}

func TestReadHerdrHistory(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "idle"}}

	// Idle: the plain history ends with the rows of the screen.
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"\u001b[1m● Tests pass\u001b[0m\r\n❯ \u00a0\r\n  status","truncated":false}}`
	f.readText = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"● Old answer\n\n● Tests pass\n❯\n  status","truncated":false}}`
	body := outputBody(t, d.readHerdr("w1:p1", 1000, true))
	if want := "● Old answer\n\n\x1b[1m● Tests pass\x1b[0m\n❯ \u00a0\n  status"; body["text"] != want {
		t.Errorf("idle: %q, want %q", body["text"], want)
	}

	// Working: herdr refuses the history, so the last history stays, and
	// the newer screen replaces its end.
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"● Tests pass\n● New step\n❯\n  status","truncated":false}}`
	f.readText = `"error":{"code":"agent_not_idle","message":"cannot read 1000 lines while w1:p1 is working"}`
	body = outputBody(t, d.readHerdr("w1:p1", 1000, true))
	if want := "● Old answer\n\n● Tests pass\n● New step\n❯\n  status"; body["text"] != want || body["error"] != nil {
		t.Errorf("working: %q, want %q", body["text"], want)
	}

	// A gone agent loses its history.
	d.setHerdr(true, herdrLive{})
	d.mu.Lock()
	n := len(d.herdrHistory)
	d.mu.Unlock()
	if n != 0 {
		t.Errorf("the history of a gone agent stays: %d", n)
	}
}

func TestSpliceScreen(t *testing.T) {
	gap := herdrGap
	cases := []struct {
		name            string
		history, screen []string
		want            []string
	}{
		{"no history", nil, []string{"a"}, []string{"a"}},
		{"same moment", []string{"h1", "h2", "T1", "T2 \u00a0", "box\r"}, []string{"\x1b[1mT1\x1b[0m", "T2", "box"},
			[]string{"h1", "h2", "\x1b[1mT1\x1b[0m", "T2", "box"}},
		{"newer screen", []string{"h1", "T1", "T2", "T3", "box"}, []string{"T2", "T3", "T4", "box"},
			[]string{"h1", "T1", "T2", "T3", "T4", "box"}},
		{"blank rows over the anchor", []string{"h1", "h2", "T1", "T2"}, []string{"", "───", "T1", "T2"},
			[]string{"", "───", "T1", "T2"}},
		{"one row at the end", []string{"h1", "T1"}, []string{"T1", "T2"}, []string{"h1", "T1", "T2"}},
		{"one unique row in the middle", []string{"h1", "T1", "box"}, []string{"T1", "T2"}, []string{"h1", "T1", "T2"}},
		{"one row with copies is not enough", []string{"T1", "h1", "T1", "box"}, []string{"T1", "T2"},
			[]string{"T1", "h1", "T1", "box", gap, "T1", "T2"}},
		{"no place", []string{"h1", "h2"}, []string{"T1", "T2"}, []string{"h1", "h2", gap, "T1", "T2"}},
		{"the most rows win", []string{"A", "B", "C", "A", "X"}, []string{"A", "B", "C"}, []string{"A", "B", "C"}},
		{"a blank screen", []string{"h1"}, []string{"", ""}, []string{"h1", "", ""}},
	}
	for _, c := range cases {
		got := spliceScreen(c.history, c.screen)
		if strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestHerdrTerminalsAndWorkspaces(t *testing.T) {
	snap := herdr.Snapshot{
		Workspaces: []herdr.Workspace{
			{ID: "wB", Label: "flux", Number: 2, ActiveTab: "wB:t2"},
			{ID: "wA", Label: "web", Number: 1, ActiveTab: "wA:t1"},
		},
		Panes: []herdr.Pane{
			{ID: "wB:p1", WorkspaceID: "wB", TabID: "wB:t1", Cwd: "/src/flux"},
			{ID: "wB:p2", WorkspaceID: "wB", TabID: "wB:t2", Cwd: "/src/flux", ForegroundCwd: "/src/flux/android", Title: "gradle"},
			{ID: "wA:p1", WorkspaceID: "wA", TabID: "wA:t1", Cwd: "/src/web", Title: "u@host:~/src/web"},
		},
		Agents: []herdr.Agent{{PaneID: "wB:p1", WorkspaceID: "wB", Agent: "claude"}},
	}
	terms := herdrTerminals(snap)
	want := []HerdrTerminal{
		{Pane: "wA:p1", Title: "u@host:~/src/web", Project: "web", Workspace: "web"},
		{Pane: "wB:p2", Title: "gradle", Project: "android", Workspace: "flux"},
	}
	if !slices.Equal(terms, want) {
		t.Errorf("terminals %+v", terms)
	}
	places := herdrWorkspaces(snap)
	wantPlaces := []HerdrWorkspace{{ID: "wA", Label: "web", Cwd: "/src/web"}, {ID: "wB", Label: "flux", Cwd: "/src/flux/android"}}
	if !slices.Equal(places, wantPlaces) {
		t.Errorf("workspaces %+v", places)
	}
}

func TestHerdrViewTerminals(t *testing.T) {
	d := herdrDaemon(context.Background(), "")
	d.herdrTerms = []HerdrTerminal{{Pane: "w1:p2"}}
	d.herdrPlaces = []HerdrWorkspace{{ID: "w1"}}
	d.herdrKinds = []string{"claude"}
	d.cfg.HerdrTerminals = true
	v := d.herdrViewLocked()
	if v.Terminals || len(v.Panes) != 0 || len(v.Workspaces) != 0 || len(v.Kinds) != 0 {
		t.Fatalf("terminals need herdr_control: %+v", v)
	}
	d.cfg.HerdrControl = true
	v = d.herdrViewLocked()
	if !v.Terminals || len(v.Panes) != 1 || len(v.Workspaces) != 1 || len(v.Kinds) != 1 {
		t.Fatalf("view %+v", v)
	}
	d.cfg.HerdrTerminals = false
	v = d.herdrViewLocked()
	if v.Terminals || len(v.Panes) != 0 || v.Panes == nil || len(v.Kinds) != 1 {
		t.Fatalf("terminals off: %+v", v)
	}
	var body map[string]any
	if err := herdrStatePacket(v).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body["terminals"] != false || body["panes"] == nil || body["kinds"] == nil || body["workspaces"] == nil {
		t.Fatalf("body %v", body)
	}
}

func TestHerdrInput(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	d.cfg.HerdrControl = true
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude"}}
	d.herdrTerms = []HerdrTerminal{{Pane: "w1:p2"}}

	if body := sentBody(t, d.herdrInput(dev, "w1:p2", "ls", []string{"enter"})); body["error"] != errHerdrTerminalsOff {
		t.Fatalf("terminals off: %v", body)
	}
	d.cfg.HerdrTerminals = true
	refused := []struct {
		name string
		p    *proto.Packet
		want string
	}{
		{"agent pane", d.herdrInput(dev, "w1:p1", "ls", nil), "No terminal is in w1:p1"},
		{"nothing", d.herdrInput(dev, "w1:p2", "\x1b", nil), "Send text or a key"},
		{"key not allowed", d.herdrInput(dev, "w1:p2", "", []string{"f1"}), `The key "f1" is not allowed`},
		{"too many keys", d.herdrInput(dev, "w1:p2", "", strings.Split("up up up up up up up up up", " ")), "Send 0 to 8 keys"},
	}
	for _, c := range refused {
		if body := sentBody(t, c.p); body["error"] != c.want {
			t.Errorf("%s: %v", c.name, body)
		}
	}
	if calls := f.takeCalls(); len(calls) != 0 {
		t.Fatalf("a refused input must not reach herdr: %v", calls)
	}
	body := sentBody(t, d.herdrInput(dev, "w1:p2", "git status\n-s\x07", []string{"enter"}))
	if body["error"] != nil || body["action"] != "input" {
		t.Errorf("input: %v", body)
	}
	if calls := f.takeCalls(); len(calls) != 1 || calls[0] != `pane.send_input {"keys":["enter"],"pane_id":"w1:p2","text":"git status -s"}` {
		t.Errorf("input calls %v", calls)
	}
	body = sentBody(t, d.herdrInput(dev, "w1:p2", "", []string{"ctrl+c"}))
	if body["error"] != nil {
		t.Errorf("ctrl+c: %v", body)
	}
}

func createdBody(t *testing.T, p *proto.Packet, kind string) map[string]any {
	t.Helper()
	var body map[string]any
	if err := p.Decode(&body); err != nil {
		t.Fatal(err)
	}
	if p.Type != proto.TypeFluxHerdr || body["kind"] != kind {
		t.Fatalf("packet %s %v", p.Type, body)
	}
	return body
}

func TestHerdrCreate(t *testing.T) {
	f := newFakeHerdr(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d := herdrDaemon(ctx, f.path)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	dir := t.TempDir()
	d.herdrKinds = []string{"claude"}
	d.herdrPlaces = []HerdrWorkspace{{ID: "w1", Label: "flux", Cwd: dir}}

	if body := createdBody(t, d.herdrCreate(dev, "agent", "claude", dir, ""), "created"); body["error"] != errHerdrControlOff {
		t.Fatalf("control off: %v", body)
	}
	d.cfg.HerdrControl = true
	refused := []struct {
		name                string
		what, kind, cwd, ws string
		want                string
	}{
		{"terminals off", "terminal", "", dir, "", errHerdrTerminalsOff},
		{"unknown kind", "agent", "gemini", dir, "", `herdr cannot start the agent "gemini" on this computer`},
		{"unknown workspace", "agent", "claude", dir, "w9", "The workspace w9 is gone"},
		{"relative folder", "agent", "claude", "src", "", "Give the folder as a full path or with ~/: src"},
		{"missing folder", "agent", "claude", dir + "/nope", "", "The folder " + dir + "/nope does not exist"},
	}
	for _, c := range refused {
		if body := createdBody(t, d.herdrCreate(dev, c.what, c.kind, c.cwd, c.ws), "created"); body["error"] != c.want {
			t.Errorf("%s: %v", c.name, body)
		}
	}
	if calls := f.takeCalls(); len(calls) != 0 {
		t.Fatalf("a refused create must not reach herdr: %v", calls)
	}

	// The loop must see the new pane before the answer. It reads the
	// agent kinds too, so claude must be on PATH.
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "claude"), []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	f.mu.Lock()
	f.replies = map[string]string{
		"server.agent_manifests": `"result":{"type":"agent_manifest_status","manifests":[{"agent":"claude"},{"agent":"gemini"}]}`,
		"tab.create":             `"result":{"type":"tab_created","tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}`,
		"agent.get":              `"result":{"type":"agent_info","agent":{"pane_id":"w1:p2","agent":"claude","name":"claude-x"}}`,
	}
	f.queue = map[string][]string{
		"agent.start": {`"error":{"code":"agent_pane_busy","message":"busy"}`, `"error":{"code":"agent_name_taken","message":"taken"}`},
		"agent.get":   {`"result":{"type":"agent_info","agent":{"pane_id":"w1:p2","agent":null,"name":"claude-x"}}`},
	}
	f.mu.Unlock()
	f.set(`{"protocol":22,"workspaces":[{"workspace_id":"w1","label":"flux","number":1}],` +
		`"agents":[{"pane_id":"w1:p2","workspace_id":"w1","agent":"claude","agent_status":"idle"}]}`)
	go d.herdrLoop(ctx)
	waitFor(t, "the agent kinds", func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return slices.Equal(d.herdrKinds, []string{"claude"}) && len(d.herdrPlaces) == 1
	})
	body := createdBody(t, d.herdrCreate(dev, "agent", "claude", dir, "w1"), "created")
	if body["error"] != nil || body["pane"] != "w1:p2" || body["what"] != "agent" {
		t.Fatalf("agent: %v", body)
	}
	name := agentName("claude", dir, 0)
	var starts []string
	for _, c := range f.takeCalls() {
		if strings.HasPrefix(c, "agent.start ") || strings.HasPrefix(c, "tab.create ") {
			starts = append(starts, c)
		}
	}
	want := []string{
		`tab.create {"cwd":"` + dir + `","focus":false,"workspace_id":"w1"}`,
		`agent.start {"kind":"claude","name":"` + name + `","pane_id":"w1:p2"}`,
		`agent.start {"kind":"claude","name":"` + name + `","pane_id":"w1:p2"}`,
		`agent.start {"kind":"claude","name":"` + name + `-2","pane_id":"w1:p2"}`,
	}
	if strings.Join(starts, "\n") != strings.Join(want, "\n") {
		t.Errorf("start calls\n%s\nwant\n%s", strings.Join(starts, "\n"), strings.Join(want, "\n"))
	}
	if _, agents := d.herdrStatus(); len(agents) != 1 || agents[0].Pane != "w1:p2" {
		t.Errorf("the state must have the new agent: %+v", agents)
	}

	// A terminal opens in a new workspace in the home folder.
	d.cfg.HerdrTerminals = true
	f.mu.Lock()
	f.replies["workspace.create"] = `"result":{"type":"workspace_created","workspace":{"workspace_id":"w2"},"root_pane":{"pane_id":"w2:p1"}}`
	f.mu.Unlock()
	f.set(`{"protocol":22,"workspaces":[],"panes":[{"pane_id":"w2:p1","workspace_id":"w2"}],"agents":[]}`)
	body = createdBody(t, d.herdrCreate(dev, "terminal", "", "~", ""), "created")
	home, _ := os.UserHomeDir()
	if body["error"] != nil || body["pane"] != "w2:p1" {
		t.Fatalf("terminal: %v", body)
	}
	if calls := f.takeCalls(); len(calls) == 0 || calls[0] != `workspace.create {"cwd":"`+home+`","focus":false}` {
		t.Errorf("terminal calls %v", calls)
	}
}

func TestHerdrCreateCloseOnFailure(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	d.cfg.HerdrControl = true
	d.herdrKinds = []string{"gemini"}
	f.replies = map[string]string{
		"workspace.create": `"result":{"type":"workspace_created","root_pane":{"pane_id":"w3:p1"}}`,
		"agent.start":      `"error":{"code":"agent_invalid_kind","message":"unknown agent kind"}`,
	}
	body := createdBody(t, d.herdrCreate(dev, "agent", "gemini", "", ""), "created")
	if body["error"] != "herdr: unknown agent kind" || body["pane"] != nil {
		t.Fatalf("failed start: %v", body)
	}
	calls := f.takeCalls()
	if len(calls) != 3 || calls[2] != `pane.close {"pane_id":"w3:p1"}` {
		t.Errorf("the new pane must close: %v", calls)
	}
}

func TestAgentAvailable(t *testing.T) {
	bin, tools := t.TempDir(), t.TempDir()
	write := func(dir, name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
		return p
	}
	// The fake mise knows 2 active tools: shimmed and launched.
	write(tools, "shimmed", "")
	write(tools, "launched", "")
	mise := write(bin, "mise", "#!/bin/sh\ncase \"$1 $2\" in\n"+
		"\"which shimmed\"|\"which launched\") echo "+tools+"/$2 ;;\n"+
		"*) echo \"mise ERROR $2 is not currently active\" >&2; exit 1 ;;\nesac\n")
	for _, shim := range []string{"shimmed", "inactive"} {
		if err := os.Symlink(mise, filepath.Join(bin, shim)); err != nil {
			t.Fatal(err)
		}
	}
	write(bin, "plain", "#!/bin/sh\nexec node /opt/plain/cli.js \"$@\"\n")
	launcher := "#!/bin/bash\nexport MISE_MINIMUM_RELEASE_AGE=0\nmise use -g --quiet \"%s\" || exit 1\nexec mise x \"%s\" -- \"%s\" \"$@\"\n"
	write(bin, "launched", strings.ReplaceAll(launcher, "%s", "launched"))
	write(bin, "notyet", strings.ReplaceAll(launcher, "%s", "notyet"))
	write(bin, "binary", "\x7fELF")
	t.Setenv("PATH", bin)

	cases := map[string]bool{
		"plain": true, "binary": true, "shimmed": true, "launched": true,
		"inactive": false, "notyet": false, "missing": false,
	}
	for kind, want := range cases {
		if got := agentAvailable(context.Background(), kind, t.TempDir()); got != want {
			t.Errorf("agentAvailable(%q) = %v, want %v", kind, got, want)
		}
	}
}

func TestHomeRelative(t *testing.T) {
	cases := []struct{ dir, home, want string }{
		{"/home/u/Code/flux", "/home/u", "~/Code/flux"},
		{"/home/u", "/home/u", "~"},
		{"/home/user2/x", "/home/u", "/home/user2/x"},
		{"/srv/x", "/home/u", "/srv/x"},
		{"", "/home/u", ""},
		{"/x", "/", "/x"},
	}
	for _, c := range cases {
		if got := homeRelative(c.dir, c.home); got != c.want {
			t.Errorf("homeRelative(%q, %q) = %q, want %q", c.dir, c.home, got, c.want)
		}
	}
}

func TestHerdrClose(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude"}}
	d.herdrTerms = []HerdrTerminal{{Pane: "w1:p2"}}
	if body := createdBody(t, d.herdrClose(dev, "w1:p1"), "closed"); body["error"] != errHerdrControlOff {
		t.Fatalf("control off: %v", body)
	}
	d.cfg.HerdrControl = true
	if body := createdBody(t, d.herdrClose(dev, "w1:p2"), "closed"); body["error"] != "No agent runs in w1:p2" {
		t.Errorf("a terminal needs herdr_terminals: %v", body)
	}
	if body := createdBody(t, d.herdrClose(dev, "w1:p1"), "closed"); body["error"] != nil || body["pane"] != "w1:p1" {
		t.Errorf("close: %v", body)
	}
	d.cfg.HerdrTerminals = true
	if body := createdBody(t, d.herdrClose(dev, "w1:p2"), "closed"); body["error"] != nil {
		t.Errorf("close a terminal: %v", body)
	}
	if calls := f.takeCalls(); strings.Join(calls, "\n") != `pane.close {"pane_id":"w1:p1"}`+"\n"+`pane.close {"pane_id":"w1:p2"}` {
		t.Errorf("close calls %v", calls)
	}
}

func TestAgentName(t *testing.T) {
	cases := []struct {
		kind, cwd string
		try       int
		want      string
	}{
		{"claude", "/home/u/Code/omarchy-flux", 0, "claude-omarchy-flux"},
		{"claude", "/home/u/Code/omarchy-flux", 1, "claude-omarchy-flux-2"},
		{"codex", "/home/u/My Project!", 0, "codex-my-project"},
		{"claude", "/", 0, "claude"},
		{"claude", "/home/u/a-very-long-folder-name-for-a-project", 0, "claude-a-very-long-folder-name-f"},
		{"claude", "/home/u/a-very-long-folder-name-for-a-project", 2, "claude-a-very-long-folder-name-3"},
		{"9x", "/p", 0, "agent-9x-p"},
	}
	for _, c := range cases {
		got := agentName(c.kind, c.cwd, c.try)
		if got != c.want || len(got) > 32 {
			t.Errorf("agentName(%q, %q, %d) = %q, want %q", c.kind, c.cwd, c.try, got, c.want)
		}
	}
}

func sentBody(t *testing.T, p *proto.Packet) map[string]any {
	t.Helper()
	var body map[string]any
	if err := p.Decode(&body); err != nil {
		t.Fatal(err)
	}
	if p.Type != proto.TypeFluxHerdr || body["kind"] != "sent" {
		t.Fatalf("packet %s %v", p.Type, body)
	}
	return body
}

func TestHerdrReplies(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "blocked"}}

	// Replies are off by default.
	if body := sentBody(t, d.herdrKeys(dev, "w1:p1", []string{"1"})); body["error"] != errHerdrControlOff {
		t.Fatalf("control off: %v", body)
	}
	d.cfg.HerdrControl = true

	refused := []struct {
		name string
		p    *proto.Packet
		want string
	}{
		{"unknown pane", d.herdrKeys(dev, "w1:p9", []string{"1"}), "No agent runs in w1:p9"},
		{"key not allowed", d.herdrKeys(dev, "w1:p1", []string{"ctrl+c"}), `The key "ctrl+c" is not allowed`},
		{"no keys", d.herdrKeys(dev, "w1:p1", nil), "Send 1 to 8 keys"},
		{"too many keys", d.herdrKeys(dev, "w1:p1", strings.Split("1 2 3 4 5 6 7 8 9", " ")), "Send 1 to 8 keys"},
		{"empty text", d.herdrPrompt(dev, "w1:p1", " \x1b\x07 \n"), "The text is empty"},
		{"long text", d.herdrPrompt(dev, "w1:p1", strings.Repeat("x", herdrMaxPrompt+1)), "The text is longer than 16 KB"},
	}
	for _, c := range refused {
		if body := sentBody(t, c.p); body["error"] != c.want {
			t.Errorf("%s: %v", c.name, body)
		}
	}
	if calls := f.takeCalls(); len(calls) != 0 {
		t.Fatalf("a refused reply must not reach herdr: %v", calls)
	}

	body := sentBody(t, d.herdrKeys(dev, "w1:p1", []string{"2", "enter"}))
	if body["error"] != nil || body["action"] != "keys" || body["pane"] != "w1:p1" {
		t.Errorf("keys: %v", body)
	}
	if calls := f.takeCalls(); len(calls) != 1 || calls[0] != `agent.send_keys {"keys":["2","enter"],"target":"w1:p1"}` {
		t.Errorf("keys calls %v", calls)
	}

	body = sentBody(t, d.herdrPrompt(dev, "w1:p1", "  Run the tests\r\nagain\x1b[A  "))
	if body["error"] != nil || body["action"] != "prompt" {
		t.Errorf("prompt: %v", body)
	}
	if calls := f.takeCalls(); len(calls) != 1 || calls[0] != `agent.prompt {"target":"w1:p1","text":"Run the tests\nagain[A"}` {
		t.Errorf("prompt calls %v", calls)
	}

	// A blocked agent gets the text as typed input and Enter.
	f.mu.Lock()
	f.replies = map[string]string{"agent.prompt": `"error":{"code":"agent_blocked","message":"agent w1:p1 is blocked"}`}
	f.mu.Unlock()
	body = sentBody(t, d.herdrPrompt(dev, "w1:p1", "Use port\n8080"))
	if body["error"] != nil {
		t.Errorf("blocked prompt: %v", body)
	}
	calls := f.takeCalls()
	if len(calls) != 2 || calls[1] != `pane.send_input {"keys":["enter"],"pane_id":"w1:p1","text":"Use port 8080"}` {
		t.Errorf("blocked prompt calls %v", calls)
	}

	f.mu.Lock()
	f.replies = map[string]string{"agent.send_keys": `"error":{"code":"agent_not_ready","message":"agent w1:p1 is not an active named agent"}`}
	f.mu.Unlock()
	if body := sentBody(t, d.herdrKeys(dev, "w1:p1", []string{"esc"})); body["error"] != "The agent in w1:p1 is not ready for input" {
		t.Errorf("herdr error: %v", body)
	}
}

func TestHerdrViewControl(t *testing.T) {
	d := herdrDaemon(context.Background(), "")
	if d.herdrViewLocked().Control {
		t.Fatal("control is off by default")
	}
	d.cfg.HerdrControl = true
	if !d.herdrViewLocked().Control {
		t.Fatal("herdr_control turns control on")
	}
	d.cfg.Herdr = false
	if d.herdrViewLocked().Control {
		t.Fatal("control needs herdr sync")
	}
}

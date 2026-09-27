package core

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"path/filepath"
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
// reply. replies holds that member for other methods, and the default is
// an ok result. calls records each other request as the method and its
// params. push sends an event to each subscription connection.
type fakeHerdr struct {
	path string

	mu       sync.Mutex
	snapshot string
	read     string
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
		f.calls = append(f.calls, req.Method+" "+string(req.Params))
	default:
		result = `"result":{"type":"ok"}`
		if r, ok := f.replies[req.Method]; ok {
			result = r
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
		{"blanks before a reset", "\x1b[48;5;2m bg \x1b[0m   \x1b[0m  ", "\x1b[48;5;2m bg\x1b[0m\x1b[0m"},
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
	body := outputBody(t, d.readHerdr("w1:p1", 20, true))
	if body["format"] != "ansi" || body["text"] != "\x1b[1mok\x1b[0m\nnext" {
		t.Errorf("body %q", body)
	}
	calls := f.takeCalls()
	if len(calls) != 1 || !strings.Contains(calls[0], `"format":"ansi"`) || !strings.Contains(calls[0], `"strip_ansi":false`) {
		t.Errorf("calls %v", calls)
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

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
	"unicode/utf8"

	"flux/internal/config"
	"flux/internal/herdr"
	"flux/internal/lan"
	"flux/internal/proto"
)

func TestHerdrAgents(t *testing.T) {
	snap := herdr.Snapshot{
		Workspaces: []herdr.Workspace{
			{ID: "wB", Label: "flux", Number: 1},
			{ID: "wA", Label: "cli\u202eamp", Number: 2},
		},
		Agents: []herdr.Agent{
			{PaneID: "wA:p1", WorkspaceID: "wA", Agent: "claude", Status: "idle", Cwd: "/home/u/Code/cli\u2066amp"},
			{PaneID: "wZ:p1", WorkspaceID: "wZ", Agent: "codex", Status: "", Cwd: "/"},
			{PaneID: "", WorkspaceID: "wB", Agent: "claude", Status: "working"},
			{PaneID: "wB:p2", WorkspaceID: "wB", Agent: "claude", Status: "blocked",
				Cwd: "/home/u/Code/flux", ForegroundCwd: "/home/u/Code/flux/android", Title: "Agents\u202e\u009b screen\n"},
		},
	}
	// A title, a project, and a label get the same filter as the output,
	// so a bidirectional control character cannot change the order of a
	// row on the phone.
	got := herdrAgents(snap)
	want := []HerdrAgent{
		{Pane: "wB:p2", Agent: "claude", Status: "blocked", Title: "Agents\ufffd screen ", Project: "android", Workspace: "flux"},
		{Pane: "wA:p1", Agent: "claude", Status: "idle", Project: "cli\ufffdamp", Workspace: "cli\ufffdamp"},
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

	// hold, when it is set, keeps each agent.read until it closes. held
	// counts the reads that wait for it.
	hold chan struct{}
	held int
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
	hold := f.hold
	if hold != nil && req.Method == "agent.read" {
		f.held++
	}
	f.mu.Unlock()
	if hold != nil && req.Method == "agent.read" {
		<-hold
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
	case "events.subscribe":
		f.subs = append(f.subs, conn)
		f.subCalls = append(f.subCalls, string(req.Params))
		f.mu.Unlock()
		_, _ = conn.Write([]byte(`{"id":"` + req.ID + `","result":{"type":"subscription_started"}}` + "\n"))
		return
	default:
		result = `"result":{"type":"ok"}`
		if r, ok := f.replies[req.Method]; ok {
			result = r
		}
		if q := f.queue[req.Method]; len(q) > 0 {
			result, f.queue[req.Method] = q[0], q[1:]
		}
		f.calls = append(f.calls, req.Method+" "+string(req.Params))
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

// holdReads makes the next agent.read calls wait until the returned
// channel closes.
func (f *fakeHerdr) holdReads() chan struct{} {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hold, f.held = make(chan struct{}), 0
	return f.hold
}

func (f *fakeHerdr) heldReads() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.held
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

	// A new agent pane needs a new subscription for its status. The
	// event also removes the history of an earlier agent in the pane.
	d.mu.Lock()
	d.herdrHistory = map[string]agentHistory{"w1:p2": {lines: []string{"old"}, agent: "codex"}}
	d.mu.Unlock()
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
	d.mu.Lock()
	_, kept := d.herdrHistory["w1:p2"]
	d.mu.Unlock()
	if kept {
		t.Error("a new agent must not get the history of the pane")
	}

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
		{"a line break ends a CSI", "\x1b[\n\x1bm", "\n"},
		{"a CSI cut by a line break goes", "a\x1b[1\n2\x1bmb", "a\n2b"},
		{"an ESC in a CSI ends it", "a\x1b[1\x1b[2mb", "a\x1b[2mb"},
		{"a private CSI with m goes", "\x1b[>4;2mx\x1b[?25h", "x"},
		{"an ESC keeps the line break after it", "a\x1b\nb", "a\nb"},
		{"DCS and APC strings go", "a\x1bPq#0;2\x1b\\b\x1b_note\x07c", "abc"},
		{"an ESC ends a string", "\x1b]0;title\x1b[1mRed", "\x1b[1mRed"},
		{"C1 controls go", "a\u0085b\u009bc", "abc"},
		{"direction controls show a mark", "ls \u202eexe.sh\u202c", "ls \ufffdexe.sh\ufffd"},
		{"isolates and marks show a mark", "\u2066x\u2069\u200e\u200f\u061c", "\ufffdx\ufffd\ufffd\ufffd\ufffd"},
		{"line separators show a mark", "a\u2028b\u2029", "a\ufffdb\ufffd"},
		{"broken UTF-8 shows a mark", "a\xffb", "a\ufffdb"},
	}
	for _, c := range cases {
		if got := cleanANSI(c.in); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestCleanPlain(t *testing.T) {
	if got := cleanPlain("a\u202eb\u0085c  \r\n\x07d\x1b\te\u200f"); got != "a\ufffdbc\nd\te\ufffd" {
		t.Errorf("cleanPlain: %q", got)
	}
}

// The error of an agent that did not start has the last line of its pane,
// with the characters that textRune removes or marks.
func TestPaneLastLine(t *testing.T) {
	if got := paneLastLine("$ claude\r\nok \u202eexe.sh\u202c \u0085done\t\x1b\r\n"); got != "ok \ufffdexe.sh\ufffd done" {
		t.Errorf("paneLastLine: %q", got)
	}
}

func TestTrimStyledEndSkipsBrokenSequences(t *testing.T) {
	for in, want := range map[string]string{
		"\x1bm":         "\x1bm",
		"a\x1b[1\x1bm ": "a",
		"a\x1b":         "a",
		"\x1b[1mb  ":    "\x1b[1mb",
	} {
		if got := trimStyledEnd(in); got != want {
			t.Errorf("trimStyledEnd(%q) = %q, want %q", in, got, want)
		}
	}
}

// FuzzCleanANSI checks that cleanANSI does not panic and that its output
// has only SGR sequences, line breaks, tabs, and printable characters.
func FuzzCleanANSI(f *testing.F) {
	for _, seed := range []string{
		"\x1b[\n\x1bm", "a\x1b[1\n2\x1bmb", "\x1b[1m\x1b[48;5;2m x \x1b[0m  ", "\x1b]8;;u\x07l\x1b]8;;\x1b\\",
		"\x1b[38:2::1:2:3m\u202e\u0085\x1bPq\x1b\\", "\x1b[>4;2m\x1b(B\x1b", "\xff\xfe\x1b[",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, in string) {
		out := cleanANSI(in)
		if !utf8.ValidString(out) {
			t.Fatalf("cleanANSI(%q) = %q is not UTF-8", in, out)
		}
		rest := sgr.ReplaceAllString(out, "")
		for _, r := range rest {
			if r != '\n' && r != '\t' && textRune(r) != r {
				t.Fatalf("cleanANSI(%q) = %q keeps %U", in, out, r)
			}
		}
	})
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
	idle := "● Old answer\n\n\x1b[1m● Tests pass\x1b[0m\n❯ \u00a0\n  status"
	if body["text"] != idle {
		t.Errorf("idle: %q, want %q", body["text"], idle)
	}
	if calls := f.takeCalls(); len(calls) != 2 {
		t.Errorf("idle calls %v", calls)
	}

	// A read soon after uses the same history, so herdr does not scroll
	// the agent again.
	body = outputBody(t, d.readHerdr("w1:p1", 1000, true))
	if body["text"] != idle {
		t.Errorf("second idle read: %q, want %q", body["text"], idle)
	}
	if calls := f.takeCalls(); len(calls) != 1 || !strings.Contains(calls[0], `"format":"ansi"`) {
		t.Errorf("second idle read calls %v", calls)
	}

	// Working: the new status makes the history old. herdr refuses the
	// history, so the last history stays, and the newer screen replaces
	// its end.
	d.setHerdr(true, herdrLive{Agents: []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "working"}}})
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"● Tests pass\n● New step\n❯\n  status","truncated":false}}`
	f.readText = `"error":{"code":"agent_not_idle","message":"cannot read 1000 lines while w1:p1 is working"}`
	body = outputBody(t, d.readHerdr("w1:p1", 1000, true))
	if want := "● Old answer\n\n● Tests pass\n● New step\n❯\n  status"; body["text"] != want || body["error"] != nil {
		t.Errorf("working: %q, want %q", body["text"], want)
	}
	if calls := f.takeCalls(); len(calls) != 2 {
		t.Errorf("working calls %v", calls)
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

func TestHerdrHistoryOfANewAgent(t *testing.T) {
	d := herdrDaemon(context.Background(), "")
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "idle"}, {Pane: "w1:p2", Agent: "codex", Status: "idle"}}
	d.herdrHistory = map[string]agentHistory{
		"w1:p1": {lines: []string{"old"}, agent: "claude", at: time.Now()},
		"w1:p2": {lines: []string{"old"}, agent: "codex", at: time.Now()},
	}
	d.setHerdr(true, herdrLive{Agents: []HerdrAgent{{Pane: "w1:p1", Agent: "codex", Status: "idle"}, {Pane: "w1:p2", Agent: "codex", Status: "working"}}})
	if _, ok := d.herdrHistory["w1:p1"]; ok {
		t.Error("an agent of another kind must not get the history of the pane")
	}
	if h := d.herdrHistory["w1:p2"]; len(h.lines) != 1 || !h.at.IsZero() {
		t.Errorf("a new status must keep the history and make it old: %+v", h)
	}

	ev := herdr.Event{Name: "pane_agent_detected", Data: json.RawMessage(`{"pane_id":"w1:p2","agent":"codex"}`)}
	if p := detectedPane(ev); p != "w1:p2" {
		t.Errorf("detected pane %q", p)
	}
	ev.Name = "pane_agent_status_changed"
	if p := detectedPane(ev); p != "" {
		t.Errorf("a status event names no new agent: %q", p)
	}
}

func TestReadHerdrOnce(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "working"}}
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"step 1","truncated":false}}`
	sent := make(chan *proto.Packet, 8)
	send := func(p *proto.Packet) { sent <- p }
	answers := func(n int) {
		t.Helper()
		for range n {
			select {
			case p := <-sent:
				if body := outputBody(t, p); body["text"] != "step 1" {
					t.Errorf("answer %v", body)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("a read got no answer")
			}
		}
		select {
		case p := <-sent:
			t.Fatalf("an extra answer: %v", p)
		case <-time.After(100 * time.Millisecond):
		}
	}

	// 3 reads on one link make 1 herdr call and get 1 answer. A read on
	// another link runs on its own.
	link := &lan.Link{}
	hold := f.holdReads()
	for range 3 {
		d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	}
	d.readHerdrOnce(dev, &lan.Link{}, "w1:p1", 1, false, send)
	waitFor(t, "2 reads", func() bool { return f.heldReads() == 2 })
	close(hold)
	answers(2)
	if calls := f.takeCalls(); len(calls) != 2 {
		t.Errorf("read calls %v", calls)
	}

	// Reads with other line counts and formats do not run at the same
	// time. The reads that came during the read get 1 new read with the
	// values of the newest read.
	hold = f.holdReads()
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	waitFor(t, "the read", func() bool { return f.heldReads() == 1 })
	for lines := 2; lines <= 1000; lines++ {
		d.readHerdrOnce(dev, link, "w1:p1", lines, lines%2 == 0, send)
	}
	d.readHerdrOnce(dev, link, "w1:p1", 7, true, send)
	close(hold)
	answers(2)
	// An ANSI read of an agent also reads the plain history.
	calls := f.takeCalls()
	if len(calls) < 2 || !strings.Contains(calls[0], `"lines":1,`) || !strings.Contains(calls[1], `"format":"ansi"`) {
		t.Errorf("read calls with other line counts %v", calls)
	}
	for _, c := range calls[1:] {
		if !strings.Contains(c, `"lines":7,`) {
			t.Errorf("a read call without the values of the newest read: %s", c)
		}
	}

	// A pane that fluxd does not know gets its answer at once, with no
	// herdr call and no read that runs.
	var unknown *proto.Packet
	d.readHerdrOnce(dev, link, "w9:p9", 1, false, func(p *proto.Packet) { unknown = p })
	if unknown == nil || outputBody(t, unknown)["error"] != "No agent runs in w9:p9" {
		t.Errorf("answer for an unknown pane: %v", unknown)
	}
	if calls := f.takeCalls(); len(calls) != 0 {
		t.Errorf("herdr calls for an unknown pane: %v", calls)
	}

	// A new status during the read makes the answer old, so the reads
	// that came get a new read.
	hold = f.holdReads()
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	waitFor(t, "the read", func() bool { return f.heldReads() == 1 })
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	d.mu.Lock()
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "idle"}}
	d.mu.Unlock()
	close(hold)
	answers(2)
	if calls := f.takeCalls(); len(calls) != 2 {
		t.Errorf("read calls after a new status %v", calls)
	}

	// A read that comes while fluxd sends the answer can be newer than
	// the answer, so it gets a new read.
	sending, release := make(chan struct{}), make(chan struct{})
	first := true
	slow := func(p *proto.Packet) {
		if first {
			first = false
			close(sending)
			<-release
		}
		sent <- p
	}
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, slow)
	<-sending
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, slow)
	close(release)
	answers(2)
	if calls := f.takeCalls(); len(calls) != 2 {
		t.Errorf("read calls after a read during the send %v", calls)
	}
	d.mu.Lock()
	running := len(d.herdrJobs.reads)
	d.mu.Unlock()
	if running != 0 {
		t.Errorf("%d reads stay", running)
	}
}

// readCalls returns the number of agent.read calls in calls.
func readCalls(calls []string) int {
	n := 0
	for _, c := range calls {
		if strings.HasPrefix(c, "agent.read ") {
			n++
		}
	}
	return n
}

func TestReadHerdrOnceChecks(t *testing.T) {
	f := newFakeHerdr(t)
	d := herdrDaemon(context.Background(), f.path)
	d.cfg.HerdrControl = true
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "working"}}
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"step 1","truncated":false}}`
	sent := make(chan *proto.Packet, 8)
	send := func(p *proto.Packet) { sent <- p }
	link := &lan.Link{}
	answer := func() map[string]any {
		t.Helper()
		select {
		case p := <-sent:
			return outputBody(t, p)
		case <-time.After(3 * time.Second):
			t.Fatal("a read got no answer")
		}
		return nil
	}
	noAnswer := func() {
		t.Helper()
		select {
		case p := <-sent:
			t.Fatalf("an extra answer: %v", p)
		case <-time.After(100 * time.Millisecond):
		}
	}
	idle := func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return len(d.herdrJobs.reads) == 0
	}

	// A reply during a read makes its answer old, also when the status
	// does not change, as in a terminal. So the read that came during it
	// gets a new read.
	hold := f.holdReads()
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	waitFor(t, "the read", func() bool { return f.heldReads() == 1 })
	if body := sentBody(t, d.herdrKeys(dev, "w1:p1", []string{"esc"})); body["error"] != nil {
		t.Fatalf("keys: %v", body)
	}
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	close(hold)
	answer()
	answer()
	noAnswer()
	if n := readCalls(f.takeCalls()); n != 2 {
		t.Errorf("%d read calls after a reply, want 2", n)
	}

	// A reply without a read that waits makes no new read.
	hold = f.holdReads()
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	waitFor(t, "the read", func() bool { return f.heldReads() == 1 })
	sentBody(t, d.herdrKeys(dev, "w1:p1", []string{"esc"}))
	close(hold)
	answer()
	noAnswer()
	if n := readCalls(f.takeCalls()); n != 1 {
		t.Errorf("%d read calls after a reply with no read that waits, want 1", n)
	}

	// An unpair during the read stops the answer and the reads that wait.
	hold = f.holdReads()
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	waitFor(t, "the read", func() bool { return f.heldReads() == 1 })
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	d.mu.Lock()
	dev.Paired = false
	d.mu.Unlock()
	close(hold)
	waitFor(t, "the end of the read", idle)
	noAnswer()
	if n := readCalls(f.takeCalls()); n != 1 {
		t.Errorf("%d read calls after an unpair, want 1", n)
	}

	// When the user turns herdr off during the read, the text does not go
	// out.
	d.mu.Lock()
	dev.Paired = true
	d.mu.Unlock()
	hold = f.holdReads()
	d.readHerdrOnce(dev, link, "w1:p1", 1, false, send)
	waitFor(t, "the read", func() bool { return f.heldReads() == 1 })
	d.mu.Lock()
	d.cfg.Herdr = false
	d.mu.Unlock()
	close(hold)
	if body := answer(); body["error"] != errHerdrDisabled || body["text"] != nil {
		t.Errorf("herdr off during the read: %v", body)
	}
	waitFor(t, "the end of the read", idle)

	// A panic during the answer sends an error, so the phone does not
	// wait. The next read of the pane runs.
	d.mu.Lock()
	d.cfg.Herdr = true
	d.mu.Unlock()
	panicked := false
	d.readHerdrOnce(dev, link, "w1:p1", 1, true, func(p *proto.Packet) {
		if !panicked {
			panicked = true
			panic("bad answer")
		}
		sent <- p
	})
	if body := answer(); body["error"] != "fluxd could not read the pane" || body["format"] != "ansi" || body["pane"] != "w1:p1" {
		t.Errorf("answer after a panic: %v", body)
	}
	waitFor(t, "the end of the read", idle)
	d.readHerdrOnce(dev, link, "w1:p1", 1, true, send)
	if body := answer(); body["text"] != "step 1" {
		t.Errorf("read after a panic: %v", body)
	}
}

func TestHerdrRecover(t *testing.T) {
	d := herdrDaemon(context.Background(), "")
	failed := false
	func() {
		defer d.herdrRecover("keys", func() { failed = true })
		panic("bad reply")
	}()
	if !failed {
		t.Error("a panic must send an error")
	}
	failed = false
	func() {
		defer d.herdrRecover("keys", func() { failed = true })
	}()
	if failed {
		t.Error("an answer without a panic must not send an error")
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
			{ID: "wA", Label: "web\u200f", Number: 1, ActiveTab: "wA:t1"},
		},
		Panes: []herdr.Pane{
			{ID: "wB:p1", WorkspaceID: "wB", TabID: "wB:t1", Cwd: "/src/flux"},
			{ID: "wB:p2", WorkspaceID: "wB", TabID: "wB:t2", Cwd: "/src/flux", ForegroundCwd: "/src/flux/android", Title: "gradle\u2067"},
			{ID: "wA:p1", WorkspaceID: "wA", TabID: "wA:t1", Cwd: "/src/web", Title: "u@host:~/src/web"},
		},
		Agents: []herdr.Agent{{PaneID: "wB:p1", WorkspaceID: "wB", Agent: "claude"}},
	}
	terms := herdrTerminals(snap)
	want := []HerdrTerminal{
		{Pane: "wA:p1", Title: "u@host:~/src/web", Project: "web", Workspace: "web\ufffd"},
		{Pane: "wB:p2", Title: "gradle\ufffd", Project: "android", Workspace: "flux"},
	}
	if !slices.Equal(terms, want) {
		t.Errorf("terminals %+v", terms)
	}
	places := herdrWorkspaces(snap)
	wantPlaces := []HerdrWorkspace{{ID: "wA", Label: "web\ufffd", Cwd: "/src/web"}, {ID: "wB", Label: "flux", Cwd: "/src/flux/android"}}
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
	if len(d.herdrJobs.creating) != 0 {
		t.Fatalf("a refused create must end: %v", d.herdrJobs.creating)
	}

	// One start runs at a time for each device.
	d.herdrJobs.creating[dev.ID] = true
	if body := createdBody(t, d.herdrCreate(dev, "agent", "claude", dir, ""), "created"); body["error"] != errHerdrCreateBusy {
		t.Errorf("second start: %v", body)
	}
	if !d.herdrJobs.creating[dev.ID] {
		t.Error("a refused second start must not end the first start")
	}
	delete(d.herdrJobs.creating, dev.ID)

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
		{"not paired", d.herdrKeys(&Device{ID: "phone2"}, "w1:p1", []string{"1"}), errHerdrNotPaired},
		{"empty text", d.herdrPrompt(dev, "w1:p1", " \x1b\x07 \n", false), "The text is empty"},
		{"long text", d.herdrPrompt(dev, "w1:p1", strings.Repeat("x", herdrMaxPrompt+1), false), "The text is longer than 16 KB"},
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

	body = sentBody(t, d.herdrPrompt(dev, "w1:p1", "  Run the tests\r\nagain\x1b[A  ", false))
	if body["error"] != nil || body["action"] != "prompt" {
		t.Errorf("prompt: %v", body)
	}
	if calls := f.takeCalls(); len(calls) != 1 || calls[0] != `agent.prompt {"target":"w1:p1","text":"Run the tests\nagain[A"}` {
		t.Errorf("prompt calls %v", calls)
	}

	// A blocked agent refuses a prompt, and fluxd does not type the text
	// in its dialog. A digit or Enter in the text can select a choice.
	f.mu.Lock()
	f.replies = map[string]string{
		"agent.prompt": `"error":{"code":"agent_blocked","message":"agent w1:p1 is blocked"}`,
		"agent.get":    `"result":{"type":"agent_info","agent":{"pane_id":"w1:p1","agent":"claude","agent_status":"blocked"}}`,
	}
	f.mu.Unlock()
	body = sentBody(t, d.herdrPrompt(dev, "w1:p1", "1 no, use git clean", false))
	if body["error"] != string(errHerdrBlocked) || body["code"] != "blocked" {
		t.Errorf("blocked prompt: %v", body)
	}
	if calls := f.takeCalls(); len(calls) != 1 || !strings.HasPrefix(calls[0], "agent.prompt ") {
		t.Errorf("blocked prompt calls %v", calls)
	}

	// An answer goes to a blocked agent as typed input and Enter.
	body = sentBody(t, d.herdrPrompt(dev, "w1:p1", "Use port\n8080", true))
	if body["error"] != nil || body["code"] != nil {
		t.Errorf("answer: %v", body)
	}
	calls := f.takeCalls()
	if len(calls) != 3 || calls[1] != `agent.get {"target":"w1:p1"}` ||
		calls[2] != `pane.send_input {"keys":["enter"],"pane_id":"w1:p1","text":"Use port 8080"}` {
		t.Errorf("answer calls %v", calls)
	}

	// An agent that does not wait now gets no typed input.
	f.mu.Lock()
	f.replies["agent.get"] = `"result":{"type":"agent_info","agent":{"pane_id":"w1:p1","agent":"claude","agent_status":"idle"}}`
	f.mu.Unlock()
	body = sentBody(t, d.herdrPrompt(dev, "w1:p1", "Use port 8080", true))
	if body["error"] != "The agent does not wait for an answer now. Send the text again." {
		t.Errorf("answer to an agent that does not wait: %v", body)
	}
	if calls := f.takeCalls(); len(calls) != 2 {
		t.Errorf("answer calls to an agent that does not wait %v", calls)
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

// TestHerdrRequestNumber checks that the answers sent, created, and closed
// carry the request number of the packet from the phone, and that an
// answer to a packet without a number has none.
func TestHerdrRequestNumber(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := newFakeHerdr(t)
	d := herdrDaemon(ctx, f.path)
	d.cfg.HerdrControl = true
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude"}}
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	answers := make(chan map[string]any, 16)
	go phone.Receive(func(p *proto.Packet) {
		if f := p.Fields(); p.Type == proto.TypeFluxHerdr && f["kind"] != "state" {
			answers <- f
		}
	})
	cases := []struct {
		body map[string]any
		kind string
	}{
		{map[string]any{"kind": "keys", "pane": "w1:p1", "keys": []string{"1"}, "request": 7}, "sent"},
		{map[string]any{"kind": "prompt", "pane": "w1:p1", "text": "Run the tests", "request": 8}, "sent"},
		{map[string]any{"kind": "input", "pane": "w1:p9", "text": "ls", "request": 9}, "sent"},
		{map[string]any{"kind": "create", "what": "agent", "agent": "none", "request": 10}, "created"},
		{map[string]any{"kind": "close", "pane": "w1:p1", "request": 11}, "closed"},
		{map[string]any{"kind": "keys", "pane": "w1:p1", "keys": []string{"2"}}, "sent"},
		{map[string]any{"kind": "keys", "pane": "w1:p1", "keys": []string{"3"}, "request": "12"}, "sent"},
	}
	for _, c := range cases {
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, c.body))
		var got map[string]any
		select {
		case got = <-answers:
		case <-time.After(5 * time.Second):
			t.Fatalf("%v: no answer within 5 seconds", c.body)
		}
		want, numbered := c.body["request"].(int)
		switch {
		case got["kind"] != c.kind:
			t.Errorf("%v: answer %v", c.body, got)
		case numbered && got["request"] != float64(want):
			t.Errorf("%v: answer has the request %v", c.body, got["request"])
		case !numbered && got["request"] != nil:
			t.Errorf("%v: answer has the request %v, want none", c.body, got["request"])
		}
	}
}

// TestHerdrSendLimit checks that at most herdrMaxSends keys, prompt,
// input, and close jobs run for each device, and that a pane that fluxd
// does not know takes no job.
func TestHerdrSendLimit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := newFakeHerdr(t)
	d := herdrDaemon(ctx, f.path)
	d.cfg.HerdrControl = true
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude"}}
	dev, tablet := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}, &Device{ID: "tablet", Paired: true}
	for range herdrMaxSends {
		if got := d.startHerdrSend(dev, "w1:p1"); got != herdrSendStarted {
			t.Fatalf("a job under the limit: %d", got)
		}
	}
	if got := d.startHerdrSend(dev, "w1:p1"); got != herdrSendBusy {
		t.Fatalf("a job over the limit: %d", got)
	}
	if got := d.startHerdrSend(tablet, "w1:p1"); got != herdrSendStarted {
		t.Fatalf("a job of another device: %d", got)
	}
	d.endHerdrSend(tablet)
	if got := d.startHerdrSend(dev, "w9:p9"); got != herdrSendUnknown {
		t.Fatalf("a job for an unknown pane: %d", got)
	}

	desk, phone, _, _ := linkPair(t, ctx)
	answers := make(chan map[string]any, 16)
	go phone.Receive(func(p *proto.Packet) {
		if f := p.Fields(); p.Type == proto.TypeFluxHerdr && f["kind"] != "state" {
			answers <- f
		}
	})
	answer := func(body map[string]any) map[string]any {
		t.Helper()
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, body))
		select {
		case got := <-answers:
			return got
		case <-time.After(5 * time.Second):
			t.Fatalf("%v: no answer within 5 seconds", body)
		}
		return nil
	}
	// A device with herdrMaxSends jobs gets the busy answer at once.
	if got := answer(map[string]any{"kind": "keys", "pane": "w1:p1", "keys": []string{"1"}, "request": 5}); got["kind"] != "sent" || got["error"] != errHerdrBusy || got["request"] != 5.0 {
		t.Errorf("keys while busy: %v", got)
	}
	if got := answer(map[string]any{"kind": "close", "pane": "w1:p1", "request": 6}); got["kind"] != "closed" || got["error"] != errHerdrBusy || got["request"] != 6.0 {
		t.Errorf("close while busy: %v", got)
	}
	// A pane that fluxd does not know gets its answer also while busy.
	if got := answer(map[string]any{"kind": "prompt", "pane": "w9:p9", "text": "hi", "request": 7}); got["error"] != "No agent runs in w9:p9" || got["request"] != 7.0 {
		t.Errorf("prompt to an unknown pane: %v", got)
	}
	if calls := f.takeCalls(); len(calls) != 0 {
		t.Errorf("herdr calls while busy: %v", calls)
	}
	for range herdrMaxSends {
		d.endHerdrSend(dev)
	}
	if got := answer(map[string]any{"kind": "keys", "pane": "w1:p1", "keys": []string{"1"}, "request": 8}); got["error"] != nil {
		t.Errorf("keys after the jobs ended: %v", got)
	}
	waitFor(t, "the end of the job", func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return len(d.herdrJobs.sending) == 0
	})
}

// TestUnsavedHerdrSettings checks that herdr_control and herdr_terminals
// do not turn on when config.toml cannot keep them, because each lets a
// paired device run commands on this computer.
func TestUnsavedHerdrSettings(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	// config.toml cannot be written, because the flux folder is a file.
	if err := os.WriteFile(filepath.Join(dir, "flux"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	d := herdrDaemon(context.Background(), "")
	for _, key := range []string{"herdrControl", "herdrTerminals"} {
		if err := d.setSetting(key, true); err == nil || !strings.Contains(err.Error(), "did not change") {
			t.Errorf("%s: error %v", key, err)
		}
	}
	if d.cfg.HerdrControl || d.cfg.HerdrTerminals {
		t.Fatalf("a herdr switch is on after the error: %+v", d.cfg)
	}
}

package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"flux/internal/herdr"
	"flux/internal/lan"
	"flux/internal/proto"
)

// setReply makes each call of method answer with the result member.
func (f *fakeHerdr) setReply(method, result string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.replies == nil {
		f.replies = map[string]string{}
	}
	f.replies[method] = result
}

// fakeBridge writes a fake herdr terminal-session bridge. body is the
// shell script that plays the bridge after its first line.
func fakeBridge(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fake-herdr")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

const bridgeFrames = `
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"aGVsbG8="}'
echo '{"type":"terminal.closed","reason":"detached"}'
`

// bridgeEcho prints one frame per stdin line, so a test can see which
// commands fluxd wrote and in which order.
const bridgeEcho = `
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"cmVhZHk="}'
n=1
while IFS= read -r line; do
  n=$((n+1))
  b=$(printf %s "$line" | base64 | tr -d '\n')
  printf '{"type":"terminal.frame","seq":%d,"encoding":"ansi","width":80,"height":24,"full":false,"bytes":"%s"}\n' "$n" "$b"
done
echo '{"type":"terminal.closed","reason":"detached"}'
`

// terminalDaemon returns a daemon whose herdr bridge is a fake script.
func terminalDaemon(ctx context.Context, t *testing.T, body string) (*Daemon, *fakeHerdr) {
	t.Helper()
	f := newFakeHerdr(t)
	// The bridge preflight checks both herdr sockets.
	ln, err := net.Listen("unix", herdr.ClientSocketPath(f.path))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	f.setReply("pane.get", `"result":{"type":"pane_info","pane":{"pane_id":"w1:p1",`+
		`"terminal_id":"term_1","agent_status":"idle","scroll":{"offset_from_bottom":0,`+
		`"max_offset_from_bottom":0,"viewport_rows":40}}}`)
	f.setReply("pane.layout", `"result":{"type":"pane_layout","layout":{"tab_id":"w1:t1",`+
		`"panes":[{"pane_id":"w1:p1","rect":{"x":0,"y":0,"width":120,"height":40}},`+
		`{"pane_id":"w1:p2","rect":{"x":0,"y":0,"width":100,"height":30}}]}}`)
	d := herdrDaemon(ctx, f.path)
	d.herdrBin = fakeBridge(t, body)
	d.herdrAgents = []HerdrAgent{{Pane: "w1:p1", Agent: "claude", Status: "idle"}}
	return d, f
}

// herdrAnswers collects the flux.herdr answers that are not state.
func herdrAnswers(t *testing.T, phone *lan.Link) <-chan map[string]any {
	t.Helper()
	answers := make(chan map[string]any, 64)
	go phone.Receive(func(p *proto.Packet) {
		if p.Type == proto.TypeFluxHerdr {
			if f := p.Fields(); f["kind"] != "state" {
				answers <- f
			}
		}
	})
	return answers
}

func nextAnswer(t *testing.T, answers <-chan map[string]any) map[string]any {
	t.Helper()
	select {
	case a := <-answers:
		return a
	case <-time.After(5 * time.Second):
		t.Fatal("no answer within 5 seconds")
		return nil
	}
}

// nextOpened returns the answer to a terminal_open and checks its kind.
// The frames of an earlier stream are noise here.
func nextOpened(t *testing.T, answers <-chan map[string]any) map[string]any {
	t.Helper()
	for {
		a := nextAnswer(t, answers)
		if a["kind"] == "terminal_frame" {
			continue
		}
		if a["kind"] != "terminal_opened" {
			t.Fatalf("answer = %v, want terminal_opened", a)
		}
		return a
	}
}

// nextClosed returns a terminal_closed, skipping the frames before it.
func nextClosed(t *testing.T, answers <-chan map[string]any) map[string]any {
	t.Helper()
	for {
		a := nextAnswer(t, answers)
		if a["kind"] == "terminal_frame" {
			continue
		}
		if a["kind"] != "terminal_closed" {
			t.Fatalf("answer = %v, want terminal_closed", a)
		}
		return a
	}
}

func frameText(t *testing.T, answer map[string]any) string {
	t.Helper()
	raw, _ := answer["bytes"].(string)
	out, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		t.Fatalf("frame bytes %q: %v", raw, err)
	}
	return string(out)
}

func TestHerdrTerminalOpenFramesAndClose(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, f := terminalDaemon(ctx, t, bridgeFrames)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	answers := herdrAnswers(t, phone)

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 3}))

	open := nextAnswer(t, answers)
	if open["kind"] != "terminal_opened" || open["session"] != "ts1" ||
		open["width"] != 120.0 || open["height"] != 40.0 || open["request"] != 3.0 {
		t.Fatalf("terminal_opened = %v", open)
	}
	frame := nextAnswer(t, answers)
	if frame["kind"] != "terminal_frame" || frame["session"] != "ts1" ||
		frame["seq"] != 1.0 || frame["encoding"] != "ansi" || frameText(t, frame) != "hello" {
		t.Fatalf("terminal_frame = %v", frame)
	}
	closed := nextAnswer(t, answers)
	if closed["kind"] != "terminal_closed" || closed["session"] != "ts1" ||
		closed["code"] != "bridge" || closed["reason"] != "detached" {
		t.Fatalf("terminal_closed = %v", closed)
	}
	calls := strings.Join(f.takeCalls(), "\n")
	if !strings.Contains(calls, "pane.get") || !strings.Contains(calls, "pane.layout") {
		t.Fatalf("fluxd did not pin the pane: %s", calls)
	}
	waitFor(t, "the stream to end", func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return len(d.herdrStreams) == 0
	})
}

func TestHerdrTerminalPermissions(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)

	// A control stream needs herdr_control.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); !strings.Contains(str(a["error"]), "replies are off") {
		t.Fatalf("control without herdr_control = %v", a)
	}

	// An unknown pane is refused.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w9:p9", "mode": "observe", "request": 2}))
	if a := nextOpened(t, answers); !strings.Contains(str(a["error"]), "does not know that pane") {
		t.Fatalf("unknown pane = %v", a)
	}

	// One stream per device.
	d.cfg.HerdrControl = true
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 3}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("first open = %v", a)
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 4}))
	if a := nextOpened(t, answers); !strings.Contains(str(a["error"]), "already streams") {
		t.Fatalf("second open of one device = %v", a)
	}
}

func TestHerdrTerminalControlNeedsTerminals(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true
	// w1:p2 is a pane without an agent, so control also needs
	// herdr_terminals.
	d.herdrTerms = []HerdrTerminal{{Pane: "w1:p2", Title: "sh"}}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p2", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); !strings.Contains(str(a["error"]), "terminals are off") {
		t.Fatalf("control of a terminal = %v", a)
	}
	d.cfg.HerdrTerminals = true
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p2", "mode": "control", "request": 2}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("control with herdr_terminals = %v", a)
	}
}

func TestHerdrTerminalInputPolicy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_scroll", "session": "ts1", "direction": "up",
		"column": 20, "row": 10}))
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_mouse", "session": "ts1", "action": "down",
		"button": "left", "column": 5, "row": 6}))
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_release", "session": "ts1", "request": 7}))

	var echoed []string
	for {
		a := nextAnswer(t, answers)
		if a["kind"] == "terminal_closed" {
			if a["code"] != "released" || a["request"] != 7.0 {
				t.Fatalf("terminal_closed = %v", a)
			}
			break
		}
		text := frameText(t, a)
		// The bridge itself prints one ready frame before it echoes.
		if text != "ready" {
			echoed = append(echoed, text)
		}
	}
	if len(echoed) != 3 {
		t.Fatalf("the bridge got %d commands: %q", len(echoed), echoed)
	}
	var scroll, mouse, release map[string]any
	for _, line := range echoed {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) != nil {
			t.Fatalf("echoed %q", line)
		}
		switch rec["type"] {
		case "terminal.scroll":
			scroll = rec
		case "terminal.mouse":
			mouse = rec
		case "terminal.release":
			release = rec
		}
	}
	// fluxd fixes the source and the step size of a gesture.
	if scroll == nil || scroll["source"] != "wheel" || scroll["lines"] != 1.0 ||
		scroll["direction"] != "up" || scroll["column"] != 20.0 || scroll["row"] != 10.0 {
		t.Fatalf("scroll = %v", scroll)
	}
	if mouse == nil || mouse["action"] != "down" || mouse["button"] != "left" ||
		mouse["column"] != 5.0 || mouse["row"] != 6.0 {
		t.Fatalf("mouse = %v", mouse)
	}
	if release == nil {
		t.Fatal("the bridge got no terminal.release")
	}
}

func TestHerdrTerminalModeSwitch(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" || a["mode"] != "observe" {
		t.Fatalf("terminal_opened = %v", a)
	}

	// A mode change on the same pane replaces the bridge: the phone sees
	// the end of the old session and a new one, in any order.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 2}))
	var opened, closed map[string]any
	for opened == nil || closed == nil {
		switch a := nextAnswer(t, answers); a["kind"] {
		case "terminal_frame":
		case "terminal_opened":
			opened = a
		case "terminal_closed":
			closed = a
		default:
			t.Fatalf("answer = %v", a)
		}
	}
	if opened["session"] != "ts2" || opened["mode"] != "control" || opened["request"] != 2.0 {
		t.Fatalf("terminal_opened = %v", opened)
	}
	if closed["session"] != "ts1" || closed["code"] != "released" {
		t.Fatalf("terminal_closed = %v", closed)
	}

	// The replacement session is the one that input reaches.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_scroll", "session": "ts1", "direction": "up",
		"column": 1, "row": 1}))
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_release", "session": "ts2", "request": 3}))
	final := nextClosed(t, answers)
	if final["session"] != "ts2" || final["code"] != "released" || final["request"] != 3.0 {
		t.Fatalf("terminal_closed = %v", final)
	}
}

// bridgeArgs prints the argv of the bridge in its first frame, so a
// test can see the terminal size that fluxd asked for. It exits when
// fluxd closes stdin, like the real bridge.
const bridgeArgs = `
b=$(printf %s "$*" | base64 | tr -d '\n')
printf '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":48,"height":80,"full":true,"bytes":"%s"}\n' "$b"
while IFS= read -r line; do :; done
echo '{"type":"terminal.closed","reason":"detached"}'
`

// A control stream may name the size of the phone: fluxd opens the
// bridge at that size, so the program on the computer redraws for the
// phone instead of being shrunk to fit. Watching keeps the pane size.
func TestHerdrTerminalOpensAtThePhoneSize(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeArgs)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1,
		"cols": 48, "rows": 80}))
	open := nextOpened(t, answers)
	if open["session"] != "ts1" || open["width"] != 48.0 || open["height"] != 80.0 {
		t.Fatalf("terminal_opened = %v", open)
	}
	frame := nextAnswer(t, answers)
	args := frameText(t, frame)
	if !strings.Contains(args, "--cols 48") || !strings.Contains(args, "--rows 80") {
		t.Fatalf("bridge argv = %q", args)
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_release", "session": "ts1", "request": 2}))
	nextClosed(t, answers)

	// An invalid size fails the open instead of reaching the bridge.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 3,
		"cols": 0, "rows": 80}))
	failed := nextAnswer(t, answers)
	if failed["kind"] != "terminal_opened" || failed["error"] == nil ||
		failed["error"] != "fluxd does not accept that terminal size" {
		t.Fatalf("answer = %v", failed)
	}

	// Watching ignores a size of the phone and keeps the pane size.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 4,
		"cols": 48, "rows": 80}))
	open = nextOpened(t, answers)
	if open["width"] != 120.0 || open["height"] != 40.0 {
		t.Fatalf("terminal_opened = %v", open)
	}
	frame = nextAnswer(t, answers)
	args = frameText(t, frame)
	if strings.Contains(args, "--cols 48") || !strings.Contains(args, "--cols 120") {
		t.Fatalf("bridge argv = %q", args)
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_release", "session": open["session"], "request": 5}))
	nextClosed(t, answers)
}

func TestHerdrTerminalRejectsStaleSessions(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	other := &Device{ID: "tablet", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	// An unknown session, and the session of another device, never
	// reach the bridge. Its echo shows exactly what it got.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_scroll", "session": "ts9", "direction": "up", "column": 1, "row": 1}))
	d.handleHerdr(other, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_scroll", "session": "ts1", "direction": "up", "column": 1, "row": 1}))
	var echoed []string
	deadline := time.After(300 * time.Millisecond)
	for done := false; !done; {
		select {
		case a := <-answers:
			switch a["kind"] {
			case "terminal_frame":
				echoed = append(echoed, frameText(t, a))
			case "terminal_closed":
			default:
				t.Fatalf("a stale session reached the phone or the bridge: %v", a)
			}
		case <-deadline:
			done = true
		}
	}
	if len(echoed) != 1 || echoed[0] != "ready" {
		t.Fatalf("the bridge got %q", echoed)
	}
}

func TestHerdrTerminalHistoryBlockedWhileStream(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, f := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true
	d.mu.Lock()
	d.herdrHistory = map[string]agentHistory{
		"w1:p1": {lines: []string{"cached"}, at: time.Now()},
	}
	d.mu.Unlock()

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	f.takeCalls()
	// herdr scrolls the terminal to collect a history, so the read gets
	// the cache and no herdr call.
	lines, _ := d.readAgentHistory(ctx, "w1:p1", 100)
	if len(lines) != 1 || lines[0] != "cached" {
		t.Fatalf("history during a stream = %q", lines)
	}
	if calls := f.takeCalls(); len(calls) != 0 {
		t.Fatalf("fluxd read the history during a stream: %v", calls)
	}
	// After the stream ends, reads call herdr again.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_release", "session": "ts1", "request": 2}))
	nextClosed(t, answers) // terminal_closed
	d.mu.Lock()
	delete(d.herdrHistory, "w1:p1")
	d.mu.Unlock()
	d.readAgentHistory(ctx, "w1:p1", 100)
	if calls := f.takeCalls(); !strings.Contains(strings.Join(calls, "\n"), "agent.read") {
		t.Fatalf("reads did not resume after the stream: %v", calls)
	}
}

func TestHerdrTerminalPruneOnAgentEnd(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	// The agent leaves the pane, which is a shell now. fluxd must not
	// keep sending input to it.
	d.setHerdr(true, herdrLive{Terminals: []HerdrTerminal{{Pane: "w1:p1", Title: "sh"}}})
	closed := nextClosed(t, answers)
	if closed["kind"] != "terminal_closed" || closed["code"] != "agent_ended" {
		t.Fatalf("terminal_closed = %v", closed)
	}
}

func TestHerdrTerminalStopsWithTheLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pidfile := filepath.Join(t.TempDir(), "pid")
	d, _ := terminalDaemon(ctx, t, `
echo $$ > `+pidfile+`
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"cmVhZHk="}'
exec sleep 300
`)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	nextAnswer(t, answers) // the frame
	raw, err := os.ReadFile(pidfile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	desk.Close()
	waitFor(t, "the bridge to stop with the link", func() bool {
		d.mu.Lock()
		gone := len(d.herdrStreams) == 0
		d.mu.Unlock()
		return gone && syscall.Kill(pid, 0) != nil
	})
}

// A bridge that floods frames fills the frame queue of the session while
// the phone stops reading. When the link then drops, the forwarder must
// drain the frames and end the stream: waiting for Close before Wait
// would deadlock, and the stream would stay registered for the device.
func TestHerdrTerminalLinkLossWithAFullFrameQueue(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pidfile := filepath.Join(t.TempDir(), "pid")
	d, _ := terminalDaemon(ctx, t, `
echo $$ > `+pidfile+`
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"cmVhZHk="}'
i=0
while :; do
  i=$((i+1))
  printf '{"type":"terminal.frame","seq":%d,"encoding":"ansi","width":80,"height":24,"full":false,"bytes":"eA=="}\n' "$i"
done
`)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	raw, err := os.ReadFile(pidfile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	// Let the phone stop reading and the frame queue fill, so the reader
	// is blocked and the forwarder would stall without the drain.
	time.Sleep(300 * time.Millisecond)
	desk.Close()
	waitFor(t, "the flooded stream to end with the link", func() bool {
		d.mu.Lock()
		gone := len(d.herdrStreams) == 0
		d.mu.Unlock()
		return gone && syscall.Kill(pid, 0) != nil
	})
}

func TestHerdrTerminalCapabilities(t *testing.T) {
	for version, want := range map[string]bool{
		"0.9.3": true, "0.9.4": true, "0.10.0": true, "1.0.0": true,
		"0.9.2": false, "0.9": false, "": false, "dev": false,
	} {
		if got := herdrBridgeOK(version); got != want {
			t.Errorf("herdrBridgeOK(%q) = %v, want %v", version, got, want)
		}
	}
	d := herdrDaemon(context.Background(), "/tmp/none.sock")
	d.herdrRunning, d.herdrBridge = true, true
	v := d.herdrViewLocked()
	if len(v.Bridge) != len(herdrBridgeCaps) {
		t.Fatalf("bridge caps = %v", v.Bridge)
	}
	p := herdrStatePacket(v).Fields()
	if got, _ := p["bridge"].([]any); len(got) == 0 {
		if _, ok := p["bridge"].([]string); !ok {
			t.Fatalf("state has no bridge caps: %v", p["bridge"])
		}
	}
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

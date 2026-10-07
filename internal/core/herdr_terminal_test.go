package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"log"
	"net"
	"os"
	"path/filepath"
	"slices"
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
	f.setReply("pane.layout", `"result":{"type":"pane_layout","layout":{"tab_id":"w1:t1",`+
		`"panes":[{"pane_id":"w1:p1","rect":{"x":0,"y":0,"width":120,"height":40}},`+
		`{"pane_id":"w1:p2","rect":{"x":0,"y":0,"width":100,"height":30}}]}}`)
	d := herdrDaemon(ctx, f.path)
	d.herdrBin = fakeBridge(t, body)
	d.herdrRunning, d.herdrBridge = true, true
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
	// Watching keeps the size of the pane, so fluxd reads its layout.
	calls := strings.Join(f.takeCalls(), "\n")
	if !strings.Contains(calls, "pane.layout") {
		t.Fatalf("fluxd did not read the size of the pane: %s", calls)
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
	// herdr_terminals. The device cannot see the pane, so the answer is
	// the one for an unknown pane.
	d.herdrTerms = []HerdrTerminal{{Pane: "w1:p2", Title: "sh"}}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p2", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["error"] != "fluxd does not know that pane" {
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
		"kind": "terminal_resize", "session": "ts1", "cols": 48, "rows": 80}))
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
	if len(echoed) != 4 {
		t.Fatalf("the bridge got %d commands: %q", len(echoed), echoed)
	}
	var scroll, mouse, resize, release map[string]any
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
		case "terminal.resize":
			resize = rec
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
	if resize == nil || resize["cols"] != 48.0 || resize["rows"] != 80.0 {
		t.Fatalf("resize = %v", resize)
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

// The loss of the link ends the stream like a release of the phone. The
// bridge gets the end of stdin, so herdr detaches and gives the desktop
// its size back, and fluxd does not kill it.
func TestHerdrTerminalStopsWithTheLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	pidfile := filepath.Join(t.TempDir(), "pid")
	released := filepath.Join(t.TempDir(), "released")
	d, _ := terminalDaemon(ctx, t, `
echo $$ > `+pidfile+`
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"cmVhZHk="}'
while IFS= read -r line; do :; done
echo done > `+released+`
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
	if _, err := os.Stat(released); err != nil {
		t.Fatalf("the bridge was killed before the end of stdin: %v", err)
	}
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

// A plain read would make herdr scroll the terminal to collect the
// history, which moves the terminal of the phone and the desktop screen.
// While a phone controls the pane, a plain read gets the cached history
// and the screen of an ANSI read, which does not scroll.
func TestHerdrTerminalPlainReadUsesCacheWhileStream(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, f := terminalDaemon(ctx, t, bridgeEcho)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"\u001b[1mscreen\u001b[0m","truncated":false}}`
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
	body := outputBody(t, d.readHerdr("w1:p1", 100, false))
	want := "cached\n··· Older lines update when the phone releases this agent ···\nscreen"
	if body["text"] != want {
		t.Fatalf("plain read during a stream = %q, want %q", body["text"], want)
	}
	assertOnlyANSIReads(t, f.takeCalls())
}

// assertOnlyANSIReads fails when fluxd made a plain read, which scrolls
// the terminal.
func assertOnlyANSIReads(t *testing.T, calls []string) {
	t.Helper()
	if len(calls) == 0 {
		t.Fatal("fluxd did not read the screen")
	}
	for _, c := range calls {
		if !strings.HasPrefix(c, "agent.read") || !strings.Contains(c, `"format":"ansi"`) {
			t.Fatalf("a read during control called %s", c)
		}
	}
}

// A control stream reserves its pane before the slow attach, so a read
// that starts during the attach serves the cache instead of scrolling
// the terminal under the new stream.
func TestHerdrTerminalAttachReservesThePane(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, f := terminalDaemon(ctx, t, bridgeEcho)
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"screen","truncated":false}}`
	d.mu.Lock()
	d.herdrStreamWait = map[string]int{"w1:p1": 1}
	d.herdrHistory = map[string]agentHistory{
		"w1:p1": {lines: []string{"cached"}, at: time.Now()},
	}
	d.mu.Unlock()
	body := outputBody(t, d.readHerdr("w1:p1", 100, false))
	if text := str(body["text"]); !strings.HasPrefix(text, "cached\n") || !strings.HasSuffix(text, "\nscreen") {
		t.Fatalf("plain read during an attach = %q", text)
	}
	assertOnlyANSIReads(t, f.takeCalls())
}

// A read with a request number runs in reviewJobs, so a control stream
// must wait for it too before it takes the pane.
func TestHerdrTerminalWaitCoversViewReads(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	pane := "w1:p1"
	key := herdrReadKey{pane: pane}
	d.mu.Lock()
	if d.reviewJobs == nil {
		d.reviewJobs = map[herdrReadKey]*reviewReadJob{}
	}
	d.reviewJobs[key] = &reviewReadJob{}
	d.mu.Unlock()
	done := make(chan struct{})
	go func() {
		d.waitHerdrReads(pane, time.Now().Add(time.Minute))
		close(done)
	}()
	select {
	case <-done:
		t.Fatal("waitHerdrReads returned while a view read runs")
	case <-time.After(200 * time.Millisecond):
	}
	d.mu.Lock()
	delete(d.reviewJobs, key)
	d.mu.Unlock()
	waitFor(t, "waitHerdrReads to return", func() bool {
		select {
		case <-done:
			return true
		default:
			return false
		}
	})
}

// Two control streams can attach to a pane at once, for example two
// devices, or a retry while the first still opens. A stream that fails
// must release only its own reservation, never the one of the other.
func TestHerdrTerminalReserveSurvivesAnotherOpen(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	first := d.reserveHerdrStream("w1:p1")
	second := d.reserveHerdrStream("w1:p1")
	second()
	if !d.herdrControlled("w1:p1") {
		t.Fatal("a second release dropped the first reservation")
	}
	first()
	if d.herdrControlled("w1:p1") {
		t.Fatal("the pane stays reserved after every release")
	}
}

// The state shows the bridge actions that the device can use. Each one
// but observe writes to the terminal, so a device without herdr_control
// gets only observe.
func TestHerdrTerminalCapabilities(t *testing.T) {
	d := herdrDaemon(context.Background(), "/tmp/none.sock")
	d.herdrRunning, d.herdrBridge = true, true
	if v := d.herdrViewLocked(); !slices.Equal(v.Bridge, herdrBridgeCaps) {
		t.Fatalf("bridge caps = %v", v.Bridge)
	}
	if v := d.herdrViewForLocked("phone1"); !slices.Equal(v.Bridge, []string{"observe"}) {
		t.Fatalf("bridge caps without herdr_control = %v", v.Bridge)
	}
	d.cfg.HerdrControl = true
	v := d.herdrViewForLocked("phone1")
	if !slices.Equal(v.Bridge, herdrBridgeCaps) {
		t.Fatalf("bridge caps with herdr_control = %v", v.Bridge)
	}
	p := herdrStatePacket(v).Fields()
	if got, _ := p["bridge"].([]any); len(got) != len(herdrBridgeCaps) || got[1] != "control" {
		t.Fatalf("state bridge = %v", p["bridge"])
	}
	// The CLI path is for the local API only.
	if _, ok := p["cli"]; ok {
		t.Fatalf("the state for a phone has the CLI: %v", p["cli"])
	}
	d.herdrBridge = false
	if v := d.herdrViewForLocked("phone1"); len(v.Bridge) != 0 {
		t.Fatalf("bridge caps without the bridge = %v", v.Bridge)
	}
}

// fakeCLI writes a herdr CLI that prints version for --version.
func fakeCLI(t *testing.T, version string) string {
	t.Helper()
	return fakeBridge(t, "echo 'herdr "+version+"'\n")
}

// The live terminal needs herdr 0.9.3 or newer for the server and for
// the CLI that fluxd runs. They can differ when 2 herdr installs are on
// PATH.
func TestHerdrBridgeNeedsServerAndCLI(t *testing.T) {
	cases := []struct {
		server, cli string
		want        bool
	}{
		{"0.9.3", "0.9.3", true},
		{"0.10.0", "0.9.4", true},
		{"0.9.3", "0.9.1", false},
		{"0.9.1", "0.9.3", false},
	}
	for _, c := range cases {
		d := herdrDaemon(context.Background(), "/tmp/none.sock")
		d.herdrBin = fakeCLI(t, c.cli)
		d.checkHerdrBridge(context.Background(), c.server, true)
		d.mu.Lock()
		got, cli := d.herdrBridge, d.herdrCLI
		d.mu.Unlock()
		if got != c.want {
			t.Errorf("server %s and CLI %s: bridge = %v, want %v", c.server, c.cli, got, c.want)
		}
		if c.server != "0.9.1" && (cli.Version != c.cli || cli.Path != d.herdrBin) {
			t.Errorf("server %s and CLI %s: cli = %+v", c.server, c.cli, cli)
		}
	}
	d := herdrDaemon(context.Background(), "/tmp/none.sock")
	d.herdrBin = filepath.Join(t.TempDir(), "missing")
	d.checkHerdrBridge(context.Background(), "0.9.3", true)
	if d.herdrBridge || d.herdrCLI.Error == "" {
		t.Fatalf("a missing CLI gave bridge %v and cli %+v", d.herdrBridge, d.herdrCLI)
	}
}

// bridgeUntilEOF plays a bridge that writes one frame and then waits for
// the end of stdin, like the real bridge. It writes the file in $MARK
// when stdin ends, so a test can see a release instead of a kill.
const bridgeUntilEOF = `
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"cmVhZHk="}'
while IFS= read -r line; do :; done
[ -n "$MARK" ] && echo done > "$MARK"
echo '{"type":"terminal.closed","reason":"detached"}'
`

// A stream of a pane without an agent needs herdr_terminals in each
// mode, as a read of that pane does. Without it, the device cannot see
// the pane, so the answer is the one for an unknown pane.
func TestHerdrTerminalObserveShellNeedsTerminals(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeUntilEOF)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.herdrTerms = []HerdrTerminal{{Pane: "w1:p2", Title: "sh"}}

	for _, control := range []bool{false, true} {
		d.cfg.HerdrControl = control
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_open", "pane": "w1:p2", "mode": "observe", "request": 1}))
		hidden := nextOpened(t, answers)
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_open", "pane": "w9:p9", "mode": "observe", "request": 1}))
		unknown := nextOpened(t, answers)
		if hidden["error"] != "fluxd does not know that pane" || hidden["error"] != unknown["error"] {
			t.Fatalf("herdr_control %v: hidden pane = %v, unknown pane = %v", control, hidden, unknown)
		}
	}

	d.cfg.HerdrTerminals = true
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p2", "mode": "observe", "request": 2}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("observe with herdr_terminals = %v", a)
	}
}

// Turning herdr_terminals off ends a running observe stream of a pane
// without an agent. The bridge gets a release and is not killed.
func TestHerdrTerminalObserveEndsWhenTerminalsOff(t *testing.T) {
	mark := filepath.Join(t.TempDir(), "released")
	t.Setenv("MARK", mark)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeUntilEOF)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl, d.cfg.HerdrTerminals = true, true
	d.herdrTerms = []HerdrTerminal{{Pane: "w1:p2", Title: "sh"}}

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p2", "mode": "observe", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	d.mu.Lock()
	d.cfg.HerdrTerminals = false
	d.mu.Unlock()
	closed := nextClosed(t, answers)
	if closed["session"] != "ts1" || closed["code"] != "stopped" {
		t.Fatalf("terminal_closed = %v", closed)
	}
	if _, err := os.Stat(mark); err != nil {
		t.Fatalf("the bridge got no release: %v", err)
	}
}

// A device that is not allowed to control gets no write actions in the
// bridge list, and a herdr without the bridge refuses the open at once.
func TestHerdrTerminalNeedsTheBridge(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeUntilEOF)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.herdrBridge = false
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 1}))
	if a := nextOpened(t, answers); a["error"] != errHerdrNoBridge {
		t.Fatalf("open without the bridge = %v", a)
	}
}

// A burst of terminal_open packets from one device starts one bridge at
// most. The others get an answer at once.
func TestHerdrTerminalOpenFlood(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	starts := filepath.Join(t.TempDir(), "starts")
	d, _ := terminalDaemon(ctx, t, `
echo start >> `+starts+`
sleep 0.5
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"cmVhZHk="}'
while IFS= read -r line; do :; done
`)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	const burst = 20
	for i := range burst {
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": i + 1}))
	}
	opened, busy := 0, 0
	for range burst {
		a := nextOpened(t, answers)
		switch {
		case a["session"] != nil && a["retry"] == nil:
			opened++
		case a["error"] == errHerdrOpenBusy && a["retry"] == true:
			busy++
		default:
			t.Fatalf("answer = %v", a)
		}
	}
	raw, _ := os.ReadFile(starts)
	if n := strings.Count(string(raw), "start"); opened != 1 || busy != burst-1 || n != 1 {
		t.Fatalf("opened %d, busy %d, bridges started %d", opened, busy, n)
	}
	// The reservation ends with the open, so the next open gets the
	// answer for a device with a stream.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 99}))
	if a := nextOpened(t, answers); !strings.Contains(str(a["error"]), "already streams") {
		t.Fatalf("open after the burst = %v", a)
	}
}

// fluxd answers each terminal_open within herdrOpenTimeout, also when the
// bridge never writes a record. The failed open ends its reservation.
func TestHerdrTerminalOpenIsBounded(t *testing.T) {
	timeout := herdrOpenTimeout
	herdrOpenTimeout = 400 * time.Millisecond
	t.Cleanup(func() { herdrOpenTimeout = timeout })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, `
while IFS= read -r line; do :; done
`)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	for i := range 2 {
		start := time.Now()
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": i + 1}))
		a := nextOpened(t, answers)
		if a["error"] != "fluxd could not open the terminal of that pane" {
			t.Fatalf("open %d = %v", i, a)
		}
		if took := time.Since(start); took > 2*time.Second {
			t.Fatalf("open %d took %v", i, took)
		}
	}
}

// fluxd logs a control open, each click, and the end of each stream,
// like the key replies. It does not log a scroll or the frames.
func TestHerdrTerminalLogs(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeEcho)
	logs := &logLines{}
	d.logger = log.New(logs, "", 0)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1,
		"cols": 48, "rows": 80}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	for _, kind := range []string{"terminal_scroll", "terminal_mouse"} {
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": kind, "session": "ts1", "direction": "up", "action": "down",
			"button": "left", "column": 5, "row": 6}))
		// The phone can still scroll a stream that just ended. That
		// writes no log line.
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": kind, "session": "ts9", "direction": "up", "action": "down",
			"button": "left", "column": 5, "row": 6}))
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_release", "session": "ts1", "request": 2}))
	nextClosed(t, answers)
	for _, line := range []string{
		"Pixel 8 took control of the herdr agent in w1:p1 at 48x80",
		"Pixel 8 clicked the left button at the cell 5,6 of the herdr agent in w1:p1",
		"The live terminal of the herdr agent in w1:p1 for Pixel 8 ended with the code released",
	} {
		waitFor(t, "the log line "+line, func() bool { return logs.has(line) })
	}
	logs.mu.Lock()
	defer logs.mu.Unlock()
	for _, line := range logs.lines {
		if strings.Contains(line, "scroll") || strings.Contains(line, "terminal.frame") ||
			strings.Contains(line, "unknown session") || strings.Contains(line, "ts9") {
			t.Fatalf("fluxd logged %q", line)
		}
	}
}

// Only a control stream freezes the history of the agent. An observe
// stream does not change the terminal, so reads go on as before.
func TestHerdrTerminalObserveKeepsHistory(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, f := terminalDaemon(ctx, t, bridgeUntilEOF)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	f.takeCalls()
	d.readAgentHistory(ctx, "w1:p1", 100)
	calls := strings.Join(f.takeCalls(), "\n")
	if !strings.Contains(calls, "agent.read") || strings.Contains(calls, `"format":"ansi"`) {
		t.Fatalf("an observe stream froze the history: %s", calls)
	}
}

// While a phone controls the pane, a read without a cached history still
// gets the screen, under a line that tells why the older lines are not
// there.
func TestHerdrTerminalHeldReadWithoutCache(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, f := terminalDaemon(ctx, t, bridgeEcho)
	f.read = `"result":{"type":"pane_read","read":{"pane_id":"w1:p1","text":"\u001b[1mscreen\u001b[0m","truncated":false}}`
	d.mu.Lock()
	d.herdrStreamWait = map[string]int{"w1:p1": 1}
	d.mu.Unlock()
	plain := outputBody(t, d.readHerdr("w1:p1", 100, false))
	if plain["error"] != nil || plain["text"] != "··· Older lines update when the phone releases this agent ···\nscreen" {
		t.Fatalf("plain read = %v", plain)
	}
	ansi := outputBody(t, d.readHerdr("w1:p1", 100, true))
	if ansi["text"] != herdrHeldGap+"\n\x1b[1mscreen\x1b[0m" {
		t.Fatalf("ANSI read = %q", ansi["text"])
	}
	assertOnlyANSIReads(t, f.takeCalls())
}

// A control stream takes typed text and named keys in order. The text is
// not trimmed or submitted, and a key uses the bytes of the terminal.
func TestHerdrTerminalTypedInput(t *testing.T) {
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
	for _, ev := range []map[string]any{
		{"kind": "terminal_input", "session": "ts1", "text": "@"},
		{"kind": "terminal_input", "session": "ts1", "text": "src/main"},
		{"kind": "terminal_input", "session": "ts1", "key": "down"},
		{"kind": "terminal_input", "session": "ts1", "key": "enter"},
	} {
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, ev))
	}
	want := []string{"@", "src/main", "\x1b[B", "\r"}
	var got []string
	for len(got) < len(want) {
		a := nextAnswer(t, answers)
		if a["kind"] != "terminal_frame" {
			t.Fatalf("answer = %v", a)
		}
		if text := frameText(t, a); text != "ready" {
			got = append(got, text)
		}
	}
	for i, line := range got {
		var rec map[string]any
		if json.Unmarshal([]byte(line), &rec) != nil {
			t.Fatalf("echoed %q", line)
		}
		if rec["type"] != "terminal.input" || rec["text"] != want[i] {
			t.Fatalf("event %d = %v, want text %q", i, rec, want[i])
		}
	}
}

// A bad event is refused with terminal_input_error and never reaches the
// bridge. An unknown session, and the session of another device, get no
// input and no answer.
func TestHerdrTerminalInputRefusals(t *testing.T) {
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
	bad := []map[string]any{
		{"kind": "terminal_input", "session": "ts1", "text": ""},
		{"kind": "terminal_input", "session": "ts1", "text": "a", "key": "enter"},
		{"kind": "terminal_input", "session": "ts1", "key": "ctrl+c"},
		{"kind": "terminal_input", "session": "ts1", "text": "a\nb"},
		{"kind": "terminal_input", "session": "ts1", "text": "a\x1b[A"},
	}
	for _, ev := range bad {
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, ev))
	}
	for range bad {
		if a := nextInputError(t, answers); a["session"] != "ts1" || a["code"] != "invalid_input" {
			t.Fatalf("answer = %v, want terminal_input_error", a)
		}
	}
	// A stale session and a foreign device reach nothing and answer nothing.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_input", "session": "ts9", "text": "x"}))
	d.handleHerdr(other, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_input", "session": "ts1", "text": "x"}))

	// A good event still reaches the bridge: exactly one echo.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_input", "session": "ts1", "text": "ok"}))
	var echoed []string
	deadline := time.After(300 * time.Millisecond)
	for done := false; !done; {
		select {
		case a := <-answers:
			switch a["kind"] {
			case "terminal_frame":
				if text := frameText(t, a); text != "ready" {
					echoed = append(echoed, text)
				}
			case "terminal_closed":
			default:
				t.Fatalf("an unexpected answer reached the phone: %v", a)
			}
		case <-deadline:
			done = true
		}
	}
	if len(echoed) != 1 || !strings.Contains(echoed[0], `"text":"ok"`) {
		t.Fatalf("the bridge got %q", echoed)
	}
}

// A bridge failure on input ends the stream, so the phone cannot keep
// typing into a dead controller. The bridge here never reads its stdin,
// so its pipe and the input queue fill and SendInput fails.
func TestHerdrTerminalInputFailureEndsTheStream(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, `
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"cmVhZHk="}'
exec sleep 300
`)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	big := strings.Repeat("x", herdrTerminalInputMax)
	for i := 0; i < 400; i++ {
		d.mu.Lock()
		_, live := d.herdrStreams["ts1"]
		d.mu.Unlock()
		if !live {
			break
		}
		d.herdrTerminalInput(dev, desk, "ts1", big, "")
	}
	waitFor(t, "the input failure to end the stream", func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return len(d.herdrStreams) == 0
	})
}

// A paste goes to the controller as one bracketed paste: the markers are
// Flux's, the line breaks and tabs stay, and every other control character
// goes, so a paste cannot close its own paste or type a key.
func TestHerdrTerminalPaste(t *testing.T) {
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
		"kind": "terminal_paste", "session": "ts1", "text": "a\r\nb\tc\x07\x1bd"}))
	want := "\x1b[200~a\nb\tcd\x1b[201~"
	for {
		a := nextAnswer(t, answers)
		if a["kind"] != "terminal_frame" {
			t.Fatalf("answer = %v", a)
		}
		text := frameText(t, a)
		if text == "ready" {
			continue
		}
		var rec map[string]any
		if json.Unmarshal([]byte(text), &rec) != nil {
			t.Fatalf("echoed %q", text)
		}
		if rec["type"] != "terminal.input" || rec["text"] != want {
			t.Fatalf("paste = %v, want %q", rec, want)
		}
		break
	}
	// An empty paste and an oversized paste are refused, and reach no bridge.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste", "session": "ts1", "text": ""}))
	if a := nextInputError(t, answers); a["code"] != "invalid_input" {
		t.Fatalf("empty paste = %v", a)
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_paste", "session": "ts1", "text": strings.Repeat("x", herdrTerminalPasteMax+1)}))
	if a := nextInputError(t, answers); a["code"] != "invalid_input" || !strings.Contains(str(a["error"]), "longer than") {
		t.Fatalf("long paste = %v", a)
	}
}

// nextInputError returns a terminal_input_error, skipping the frames.
func nextInputError(t *testing.T, answers <-chan map[string]any) map[string]any {
	t.Helper()
	for {
		a := nextAnswer(t, answers)
		if a["kind"] == "terminal_frame" {
			continue
		}
		if a["kind"] != "terminal_input_error" {
			t.Fatalf("answer = %v, want terminal_input_error", a)
		}
		return a
	}
}

// testJPEG returns a small JPEG image, so a test can prove the conversion
// to PNG that the clipboard needs.
func testJPEG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 4, 4))
	for y := 0; y < 4; y++ {
		for x := 0; x < 4; x++ {
			img.Set(x, y, color.RGBA{R: uint8(x * 60), G: uint8(y * 60), B: 128, A: 255})
		}
	}
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, nil); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// The clipboard needs image/png, because the paste path of opencode reads
// only that type. A PNG stays as it is; a JPEG becomes a PNG; a WebP is
// refused with a reason.
func TestHerdrTerminalPNG(t *testing.T) {
	pngIn := testPNG(4)
	out, why := herdrTerminalPNG(pngIn, "image/png")
	if why != "" || !bytes.Equal(out, pngIn) {
		t.Fatalf("a PNG must stay as it is: %q", why)
	}
	out, why = herdrTerminalPNG(testJPEG(t), "image/jpeg")
	if why != "" || len(out) == 0 {
		t.Fatalf("a JPEG must become a PNG: %q", why)
	}
	if _, format, err := image.Decode(bytes.NewReader(out)); err != nil || format != "png" {
		t.Fatalf("the JPEG became %q, err %v, want png", format, err)
	}
	if _, why := herdrTerminalPNG(testJPEG(t), "image/webp"); why == "" {
		t.Fatal("a WebP needs a decoder that Flux does not carry")
	}
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

// Only the transient errors of terminal_opened tell the phone to try
// again. The other errors keep their text and get no retry flag.
func TestHerdrTerminalOpenRetryFlag(t *testing.T) {
	for err, want := range map[string]bool{
		errHerdrOpenBusy:                   true,
		errHerdrOpenLate:                   true,
		errHerdrStreams:                    true,
		errHerdrNoBridge:                   false,
		"fluxd does not know that pane":    false,
		"replies are off on this computer": false,
	} {
		body := herdrOpenFailed("w1:p1", "control", err).Fields()
		if body["kind"] != "terminal_opened" || body["error"] != err || body["pane"] != "w1:p1" || body["mode"] != "control" {
			t.Fatalf("answer for %q = %v", err, body)
		}
		if retry, ok := body["retry"]; ok != want || (ok && retry != true) {
			t.Errorf("retry for %q = %v, %v, want %v", err, retry, ok, want)
		}
	}
}

// A restart for a new fluxd binary waits while a live terminal runs or
// opens, as it waits for the other streams.
func TestHerdrTerminalKeepsTheRestart(t *testing.T) {
	d := herdrDaemon(context.Background(), "/tmp/none.sock")
	if what := d.Busy(); what != "" {
		t.Fatalf("Busy without a stream = %q", what)
	}
	d.herdrStreams = map[string]*herdrTerminal{"ts1": {id: "ts1", mode: "control"}}
	if what := d.Busy(); what != "the live terminal" {
		t.Fatalf("Busy with a stream = %q", what)
	}
	d.herdrStreams = nil
	d.herdrJobs.opening = map[string]bool{"phone1": true}
	if what := d.Busy(); what != "the live terminal" {
		t.Fatalf("Busy with an open = %q", what)
	}
}

// A failed input event goes to the log once for each stream. A gesture
// sends many events, so a line for each one would fill the journal.
func TestHerdrTerminalInputErrorLoggedOnce(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, bridgeUntilEOF)
	logs := &logLines{}
	d.logger = log.New(logs, "", 0)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	answers := herdrAnswers(t, phone)

	// An observe stream refuses each scroll.
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "observe", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	for range 5 {
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_scroll", "session": "ts1", "direction": "up", "column": 1, "row": 1}))
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": "terminal_mouse", "session": "ts1", "action": "down", "button": "left", "column": 1, "row": 1}))
	}
	logs.mu.Lock()
	n := 0
	for _, line := range logs.lines {
		if strings.Contains(line, "read-only") {
			n++
		}
	}
	logs.mu.Unlock()
	if n != 1 {
		t.Fatalf("fluxd logged %d input errors, want 1: %q", n, logs.lines)
	}
}

// A control stream ends with the code stopped when the user turns
// control off, when a rule of the device turns it off, or when the
// device is no longer paired. The bridge gets a release and is not
// killed.
func TestHerdrTerminalControlOff(t *testing.T) {
	cases := map[string]func(d *Daemon, dev *Device){
		"config": func(d *Daemon, dev *Device) { d.cfg.HerdrControl = false },
		"rule": func(d *Daemon, dev *Device) {
			d.cfg.Devices = map[string]map[string]bool{dev.ID: {"herdrControl": false}}
		},
		"unpair": func(d *Daemon, dev *Device) { dev.Paired = false },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			mark := filepath.Join(t.TempDir(), "released")
			t.Setenv("MARK", mark)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			d, _ := terminalDaemon(ctx, t, bridgeUntilEOF)
			desk, phone, _, _ := linkPair(t, ctx)
			dev := &Device{ID: "phone1", Paired: true}
			answers := herdrAnswers(t, phone)
			d.cfg.HerdrControl = true

			d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
				"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
			if a := nextOpened(t, answers); a["session"] != "ts1" {
				t.Fatalf("terminal_opened = %v", a)
			}
			d.mu.Lock()
			change(d, dev)
			d.mu.Unlock()
			closed := nextClosed(t, answers)
			if closed["session"] != "ts1" || closed["code"] != "stopped" {
				t.Fatalf("terminal_closed = %v", closed)
			}
			if _, err := os.Stat(mark); err != nil {
				t.Fatalf("the bridge got no release: %v", err)
			}
		})
	}
}

// An input event after control went off ends the stream at once, before
// the next check of watchSession, and never reaches the bridge. The
// check of watchSession runs each second, so the events below come
// before it.
func TestHerdrTerminalInputAfterControlOff(t *testing.T) {
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
	d.mu.Lock()
	d.cfg.Devices = map[string]map[string]bool{dev.ID: {"herdrControl": false}}
	d.mu.Unlock()
	for _, kind := range []string{"terminal_scroll", "terminal_mouse", "terminal_resize"} {
		d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
			"kind": kind, "session": "ts1", "direction": "up", "action": "down",
			"button": "left", "column": 1, "row": 1, "cols": 40, "rows": 20}))
	}
	var echoed []string
	for {
		a := nextAnswer(t, answers)
		if a["kind"] == "terminal_closed" {
			if a["code"] != "stopped" {
				t.Fatalf("terminal_closed = %v", a)
			}
			break
		}
		echoed = append(echoed, frameText(t, a))
	}
	for _, line := range echoed {
		if strings.Contains(line, "terminal.scroll") || strings.Contains(line, "terminal.mouse") ||
			strings.Contains(line, "terminal.resize") {
			t.Fatalf("an event after control went off reached the bridge: %q", echoed)
		}
	}
	if !slices.ContainsFunc(echoed, func(line string) bool { return strings.Contains(line, "terminal.release") }) {
		t.Fatalf("the bridge got no release: %q", echoed)
	}
}

// A bridge that ends with SIGKILL after the release is not a clean
// release. The log names the kill and the last stderr line of the bridge,
// and it never shows the bytes of a frame.
func TestHerdrTerminalLogsAKilledBridge(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := terminalDaemon(ctx, t, `
echo '{"type":"terminal.frame","seq":1,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"c2VjcmV0LWZyYW1l"}'
while IFS= read -r line; do :; done
echo 'fake-stderr-line' >&2
kill -9 $$
`)
	logs := &logLines{}
	d.logger = log.New(logs, "", 0)
	desk, phone, _, _ := linkPair(t, ctx)
	dev := &Device{ID: "phone1", Name: "Pixel 8", Paired: true}
	answers := herdrAnswers(t, phone)
	d.cfg.HerdrControl = true

	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_open", "pane": "w1:p1", "mode": "control", "request": 1}))
	if a := nextOpened(t, answers); a["session"] != "ts1" {
		t.Fatalf("terminal_opened = %v", a)
	}
	d.handleHerdr(dev, desk, proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "terminal_release", "session": "ts1", "request": 2}))
	if closed := nextClosed(t, answers); closed["code"] != "released" {
		t.Fatalf("terminal_closed = %v", closed)
	}
	want := "The live terminal of the herdr agent in w1:p1 for Pixel 8 ended with the code released: " +
		"herdr: the terminal session ended with SIGKILL: fake-stderr-line"
	waitFor(t, "the log line of the kill", func() bool { return logs.has(want) })
	logs.mu.Lock()
	defer logs.mu.Unlock()
	for _, line := range logs.lines {
		if strings.Contains(line, "secret-frame") || strings.Contains(line, "c2VjcmV0LWZyYW1l") {
			t.Fatalf("fluxd logged a frame: %q", line)
		}
	}
}

// fluxd checks the bridge again while the last check failed. An update
// of the herdr CLI then turns the live terminal on without a restart. A
// check that passed does not run again.
func TestHerdrBridgeRetry(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	f := newFakeHerdr(t)
	f.mu.Lock()
	f.version = "0.9.3"
	f.mu.Unlock()
	d := herdrDaemon(ctx, f.path)
	logs := &logLines{}
	d.logger = log.New(logs, "", 0)
	d.herdrBin = fakeCLI(t, "0.9.1")
	if d.checkHerdrBridge(ctx, "0.9.3", true); d.herdrBridge {
		t.Fatal("an old CLI passed")
	}
	// The same result writes no new log line.
	logs.mu.Lock()
	before := len(logs.lines)
	logs.mu.Unlock()
	d.retryHerdrBridge(ctx)
	logs.mu.Lock()
	after := len(logs.lines)
	logs.mu.Unlock()
	if d.herdrBridge || after != before {
		t.Fatalf("a retry with the same CLI gave bridge %v and %d new log lines", d.herdrBridge, after-before)
	}

	d.herdrBin = fakeCLI(t, "0.9.3")
	d.retryHerdrBridge(ctx)
	d.mu.Lock()
	ok, cli := d.herdrBridge, d.herdrCLI
	d.mu.Unlock()
	if !ok || cli.Version != "0.9.3" {
		t.Fatalf("a retry after the update gave bridge %v and cli %+v", ok, cli)
	}
	if !logs.has("the live terminal on the phone is on") {
		t.Fatalf("the log does not show the change: %q", logs.lines)
	}

	d.herdrBin = fakeCLI(t, "0.9.1")
	if d.retryHerdrBridge(ctx); !d.herdrBridge {
		t.Fatal("a check that passed ran again")
	}
}

package herdr

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMain lets this test binary stand in for the herdr CLI when it is
// invoked with the "terminal" subcommand. The target name selects the
// behavior of the fake bridge.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "terminal" {
		fakeBridge(os.Args[2:])
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// fakeBridge pretends to be `herdr terminal session ...`.
func fakeBridge(args []string) {
	target := ""
	if len(args) > 2 {
		target = args[2]
	}
	emit := func(rec map[string]any) {
		line, _ := json.Marshal(rec)
		_, _ = os.Stdout.Write(append(line, '\n'))
	}
	frame := func(seq int, text string) {
		emit(map[string]any{"type": "terminal.frame", "seq": seq, "encoding": "ansi",
			"width": 80, "height": 24, "full": seq == 1,
			"bytes": base64.StdEncoding.EncodeToString([]byte(text))})
	}
	closed := func(reason string) {
		emit(map[string]any{"type": "terminal.closed", "reason": reason})
	}
	switch {
	case target == "w1:args":
		frame(1, strings.Join(os.Args[1:], " "))
		closed("detached")
	case target == "w1:env":
		frame(1, fmt.Sprintf("socket=%s client=%s session=%s",
			os.Getenv("HERDR_SOCKET_PATH"), os.Getenv("HERDR_CLIENT_SOCKET_PATH"),
			os.Getenv("HERDR_SESSION")))
		closed("detached")
	case target == "w1:frames":
		frame(1, "first")
		frame(2, "second")
		closed("detached")
	case target == "w1:closed":
		closed("terminal attach failed: fake refuses")
	case target == "w1:badjson":
		frame(1, "ok")
		_, _ = os.Stdout.WriteString("{not json\n")
	case target == "w1:bigrecord":
		frame(1, "ok")
		_, _ = os.Stdout.WriteString(`{"type":"terminal.frame","bytes":"` +
			strings.Repeat("A", maxFrameRecord+64) + `"}` + "\n")
	case target == "w1:badbase64":
		frame(1, "ok")
		emit(map[string]any{"type": "terminal.frame", "seq": 2, "encoding": "ansi",
			"width": 80, "height": 24, "full": false, "bytes": "!!!"})
	case target == "w1:badencoding":
		frame(1, "ok")
		emit(map[string]any{"type": "terminal.frame", "seq": 2, "encoding": "png",
			"width": 80, "height": 24, "full": false, "bytes": "AAAA"})
	case target == "w1:eof":
		frame(1, "ok")
		// Exits without terminal.closed.
	case target == "w1:silent":
		// Exits without a record.
	case target == "w1:stderr":
		_, _ = os.Stderr.WriteString(strings.Repeat("noise ", 40000))
		_, _ = os.Stderr.WriteString("fake-stderr-marker\n")
		frame(1, "ok")
		closed("detached")
	case target == "w1:echo":
		frame(1, "ready")
		sc := bufio.NewScanner(os.Stdin)
		for seq := 1; sc.Scan(); {
			seq++
			frame(seq, sc.Text())
		}
		closed("detached")
	case target == "w1:hang":
		frame(1, "ready")
		// Reads nothing and never exits: the wrapper must kill it.
		time.Sleep(time.Hour)
	default:
		closed("terminal attach failed: unknown fake target")
	}
}

// fakeConfig returns a SessionConfig whose binary is this test binary
// and whose sockets exist for the preflight checks.
func fakeConfig(t *testing.T, target string, control bool) SessionConfig {
	t.Helper()
	dir := t.TempDir()
	socket := filepath.Join(dir, "herdr.sock")
	for _, path := range []string{socket, ClientSocketPath(socket)} {
		ln, err := net.Listen("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ln.Close() })
	}
	return SessionConfig{Path: os.Args[0], Socket: socket, Target: target,
		Cols: 80, Rows: 24, Control: control}
}

func openFake(t *testing.T, target string, control bool) *Session {
	t.Helper()
	s, err := OpenSession(context.Background(), fakeConfig(t, target, control))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func collectFrames(s *Session) []Frame {
	var frames []Frame
	for f := range s.Frames() {
		frames = append(frames, f)
	}
	return frames
}

// echoed returns the stdin lines that the w1:echo fake echoed back,
// without its ready frame.
func echoed(t *testing.T, s *Session) []string {
	t.Helper()
	var out []string
	for i, f := range collectFrames(s) {
		text := string(f.Bytes)
		if i == 0 && text == "ready" {
			continue
		}
		out = append(out, text)
	}
	return out
}

func TestSessionFramesAndReason(t *testing.T) {
	s := openFake(t, "w1:frames", true)
	frames := collectFrames(s)
	reason, err := s.Wait()
	if err != nil || reason != "detached" {
		t.Fatalf("Wait = %q, %v", reason, err)
	}
	if len(frames) != 2 {
		t.Fatalf("got %d frames", len(frames))
	}
	if frames[0].Seq != 1 || !frames[0].Full || frames[1].Seq != 2 || frames[1].Full {
		t.Fatalf("frames = %+v", frames)
	}
	if frames[0].Encoding != "ansi" || frames[0].Width != 80 || frames[0].Height != 24 {
		t.Fatalf("frame = %+v", frames[0])
	}
	if string(frames[0].Bytes) != "first" || string(frames[1].Bytes) != "second" {
		t.Fatalf("bytes = %q, %q", frames[0].Bytes, frames[1].Bytes)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestSessionOpenRefused(t *testing.T) {
	_, err := OpenSession(context.Background(), fakeConfig(t, "w1:closed", true))
	if err == nil || !strings.Contains(err.Error(), "fake refuses") {
		t.Fatalf("err = %v", err)
	}
}

func TestSessionOpenWithoutRecord(t *testing.T) {
	_, err := OpenSession(context.Background(), fakeConfig(t, "w1:silent", true))
	if err == nil {
		t.Fatal("a bridge that produced no record opened")
	}
}

func TestSessionEndsOnBadJSON(t *testing.T) {
	s := openFake(t, "w1:badjson", true)
	collectFrames(s)
	if _, err := s.Wait(); err == nil || !strings.Contains(err.Error(), "record") {
		t.Fatalf("err = %v", err)
	}
}

func TestSessionEndsOnRecordTooLong(t *testing.T) {
	s := openFake(t, "w1:bigrecord", true)
	collectFrames(s)
	if _, err := s.Wait(); err == nil || !strings.Contains(err.Error(), "too long") {
		t.Fatalf("err = %v", err)
	}
}

func TestSessionEndsOnBadFrame(t *testing.T) {
	for _, target := range []string{"w1:badbase64", "w1:badencoding"} {
		s := openFake(t, target, true)
		collectFrames(s)
		if _, err := s.Wait(); err == nil {
			t.Fatalf("%s: Wait accepted an invalid frame", target)
		}
	}
}

func TestSessionEndsWithoutClosed(t *testing.T) {
	s := openFake(t, "w1:eof", true)
	collectFrames(s)
	reason, err := s.Wait()
	if err == nil || reason != "" {
		t.Fatalf("Wait = %q, %v", reason, err)
	}
}

func TestSessionSendOrder(t *testing.T) {
	s := openFake(t, "w1:echo", true)
	if err := s.SendInput("hello"); err != nil {
		t.Fatal(err)
	}
	if err := s.SendScroll("up", 1, 20, 10); err != nil {
		t.Fatal(err)
	}
	if err := s.SendMouse("down", "left", 5, 6); err != nil {
		t.Fatal(err)
	}
	if err := s.Resize(100, 30); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	lines := echoed(t, s)
	want := []string{"terminal.input", "terminal.scroll", "terminal.mouse",
		"terminal.resize", "terminal.release"}
	if len(lines) != len(want) {
		t.Fatalf("got %d echoed commands: %q", len(lines), lines)
	}
	for i, line := range lines {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatal(err)
		}
		if rec["type"] != want[i] {
			t.Fatalf("command %d = %v, want %s", i, rec["type"], want[i])
		}
		if i == 1 && (rec["direction"] != "up" || rec["lines"] != 1.0 ||
			rec["column"] != 20.0 || rec["row"] != 10.0 || rec["source"] != "wheel") {
			t.Fatalf("scroll = %v", rec)
		}
	}
}

func TestSessionSendValidation(t *testing.T) {
	s := openFake(t, "w1:echo", true)
	bad := []error{
		s.SendInput(""),
		s.SendScroll("sideways", 1, 0, 0),
		s.SendScroll("up", 0, 0, 0),
		s.SendScroll("up", 1, -1, 0),
		s.SendMouse("jump", "left", 0, 0),
		s.SendMouse("down", "thumb", 0, 0),
		s.Resize(0, 24),
	}
	for i, err := range bad {
		if err == nil {
			t.Fatalf("call %d was accepted", i)
		}
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	lines := echoed(t, s)
	if len(lines) != 1 || !strings.Contains(lines[0], "terminal.release") {
		t.Fatalf("invalid calls reached the bridge: %q", lines)
	}
}

func TestSessionObserveIsReadOnly(t *testing.T) {
	s := openFake(t, "w1:echo", false)
	if err := s.SendInput("hello"); err == nil {
		t.Fatal("an observer accepted input")
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	if lines := echoed(t, s); len(lines) != 0 {
		t.Fatalf("an observer sent %d commands: %q", len(lines), lines)
	}
}

func TestSessionCloseKillsHungBridge(t *testing.T) {
	s := openFake(t, "w1:hang", true)
	s.releaseWait = 100 * time.Millisecond
	// The fake reads nothing, so the pipe and then the queue fill up.
	var full error
	for i := 0; i < 2000 && full == nil; i++ {
		full = s.SendInput(strings.Repeat("x", 256))
	}
	if full == nil {
		t.Fatal("SendInput never reported a full input queue")
	}
	if err := s.Close(); err == nil {
		t.Fatal("Close did not report that it killed the bridge")
	}
	if s.cmd.ProcessState == nil {
		t.Fatal("the bridge process was not reaped")
	}
	if err := s.SendInput("x"); err == nil {
		t.Fatal("SendInput after Close was accepted")
	}
}

func TestSessionStderrTailBounded(t *testing.T) {
	s := openFake(t, "w1:stderr", true)
	collectFrames(s)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	out := s.Stderr()
	if len(out) > stderrTail {
		t.Fatalf("kept %d bytes of stderr", len(out))
	}
	if !strings.Contains(out, "fake-stderr-marker") {
		t.Fatal("the stderr tail lost its end")
	}
}

func TestSessionEnvironment(t *testing.T) {
	s := openFake(t, "w1:env", true)
	frames := collectFrames(s)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	want := "socket=" + s.cfg.Socket + " client= session="
	got := ""
	if len(frames) == 1 {
		got = string(frames[0].Bytes)
	}
	if got != want {
		t.Fatalf("bridge env = %q, want %q", got, want)
	}
}

func TestSessionArguments(t *testing.T) {
	s := openFake(t, "w1:args", true)
	frames := collectFrames(s)
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	want := "terminal session control " + s.cfg.Target + " --cols 80 --rows 24"
	got := ""
	if len(frames) == 1 {
		got = string(frames[0].Bytes)
	}
	if got != want {
		t.Fatalf("bridge args = %q, want %q", got, want)
	}
}

func TestClientSocketPath(t *testing.T) {
	for api, want := range map[string]string{
		"/home/u/.config/herdr/herdr.sock": "/home/u/.config/herdr/herdr-client.sock",
		"/tmp/custom-api":                  "/tmp/custom-api-client.sock",
		"/tmp/herdr":                       "/tmp/herdr-client.sock",
	} {
		if got := ClientSocketPath(api); got != want {
			t.Fatalf("ClientSocketPath(%q) = %q, want %q", api, got, want)
		}
	}
}

func TestCheckSocket(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "herdr.sock")
	if err := CheckSocket(path); err == nil {
		t.Fatal("a missing socket passed")
	}
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := CheckSocket(file); err == nil {
		t.Fatal("a regular file passed")
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	if err := CheckSocket(path); err != nil {
		t.Fatal(err)
	}
}

func TestGetPane(t *testing.T) {
	path, reqs := fakeServer(t, func(req request) []string {
		return []string{`{"id":"flux","result":{"pane":{"pane_id":"w1:p1",` +
			`"terminal_id":"term_1","agent_status":"idle","scroll":{` +
			`"offset_from_bottom":3,"max_offset_from_bottom":10,` +
			`"viewport_rows":24}}}}`}
	})
	p, err := GetPane(context.Background(), path, "w1:p1")
	if err != nil {
		t.Fatal(err)
	}
	if p.ID != "w1:p1" || p.TerminalID != "term_1" || p.Status != "idle" ||
		p.Scroll.OffsetFromBottom != 3 || p.Scroll.ViewportRows != 24 {
		t.Fatalf("pane = %+v", p)
	}
	req := <-reqs
	if req.Method != "pane.get" {
		t.Fatalf("method = %q", req.Method)
	}
	if params, ok := req.Params.(map[string]any); !ok || params["pane_id"] != "w1:p1" {
		t.Fatalf("params = %v", req.Params)
	}
}

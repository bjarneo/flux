package herdr

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	// The fake CLI prints the version that a test sets.
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Println(os.Getenv("FLUX_TEST_HERDR_VERSION"))
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
		_, _ = os.Stderr.WriteString("fake-hang-marker\n")
		// Reads nothing and never exits: the wrapper must kill it.
		time.Sleep(time.Hour)
	case target == "w1:closehang":
		// Ends the stream with its last record, but does not exit.
		frame(1, "ready")
		closed("detached")
		time.Sleep(time.Hour)
	case target == "w1:flood":
		// Writes frames until the reader stops, and ends the stream when
		// stdin closes, like the real bridge.
		frame(1, "ready")
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			closed("detached")
			os.Exit(0)
		}()
		for seq := 2; ; seq++ {
			frame(seq, "x")
		}
	case target == "w1:mute":
		// Writes nothing and exits when stdin closes.
		_, _ = io.Copy(io.Discard, os.Stdin)
	case target == "w1:oldcli":
		// An old herdr CLI that does not know the bridge.
		_, _ = os.Stderr.WriteString("error: unknown command: terminal\n")
		os.Exit(2)
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
	// The end always has a reason, so the phone can show why.
	reason, err := s.Wait()
	if err == nil || reason == "" {
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
	err := s.Close()
	if !errors.Is(err, errKilled) || !strings.Contains(err.Error(), "fake-hang-marker") {
		t.Fatalf("Close = %v, want the kill with the last stderr line", err)
	}
	if s.cmd.ProcessState == nil {
		t.Fatal("the bridge process was not reaped")
	}
	if err := s.SendInput("x"); err == nil {
		t.Fatal("SendInput after Close was accepted")
	}
	// The kill is not a clean release.
	collectFrames(s)
	if reason, err := s.Wait(); !errors.Is(err, errKilled) {
		t.Fatalf("Wait = %q, %v, want the kill", reason, err)
	}
	if err := s.Close(); !errors.Is(err, errKilled) {
		t.Fatalf("a second Close = %v", err)
	}
}

// A bridge that sends terminal.closed and then does not exit gets
// killed. Wait has the clean reason, but Close reports the kill.
func TestSessionCloseKillsBridgeAfterClosed(t *testing.T) {
	s := openFake(t, "w1:closehang", true)
	s.releaseWait = 100 * time.Millisecond
	collectFrames(s)
	if reason, err := s.Wait(); reason != "detached" || err != nil {
		t.Fatalf("Wait = %q, %v", reason, err)
	}
	if err := s.Close(); !errors.Is(err, errKilled) {
		t.Fatalf("Close = %v, want the kill", err)
	}
}

// The end of ctx also kills a bridge that does not exit after the
// release. Close then reports the kill, also when Close itself did not
// kill the bridge.
func TestSessionContextEndKillReported(t *testing.T) {
	delay := killDelay
	killDelay = 200 * time.Millisecond
	t.Cleanup(func() { killDelay = delay })
	ctx, cancel := context.WithCancel(context.Background())
	s, err := OpenSession(ctx, fakeConfig(t, "w1:hang", true))
	if err != nil {
		t.Fatal(err)
	}
	// Close waits longer than exec, so the kill of the end of ctx comes
	// first.
	s.releaseWait = time.Hour
	cancel()
	collectFrames(s)
	if reason, err := s.Wait(); !errors.Is(err, errKilled) {
		t.Fatalf("Wait = %q, %v, want the kill", reason, err)
	}
	if err := s.Close(); !errors.Is(err, errKilled) {
		t.Fatalf("Close = %v, want the kill", err)
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

// A full frame queue blocks the reader while the bridge still writes.
// Close must stop the reader and close stdout, so the bridge exits at
// once instead of after releaseTimeout and a kill.
func TestSessionCloseWithAFullFrameQueue(t *testing.T) {
	s := openFake(t, "w1:flood", true)
	waitQueueFull(t, s)
	start := time.Now()
	if err := s.Close(); err != nil {
		t.Fatalf("Close = %v", err)
	}
	if took := time.Since(start); took > releaseTimeout/2 {
		t.Fatalf("Close took %v", took)
	}
	collectFrames(s)
	if reason, _ := s.Wait(); reason == "" {
		t.Fatal("the stream ended without a reason")
	}
}

// waitQueueFull waits until the reader has filled the frame queue.
func waitQueueFull(t *testing.T, s *Session) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for len(s.frames) < cap(s.frames) {
		if time.Now().After(deadline) {
			t.Fatal("the frame queue did not fill")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The end of ctx releases the terminal like Close. The bridge gets
// terminal.release and the end of stdin, and it exits by itself.
func TestSessionContextEndReleases(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	s, err := OpenSession(ctx, fakeConfig(t, "w1:echo", true))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	start := time.Now()
	cancel()
	lines := echoed(t, s)
	if len(lines) != 1 || !strings.Contains(lines[0], "terminal.release") {
		t.Fatalf("the bridge got %q", lines)
	}
	if reason, err := s.Wait(); reason != "detached" || err != nil {
		t.Fatalf("Wait = %q, %v", reason, err)
	}
	<-s.Exited()
	if code := s.cmd.ProcessState.ExitCode(); code != 0 {
		t.Fatalf("the bridge exit code is %d, so it was killed", code)
	}
	if took := time.Since(start); took > releaseTimeout/2 {
		t.Fatalf("the release took %v", took)
	}
}

// A bridge without a record fails the open within OpenTimeout.
func TestSessionOpenTimeout(t *testing.T) {
	cfg := fakeConfig(t, "w1:mute", false)
	cfg.OpenTimeout = 200 * time.Millisecond
	start := time.Now()
	_, err := OpenSession(context.Background(), cfg)
	if err == nil || !strings.Contains(err.Error(), "no record") {
		t.Fatalf("err = %v", err)
	}
	if took := time.Since(start); took > 2*time.Second {
		t.Fatalf("the open took %v", took)
	}
}

// An old herdr CLI fails on its arguments. The open error names its
// last stderr line, so the log shows why.
func TestSessionOpenErrorNamesStderr(t *testing.T) {
	_, err := OpenSession(context.Background(), fakeConfig(t, "w1:oldcli", true))
	if err == nil || !strings.Contains(err.Error(), "unknown command: terminal") {
		t.Fatalf("err = %v", err)
	}
}

func TestBridgeVersionOK(t *testing.T) {
	for version, want := range map[string]bool{
		"0.9.3": true, "0.9.4": true, "0.10.0": true, "1.0.0": true,
		"0.9.3-rc1": true, "1.2.3+build": true,
		"0.9.2": false, "0.9.1": false, "0.9": false, "": false, "dev": false,
		"0.+9.3": false, "0.-1.3": false,
		// The suffix starts at the first "-" or "+", so its dots are not
		// part of the version.
		"0.9-rc.3": false, "1.0+build.2": false, "0.9.3-preview.abc": true,
		"v0.9.3": true, "0.9.3.1": false, "0.9.x": false,
	} {
		if got := BridgeVersionOK(version); got != want {
			t.Errorf("BridgeVersionOK(%q) = %v, want %v", version, got, want)
		}
	}
}

func TestCLIVersion(t *testing.T) {
	for out, want := range map[string]string{
		"herdr 0.9.3":    "0.9.3",
		"herdr v0.10.1":  "0.10.1",
		"herdr 0.9.1 x":  "0.9.1",
		"herdr":          "",
		"something else": "",
	} {
		t.Setenv("FLUX_TEST_HERDR_VERSION", out)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		got, err := CLIVersion(ctx, os.Args[0])
		cancel()
		if got != want || (want == "") != (err != nil) {
			t.Errorf("CLIVersion for %q = %q, %v, want %q", out, got, err, want)
		}
	}
	if _, err := CLIVersion(context.Background(), filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Error("CLIVersion of a missing binary passed")
	}
}

func TestGetLayout(t *testing.T) {
	path, reqs := fakeServer(t, func(req request) []string {
		return []string{`{"id":"flux","result":{"type":"pane_layout","layout":{"tab_id":"w1:t1",` +
			`"panes":[{"pane_id":"w1:p2","rect":{"x":0,"y":0,"width":100,"height":30}},` +
			`{"pane_id":"w1:p1","rect":{"x":100,"y":0,"width":120,"height":40}}]}}}`}
	})
	l, err := GetLayout(context.Background(), path, "w1:p1")
	if err != nil {
		t.Fatal(err)
	}
	if l.Width != 120 || l.Height != 40 {
		t.Fatalf("layout = %+v", l)
	}
	if req := <-reqs; req.Method != "pane.layout" {
		t.Fatalf("method = %q", req.Method)
	}
	if _, err := GetLayout(context.Background(), path, "w1:p9"); err == nil {
		t.Fatal("a pane without a layout passed")
	}
}

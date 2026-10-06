package herdr

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"

	"golang.org/x/sys/unix"
)

// The terminal-session bridge runs one herdr CLI subprocess per stream:
//
//	herdr terminal session observe|control <target> --cols N --rows M
//
// It prints newline-delimited JSON records on stdout: terminal.frame with
// base64 ANSI bytes, then terminal.closed with a reason. A controller
// reads newline-delimited terminal.* commands on stdin. Closing stdin
// releases the terminal, because the CLI detaches when its input ends.

const (
	// maxFrameRecord is the largest bridge record that Flux reads. The
	// bytes of a frame are base64, so the decoded ANSI is smaller.
	maxFrameRecord = 1 << 20

	// maxFrameDim is the largest accepted terminal dimension.
	maxFrameDim = 1000

	// frameQueue buffers frames while the caller forwards them. ANSI
	// frames are incremental, so the reader cannot drop one. It blocks
	// instead, and Close stops it.
	frameQueue = 16

	// inputQueue bounds the commands that wait for stdin. Send fails
	// when the bridge cannot keep up, instead of growing forever.
	inputQueue = 128

	// releaseTimeout is how long Close waits for the process to exit
	// after the release before it kills its own subprocess.
	releaseTimeout = 5 * time.Second

	// openTimeout is how long OpenSession waits for the first record
	// when SessionConfig.OpenTimeout is zero.
	openTimeout = 8 * time.Second

	// stderrWait is how long a failed open waits for the bridge to exit,
	// so the error can name the last stderr line of the bridge.
	stderrWait = 250 * time.Millisecond

	// stderrTail is the stderr text kept for diagnostics. Frames and
	// input never go to a log.
	stderrTail = 8 << 10
)

// killDelay is how long exec waits for the bridge to exit after the end
// of ctx and the release before it kills the bridge. Tests make it
// shorter.
var killDelay = releaseTimeout

// Frame is one validated terminal.frame record of the bridge.
type Frame struct {
	Seq      uint64
	Encoding string
	Width    int
	Height   int
	Full     bool
	Bytes    []byte
}

// SessionConfig configures one terminal-session bridge. Path is the
// herdr binary, Socket is the API socket of its session, and Target is
// the pane to stream. Cols and Rows are the viewport of the stream.
// Observe only renders for them, and control also owns the terminal size.
// Control makes the stream writable.
type SessionConfig struct {
	Path    string
	Socket  string
	Target  string
	Cols    int
	Rows    int
	Control bool

	// OpenTimeout limits the wait for the first record. Zero means
	// openTimeout.
	OpenTimeout time.Duration
}

// Session is one herdr terminal-session bridge subprocess. The stream
// ends when the bridge closes it, when Close releases it, or when ctx
// ends. The end of ctx releases the terminal like Close and kills the
// process only when it does not exit within releaseTimeout.
type Session struct {
	cfg         SessionConfig
	cmd         *exec.Cmd
	frames      chan Frame
	input       chan []byte
	first       chan struct{}
	ended       chan struct{}
	reaped      chan struct{}
	readerQuit  chan struct{}
	firstOnce   sync.Once
	closeOnce   sync.Once
	mu          sync.RWMutex
	closed      bool
	firstErr    error
	endReason   string
	endErr      error
	closeErr    error
	stderr      tailBuffer
	releaseWait time.Duration

	// killed is true when the bridge process ended with SIGKILL. The
	// reaper sets it before it closes reaped, so read it only after a
	// receive from reaped.
	killed bool
}

// errKilled reports a bridge that ended with SIGKILL. Close and the end
// of ctx kill a bridge that does not exit after the release, so herdr
// can keep the terminal at the size of the phone.
var errKilled = errors.New("herdr: the terminal session ended with SIGKILL")

// OpenSession starts one bridge and waits for its first record, so a
// refused attach fails here instead of later. The ctx owns the
// subprocess: pass the lifetime of the stream. Its end releases the
// terminal, and a bridge that does not exit then gets killed.
func OpenSession(ctx context.Context, cfg SessionConfig) (*Session, error) {
	if cfg.Path == "" || cfg.Socket == "" || cfg.Target == "" {
		return nil, errors.New("herdr: terminal session needs a binary, a socket, and a target")
	}
	if cfg.Cols < 1 || cfg.Rows < 1 || cfg.Cols > maxFrameDim || cfg.Rows > maxFrameDim {
		return nil, fmt.Errorf("herdr: invalid terminal size %dx%d", cfg.Cols, cfg.Rows)
	}
	// HERDR_SOCKET_PATH can name a shared folder where another user can
	// listen first. That user must not get the frames or the input.
	if err := CheckSocket(cfg.Socket); err != nil {
		return nil, err
	}
	if err := CheckSocket(ClientSocketPath(cfg.Socket)); err != nil {
		return nil, err
	}
	kind := "observe"
	if cfg.Control {
		kind = "control"
	}
	// The CLI never gets a session name or a socket path as an argument:
	// only HERDR_SOCKET_PATH in its environment selects the session.
	args := []string{"terminal", "session", kind, cfg.Target,
		"--cols", strconv.Itoa(cfg.Cols), "--rows", strconv.Itoa(cfg.Rows)}
	cmd := exec.CommandContext(ctx, cfg.Path, args...)
	cmd.Env = bridgeEnv(cfg.Socket)
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		stdinR.Close()
		stdinW.Close()
		return nil, err
	}
	cmd.Stdin, cmd.Stdout = stdinR, stdoutW
	s := &Session{
		cfg: cfg, cmd: cmd,
		frames: make(chan Frame, frameQueue),
		input:  make(chan []byte, inputQueue),
		first:  make(chan struct{}), ended: make(chan struct{}),
		reaped:     make(chan struct{}),
		readerQuit: make(chan struct{}), releaseWait: releaseTimeout,
	}
	s.stderr.max = stderrTail
	cmd.Stderr = &s.stderr
	// The end of ctx releases the terminal first, as Close does. herdr
	// then detaches and gives the desktop its size back. exec kills the
	// process only when it is still alive after WaitDelay.
	cmd.Cancel = func() error {
		s.release()
		return nil
	}
	cmd.WaitDelay = killDelay
	if err := cmd.Start(); err != nil {
		stdinR.Close()
		stdinW.Close()
		stdoutR.Close()
		stdoutW.Close()
		return nil, err
	}
	// The child holds its own ends of the pipes now.
	stdinR.Close()
	stdoutW.Close()
	go s.write(stdinW)
	go s.read(stdoutR)
	go func() {
		_ = cmd.Wait()
		s.killed = sigkilled(cmd.ProcessState)
		close(s.reaped)
	}()
	wait := cfg.OpenTimeout
	if wait <= 0 {
		wait = openTimeout
	}
	// A failed open returns at once. Close releases the terminal and
	// reaps the bridge in the background, so the caller keeps its own
	// time limit.
	select {
	case <-s.first:
	case <-ctx.Done():
		go s.Close()
		return nil, ctx.Err()
	case <-time.After(wait):
		go s.Close()
		return nil, errors.New("herdr: terminal session produced no record")
	}
	if s.firstErr != nil {
		// The stream ended. Give the bridge a moment to exit, so the
		// error can show why it failed, for example an unknown command
		// of an old herdr CLI.
		select {
		case <-s.reaped:
		case <-time.After(stderrWait):
		}
		err := s.firstErr
		if tail := lastLine(s.Stderr()); tail != "" {
			err = fmt.Errorf("%w: %s", err, tail)
		}
		go s.Close()
		return nil, err
	}
	return s, nil
}

// Frames delivers each frame in order and closes when the stream ends.
// Frames can be incremental, so the caller must apply each one of them.
func (s *Session) Frames() <-chan Frame { return s.frames }

// Wait blocks until the stream ends and reports the terminal.closed
// reason. The error is set when the stream ended without a clean record.
func (s *Session) Wait() (string, error) {
	<-s.ended
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.endReason, s.endErr
}

// Stderr returns the tail of the output that the bridge wrote to stderr.
// It is for diagnostics only and never contains frames or input.
func (s *Session) Stderr() string { return s.stderr.String() }

// SendInput types text in the terminal. Only a controller can send.
func (s *Session) SendInput(text string) error {
	if text == "" {
		return errors.New("herdr: empty terminal input")
	}
	return s.send(map[string]any{"type": "terminal.input", "text": text})
}

// SendScroll sends one wheel step at a zero-based cell of the controller
// viewport. lines is how far a host scroll moves. An application that
// reports the mouse gets one wheel event for each call, whatever lines
// says.
func (s *Session) SendScroll(direction string, lines, column, row int) error {
	if direction != "up" && direction != "down" {
		return fmt.Errorf("herdr: invalid scroll direction %q", direction)
	}
	if lines < 1 {
		return errors.New("herdr: scroll lines must be at least 1")
	}
	if err := checkCell(column, row); err != nil {
		return err
	}
	return s.send(map[string]any{"type": "terminal.scroll", "direction": direction,
		"lines": lines, "source": "wheel", "column": column, "row": row})
}

// SendMouse sends one pointer event at a zero-based cell of the
// controller viewport. herdr encodes it for the mouse mode of the
// application and drops it when the application reports no mouse.
func (s *Session) SendMouse(action, button string, column, row int) error {
	if action != "down" && action != "up" && action != "drag" && action != "move" {
		return fmt.Errorf("herdr: invalid mouse action %q", action)
	}
	if button != "left" && button != "right" && button != "middle" {
		return fmt.Errorf("herdr: invalid mouse button %q", button)
	}
	if err := checkCell(column, row); err != nil {
		return err
	}
	return s.send(map[string]any{"type": "terminal.mouse", "action": action,
		"button": button, "column": column, "row": row})
}

// Resize changes the terminal to the size of the controller viewport.
// Only a controller can resize. Observe does not change the terminal.
func (s *Session) Resize(cols, rows int) error {
	if cols < 1 || rows < 1 || cols > maxFrameDim || rows > maxFrameDim {
		return fmt.Errorf("herdr: invalid terminal size %dx%d", cols, rows)
	}
	return s.send(map[string]any{"type": "terminal.resize", "cols": cols, "rows": rows})
}

func checkCell(column, row int) error {
	if column < 0 || row < 0 {
		return fmt.Errorf("herdr: invalid cell %d,%d", column, row)
	}
	return nil
}

// send queues one JSON line for stdin. The writer goroutine is the only
// one that writes, so commands never interleave. The queue is bounded:
// when the bridge cannot keep up, Send fails instead of dropping a
// command later without a trace.
func (s *Session) send(payload map[string]any) error {
	if !s.cfg.Control {
		return errors.New("herdr: the terminal session is read-only")
	}
	line, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.closed {
		return errors.New("herdr: terminal session is closed")
	}
	select {
	case s.input <- line:
		return nil
	default:
		return errors.New("herdr: terminal session input queue is full")
	}
}

// Close releases the terminal and reaps the bridge. It queues
// terminal.release and closes stdin, waits releaseWait for the process
// to exit, and then kills only this subprocess. Closing stdin is already
// a release, because the herdr CLI detaches when its input ends. Close
// returns an error with the last stderr line of the bridge when the
// process ended with SIGKILL, also after a kill at the end of ctx. Close
// is safe to call more than once.
func (s *Session) Close() error {
	s.release()
	s.closeOnce.Do(func() {
		select {
		case <-s.reaped:
		case <-time.After(s.releaseWait):
			_ = s.cmd.Process.Kill()
			<-s.reaped
		}
		if s.killed {
			s.closeErr = errKilled
			if tail := lastLine(s.Stderr()); tail != "" {
				s.closeErr = fmt.Errorf("%w: %s", errKilled, tail)
			}
		}
	})
	return s.closeErr
}

// sigkilled reports whether the process ended with SIGKILL.
func sigkilled(state *os.ProcessState) bool {
	if state == nil {
		return false
	}
	ws, ok := state.Sys().(syscall.WaitStatus)
	return ok && ws.Signaled() && ws.Signal() == syscall.SIGKILL
}

// Exited closes when the bridge process has exited and was reaped.
func (s *Session) Exited() <-chan struct{} { return s.reaped }

// release queues terminal.release for a controller and closes stdin, so
// the herdr CLI detaches. It also stops the reader when the frame queue
// is full. It does not wait, and it is safe to call more than once.
func (s *Session) release() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.closed = true
	if s.cfg.Control {
		line, _ := json.Marshal(map[string]any{"type": "terminal.release"})
		select {
		case s.input <- line:
		default:
		}
	}
	close(s.input)
	close(s.readerQuit)
}

// write sends the queued commands in order and then closes stdin. It
// stops at the first failed write, when the process has exited.
func (s *Session) write(stdin *os.File) {
	defer stdin.Close()
	for line := range s.input {
		if _, err := stdin.Write(append(line, '\n')); err != nil {
			return
		}
	}
}

// bridgeRecord is one JSON line of the bridge output.
type bridgeRecord struct {
	Type     string `json:"type"`
	Seq      uint64 `json:"seq"`
	Encoding string `json:"encoding"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	Full     bool   `json:"full"`
	Bytes    string `json:"bytes"`
	Reason   string `json:"reason"`
}

// frame validates one record before it can reach a phone. A frame is
// never truncated: a record that does not validate ends the stream.
func (r bridgeRecord) frame() (Frame, error) {
	if r.Encoding != "ansi" {
		return Frame{}, fmt.Errorf("herdr: unsupported frame encoding %q", r.Encoding)
	}
	if r.Width < 1 || r.Height < 1 || r.Width > maxFrameDim || r.Height > maxFrameDim {
		return Frame{}, fmt.Errorf("herdr: invalid frame size %dx%d", r.Width, r.Height)
	}
	raw, err := base64.StdEncoding.DecodeString(r.Bytes)
	if err != nil {
		return Frame{}, fmt.Errorf("herdr: invalid frame bytes: %w", err)
	}
	return Frame{Seq: r.Seq, Encoding: r.Encoding, Width: r.Width,
		Height: r.Height, Full: r.Full, Bytes: raw}, nil
}

// read parses the bridge output until the stream ends. It closes stdout
// when it returns, so a bridge that still writes gets EPIPE and exits
// instead of blocking on a pipe that nobody reads.
func (s *Session) read(stdout *os.File) {
	defer func() {
		_ = stdout.Close()
		s.mu.RLock()
		err, reason := s.endErr, s.endReason
		s.mu.RUnlock()
		// A stream that ends before its first frame fails the open, also
		// after a clean release.
		if err == nil {
			err = fmt.Errorf("herdr: terminal session ended: %s", reason)
		}
		s.markFirst(err)
		close(s.frames)
		close(s.ended)
	}()
	r := bufio.NewReader(stdout)
	for {
		line, err := readLine(r, maxFrameRecord)
		if err != nil {
			s.mu.RLock()
			released := s.closed
			s.mu.RUnlock()
			switch {
			case errors.Is(err, io.EOF) && released:
				// The bridge closed its output after a release without its
				// last record. That is a clean end only when the process
				// exits by itself. Close and the end of ctx kill a bridge
				// that does not exit, so this wait has a limit.
				<-s.reaped
				var end error
				if s.killed {
					end = errKilled
				}
				s.setEnd(releasedReason, end)
			case errors.Is(err, io.EOF):
				s.setEnd("", errors.New("herdr: terminal session ended without terminal.closed"))
			default:
				s.setEnd("", fmt.Errorf("herdr: terminal session: %w", err))
			}
			return
		}
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var rec bridgeRecord
		if err := json.Unmarshal(line, &rec); err != nil {
			s.setEnd("", fmt.Errorf("herdr: terminal session record: %w", err))
			return
		}
		switch rec.Type {
		case "terminal.frame":
			frame, err := rec.frame()
			if err != nil {
				s.setEnd("", err)
				return
			}
			s.markFirst(nil)
			// The reader buffers the frame when it can. It drops the
			// frame only when the queue is full and Close already ended
			// the stream.
			select {
			case s.frames <- frame:
			default:
				select {
				case s.frames <- frame:
				case <-s.readerQuit:
					s.setEnd(releasedReason, nil)
					return
				}
			}
		case "terminal.closed":
			s.setEnd(rec.Reason, nil)
			s.markFirst(fmt.Errorf("herdr: terminal session closed: %s", rec.Reason))
			return
		}
	}
}

// releasedReason is the end reason when Close ended the stream before
// the bridge sent terminal.closed.
const releasedReason = "released"

// setEnd records how the stream ended. The reason is never empty, so a
// caller can always show why the stream ended.
func (s *Session) setEnd(reason string, err error) {
	switch {
	case reason != "":
	case err != nil:
		reason = err.Error()
	default:
		reason = "closed"
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.endReason, s.endErr = reason, err
}

// lastLine returns the last line of text with text in it, without
// control characters and at most 200 characters long. It is for a log
// line, never for a phone.
func lastLine(text string) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	line := strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, strings.TrimSpace(lines[len(lines)-1]))
	if r := []rune(line); len(r) > 200 {
		line = string(r[:200])
	}
	return line
}

// markFirst reports the first record to OpenSession. A stream that ends
// with its first record fails the open with its reason.
func (s *Session) markFirst(err error) {
	s.firstOnce.Do(func() {
		s.firstErr = err
		close(s.first)
	})
}

// bridgeEnv points the herdr CLI at the same session as the API socket
// and removes the variables that could redirect it to another session or
// to a client socket that Flux did not check.
func bridgeEnv(socket string) []string {
	env := make([]string, 0, len(os.Environ())+1)
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		switch key {
		case "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH", "HERDR_SESSION":
			continue
		}
		env = append(env, kv)
	}
	return append(env, "HERDR_SOCKET_PATH="+socket)
}

// ClientSocketPath returns the client socket that the herdr CLI derives
// from an API socket path: herdr inserts "-client" before ".sock".
func ClientSocketPath(apiSocket string) string {
	dir, file := filepath.Split(apiSocket)
	stem := strings.TrimSuffix(file, filepath.Ext(file))
	if stem == "" {
		stem = "herdr"
	}
	return filepath.Join(dir, stem+"-client.sock")
}

// CheckSocket checks that path is a Unix socket of this user. The herdr
// API client checks the same with SO_PEERCRED. A subprocess cannot do
// that, so Flux checks the file before it starts the CLI.
func CheckSocket(path string) error {
	var st unix.Stat_t
	if err := unix.Stat(path, &st); err != nil {
		return fmt.Errorf("herdr: %s: %w", path, err)
	}
	if st.Mode&unix.S_IFMT != unix.S_IFSOCK {
		return fmt.Errorf("herdr: %s is not a socket", path)
	}
	if int(st.Uid) != os.Getuid() {
		return fmt.Errorf("herdr: %s belongs to user %d, not to user %d", path, st.Uid, os.Getuid())
	}
	return nil
}

// MinBridgeVersion is the oldest herdr that has the terminal-session
// bridge. The herdr server and the herdr CLI that fluxd runs both need it.
const MinBridgeVersion = "0.9.3"

// BridgeVersionOK reports whether a herdr version, such as 0.9.3, has the
// terminal-session bridge. The bridge is not part of the API protocol, so
// the protocol number alone cannot show that it exists.
func BridgeVersionOK(version string) bool {
	v, ok := parseVersion(version)
	min, _ := parseVersion(MinBridgeVersion)
	return ok && slices.Compare(v[:], min[:]) >= 0
}

// parseVersion reads a version such as 0.9.3, v0.9.3, 0.10.0-rc1, or
// 1.0.0+build.2. It removes the pre-release and build suffix at the first
// "-" or "+" before it splits the rest. The rest must be exactly 3
// numbers.
func parseVersion(version string) ([3]int, bool) {
	var v [3]int
	base, _, _ := strings.Cut(strings.TrimPrefix(version, "v"), "-")
	base, _, _ = strings.Cut(base, "+")
	parts := strings.Split(base, ".")
	if len(parts) != len(v) {
		return v, false
	}
	for i, part := range parts {
		// The cut removed each sign, so Atoi accepts only digits here.
		n, err := strconv.Atoi(part)
		if err != nil {
			return v, false
		}
		v[i] = n
	}
	return v, true
}

// CLIVersion runs the herdr CLI bin with --version and returns the
// version that it prints. herdr prints a line such as "herdr 0.9.3". The
// CLI can be another herdr than the server, for example when 2 installs
// are on PATH. Give ctx a short deadline.
func CLIVersion(ctx context.Context, bin string) (string, error) {
	cmd := exec.CommandContext(ctx, bin, "--version")
	cmd.WaitDelay = time.Second
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("herdr: %s --version: %w", bin, err)
	}
	for _, field := range strings.Fields(string(out)) {
		field = strings.TrimPrefix(field, "v")
		if _, ok := parseVersion(field); ok {
			return field, nil
		}
	}
	return "", fmt.Errorf("herdr: %s --version printed no version", bin)
}

// tailBuffer keeps only the last max bytes of what is written to it.
type tailBuffer struct {
	mu   sync.Mutex
	data []byte
	max  int
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.data = append(b.data, p...)
	if len(b.data) > b.max {
		b.data = append(b.data[:0], b.data[len(b.data)-b.max:]...)
	}
	return len(p), nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.data)
}

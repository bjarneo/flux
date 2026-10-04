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
	"strconv"
	"strings"
	"sync"
	"time"

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
	// frames are incremental, so none may be dropped: the reader blocks
	// instead, and Close unblocks it.
	frameQueue = 16

	// inputQueue bounds the commands that wait for stdin. Send fails
	// when the bridge cannot keep up, instead of growing forever.
	inputQueue = 128

	// releaseTimeout is how long Close waits for the process to exit
	// after the release before it kills its own subprocess.
	releaseTimeout = 5 * time.Second

	// openTimeout is how long OpenSession waits for the first record.
	openTimeout = 8 * time.Second

	// stderrTail is the stderr text kept for diagnostics. Frames and
	// input never go to a log.
	stderrTail = 8 << 10
)

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
// the pane, terminal, or agent to stream. Cols and Rows are the viewport
// of the stream: observe only renders for them, while control also owns
// the terminal size. Control makes the stream writable.
type SessionConfig struct {
	Path    string
	Socket  string
	Target  string
	Cols    int
	Rows    int
	Control bool
}

// Session is one herdr terminal-session bridge subprocess. The stream
// ends when the bridge closes it or when ctx ends, which kills the
// process. Close releases the terminal and reaps the process.
type Session struct {
	cfg         SessionConfig
	cmd         *exec.Cmd
	frames      chan Frame
	input       chan []byte
	first       chan struct{}
	ended       chan struct{}
	reaped      chan struct{}
	closeDone   chan struct{}
	readerQuit  chan struct{}
	firstOnce   sync.Once
	mu          sync.RWMutex
	closed      bool
	firstErr    error
	endReason   string
	endErr      error
	closeErr    error
	stderr      tailBuffer
	releaseWait time.Duration
}

// OpenSession starts one bridge and waits for its first record, so a
// refused attach fails here instead of later. The ctx owns the
// subprocess: pass the lifetime of the link or of the daemon.
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
		reaped: make(chan struct{}), closeDone: make(chan struct{}),
		readerQuit: make(chan struct{}), releaseWait: releaseTimeout,
	}
	s.stderr.max = stderrTail
	cmd.Stderr = &s.stderr
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
		close(s.reaped)
	}()
	select {
	case <-s.first:
	case <-ctx.Done():
		_ = s.Close()
		return nil, ctx.Err()
	case <-time.After(openTimeout):
		_ = s.Close()
		return nil, errors.New("herdr: terminal session produced no record")
	}
	if s.firstErr != nil {
		_ = s.Close()
		return nil, s.firstErr
	}
	return s, nil
}

// Frames delivers each frame in order and closes when the stream ends.
// Frames may be incremental, so the caller must apply every one of them.
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

// SendInput types text in the terminal. Only a controller may send.
func (s *Session) SendInput(text string) error {
	if text == "" {
		return errors.New("herdr: empty terminal input")
	}
	return s.send(map[string]any{"type": "terminal.input", "text": text})
}

// SendScroll sends one wheel step at a zero-based cell of the controller
// viewport. lines is how far a host scroll moves; an application that
// reports the mouse receives one wheel event per call, whatever lines
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
// Only a controller may resize; observe leaves the terminal untouched.
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
// is safe to call more than once.
func (s *Session) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		<-s.closeDone
		return s.closeErr
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
	s.mu.Unlock()

	var err error
	select {
	case <-s.reaped:
	case <-time.After(s.releaseWait):
		_ = s.cmd.Process.Kill()
		<-s.reaped
		err = errors.New("herdr: terminal session did not exit after release")
	}
	s.closeErr = err
	close(s.closeDone)
	return err
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

// frame validates one record before it may reach a phone. A frame is
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

// read parses the bridge output until the stream ends.
func (s *Session) read(stdout *os.File) {
	defer func() {
		s.markFirst(s.endErr)
		close(s.frames)
		close(s.ended)
	}()
	r := bufio.NewReader(stdout)
	for {
		line, err := readLine(r, maxFrameRecord)
		if err != nil {
			if errors.Is(err, io.EOF) {
				s.setEnd("", errors.New("herdr: terminal session ended without terminal.closed"))
			} else {
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
			// Prefer to buffer the frame; only a full queue can be
			// abandoned, when Close has already unblocked the reader.
			select {
			case s.frames <- frame:
			default:
				select {
				case s.frames <- frame:
				case <-s.readerQuit:
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

func (s *Session) setEnd(reason string, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.endReason, s.endErr = reason, err
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
// API client checks the same with SO_PEERCRED; a subprocess cannot, so
// Flux checks the file before it starts the CLI.
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

// Package hc is a client for the API socket of herdr-core, the runtime of
// the herdr app. fluxd uses it to show the agents of the herdr app on a
// paired phone, next to the agents of the herdr terminal app.
//
// The API is JSON-RPC 2.0, one message per line, on a Unix socket. A
// terminal reports its status itself, with the app that runs in it, so
// a terminal with a status app is an agent. See schema/README.md in
// herdr-core.
package hc

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"golang.org/x/sys/unix"
)

// Generation is the protocol generation of herdr-core that Flux speaks.
const Generation = 1

// maxLine is the largest reply line that the client reads. A read of a
// terminal with its history can be long.
const maxLine = 32 << 20

// callTimeout limits a call when ctx has no deadline.
const callTimeout = 5 * time.Second

// session is the herdr-core session of the herdr app.
const session = "default"

// SocketPath returns the API socket of the default herdr-core session,
// with the rules of herdr-core: HC_SOCKET, then the runtime folder, then
// the state folder.
func SocketPath() string {
	if p := os.Getenv("HC_SOCKET"); p != "" {
		return p
	}
	name := session + ".sock"
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		return filepath.Join(dir, "herdr-core", name)
	}
	run := filepath.Join("/run/user", strconv.Itoa(os.Getuid()))
	if fi, err := os.Stat(run); err == nil && fi.IsDir() {
		return filepath.Join(run, "herdr-core", name)
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		home, _ := os.UserHomeDir()
		state = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(state, "herdr-core", session, name)
}

// Error is an error reply of herdr-core. Kind is stable, such as
// not_found or blocked.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    struct {
		Kind string `json:"kind"`
		Hint string `json:"hint"`
	} `json:"data"`
}

func (e *Error) Error() string { return "herdr-core: " + e.Message }

// Kind returns the kind of a herdr-core error, or an empty string.
func Kind(err error) string {
	var he *Error
	if errors.As(err, &he) {
		return he.Data.Kind
	}
	return ""
}

// Hello is the part of the hello reply that Flux uses.
type Hello struct {
	Generation int    `json:"generation"`
	Version    string `json:"version"`
	Core       struct {
		Name string `json:"name"`
	} `json:"core"`
}

// Status is what the program in a terminal reported: the app, such as
// claude-code or opencode, and a state word, such as working.
type Status struct {
	App   string `json:"app"`
	State string `json:"state"`
	Title string `json:"title"`
	Msg   string `json:"msg"`
}

// Foreground is the program that runs in a terminal now.
type Foreground struct {
	Cwd string `json:"cwd"`
}

// Terminal is the part of a terminal record that Flux uses. Address is
// t7, or machine/t7 for a terminal on a machine of the core.
type Terminal struct {
	Address    string            `json:"address"`
	Name       *string           `json:"name"`
	State      string            `json:"state"`
	Cwd        string            `json:"cwd"`
	Title      string            `json:"title"`
	Labels     map[string]string `json:"labels"`
	Status     *Status           `json:"status"`
	Foreground *Foreground       `json:"foreground"`
}

// Live reports whether the program of the terminal still runs.
func (t Terminal) Live() bool { return t.State == "live" }

// Dir returns the folder of the program in the terminal, or the start
// folder of the terminal.
func (t Terminal) Dir() string {
	if t.Foreground != nil && t.Foreground.Cwd != "" {
		return t.Foreground.Cwd
	}
	return t.Cwd
}

// Read is the screen of a terminal with its history. How is "screen",
// "history", "stitched", or "ansi" for the screen with its styles.
type Read struct {
	Text     string `json:"text"`
	Complete bool   `json:"complete"`
	How      string `json:"how"`
}

type request struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int    `json:"id"`
	Method  string `json:"method"`
	Params  any    `json:"params"`
}

type response struct {
	ID     *int            `json:"id"`
	Method string          `json:"method"`
	Result json.RawMessage `json:"result"`
	Error  *Error          `json:"error"`
}

// Hi sends hello and returns the identity of the core. It fails for a
// core of another protocol generation.
func Hi(ctx context.Context, path string) (Hello, error) {
	var h Hello
	if err := Call(ctx, path, "hello", map[string]any{"generation": Generation}, &h); err != nil {
		return h, err
	}
	if h.Generation != Generation {
		return h, fmt.Errorf("herdr-core speaks protocol generation %d, and Flux speaks %d", h.Generation, Generation)
	}
	return h, nil
}

// List returns the live terminals of the core and its machines.
func List(ctx context.Context, path string) ([]Terminal, error) {
	var out struct {
		Terminals []Terminal `json:"terminals"`
	}
	err := Call(ctx, path, "terminal.list", struct{}{}, &out)
	return out.Terminals, err
}

// Get returns one terminal.
func Get(ctx context.Context, path, terminal string) (Terminal, error) {
	var t Terminal
	err := Call(ctx, path, "terminal.get", map[string]any{"terminal": terminal}, &t)
	return t, err
}

// ReadTerminal returns the screen of a terminal and lines of history
// above it, as plain text.
func ReadTerminal(ctx context.Context, path, terminal string, lines int) (Read, error) {
	var r Read
	err := Call(ctx, path, "terminal.read", map[string]any{"terminal": terminal, "lines": lines}, &r)
	return r, err
}

// ReadScreenANSI returns the screen of a terminal with its colors and
// styles as SGR sequences. A herdr-core without the ansi option ignores
// it and returns the plain screen, with How "screen", not "ansi".
func ReadScreenANSI(ctx context.Context, path, terminal string) (Read, error) {
	var r Read
	err := Call(ctx, path, "terminal.read", map[string]any{"terminal": terminal, "ansi": true}, &r)
	return r, err
}

// Send pastes text and presses Enter. herdr-core refuses a blocked
// program unless force, because the text would answer its dialog.
func Send(ctx context.Context, path, terminal, text string, force bool) error {
	return Call(ctx, path, "terminal.send", map[string]any{"terminal": terminal, "text": text, "force": force}, nil)
}

// Keys presses named keys, such as enter, esc, or ctrl+c.
func Keys(ctx context.Context, path, terminal string, keys []string) error {
	return Call(ctx, path, "terminal.keys", map[string]any{"terminal": terminal, "keys": keys}, nil)
}

// Kill ends the program of a terminal.
func Kill(ctx context.Context, path, terminal string) error {
	return Call(ctx, path, "terminal.kill", map[string]any{"terminal": terminal}, nil)
}

// Call sends one request on a new connection and decodes its result
// into out. out can be nil.
func Call(ctx context.Context, path, method string, params, out any) error {
	conn, r, err := open(ctx, path, method, params)
	if err != nil {
		return err
	}
	defer conn.Close()
	resp, err := await(r)
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(resp.Result, out); err != nil {
		return fmt.Errorf("herdr-core %s: %w", method, err)
	}
	return nil
}

// Stream is an events connection. fluxd reads the terminals again after
// each notification, so Next returns only the method of the
// notification: event, heartbeat, or missed.
type Stream struct {
	conn net.Conn
	r    *bufio.Reader
}

// Subscribe opens a connection that receives the changes of all
// terminals. It returns after herdr-core sent its snapshot.
func Subscribe(ctx context.Context, path string) (*Stream, error) {
	conn, r, err := open(ctx, path, "events.subscribe", struct{}{})
	if err != nil {
		return nil, err
	}
	if _, err := await(r); err != nil {
		conn.Close()
		return nil, err
	}
	// Notifications have no deadline. Close ends Next.
	_ = conn.SetDeadline(time.Time{})
	return &Stream{conn: conn, r: r}, nil
}

// Next blocks until the next notification arrives or the connection
// closes, and returns its method.
func (s *Stream) Next() (string, error) {
	for {
		resp, err := readReply(s.r)
		if err != nil {
			return "", err
		}
		if resp.ID == nil && resp.Method != "" {
			return resp.Method, nil
		}
	}
}

// Close ends the subscription.
func (s *Stream) Close() error { return s.conn.Close() }

// open connects, checks the owner of the socket, sends the request, and
// returns a reader for the replies.
func open(ctx context.Context, path, method string, params any) (net.Conn, *bufio.Reader, error) {
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", path)
	if err != nil {
		return nil, nil, err
	}
	if err := checkOwner(conn, os.Getuid()); err != nil {
		conn.Close()
		return nil, nil, err
	}
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(callTimeout)
	}
	_ = conn.SetDeadline(deadline)
	line, err := json.Marshal(request{JSONRPC: "2.0", ID: 1, Method: method, Params: params})
	if err != nil {
		conn.Close()
		return nil, nil, err
	}
	if _, err := conn.Write(append(line, '\n')); err != nil {
		conn.Close()
		return nil, nil, err
	}
	return conn, bufio.NewReader(conn), nil
}

// checkOwner checks with SO_PEERCRED that the server of conn runs as the
// user uid. HC_SOCKET can name a shared folder, where another user can
// listen first. That user must not get the prompts of the phone.
func checkOwner(conn net.Conn, uid int) error {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return errors.New("herdr-core: the socket is not a Unix socket")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return err
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return err
	}
	if credErr != nil {
		return credErr
	}
	if int(cred.Uid) != uid {
		return fmt.Errorf("herdr-core: the socket belongs to user %d, not to user %d", cred.Uid, uid)
	}
	return nil
}

// await reads replies until the response to the request arrives. It
// skips notifications.
func await(r *bufio.Reader) (response, error) {
	for {
		resp, err := readReply(r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				err = io.ErrUnexpectedEOF
			}
			return resp, err
		}
		if resp.ID == nil {
			continue
		}
		if resp.Error != nil {
			return resp, resp.Error
		}
		return resp, nil
	}
}

// errLineTooLong is the error for a reply line longer than maxLine.
var errLineTooLong = errors.New("herdr-core: reply line is too long")

// readReply reads and decodes the next reply line. It skips empty lines.
func readReply(r *bufio.Reader) (response, error) {
	var resp response
	for {
		line, err := readLine(r, maxLine)
		if err != nil {
			return resp, err
		}
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		if err := json.Unmarshal(line, &resp); err != nil {
			return resp, fmt.Errorf("herdr-core: %w", err)
		}
		return resp, nil
	}
}

// readLine reads one line of at most max bytes.
func readLine(r *bufio.Reader, max int) ([]byte, error) {
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		if len(line)+len(chunk) > max {
			return nil, errLineTooLong
		}
		line = append(line, chunk...)
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return line, err
	}
}

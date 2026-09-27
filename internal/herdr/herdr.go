// Package herdr is a client for the API socket of herdr, a terminal
// workspace manager for coding agents. fluxd uses it to show the herdr
// agents of this computer on a paired phone.
//
// The API uses JSON lines. A request has a string ID, a method, and a
// params object. A subscription connection receives events after its
// response.
package herdr

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
	"time"
)

// MinProtocol is the oldest herdr API protocol that Flux supports.
const MinProtocol = 22

// maxLine is the largest reply line that the client reads. An agent read
// with 400 lines is much smaller.
const maxLine = 32 << 20

// callTimeout limits a call when the context has no deadline.
const callTimeout = 5 * time.Second

// requestID is the ID of each request. Each call uses a new connection,
// so one fixed ID is enough.
const requestID = "flux"

// Statuses of an agent.
const (
	StatusIdle    = "idle"
	StatusWorking = "working"
	StatusBlocked = "blocked"
	StatusDone    = "done"
	StatusUnknown = "unknown"
)

// SocketPath returns the API socket of the default herdr session.
// HERDR_SOCKET_PATH overrides it. herdr sets that variable in its panes.
func SocketPath() string {
	if p := os.Getenv("HERDR_SOCKET_PATH"); p != "" {
		return p
	}
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "herdr", "herdr.sock")
}

// Error is an error response from herdr.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return "herdr: " + e.Message }

// Pong is the result of ping.
type Pong struct {
	Version  string `json:"version"`
	Protocol int    `json:"protocol"`
}

// Snapshot is the part of the session snapshot that Flux uses.
type Snapshot struct {
	Version    string      `json:"version"`
	Protocol   int         `json:"protocol"`
	Workspaces []Workspace `json:"workspaces"`
	Agents     []Agent     `json:"agents"`
}

// Workspace is one herdr workspace. Number is its place in the sidebar.
type Workspace struct {
	ID     string `json:"workspace_id"`
	Label  string `json:"label"`
	Number int    `json:"number"`
}

// Agent is a coding agent that herdr found in a pane.
type Agent struct {
	PaneID        string `json:"pane_id"`
	WorkspaceID   string `json:"workspace_id"`
	Agent         string `json:"agent"`
	Status        string `json:"agent_status"`
	Cwd           string `json:"cwd"`
	ForegroundCwd string `json:"foreground_cwd"`
	Title         string `json:"terminal_title_stripped"`
}

// Read is the recent terminal output of an agent.
type Read struct {
	PaneID    string `json:"pane_id"`
	Text      string `json:"text"`
	Truncated bool   `json:"truncated"`
}

// Subscription selects the events of a subscription connection. Some
// types, such as pane.agent_status_changed, need PaneID.
type Subscription struct {
	Type   string `json:"type"`
	PaneID string `json:"pane_id,omitempty"`
}

// Event is one event from a subscription connection.
type Event struct {
	Name string          `json:"event"`
	Data json.RawMessage `json:"data"`
}

type request struct {
	ID     string `json:"id"`
	Method string `json:"method"`
	Params any    `json:"params"`
}

type response struct {
	ID     string          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *Error          `json:"error"`
	Event  string          `json:"event"`
	Data   json.RawMessage `json:"data"`
}

// Ping returns the version and the API protocol of the herdr server.
func Ping(ctx context.Context, path string) (Pong, error) {
	var p Pong
	err := Call(ctx, path, "ping", nil, &p)
	return p, err
}

// GetSnapshot returns the workspaces and the agents of the session.
func GetSnapshot(ctx context.Context, path string) (Snapshot, error) {
	var r struct {
		Snapshot Snapshot `json:"snapshot"`
	}
	err := Call(ctx, path, "session.snapshot", nil, &r)
	return r.Snapshot, err
}

// ReadAgent returns up to lines rows of recent output from the agent in
// the pane. herdr joins soft-wrapped rows. With ansi, the text keeps the
// ANSI codes of colors and styles. Without it, herdr removes them.
func ReadAgent(ctx context.Context, path, pane string, lines int, ansi bool) (Read, error) {
	params := map[string]any{"target": pane, "source": "recent_unwrapped", "lines": lines}
	if ansi {
		params["format"], params["strip_ansi"] = "ansi", false
	}
	var r struct {
		Read Read `json:"read"`
	}
	err := Call(ctx, path, "agent.read", params, &r)
	return r.Read, err
}

// SendKeys sends key presses to the agent in the pane. herdr checks that
// an agent is in the pane and that each key name is valid before it
// writes a byte.
func SendKeys(ctx context.Context, path, pane string, keys []string) error {
	return Call(ctx, path, "agent.send_keys", map[string]any{"target": pane, "keys": keys}, nil)
}

// Prompt submits text and Enter to the agent in the pane. herdr refuses
// it with the code agent_blocked when the agent waits for an answer.
func Prompt(ctx context.Context, path, pane, text string) error {
	return Call(ctx, path, "agent.prompt", map[string]any{"target": pane, "text": text}, nil)
}

// SendInput types text in the pane and then sends the keys. It does not
// check for an agent. Use it only after herdr reported one.
func SendInput(ctx context.Context, path, pane, text string, keys []string) error {
	return Call(ctx, path, "pane.send_input", map[string]any{"pane_id": pane, "text": text, "keys": keys}, nil)
}

// Call sends one request on a new connection and decodes the result into
// out. out can be nil.
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
		return fmt.Errorf("herdr %s: %w", method, err)
	}
	return nil
}

// Stream is a subscription connection.
type Stream struct {
	conn net.Conn
	r    *bufio.Reader
}

// Subscribe opens a connection that receives the events of the
// subscriptions. It returns after herdr accepts them.
func Subscribe(ctx context.Context, path string, subs []Subscription) (*Stream, error) {
	params := map[string]any{"subscriptions": subs}
	conn, r, err := open(ctx, path, "events.subscribe", params)
	if err != nil {
		return nil, err
	}
	if _, err := await(r); err != nil {
		conn.Close()
		return nil, err
	}
	// Events have no deadline. Close ends Next.
	_ = conn.SetDeadline(time.Time{})
	return &Stream{conn: conn, r: r}, nil
}

// Next blocks until the next event arrives or the connection closes.
func (s *Stream) Next() (Event, error) {
	for {
		resp, err := readReply(s.r)
		if err != nil {
			return Event{}, err
		}
		if resp.Event != "" {
			return Event{Name: resp.Event, Data: resp.Data}, nil
		}
	}
}

// Close ends the subscription.
func (s *Stream) Close() error { return s.conn.Close() }

// open connects, sends the request, and returns a reader for the replies.
func open(ctx context.Context, path, method string, params any) (net.Conn, *bufio.Reader, error) {
	if params == nil {
		params = struct{}{}
	}
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, "unix", path)
	if err != nil {
		return nil, nil, err
	}
	deadline, ok := ctx.Deadline()
	if !ok {
		deadline = time.Now().Add(callTimeout)
	}
	_ = conn.SetDeadline(deadline)
	line, err := json.Marshal(request{ID: requestID, Method: method, Params: params})
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

// await reads replies until the response to the request arrives. It
// skips events.
func await(r *bufio.Reader) (response, error) {
	for {
		resp, err := readReply(r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				err = io.ErrUnexpectedEOF
			}
			return resp, err
		}
		if resp.Event != "" {
			continue
		}
		if resp.Error != nil {
			return resp, resp.Error
		}
		return resp, nil
	}
}

// errLineTooLong is the error for a reply line longer than maxLine.
var errLineTooLong = errors.New("herdr: reply line is too long")

// readReply reads and decodes the next reply line. It skips empty lines.
func readReply(r *bufio.Reader) (response, error) {
	var resp response
	for {
		line, err := readLine(r)
		if err != nil {
			return resp, err
		}
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		if err := json.Unmarshal(line, &resp); err != nil {
			return resp, fmt.Errorf("herdr: %w", err)
		}
		return resp, nil
	}
}

// readLine reads one line of at most maxLine bytes.
func readLine(r *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		if len(line)+len(chunk) > maxLine {
			return nil, errLineTooLong
		}
		line = append(line, chunk...)
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return line, err
	}
}

// Package ipc is the JSON lines protocol between fluxd and its clients on
// the Unix socket $XDG_RUNTIME_DIR/flux/fluxd.sock.
package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

// Request is one call from a client.
type Request struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Error is the error object of a response.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Message }

// Message is a response or an event from fluxd.
type Message struct {
	ID     int64           `json:"id,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *Error          `json:"error,omitempty"`
	Event  string          `json:"event,omitempty"`
	Data   json.RawMessage `json:"data,omitempty"`
}

// Handler runs the methods. An error with Code and Message fields keeps its
// code in the response.
type Handler interface {
	Call(ctx context.Context, method string, params json.RawMessage) (any, error)
	Subscribe(send func(event string, data any)) (cancel func())
}

// maxSocketPath is the longest Unix socket path that Linux accepts.
const maxSocketPath = 107

// Serve listens on the socket path until ctx ends.
func Serve(ctx context.Context, path string, h Handler) error {
	if len(path) > maxSocketPath {
		return fmt.Errorf("the socket path has %d bytes, and the limit is %d: %s", len(path), maxSocketPath, path)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	if c, err := net.DialTimeout("unix", path, 500*time.Millisecond); err == nil {
		c.Close()
		return fmt.Errorf("fluxd already runs on %s", path)
	}
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return err
	}
	go func() {
		<-ctx.Done()
		ln.Close()
		os.Remove(path)
	}()
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go serveConn(ctx, conn, h)
	}
}

func serveConn(ctx context.Context, conn net.Conn, h Handler) {
	defer conn.Close()
	var wmu sync.Mutex
	write := func(m Message) {
		b, err := json.Marshal(m)
		if err != nil {
			return
		}
		wmu.Lock()
		defer wmu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		_, _ = conn.Write(append(b, '\n'))
	}
	var cancel func()
	defer func() {
		if cancel != nil {
			cancel()
		}
	}()
	s := bufio.NewScanner(conn)
	s.Buffer(make([]byte, 64<<10), 16<<20)
	for s.Scan() {
		var req Request
		if err := json.Unmarshal(s.Bytes(), &req); err != nil {
			write(Message{Error: &Error{Code: "bad_request", Message: err.Error()}})
			continue
		}
		if req.Method == "subscribe" {
			if cancel == nil {
				cancel = h.Subscribe(func(event string, data any) {
					raw, err := marshal(data)
					if err == nil {
						write(Message{Event: event, Data: raw})
					}
				})
			}
			write(Message{ID: req.ID, Result: json.RawMessage("{}")})
			continue
		}
		go func(req Request) {
			res, err := h.Call(ctx, req.Method, req.Params)
			if err != nil {
				write(Message{ID: req.ID, Error: toError(err)})
				return
			}
			raw, err := marshal(res)
			if err != nil {
				write(Message{ID: req.ID, Error: toError(err)})
				return
			}
			write(Message{ID: req.ID, Result: raw})
		}(req)
	}
}

func marshal(v any) (json.RawMessage, error) {
	if raw, ok := v.(json.RawMessage); ok {
		return raw, nil
	}
	return json.Marshal(v)
}

// toError keeps the code of an error that encodes to {"code", "message"}.
func toError(err error) *Error {
	var e Error
	if b, merr := json.Marshal(err); merr == nil && json.Unmarshal(b, &e) == nil && e.Code != "" {
		return &e
	}
	return &Error{Code: "error", Message: err.Error()}
}

// Client is a connection to fluxd.
type Client struct {
	conn    net.Conn
	next    atomic.Int64
	mu      sync.Mutex
	pending map[int64]chan Message
	events  chan Message
	err     error
	done    chan struct{}
}

// Dial connects to fluxd.
func Dial(path string) (*Client, error) {
	conn, err := net.DialTimeout("unix", path, 2*time.Second)
	if err != nil {
		return nil, err
	}
	c := &Client{conn: conn, pending: map[int64]chan Message{}, events: make(chan Message, 16), done: make(chan struct{})}
	go c.readLoop()
	return c, nil
}

func (c *Client) readLoop() {
	s := bufio.NewScanner(c.conn)
	s.Buffer(make([]byte, 64<<10), 64<<20)
	for s.Scan() {
		var m Message
		if json.Unmarshal(s.Bytes(), &m) != nil {
			continue
		}
		if m.Event != "" {
			select {
			case c.events <- m:
			default:
			}
			continue
		}
		c.mu.Lock()
		ch := c.pending[m.ID]
		delete(c.pending, m.ID)
		c.mu.Unlock()
		if ch != nil {
			ch <- m
		}
	}
	c.mu.Lock()
	c.err = errors.New("fluxd closed the connection")
	for id, ch := range c.pending {
		close(ch)
		delete(c.pending, id)
	}
	c.mu.Unlock()
	close(c.done)
	close(c.events)
}

// Call sends a request and waits for the result.
func (c *Client) Call(method string, params any, result any) error {
	id := c.next.Add(1)
	req := Request{ID: id, Method: method}
	if params != nil {
		raw, err := json.Marshal(params)
		if err != nil {
			return err
		}
		req.Params = raw
	}
	b, _ := json.Marshal(req)
	ch := make(chan Message, 1)
	c.mu.Lock()
	if c.err != nil {
		c.mu.Unlock()
		return c.err
	}
	c.pending[id] = ch
	c.mu.Unlock()
	if _, err := c.conn.Write(append(b, '\n')); err != nil {
		return err
	}
	select {
	case m, ok := <-ch:
		if !ok {
			return errors.New("fluxd closed the connection")
		}
		if m.Error != nil {
			return m.Error
		}
		if result != nil && len(m.Result) > 0 {
			return json.Unmarshal(m.Result, result)
		}
		return nil
	case <-time.After(60 * time.Second):
		return errors.New("fluxd did not answer within 60 seconds")
	}
}

// Events returns the channel of events after Subscribe.
func (c *Client) Events() <-chan Message { return c.events }

// Close closes the connection.
func (c *Client) Close() error { return c.conn.Close() }

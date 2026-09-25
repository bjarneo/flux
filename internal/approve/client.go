package approve

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"

	"golang.org/x/sys/unix"
)

// maxLine is the longest line that the helper reads from fluxd.
const maxLine = 64 << 10

// RemoteError is an error that fluxd returns, with its code.
type RemoteError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *RemoteError) Error() string { return e.Message }

// conn is a small client of the fluxd socket for code that runs as root.
// It checks the user of the server, reads at most maxLine bytes per line,
// and has a deadline for each call.
type conn struct {
	c    net.Conn
	r    *bufio.Reader
	next int64
}

// dial connects to the fluxd socket and checks with SO_PEERCRED that the
// server runs as peerUID.
func dial(path string, peerUID int, timeout time.Duration) (*conn, error) {
	c, err := net.DialTimeout("unix", path, timeout)
	if err != nil {
		return nil, err
	}
	uc, ok := c.(*net.UnixConn)
	if !ok {
		c.Close()
		return nil, errors.New("the socket is not a Unix socket")
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		c.Close()
		return nil, err
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		c.Close()
		return nil, err
	}
	if credErr != nil {
		c.Close()
		return nil, credErr
	}
	if int(cred.Uid) != peerUID {
		c.Close()
		return nil, fmt.Errorf("the socket belongs to user %d, not to user %d", cred.Uid, peerUID)
	}
	return &conn{c: c, r: bufio.NewReaderSize(c, 4096)}, nil
}

func (c *conn) Close() error { return c.c.Close() }

// call sends 1 request and waits for its response until deadline.
func (c *conn) call(method string, params, result any, deadline time.Time) error {
	c.next++
	id := c.next
	req := map[string]any{"id": id, "method": method}
	if params != nil {
		req["params"] = params
	}
	b, err := json.Marshal(req)
	if err != nil {
		return err
	}
	if err := c.c.SetDeadline(deadline); err != nil {
		return err
	}
	if _, err := c.c.Write(append(b, '\n')); err != nil {
		return err
	}
	for {
		line, err := c.readLine()
		if err != nil {
			return err
		}
		var m struct {
			ID     int64           `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *RemoteError    `json:"error"`
		}
		if err := json.Unmarshal(line, &m); err != nil {
			return fmt.Errorf("fluxd sent a line that is not JSON: %w", err)
		}
		if m.ID != id {
			// An event or an old answer.
			continue
		}
		if m.Error != nil {
			return m.Error
		}
		if result != nil && len(m.Result) > 0 {
			return json.Unmarshal(m.Result, result)
		}
		return nil
	}
}

func (c *conn) readLine() ([]byte, error) {
	var out []byte
	for {
		part, isPrefix, err := c.r.ReadLine()
		if err != nil {
			return nil, err
		}
		out = append(out, part...)
		if len(out) > maxLine {
			return nil, fmt.Errorf("fluxd sent a line longer than %d bytes", maxLine)
		}
		if !isPrefix {
			return out, nil
		}
	}
}

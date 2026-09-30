package approve

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"time"

	"flux/internal/ipc"
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

// SocketPath returns the fixed fluxd socket of the user uid. It is the
// path that fluxd uses when XDG_RUNTIME_DIR is /run/user/<uid>. The helper
// and `flux-cli approve` do not read FLUX_SOCKET or XDG_RUNTIME_DIR,
// because the environment of a PAM caller is not trusted.
func SocketPath(uid int) string { return fmt.Sprintf("/run/user/%d/flux/fluxd.sock", uid) }

// dial connects to the fluxd socket. It checks that the folder of the
// socket and the socket belong to peerUID, and with SO_PEERCRED that the
// server runs as peerUID.
func dial(path string, peerUID int, timeout time.Duration) (*conn, error) {
	if err := ipc.CheckSocket(path, peerUID); err != nil {
		return nil, err
	}
	c, err := net.DialTimeout("unix", path, timeout)
	if err != nil {
		return nil, err
	}
	if err := ipc.CheckPeer(c, peerUID); err != nil {
		c.Close()
		return nil, err
	}
	return &conn{c: c, r: bufio.NewReaderSize(c, 4096)}, nil
}

// Reachable reports whether fluxd of the user uid answers on the socket
// path, with the same checks as the helper.
func Reachable(path string, uid int) error {
	c, err := dial(path, uid, dialTimeout)
	if err != nil {
		return err
	}
	return c.Close()
}

func (c *conn) Close() error { return c.c.Close() }

// cancelRequest ends a request on a new connection. It ignores errors.
func cancelRequest(path string, peerUID int, id string) {
	c, err := dial(path, peerUID, time.Second)
	if err != nil {
		return
	}
	defer c.Close()
	_ = c.call("approve.cancel", map[string]any{"id": id}, nil, time.Now().Add(time.Second))
}

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

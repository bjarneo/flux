package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// testHandler keeps the send function of the last subscriber.
type testHandler struct {
	mu   sync.Mutex
	send func(event string, data any)
	subs chan struct{}
	gone chan struct{}
	// ended gets the error of the context of a "wait" call when the
	// context ends.
	ended chan error
}

func (h *testHandler) Call(ctx context.Context, method string, params json.RawMessage) (any, error) {
	switch method {
	case "slow":
		time.Sleep(100 * time.Millisecond)
	case "wait":
		<-ctx.Done()
		h.ended <- ctx.Err()
		return nil, ctx.Err()
	}
	return map[string]string{"method": method}, nil
}

func (h *testHandler) Subscribe(send func(event string, data any)) func() {
	h.mu.Lock()
	h.send = send
	h.mu.Unlock()
	h.subs <- struct{}{}
	return func() { close(h.gone) }
}

// shortDir returns a new private folder with a short path, because Unix
// socket paths have a limit of 107 bytes.
func shortDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "ipc")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}

func serveTest(t *testing.T) (*testHandler, string) {
	path := filepath.Join(shortDir(t), "s")
	h := &testHandler{subs: make(chan struct{}, 1), gone: make(chan struct{}), ended: make(chan error, 1)}
	ln, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go Serve(ctx, ln, h)
	return h, path
}

func subscribe(t *testing.T, h *testHandler, path string) net.Conn {
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	if _, err := conn.Write([]byte(`{"id":1,"method":"subscribe"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-h.subs:
	case <-time.After(2 * time.Second):
		t.Fatal("no subscription")
	}
	return conn
}

// A client that reads nothing must not block the sender of events, and it
// loses its connection when its queue is full.
func TestSlowClientDoesNotBlock(t *testing.T) {
	h, path := serveTest(t)
	subscribe(t, h, path)
	h.mu.Lock()
	send := h.send
	h.mu.Unlock()
	big := strings.Repeat("x", 16<<10)
	start := time.Now()
	for range 4 * maxQueued {
		send("toast", map[string]any{"text": big})
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Errorf("the events took %v", d)
	}
	select {
	case <-h.gone:
	case <-time.After(2 * time.Second):
		t.Error("the slow client kept its subscription")
	}
}

// fluxd sends only the newest state event to a client that reads slowly.
func TestStateEventsMerge(t *testing.T) {
	h, path := serveTest(t)
	conn := subscribe(t, h, path)
	h.mu.Lock()
	send := h.send
	h.mu.Unlock()
	for i := range 10 * maxQueued {
		send("state", map[string]int{"n": i})
	}
	r := bufio.NewReader(conn)
	last := -1
	deadline := time.Now().Add(2 * time.Second)
	for last != 10*maxQueued-1 && time.Now().Before(deadline) {
		_ = conn.SetReadDeadline(deadline)
		line, err := r.ReadBytes('\n')
		if err != nil {
			t.Fatal(err)
		}
		var m struct {
			Event string `json:"event"`
			Data  struct {
				N int `json:"n"`
			} `json:"data"`
		}
		if json.Unmarshal(line, &m) != nil || m.Event != "state" {
			continue
		}
		if m.Data.N <= last {
			t.Fatalf("state %d came after state %d", m.Data.N, last)
		}
		last = m.Data.N
	}
	if last != 10*maxQueued-1 {
		t.Errorf("the last state is %d, want %d", last, 10*maxQueued-1)
	}
	select {
	case <-h.gone:
		t.Error("state events closed the connection")
	default:
	}
}

func TestCallAnswers(t *testing.T) {
	_, path := serveTest(t)
	c, err := Dial(path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	var res map[string]string
	if err := c.Call("ping", nil, &res); err != nil {
		t.Fatal(err)
	}
	if res["method"] != "ping" {
		t.Errorf("result = %v", res)
	}
}

// A client that sends a request and closes its write side still gets the
// answer, as with socat or nc -N.
func TestHalfCloseGetsAnswer(t *testing.T) {
	_, path := serveTest(t)
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(`{"id":7,"method":"slow"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	if err := conn.(*net.UnixConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	r := bufio.NewReader(conn)
	line, err := r.ReadBytes('\n')
	if err != nil {
		t.Fatalf("no answer after a half-close: %v", err)
	}
	var m Message
	if err := json.Unmarshal(line, &m); err != nil || m.ID != 7 || m.Error != nil {
		t.Fatalf("answer %s", line)
	}
	// After the last answer, fluxd closes the connection.
	if _, err := r.ReadBytes('\n'); err != io.EOF {
		t.Fatalf("after the answer: %v", err)
	}
}

// The context of a call ends when the client closes the connection, so an
// approval ends when its helper stops.
func TestCallEndsWhenClientCloses(t *testing.T) {
	h, path := serveTest(t)
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write([]byte(`{"id":1,"method":"wait"}` + "\n")); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	conn.Close()
	select {
	case err := <-h.ended:
		if err != context.Canceled {
			t.Fatalf("the context ended with %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the call went on after the client closed the connection")
	}
}

// failingListener fails the first Accept, as with EMFILE.
type failingListener struct {
	net.Listener
	failed bool
}

func (l *failingListener) Accept() (net.Conn, error) {
	if !l.failed {
		l.failed = true
		return nil, &net.OpError{Op: "accept", Net: "unix", Err: os.NewSyscallError("accept4", syscall.EMFILE)}
	}
	return l.Listener.Accept()
}

func TestAcceptErrorDoesNotStop(t *testing.T) {
	path := filepath.Join(shortDir(t), "s")
	ln, err := Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stopped := make(chan error, 1)
	h := &testHandler{subs: make(chan struct{}, 1), gone: make(chan struct{})}
	go func() { stopped <- Serve(ctx, &failingListener{Listener: ln}, h) }()
	c, err := Dial(path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if err := c.Call("ping", nil, nil); err != nil {
		t.Fatalf("a call after a failed accept: %v", err)
	}
	select {
	case err := <-stopped:
		t.Fatalf("Serve stopped: %v", err)
	default:
	}
	cancel()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatalf("Serve returned %v at the end", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not stop")
	}
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Errorf("the socket file stays: %v", err)
	}
}

func TestListenChecksTheFolder(t *testing.T) {
	base := shortDir(t)

	open := filepath.Join(base, "open")
	if err := os.Mkdir(open, 0o777); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(open, 0o777); err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(filepath.Join(open, "s")); err == nil || !strings.Contains(err.Error(), "other users can write") {
		t.Errorf("a folder that others can write to: %v", err)
	}

	// FLUX_SOCKET can name a folder that others can only read, such as the
	// home folder. Listen uses it and does not change its mode.
	read := filepath.Join(base, "read")
	if err := os.Mkdir(read, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(read, 0o755); err != nil {
		t.Fatal(err)
	}
	rl, err := Listen(filepath.Join(read, "s"))
	if err != nil {
		t.Fatalf("a folder that others can read: %v", err)
	}
	rl.Close()
	if st, err := os.Stat(read); err != nil || st.Mode().Perm() != 0o755 {
		t.Errorf("the folder that others can read: %v %v", st.Mode(), err)
	}
	// The runtime folder of Flux gets mode 0700.
	if err := PrivateDir(read); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(read); err != nil || st.Mode().Perm() != 0o700 {
		t.Errorf("the runtime folder: %v %v", st.Mode(), err)
	}
	if err := PrivateDir(open); err == nil {
		t.Error("PrivateDir took a folder that others can write to")
	}

	link := filepath.Join(base, "link")
	if err := os.Symlink(base, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(filepath.Join(link, "s")); err == nil || !strings.Contains(err.Error(), "not a folder") {
		t.Errorf("a symlink to a folder: %v", err)
	}

	// A missing folder gets mode 0700.
	made := filepath.Join(base, "made")
	ln, err := Listen(filepath.Join(made, "s"))
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	if st, err := os.Stat(made); err != nil || st.Mode().Perm() != 0o700 {
		t.Errorf("the new folder: %v %v", st.Mode(), err)
	}
	if st, err := os.Stat(filepath.Join(made, "s")); err != nil || st.Mode().Perm() != 0o600 {
		t.Errorf("the socket: %v %v", st.Mode(), err)
	}

	// A second fluxd does not take the socket.
	go Serve(context.Background(), ln, &testHandler{})
	if _, err := Listen(filepath.Join(made, "s")); err == nil || !strings.Contains(err.Error(), "already runs") {
		t.Errorf("a second listener: %v", err)
	}

	// A file that is not a socket stays.
	file := filepath.Join(made, "file")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Listen(file); err == nil {
		t.Error("Listen replaced a file that is not a socket")
	}
}

func TestDialRefusesAFile(t *testing.T) {
	path := filepath.Join(shortDir(t), "s")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Dial(path); err == nil || !strings.Contains(err.Error(), "not a socket") {
		t.Fatalf("got %v", err)
	}
}

// A client sends nothing to a socket of another user. The test cannot make
// a file of another user, so it asks for another user ID.
func TestCheckSocketOwner(t *testing.T) {
	_, path := serveTest(t)
	uid := os.Getuid()
	if err := CheckSocket(path, uid); err != nil {
		t.Fatalf("the socket of this user: %v", err)
	}
	if err := CheckSocket(path, uid+1); err == nil || !strings.Contains(err.Error(), "belongs to user") {
		t.Fatalf("another user: %v", err)
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := CheckPeer(conn, uid); err != nil {
		t.Fatalf("the peer of this user: %v", err)
	}
	if err := CheckPeer(conn, uid+1); err == nil {
		t.Fatal("the peer must belong to the other user")
	}
	if _, err := Dial(filepath.Join(filepath.Dir(path), "missing")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a missing socket: %v", err)
	}
}

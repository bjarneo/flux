package sshagent

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
	"golang.org/x/sys/unix"

	"flux/internal/ipc"
	"flux/internal/proto"
)

// Key is the public key of a phone, as the agent lists it.
type Key struct {
	// Blob is the public key in the SSH wire format.
	Blob []byte
	// Comment names the phone, for example "Flux on Pixel 8".
	Comment string
}

// Peer is the process at the other end of an agent connection.
type Peer struct {
	PID int
	// Program is the command line of the process, cleaned for the screen
	// of the phone, or "" when /proc does not show it. The process can
	// choose its own command line, so the program is only a hint.
	Program string
}

// Backend holds the keys of the phones and sends the sign requests.
type Backend interface {
	// SSHKeys returns the key of each connected phone that has one.
	SSHKeys() []Key
	// SSHSign asks the phone of keyBlob to sign data. ctx ends when the
	// client closes its connection.
	SSHSign(ctx context.Context, keyBlob, data []byte, peer Peer) (*ssh.Signature, error)
}

// ErrRefused is the error of each agent operation that Flux does not
// offer: add, remove, lock, and unlock. The client gets SSH_AGENT_FAILURE.
var ErrRefused = errors.New("the Flux agent only lists and signs with the keys of the phones")

// maxConns is the largest number of agent connections at the same time.
const maxConns = 64

// maxProgram is the longest program text that the agent sends to a phone,
// in bytes.
const maxProgram = 256

// hangupPoll is the time between 2 checks for a client that closed its
// connection during a sign request.
const hangupPoll = 200 * time.Millisecond

// Listen makes the agent socket at path with mode 0600. The folder must be
// a folder of this user that no other user can write to. Listen removes a
// socket that nobody answers on, and fails when a program answers on it.
func Listen(path string) (net.Listener, error) {
	if _, err := ipc.OwnDir(filepath.Dir(path)); err != nil {
		return nil, err
	}
	if c, err := net.DialTimeout("unix", path, 500*time.Millisecond); err == nil {
		c.Close()
		return nil, fmt.Errorf("another program answers on %s", path)
	}
	if st, err := os.Lstat(path); err == nil {
		if st.Mode().Type() != fs.ModeSocket {
			return nil, fmt.Errorf("%s exists and is not a socket", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// Serve answers the agent clients on ln until ctx ends. Then it closes ln,
// which also removes the socket file. It accepts only processes of this
// user and of root.
func Serve(ctx context.Context, ln net.Listener, b Backend, logf func(string, ...any)) error {
	stop := context.AfterFunc(ctx, func() { ln.Close() })
	defer stop()
	slots := make(chan struct{}, maxConns)
	var wait time.Duration
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			wait = min(max(2*wait, 5*time.Millisecond), time.Second)
			select {
			case <-time.After(wait):
			case <-ctx.Done():
				return nil
			}
			continue
		}
		wait = 0
		uc, ok := c.(*net.UnixConn)
		if !ok {
			c.Close()
			continue
		}
		select {
		case slots <- struct{}{}:
		default:
			logf("ssh agent: refused a connection, because %d connections are open", maxConns)
			c.Close()
			continue
		}
		go func() {
			defer func() { <-slots }()
			defer uc.Close()
			serveConn(ctx, uc, b, logf)
		}()
	}
}

func serveConn(ctx context.Context, c *net.UnixConn, b Backend, logf func(string, ...any)) {
	cred, err := peerCred(c)
	if err != nil {
		logf("ssh agent: %v", err)
		return
	}
	if int(cred.Uid) != os.Getuid() && cred.Uid != 0 {
		logf("ssh agent: refused a process of user %d", cred.Uid)
		return
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	// The context ends the open sign request when fluxd stops.
	context.AfterFunc(ctx, func() { c.Close() })
	a := &conn{ctx: ctx, c: c, b: b, peer: Peer{PID: int(cred.Pid), Program: program(int(cred.Pid))}}
	// A client that stops, for example after Ctrl+C, closes the
	// connection before the answer. That is no error of the agent.
	err = agent.ServeAgent(a, c)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) && !errors.Is(err, syscall.EPIPE) && !errors.Is(err, syscall.ECONNRESET) {
		logf("ssh agent: %v", err)
	}
}

func peerCred(c *net.UnixConn) (*unix.Ucred, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return nil, err
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return nil, err
	}
	return cred, credErr
}

// program reads the command line of the process pid from /proc. It
// returns "" when the process is gone or in another PID namespace.
func program(pid int) string {
	if pid <= 0 {
		return ""
	}
	f, err := os.Open("/proc/" + strconv.Itoa(pid) + "/cmdline")
	if err != nil {
		return ""
	}
	defer f.Close()
	b, _ := io.ReadAll(io.LimitReader(f, 4096))
	return CleanProgram(b)
}

// CleanProgram turns a command line from /proc into 1 line of text: the
// file name of the program without its folder, then the arguments, with 1
// space between them. Each control character and bidi control becomes a
// space. The line has at most maxProgram bytes, and a cut line ends with
// "…".
func CleanProgram(cmdline []byte) string {
	args := bytes.Split(bytes.TrimRight(cmdline, "\x00"), []byte{0})
	if i := bytes.LastIndexByte(args[0], '/'); i >= 0 && i < len(args[0])-1 {
		args[0] = args[0][i+1:]
	}
	var parts []string
	for _, a := range args {
		s := strings.Map(func(r rune) rune {
			if r == utf8.RuneError || proto.IsControl(r) {
				return ' '
			}
			return r
		}, string(a))
		if s = strings.Join(strings.Fields(s), " "); s != "" {
			parts = append(parts, s)
		}
	}
	s := strings.Join(parts, " ")
	if len(s) <= maxProgram {
		return s
	}
	const more = "…"
	cut := maxProgram - len(more)
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + more
}

// conn is the agent of 1 client connection.
type conn struct {
	ctx  context.Context
	c    *net.UnixConn
	b    Backend
	peer Peer
}

func (a *conn) List() ([]*agent.Key, error) {
	var out []*agent.Key
	for _, k := range a.b.SSHKeys() {
		pub, err := ssh.ParsePublicKey(k.Blob)
		if err != nil {
			continue
		}
		out = append(out, &agent.Key{Format: pub.Type(), Blob: k.Blob, Comment: k.Comment})
	}
	return out, nil
}

func (a *conn) Sign(key ssh.PublicKey, data []byte) (*ssh.Signature, error) {
	return a.SignWithFlags(key, data, 0)
}

// SignWithFlags signs with the key of a phone. The flags choose the hash of
// an RSA key, and an ECDSA key of a phone ignores them.
func (a *conn) SignWithFlags(key ssh.PublicKey, data []byte, _ agent.SignatureFlags) (*ssh.Signature, error) {
	ctx, cancel := context.WithCancel(a.ctx)
	defer cancel()
	stop := watchHangup(a.c, cancel)
	defer stop()
	return a.b.SSHSign(ctx, key.Marshal(), data, a.peer)
}

func (a *conn) Add(agent.AddedKey) error       { return ErrRefused }
func (a *conn) Remove(ssh.PublicKey) error     { return ErrRefused }
func (a *conn) RemoveAll() error               { return ErrRefused }
func (a *conn) Lock([]byte) error              { return ErrRefused }
func (a *conn) Unlock([]byte) error            { return ErrRefused }
func (a *conn) Signers() ([]ssh.Signer, error) { return nil, ErrRefused }
func (a *conn) Extension(string, []byte) ([]byte, error) {
	return nil, agent.ErrExtensionUnsupported
}

// watchHangup calls cancel when the client closes its connection. The
// agent reads no request while a sign request waits for the phone, so a
// poll finds the hang-up. stop ends the watch.
func watchHangup(c *net.UnixConn, cancel func()) (stop func()) {
	done := make(chan struct{})
	var once sync.Once
	go func() {
		t := time.NewTicker(hangupPoll)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
				if hungUp(c) {
					cancel()
					return
				}
			}
		}
	}()
	return func() { once.Do(func() { close(done) }) }
}

// hungUp reports whether the client closed its end of the connection.
func hungUp(c *net.UnixConn) bool {
	raw, err := c.SyscallConn()
	if err != nil {
		return true
	}
	closed := false
	if err := raw.Control(func(fd uintptr) {
		fds := []unix.PollFd{{Fd: int32(fd)}}
		if n, err := unix.Poll(fds, 0); err == nil && n > 0 {
			closed = fds[0].Revents&(unix.POLLHUP|unix.POLLERR) != 0
		}
	}); err != nil {
		return true
	}
	return closed
}

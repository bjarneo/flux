package lan

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"flux/internal/proto"
)

// Limits of the payload sockets. payloadWait is how long a payload server
// waits for the device. payloadHandshakes is the number of connections
// that it checks at the same time.
const (
	payloadWait       = 20 * time.Second
	payloadHandshakes = 4
)

// payloadIdle is how long a received payload can stop before the transfer
// fails. Tests make it shorter.
var payloadIdle = 60 * time.Second

// SendWithPayload sends a packet with a payload. It opens a payload server
// on a port from MinPayloadPort to MaxPayloadPort on the local address of
// the link, announces the port in the packet, and streams r to the device
// that connects. The payload server is the TLS server. progress receives
// the number of bytes sent so far.
//
// A peer that opens tunnels gets the payload through a tunnel instead, so
// the payload passes a firewall on this computer.
func (l *Link) SendWithPayload(ctx context.Context, p *proto.Packet, r io.Reader, size int64, progress func(int64)) error {
	if l.CanTunnel() {
		return l.pushPayload(ctx, p, r, size, progress)
	}
	host := ""
	if a, ok := l.LocalAddr().(*net.TCPAddr); ok {
		host = (&net.IPAddr{IP: a.IP, Zone: a.Zone}).String()
	}
	ln, port, err := listenPayload(ctx, host)
	if err != nil {
		return err
	}
	defer ln.Close()
	p.PayloadSize = size
	p.PayloadTransferInfo = &proto.TransferInfo{Port: port}
	if err := l.Send(p); err != nil {
		return err
	}
	tc, err := l.acceptPayload(ctx, ln)
	if err != nil {
		return err
	}
	defer tc.Close()
	stop := context.AfterFunc(ctx, func() { tc.Close() })
	defer stop()
	_, err = io.Copy(tc, &progressReader{r: r, fn: progress})
	return err
}

// acceptPayload accepts connections on ln until one of them comes from the
// address of the link and shows the certificate of the device, or until
// payloadWait ends. It closes the other connections, so that another host
// on the network cannot make the transfer fail.
func (l *Link) acceptPayload(ctx context.Context, ln net.Listener) (*tls.Conn, error) {
	// The transfer needs 1 connection, so the port closes when this ends.
	defer ln.Close()
	wait, cancel := context.WithTimeout(ctx, payloadWait)
	defer cancel()
	// A closed listener ends the accept loop.
	stop := context.AfterFunc(wait, func() { ln.Close() })
	defer stop()
	var (
		mu     sync.Mutex
		winner *tls.Conn
		ended  bool
	)
	ready := make(chan struct{})
	go func() {
		slots := make(chan struct{}, payloadHandshakes)
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			if !l.fromPeer(c) {
				c.Close()
				continue
			}
			select {
			case slots <- struct{}{}:
			default:
				c.Close()
				continue
			}
			go func() {
				defer func() { <-slots }()
				tc := l.payloadHandshake(wait, c)
				if tc == nil {
					return
				}
				mu.Lock()
				first := winner == nil && !ended
				if first {
					winner = tc
				}
				mu.Unlock()
				if !first {
					tc.Close()
					return
				}
				close(ready)
			}()
		}
	}()
	select {
	case <-ready:
	case <-wait.Done():
	case <-l.done:
	}
	mu.Lock()
	ended = true
	tc := winner
	mu.Unlock()
	select {
	case <-l.done:
		if tc != nil {
			tc.Close()
		}
		return nil, net.ErrClosed
	default:
	}
	switch {
	case tc != nil:
		return tc, nil
	case ctx.Err() != nil:
		return nil, ctx.Err()
	}
	return nil, errors.New("the device did not fetch the file. It can receive files only through an incoming connection, and the firewall blocks it")
}

// fromPeer reports whether c comes from the address of the link.
func (l *Link) fromPeer(c net.Conn) bool {
	a, ok := c.RemoteAddr().(*net.TCPAddr)
	if !ok || l.Addr == nil {
		return l.Addr == nil
	}
	return a.IP.Equal(l.Addr.IP)
}

// payloadHandshake runs the TLS handshake of a payload connection as the
// server. It returns nil and closes c when the peer is not the device of
// the link.
func (l *Link) payloadHandshake(ctx context.Context, c net.Conn) *tls.Conn {
	setUserTimeout(c)
	tc := tls.Server(c, serverConfig(l.provider.cfg.Cert))
	_ = tc.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tc.HandshakeContext(ctx); err != nil {
		tc.Close()
		return nil
	}
	if err := l.checkPeer(tc); err != nil {
		l.provider.logf("%s: a payload connection from %s: %v", l.Identity.DeviceName, c.RemoteAddr(), err)
		tc.Close()
		return nil
	}
	_ = tc.SetDeadline(time.Time{})
	return tc
}

// FetchPayload connects to the payload port of a received packet and
// returns the payload stream. The receiver is the TLS client. The stream
// fails when the device sends nothing for payloadIdle.
func (l *Link) FetchPayload(ctx context.Context, p *proto.Packet) (io.ReadCloser, error) {
	if !p.HasPayload() {
		return nil, errors.New("packet has no payload")
	}
	port := p.PayloadTransferInfo.Port
	if port < MinPayloadPort || port > MaxPayloadPort {
		return nil, fmt.Errorf("the device sent payload port %d, outside %d to %d", port, MinPayloadPort, MaxPayloadPort)
	}
	conn, err := l.dialPort(ctx, port)
	if err != nil {
		return nil, err
	}
	setUserTimeout(conn)
	tc := tls.Client(conn, clientConfig(l.provider.cfg.Cert))
	_ = tc.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tc.HandshakeContext(ctx); err != nil {
		tc.Close()
		return nil, fmt.Errorf("payload TLS: %w", err)
	}
	if err := l.checkPeer(tc); err != nil {
		tc.Close()
		return nil, err
	}
	_ = tc.SetDeadline(time.Time{})
	var rc io.ReadCloser = &idleConn{c: tc}
	if p.PayloadSize > 0 {
		rc = &limitedConn{Reader: io.LimitReader(rc, p.PayloadSize), c: tc}
	}
	return rc, nil
}

// idleConn fails a read when the peer sends nothing for payloadIdle. A
// stalled transfer then ends, and it does not hold the restart of fluxd.
type idleConn struct {
	c *tls.Conn
}

func (i *idleConn) Read(b []byte) (int, error) {
	_ = i.c.SetReadDeadline(time.Now().Add(payloadIdle))
	n, err := i.c.Read(b)
	if errors.Is(err, os.ErrDeadlineExceeded) {
		err = fmt.Errorf("the device sent nothing for %d seconds", int(payloadIdle.Seconds()))
	}
	return n, err
}

func (i *idleConn) Close() error { return i.c.Close() }

// checkPeer makes sure that the payload socket belongs to the same device
// as the link.
func (l *Link) checkPeer(tc *tls.Conn) error {
	cert, err := peerCert(tc)
	if err != nil {
		return err
	}
	if !bytes.Equal(cert.Raw, l.Cert.Raw) {
		return errors.New("payload certificate does not match the device")
	}
	return nil
}

// listenPayload listens on the first free port from MinPayloadPort to
// MaxPayloadPort on host. An empty host listens on every interface.
func listenPayload(ctx context.Context, host string) (net.Listener, int, error) {
	lc := net.ListenConfig{}
	for port := MinPayloadPort; port <= MaxPayloadPort; port++ {
		ln, err := lc.Listen(ctx, "tcp", net.JoinHostPort(host, fmt.Sprint(port)))
		if err == nil {
			return ln, port, nil
		}
	}
	return nil, 0, fmt.Errorf("no free payload port from %d to %d", MinPayloadPort, MaxPayloadPort)
}

type progressReader struct {
	r  io.Reader
	n  int64
	fn func(int64)
}

func (p *progressReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.n += int64(n)
	if p.fn != nil && n > 0 {
		p.fn(p.n)
	}
	return n, err
}

type limitedConn struct {
	io.Reader
	c io.Closer
}

func (l *limitedConn) Close() error { return l.c.Close() }

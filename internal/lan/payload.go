package lan

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"time"

	"flux/internal/proto"
)

// SendWithPayload sends a packet with a payload. It opens a payload server
// on a port from 1739 to 1764, announces the port in the packet, and
// streams r to the device that connects. The payload server is the TLS
// server. progress receives the number of bytes sent so far.
//
// A peer that opens tunnels gets the payload through a tunnel instead, so
// the payload passes a firewall on this computer.
func (l *Link) SendWithPayload(ctx context.Context, p *proto.Packet, r io.Reader, size int64, progress func(int64)) error {
	if l.CanTunnel() {
		return l.pushPayload(ctx, p, r, size, progress)
	}
	ln, port, err := listenPayload(ctx)
	if err != nil {
		return err
	}
	defer ln.Close()
	p.PayloadSize = size
	p.PayloadTransferInfo = &proto.TransferInfo{Port: port}
	if err := l.Send(p); err != nil {
		return err
	}

	accepted := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			close(accepted)
			return
		}
		accepted <- c
	}()
	var conn net.Conn
	select {
	case c, ok := <-accepted:
		if !ok {
			return errors.New("payload listener closed")
		}
		conn = c
	case <-time.After(20 * time.Second):
		return errors.New("the device did not fetch the file. It can receive files only through an incoming connection, and the firewall blocks it")
	case <-ctx.Done():
		return ctx.Err()
	case <-l.done:
		return net.ErrClosed
	}
	tc := tls.Server(conn, serverConfig(l.provider.cfg.Cert))
	defer tc.Close()
	stop := context.AfterFunc(ctx, func() { tc.Close() })
	defer stop()
	_ = tc.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tc.Handshake(); err != nil {
		return fmt.Errorf("payload TLS: %w", err)
	}
	if err := l.checkPeer(tc); err != nil {
		return err
	}
	_ = tc.SetDeadline(time.Time{})
	_, err = io.Copy(tc, &progressReader{r: r, fn: progress})
	return err
}

// FetchPayload connects to the payload port of a received packet and
// returns the payload stream. The receiver is the TLS client.
func (l *Link) FetchPayload(ctx context.Context, p *proto.Packet) (io.ReadCloser, error) {
	if !p.HasPayload() {
		return nil, errors.New("packet has no payload")
	}
	d := net.Dialer{Timeout: 10 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(l.IP(), fmt.Sprint(p.PayloadTransferInfo.Port)))
	if err != nil {
		return nil, err
	}
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
	var rc io.ReadCloser = tc
	if p.PayloadSize > 0 {
		rc = &limitedConn{Reader: io.LimitReader(tc, p.PayloadSize), c: tc}
	}
	return rc, nil
}

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

func listenPayload(ctx context.Context) (net.Listener, int, error) {
	lc := net.ListenConfig{}
	for port := MinPayloadPort; port <= MaxPayloadPort; port++ {
		ln, err := lc.Listen(ctx, "tcp", fmt.Sprintf(":%d", port))
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

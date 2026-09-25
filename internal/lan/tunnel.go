package lan

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"sync"
	"time"

	"flux/internal/proto"
)

// The Flux tunnel extension turns a payload socket around. In KDE Connect
// the sender of a payload listens and the receiver connects in, which a
// firewall on this computer blocks. With a tunnel, the phone listens, sends
// its port in a flux.tunnel packet, and fluxd connects out. The listener is
// the TLS server, and fluxd is the TLS client.

// tunnelWait is how long fluxd waits for the flux.tunnel packet.
const tunnelWait = 30 * time.Second

type tunnelReply struct {
	port int
	err  string
}

type tunnels struct {
	mu      sync.Mutex
	waiting map[string]chan tunnelReply
}

// CanTunnel reports whether the peer opens tunnel listeners. A peer that
// sends flux.tunnel packets lists the type in its outgoing capabilities.
func (l *Link) CanTunnel() bool {
	return slices.Contains(l.Identity.OutgoingCapabilities, proto.TypeFluxTunnel)
}

// TunnelReady passes the body of a flux.tunnel packet to the call that
// waits for it.
func (l *Link) TunnelReady(id string, port int, errMsg string) {
	l.tun.mu.Lock()
	ch := l.tun.waiting[id]
	delete(l.tun.waiting, id)
	l.tun.mu.Unlock()
	if ch != nil {
		ch <- tunnelReply{port: port, err: errMsg}
	}
}

// NewTunnelID returns a token for a tunnel and registers it. Call
// OpenTunnel with the token after the packet that names it is sent.
func (l *Link) NewTunnelID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	id := hex.EncodeToString(b)
	l.tun.mu.Lock()
	if l.tun.waiting == nil {
		l.tun.waiting = map[string]chan tunnelReply{}
	}
	l.tun.waiting[id] = make(chan tunnelReply, 1)
	l.tun.mu.Unlock()
	return id
}

// OpenTunnel waits for the port of tunnel id and connects to it. It returns
// the TLS connection after it checks the pinned certificate.
func (l *Link) OpenTunnel(ctx context.Context, id string) (*tls.Conn, error) {
	l.tun.mu.Lock()
	ch := l.tun.waiting[id]
	l.tun.mu.Unlock()
	if ch == nil {
		return nil, fmt.Errorf("no tunnel %s", id)
	}
	defer func() {
		l.tun.mu.Lock()
		delete(l.tun.waiting, id)
		l.tun.mu.Unlock()
	}()
	var reply tunnelReply
	select {
	case reply = <-ch:
	case <-time.After(tunnelWait):
		return nil, errors.New("the device did not open a tunnel within 30 seconds")
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-l.done:
		return nil, net.ErrClosed
	}
	if reply.err != "" {
		return nil, fmt.Errorf("the device could not open a tunnel: %s", reply.err)
	}
	if reply.port < MinPayloadPort || reply.port > MaxPayloadPort {
		return nil, fmt.Errorf("the device sent tunnel port %d, outside %d to %d", reply.port, MinPayloadPort, MaxPayloadPort)
	}
	d := net.Dialer{Timeout: 10 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(l.IP(), fmt.Sprint(reply.port)))
	if err != nil {
		return nil, err
	}
	tc := tls.Client(conn, clientConfig(l.provider.cfg.Cert))
	_ = tc.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tc.HandshakeContext(ctx); err != nil {
		tc.Close()
		return nil, fmt.Errorf("tunnel TLS: %w", err)
	}
	if err := l.checkPeer(tc); err != nil {
		tc.Close()
		return nil, err
	}
	_ = tc.SetDeadline(time.Time{})
	return tc, nil
}

// pushPayload sends a packet with a payload through a tunnel.
func (l *Link) pushPayload(ctx context.Context, p *proto.Packet, r io.Reader, size int64, progress func(int64)) error {
	id := l.NewTunnelID()
	p.PayloadSize = size
	p.PayloadTransferInfo = &proto.TransferInfo{Tunnel: id}
	if err := l.Send(p); err != nil {
		l.TunnelReady(id, 0, "canceled")
		return err
	}
	tc, err := l.OpenTunnel(ctx, id)
	if err != nil {
		return err
	}
	defer tc.Close()
	stop := context.AfterFunc(ctx, func() { tc.Close() })
	defer stop()
	_, err = io.Copy(tc, &progressReader{r: r, fn: progress})
	return err
}

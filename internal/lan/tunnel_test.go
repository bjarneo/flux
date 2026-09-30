package lan

import (
	"context"
	"crypto/tls"
	"net"
	"strings"
	"testing"
	"time"

	"flux/internal/proto"
)

// A fast peer can answer before OpenTunnel waits. The reply must stay for
// OpenTunnel, and a second reply must not block the packet handler.
func TestTunnelReplyBeforeOpen(t *testing.T) {
	l := &Link{}
	id := l.NewTunnelID()
	l.TunnelReady(id, 0, "busy")
	l.TunnelReady(id, 0, "again")
	_, err := l.OpenTunnel(context.Background(), id)
	if err == nil || !strings.Contains(err.Error(), "busy") {
		t.Fatalf("OpenTunnel = %v, want the first reply of the device", err)
	}
	if _, err := l.OpenTunnel(context.Background(), id); err == nil || !strings.Contains(err.Error(), "no tunnel") {
		t.Fatalf("OpenTunnel after the end = %v, want no tunnel", err)
	}
}

func TestCancelTunnel(t *testing.T) {
	l := &Link{}
	id := l.NewTunnelID()
	l.CancelTunnel(id)
	if _, err := l.OpenTunnel(context.Background(), id); err == nil || !strings.Contains(err.Error(), "no tunnel") {
		t.Fatalf("OpenTunnel after CancelTunnel = %v, want no tunnel", err)
	}
}

// Flux for Android takes a payload, tunnel, or stream connection only
// from the address of the link. DialPeer and FetchPayload connect from
// the local IP of the link, also when the kernel would choose another
// source address. The test uses 127.0.0.2, which only a bind selects.
func TestDialFromLinkAddress(t *testing.T) {
	ctx := context.Background()
	local := net.IPv4(127, 0, 0, 2)
	// The link: a TCP connection from 127.0.0.2 to 127.0.0.1.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	d := net.Dialer{LocalAddr: &net.TCPAddr{IP: local}}
	c, err := d.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Skipf("no 127.0.0.2 on this computer: %v", err)
	}
	defer c.Close()
	l := &Link{
		Addr:     &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)},
		provider: &Provider{},
		conn:     tls.Client(c, &tls.Config{}),
		done:     make(chan struct{}),
	}

	dials := map[string]func(port int) error{
		"DialPeer": func(port int) error {
			_, err := l.DialPeer(ctx, port)
			return err
		},
		"FetchPayload": func(port int) error {
			p := &proto.Packet{PayloadSize: 1, PayloadTransferInfo: &proto.TransferInfo{Port: port}}
			_, err := l.FetchPayload(ctx, p)
			return err
		},
	}
	for name, dial := range dials {
		peer, port, err := listenPayload(ctx, "127.0.0.1")
		if err != nil {
			t.Fatal(err)
		}
		from := make(chan net.Addr, 1)
		go func() {
			conn, err := peer.Accept()
			if err != nil {
				from <- nil
				return
			}
			from <- conn.RemoteAddr()
			// The handshake of the dial fails, and the test needs only the
			// source address.
			conn.Close()
		}()
		err = dial(port)
		// A dial that fails before the connect leaves Accept waiting.
		// Close peer only after the read, because a close resets a
		// connection that waits in the backlog.
		var a *net.TCPAddr
		select {
		case addr := <-from:
			a, _ = addr.(*net.TCPAddr)
		case <-time.After(5 * time.Second):
		}
		peer.Close()
		if a == nil || !a.IP.Equal(local) {
			t.Errorf("%s connected from %v, want %v. The dial returned %v", name, a, local, err)
		}
	}
}

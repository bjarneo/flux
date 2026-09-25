package lan

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"flux/internal/proto"
)

type peer struct {
	id    string
	cert  tls.Certificate
	prov  *Provider
	links chan *Link
	mu    sync.Mutex
	pins  map[string]*x509.Certificate
}

var nextPort = 27160

func newPeer(t *testing.T, ctx context.Context, name string, extraOutgoing ...string) *peer {
	t.Helper()
	cert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := &peer{id: id, cert: cert, links: make(chan *Link, 4), pins: map[string]*x509.Certificate{}}
	nextPort += 60
	p.prov = New(Config{
		Cert: cert,
		Identity: func() proto.Identity {
			ident := proto.NewIdentity(id, name, 0)
			ident.OutgoingCapabilities = append(append([]string{}, ident.OutgoingCapabilities...), extraOutgoing...)
			return ident
		},
		Trusted: func(dev string) (*x509.Certificate, bool) {
			p.mu.Lock()
			defer p.mu.Unlock()
			c, ok := p.pins[dev]
			return c, ok
		},
		HasLink:      func(string) bool { return false },
		OnLink:       func(l *Link) { p.links <- l },
		Logf:         t.Logf,
		UDPPort:      nextPort,
		FirstTCPPort: nextPort + 1,
	})
	if err := p.prov.Start(ctx); err != nil {
		t.Fatal(err)
	}
	return p
}

func (p *peer) udpAddr() *net.UDPAddr {
	return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: p.prov.cfg.UDPPort}
}

func waitLink(t *testing.T, ch chan *Link) *Link {
	t.Helper()
	select {
	case l := <-ch:
		return l
	case <-time.After(5 * time.Second):
		t.Fatal("no link within 5 seconds")
		return nil
	}
}

// TestHandshake runs discovery, the TLS handshake with the KDE Connect
// roles, and the second identity exchange between 2 providers.
func TestHandshake(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")

	// The desk broadcasts. The phone answers by TCP and is the TLS server.
	desk.prov.AnnounceTo(phone.udpAddr())
	onDesk := waitLink(t, desk.links)
	onPhone := waitLink(t, phone.links)

	if onDesk.DeviceID() != phone.id || onPhone.DeviceID() != desk.id {
		t.Fatalf("wrong peers: %s and %s", onDesk.DeviceID(), onPhone.DeviceID())
	}
	if onDesk.Identity.DeviceName != "phone" || onDesk.Identity.TCPPort != 0 {
		t.Errorf("identity after TLS: %+v", onDesk.Identity)
	}
	if !bytes.Equal(onDesk.Cert.Raw, phone.cert.Leaf.Raw) {
		t.Error("the desk did not get the phone certificate")
	}

	got := make(chan *proto.Packet, 1)
	go onPhone.Receive(func(p *proto.Packet) { got <- p })
	if err := onDesk.Send(proto.New(proto.TypePing, map[string]any{"message": "hi"})); err != nil {
		t.Fatal(err)
	}
	select {
	case p := <-got:
		if p.Type != proto.TypePing || p.Fields()["message"] != "hi" {
			t.Fatalf("unexpected packet %s %s", p.Type, p.Body)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("ping did not arrive")
	}
}

// TestPayload sends 1 MiB from the desk to the phone.
func TestPayload(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	desk.prov.AnnounceTo(phone.udpAddr())
	onDesk := waitLink(t, desk.links)
	onPhone := waitLink(t, phone.links)

	data := make([]byte, 1<<20)
	_, _ = rand.Read(data)
	packets := make(chan *proto.Packet, 1)
	go onPhone.Receive(func(p *proto.Packet) { packets <- p })

	sent := make(chan error, 1)
	go func() {
		p := proto.New(proto.TypeShare, map[string]any{"filename": "blob.bin"})
		sent <- onDesk.SendWithPayload(ctx, p, bytes.NewReader(data), int64(len(data)), nil)
	}()
	var p *proto.Packet
	select {
	case p = <-packets:
	case <-time.After(5 * time.Second):
		t.Fatal("share packet did not arrive")
	}
	if !p.HasPayload() || p.PayloadSize != int64(len(data)) {
		t.Fatalf("payload fields: size %d info %+v", p.PayloadSize, p.PayloadTransferInfo)
	}
	rc, err := onPhone.FetchPayload(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(rc)
	rc.Close()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("payload differs: got %d bytes", len(got))
	}
	if err := <-sent; err != nil {
		t.Fatalf("sender: %v", err)
	}
}

// TestPinnedCertificate refuses a link when the certificate differs from
// the pinned one.
func TestPinnedCertificate(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	other, _, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	desk.mu.Lock()
	desk.pins[phone.id] = other.Leaf
	desk.mu.Unlock()

	desk.prov.AnnounceTo(phone.udpAddr())
	select {
	case l := <-desk.links:
		t.Fatalf("the desk accepted a link with a changed certificate from %s", l.DeviceID())
	case <-time.After(1500 * time.Millisecond):
	}
}

// TestWrongTarget closes a connection whose identity names another device.
func TestWrongTarget(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")

	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", desk.prov.TCPPort()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	id := proto.NewIdentity("0123456789abcdef0123456789abcdef", "intruder", 0)
	id.TargetDeviceID = "ffffffffffffffffffffffffffffffff"
	id.TargetProtocolVersion = 8
	line, _ := proto.New(proto.TypeIdentity, id).Marshal()
	if _, err := conn.Write(line); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := bufio.NewReader(conn).ReadByte(); err == nil {
		t.Fatal("the desk answered a connection for another device")
	}
}

// TestPreferredAgrees checks that both sides of a simultaneous connection
// keep the same socket.
func TestPreferredAgrees(t *testing.T) {
	a, b := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	link := func(peer string, outgoing bool) *Link {
		return &Link{Identity: proto.Identity{DeviceID: peer}, Outgoing: outgoing, Started: time.Now()}
	}
	// Socket 1 is opened by a. Socket 2 is opened by b, the larger ID.
	for _, aFirst := range []bool{true, false} {
		for _, bFirst := range []bool{true, false} {
			aOld, aNew := link(b, true), link(b, false) // a's view of socket 1, then socket 2
			if !aFirst {
				aOld, aNew = aNew, aOld
			}
			bOld, bNew := link(a, false), link(a, true) // b's view of socket 1, then socket 2
			if !bFirst {
				bOld, bNew = bNew, bOld
			}
			aKeeps := Preferred(aOld, aNew, a)
			bKeeps := Preferred(bOld, bNew, b)
			// Both must keep socket 2: for a it is the link that is not
			// outgoing, and for b it is the outgoing link.
			if aKeeps.Outgoing || !bKeeps.Outgoing {
				t.Errorf("aFirst=%v bFirst=%v: a keeps outgoing=%v, b keeps outgoing=%v", aFirst, bFirst, aKeeps.Outgoing, bKeeps.Outgoing)
			}
		}
	}
	old := link(b, false)
	old.Started = time.Now().Add(-time.Minute)
	if next := link(b, true); Preferred(old, next, a) != next {
		t.Error("a reconnect after the race window must replace the old link")
	}
}

// TestDial connects without UDP, as fluxd does for a device that mDNS
// found. The dialing side must be the TCP client.
func TestDial(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	desk.prov.Dial(ctx, "127.0.0.1", phone.prov.TCPPort(), proto.Identity{DeviceID: phone.id, ProtocolVersion: 8})
	onDesk := waitLink(t, desk.links)
	onPhone := waitLink(t, phone.links)
	if !onDesk.Outgoing || onPhone.Outgoing {
		t.Fatalf("desk outgoing=%v, phone outgoing=%v", onDesk.Outgoing, onPhone.Outgoing)
	}
	if onDesk.DeviceID() != phone.id || onPhone.DeviceID() != desk.id {
		t.Fatal("wrong peers")
	}
}

// TestTunnelPayload sends a payload to a peer that opens tunnels. The test
// plays the phone side: it listens, sends flux.tunnel, and reads the bytes.
func TestTunnelPayload(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone", proto.TypeFluxTunnel)
	desk.prov.Dial(ctx, "127.0.0.1", phone.prov.TCPPort(), proto.Identity{DeviceID: phone.id, ProtocolVersion: 8})
	onDesk := waitLink(t, desk.links)
	onPhone := waitLink(t, phone.links)
	if !onDesk.CanTunnel() {
		t.Fatal("the desk does not see the tunnel capability of the phone")
	}
	go onDesk.Receive(func(p *proto.Packet) {
		if p.Type == proto.TypeFluxTunnel {
			f := p.Fields()
			port, _ := f["port"].(float64)
			onDesk.TunnelReady(fmt.Sprint(f["id"]), int(port), "")
		}
	})

	data := make([]byte, 300_000)
	_, _ = rand.Read(data)
	got := make(chan []byte, 1)
	go onPhone.Receive(func(p *proto.Packet) {
		if p.PayloadTransferInfo == nil || p.PayloadTransferInfo.Tunnel == "" || p.PayloadTransferInfo.Port != 0 {
			return
		}
		ln, port, err := listenPayload(ctx)
		if err != nil {
			t.Error(err)
			return
		}
		go func() {
			defer ln.Close()
			c, err := ln.Accept()
			if err != nil {
				return
			}
			tc := tls.Server(c, serverConfig(phone.cert))
			defer tc.Close()
			if err := tc.Handshake(); err != nil {
				t.Error(err)
				return
			}
			if cert, _ := peerCert(tc); cert == nil || !bytes.Equal(cert.Raw, desk.cert.Leaf.Raw) {
				t.Error("the tunnel client is not the desk")
				return
			}
			b, _ := io.ReadAll(io.LimitReader(tc, p.PayloadSize))
			got <- b
		}()
		_ = onPhone.Send(proto.New(proto.TypeFluxTunnel, map[string]any{"id": p.PayloadTransferInfo.Tunnel, "port": port}))
	})

	p := proto.New(proto.TypeShare, map[string]any{"filename": "tunnel.bin"})
	if err := onDesk.SendWithPayload(ctx, p, bytes.NewReader(data), int64(len(data)), nil); err != nil {
		t.Fatal(err)
	}
	select {
	case b := <-got:
		if !bytes.Equal(b, data) {
			t.Fatalf("tunnel payload differs: %d bytes", len(b))
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the phone did not receive the payload")
	}
}

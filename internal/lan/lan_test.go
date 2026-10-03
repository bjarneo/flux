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
	"strings"
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
	// logs receives each log line of the provider.
	logs chan string
	// oldApps receives the device ID of each identity of an app from
	// before Flux 0.8.
	oldApps chan string
}

func newPeer(t *testing.T, ctx context.Context, name string, extraOutgoing ...string) *peer {
	t.Helper()
	cert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p := &peer{id: id, cert: cert, links: make(chan *Link, 4), pins: map[string]*x509.Certificate{}, logs: make(chan string, 64), oldApps: make(chan string, 4)}
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
		HasLink: func(string) bool { return false },
		OnLink:  func(l *Link) { p.links <- l },
		OnOldApp: func(id proto.Identity, ip string) {
			select {
			case p.oldApps <- id.DeviceID:
			default:
			}
		},
		Logf: func(format string, args ...any) {
			line := fmt.Sprintf(format, args...)
			t.Log(line)
			select {
			case p.logs <- line:
			default:
			}
		},
		FreePorts: true,
	})
	if err := p.prov.Start(ctx); err != nil {
		t.Fatal(err)
	}
	return p
}

func (p *peer) udpAddr() *net.UDPAddr {
	return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: p.prov.UDPPort()}
}

// waitLog waits for a log line of the peer that contains text.
func (p *peer) waitLog(t *testing.T, text string) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case line := <-p.logs:
			if strings.Contains(line, text) {
				return
			}
		case <-deadline:
			t.Fatalf("no log line with %q within 5 seconds", text)
		}
	}
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

// TestHandshake runs discovery, the TLS handshake with the Flux roles,
// and the second identity exchange between 2 providers.
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
// the pinned one, in both roles: when the phone connects to the desk, and
// when the desk dials the phone. A link with the pinned certificate
// passes.
func TestPinnedCertificate(t *testing.T) {
	for _, dial := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		desk := newPeer(t, ctx, "desk")
		phone := newPeer(t, ctx, "phone")
		other, _, err := proto.LoadOrCreateCert(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		connect := func() {
			if dial {
				desk.prov.Dial(ctx, "127.0.0.1", phone.prov.TCPPort(), proto.Identity{DeviceID: phone.id, ProtocolVersion: 8})
			} else {
				desk.prov.AnnounceTo(phone.udpAddr())
			}
		}
		desk.mu.Lock()
		desk.pins[phone.id] = other.Leaf
		desk.mu.Unlock()
		connect()
		desk.waitLog(t, "certificate differs from the pinned certificate")
		select {
		case l := <-desk.links:
			t.Fatalf("dial=%v: the desk accepted a link with a changed certificate from %s", dial, l.DeviceID())
		default:
		}

		// A pin without a valid certificate refuses every link.
		desk.mu.Lock()
		desk.pins[phone.id] = nil
		desk.mu.Unlock()
		time.Sleep(attemptWindow)
		connect()
		desk.waitLog(t, "no valid pinned certificate")

		// The pinned certificate passes.
		desk.mu.Lock()
		desk.pins[phone.id] = phone.cert.Leaf
		desk.mu.Unlock()
		time.Sleep(attemptWindow)
		connect()
		if l := waitLink(t, desk.links); !bytes.Equal(l.Cert.Raw, phone.cert.Leaf.Raw) {
			t.Fatalf("dial=%v: the link has another certificate", dial)
		}
	}
}

// TestLineLimit checks that a link of a device that is not paired reads
// lines of up to 64 KiB, and that a paired link reads longer lines.
func TestLineLimit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	desk.prov.AnnounceTo(phone.udpAddr())
	onDesk := waitLink(t, desk.links)
	onPhone := waitLink(t, phone.links)

	big := proto.New(proto.TypePing, map[string]any{"message": strings.Repeat("x", 100<<10)})
	got := make(chan *proto.Packet, 1)
	done := make(chan error, 1)
	onDesk.SetPaired(true)
	go func() { done <- onDesk.Receive(func(p *proto.Packet) { got <- p }) }()
	if err := onPhone.Send(big); err != nil {
		t.Fatal(err)
	}
	select {
	case <-got:
	case <-time.After(5 * time.Second):
		t.Fatal("a paired link did not read a packet of 100 KiB")
	}
	onDesk.SetPaired(false)
	_ = onPhone.Send(big)
	select {
	case err := <-done:
		if err != errLineTooLong {
			t.Fatalf("Receive ended with %v, want %v", err, errLineTooLong)
		}
	case <-got:
		t.Fatal("a link that is not paired read a packet of 100 KiB")
	case <-time.After(5 * time.Second):
		t.Fatal("the link did not end")
	}
}

// TestHandshakeLimit closes an incoming connection when too many
// connections from the same address wait for their link.
func TestHandshakeLimit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	addr := fmt.Sprintf("127.0.0.1:%d", desk.prov.TCPPort())
	for range maxHandshakesPerIP {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
	}
	// The provider counts a connection when it accepts it. Wait until it
	// counted all of them.
	deadline := time.Now().Add(5 * time.Second)
	for {
		desk.prov.mu.Lock()
		n := desk.prov.perIP["127.0.0.1"]
		desk.prov.mu.Unlock()
		if n == maxHandshakesPerIP {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("%d connections wait, want %d", n, maxHandshakesPerIP)
		}
		time.Sleep(10 * time.Millisecond)
	}
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("the extra connection got %v, want EOF", err)
	}
}

// TestPeerPort checks the ports that discovery can make fluxd dial.
func TestPeerPort(t *testing.T) {
	p := New(Config{Identity: func() proto.Identity { return proto.Identity{} }})
	for port, want := range map[int]bool{MinTCPPort: true, MaxTCPPort: true, 22: false, 80: false, 1715: false, 1765: false, 0: false, 70000: false} {
		if got := p.peerPort(port); got != want {
			t.Errorf("peerPort(%d) = %v, want %v", port, got, want)
		}
	}
	if p := New(Config{Identity: func() proto.Identity { return proto.Identity{} }, FirstTCPPort: 28720}); !p.peerPort(28721) || p.peerPort(0) {
		t.Error("a provider with other ports must accept the ports of its peers")
	}
}

// TestAttemptsArePruned checks that the attempts map keeps only the
// devices of the last second.
func TestAttemptsArePruned(t *testing.T) {
	p := New(Config{Identity: func() proto.Identity { return proto.Identity{} }})
	for i := range 100 {
		if !p.shouldAttempt(fmt.Sprintf("%032d", i)) {
			t.Fatal("a new device must get an attempt")
		}
	}
	if p.shouldAttempt(fmt.Sprintf("%032d", 1)) {
		t.Fatal("a second attempt within 1 second must wait")
	}
	p.mu.Lock()
	for id := range p.attempts {
		p.attempts[id] = time.Now().Add(-2 * attemptWindow)
	}
	p.pruned = time.Now().Add(-2 * attemptWindow)
	p.mu.Unlock()
	p.shouldAttempt("new")
	p.mu.Lock()
	n := len(p.attempts)
	p.mu.Unlock()
	if n != 1 {
		t.Fatalf("%d attempts after the prune, want 1", n)
	}
}

// TestPayloadAfterStranger checks that a connection from another host with
// another certificate does not make a transfer fail.
func TestPayloadAfterStranger(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	desk.prov.AnnounceTo(phone.udpAddr())
	onDesk := waitLink(t, desk.links)
	onPhone := waitLink(t, phone.links)
	stranger, _, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	data := []byte("payload for the phone")
	packets := make(chan *proto.Packet, 1)
	go onPhone.Receive(func(p *proto.Packet) { packets <- p })
	sent := make(chan error, 1)
	go func() {
		sent <- onDesk.SendWithPayload(ctx, proto.New(proto.TypeShare, nil), bytes.NewReader(data), int64(len(data)), nil)
	}()
	var p *proto.Packet
	select {
	case p = <-packets:
	case <-time.After(5 * time.Second):
		t.Fatal("share packet did not arrive")
	}
	// The stranger connects first and shows its own certificate.
	c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", p.PayloadTransferInfo.Port))
	if err != nil {
		t.Fatal(err)
	}
	tc := tls.Client(c, clientConfig(stranger))
	_ = tc.Handshake()
	desk.waitLog(t, "payload connection")
	tc.Close()

	rc, err := onPhone.FetchPayload(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(rc)
	rc.Close()
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("payload %q, %v", got, err)
	}
	if err := <-sent; err != nil {
		t.Fatalf("sender: %v", err)
	}
}

// TestPayloadIdle checks that a received payload fails when the device
// shows its certificate and then sends nothing.
func TestPayloadIdle(t *testing.T) {
	old := payloadIdle
	payloadIdle = 100 * time.Millisecond
	t.Cleanup(func() { payloadIdle = old })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	desk.prov.AnnounceTo(phone.udpAddr())
	onDesk := waitLink(t, desk.links)
	waitLink(t, phone.links)
	ln, port, err := listenPayload(ctx, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		tc := tls.Server(c, serverConfig(phone.cert))
		defer tc.Close()
		if tc.Handshake() == nil {
			<-ctx.Done()
		}
	}()
	p := proto.New(proto.TypeShare, nil)
	p.PayloadSize, p.PayloadTransferInfo = 18, &proto.TransferInfo{Port: port}
	rc, err := onDesk.FetchPayload(ctx, p)
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	if _, err := io.ReadAll(rc); err == nil || !strings.Contains(err.Error(), "sent nothing") {
		t.Fatalf("read of a silent payload: %v", err)
	}
}

// TestPeerCertificateChecks checks that FetchPayload and DialPeer refuse a
// listener with another certificate, and that FetchPayload refuses a port
// outside the payload ports.
func TestPeerCertificateChecks(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	desk.prov.AnnounceTo(phone.udpAddr())
	onDesk := waitLink(t, desk.links)
	waitLink(t, phone.links)
	stranger, _, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	ln, port, err := listenPayload(ctx, "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				tc := tls.Server(c, serverConfig(stranger))
				_ = tc.Handshake()
				_, _ = tc.Write([]byte("not from the phone"))
				tc.Close()
			}()
		}
	}()
	p := proto.New(proto.TypeShare, nil)
	p.PayloadSize, p.PayloadTransferInfo = 18, &proto.TransferInfo{Port: port}
	if _, err := onDesk.FetchPayload(ctx, p); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("FetchPayload from a stranger: %v", err)
	}
	if _, err := onDesk.DialPeer(ctx, port); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("DialPeer to a stranger: %v", err)
	}
	p.PayloadTransferInfo.Port = 22
	if _, err := onDesk.FetchPayload(ctx, p); err == nil || !strings.Contains(err.Error(), "outside") {
		t.Fatalf("FetchPayload from port 22: %v", err)
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
		ln, port, err := listenPayload(ctx, "127.0.0.1")
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

// An app from before Flux 0.8 announces itself with the old identity
// type. The provider reports it and does not connect to it.
func TestOldAppIdentity(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	const phoneID = "b8657d84254547ff8f465063b44b840d"

	// The phone listener counts the connections of the desk.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	dials := make(chan struct{}, 4)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
			dials <- struct{}{}
		}
	}()
	port := ln.Addr().(*net.TCPAddr).Port

	conn, err := net.DialUDP("udp", nil, desk.udpAddr())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	send := func(typ string) {
		t.Helper()
		line, err := proto.New(typ, proto.NewIdentity(phoneID, "phone", port)).Marshal()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Write(line); err != nil {
			t.Fatal(err)
		}
	}

	send(proto.TypeOldIdentity)
	select {
	case id := <-desk.oldApps:
		if id != phoneID {
			t.Fatalf("old app %q", id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the old identity was not reported")
	}
	select {
	case <-dials:
		t.Fatal("the desk connected to an old app")
	case <-time.After(300 * time.Millisecond):
	}

	// A current identity gets a connection, and is not an old app.
	send(proto.TypeIdentity)
	select {
	case <-dials:
	case <-time.After(5 * time.Second):
		t.Fatal("the desk did not connect to a current identity")
	}
	select {
	case id := <-desk.oldApps:
		t.Fatalf("a current identity was reported as an old app: %s", id)
	default:
	}
}

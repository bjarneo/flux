package core

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"log"
	"math/big"
	"net"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/lan"
	"flux/internal/proto"
)

// logLines keeps the log lines of a test daemon.
type logLines struct {
	mu    sync.Mutex
	lines []string
}

func (l *logLines) Write(b []byte) (int, error) {
	l.mu.Lock()
	l.lines = append(l.lines, string(b))
	l.mu.Unlock()
	return len(b), nil
}

func (l *logLines) has(text string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return slices.ContainsFunc(l.lines, func(line string) bool { return strings.Contains(line, text) })
}

// pairDaemon returns a daemon with its own trust store and a LAN provider
// on free ports. Its links go through pinFor and onLink, as in fluxd.
func pairDaemon(t *testing.T, ctx context.Context) (*Daemon, *logLines) {
	t.Helper()
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	trust, err := config.LoadTrust()
	if err != nil {
		t.Fatal(err)
	}
	cert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	logs := &logLines{}
	d := &Daemon{
		cfg: &config.Config{}, trust: trust, cert: cert, selfID: id,
		devices: map[string]*Device{}, clip: &memClipboard{},
		dirty: make(chan struct{}, 1), ctx: ctx, logger: log.New(logs, "", 0),
	}
	p := lan.New(lan.Config{
		Cert:      cert,
		Identity:  func() proto.Identity { return proto.NewIdentity(id, "desk", 0) },
		Trusted:   d.pinFor,
		HasLink:   func(string) bool { return false },
		OnLink:    d.onLink,
		Logf:      d.logf,
		FreePorts: true,
	})
	if err := p.Start(ctx); err != nil {
		t.Fatal(err)
	}
	d.lan = p
	return d, logs
}

// testPeer is a device that links to a test daemon, for example a phone.
type testPeer struct {
	prov  *lan.Provider
	links chan *lan.Link
}

func newTestPeer(t *testing.T, ctx context.Context, cert tls.Certificate) *testPeer {
	t.Helper()
	id := cert.Leaf.Subject.CommonName
	p := &testPeer{links: make(chan *lan.Link, 4)}
	p.prov = lan.New(lan.Config{
		Cert:      cert,
		Identity:  func() proto.Identity { return proto.NewIdentity(id, "Pixel 8", 0) },
		Trusted:   func(string) (*x509.Certificate, bool) { return nil, false },
		HasLink:   func(string) bool { return false },
		OnLink:    func(l *lan.Link) { p.links <- l },
		Logf:      t.Logf,
		FreePorts: true,
	})
	if err := p.prov.Start(ctx); err != nil {
		t.Fatal(err)
	}
	return p
}

// connect makes the peer dial the daemon d on port.
func (p *testPeer) connect(ctx context.Context, d *Daemon, port int) {
	p.prov.Dial(ctx, "127.0.0.1", port, proto.Identity{DeviceID: d.selfID, ProtocolVersion: proto.ProtocolVersion})
}

// dial connects the peer to the daemon d on port and returns the link on
// the side of the peer.
func (p *testPeer) dial(t *testing.T, ctx context.Context, d *Daemon, port int) *lan.Link {
	t.Helper()
	p.connect(ctx, d, port)
	select {
	case l := <-p.links:
		return l
	case <-time.After(5 * time.Second):
		t.Fatal("no link within 5 seconds")
		return nil
	}
}

// certFor makes a self-signed certificate with id as its CN. Any host on
// the network can make one for a device ID that it saw.
func certFor(t *testing.T, id string) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: id},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
}

// strayLink returns a link on the side of the daemon from a device with
// cert. It comes from a second provider of the daemon without a pin check,
// like a link that passed the provider just before a pairing started.
func strayLink(t *testing.T, ctx context.Context, d *Daemon, cert tls.Certificate) *lan.Link {
	t.Helper()
	links := make(chan *lan.Link, 1)
	side := lan.New(lan.Config{
		Cert:      d.cert,
		Identity:  func() proto.Identity { return proto.NewIdentity(d.selfID, "desk", 0) },
		Trusted:   func(string) (*x509.Certificate, bool) { return nil, false },
		HasLink:   func(string) bool { return false },
		OnLink:    func(l *lan.Link) { links <- l },
		Logf:      t.Logf,
		FreePorts: true,
	})
	if err := side.Start(ctx); err != nil {
		t.Fatal(err)
	}
	newTestPeer(t, ctx, cert).dial(t, ctx, d, side.TCPPort())
	select {
	case l := <-links:
		return l
	case <-time.After(5 * time.Second):
		t.Fatal("no stray link within 5 seconds")
		return nil
	}
}

// packets reads the packets of a link into a channel.
func packets(l *lan.Link) chan *proto.Packet {
	ch := make(chan *proto.Packet, 256)
	go l.Receive(func(p *proto.Packet) { ch <- p })
	return ch
}

// nextPair returns the body of the next flux.pair packet from ch.
func nextPair(t *testing.T, ch chan *proto.Packet) map[string]any {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case p := <-ch:
			if p.Type != proto.TypePair {
				continue
			}
			var body map[string]any
			if err := p.Decode(&body); err != nil {
				t.Fatal(err)
			}
			return body
		case <-deadline:
			t.Fatal("no pair packet within 5 seconds")
			return nil
		}
	}
}

// linked waits until the device has a link and returns the device and the
// link on the side of the daemon.
func linked(t *testing.T, d *Daemon, id string) (*Device, *lan.Link) {
	t.Helper()
	var dev *Device
	var l *lan.Link
	waitFor(t, "a link of "+id, func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		dev = d.devices[id]
		if dev != nil {
			l = dev.link
		}
		return l != nil
	})
	return dev, l
}

// field reads a value of the device under d.mu.
func field[T any](d *Daemon, get func() T) T {
	d.mu.Lock()
	defer d.mu.Unlock()
	return get()
}

func waitClosed(t *testing.T, l *lan.Link) {
	t.Helper()
	select {
	case <-l.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the link did not close")
	}
}

// pinned returns the certificate in the trust store for the device.
func pinned(t *testing.T, d *Daemon, id string) *x509.Certificate {
	t.Helper()
	tr, ok := d.trust.Get(id)
	if !ok {
		return nil
	}
	c, err := proto.ParseCertPEM(tr.CertPEM)
	if err != nil {
		t.Fatalf("the trust store has a bad certificate: %v", err)
	}
	return c
}

// phonePair starts a daemon and links a phone to it. It returns the daemon,
// its log, the certificate of the phone, the device on the daemon, the
// link on the daemon, the link on the phone, and the packets that the
// phone receives.
func phonePair(t *testing.T, ctx context.Context) (*Daemon, *logLines, tls.Certificate, *Device, *lan.Link, *lan.Link, chan *proto.Packet) {
	t.Helper()
	d, logs := pairDaemon(t, ctx)
	cert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	onPhone := newTestPeer(t, ctx, cert).dial(t, ctx, d, d.lan.TCPPort())
	fromDesk := packets(onPhone)
	dev, onDesk := linked(t, d, id)
	return d, logs, cert, dev, onDesk, onPhone, fromDesk
}

// TestPairRequestIgnoresSecondLink is the regression test for a pairing
// that the desktop starts. A second link with the ID of the phone and
// another certificate must not replace the link of the pairing, and its
// pair answer must not pin its certificate.
func TestPairRequestIgnoresSecondLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, logs, phoneCert, dev, onDesk, onPhone, fromDesk := phonePair(t, ctx)

	key, err := d.RequestPair(dev)
	if err != nil {
		t.Fatal(err)
	}
	req := nextPair(t, fromDesk)
	ts := int64(req["timestamp"].(float64))
	if want := proto.VerificationKey(phoneCert.Leaf, d.cert.Leaf, ts); key != want || len(key) != 16 {
		t.Fatalf("key %q, want %q", key, want)
	}

	// An attacker links with the ID of the phone and its own certificate.
	evilCert := certFor(t, dev.ID)
	newTestPeer(t, ctx, evilCert).connect(ctx, d, d.lan.TCPPort())
	waitFor(t, "the refusal of the attacker", func() bool { return logs.has("certificate differs from the pinned certificate") })

	// A link that passed the provider before the pairing started.
	stray := strayLink(t, ctx, d, evilCert)
	d.handlePacket(dev, stray, proto.New(proto.TypePair, map[string]any{"pair": true}))
	d.onLink(stray)
	waitClosed(t, stray)
	if l, state := field(d, func() *lan.Link { return dev.link }), field(d, func() string { return dev.pairState }); l != onDesk || state != "requested" {
		t.Fatalf("after the attacker: link changed %v, pair state %q", l != onDesk, state)
	}
	if pinned(t, d, dev.ID) != nil {
		t.Fatal("the attacker got a trust entry")
	}

	// The phone accepts on the link of the request. fluxd waits for the
	// user of the computer.
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the confirm state", func() bool { return field(d, func() string { return dev.pairState }) == "confirm" })
	if err := d.AcceptPair(dev, key); err != nil {
		t.Fatal(err)
	}
	if c := pinned(t, d, dev.ID); c == nil || !c.Equal(phoneCert.Leaf) {
		t.Fatal("the trust store does not pin the certificate of the phone")
	}

	// A paired device refuses a link with another certificate.
	stray = strayLink(t, ctx, d, evilCert)
	d.onLink(stray)
	waitClosed(t, stray)
	if field(d, func() *lan.Link { return dev.link }) != onDesk {
		t.Fatal("a link with another certificate replaced the link of the paired device")
	}
}

// TestPairAcceptIgnoresSecondLink is the regression test for a pairing
// that the phone starts. The user compares the key of the phone, so Accept
// must pin the certificate of the phone.
func TestPairAcceptIgnoresSecondLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, phoneCert, dev, _, onPhone, fromDesk := phonePair(t, ctx)

	ts := time.Now().Unix()
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the incoming request", func() bool { return field(d, func() string { return dev.pairState }) == "incoming" })
	if key := field(d, func() string { return dev.pairKey }); key != proto.VerificationKey(d.cert.Leaf, phoneCert.Leaf, ts) {
		t.Fatalf("key %q", key)
	}

	stray := strayLink(t, ctx, d, certFor(t, dev.ID))
	d.handlePacket(dev, stray, proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts + 1}))
	d.onLink(stray)
	waitClosed(t, stray)

	if err := d.AcceptPair(dev, proto.VerificationKey(d.cert.Leaf, phoneCert.Leaf, ts)); err != nil {
		t.Fatal(err)
	}
	if body := nextPair(t, fromDesk); body["pair"] != true {
		t.Fatalf("answer %v", body)
	}
	if c := pinned(t, d, dev.ID); c == nil || !c.Equal(phoneCert.Leaf) {
		t.Fatal("the trust store does not pin the certificate of the phone")
	}
}

// TestAcceptReadsLongLines checks that the link reads the long lines of a
// paired device from the first packet after the answer. Flux for Android
// sends its clipboard when it reads pair true, and the clipboard can be
// longer than the line limit of a device that is not paired.
func TestAcceptReadsLongLines(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, dev, onDesk, onPhone, fromDesk := phonePair(t, ctx)
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": time.Now().Unix()})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the incoming request", func() bool { return field(d, func() string { return dev.pairState }) == "incoming" })

	accepted := make(chan error, 1)
	go func() { accepted <- d.AcceptPair(dev, "") }()
	if body := nextPair(t, fromDesk); body["pair"] != true {
		t.Fatalf("answer %v", body)
	}
	long := strings.Repeat("x", 100<<10)
	if err := onPhone.Send(proto.New(proto.TypeClipboardConnect, map[string]any{"content": long})); err != nil {
		t.Fatal(err)
	}
	if err := <-accepted; err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the long clipboard", func() bool {
		return field(d, func() bool {
			return slices.ContainsFunc(d.clipboard, func(e ClipEntry) bool { return e.Text == long })
		})
	})
	if field(d, func() *lan.Link { return dev.link }) != onDesk {
		t.Fatal("the long line closed the link")
	}
}

// TestAcceptOnce checks that 2 accepts at the same time answer the device
// once, that the device stays paired, and that the result shows the key of
// the request.
func TestAcceptOnce(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, phoneCert, dev, onDesk, onPhone, fromDesk := phonePair(t, ctx)
	ts := time.Now().Unix()
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the incoming request", func() bool { return field(d, func() string { return dev.pairState }) == "incoming" })

	type result struct {
		res any
		err error
	}
	results := make(chan result, 2)
	for range 2 {
		go func() {
			res, err := d.pairCall("pair.accept", dev, "")
			results <- result{res, err}
		}()
	}
	var ok []any
	for range 2 {
		r := <-results
		switch {
		case r.err == nil:
			ok = append(ok, r.res)
		case errCode(r.err) != "no_request":
			t.Fatalf("second accept: %v", r.err)
		}
	}
	if len(ok) != 1 {
		t.Fatalf("%d accepts of 1 request", len(ok))
	}
	want := proto.VerificationKey(d.cert.Leaf, phoneCert.Leaf, ts)
	if key := ok[0].(map[string]any)["key"]; key != want {
		t.Fatalf("key %v, want %s", key, want)
	}

	// The phone gets 1 answer and no unpair. A ping marks the end.
	_ = onDesk.Send(proto.New(proto.TypePing, nil))
	answers := 0
	for done := false; !done; {
		select {
		case p := <-fromDesk:
			switch p.Type {
			case proto.TypePing:
				done = true
			case proto.TypePair:
				if p.Fields()["pair"] != true {
					t.Fatalf("the phone got %s", p.Body)
				}
				answers++
			}
		case <-time.After(5 * time.Second):
			t.Fatal("no marker packet")
		}
	}
	if answers != 1 {
		t.Fatalf("the phone got %d answers", answers)
	}
	if !field(d, func() bool { return dev.Paired }) || pinned(t, d, dev.ID) == nil {
		t.Fatal("the device is not paired after the accept")
	}
}

// TestAcceptSendFails checks that fluxd removes the pin again when the
// answer to a pair request cannot go out.
func TestAcceptSendFails(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _ := pairDaemon(t, ctx)
	cert, _, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// No receive loop reads the stray link, so it stays the link of the
	// device after it closed.
	l := strayLink(t, ctx, d, cert)
	dev := newDevice(l.DeviceID())
	d.mu.Lock()
	d.devices[dev.ID] = dev
	dev.link, dev.pairLink, dev.pairCert, dev.pairState = l, l, l.Cert, "incoming"
	d.mu.Unlock()
	l.Close()
	if err := d.AcceptPair(dev, ""); err == nil {
		t.Fatal("AcceptPair succeeded without the answer")
	}
	if field(d, func() bool { return dev.Paired }) || pinned(t, d, dev.ID) != nil {
		t.Fatal("the pin stays after the answer failed")
	}
}

// TestPairingEndsWithItsLink checks that a new link of the device ends an
// open pairing, and that Accept then pins nothing.
func TestPairingEndsWithItsLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, phoneCert, dev, onDesk, onPhone, _ := phonePair(t, ctx)

	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": time.Now().Unix()})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the incoming request", func() bool { return field(d, func() string { return dev.pairState }) == "incoming" })

	// The phone links again with the same certificate.
	newTestPeer(t, ctx, phoneCert).dial(t, ctx, d, d.lan.TCPPort())
	waitFor(t, "the new link", func() bool { return field(d, func() *lan.Link { return dev.link }) != onDesk })
	if state := field(d, func() string { return dev.pairState }); state != "" {
		t.Fatalf("pair state %q after a new link", state)
	}
	if err := d.AcceptPair(dev, ""); errCode(err) != "no_request" {
		t.Fatalf("AcceptPair after a new link: %v", err)
	}

	// An accept refuses a pairing whose link is not the current link, in
	// both states that wait for the user of this computer.
	for _, state := range []string{"incoming", "confirm"} {
		d.mu.Lock()
		dev.pairState, dev.pairLink, dev.pairCert = state, onDesk, phoneCert.Leaf
		d.mu.Unlock()
		if err := d.AcceptPair(dev, ""); errCode(err) != "no_request" {
			t.Fatalf("AcceptPair in state %s on an old link: %v", state, err)
		}
	}
	if pinned(t, d, dev.ID) != nil || field(d, func() bool { return dev.Paired }) {
		t.Fatal("the device is paired")
	}
}

// TestHandlePairChecks covers the branches of the pairing state machine.
func TestHandlePairChecks(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, dev, onDesk, onPhone, fromDesk := phonePair(t, ctx)
	send := func(body map[string]any) {
		t.Helper()
		// Each case is a new request, so it comes after the cooldown.
		d.mu.Lock()
		dev.pairAt = time.Time{}
		d.mu.Unlock()
		if err := onPhone.Send(proto.New(proto.TypePair, body)); err != nil {
			t.Fatal(err)
		}
	}
	state := func() string { return field(d, func() string { return dev.pairState }) }
	refused := func(what string) {
		t.Helper()
		if body := nextPair(t, fromDesk); body["pair"] != false {
			t.Fatalf("%s: answer %v", what, body)
		}
		if s := state(); s != "" {
			t.Fatalf("%s: pair state %q", what, s)
		}
	}

	send(map[string]any{"pair": true, "timestamp": time.Now().Add(31 * time.Minute).Unix()})
	refused("a clock 31 minutes ahead")
	send(map[string]any{"pair": true, "timestamp": time.Now().Add(-31 * time.Minute).Unix()})
	refused("a clock 31 minutes behind")
	send(map[string]any{"pair": true})
	refused("no timestamp")

	// Too many open requests of other devices.
	d.mu.Lock()
	for i := range maxIncoming {
		o := newDevice(fmt.Sprintf("%032d", i))
		o.pairState = "incoming"
		d.devices[o.ID] = o
	}
	d.mu.Unlock()
	send(map[string]any{"pair": true, "timestamp": time.Now().Unix()})
	refused("too many requests")
	d.mu.Lock()
	for i := range maxIncoming {
		delete(d.devices, fmt.Sprintf("%032d", i))
	}
	d.mu.Unlock()

	ts := time.Now().Add(-29 * time.Minute).Unix()
	send(map[string]any{"pair": true, "timestamp": ts})
	waitFor(t, "a request with a clock 29 minutes behind", func() bool { return state() == "incoming" })

	// A new request within the cooldown keeps the open request.
	d.mu.Lock()
	dev.pairAt = time.Now()
	d.mu.Unlock()
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts + 5})); err != nil {
		t.Fatal(err)
	}
	// A packet of an unpaired device shows when the link read it.
	if err := onPhone.Send(proto.New(proto.TypePing, nil)); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the ping", func() bool { return field(d, func() int { return dev.ignored }) > 0 })
	if got := field(d, func() int64 { return dev.pairTime }); got != ts {
		t.Fatalf("a request within the cooldown changed the timestamp to %d", got)
	}

	if err := d.AcceptPair(dev, ""); err != nil {
		t.Fatal(err)
	}
	nextPair(t, fromDesk)
	if pinned(t, d, dev.ID) == nil {
		t.Fatal("no trust entry after Accept")
	}

	// A paired device that asks again loses its trust, and the user must
	// compare the key again.
	send(map[string]any{"pair": true, "timestamp": time.Now().Unix()})
	waitFor(t, "a new request of a paired device", func() bool { return state() == "incoming" })
	if pinned(t, d, dev.ID) != nil || field(d, func() bool { return dev.Paired }) {
		t.Fatal("a paired device that asks again keeps its trust")
	}
	if err := d.AcceptPair(dev, ""); err != nil {
		t.Fatal(err)
	}
	nextPair(t, fromDesk)

	// The device unpairs. fluxd removes the trust and closes the link.
	send(map[string]any{"pair": false})
	waitClosed(t, onDesk)
	if pinned(t, d, dev.ID) != nil || field(d, func() bool { return dev.Paired }) {
		t.Fatal("the device keeps its trust after it unpaired")
	}
}

// TestPairTimeout checks that a request ends after pairTimeout, and that
// the device gets pair false.
func TestPairTimeout(t *testing.T) {
	old := pairTimeout
	pairTimeout = 100 * time.Millisecond
	t.Cleanup(func() { pairTimeout = old })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, dev, _, _, fromDesk := phonePair(t, ctx)
	if _, err := d.RequestPair(dev); err != nil {
		t.Fatal(err)
	}
	if body := nextPair(t, fromDesk); body["pair"] != true {
		t.Fatalf("request %v", body)
	}
	if body := nextPair(t, fromDesk); body["pair"] != false {
		t.Fatalf("after the timeout %v", body)
	}
	waitFor(t, "the end of the request", func() bool { return field(d, func() string { return dev.pairState }) == "" })
	if err := d.AcceptPair(dev, ""); errCode(err) != "no_request" {
		t.Fatalf("AcceptPair after the timeout: %v", err)
	}
	// The phone did not answer the request of this computer, so a request
	// of the phone counts at once.
	if !field(d, func() time.Time { return dev.pairEnded }).IsZero() {
		t.Fatal("the timeout of a request of this computer started the retry wait")
	}
}

// TestUnpairClosesLink checks that Unpair tells the device, closes the
// link, and removes what the device shared.
func TestUnpairClosesLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, dev, onDesk, onPhone, fromDesk := phonePair(t, ctx)
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": time.Now().Unix()})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the incoming request", func() bool { return field(d, func() string { return dev.pairState }) == "incoming" })
	if err := d.AcceptPair(dev, ""); err != nil {
		t.Fatal(err)
	}
	nextPair(t, fromDesk)
	d.mu.Lock()
	dev.battery = &Battery{Charge: 80}
	dev.notifications = []*PhoneNotification{{ID: "1"}}
	dev.conversations = map[int64]*Conversation{1: {}}
	dev.outbox = []OutboxMessage{{Thread: 1, Body: "On my way", Pending: true}}
	d.mu.Unlock()

	if err := d.Unpair(dev); err != nil {
		t.Fatal(err)
	}
	if body := nextPair(t, fromDesk); body["pair"] != false {
		t.Fatalf("answer %v", body)
	}
	waitClosed(t, onDesk)
	d.mu.Lock()
	left := dev.battery != nil || len(dev.notifications) > 0 || len(dev.conversations) > 0 || len(dev.outbox) > 0 || dev.Paired
	d.mu.Unlock()
	if left || pinned(t, d, dev.ID) != nil {
		t.Fatal("the device keeps its trust or its data after Unpair")
	}
	if err := d.Unpair(dev); errCode(err) != "not_paired" {
		t.Fatalf("Unpair of a device that is not paired: %v", err)
	}
	if err := d.RejectPair(dev, ""); errCode(err) != "no_request" {
		t.Fatalf("RejectPair without a request: %v", err)
	}
}

// TestPinnedDevice checks the pin of a paired device on both checks: the
// provider before the identity exchange, and onLink. A test without the
// pin fails here. The certificate of the pairing passes.
func TestPinnedDevice(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, logs := pairDaemon(t, ctx)
	phoneCert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := config.TrustedDevice{ID: id, Name: "Pixel 8", CertPEM: proto.CertPEM(phoneCert.Leaf), PairedAt: "2026-09-29"}
	if err := d.trust.Put(entry); err != nil {
		t.Fatal(err)
	}
	dev := newDevice(id)
	if err := dev.applyTrust(entry); err != nil {
		t.Fatal(err)
	}
	d.devices[id] = dev
	evilCert := certFor(t, id)

	newTestPeer(t, ctx, evilCert).connect(ctx, d, d.lan.TCPPort())
	waitFor(t, "the refusal in the provider", func() bool { return logs.has("certificate differs from the pinned certificate") })
	stray := strayLink(t, ctx, d, evilCert)
	d.onLink(stray)
	waitClosed(t, stray)
	if field(d, func() *lan.Link { return dev.link }) != nil {
		t.Fatal("a link with another certificate got the paired device")
	}

	newTestPeer(t, ctx, phoneCert).dial(t, ctx, d, d.lan.TCPPort())
	_, l := linked(t, d, id)
	if !l.Cert.Equal(phoneCert.Leaf) || !field(d, func() bool { return dev.Paired }) {
		t.Fatal("the link with the pinned certificate is not a paired link")
	}
	// onLink saves the address after the link is up. Wait for it, so that
	// the file is complete before the test removes the folder.
	waitFor(t, "the saved address", func() bool { tr, _ := d.trust.Get(id); return tr.LastIP != "" })
}

// TestBadTrustEntry checks that a trust entry with a certificate that does
// not parse refuses every link and counts as not paired.
func TestBadTrustEntry(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, logs := pairDaemon(t, ctx)
	phoneCert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	entry := config.TrustedDevice{ID: id, Name: "Pixel 8", CertPEM: "not a certificate"}
	if err := d.trust.Put(entry); err != nil {
		t.Fatal(err)
	}
	dev := newDevice(id)
	if err := dev.applyTrust(entry); err == nil {
		t.Fatal("applyTrust accepted a bad certificate")
	}
	d.devices[id] = dev
	if dev.Paired {
		t.Fatal("a device with a bad certificate counts as paired")
	}
	if c, ok := d.pinFor(id); c != nil || !ok {
		t.Fatal("a bad trust entry must refuse every certificate")
	}
	newTestPeer(t, ctx, phoneCert).connect(ctx, d, d.lan.TCPPort())
	waitFor(t, "the refusal in the provider", func() bool { return logs.has("no valid pinned certificate") })
	stray := strayLink(t, ctx, d, phoneCert)
	d.onLink(stray)
	waitClosed(t, stray)

	if err := d.Unpair(dev); err != nil {
		t.Fatal(err)
	}
	if _, ok := d.trust.Get(id); ok {
		t.Fatal("Unpair kept the bad trust entry")
	}
}

// packetTypes returns the values of the Type constants of the proto
// package. A new packet type is then in the gate test at once.
func packetTypes(t *testing.T) []string {
	t.Helper()
	files, err := filepath.Glob("../proto/*.go")
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	fset := token.NewFileSet()
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, decl := range f.Decls {
			gen, ok := decl.(*ast.GenDecl)
			if !ok || gen.Tok != token.CONST {
				continue
			}
			for _, spec := range gen.Specs {
				vs := spec.(*ast.ValueSpec)
				for i, n := range vs.Names {
					if !strings.HasPrefix(n.Name, "Type") || i >= len(vs.Values) {
						continue
					}
					if lit, ok := vs.Values[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
						v, _ := strconv.Unquote(lit.Value)
						out = append(out, v)
					}
				}
			}
		}
	}
	if len(out) < 20 {
		t.Fatalf("found only %d packet types", len(out))
	}
	return out
}

// TestHandlePacketIgnoresUnpairedDevice sends each packet type from a
// device that is not paired. Only flux.pair passes the gate.
func TestHandlePacketIgnoresUnpairedDevice(t *testing.T) {
	d, _ := clipDaemon(t, true)
	dev := newDevice("phone")
	l := &lan.Link{Identity: proto.Identity{DeviceID: "phone"}}
	dev.link = l
	d.devices[dev.ID] = dev
	n := 0
	for _, typ := range packetTypes(t) {
		if typ == proto.TypePair {
			continue
		}
		d.handlePacket(dev, l, proto.New(typ, map[string]any{"content": "x", "request": true}))
		if n++; dev.ignored != n {
			t.Fatalf("%s from a device that is not paired passed the gate", typ)
		}
	}

	// A paired device counts only on its current link.
	dev.Paired = true
	d.handlePacket(dev, &lan.Link{}, proto.New(proto.TypeClipboard, map[string]any{"content": "from an old link"}))
	if len(d.clipboard) != 0 {
		t.Fatal("a packet from an old link reached the clipboard")
	}
}

func TestLookup(t *testing.T) {
	d := &Daemon{devices: map[string]*Device{}}
	add := func(id, name string, paired, linked bool, state string) *Device {
		dev := newDevice(fmt.Sprintf("%032s", id))
		dev.Name, dev.Paired, dev.pairState = name, paired, state
		if linked {
			dev.link = &lan.Link{}
		}
		d.devices[dev.ID] = dev
		return dev
	}
	phone := add("a", "Pixel 8", true, true, "")
	udp := add("b", "Pixel 8", false, false, "")
	asking := add("c", "pixel 8", false, true, "incoming")

	if dev, err := d.find("pixel 8", nil); err != nil || dev != phone {
		t.Fatalf("a name must find the paired device: %v", err)
	}
	if dev, _ := d.find(udp.ID, nil); dev != udp {
		t.Fatal("an exact ID must win")
	}
	incoming := func(dev *Device) bool { return dev.pairState == "incoming" }
	if dev, err := d.find("Pixel 8", incoming); err != nil || dev != asking {
		t.Fatalf("accept must find the device with the request: %v", err)
	}
	if _, err := d.find("Nothing", nil); errCode(err) != "not_found" {
		t.Fatalf("an unknown name: %v", err)
	}

	// 2 devices of the same kind with 1 name are ambiguous.
	other := add("d", "Pixel 8", true, false, "")
	_, err := d.find("Pixel 8", nil)
	if errCode(err) != "ambiguous" || !strings.Contains(err.Error(), phone.ID) || !strings.Contains(err.Error(), other.ID) {
		t.Fatalf("2 paired devices with 1 name: %v", err)
	}
	add("e", "pixel 8", false, true, "incoming")
	if _, err := d.find("Pixel 8", incoming); errCode(err) != "ambiguous" {
		t.Fatalf("2 requests with 1 name: %v", err)
	}

	// Accept by name finds no device without a request.
	delete(d.devices, asking.ID)
	for id, dev := range d.devices {
		if dev.pairState != "" {
			delete(d.devices, id)
		}
	}
	raw, _ := json.Marshal(map[string]any{"device": "Pixel 8"})
	if _, err := d.Call(context.Background(), "pair.accept", raw); errCode(err) != "no_request" {
		t.Fatalf("pair.accept without a request: %v", err)
	}
	// A pair request by the name of a paired device says that it is paired.
	add("f", "Solo", true, true, "")
	raw, _ = json.Marshal(map[string]any{"device": "Solo"})
	if _, err := d.Call(context.Background(), "pair.request", raw); errCode(err) != "paired" {
		t.Fatalf("pair.request to a paired device: %v", err)
	}
}

// TestDiscoveryKeepsPairedAddress checks that UDP and mDNS do not change
// the address of a paired device. The address is only a dial candidate.
func TestDiscoveryKeepsPairedAddress(t *testing.T) {
	id := strings.Repeat("a", 32)
	d := &Daemon{devices: map[string]*Device{}}
	phone := newDevice(id)
	phone.Paired, phone.Name, phone.Type = true, "Pixel 8", "phone"
	phone.IP, phone.Port, phone.Addresses = "192.168.1.20", 12100, []string{"pixel-8"}
	d.devices[id] = phone

	d.onIdentity(proto.Identity{DeviceID: id, DeviceName: "Evil", DeviceType: "\x1b]52;c;aGk=\x07", TCPPort: 12101}, "192.168.1.66")
	d.onMDNS(lan.MDNSPeer{DeviceID: id, Name: "Evil", IP: "192.168.1.67", Port: 12102, Protocol: 8})
	if phone.IP != "192.168.1.20" || phone.Port != 12100 || phone.Name != "Pixel 8" || phone.Type != "phone" {
		t.Fatalf("discovery changed the paired device: %s:%d %q %q", phone.IP, phone.Port, phone.Name, phone.Type)
	}
	want := []string{"192.168.1.20:12100", "192.168.1.67:12102", "pixel-8:12100"}
	if got := phone.dialAddrs(time.Now()); !slices.Equal(got, want) {
		t.Fatalf("dialAddrs = %v, want %v", got, want)
	}

	// A device that is not paired takes the address and a clean name.
	other := strings.Repeat("b", 32)
	d.onIdentity(proto.Identity{DeviceID: other, DeviceName: "Pixel\x1bc 7", DeviceType: "\x1b]52;c;aGk=\x07", TCPPort: 12100}, "192.168.1.30")
	if dev := d.devices[other]; dev.IP != "192.168.1.30" || dev.Name != "Pixelc 7" || dev.Type != "" {
		t.Fatalf("unpaired device: %s %q %q", dev.IP, dev.Name, dev.Type)
	}
}

// TestDiscoveredDevicesAreBounded sends identities with new IDs and a
// large device type. fluxd keeps at most maxDiscovered of them. A device
// that gets pair false on its next link stays.
func TestDiscoveredDevicesAreBounded(t *testing.T) {
	d := &Daemon{devices: map[string]*Device{}}
	phone := newDevice(strings.Repeat("p", 32))
	phone.Paired = true
	d.devices[phone.ID] = phone
	owed := newDevice(strings.Repeat("q", 32))
	owed.unpairPeer = true
	d.devices[owed.ID] = owed
	big := strings.Repeat("x", 60<<10)
	for i := range 1000 {
		d.onIdentity(proto.Identity{DeviceID: fmt.Sprintf("%032x", i), DeviceType: big, TCPPort: 12100}, "192.0.2.1")
	}
	if n := len(d.devices); n > maxDiscovered+2 {
		t.Fatalf("%d devices after 1000 identities", n)
	}
	if d.devices[phone.ID] != phone {
		t.Fatal("the paired device is gone")
	}
	if d.devices[owed.ID] != owed {
		t.Fatal("the device that gets pair false is gone")
	}
	if dev := d.devices[fmt.Sprintf("%032x", 999)]; dev == nil || dev.Type != "" {
		t.Fatal("the newest device is missing or keeps its type")
	}
}

// TestUnpairedLinkLimits checks which links of devices that are not paired
// fluxd closes when a new link comes.
func TestUnpairedLinkLimits(t *testing.T) {
	d := &Daemon{devices: map[string]*Device{}}
	start := time.Now().Add(-time.Minute)
	n := 0
	add := func(ip string, paired bool, state string) (*Device, *lan.Link) {
		n++
		l := &lan.Link{Addr: &net.TCPAddr{IP: net.ParseIP(ip)}, Started: start.Add(time.Duration(n) * time.Second)}
		dev := newDevice(fmt.Sprintf("%032d", n))
		dev.link, dev.Paired, dev.pairState = l, paired, state
		d.devices[dev.ID] = dev
		return dev, l
	}
	_, a1 := add("10.0.0.1", false, "")
	_, a2 := add("10.0.0.1", false, "")
	_, a3 := add("10.0.0.1", false, "")
	if out := d.unpairedOverflowLocked(a3); !slices.Equal(out, []*lan.Link{a1}) {
		t.Fatalf("3 links from 1 address: closes %d links", len(out))
	}
	// A link with an open pairing stays.
	d.devices[fmt.Sprintf("%032d", 1)].pairState = "incoming"
	if out := d.unpairedOverflowLocked(a3); !slices.Equal(out, []*lan.Link{a2}) {
		t.Fatal("the link with a pairing was closed")
	}
	// Paired devices do not count, and the limit in total applies.
	d.devices = map[string]*Device{}
	add("10.0.0.9", true, "")
	var first, last *lan.Link
	for i := range maxUnpairedLinks + 1 {
		_, l := add(fmt.Sprintf("10.0.1.%d", i), false, "")
		if first == nil {
			first = l
		}
		last = l
	}
	if out := d.unpairedOverflowLocked(last); !slices.Equal(out, []*lan.Link{first}) {
		t.Fatalf("%d links: closes %d links", maxUnpairedLinks+1, len(out))
	}
}

// TestCloseIdleLinks checks that fluxd closes the link of a device that is
// not paired and sends no pair request, and keeps a link with a pairing.
func TestCloseIdleLinks(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, dev, onDesk, _, _ := phonePair(t, ctx)
	later := time.Now().Add(unpairedIdle + time.Second)
	d.mu.Lock()
	dev.pairState = "incoming"
	d.mu.Unlock()
	d.closeIdleLinks(later)
	select {
	case <-onDesk.Done():
		t.Fatal("fluxd closed a link with a pairing")
	default:
	}
	d.mu.Lock()
	dev.pairState = ""
	d.mu.Unlock()
	d.closeIdleLinks(later)
	waitClosed(t, onDesk)
}

// TestConnectClipboardSkipsHiddenCopy checks that a device that connects
// gets only the last text that Watch reported. Watch does not report a
// password manager copy, so that copy stays on the desktop.
func TestConnectClipboardSkipsHiddenCopy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, _, onDesk, _, fromDesk := phonePair(t, ctx)
	clip := d.clip.(*memClipboard)
	d.mu.Lock()
	d.cfg.AutoClipboard = true
	d.lastLocalClip = time.Now()
	d.content.lastClip = ""
	d.mu.Unlock()

	next := func() *proto.Packet {
		t.Helper()
		_ = onDesk.Send(proto.New(proto.TypePing, nil))
		var got *proto.Packet
		for {
			select {
			case p := <-fromDesk:
				if p.Type == proto.TypePing {
					return got
				}
				if p.Type == proto.TypeClipboardConnect {
					got = p
				}
			case <-time.After(5 * time.Second):
				t.Fatal("no marker packet")
			}
		}
	}
	_ = clip.Set("hunter2")
	d.sendConnectClipboard(onDesk)
	if p := next(); p != nil {
		t.Fatalf("fluxd sent a copy that Watch did not report: %s", p.Body)
	}
	d.mu.Lock()
	d.content.lastClip = "normal text"
	d.mu.Unlock()
	d.sendConnectClipboard(onDesk)
	p := next()
	if p == nil || !strings.Contains(string(p.Body), "normal text") {
		t.Fatal("fluxd did not send the synced copy")
	}
	if strings.Contains(string(p.Body), "hunter2") {
		t.Fatalf("fluxd sent the live clipboard: %s", p.Body)
	}
}

// TestRecoverPacket checks that a panic in a packet handler ends in a log
// line with the stack, and that fluxd stops only when the panic leaves
// d.mu locked.
func TestRecoverPacket(t *testing.T) {
	oldWait, oldExit := muWait, exitProcess
	t.Cleanup(func() { muWait, exitProcess = oldWait, oldExit })
	muWait = 500 * time.Millisecond
	code := -1
	exitProcess = func(c int) { code = c }

	logs := &logLines{}
	d := &Daemon{logger: log.New(logs, "", 0)}
	func() {
		defer d.recoverPacket(nil, proto.New("flux.test\n", nil))
		panic("broken handler")
	}()
	if !logs.has("broken handler") || !logs.has(`"flux.test\n"`) || !logs.has("goroutine") {
		t.Fatalf("log %q", logs.lines)
	}
	if code != -1 {
		t.Fatalf("fluxd stopped with %d after a panic without the lock", code)
	}

	// Another goroutine holds d.mu for a short time.
	d.mu.Lock()
	time.AfterFunc(20*time.Millisecond, d.mu.Unlock)
	func() {
		defer d.recoverPacket(nil, proto.New("flux.test", nil))
		panic("broken handler")
	}()
	if code != -1 {
		t.Fatalf("fluxd stopped with %d while another goroutine held the lock", code)
	}

	// The handler panics while it holds d.mu.
	func() {
		defer d.recoverPacket(nil, proto.New("flux.test", nil))
		d.mu.Lock()
		panic("broken handler")
	}()
	if code != 1 || !logs.has("left the daemon locked") {
		t.Fatalf("exit code %d after a panic with the lock, log %q", code, logs.lines)
	}
}

// TestSendNeedsPairing checks that a feature packet does not reach a
// device that is not paired.
func TestSendNeedsPairing(t *testing.T) {
	d := &Daemon{devices: map[string]*Device{}}
	dev := newDevice("phone")
	dev.link = &lan.Link{}
	if err := d.send(dev, proto.New(proto.TypePing, nil)); errCode(err) != "not_paired" {
		t.Fatalf("send to a device that is not paired: %v", err)
	}
	dev.link = nil
	if err := d.send(dev, proto.New(proto.TypePing, nil)); errCode(err) != "offline" {
		t.Fatalf("send to an offline device: %v", err)
	}
}

func TestFingerprintInState(t *testing.T) {
	cert, id, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	dev := newDevice(id)
	if dev.view().Fingerprint != "" {
		t.Fatal("a device without a certificate has a fingerprint")
	}
	dev.Cert = cert.Leaf
	if fp := dev.view().Fingerprint; fp != proto.Fingerprint(cert.Leaf) || len(fp) != 16 {
		t.Fatalf("fingerprint %q", fp)
	}
}

// confirmState makes the daemon ask the phone to pair, and makes the phone
// accept. It returns the key of the pairing.
func confirmState(t *testing.T, d *Daemon, dev *Device, onPhone *lan.Link, fromDesk chan *proto.Packet) string {
	t.Helper()
	key, err := d.RequestPair(dev)
	if err != nil {
		t.Fatal(err)
	}
	if body := nextPair(t, fromDesk); body["pair"] != true {
		t.Fatalf("request %v", body)
	}
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the confirm state", func() bool { return field(d, func() string { return dev.pairState }) == "confirm" })
	return key
}

// noPairBefore sends a ping marker on the link of the daemon and fails
// when the phone gets a pair packet before it.
func noPairBefore(t *testing.T, onDesk *lan.Link, fromDesk chan *proto.Packet) {
	t.Helper()
	_ = onDesk.Send(proto.New(proto.TypePing, nil))
	for {
		select {
		case p := <-fromDesk:
			switch p.Type {
			case proto.TypePing:
				return
			case proto.TypePair:
				t.Fatalf("the phone got %s", p.Body)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("no marker packet")
		}
	}
}

// TestConfirmNeedsLocalAccept checks a pairing that the desktop starts.
// The answer of the phone does not pin the phone. Only an accept on this
// computer with the key of the pairing pins it, and the phone gets no
// second answer.
func TestConfirmNeedsLocalAccept(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, phoneCert, dev, onDesk, onPhone, fromDesk := phonePair(t, ctx)
	key := confirmState(t, d, dev, onPhone, fromDesk)
	if pinned(t, d, dev.ID) != nil || field(d, func() bool { return dev.Paired }) {
		t.Fatal("the answer of the phone pinned it")
	}
	if v := field(d, dev.view); v.PairState != "confirm" || v.PairKey != key {
		t.Fatalf("view %q %q", v.PairState, v.PairKey)
	}
	// A repeated answer keeps the pairing.
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true})); err != nil {
		t.Fatal(err)
	}
	noPairBefore(t, onDesk, fromDesk)
	if state := field(d, func() string { return dev.pairState }); state != "confirm" {
		t.Fatalf("pair state %q after a repeated answer", state)
	}

	if err := d.AcceptPair(dev, "0000000000000000"); errCode(err) != "no_request" {
		t.Fatalf("AcceptPair with another key: %v", err)
	}
	// The key can come in groups and in lower case.
	res, err := d.pairCall("pair.accept", dev, strings.ToLower(proto.FormatKey(key)))
	if err != nil {
		t.Fatal(err)
	}
	if got := res.(map[string]any)["key"]; got != key {
		t.Fatalf("key %v, want %s", got, key)
	}
	if c := pinned(t, d, dev.ID); c == nil || !c.Equal(phoneCert.Leaf) || !field(d, func() bool { return dev.Paired }) {
		t.Fatal("the accept did not pin the phone")
	}
	noPairBefore(t, onDesk, fromDesk)
}

// TestConfirmKeepsFirstPackets checks the packets that the phone sends
// after its answer, while the pairing waits in state "confirm". fluxd acts
// on them only after the accept on this computer, and a reject drops them.
func TestConfirmKeepsFirstPackets(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, dev, onDesk, onPhone, fromDesk := phonePair(t, ctx)
	battery := func(charge int) {
		t.Helper()
		if err := onPhone.Send(proto.New(proto.TypeBattery, map[string]any{"currentCharge": charge, "isCharging": true})); err != nil {
			t.Fatal(err)
		}
	}
	queued := func() int { return field(d, func() int { return len(dev.confirmQueue) }) }

	key := confirmState(t, d, dev, onPhone, fromDesk)
	battery(42)
	waitFor(t, "the queued battery", func() bool { return queued() == 1 })
	if field(d, func() *Battery { return dev.battery }) != nil {
		t.Fatal("fluxd used the battery before the accept")
	}
	if err := d.AcceptPair(dev, key); err != nil {
		t.Fatal(err)
	}
	if b := field(d, func() *Battery { return dev.battery }); b == nil || b.Charge != 42 || !b.Charging {
		t.Fatalf("battery after the accept: %+v", b)
	}
	if queued() != 0 {
		t.Fatal("the queue is not empty after the accept")
	}
	noPairBefore(t, onDesk, fromDesk)
}

// TestConfirmQueueLimit checks that a reject drops the queued packets, and
// that the queue keeps at most maxConfirmQueue packets.
func TestConfirmQueueLimit(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, dev, _, onPhone, fromDesk := phonePair(t, ctx)
	queued := func() int { return field(d, func() int { return len(dev.confirmQueue) }) }

	key := confirmState(t, d, dev, onPhone, fromDesk)
	for range maxConfirmQueue + 8 {
		if err := onPhone.Send(proto.New(proto.TypePing, nil)); err != nil {
			t.Fatal(err)
		}
	}
	waitFor(t, "a full queue", func() bool { return queued() == maxConfirmQueue })
	// The rest of the pings must not grow the queue.
	for end := time.Now().Add(300 * time.Millisecond); time.Now().Before(end); time.Sleep(10 * time.Millisecond) {
		if n := queued(); n > maxConfirmQueue {
			t.Fatalf("the queue holds %d packets", n)
		}
	}
	if err := d.RejectPair(dev, key); err != nil {
		t.Fatal(err)
	}
	if queued() != 0 {
		t.Fatal("the reject kept the queued packets")
	}
}

// TestConfirmRejectAndTimeout checks that a reject and a timeout in state
// "confirm" send pair false, so that the phone removes its pin, and pin
// nothing.
func TestConfirmRejectAndTimeout(t *testing.T) {
	old := pairTimeout
	pairTimeout = 300 * time.Millisecond
	t.Cleanup(func() { pairTimeout = old })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, _, dev, _, onPhone, fromDesk := phonePair(t, ctx)

	key := confirmState(t, d, dev, onPhone, fromDesk)
	if err := d.RejectPair(dev, "0000000000000000"); errCode(err) != "no_request" {
		t.Fatalf("RejectPair with another key: %v", err)
	}
	if err := d.RejectPair(dev, key); err != nil {
		t.Fatal(err)
	}
	if body := nextPair(t, fromDesk); body["pair"] != false {
		t.Fatalf("after the reject %v", body)
	}
	if field(d, func() string { return dev.pairState }) != "" || field(d, func() time.Time { return dev.pairEnded }).IsZero() {
		t.Fatal("the reject did not end the pairing")
	}

	confirmState(t, d, dev, onPhone, fromDesk)
	if body := nextPair(t, fromDesk); body["pair"] != false {
		t.Fatalf("after the timeout %v", body)
	}
	waitFor(t, "the end of the pairing", func() bool { return field(d, func() string { return dev.pairState }) == "" })
	if pinned(t, d, dev.ID) != nil || field(d, func() bool { return dev.Paired }) {
		t.Fatal("the device is paired")
	}
}

// TestConfirmEndsWithLink checks that a pairing in state "confirm" ends
// with its link, and that the next link of the phone gets pair false. The
// phone pinned this computer, and it must remove the pin. A link of
// another host with the ID of the phone does not take the pair false.
func TestConfirmEndsWithLink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, phoneCert, dev, onDesk, onPhone, fromDesk := phonePair(t, ctx)

	// A new link of the phone replaces the link of the pairing.
	confirmState(t, d, dev, onPhone, fromDesk)
	again := newTestPeer(t, ctx, phoneCert).dial(t, ctx, d, d.lan.TCPPort())
	fromAgain := packets(again)
	if body := nextPair(t, fromAgain); body["pair"] != false {
		t.Fatalf("on the new link %v", body)
	}
	waitFor(t, "the new link", func() bool { return field(d, func() *lan.Link { return dev.link }) != onDesk })
	if state := field(d, func() string { return dev.pairState }); state != "" {
		t.Fatalf("pair state %q after a new link", state)
	}

	// The link of the pairing closes, and the phone links again later.
	confirmState(t, d, dev, again, fromAgain)
	again.Close()
	waitFor(t, "the end of the link", func() bool { return field(d, func() *lan.Link { return dev.link }) == nil })
	if field(d, dev.forgettable) {
		t.Fatal("fluxd can forget the device before it gets pair false")
	}

	// A host with the ID of the phone and another certificate links first.
	evil := newTestPeer(t, ctx, certFor(t, dev.ID)).dial(t, ctx, d, d.lan.TCPPort())
	_, onEvil := linked(t, d, dev.ID)
	if !field(d, func() bool { return dev.unpairPeer && dev.unpairCert.Equal(phoneCert.Leaf) }) {
		t.Fatal("the link of another host took the pair false of the phone")
	}
	evil.Close()
	waitClosed(t, onEvil)
	waitFor(t, "the end of the link of the host", func() bool { return field(d, func() *lan.Link { return dev.link }) == nil })

	last := newTestPeer(t, ctx, phoneCert).dial(t, ctx, d, d.lan.TCPPort())
	if body := nextPair(t, packets(last)); body["pair"] != false {
		t.Fatalf("on the next link %v", body)
	}
	if pinned(t, d, dev.ID) != nil || field(d, func() bool { return dev.unpairPeer }) {
		t.Fatal("the device is pinned, or fluxd sends pair false again")
	}
}

// TestAcceptBoundToKey is the regression test for an accept that pinned a
// later pairing. The phone asks to pair, and its link closes. A host with
// the ID of the phone and another certificate then asks to pair. An accept
// with the key of the phone must not pin the host.
func TestAcceptBoundToKey(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, _, phoneCert, dev, _, onPhone, _ := phonePair(t, ctx)
	ts := time.Now().Unix()
	if err := onPhone.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the incoming request", func() bool { return field(d, func() string { return dev.pairState }) == "incoming" })
	phoneKey := proto.VerificationKey(d.cert.Leaf, phoneCert.Leaf, ts)
	onPhone.Close()
	waitFor(t, "the end of the link", func() bool { return field(d, func() *lan.Link { return dev.link }) == nil })

	evil := newTestPeer(t, ctx, certFor(t, dev.ID)).dial(t, ctx, d, d.lan.TCPPort())
	linked(t, d, dev.ID)
	// The host waits until the retry wait of the closed request ends.
	d.mu.Lock()
	dev.pairAt, dev.pairEnded = time.Time{}, time.Time{}
	d.mu.Unlock()
	if err := evil.Send(proto.New(proto.TypePair, map[string]any{"pair": true, "timestamp": ts + 1})); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the request of the host", func() bool { return field(d, func() string { return dev.pairState }) == "incoming" })
	if err := d.AcceptPair(dev, phoneKey); errCode(err) != "no_request" {
		t.Fatalf("AcceptPair with the key of the phone: %v", err)
	}
	d.onNotificationAction(0, "pair-accept:"+dev.ID+":"+phoneKey)
	d.onNotificationAction(0, "pair-accept:"+dev.ID)
	if pinned(t, d, dev.ID) != nil || field(d, func() bool { return dev.Paired }) {
		t.Fatal("an accept for the key of the phone pinned the host")
	}
}

// toasts records the toasts of the daemon.
func toasts(d *Daemon) func() []string {
	var mu sync.Mutex
	var list []string
	d.mu.Lock()
	if d.subs == nil {
		d.subs = map[int]func(string, any){}
	}
	d.mu.Unlock()
	d.Subscribe(func(event string, data any) {
		if event != "toast" {
			return
		}
		mu.Lock()
		list = append(list, data.(map[string]string)["text"])
		mu.Unlock()
	})
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(list)
	}
}

// TestPairRequestSpam checks the limits for pair requests. After a pair
// false, a device waits pairRetry before a new request counts. An incoming
// request that ends with its link also starts the wait. 1 address can hold
// maxIncomingPerIP requests, and a refused request shows a toast.
func TestPairRequestSpam(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	d, logs, phoneCert, dev, _, onPhone, fromDesk := phonePair(t, ctx)
	shown := toasts(d)
	// peer is the link of the phone that sends the requests.
	peer := onPhone
	send := func(body map[string]any) {
		t.Helper()
		d.mu.Lock()
		dev.pairAt = time.Time{}
		d.mu.Unlock()
		if err := peer.Send(proto.New(proto.TypePair, body)); err != nil {
			t.Fatal(err)
		}
	}
	state := func() string { return field(d, func() string { return dev.pairState }) }

	send(map[string]any{"pair": true, "timestamp": time.Now().Unix()})
	waitFor(t, "the first request", func() bool { return state() == "incoming" })
	send(map[string]any{"pair": false})
	waitFor(t, "the withdraw", func() bool { return state() == "" })
	send(map[string]any{"pair": true, "timestamp": time.Now().Unix() + 1})
	if body := nextPair(t, fromDesk); body["pair"] != false {
		t.Fatalf("a request after a withdraw: answer %v", body)
	}
	if state() != "" || !logs.has("its last pairing ended") {
		t.Fatal("a request after a withdraw counted")
	}

	// 2 open requests from the address of the phone.
	d.mu.Lock()
	dev.pairEnded = time.Time{}
	for i := range maxIncomingPerIP {
		o := newDevice(fmt.Sprintf("%032d", i))
		o.pairState = "incoming"
		o.pairLink = &lan.Link{Addr: &net.TCPAddr{IP: net.ParseIP("127.0.0.1")}}
		d.devices[o.ID] = o
	}
	d.mu.Unlock()
	send(map[string]any{"pair": true, "timestamp": time.Now().Unix()})
	if body := nextPair(t, fromDesk); body["pair"] != false {
		t.Fatalf("a third request from 1 address: answer %v", body)
	}
	waitFor(t, "the toast", func() bool {
		return slices.ContainsFunc(shown(), func(s string) bool { return strings.Contains(s, "refused the pair request") })
	})

	// Requests from other addresses do not count for the phone.
	d.mu.Lock()
	for i := range maxIncomingPerIP {
		d.devices[fmt.Sprintf("%032d", i)].pairLink = &lan.Link{Addr: &net.TCPAddr{IP: net.ParseIP("192.0.2.1")}}
	}
	d.mu.Unlock()
	send(map[string]any{"pair": true, "timestamp": time.Now().Unix()})
	waitFor(t, "a request from another address", func() bool { return state() == "incoming" })

	// The phone closes the link of its request and links again.
	ended := func() bool { return !field(d, func() time.Time { return dev.pairEnded }).IsZero() }
	peer.Close()
	waitFor(t, "the end of the link", func() bool { return field(d, func() *lan.Link { return dev.link }) == nil })
	if state() != "" || !ended() {
		t.Fatal("the end of the link did not start the wait")
	}
	peer = newTestPeer(t, ctx, phoneCert).dial(t, ctx, d, d.lan.TCPPort())
	fromDesk = packets(peer)
	_, onDesk := linked(t, d, dev.ID)
	send(map[string]any{"pair": true, "timestamp": time.Now().Unix() + 2})
	if body := nextPair(t, fromDesk); body["pair"] != false || state() != "" {
		t.Fatalf("a request after a closed link: answer %v, state %q", body, state())
	}

	// A new link of the phone replaces the link of its request.
	d.mu.Lock()
	dev.pairEnded = time.Time{}
	d.mu.Unlock()
	send(map[string]any{"pair": true, "timestamp": time.Now().Unix() + 3})
	waitFor(t, "the request on the new link", func() bool { return state() == "incoming" })
	newTestPeer(t, ctx, phoneCert).dial(t, ctx, d, d.lan.TCPPort())
	waitClosed(t, onDesk)
	if state() != "" || !ended() {
		t.Fatal("a new link did not start the wait")
	}
}

package lan

import (
	"context"
	"crypto/tls"
	"errors"
	"flux/internal/proto"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestSendWithinDeadlineBoundsWaitingForAnotherWriter(t *testing.T) {
	l := &Link{done: make(chan struct{})}
	l.wmu.Lock()
	defer l.wmu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	if err := l.SendWithin(ctx, proto.New(proto.TypePing, nil)); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("send error: %v", err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("serializer admission ignored deadline")
	}
}

func TestSendWithinRechecksAuthorityAfterSerializerAdmission(t *testing.T) {
	l := &Link{done: make(chan struct{})}
	l.wmu.Lock()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- l.SendWithinCurrent(ctx, proto.New(proto.TypeFluxInput, map[string]any{"enabled": true}), func() bool { return false })
	}()
	l.wmu.Unlock()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("revoked authorization: %v", err)
		}
	case <-ctx.Done():
		t.Fatal("revoked send did not finish")
	}
}

type closeNotifyObservation struct {
	net.Conn
	active  atomic.Bool
	once    sync.Once
	entered chan struct{}
}

func (c *closeNotifyObservation) Write(b []byte) (int, error) {
	if c.active.Load() {
		c.once.Do(func() { close(c.entered) })
	}
	return c.Conn.Write(b)
}

func TestAbortInterruptsAlreadyEnteredGracefulTLSClose(t *testing.T) {
	cert, _, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	observed := &closeNotifyObservation{Conn: a, entered: make(chan struct{})}
	clientSettings := clientConfig(cert)
	clientSettings.MaxVersion = tls.VersionTLS12
	clientSettings.SessionTicketsDisabled = true
	serverSettings := serverConfig(cert)
	serverSettings.MaxVersion = tls.VersionTLS12
	serverSettings.SessionTicketsDisabled = true
	client := tls.Client(observed, clientSettings)
	server := tls.Server(b, serverSettings)
	_ = a.SetDeadline(time.Now().Add(2 * time.Second))
	_ = b.SetDeadline(time.Now().Add(2 * time.Second))
	handshake := make(chan error, 1)
	go func() { handshake <- server.Handshake() }()
	if err := client.Handshake(); err != nil {
		t.Fatal(err)
	}
	if err := <-handshake; err != nil {
		t.Fatal(err)
	}
	_ = a.SetDeadline(time.Time{})
	_ = b.SetDeadline(time.Time{})
	observed.active.Store(true)
	link := &Link{conn: client, done: make(chan struct{})}
	closed := make(chan struct{})
	go func() { link.Close(); close(closed) }()
	select {
	case <-observed.entered:
	case <-time.After(time.Second):
		t.Fatal("graceful close did not enter TLS write")
	}
	aborted := make(chan struct{})
	go func() { link.Abort(); close(aborted) }()
	select {
	case <-aborted:
	case <-time.After(time.Second):
		t.Fatal("Abort waited behind graceful TLS Close")
	}
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("Abort did not interrupt graceful close")
	}
	select {
	case <-link.Done():
	default:
		t.Fatal("link did not finish")
	}
}

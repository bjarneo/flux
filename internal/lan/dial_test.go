package lan

import (
	"context"
	"net"
	"testing"
	"time"

	"flux/internal/proto"
)

// unreachable is in TEST-NET-1, so no host answers on it.
const unreachable = "192.0.2.1"

func listenLoopback(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

func TestDialFirstPrefersFirstHost(t *testing.T) {
	port := listenLoopback(t)
	conn, i, err := dialFirst(context.Background(), &net.Dialer{Timeout: 5 * time.Second}, []string{"127.0.0.1", "localhost"}, port)
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if i != 0 {
		t.Fatalf("host %d won, want host 0", i)
	}
}

// TestDialFirstSkipsSilentHost checks that a host that does not answer
// delays the next host by dialDelay only, not by the dial timeout.
func TestDialFirstSkipsSilentHost(t *testing.T) {
	port := listenLoopback(t)
	began := time.Now()
	conn, i, err := dialFirst(context.Background(), &net.Dialer{Timeout: 5 * time.Second}, []string{unreachable, "127.0.0.1"}, port)
	if err != nil {
		t.Fatal(err)
	}
	conn.Close()
	if i != 1 {
		t.Fatalf("host %d won, want host 1", i)
	}
	if took := time.Since(began); took > 2*time.Second {
		t.Fatalf("the dial took %v", took)
	}
}

func TestDialFirstFails(t *testing.T) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()
	if _, i, err := dialFirst(context.Background(), &net.Dialer{Timeout: time.Second}, []string{"127.0.0.1"}, port); err == nil || i != -1 {
		t.Fatalf("dial to a closed port: index %d, error %v", i, err)
	}
	if _, _, err := dialFirst(context.Background(), &net.Dialer{}, nil, port); err == nil {
		t.Fatal("dial with no host must fail")
	}
}

// TestDialAny links to a device through its second address, as fluxd
// does for a phone that left the local network.
func TestDialAny(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")
	desk.prov.DialAny(ctx, []string{unreachable, "localhost"}, phone.prov.TCPPort(), proto.Identity{DeviceID: phone.id, ProtocolVersion: 8})
	onDesk := waitLink(t, desk.links)
	waitLink(t, phone.links)
	if !onDesk.Outgoing || onDesk.DeviceID() != phone.id {
		t.Fatalf("outgoing=%v, peer %s", onDesk.Outgoing, onDesk.DeviceID())
	}
}

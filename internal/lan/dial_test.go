package lan

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"sync"
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

// addrs joins each host with port.
func addrs(port int, hosts ...string) []string {
	out := make([]string, 0, len(hosts))
	for _, h := range hosts {
		out = append(out, net.JoinHostPort(h, strconv.Itoa(port)))
	}
	return out
}

func TestDialFirstPrefersFirstHost(t *testing.T) {
	port := listenLoopback(t)
	conn, i, err := dialFirst(context.Background(), &net.Dialer{Timeout: 5 * time.Second}, addrs(port, "127.0.0.1", "localhost"))
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
	conn, i, err := dialFirst(context.Background(), &net.Dialer{Timeout: 5 * time.Second}, addrs(port, unreachable, "127.0.0.1"))
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
	if _, i, err := dialFirst(context.Background(), &net.Dialer{Timeout: time.Second}, addrs(port, "127.0.0.1")); err == nil || i != -1 {
		t.Fatalf("dial to a closed port: index %d, error %v", i, err)
	}
	if _, _, err := dialFirst(context.Background(), &net.Dialer{}, nil); err == nil {
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

// TestStalledDialsKeepPinnedDial fills the dial pool with dials to devices
// without a pin. Each one reaches a host that accepts TCP and never starts
// TLS, so it holds its token until its deadline. A dial to a pinned device
// must still link.
func TestStalledDialsKeepPinnedDial(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	desk := newPeer(t, ctx, "desk")
	phone := newPeer(t, ctx, "phone")

	silent, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	var held []net.Conn
	closed := false
	t.Cleanup(func() {
		silent.Close()
		mu.Lock()
		closed = true
		for _, c := range held {
			c.Close()
		}
		mu.Unlock()
		// Each stalled dial logs its end through t, so the test ends only
		// after the log line of each one.
		for range maxDials {
			desk.waitLog(t, "stalled")
		}
	})
	go func() {
		for {
			c, err := silent.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			if closed {
				c.Close()
			} else {
				held = append(held, c)
			}
			mu.Unlock()
		}
	}()
	port := silent.Addr().(*net.TCPAddr).Port
	for i := range maxDials {
		desk.prov.DialAddrs(ctx, addrs(port, "127.0.0.1"), proto.Identity{DeviceID: fmt.Sprintf("stalled%025d", i), DeviceName: "stalled", ProtocolVersion: 8})
	}
	if n := len(desk.prov.dials); n != maxDials {
		t.Fatalf("%d dials hold a token, want %d", n, maxDials)
	}

	desk.mu.Lock()
	desk.pins[phone.id] = phone.cert.Leaf
	desk.mu.Unlock()
	desk.prov.DialAddrs(ctx, addrs(phone.prov.TCPPort(), "127.0.0.1"), proto.Identity{DeviceID: phone.id, ProtocolVersion: 8})
	if l := waitLink(t, desk.links); l.DeviceID() != phone.id {
		t.Fatalf("link to %s, want the pinned phone", l.DeviceID())
	}
	if n := len(desk.prov.dials); n != maxDials {
		t.Fatalf("%d dials hold a token after the pinned dial, want %d", n, maxDials)
	}
}

package lan

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

// runWatch runs watch in a goroutine and returns its result channel.
func runWatch(ctx context.Context, closed <-chan struct{}, signals <-chan *dbus.Signal, item func(*dbus.Signal)) <-chan watchEnd {
	res := make(chan watchEnd, 1)
	go func() {
		res <- watch(ctx, closed, signals, nil, func(sig *dbus.Signal) bool { item(sig); return false })
	}()
	return res
}

func waitWatch(t *testing.T, res <-chan watchEnd) watchEnd {
	t.Helper()
	select {
	case end := <-res:
		return end
	case <-time.After(3 * time.Second):
		t.Fatal("watch did not return")
		return ctxDone
	}
}

// TestWatchStopsWhenSignalsClose checks that watch returns when godbus
// closes the signal channel, and does not spin on nil receives.
func TestWatchStopsWhenSignalsClose(t *testing.T) {
	signals := make(chan *dbus.Signal, 2)
	var got []*dbus.Signal
	res := runWatch(context.Background(), nil, signals, func(sig *dbus.Signal) { got = append(got, sig) })
	sig := &dbus.Signal{Name: avahiBrowser + ".ItemNew"}
	signals <- sig
	close(signals)
	if end := waitWatch(t, res); end != busClosed {
		t.Fatalf("watch returned %d, want busClosed", end)
	}
	if len(got) != 1 || got[0] != sig {
		t.Fatalf("item got %v, want the 1 signal", got)
	}
}

func TestWatchStopsWhenConnectionCloses(t *testing.T) {
	closed := make(chan struct{})
	res := runWatch(context.Background(), closed, make(chan *dbus.Signal), func(*dbus.Signal) {})
	close(closed)
	if end := waitWatch(t, res); end != busClosed {
		t.Fatalf("watch returned %d, want busClosed", end)
	}
}

func TestWatchStopsWithContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	res := runWatch(ctx, nil, make(chan *dbus.Signal), func(*dbus.Signal) {})
	cancel()
	if end := waitWatch(t, res); end != ctxDone {
		t.Fatalf("watch returned %d, want ctxDone", end)
	}
}

// ownerChanged returns a NameOwnerChanged signal from sender for name.
func ownerChanged(sender, name, oldOwner, newOwner string) *dbus.Signal {
	return &dbus.Signal{
		Sender: sender, Path: "/org/freedesktop/DBus", Name: busName + ".NameOwnerChanged",
		Body: []any{name, oldOwner, newOwner},
	}
}

// TestWatchAvahiRestart checks that watch returns when Avahi stops and when
// it starts, so that run publishes the service again. A signal for
// another name, or a signal that does not come from the bus, does not
// end watch.
func TestWatchAvahiRestart(t *testing.T) {
	for _, c := range []struct {
		sig  *dbus.Signal
		want watchEnd
	}{
		{ownerChanged(busName, avahiBus, ":1.5", ""), avahiStopped},
		{ownerChanged(busName, avahiBus, "", ":1.9"), avahiStarted},
		{ownerChanged(busName, avahiBus, ":1.5", ":1.9"), avahiStarted},
	} {
		signals := make(chan *dbus.Signal, 4)
		var got []*dbus.Signal
		res := runWatch(context.Background(), nil, signals, func(sig *dbus.Signal) { got = append(got, sig) })
		other := ownerChanged(busName, "org.example.Other", ":1.7", "")
		fake := ownerChanged(":1.77", avahiBus, ":1.5", "")
		signals <- other
		signals <- fake
		signals <- c.sig
		if end := waitWatch(t, res); end != c.want {
			t.Errorf("%v: watch returned %d, want %d", c.sig.Body, end, c.want)
		}
		if len(got) != 2 || got[0] != other || got[1] != fake {
			t.Errorf("%v: item got %v, want the 2 other signals", c.sig.Body, got)
		}
	}
}

// TestWatchRetry checks that watch returns when the retry time comes.
func TestWatchRetry(t *testing.T) {
	retry := make(chan time.Time, 1)
	res := make(chan watchEnd, 1)
	go func() {
		res <- watch(context.Background(), nil, make(chan *dbus.Signal), retry, func(*dbus.Signal) bool { return false })
	}()
	retry <- time.Now()
	if end := waitWatch(t, res); end != retryNow {
		t.Fatalf("watch returned %d, want retryNow", end)
	}
}

func TestNextRetry(t *testing.T) {
	var got []time.Duration
	for wait := mdnsRetryMin; len(got) < 8; wait = nextRetry(wait) {
		got = append(got, wait)
	}
	want := []time.Duration{1, 2, 4, 8, 16, 32, 60, 60}
	for i := range want {
		if got[i] != want[i]*time.Second {
			t.Fatalf("waits %v, want %v seconds", got, want)
		}
	}
}

// TestWatchBrowserFailed checks that watch returns when item reports a
// failure of the browser.
func TestWatchBrowserFailed(t *testing.T) {
	signals := make(chan *dbus.Signal, 1)
	res := make(chan watchEnd, 1)
	go func() {
		res <- watch(context.Background(), nil, signals, nil, func(*dbus.Signal) bool { return true })
	}()
	signals <- &dbus.Signal{Name: avahiBrowser + ".Failure"}
	if end := waitWatch(t, res); end != browserFailed {
		t.Fatalf("watch returned %d, want browserFailed", end)
	}
}

// fakeAvahi answers ResolveService with a fixed address for each name in
// addrs, and with an error for other names.
type fakeAvahi struct {
	dbus.BusObject
	mu    sync.Mutex
	addrs map[string]string
	calls []string
}

func (f *fakeAvahi) Call(method string, _ dbus.Flags, args ...any) *dbus.Call {
	name, _ := args[2].(string)
	f.mu.Lock()
	f.calls = append(f.calls, name)
	addr, ok := f.addrs[name]
	f.mu.Unlock()
	if method != avahiServer+".ResolveService" || !ok {
		return &dbus.Call{Err: errors.New("Timeout reached")}
	}
	txt := [][]byte{[]byte("id=" + name), []byte("name=Pixel"), []byte("type=phone"), []byte("protocol=8")}
	return &dbus.Call{Body: []any{int32(2), int32(0), name, serviceType, "local", "pixel.local", int32(0), addr, uint16(12100), txt, uint32(0)}}
}

func browserSignal(member, path, name string) *dbus.Signal {
	return &dbus.Signal{
		Name: avahiBrowser + "." + member,
		Path: dbus.ObjectPath(path),
		Body: []any{int32(2), int32(0), name, serviceType, "local", uint32(0)},
	}
}

// TestRescanFindsKnownDevices checks that Rescan resolves each entry that
// the browser reported and did not remove. The browser reports a device
// only once, so this is how fluxd finds a phone again after its link
// closed.
func TestRescanFindsKnownDevices(t *testing.T) {
	var logs []string
	var mu sync.Mutex
	found := make(chan MDNSPeer, 8)
	m := &MDNS{
		self:     "self",
		found:    func(p MDNSPeer) { found <- p },
		logf:     func(f string, a ...any) { mu.Lock(); logs = append(logs, fmt.Sprintf(f, a...)); mu.Unlock() },
		services: map[service]bool{},
		noted:    map[service]string{},
	}
	server := &fakeAvahi{addrs: map[string]string{"phone_a": "192.168.1.20", "phone_b": "192.168.1.21"}}
	m.setServer(server)
	a := &avahi{server: server, browser: "/browser/1"}

	for _, sig := range []*dbus.Signal{
		browserSignal("ItemNew", "/browser/1", "phone_a"),
		browserSignal("ItemNew", "/browser/1", "phone_b"),
		browserSignal("ItemNew", "/browser/1", "self"),
		browserSignal("ItemNew", "/browser/2", "other"),
		browserSignal("ItemRemove", "/browser/1", "phone_b"),
	} {
		if m.item(a, sig) {
			t.Fatalf("item reported a failure for %s", sig.Name)
		}
	}
	// ItemNew resolves phone_a and phone_b once each.
	for range 2 {
		select {
		case <-found:
		case <-time.After(3 * time.Second):
			t.Fatal("the browser entries did not resolve")
		}
	}
	if n := m.Rescan(); n != 1 {
		t.Fatalf("Rescan resolved %d entries, want 1", n)
	}
	select {
	case p := <-found:
		if p.DeviceID != "phone_a" || p.IP != "192.168.1.20" || p.Port != 12100 || p.Name != "Pixel" {
			t.Fatalf("Rescan found %+v", p)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Rescan found no device")
	}
	mu.Lock()
	defer mu.Unlock()
	foundLines := 0
	for _, l := range logs {
		if strings.HasPrefix(l, "mDNS: found") {
			foundLines++
		}
	}
	// The second resolve of phone_a has the same address, so it logs
	// nothing new.
	if foundLines != 2 {
		t.Fatalf("logged %d found lines, want 2: %q", foundLines, logs)
	}
}

// TestBrowserFailureIsReported checks that a Failure signal of the browser
// ends the watch, so run starts a new browser.
func TestBrowserFailureIsReported(t *testing.T) {
	m := &MDNS{logf: func(string, ...any) {}, services: map[service]bool{}, noted: map[service]string{}}
	a := &avahi{browser: "/browser/1"}
	if !m.item(a, &dbus.Signal{Name: avahiBrowser + ".Failure", Path: "/browser/1", Body: []any{"Too many objects"}}) {
		t.Fatal("item did not report the failure of the browser")
	}
	if m.item(a, &dbus.Signal{Name: avahiBrowser + ".Failure", Path: "/browser/2", Body: []any{"x"}}) {
		t.Fatal("item reported the failure of another browser")
	}
}

// TestRescanWithoutAvahi checks that Rescan does nothing while Avahi does
// not run, and that a nil MDNS is safe.
func TestRescanWithoutAvahi(t *testing.T) {
	var m *MDNS
	if m.Rescan() != 0 {
		t.Fatal("a nil MDNS resolved entries")
	}
	m = &MDNS{logf: func(string, ...any) {}, services: map[service]bool{{name: "x"}: true}, noted: map[service]string{}}
	if m.Rescan() != 0 {
		t.Fatal("Rescan resolved entries without Avahi")
	}
}

package lan

import (
	"context"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

// runWatch runs watch in a goroutine and returns its result channel.
func runWatch(ctx context.Context, closed <-chan struct{}, signals <-chan *dbus.Signal, item func(*dbus.Signal)) <-chan watchEnd {
	res := make(chan watchEnd, 1)
	go func() { res <- watch(ctx, closed, signals, nil, item) }()
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
	go func() { res <- watch(context.Background(), nil, make(chan *dbus.Signal), retry, func(*dbus.Signal) {}) }()
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

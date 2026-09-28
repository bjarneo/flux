package lan

import (
	"context"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

// runWatch runs watch in a goroutine and returns its result channel.
func runWatch(ctx context.Context, closed <-chan struct{}, signals <-chan *dbus.Signal, item func(*dbus.Signal)) <-chan bool {
	res := make(chan bool, 1)
	go func() { res <- watch(ctx, closed, signals, item) }()
	return res
}

func waitWatch(t *testing.T, res <-chan bool) bool {
	t.Helper()
	select {
	case ended := <-res:
		return ended
	case <-time.After(3 * time.Second):
		t.Fatal("watch did not return")
		return false
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
	if waitWatch(t, res) {
		t.Fatal("watch reported the end of the context")
	}
	if len(got) != 1 || got[0] != sig {
		t.Fatalf("item got %v, want the 1 signal", got)
	}
}

func TestWatchStopsWhenConnectionCloses(t *testing.T) {
	closed := make(chan struct{})
	res := runWatch(context.Background(), closed, make(chan *dbus.Signal), func(*dbus.Signal) {})
	close(closed)
	if waitWatch(t, res) {
		t.Fatal("watch reported the end of the context")
	}
}

func TestWatchStopsWithContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	res := runWatch(ctx, nil, make(chan *dbus.Signal), func(*dbus.Signal) {})
	cancel()
	if !waitWatch(t, res) {
		t.Fatal("watch did not report the end of the context")
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

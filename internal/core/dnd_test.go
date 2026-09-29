package core

import (
	"context"
	"io"
	"log"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/proto"
)

func TestDndGuardLocalChanges(t *testing.T) {
	var g dndGuard
	now := time.Unix(1000, 0)
	if g.local(false, now) {
		t.Fatal("the first state is the start value, not a change")
	}
	if g.local(false, now) {
		t.Fatal("the same state is not a change")
	}
	if !g.local(true, now) {
		t.Fatal("a new state on this computer must go to the phones")
	}
	if g.local(true, now) {
		t.Fatal("a change goes out once")
	}
}

func TestDndGuardNoEcho(t *testing.T) {
	var g dndGuard
	now := time.Unix(1000, 0)
	g.local(false, now)
	if !g.remote(true, now) {
		t.Fatal("a new state from a phone must apply")
	}
	// The desktop still reports the old state for a moment.
	if g.local(false, now.Add(time.Second)) {
		t.Fatal("the old state during the wait is not a local change")
	}
	// Then it reports the state that the phone set.
	if g.local(true, now.Add(2*time.Second)) {
		t.Fatal("the state from the phone must not go back to the phone")
	}
	if g.remote(true, now.Add(3*time.Second)) {
		t.Fatal("the same state from a phone does not apply again")
	}
	// A later change on this computer goes out.
	if !g.local(false, now.Add(10*time.Second)) {
		t.Fatal("a later local change must go out")
	}
}

func TestDndGuardFailedApply(t *testing.T) {
	var g dndGuard
	now := time.Unix(1000, 0)
	g.local(false, now)
	g.remote(true, now)
	// The desktop never took the state. After the wait, its state wins and
	// goes to the phones, so that both sides agree again.
	if !g.local(false, now.Add(dndSettle+time.Second)) {
		t.Fatal("after the wait, the desktop state must go to the phones")
	}
}

func TestDndGuardRemoteFirst(t *testing.T) {
	var g dndGuard
	now := time.Unix(1000, 0)
	if !g.remote(true, now) {
		t.Fatal("a state from a phone before the first poll must apply")
	}
	if g.local(true, now) {
		t.Fatal("the applied state is not a local change")
	}
}

// countDnd counts the reads of the desktop state.
type countDnd struct{ gets atomic.Int32 }

func (c *countDnd) Get() (bool, bool) { c.gets.Add(1); return false, true }
func (c *countDnd) Set(bool) error    { return nil }

// With no phone that accepts flux.dnd, the loop does not read the desktop.
func TestDndLoopIdleWithoutPhone(t *testing.T) {
	dnd := &countDnd{}
	d := &Daemon{
		cfg:     &config.Config{SyncDnd: true},
		devices: map[string]*Device{},
		dnd:     dnd,
		dndWake: make(chan struct{}, 1),
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		d.dndLoop(ctx)
		close(done)
	}()
	d.wakeDnd()
	time.Sleep(50 * time.Millisecond)
	cancel()
	<-done
	if n := dnd.gets.Load(); n != 0 {
		t.Errorf("the loop read the desktop state %d times", n)
	}
}

// slowDnd records each state and holds the first Set until release.
type slowDnd struct {
	release chan struct{}
	started chan struct{}
	mu      sync.Mutex
	sets    []bool
}

func (s *slowDnd) Get() (bool, bool) { return false, true }

func (s *slowDnd) Set(on bool) error {
	s.mu.Lock()
	first := len(s.sets) == 0
	s.sets = append(s.sets, on)
	s.mu.Unlock()
	if first {
		close(s.started)
		<-s.release
	}
	return nil
}

// TestHandleDndAppliesNewest sends 3 fast changes from a phone. The
// changes apply 1 at a time, and the last one wins.
func TestHandleDndAppliesNewest(t *testing.T) {
	dnd := &slowDnd{release: make(chan struct{}), started: make(chan struct{})}
	d := &Daemon{
		cfg:     &config.Config{SyncDnd: true},
		devices: map[string]*Device{},
		dnd:     dnd,
		logger:  log.New(io.Discard, "", 0),
	}
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	for i, on := range []bool{true, false, true} {
		d.handleDnd(dev, proto.New(proto.TypeFluxDnd, map[string]any{"on": on}))
		if i == 0 {
			<-dnd.started
		}
	}
	close(dnd.release)
	waitIdle(t, d, &d.content.dndQ)
	if !slices.Equal(dnd.sets, []bool{true, true}) {
		t.Fatalf("sets %v", dnd.sets)
	}
}

// TestHandleDndAfterUnpair checks that a state that waits on the worker
// does not apply after the phone is unpaired.
func TestHandleDndAfterUnpair(t *testing.T) {
	dnd := &slowDnd{release: make(chan struct{}), started: make(chan struct{})}
	d := &Daemon{
		cfg:     &config.Config{SyncDnd: true},
		devices: map[string]*Device{},
		dnd:     dnd,
		logger:  log.New(io.Discard, "", 0),
	}
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	d.handleDnd(dev, proto.New(proto.TypeFluxDnd, map[string]any{"on": true}))
	<-dnd.started
	d.handleDnd(dev, proto.New(proto.TypeFluxDnd, map[string]any{"on": false}))
	d.mu.Lock()
	dev.Paired = false
	d.mu.Unlock()
	close(dnd.release)
	waitIdle(t, d, &d.content.dndQ)
	if !slices.Equal(dnd.sets, []bool{true}) {
		t.Fatalf("sets %v", dnd.sets)
	}
}

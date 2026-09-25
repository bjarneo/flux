package core

import (
	"testing"
	"time"
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

package core

import (
	"io"
	"log"
	"slices"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// fakeMedia is a set of desktop players that records each action.
type fakeMedia struct {
	players []desktop.Player
	actions []string
}

func (f *fakeMedia) Players() []desktop.Player { return slices.Clone(f.players) }

func (f *fakeMedia) Action(name, action string) error {
	f.actions = append(f.actions, name+":"+action)
	for i := range f.players {
		if f.players[i].Name == name {
			f.players[i].Playing = action == "Play"
		}
	}
	return nil
}

func (f *fakeMedia) set(name string, playing bool) {
	for i := range f.players {
		if f.players[i].Name == name {
			f.players[i].Playing = playing
		}
	}
}

func TestCallPausePausesOnlyPlayingPlayers(t *testing.T) {
	m := &fakeMedia{players: []desktop.Player{{Name: "spotify", Playing: true}, {Name: "mpv"}, {Name: "firefox", Playing: true}}}
	var c callPause
	c.pause(m)
	if !slices.Equal(m.actions, []string{"spotify:Pause", "firefox:Pause"}) {
		t.Fatalf("pause actions: %v", m.actions)
	}
	// A second ring, or ringing then talking, pauses nothing again.
	c.pause(m)
	if len(m.actions) != 2 {
		t.Fatalf("second pause: %v", m.actions)
	}
	m.actions = nil
	c.resume(m)
	if !slices.Equal(m.actions, []string{"spotify:Play", "firefox:Play"}) {
		t.Fatalf("resume actions: %v", m.actions)
	}
	if len(c.paused) != 0 {
		t.Fatalf("the list must be empty after the call: %v", c.paused)
	}
}

func TestCallResumeLeavesChangedPlayers(t *testing.T) {
	m := &fakeMedia{players: []desktop.Player{{Name: "spotify", Playing: true}, {Name: "vlc", Playing: true}}}
	var c callPause
	c.pause(m)
	// During the call, the user plays spotify again and closes vlc.
	m.set("spotify", true)
	m.players = m.players[:1]
	m.actions = nil
	c.resume(m)
	if len(m.actions) != 0 {
		t.Fatalf("resume must not touch a player that plays or closed: %v", m.actions)
	}
}

func telephonyPacket(body map[string]any) *proto.Packet {
	return proto.New(proto.TypeTelephony, body)
}

func TestHandleTelephony(t *testing.T) {
	m := &fakeMedia{players: []desktop.Player{{Name: "spotify", Playing: true}, {Name: "mpv"}}}
	d := &Daemon{cfg: &config.Config{PauseMediaOnCall: true}, logger: log.New(io.Discard, "", 0), callPlayers: m}
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}

	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing", "phoneNumber": "+4712345678"}))
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "talking", "phoneNumber": "+4712345678"}))
	waitIdle(t, d, &d.content.mediaQ)
	if !slices.Equal(m.actions, []string{"spotify:Pause"}) {
		t.Fatalf("ringing and talking: %v", m.actions)
	}
	// The phone sends isCancel as a boolean or as a string.
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "talking", "isCancel": "true"}))
	waitIdle(t, d, &d.content.mediaQ)
	if !slices.Equal(m.actions, []string{"spotify:Pause", "spotify:Play"}) {
		t.Fatalf("after the call: %v", m.actions)
	}

	// With pause_media_on_call off, a call leaves the players alone.
	d.cfg.PauseMediaOnCall = false
	m.actions = nil
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing"}))
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing", "isCancel": true}))
	waitIdle(t, d, &d.content.mediaQ)
	if len(m.actions) != 0 {
		t.Fatalf("pause_media_on_call off: %v", m.actions)
	}
}

// TestDropCall checks that the call state ends when the link that reported
// the call drops, so that a later call does not play players that it did
// not pause.
func TestDropCall(t *testing.T) {
	m := &fakeMedia{players: []desktop.Player{{Name: "spotify", Playing: true}}}
	d := &Daemon{cfg: &config.Config{PauseMediaOnCall: true}, logger: log.New(io.Discard, "", 0), callPlayers: m}
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	first, second := &lan.Link{}, &lan.Link{}
	d.callEvent(dev, nil, callBody{Event: "ringing"})
	d.calls[dev.ID].link = first

	// A link that did not report the call changes nothing.
	d.dropCall(dev, second)
	if d.calls[dev.ID] == nil {
		t.Fatal("the drop of another link ended the call")
	}
	d.dropCall(dev, first)
	if d.calls[dev.ID] != nil {
		t.Fatal("the call state stays after its link dropped")
	}
	// spotify stays paused. The end of the next call does not play it,
	// because that call did not pause it.
	m.actions = nil
	d.callEvent(dev, nil, callBody{Event: "talking", IsCancel: "true"})
	if len(m.actions) != 0 {
		t.Fatalf("the end of a new call ran %v", m.actions)
	}
}

// stuckMedia is a set of players that does not answer until release
// closes, like a stopped mpv that keeps its bus name.
type stuckMedia struct{ release chan struct{} }

func (s *stuckMedia) Players() []desktop.Player { <-s.release; return nil }

func (s *stuckMedia) Action(string, string) error { <-s.release; return nil }

// TestTelephonyDoesNotBlockReadLoop checks that a call event returns at
// once while the players do not answer. The read loop of the phone then
// handles the next packets, such as an approval answer.
func TestTelephonyDoesNotBlockReadLoop(t *testing.T) {
	m := &stuckMedia{release: make(chan struct{})}
	d := &Daemon{cfg: &config.Config{PauseMediaOnCall: true}, logger: log.New(io.Discard, "", 0), callPlayers: m}
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	done := make(chan struct{})
	go func() {
		defer close(done)
		d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing"}))
		d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing", "isCancel": true}))
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("a call event waits for the players")
	}
	close(m.release)
	waitIdle(t, d, &d.content.mediaQ)
}

func TestCaller(t *testing.T) {
	cases := []struct {
		b    callBody
		want string
	}{
		{callBody{ContactName: "Mom", PhoneNumber: "+47 123"}, "Mom"},
		{callBody{PhoneNumber: "+47 123"}, "+47 123"},
		{callBody{ContactName: "  "}, "Unknown caller"},
	}
	for _, c := range cases {
		if got := c.b.caller(); got != c.want {
			t.Errorf("%+v: got %q, want %q", c.b, got, c.want)
		}
	}
}

// TestCallEventNeedsPairedLink checks that a call event that waits on the
// media worker does nothing after an unpair or after its link changed.
func TestCallEventNeedsPairedLink(t *testing.T) {
	m := &fakeMedia{players: []desktop.Player{{Name: "spotify", Playing: true}}}
	d := &Daemon{cfg: &config.Config{PauseMediaOnCall: true}, logger: log.New(io.Discard, "", 0), callPlayers: m}
	old := &lan.Link{}
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	// The phone connected again, so the event of the old link is old.
	d.callEvent(dev, old, callBody{Event: "ringing"})
	dev.Paired = false
	d.callEvent(dev, nil, callBody{Event: "ringing"})
	if len(m.actions) != 0 || d.calls[dev.ID] != nil {
		t.Fatalf("actions %v, call state %+v", m.actions, d.calls[dev.ID])
	}
}

// slowMedia is a set of players that reports each Players call and then
// answers late.
type slowMedia struct{ called chan struct{} }

func (s *slowMedia) Players() []desktop.Player {
	s.called <- struct{}{}
	time.Sleep(50 * time.Millisecond)
	return nil
}

func (s *slowMedia) Action(string, string) error { return nil }

// TestCallEventReadsNameUnderLock checks that a call event on the media
// worker reads the device name under the lock, while a new identity of the
// phone changes the name. Run it with -race.
func TestCallEventReadsNameUnderLock(t *testing.T) {
	m := &slowMedia{called: make(chan struct{}, 1)}
	d := &Daemon{cfg: &config.Config{PauseMediaOnCall: true}, logger: log.New(io.Discard, "", 0), callPlayers: m}
	dev := &Device{ID: "p1", Name: "Pixel 8", Paired: true}
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing"}))
	<-m.called
	d.mu.Lock()
	dev.setIdentity(proto.Identity{DeviceName: "Pixel 9"})
	d.mu.Unlock()
	waitIdle(t, d, &d.content.mediaQ)
}

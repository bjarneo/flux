package core

import (
	"io"
	"log"
	"slices"
	"testing"

	"flux/internal/config"
	"flux/internal/desktop"
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
	dev := &Device{ID: "p1", Name: "Pixel 8"}

	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing", "phoneNumber": "+4712345678"}))
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "talking", "phoneNumber": "+4712345678"}))
	if !slices.Equal(m.actions, []string{"spotify:Pause"}) {
		t.Fatalf("ringing and talking: %v", m.actions)
	}
	// The phone sends isCancel as a boolean or as a string.
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "talking", "isCancel": "true"}))
	if !slices.Equal(m.actions, []string{"spotify:Pause", "spotify:Play"}) {
		t.Fatalf("after the call: %v", m.actions)
	}

	// With pause_media_on_call off, a call leaves the players alone.
	d.cfg.PauseMediaOnCall = false
	m.actions = nil
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing"}))
	d.handleTelephony(dev, telephonyPacket(map[string]any{"event": "ringing", "isCancel": true}))
	if len(m.actions) != 0 {
		t.Fatalf("pause_media_on_call off: %v", m.actions)
	}
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

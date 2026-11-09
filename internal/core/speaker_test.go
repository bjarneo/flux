package core

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/proto"
)

// slowWriter takes each write only after the test sends on next. Each
// write first sends on entered when it has room.
type slowWriter struct {
	next    chan struct{}
	entered chan struct{}
	mu      sync.Mutex
	buf     bytes.Buffer
}

func newSlowWriter() *slowWriter {
	return &slowWriter{next: make(chan struct{}), entered: make(chan struct{}, 1)}
}

func (w *slowWriter) Write(p []byte) (int, error) {
	select {
	case w.entered <- struct{}{}:
	default:
	}
	if _, ok := <-w.next; !ok {
		return 0, errors.New("closed")
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buf.Write(p)
}

func (w *slowWriter) bytes() []byte {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Clone(w.buf.Bytes())
}

// frameReader returns 1 frame of 20 ms on each read. Before the second
// frame, it waits until wait has a value.
type frameReader struct {
	frames [][]byte
	wait   chan struct{}
	n      int
}

func (r *frameReader) Read(p []byte) (int, error) {
	if r.n >= len(r.frames) {
		return 0, io.EOF
	}
	if r.n == 1 && r.wait != nil {
		<-r.wait
	}
	c := copy(p, r.frames[r.n])
	r.n++
	return c, nil
}

func testFrames(n int) [][]byte {
	frames := make([][]byte, n)
	for i := range frames {
		frames[i] = make([]byte, desktopAudioBytes)
		frames[i][0] = byte(i)
	}
	return frames
}

func TestPumpSpeakerFrames(t *testing.T) {
	frames := testFrames(3)
	w := newSlowWriter()
	go func() {
		for range 3 {
			w.next <- struct{}{}
		}
	}()
	firsts := 0
	err := pumpSpeaker(&frameReader{frames: frames}, w, speakerBacklog, func() { firsts++ }, func() { t.Error("a short stream dropped audio") })
	if !errors.Is(err, io.EOF) || firsts != 1 {
		t.Fatalf("err %v, first called %d times", err, firsts)
	}
	// The writer can still run after the pump returns.
	var out *bytes.Buffer
	waitFor(t, "3 frames", func() bool {
		b := w.bytes()
		out = bytes.NewBuffer(b)
		return len(b) == 3*(desktopAudioBytes+5)
	})
	for i := 0; i < 3; i++ {
		header := out.Next(5)
		if len(header) != 5 || int(binary.BigEndian.Uint32(header)) != desktopAudioBytes || header[4] != frameAudio {
			t.Fatalf("frame %d header %v", i, header)
		}
		if !bytes.Equal(out.Next(desktopAudioBytes), frames[i]) {
			t.Fatalf("frame %d changed", i)
		}
	}
}

// TestPumpSpeakerDropsOldAudio checks that a stalled network keeps at most
// the backlog, and that the oldest audio goes.
func TestPumpSpeakerDropsOldAudio(t *testing.T) {
	const frames = 20
	w := newSlowWriter()
	drops := 0
	err := pumpSpeaker(&frameReader{frames: testFrames(frames), wait: w.entered}, w, 3, func() {}, func() { drops++ })
	if !errors.Is(err, io.EOF) {
		t.Fatal(err)
	}
	// The writer took the first frame and waits in its write. The queue
	// keeps the 3 newest frames.
	if drops != frames-1-3 {
		t.Fatalf("dropped %d frames, want %d", drops, frames-1-3)
	}
	for i := 0; i < 4; i++ {
		w.next <- struct{}{}
	}
	close(w.next)
	var got []byte
	waitFor(t, "4 frames", func() bool { return len(w.bytes()) == 4*(5+desktopAudioBytes) })
	out := bytes.NewBuffer(w.bytes())
	for out.Len() > 0 {
		f := out.Next(5 + desktopAudioBytes)
		got = append(got, f[5])
	}
	if !bytes.Equal(got, []byte{0, 17, 18, 19}) {
		t.Fatalf("frames %v, want the first and the 3 newest", got)
	}
}

func TestPumpSpeakerWriteError(t *testing.T) {
	pr, pw := io.Pipe()
	defer pw.Close()
	go func() {
		for {
			if _, err := pw.Write(make([]byte, desktopAudioBytes)); err != nil {
				return
			}
		}
	}()
	w := newSlowWriter()
	close(w.next)
	err := pumpSpeaker(pr, w, speakerBacklog, func() {}, func() {})
	var closed writeError
	if !errors.As(err, &closed) {
		t.Fatalf("got %v, want a write error", err)
	}
}

func TestOutputMute(t *testing.T) {
	ctx := context.Background()
	file := filepath.Join(t.TempDir(), "speaker-muted")
	m := newMemOutputs()
	var mute outputMute

	got, err := mute.apply(ctx, m, true, file)
	if err != nil || got != "Laptop Speakers" {
		t.Fatalf("apply: %q, %v", got, err)
	}
	if data, _ := os.ReadFile(file); string(data) != "speakers\n" {
		t.Fatalf("the file has %q", data)
	}
	// A second check changes nothing.
	if got, err = mute.apply(ctx, m, true, file); err != nil || got != "Laptop Speakers" {
		t.Fatalf("second apply: %q, %v", got, err)
	}
	// Another default output takes the mute.
	if err := m.SetDefault(ctx, "hdmi"); err != nil {
		t.Fatal(err)
	}
	if got, err = mute.apply(ctx, m, true, file); err != nil || !strings.HasPrefix(got, "HDMI") {
		t.Fatalf("after the switch: %q, %v", got, err)
	}
	if err := mute.restore(ctx, m, file); err != nil {
		t.Fatal(err)
	}
	want := []string{"speakers mute true", "hdmi default", "speakers mute false", "hdmi mute true", "hdmi mute false"}
	if got := m.log(); !slices.Equal(got, want) {
		t.Fatalf("changes %q, want %q", got, want)
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatal("restore left the file")
	}

	// An output that the user muted stays muted at the end.
	if err := m.SetMute(ctx, "hdmi", true); err != nil {
		t.Fatal(err)
	}
	before := len(m.log())
	if got, err = mute.apply(ctx, m, true, file); err != nil || got != "" {
		t.Fatalf("a muted output: %q, %v", got, err)
	}
	if err := mute.restore(ctx, m, file); err != nil {
		t.Fatal(err)
	}
	if got := m.log()[before:]; len(got) != 0 {
		t.Fatalf("an output that the user muted changed: %q", got)
	}

	// No mute wanted turns the sound on again at once.
	_ = m.SetMute(ctx, "hdmi", false)
	if _, err := mute.apply(ctx, m, true, file); err != nil {
		t.Fatal(err)
	}
	if got, err := mute.apply(ctx, m, false, file); err != nil || got != "" {
		t.Fatalf("mute off: %q, %v", got, err)
	}
	if o, _ := m.Find(ctx, "hdmi"); o.Muted {
		t.Fatal("mute off left the output muted")
	}

	// An error keeps the state, so the next check tries again.
	m.fail = desktop.ErrNoPactl
	if _, err := mute.apply(ctx, m, true, file); !errors.Is(err, desktop.ErrNoPactl) {
		t.Fatalf("without pactl: %v", err)
	}
}

func TestRestoreCrashedMute(t *testing.T) {
	file := filepath.Join(t.TempDir(), "speaker-muted")
	d, _ := sessionDaemon(t, &config.Config{})
	m := newMemOutputs()
	_ = m.SetMute(context.Background(), "hdmi", true)
	d.outputs = m
	if err := os.WriteFile(file, []byte("hdmi\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.restoreCrashedMute(context.Background(), file, 2, time.Millisecond)
	if o, _ := m.Find(context.Background(), "hdmi"); o.Muted {
		t.Fatal("the output is still muted")
	}
	if _, err := os.Stat(file); !os.IsNotExist(err) {
		t.Fatal("the file stays")
	}
	// The file stays when PipeWire does not answer.
	_ = os.WriteFile(file, []byte("hdmi\n"), 0o600)
	m.fail = errors.New("connection refused")
	d.restoreCrashedMute(context.Background(), file, 2, time.Millisecond)
	if _, err := os.Stat(file); err != nil {
		t.Fatal("the file went after a failure")
	}
}

// fakePwRecord puts a pw-record on PATH that writes silence in frames of
// 20 ms until it stops.
func fakePwRecord(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	script := "#!/bin/sh\nwhile :; do /usr/bin/head -c 3840 /dev/zero || exit 0; /usr/bin/sleep 0.02; done\n"
	if err := os.WriteFile(filepath.Join(dir, "pw-record"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
}

func speakerPacket(port int, mute bool) *proto.Packet {
	return proto.New(proto.TypeFluxSpeaker, map[string]any{"state": "start", "port": port, "mute": mute})
}

func (d *Daemon) currentSpeaker() *speakerSession {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.speaker
}

// TestSpeakerSession runs a stream with mute: fluxd mutes the default
// output while the phone plays, follows a change of the mute choice, and
// turns the sound on again at the stop.
func TestSpeakerSession(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	fakePwRecord(t)
	d, dev := sessionDaemon(t, &config.Config{})
	m := newMemOutputs()
	d.outputs = m
	l := newFakeStreamLink()
	close(l.release)
	d.handleSpeaker(dev, l, speakerPacket(12071, true))
	s := d.currentSpeaker()
	if s == nil {
		t.Fatal("no session")
	}
	l.waitDial(t)
	waitFor(t, "the mute", func() bool {
		o, _ := m.Find(context.Background(), "speakers")
		return o.Muted
	})
	waitFor(t, "the live state", func() bool {
		d.mu.Lock()
		defer d.mu.Unlock()
		return s.view.Active && s.view.Muted == "Laptop Speakers"
	})
	if busy := d.Busy(); busy != "the phone speaker" {
		t.Fatalf("Busy() = %q", busy)
	}
	if v := d.speakerView(); v == nil || !v.Active || v.ToName != "Pixel 8" || v.Rate != 48000 || v.Channels != 2 || !v.Mute {
		t.Fatalf("view %+v", v)
	}

	// The phone turns the mute off, and on again.
	d.handleSpeaker(dev, l, proto.New(proto.TypeFluxSpeaker, map[string]any{"state": "mute", "mute": false}))
	waitFor(t, "the sound on", func() bool {
		o, _ := m.Find(context.Background(), "speakers")
		return !o.Muted
	})
	d.handleSpeaker(dev, l, proto.New(proto.TypeFluxSpeaker, map[string]any{"state": "mute", "mute": true}))
	waitFor(t, "the second mute", func() bool {
		o, _ := m.Find(context.Background(), "speakers")
		return o.Muted
	})

	if err := d.StopSpeaker(); err != nil {
		t.Fatal(err)
	}
	waitDone(t, s.ctx, "the session")
	waitFor(t, "the end of the session", func() bool {
		select {
		case <-s.done:
			return true
		default:
			return false
		}
	})
	if o, _ := m.Find(context.Background(), "speakers"); o.Muted {
		t.Fatal("the stop left the output muted")
	}
	want := []string{"speakers mute true", "speakers mute false", "speakers mute true", "speakers mute false"}
	if got := m.log(); !slices.Equal(got, want) {
		t.Fatalf("changes %q, want %q", got, want)
	}
	states := strings.Join(l.states(), ",")
	if !strings.HasPrefix(states, "live,muted,muted,muted,") || !strings.HasSuffix(states, "stop") {
		t.Fatalf("states %s", states)
	}
	if err := d.StopSpeaker(); err == nil {
		t.Fatal("a second stop must fail")
	}
	if d.Busy() != "" {
		t.Fatalf("Busy() = %q after the stop", d.Busy())
	}
}

func (d *Daemon) speakerView() *SpeakerView {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.speakerViewLocked()
}

func TestSpeakerRefusals(t *testing.T) {
	d, dev := sessionDaemon(t, &config.Config{})
	l := newFakeStreamLink()
	if d.claimSpeaker(dev, l, speakerStart{Port: 0}) != nil {
		t.Fatal("a start without a port must fail")
	}
	d.opts.Headless = true
	if d.claimSpeaker(dev, l, speakerStart{Port: 12071}) != nil {
		t.Fatal("a headless fluxd must refuse the speaker")
	}
	if v := d.speakerView(); v == nil || v.Error == "" {
		t.Fatalf("view %+v", v)
	}
	if got := l.states(); len(got) != 2 || !strings.HasPrefix(got[1], "error: the phone speaker is off in headless mode") {
		t.Fatalf("states %q", got)
	}
}

func TestSpeakerStartsReplaceTheOldSession(t *testing.T) {
	d, dev := sessionDaemon(t, &config.Config{})
	l := newFakeStreamLink()
	s1 := d.claimSpeaker(dev, l, speakerStart{Port: 12071})
	s2 := d.claimSpeaker(dev, l, speakerStart{Port: 12072})
	if s1 == nil || s2 == nil || s1.ctx.Err() == nil {
		t.Fatal("the second start did not end the first")
	}
	d.handleSpeaker(dev, l, proto.New(proto.TypeFluxSpeaker, map[string]any{"state": "stop"}))
	if s2.ctx.Err() == nil || d.currentSpeaker() != nil {
		t.Fatal("the stop of the phone did not end the session")
	}
}

// TestSpeakerRequest checks flux-cli speaker start: only a device that can
// play the audio gets the request, and a running stream refuses it.
func TestSpeakerRequest(t *testing.T) {
	d, dev, onDesk, ch := requestDaemon(t)
	// The phone takes stream requests, but cannot play the audio.
	err := d.RequestSpeaker("")
	var ae *Error
	if !errors.As(err, &ae) || ae.Code != "no_device" {
		t.Fatalf("got %v, want no_device", err)
	}
	if err := d.RequestSpeaker("Pixel 8"); !errors.As(err, &ae) || ae.Code != "not_supported" {
		t.Fatalf("got %v, want not_supported", err)
	}
	noRequest(t, onDesk, ch, "a phone without the speaker")

	d.mu.Lock()
	dev.Incoming = append(dev.Incoming, proto.TypeFluxSpeaker)
	plugins := dev.plugins()
	d.mu.Unlock()
	if !slices.Contains(plugins, "speaker") {
		t.Fatalf("plugins %q", plugins)
	}
	if err := d.RequestSpeaker(""); err != nil {
		t.Fatal(err)
	}
	if kind := nextRequest(t, ch); kind != "speaker" {
		t.Fatalf("kind %q", kind)
	}

	d.mu.Lock()
	d.speaker = &speakerSession{dev: dev}
	d.sessions.streamAsked = nil
	d.mu.Unlock()
	if err := d.RequestSpeaker(""); !errors.As(err, &ae) || ae.Code != "already_active" || !strings.Contains(ae.Message, "flux-cli speaker stop") {
		t.Fatalf("got %v, want already_active", err)
	}
}

package core

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/proto"
)

// fakeStreamLink is a link to a phone. Its DialPeer waits until the test
// closes release, and it records the context of each dial.
type fakeStreamLink struct {
	mu      sync.Mutex
	sent    []map[string]any
	dials   chan context.Context
	release chan struct{}
	done    chan struct{}
	// phones gets the phone end of each stream.
	phones chan net.Conn
}

func newFakeStreamLink() *fakeStreamLink {
	return &fakeStreamLink{
		dials:   make(chan context.Context, 64),
		release: make(chan struct{}),
		done:    make(chan struct{}),
		phones:  make(chan net.Conn, 64),
	}
}

func (f *fakeStreamLink) Send(p *proto.Packet) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, p.Fields())
	return nil
}

func (f *fakeStreamLink) DialPeer(ctx context.Context, _ int) (*tls.Conn, error) {
	f.dials <- ctx
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-f.release:
	}
	c1, c2 := net.Pipe()
	go func() { _, _ = io.Copy(io.Discard, c2) }()
	context.AfterFunc(ctx, func() { c2.Close() })
	f.phones <- c2
	return tls.Client(c1, &tls.Config{InsecureSkipVerify: true}), nil
}

func (f *fakeStreamLink) Done() <-chan struct{} { return f.done }

// states returns the state of each packet that fluxd sent, with the
// message of an error.
func (f *fakeStreamLink) states() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, b := range f.sent {
		s := fmt.Sprint(b["state"])
		if m, ok := b["message"]; ok {
			s += ": " + fmt.Sprint(m)
		}
		out = append(out, s)
	}
	return out
}

// waitDial returns the context of the next dial.
func (f *fakeStreamLink) waitDial(t *testing.T) context.Context {
	t.Helper()
	select {
	case ctx := <-f.dials:
		return ctx
	case <-time.After(5 * time.Second):
		t.Fatal("fluxd did not dial the phone")
		return nil
	}
}

func waitDone(t *testing.T, ctx context.Context, what string) {
	t.Helper()
	select {
	case <-ctx.Done():
	case <-time.After(5 * time.Second):
		t.Fatalf("%s still runs", what)
	}
}

// sessionDaemon returns a daemon without a desktop and a paired device.
func sessionDaemon(t *testing.T, cfg *config.Config) (*Daemon, *Device) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	cfg.Name = "arch"
	d := &Daemon{
		cfg:     cfg,
		devices: map[string]*Device{},
		inputQ:  make(chan inputAction, inputQueue),
		dirty:   make(chan struct{}, 1),
		ctx:     ctx,
		logger:  log.New(io.Discard, "", 0),
	}
	dev := &Device{ID: "phone", Name: "Pixel 8", Paired: true}
	d.devices[dev.ID] = dev
	return d, dev
}

// fakeRecorder puts a gpu-screen-recorder on PATH that lists 1 monitor. It
// creates the returned file when it records. It adds 1 line to the file
// runs for each run.
func fakeRecorder(t *testing.T) string {
	t.Helper()
	// A recording writes "end" 0.3 seconds after it stops, also after the
	// test ended. t.TempDir then fails with "directory not empty" when the
	// write comes during its removal. So this folder has its own removal,
	// which tries again for a short time.
	dir, err := os.MkdirTemp("", "flux-recorder-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		deadline := time.Now().Add(2 * time.Second)
		for {
			err := os.RemoveAll(dir)
			if err == nil {
				return
			}
			if time.Now().After(deadline) {
				t.Logf("remove %s: %v", dir, err)
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
	})
	mark := filepath.Join(dir, "recorded")
	runs := filepath.Join(dir, "runs")
	// A recording stops 0.3 seconds after SIGINT and then writes "end".
	// A test sends SIGINT as soon as it sees the line in runs or the mark,
	// so the trap and the sleep start first. The sleep writes nothing to
	// the stream, so it cannot hold the stream open after the shell exits.
	script := "#!/bin/sh\n" +
		"if [ \"$1\" = --list-monitors ]; then echo \"$1\" >> " + runs + "; echo 'DP-1|1920x1080'; exit 0; fi\n" +
		"trap '/usr/bin/kill $pid; /usr/bin/sleep 0.3; echo end >> " + runs + "; exit 0' INT\n" +
		"/usr/bin/sleep 10 >/dev/null & pid=$!\n" +
		"echo \"$1\" >> " + runs + "\n" +
		"/usr/bin/touch " + mark + "\n" +
		"wait $pid\n"
	if err := os.WriteFile(filepath.Join(dir, desktopRecorder), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	return mark
}

func recorded(mark string) bool {
	_, err := os.Stat(mark)
	return err == nil
}

func desktopPacket(port int) *proto.Packet {
	return proto.New(proto.TypeFluxDesktop, map[string]any{"state": "start", "port": port})
}

func (d *Daemon) currentDesktop() *desktopSession {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.desktop
}

// A phone sends 2 starts and delays the TLS handshake of the first. The
// second start ends the first, so the user can stop every stream.
func TestDesktopStartsLeaveNoOrphan(t *testing.T) {
	mark := fakeRecorder(t)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	first, second := newFakeStreamLink(), newFakeStreamLink()
	d.handleDesktop(dev, first, desktopPacket(1740))
	ctx1 := first.waitDial(t)
	d.handleDesktop(dev, second, desktopPacket(1741))
	ctx2 := second.waitDial(t)
	waitDone(t, ctx1, "the first start")

	// The user turns the remote desktop off while the second start dials.
	d.mu.Lock()
	d.cfg.RemoteDesktop = false
	d.mu.Unlock()
	d.inputChanged()
	waitDone(t, ctx2, "the second start")
	close(first.release)
	close(second.release)

	time.Sleep(200 * time.Millisecond)
	if recorded(mark) {
		t.Fatal("a recorder started after the stop")
	}
	if s := d.currentDesktop(); s != nil {
		t.Fatalf("a session stays: %+v", s.view)
	}
	if busy := d.Busy(); busy != "" {
		t.Fatalf("Busy = %q, want nothing", busy)
	}
	if got := second.states(); len(got) != 1 || got[0] != "stop" {
		t.Fatalf("the phone got %q, want a stop", got)
	}
	if got := first.states(); len(got) != 0 {
		t.Fatalf("the replaced start got %q, want nothing", got)
	}
}

// StopDesktop also stops a start that still dials the phone.
func TestStopDesktopStopsAPendingStart(t *testing.T) {
	fakeRecorder(t)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := newFakeStreamLink()
	d.handleDesktop(dev, l, desktopPacket(1740))
	ctx := l.waitDial(t)
	if err := d.StopDesktop(); err != nil {
		t.Fatalf("StopDesktop: %v", err)
	}
	waitDone(t, ctx, "the start")
	if err := d.StopDesktop(); err == nil {
		t.Fatal("a second StopDesktop found a session")
	}
}

// The switch can turn off while fluxd dials the phone. The recorder then
// does not start.
func TestDesktopChecksTheSwitchBeforeTheRecorder(t *testing.T) {
	check := sessionCheck
	sessionCheck = time.Hour
	t.Cleanup(func() { sessionCheck = check })
	mark := fakeRecorder(t)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := newFakeStreamLink()
	d.handleDesktop(dev, l, desktopPacket(1740))
	ctx := l.waitDial(t)
	d.mu.Lock()
	d.cfg.RemoteDesktop = false
	d.mu.Unlock()
	close(l.release)
	waitDone(t, ctx, "the session")
	waitFor(t, "the session ends", func() bool { return d.currentDesktop() == nil })
	if recorded(mark) {
		t.Fatal("the recorder started with the switch off")
	}
	if got := l.states(); len(got) != 1 || !strings.Contains(got[0], "the remote desktop is off") {
		t.Fatalf("the phone got %q, want the error", got)
	}
}

// The recorder starts when the setting stays on, and the session ends when
// the device is no longer paired.
func TestDesktopEndsAfterAnUnpair(t *testing.T) {
	check := sessionCheck
	sessionCheck = 10 * time.Millisecond
	t.Cleanup(func() { sessionCheck = check })
	mark := fakeRecorder(t)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := newFakeStreamLink()
	d.handleDesktop(dev, l, desktopPacket(1740))
	ctx := l.waitDial(t)
	close(l.release)
	waitFor(t, "the recorder starts", func() bool { return recorded(mark) })
	d.mu.Lock()
	dev.Paired = false
	d.mu.Unlock()
	waitDone(t, ctx, "the stream after the unpair")
	waitFor(t, "the session ends", func() bool { return d.currentDesktop() == nil })
}

// recorderLog returns the runs of the recorder from fakeRecorder: 1 line
// for each run, and "end" when a recording stopped.
func recorderLog(t *testing.T, mark string) []string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(filepath.Dir(mark), "runs"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return strings.Fields(string(b))
}

// recorderRuns returns the number of list runs and of recordings of the
// recorder from fakeRecorder.
func recorderRuns(t *testing.T, mark string) (lists, records int) {
	t.Helper()
	for _, line := range recorderLog(t, mark) {
		switch line {
		case "--list-monitors":
			lists++
		case "end":
		default:
			records++
		}
	}
	return lists, records
}

// A new start waits until the recorder of the old session stopped, so 2
// recorders never run at the same time.
func TestDesktopStartWaitsForTheOldRecorder(t *testing.T) {
	mark := fakeRecorder(t)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := newFakeStreamLink()
	close(l.release)
	d.handleDesktop(dev, l, desktopPacket(1740))
	waitFor(t, "the first recorder", func() bool { return recorded(mark) })
	d.handleDesktop(dev, l, desktopPacket(1741))
	waitFor(t, "the second recorder", func() bool {
		_, records := recorderRuns(t, mark)
		return records == 2
	})
	runs := recorderLog(t, mark)
	end := slices.Index(runs, "end")
	first := slices.IndexFunc(runs, func(s string) bool { return s != "--list-monitors" })
	if end < 0 || slices.Contains(runs[first+1:end], "--list-monitors") {
		t.Fatalf("the second start ran before the first recorder stopped: %q", runs)
	}
	if err := d.StopDesktop(); err != nil {
		t.Fatal(err)
	}
}

// 3 starts overlap. The second start ends at once, and the third start
// still waits until the recorder of the first session stopped.
func TestDesktopOverlappingStartsWaitForTheOldRecorder(t *testing.T) {
	mark := fakeRecorder(t)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := newFakeStreamLink()
	close(l.release)
	d.handleDesktop(dev, l, desktopPacket(1740))
	waitFor(t, "the first recorder", func() bool { return recorded(mark) })
	d.handleDesktop(dev, l, desktopPacket(1741))
	d.handleDesktop(dev, l, desktopPacket(1742))
	waitFor(t, "the third recorder", func() bool {
		_, records := recorderRuns(t, mark)
		return records == 2
	})
	runs := recorderLog(t, mark)
	end := slices.Index(runs, "end")
	first := slices.IndexFunc(runs, func(s string) bool { return s != "--list-monitors" })
	if end < 0 || slices.Contains(runs[first+1:end], "--list-monitors") {
		t.Fatalf("the third start ran before the first recorder stopped: %q", runs)
	}
	if err := d.StopDesktop(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the session ends", func() bool { return d.currentDesktop() == nil })
}

// A flood of starts from a phone runs 1 recorder, and the starts that a
// later start ended run no process.
func TestDesktopStartFloodRunsOneRecorder(t *testing.T) {
	mark := fakeRecorder(t)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := newFakeStreamLink()
	for i := range 20 {
		d.handleDesktop(dev, l, desktopPacket(1740+i))
	}
	last := d.currentDesktop()
	var ctx context.Context
	for ctx == nil || ctx != last.ctx {
		ctx = l.waitDial(t)
	}
	close(l.release)
	waitFor(t, "the recorder starts", func() bool { return recorded(mark) })
	time.Sleep(100 * time.Millisecond)
	lists, records := recorderRuns(t, mark)
	if records != 1 || lists > 4 {
		t.Fatalf("%d recordings and %d lists of the monitors, want 1 recording and at most 4 lists", records, lists)
	}
	if err := d.StopDesktop(); err != nil {
		t.Fatal(err)
	}
	waitDone(t, ctx, "the session")
}

// The session ends when the phone closes the stream, also while the screen
// does not change and the recorder writes no frame.
func TestDesktopEndsWhenThePhoneClosesTheStream(t *testing.T) {
	mark := fakeRecorder(t)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := newFakeStreamLink()
	d.handleDesktop(dev, l, desktopPacket(1740))
	ctx := l.waitDial(t)
	close(l.release)
	phone := <-l.phones
	waitFor(t, "the recorder starts", func() bool { return recorded(mark) })
	phone.Close()
	waitDone(t, ctx, "the session")
	waitFor(t, "the session ends", func() bool { return d.currentDesktop() == nil })
}

func TestDesktopRefusesAStartWhenOff(t *testing.T) {
	d, dev := sessionDaemon(t, &config.Config{})
	l := newFakeStreamLink()
	d.handleDesktop(dev, l, desktopPacket(1740))
	if s := d.currentDesktop(); s != nil {
		t.Fatal("a start claimed the session with the switch off")
	}
	if got := l.states(); len(got) != 1 || !strings.Contains(got[0], "flux-cli desktop on") {
		t.Fatalf("the phone got %q", got)
	}
}

// The microphone, the screen mirror, and the webcam have 1 session each. A
// later start ends a start that still dials, and a stop finds it.
func TestStreamStartsReplaceTheOldSession(t *testing.T) {
	d, dev := sessionDaemon(t, &config.Config{})
	l := newFakeStreamLink()

	m1 := d.claimMic(dev, l, &micStart{Port: 1740})
	m2 := d.claimMic(dev, l, &micStart{Port: 1741})
	if m1 == nil || m2 == nil || m1.ctx.Err() == nil {
		t.Fatal("the second microphone start did not end the first")
	}
	if err := d.StopMic(); err != nil || m2.ctx.Err() == nil {
		t.Fatalf("StopMic did not stop the pending start: %v", err)
	}

	s1 := d.claimScreen(dev, l, screenStart{Port: 1740})
	if s1 == nil {
		t.Fatal("the screen mirror did not start")
	}
	d.endScreen(dev.ID)
	if s1.ctx.Err() == nil || d.screen != nil {
		t.Fatal("endScreen did not stop the pending start")
	}

	w1 := d.claimWebcam(dev, l, webcamStart{Port: 1740})
	w2 := d.claimWebcam(dev, l, webcamStart{Port: 1741})
	if w1 == nil || w2 == nil || w1.ctx.Err() == nil {
		t.Fatal("the second webcam start did not end the first")
	}
	if err := d.StopWebcam(); err != nil || w2.ctx.Err() == nil {
		t.Fatalf("StopWebcam did not stop the pending start: %v", err)
	}
}

// Each screen mirror start opens a window, so 1 device can start at most
// 1 mirror in screenStartGap.
func TestScreenStartGap(t *testing.T) {
	d, dev := sessionDaemon(t, &config.Config{})
	l := newFakeStreamLink()
	if d.claimScreen(dev, l, screenStart{Port: 1740}) == nil {
		t.Fatal("the first start failed")
	}
	if d.claimScreen(dev, l, screenStart{Port: 1741}) != nil {
		t.Fatal("a second start in the gap opened a window")
	}
	if got := l.states(); len(got) != 1 || !strings.Contains(got[0], "wait 3 seconds") {
		t.Fatalf("the phone got %q", got)
	}
}

func TestWebcamOffWhenHeadless(t *testing.T) {
	d, dev := sessionDaemon(t, &config.Config{})
	d.opts.Headless = true
	l := newFakeStreamLink()
	if d.claimWebcam(dev, l, webcamStart{Port: 1740}) != nil {
		t.Fatal("a headless daemon started the webcam")
	}
	if got := l.states(); len(got) != 1 || !strings.Contains(got[0], "headless") {
		t.Fatalf("the phone got %q", got)
	}
}

// Only the device of the webcam session reports the settings, and the
// settings end with the session.
func TestWebcamSettingsBelongToTheSession(t *testing.T) {
	d, dev := sessionDaemon(t, &config.Config{})
	other := &Device{ID: "tablet", Name: "Tab", Paired: true}
	l := newFakeStreamLink()
	report := func(from *Device, body map[string]any) {
		body["state"] = "config"
		d.handleWebcam(from, l, proto.New(proto.TypeFluxWebcam, body))
	}
	settings := map[string]any{"config": map[string]any{"zoom": 2, "extra": "x"}, "caps": map[string]any{"cameras": []string{"back", "front"}}}

	report(dev, settings)
	if d.webcamConfig != nil {
		t.Fatal("settings without a session were kept")
	}
	if d.claimWebcam(dev, l, webcamStart{Port: 1740}) == nil {
		t.Fatal("the webcam did not start")
	}
	report(other, settings)
	if d.webcamConfig != nil {
		t.Fatal("the settings of another device were kept")
	}
	report(dev, settings)
	if string(d.webcamConfig) != `{"zoom":2}` || string(d.webcamCaps) != `{"cameras":["back","front"]}` {
		t.Fatalf("settings %s %s", d.webcamConfig, d.webcamCaps)
	}
	d.endWebcam(dev.ID)
	if d.webcamConfig != nil || d.webcamCaps != nil {
		t.Fatal("the settings stay after the session")
	}
}

func TestCleanWebcamConfig(t *testing.T) {
	many := make([]string, maxWebcamList+1)
	for i := range many {
		many[i] = "a"
	}
	bad := []struct{ config, caps string }{
		{`{"aspect":"` + strings.Repeat("x", maxWebcamText+1) + `"}`, ``},
		{``, `{"aspects":` + mustString(many) + `}`},
		{``, `{"resolutions":[` + strings.Repeat("720,", maxWebcamList) + `720]}`},
		{`{"zoom":1e300}`, ``},
		{``, `{"cameras":["` + strings.Repeat("x", maxWebcamJSON) + `"]}`},
		{`[1,2]`, ``},
	}
	for _, c := range bad {
		if _, _, err := cleanWebcamConfig(rawOrNil(c.config), rawOrNil(c.caps)); err == nil {
			t.Errorf("%s %s: no error", c.config, c.caps)
		}
	}
	// The Mac names a camera by its device name, which can be long.
	cfg, caps, err := cleanWebcamConfig(
		rawOrNil(`{"aspect":"16:9","resolution":720,"camera":"alexandra's iphone 15 pro max camera","mirror":false,"zoom":1,"exposure":0,"whiteBalance":"auto","brightness":0,"contrast":1,"saturation":1,"warmth":0}`),
		rawOrNil(`{"zoomMax":8,"exposureMin":-2,"exposureMax":2,"exposureStep":0.5,"whiteBalance":["auto"],"cameras":["facetime hd camera","alexandra's iphone 15 pro max camera"],"aspects":["16:9"],"resolutions":[720,1080]}`))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(cfg), `"contrast":1`) || !strings.Contains(string(cfg), `"mirror":false`) || !strings.Contains(string(caps), `"resolutions":[720,1080]`) {
		t.Fatalf("settings %s %s", cfg, caps)
	}
	if !strings.Contains(string(caps), `"alexandra's iphone 15 pro max camera"]`) {
		t.Fatalf("the long camera name is missing: %s", caps)
	}
}

// fluxd sends only the known webcam settings, with the same limits as the
// settings from the phone, so that a value cannot stop an older app.
func TestConfigureWebcamChecksSettings(t *testing.T) {
	d, dev := sessionDaemon(t, &config.Config{})
	l := newFakeStreamLink()
	if d.claimWebcam(dev, l, webcamStart{Port: 1740}) == nil {
		t.Fatal("the webcam did not start")
	}
	for _, c := range []string{
		`{"resolution":1e300}`, `{"resolution":-9.2e18}`, `{"resolution":-720}`, `{"resolution":720.5}`,
		`{"zoom":1e300}`, `{"brightness":-1e9}`, `{"mirror":"yes"}`, `{"extra":1}`,
		`{"camera":"` + strings.Repeat("x", maxWebcamText+1) + `"}`, `{}`, `[1]`, `null`,
	} {
		var e *Error
		if err := d.ConfigureWebcam(json.RawMessage(c), false); !errors.As(err, &e) || e.Code != "bad_params" {
			t.Errorf("%s: %v", c, err)
		}
	}
	l.mu.Lock()
	sent := len(l.sent)
	l.mu.Unlock()
	if sent != 0 {
		t.Fatalf("fluxd sent %d packets for settings that are not valid", sent)
	}
	if err := d.ConfigureWebcam(json.RawMessage(`{"resolution":1080,"zoom":2.5,"mirror":true,"camera":"front"}`), false); err != nil {
		t.Fatal(err)
	}
	l.mu.Lock()
	got := l.sent[0]["config"]
	l.mu.Unlock()
	want := map[string]any{"resolution": 1080.0, "zoom": 2.5, "mirror": true, "camera": "front"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sent %#v", got)
	}
}

func rawOrNil(s string) []byte {
	if s == "" {
		return nil
	}
	return []byte(s)
}

func mustString(v []string) string {
	return string(mustJSON(v))
}

func TestPeerText(t *testing.T) {
	got := peerText("x\nlink up: attacker paired=true")
	if strings.Contains(got, "\n") || got != `"x\nlink up: attacker paired=true"` {
		t.Fatalf("peerText = %s", got)
	}
	long := peerText(strings.Repeat("ø", 1000))
	if n := len([]rune(long)); n != maxPeerText+3 {
		t.Fatalf("kept %d characters", n)
	}
}

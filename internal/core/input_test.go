package core

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// fakeInput records the calls of the input backend.
type fakeInput struct {
	mu    sync.Mutex
	calls []string
}

func (f *fakeInput) add(format string, args ...any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, fmt.Sprintf(format, args...))
	return nil
}

func (f *fakeInput) Move(dx, dy float64) error { return f.add("move %g %g", dx, dy) }
func (f *fakeInput) Button(b uint32, pressed bool) error {
	return f.add("button %#x %v", b, pressed)
}
func (f *fakeInput) Scroll(dx, dy float64) error { return f.add("scroll %g %g", dx, dy) }
func (f *fakeInput) Type(_ context.Context, text string, mods []string) error {
	return f.add("type %q %s", text, strings.Join(mods, "+"))
}
func (f *fakeInput) Key(_ context.Context, name string, mods []string) error {
	return f.add("key %s %s", name, strings.Join(mods, "+"))
}
func (f *fakeInput) MoveTo(monitor string, x, y float64) error {
	return f.add("moveTo %s %g %g", monitor, x, y)
}

func (f *fakeInput) got() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func (f *fakeInput) wait(t *testing.T, n int) []string {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		f.mu.Lock()
		got := append([]string(nil), f.calls...)
		f.mu.Unlock()
		if len(got) >= n {
			return got
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("got %d calls, want %d", len(f.calls), n)
	return nil
}

func TestInputActions(t *testing.T) {
	left, right, middle := uint32(desktop.BtnLeft), uint32(desktop.BtnRight), uint32(desktop.BtnMiddle)
	cases := []struct {
		body string
		want []inputAction
	}{
		{`{"dx":3.5,"dy":-2}`, []inputAction{{kind: "move", dx: 3.5, dy: -2}}},
		{`{"dx":1e9,"dy":0}`, []inputAction{{kind: "move", dx: maxInputDelta}}},
		{`{"singleclick":true,"dx":5}`, []inputAction{{kind: "button", button: left, pressed: true}, {kind: "button", button: left}}},
		{`{"rightclick":true}`, []inputAction{{kind: "button", button: right, pressed: true}, {kind: "button", button: right}}},
		{`{"middleclick":true}`, []inputAction{{kind: "button", button: middle, pressed: true}, {kind: "button", button: middle}}},
		{`{"singlehold":true}`, []inputAction{{kind: "button", button: left, pressed: true}}},
		{`{"singlerelease":true}`, []inputAction{{kind: "button", button: left}}},
		{`{"scroll":true,"dx":0,"dy":12}`, []inputAction{{kind: "scroll", dy: 12}}},
		{`{"scroll":true}`, nil},
		{`{"specialKey":12}`, []inputAction{{kind: "key", text: "Return"}}},
		{`{"specialKey":2,"shift":true,"ctrl":true}`, []inputAction{{kind: "key", text: "Tab", mods: []string{"ctrl", "shift"}}}},
		{`{"specialKey":99}`, nil},
		{`{"key":"c","ctrl":true}`, []inputAction{{kind: "type", text: "c", mods: []string{"ctrl"}}}},
		{`{"key":" ","super":true}`, []inputAction{{kind: "type", text: " ", mods: []string{"logo"}}}},
		{`{"key":"hei\u0000 på\ndeg"}`, []inputAction{{kind: "type", text: "hei pådeg"}}},
		{`{"key":"\n"}`, nil},
		{`{}`, nil},
		// A position of the remote desktop comes before the action.
		{`{"x":0.25,"y":0.5}`, []inputAction{{kind: "moveTo", x: 0.25, y: 0.5}}},
		{`{"x":0.25,"y":0.5,"singleclick":true}`, []inputAction{
			{kind: "moveTo", x: 0.25, y: 0.5}, {kind: "button", button: left, pressed: true}, {kind: "button", button: left},
		}},
		{`{"x":-3,"y":7,"scroll":true,"dy":4}`, []inputAction{{kind: "moveTo", x: 0, y: 1}, {kind: "scroll", dy: 4}}},
		{`{"x":0.5,"singlehold":true}`, []inputAction{{kind: "button", button: left, pressed: true}}},
	}
	for _, c := range cases {
		var b mousepadBody
		if err := json.Unmarshal([]byte(c.body), &b); err != nil {
			t.Fatal(err)
		}
		if got := inputActions(b); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s:\n got %+v\nwant %+v", c.body, got, c.want)
		}
	}
}

func TestCleanInputTextLimit(t *testing.T) {
	if n := len([]rune(cleanInputText(strings.Repeat("ø", maxInputText+10)))); n != maxInputText {
		t.Fatalf("kept %d characters", n)
	}
}

func inputDaemon(t *testing.T, on bool) (*Daemon, *fakeInput) {
	t.Helper()
	in := &fakeInput{}
	d := newInputDaemon(t, on, in)
	return d, in
}

// newInputDaemon returns a daemon with the input backend in and a running
// input loop.
func newInputDaemon(t *testing.T, on bool, in inputBackend) *Daemon {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	d := &Daemon{
		cfg:     &config.Config{RemoteInput: on},
		input:   in,
		inputQ:  make(chan inputAction, inputQueue),
		devices: map[string]*Device{},
		dirty:   make(chan struct{}, 1),
		ctx:     ctx,
		logger:  log.New(io.Discard, "", 0),
	}
	go d.inputLoop(ctx)
	return d
}

// inputDevice returns a paired device with a link.
func inputDevice(id, name string) *Device {
	return &Device{ID: id, Name: name, Paired: true, link: &lan.Link{}}
}

func mousepad(body string) *proto.Packet {
	var fields map[string]any
	_ = json.Unmarshal([]byte(body), &fields)
	return proto.New(proto.TypeMousepadRequest, fields)
}

func TestHandleMousepad(t *testing.T) {
	d, in := inputDaemon(t, true)
	dev := inputDevice("phone", "Pixel 8")
	d.handleMousepad(dev, mousepad(`{"dx":4,"dy":2}`))
	d.handleMousepad(dev, mousepad(`{"singleclick":true}`))
	d.handleMousepad(dev, mousepad(`{"key":"ls"}`))
	d.handleMousepad(dev, mousepad(`{"specialKey":12}`))
	want := []string{"move 4 2", "button 0x110 true", "button 0x110 false", `type "ls" `, "key Return "}
	if got := in.wait(t, len(want)); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
}

func TestHandleMousepadPosition(t *testing.T) {
	d, in := inputDaemon(t, true)
	dev := inputDevice("phone", "Pixel 8")
	// Without a remote desktop, a position has no monitor.
	d.handleMousepad(dev, mousepad(`{"x":0.5,"y":0.5,"singleclick":true}`))
	d.desktop = &desktopSession{dev: dev, view: DesktopView{Monitor: "DP-1"}}
	d.handleMousepad(dev, mousepad(`{"x":0.5,"y":0.25,"rightclick":true}`))
	// A position from another phone has no monitor.
	d.handleMousepad(inputDevice("tablet", "Tab"), mousepad(`{"x":0.1,"y":0.1}`))
	want := []string{
		"button 0x110 true", "button 0x110 false",
		"moveTo DP-1 0.5 0.25", "button 0x111 true", "button 0x111 false",
	}
	if got := in.wait(t, len(want)); !reflect.DeepEqual(got, want) {
		t.Fatalf("calls %q, want %q", got, want)
	}
}

func TestHandleMousepadOff(t *testing.T) {
	d, in := inputDaemon(t, false)
	dev := inputDevice("phone", "Pixel 8")
	d.handleMousepad(dev, mousepad(`{"key":"rm -rf ~"}`))
	d.handleMousepad(dev, mousepad(`{"specialKey":12}`))
	time.Sleep(50 * time.Millisecond)
	if calls := in.got(); len(calls) != 0 {
		t.Fatalf("remote input ran while it is off: %q", calls)
	}
	if !dev.inputRefused {
		t.Fatal("the refusal is not recorded")
	}

	// A headless daemon has no input, also with the setting on.
	d.cfg.RemoteInput = true
	d.input = nil
	d.handleMousepad(dev, mousepad(`{"specialKey":12}`))
	if len(d.inputQ) != 0 {
		t.Fatal("queued input without a backend")
	}
}

// The Flux window and flux-cli turn the remote settings on and off with
// settings.set.
func TestSetRemoteSettings(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	d, _ := inputDaemon(t, false)
	d.desktopErr = "the remote desktop is off on arch"
	for _, key := range []string{"remoteDesktop", "remoteInput"} {
		if err := d.setSetting(key, true); err != nil {
			t.Fatalf("%s: %v", key, err)
		}
	}
	if !d.cfg.RemoteDesktop || !d.cfg.RemoteInput {
		t.Fatalf("settings: %+v", d.cfg)
	}
	if d.desktopErr != "" {
		t.Fatalf("the old error stays: %q", d.desktopErr)
	}
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.RemoteDesktop || !cfg.RemoteInput {
		t.Fatalf("config.toml does not keep the settings: %+v", cfg)
	}
	if err := d.setSetting("remoteDesktop", "on"); err == nil {
		t.Fatal("a text value must fail")
	}
}

// A switch that config.toml cannot keep does not turn on. A switch that
// turns off stops the sessions, also when config.toml cannot keep it. Each
// other setting that config.toml cannot keep does not change.
func TestUnsavedRemoteSettings(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	// config.toml cannot be written, because the flux folder is a file.
	if err := os.WriteFile(filepath.Join(dir, "flux"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	d, _ := inputDaemon(t, false)
	if err := d.setSetting("remoteInput", true); err == nil {
		t.Fatal("no error")
	}
	if d.cfg.RemoteInput {
		t.Fatal("remote input is on after the error")
	}

	d.cfg.RemoteDesktop = true
	s := d.claimDesktop(inputDevice("phone", "Pixel 8"), newFakeStreamLink())
	if s == nil {
		t.Fatal("the remote desktop did not start")
	}
	err := d.setSetting("remoteDesktop", false)
	if err == nil || !strings.Contains(err.Error(), "off until fluxd restarts") {
		t.Fatalf("error %v", err)
	}
	if d.cfg.RemoteDesktop || s.ctx.Err() == nil {
		t.Fatal("the remote desktop runs after the switch turned off")
	}

	// Each other setting keeps its old value, and the window gets the
	// state again.
	d.mu.Lock()
	d.cfg.AutoClipboard, d.cfg.Notifications, d.cfg.PauseMediaOnCall, d.cfg.SyncDnd = true, true, true, true
	d.cfg.Herdr, d.cfg.CheckUpdates, d.cfg.Name, d.cfg.DownloadDir = true, true, "desk", "/home/alice/Downloads"
	d.mu.Unlock()
	for _, c := range []struct {
		key   string
		value any
		get   func(*config.Config) any
	}{
		{"autoClipboard", false, func(c *config.Config) any { return c.AutoClipboard }},
		{"notifications", false, func(c *config.Config) any { return c.Notifications }},
		{"pauseMediaOnCall", false, func(c *config.Config) any { return c.PauseMediaOnCall }},
		{"syncDnd", false, func(c *config.Config) any { return c.SyncDnd }},
		{"herdr", false, func(c *config.Config) any { return c.Herdr }},
		{"checkUpdates", false, func(c *config.Config) any { return c.CheckUpdates }},
		{"name", "laptop", func(c *config.Config) any { return c.Name }},
		{"downloadDir", "/tmp/elsewhere", func(c *config.Config) any { return c.DownloadDir }},
	} {
		d.mu.Lock()
		old := c.get(d.cfg)
		d.mu.Unlock()
		select {
		case <-d.dirty:
		default:
		}
		err := d.setSetting(c.key, c.value)
		if err == nil || !strings.Contains(err.Error(), c.key+" did not change") {
			t.Errorf("%s: error %v", c.key, err)
		}
		d.mu.Lock()
		now := c.get(d.cfg)
		d.mu.Unlock()
		if now != old {
			t.Errorf("%s is %v after the error, want %v", c.key, now, old)
		}
		if len(d.dirty) == 0 {
			t.Errorf("%s: the window does not get the old value", c.key)
		}
	}
}

// slowInput is an input backend whose Type waits until the test lets it
// go or until its context ends, as a slow wtype does.
type slowInput struct {
	fakeInput
	started chan struct{}
	release chan struct{}
}

func (s *slowInput) Type(ctx context.Context, text string, mods []string) error {
	s.started <- struct{}{}
	select {
	case <-s.release:
		return s.add("type %q", text)
	case <-ctx.Done():
		return s.add("stopped %q", text)
	}
}

func newSlowInput() *slowInput {
	return &slowInput{started: make(chan struct{}, inputQueue), release: make(chan struct{})}
}

func (s *slowInput) waitStart(t *testing.T) {
	t.Helper()
	select {
	case <-s.started:
	case <-time.After(3 * time.Second):
		t.Fatal("wtype did not start")
	}
}

// queueText queues typed text and keys from dev behind a wtype that waits.
func queueText(t *testing.T, d *Daemon, in *slowInput, dev *Device) {
	t.Helper()
	d.handleMousepad(dev, mousepad(`{"key":"first"}`))
	in.waitStart(t)
	for range 20 {
		d.handleMousepad(dev, mousepad(`{"key":"rm -rf ~"}`))
		d.handleMousepad(dev, mousepad(`{"specialKey":12}`))
	}
}

// Queued keys do not run after remote input turns off, and the wtype that
// runs stops.
func TestQueuedInputStopsWhenRemoteInputTurnsOff(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	in := newSlowInput()
	d := newInputDaemon(t, true, in)
	dev := inputDevice("phone", "Pixel 8")
	d.devices[dev.ID] = dev
	queueText(t, d, in, dev)
	if err := d.setSetting("remoteInput", false); err != nil {
		t.Fatal(err)
	}
	in.wait(t, 1)
	time.Sleep(100 * time.Millisecond)
	close(in.release)
	time.Sleep(100 * time.Millisecond)
	if got := in.got(); len(got) != 1 || got[0] != `stopped "first"` {
		t.Fatalf("remote input ran after it turned off: %q", got)
	}
	if n := len(d.inputQ); n != 0 {
		t.Fatalf("%d actions wait in the queue", n)
	}

	// Remote input that turns on again does not run the old actions.
	if err := d.setSetting("remoteInput", true); err != nil {
		t.Fatal(err)
	}
	d.handleMousepad(dev, mousepad(`{"key":"new"}`))
	if got := in.wait(t, 2); got[1] != `type "new"` {
		t.Fatalf("calls %q", got)
	}
}

// Queued keys do not run after an unpair, and the wtype that runs stops.
func TestQueuedInputStopsAfterAnUnpair(t *testing.T) {
	check := sessionCheck
	sessionCheck = 10 * time.Millisecond
	t.Cleanup(func() { sessionCheck = check })
	in := newSlowInput()
	d := newInputDaemon(t, true, in)
	dev := inputDevice("phone", "Pixel 8")
	queueText(t, d, in, dev)
	d.mu.Lock()
	dev.Paired = false
	d.mu.Unlock()
	in.wait(t, 1)
	close(in.release)
	time.Sleep(100 * time.Millisecond)
	if got := in.got(); len(got) != 1 || got[0] != `stopped "first"` {
		t.Fatalf("remote input ran after the unpair: %q", got)
	}
}

// A held button goes up when the link of the device that holds it drops,
// and when remote input turns off.
func TestHeldButtonGoesUp(t *testing.T) {
	d, in := inputDaemon(t, true)
	dev := inputDevice("phone", "Pixel 8")
	d.handleMousepad(dev, mousepad(`{"singlehold":true}`))
	in.wait(t, 1)
	d.mu.Lock()
	dev.link = nil
	d.mu.Unlock()
	if got := in.wait(t, 2); got[1] != "button 0x110 false" {
		t.Fatalf("calls %q", got)
	}

	dev = inputDevice("phone", "Pixel 8")
	d.handleMousepad(dev, mousepad(`{"singlehold":true}`))
	in.wait(t, 3)
	d.mu.Lock()
	d.cfg.RemoteInput = false
	d.mu.Unlock()
	d.inputChanged()
	if got := in.wait(t, 4); got[3] != "button 0x110 false" {
		t.Fatalf("calls %q", got)
	}
}

// A packet goes into the queue with all of its actions or not at all, and
// a release still fits in a full queue.
func TestInputQueueKeepsClicksWhole(t *testing.T) {
	in := &fakeInput{}
	d := &Daemon{
		cfg:    &config.Config{RemoteInput: true},
		input:  in,
		inputQ: make(chan inputAction, inputQueue),
		logger: log.New(io.Discard, "", 0),
	}
	dev := inputDevice("phone", "Pixel 8")
	for range inputQueue {
		d.handleMousepad(dev, mousepad(`{"singleclick":true}`))
	}
	if n := len(d.inputQ); n%2 != 0 || n > inputQueue-inputReserve {
		t.Fatalf("the queue holds %d actions", n)
	}
	d.handleMousepad(dev, mousepad(`{"singlerelease":true}`))
	if n := len(d.inputQ); n%2 != 1 {
		t.Fatalf("the release did not fit: %d actions", n)
	}
	// The text in the queue has a limit too.
	d2 := newInputDaemon(t, true, newSlowInput())
	long := strings.Repeat("a", maxInputText)
	for range 2 * maxInputBacklog / maxInputText {
		d2.handleMousepad(dev, mousepad(`{"key":"`+long+`"}`))
	}
	d2.mu.Lock()
	text := d2.sessions.inputText
	d2.mu.Unlock()
	if text > maxInputBacklog {
		t.Fatalf("the queue holds %d characters", text)
	}
}

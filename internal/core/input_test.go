package core

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
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
func (f *fakeInput) Type(text string, mods []string) error {
	return f.add("type %q %s", text, strings.Join(mods, "+"))
}
func (f *fakeInput) Key(name string, mods []string) error {
	return f.add("key %s %s", name, strings.Join(mods, "+"))
}
func (f *fakeInput) MoveTo(monitor string, x, y float64) error {
	return f.add("moveTo %s %g %g", monitor, x, y)
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
		{`{"doubleclick":true}`, []inputAction{
			{kind: "button", button: left, pressed: true}, {kind: "button", button: left},
			{kind: "button", button: left, pressed: true}, {kind: "button", button: left},
		}},
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
	d := &Daemon{
		cfg:    &config.Config{RemoteInput: on},
		input:  in,
		inputQ: make(chan inputAction, inputQueue),
		logger: log.New(io.Discard, "", 0),
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go d.inputLoop(ctx)
	return d, in
}

func mousepad(body string) *proto.Packet {
	var fields map[string]any
	_ = json.Unmarshal([]byte(body), &fields)
	return proto.New(proto.TypeMousepadRequest, fields)
}

func TestHandleMousepad(t *testing.T) {
	d, in := inputDaemon(t, true)
	dev := &Device{Name: "Pixel 8"}
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
	dev := &Device{ID: "phone", Name: "Pixel 8"}
	// Without a remote desktop, a position has no monitor.
	d.handleMousepad(dev, mousepad(`{"x":0.5,"y":0.5,"singleclick":true}`))
	d.desktop = &desktopSession{dev: dev, view: DesktopView{Monitor: "DP-1"}}
	d.handleMousepad(dev, mousepad(`{"x":0.5,"y":0.25,"rightclick":true}`))
	// A position from another phone has no monitor.
	d.handleMousepad(&Device{ID: "tablet", Name: "Tab"}, mousepad(`{"x":0.1,"y":0.1}`))
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
	dev := &Device{Name: "Pixel 8"}
	d.handleMousepad(dev, mousepad(`{"key":"rm -rf ~"}`))
	d.handleMousepad(dev, mousepad(`{"specialKey":12}`))
	time.Sleep(50 * time.Millisecond)
	if len(in.calls) != 0 {
		t.Fatalf("remote input ran while it is off: %q", in.calls)
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

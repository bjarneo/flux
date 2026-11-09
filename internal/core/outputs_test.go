package core

import (
	"context"
	"fmt"
	"slices"
	"sync"
	"testing"
	"time"

	"flux/internal/desktop"
	"flux/internal/proto"
)

// memOutputs is a fake of the audio outputs. It keeps the outputs in
// memory and records each change.
type memOutputs struct {
	mu      sync.Mutex
	outs    []desktop.Output
	changes []string
	// fail makes each call fail with this error.
	fail error
}

func newMemOutputs() *memOutputs {
	return &memOutputs{outs: []desktop.Output{
		{Name: "speakers", Description: "Laptop Speakers", Volume: 80, Default: true},
		{Name: "hdmi", Description: "HDMI \x1b[31mMonitor", Volume: 100},
	}}
}

func (m *memOutputs) List(context.Context) ([]desktop.Output, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail != nil {
		return nil, m.fail
	}
	return slices.Clone(m.outs), nil
}

func (m *memOutputs) Default(context.Context) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail != nil {
		return "", m.fail
	}
	for _, o := range m.outs {
		if o.Default {
			return o.Name, nil
		}
	}
	return "", nil
}

func (m *memOutputs) Find(_ context.Context, name string) (desktop.Output, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail != nil {
		return desktop.Output{}, m.fail
	}
	for _, o := range m.outs {
		if o.Name == name {
			return o, nil
		}
	}
	return desktop.Output{}, fmt.Errorf("no output %s", name)
}

// change applies f to the output with the name and records what.
func (m *memOutputs) change(name, what string, f func(o *desktop.Output)) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail != nil {
		return m.fail
	}
	for i := range m.outs {
		if m.outs[i].Name == name {
			f(&m.outs[i])
			m.changes = append(m.changes, name+" "+what)
			return nil
		}
	}
	return fmt.Errorf("no output %s", name)
}

func (m *memOutputs) SetDefault(_ context.Context, name string) error {
	m.mu.Lock()
	for i := range m.outs {
		m.outs[i].Default = false
	}
	m.mu.Unlock()
	return m.change(name, "default", func(o *desktop.Output) { o.Default = true })
}

func (m *memOutputs) SetVolume(_ context.Context, name string, percent int) error {
	return m.change(name, fmt.Sprintf("volume %d", percent), func(o *desktop.Output) { o.Volume = percent })
}

func (m *memOutputs) SetMute(_ context.Context, name string, muted bool) error {
	return m.change(name, fmt.Sprintf("mute %v", muted), func(o *desktop.Output) { o.Muted = muted })
}

func (m *memOutputs) log() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return slices.Clone(m.changes)
}

// nextOutputs returns the body of the next flux.audio packet on ch.
func nextOutputs(t *testing.T, ch chan *proto.Packet) (outs []map[string]any, errText string) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case p := <-ch:
			if p.Type != proto.TypeFluxAudio {
				continue
			}
			var b struct {
				Outputs []map[string]any `json:"outputs"`
				Error   string           `json:"error"`
			}
			if err := p.Decode(&b); err != nil {
				t.Fatal(err)
			}
			return b.Outputs, b.Error
		case <-deadline:
			t.Fatal("no flux.audio packet within 5 seconds")
			return nil, ""
		}
	}
}

func audioRequestPacket(body map[string]any) *proto.Packet {
	return proto.New(proto.TypeFluxAudioRequest, body)
}

func TestAudioOutputsRequest(t *testing.T) {
	d, dev, onDesk, ch := requestDaemon(t)
	m := newMemOutputs()
	d.outputs = m

	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"request": true}))
	outs, errText := nextOutputs(t, ch)
	if errText != "" || len(outs) != 2 {
		t.Fatalf("outputs %v, error %q", outs, errText)
	}
	if outs[0]["name"] != "speakers" || outs[0]["default"] != true || outs[0]["volume"] != 80.0 || outs[0]["muted"] != false {
		t.Fatalf("first output %v", outs[0])
	}
	// A description cannot carry control characters to the phone.
	if outs[1]["description"] != "HDMI [31mMonitor" {
		t.Fatalf("description %q", outs[1]["description"])
	}

	// Each change answers with the outputs after the change.
	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"output": "hdmi", "default": true}))
	if outs, _ = nextOutputs(t, ch); outs[1]["default"] != true || outs[0]["default"] != false {
		t.Fatalf("after the default change: %v", outs)
	}
	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"output": "speakers", "volume": 300}))
	nextOutputs(t, ch)
	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"output": "speakers", "mute": true}))
	if outs, _ = nextOutputs(t, ch); outs[0]["muted"] != true || outs[0]["volume"] != 150.0 {
		t.Fatalf("after the mute: %v", outs)
	}
	want := []string{"hdmi default", "speakers volume 150", "speakers mute true"}
	if got := m.log(); !slices.Equal(got, want) {
		t.Fatalf("changes %q, want %q", got, want)
	}

	// An output that is not in the list changes nothing.
	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"output": "--help", "mute": true}))
	if _, errText = nextOutputs(t, ch); errText == "" {
		t.Fatal("an unknown output must answer with an error")
	}
	if got := m.log(); len(got) != len(want) {
		t.Fatalf("an unknown output changed %q", got)
	}

	// A packet that asks for nothing gets no answer.
	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"output": "hdmi"}))
	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"request": true}))
	if outs, _ = nextOutputs(t, ch); len(outs) != 2 {
		t.Fatalf("outputs %v", outs)
	}
	select {
	case p := <-ch:
		t.Fatalf("an extra packet %s", p.Type)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestAudioOutputsErrors(t *testing.T) {
	d, dev, onDesk, ch := requestDaemon(t)
	// A headless daemon has no outputs.
	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"request": true}))
	if outs, errText := nextOutputs(t, ch); len(outs) != 0 || errText != errNoOutputs.Error() {
		t.Fatalf("headless: %v %q", outs, errText)
	}
	m := newMemOutputs()
	m.fail = desktop.ErrNoPactl
	d.outputs = m
	d.handlePacket(dev, onDesk, audioRequestPacket(map[string]any{"request": true}))
	if _, errText := nextOutputs(t, ch); errText != desktop.ErrNoPactl.Error() {
		t.Fatalf("without pactl: %q", errText)
	}
	// A device that is not paired gets nothing.
	m.fail = nil
	d.mu.Lock()
	dev.Paired = false
	d.mu.Unlock()
	d.answerAudio(onDesk, audioRequest{Request: true})
	select {
	case p := <-ch:
		t.Fatalf("a device that is not paired got %s", p.Type)
	case <-time.After(100 * time.Millisecond):
	}
}

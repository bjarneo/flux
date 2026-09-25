package core

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// The phone as microphone. The phone streams raw PCM, and pw-cat plays it
// into a new PipeWire source, "Flux Microphone", that apps can select. The
// source exists while pw-cat runs, so it goes away when the stream stops.

const (
	micSource = "Flux Microphone"
	micNode   = "flux_mic"
)

// MicView is the microphone state for the window.
type MicView struct {
	Active   bool   `json:"active"`
	Source   string `json:"source"`
	From     string `json:"from"`
	FromName string `json:"fromName"`
	Rate     int    `json:"rate"`
	Channels int    `json:"channels"`
	Error    string `json:"error,omitempty"`
}

type micSession struct {
	dev    *Device
	link   *lan.Link
	cancel context.CancelFunc
	view   MicView
}

type micStart struct {
	State    string `json:"state"`
	Port     int    `json:"port"`
	Rate     int    `json:"rate"`
	Channels int    `json:"channels"`
	Format   string `json:"format"`
	Message  string `json:"message"`
}

// check fills in the defaults and reports a stream that fluxd cannot play.
func (b *micStart) check() error {
	if b.Format == "" {
		b.Format = "s16le"
	}
	if b.Rate == 0 {
		b.Rate = 48000
	}
	if b.Channels == 0 {
		b.Channels = 1
	}
	switch {
	case b.Port <= 0 || b.Port > 65535:
		return fmt.Errorf("the port %d is not valid", b.Port)
	case b.Format != "s16le":
		return fmt.Errorf("the format %q is not supported. Send s16le", b.Format)
	case b.Rate < 8000 || b.Rate > 96000:
		return fmt.Errorf("the rate %d Hz is not supported. Send 8000 to 96000 Hz", b.Rate)
	case b.Channels != 1 && b.Channels != 2:
		return fmt.Errorf("%d channels are not supported. Send 1 or 2", b.Channels)
	}
	return nil
}

// micArgs returns the pw-cat arguments that play raw s16le PCM from stdin
// into a new PipeWire source.
func micArgs(rate, channels int) []string {
	props := fmt.Sprintf(`{ media.class = "Audio/Source" node.name = %q node.description = %q media.icon-name = "audio-input-microphone" }`,
		micNode, micSource)
	return []string{
		"--playback", "--raw",
		"--format", "s16", "--rate", strconv.Itoa(rate), "--channels", strconv.Itoa(channels),
		"--latency", "40ms",
		"--properties", props,
		"-",
	}
}

func (d *Daemon) handleMic(dev *Device, l *lan.Link, p *proto.Packet) {
	var b micStart
	if p.Decode(&b) != nil {
		return
	}
	switch b.State {
	case "start":
		go d.runMic(dev, l, b)
	case "stop":
		d.endMic(dev.ID)
	case "error":
		d.logf("%s: microphone: %s", dev.Name, b.Message)
	}
}

// runMic runs 1 microphone session until the phone stops, the link drops,
// or the user stops it on this computer.
func (d *Daemon) runMic(dev *Device, l *lan.Link, b micStart) {
	fail := func(err error) {
		d.logf("%s: microphone: %v", dev.Name, err)
		_ = l.Send(proto.New(proto.TypeFluxMic, map[string]any{"state": "error", "message": err.Error()}))
		d.mu.Lock()
		d.micErr = err.Error()
		d.mu.Unlock()
		d.markDirty()
	}
	if err := b.check(); err != nil {
		fail(err)
		return
	}
	if d.opts.Headless {
		fail(errors.New("the microphone is off in headless mode"))
		return
	}
	pwcat, err := exec.LookPath("pw-cat")
	if err != nil {
		fail(errors.New("pw-cat is not installed on the computer. Install it with: sudo pacman -S pipewire"))
		return
	}
	d.endMic("")
	ctx, cancel := context.WithCancel(d.ctx)
	defer cancel()
	tc, err := l.DialPeer(ctx, b.Port)
	if err != nil {
		fail(fmt.Errorf("connect to the phone microphone: %w", err))
		return
	}
	defer tc.Close()
	s := &micSession{dev: dev, link: l, cancel: cancel, view: MicView{
		Source: micSource, From: dev.ID, FromName: dev.Name, Rate: b.Rate, Channels: b.Channels,
	}}
	d.mu.Lock()
	d.mic, d.micErr = s, ""
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		if d.mic == s {
			d.mic = nil
		}
		d.mu.Unlock()
		d.markDirty()
	}()
	cancelOnLinkDown(ctx, l, cancel)

	cmd := childCommand(ctx, pwcat, micArgs(b.Rate, b.Channels)...)
	cmd.Stdin = tc
	var stderr lockedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		fail(fmt.Errorf("start pw-cat: %w", err))
		return
	}
	// Report the microphone as live once pw-cat runs with the stream.
	go func() {
		select {
		case <-time.After(700 * time.Millisecond):
		case <-ctx.Done():
			return
		}
		d.mu.Lock()
		s.view.Active = true
		d.mu.Unlock()
		_ = l.Send(proto.New(proto.TypeFluxMic, map[string]any{"state": "live", "source": micSource}))
		d.toast("%s is live as %s", dev.Name, micSource)
		d.markDirty()
	}()
	err = cmd.Wait()
	if err != nil && ctx.Err() == nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		fail(fmt.Errorf("the audio stream stopped: %s", lastLine(msg)))
		return
	}
	d.logf("%s: microphone stopped", dev.Name)
}

// endMic stops the session. An empty ID stops any session.
func (d *Daemon) endMic(deviceID string) {
	d.mu.Lock()
	s := d.mic
	d.mu.Unlock()
	if s != nil && (deviceID == "" || s.dev.ID == deviceID) {
		s.cancel()
	}
}

// StopMic stops the phone microphone from this computer and tells the phone.
func (d *Daemon) StopMic() error {
	d.mu.Lock()
	s := d.mic
	d.mu.Unlock()
	if s == nil {
		return apiErr("not_active", "No phone microphone is live")
	}
	_ = s.link.Send(proto.New(proto.TypeFluxMic, map[string]any{"state": "stop"}))
	s.cancel()
	return nil
}

func (d *Daemon) micViewLocked() *MicView {
	if d.mic != nil {
		v := d.mic.view
		return &v
	}
	if d.micErr != "" {
		return &MicView{Error: d.micErr, Source: micSource}
	}
	return nil
}

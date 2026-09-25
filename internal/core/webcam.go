package core

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"

	"flux/internal/desktop"
	"flux/internal/lan"
	"flux/internal/proto"
)

// The phone as webcam. The phone opens a TLS listener and sends its port in
// a flux.webcam packet. fluxd connects out to it, so the stream passes a
// firewall that blocks incoming traffic, and pipes the raw H.264 stream
// into ffmpeg. ffmpeg writes the frames to a v4l2loopback device, which
// video call apps see as the camera "Flux Camera".

const webcamLabel = "Flux Camera"

// WebcamView is the webcam state for the window.
type WebcamView struct {
	Active   bool   `json:"active"`
	Device   string `json:"device"`
	Label    string `json:"label"`
	From     string `json:"from"`
	FromName string `json:"fromName"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	FPS      int    `json:"fps"`
	Error    string `json:"error,omitempty"`
}

type webcamSession struct {
	dev    *Device
	link   *lan.Link
	cancel context.CancelFunc
	view   WebcamView
}

type webcamStart struct {
	State   string `json:"state"`
	Port    int    `json:"port"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
	FPS     int    `json:"fps"`
	Codec   string `json:"codec"`
	Message string `json:"message"`
}

func (d *Daemon) handleWebcam(dev *Device, l *lan.Link, p *proto.Packet) {
	var b webcamStart
	if p.Decode(&b) != nil {
		return
	}
	switch b.State {
	case "start":
		go d.runWebcam(dev, l, b)
	case "stop":
		d.endWebcam(dev.ID)
	case "error":
		d.logf("%s: webcam: %s", dev.Name, b.Message)
	}
}

// runWebcam runs 1 webcam session until the phone stops, the link drops,
// or the user stops it on this computer.
func (d *Daemon) runWebcam(dev *Device, l *lan.Link, b webcamStart) {
	fail := func(err error) {
		d.logf("%s: webcam: %v", dev.Name, err)
		_ = l.Send(proto.New(proto.TypeFluxWebcam, map[string]any{"state": "error", "message": err.Error()}))
		d.mu.Lock()
		d.webcamErr = err.Error()
		d.mu.Unlock()
		d.markDirty()
	}
	if b.Codec != "" && b.Codec != "h264" {
		fail(fmt.Errorf("the codec %q is not supported. Send h264", b.Codec))
		return
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		fail(errors.New("ffmpeg is not installed on the computer. Install it with: sudo pacman -S ffmpeg"))
		return
	}
	d.endWebcam("")
	loop, err := d.loopbackDevice()
	if err != nil {
		fail(err)
		return
	}
	ctx, cancel := context.WithCancel(d.ctx)
	defer cancel()
	tc, err := l.DialPeer(ctx, b.Port)
	if err != nil {
		fail(fmt.Errorf("connect to the phone camera: %w", err))
		return
	}
	defer tc.Close()
	if b.FPS <= 0 {
		b.FPS = 30
	}
	s := &webcamSession{dev: dev, link: l, cancel: cancel, view: WebcamView{
		Device: loop.Path, Label: loop.Label, From: dev.ID, FromName: dev.Name,
		Width: b.Width, Height: b.Height, FPS: b.FPS,
	}}
	d.mu.Lock()
	d.webcam, d.webcamErr = s, ""
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		if d.webcam == s {
			d.webcam = nil
		}
		d.mu.Unlock()
		d.markDirty()
	}()
	// The session also ends when the link to the phone drops.
	go func() {
		select {
		case <-l.Done():
			cancel()
		case <-ctx.Done():
		}
	}()

	cmd := exec.CommandContext(ctx, ffmpeg,
		"-hide_banner", "-loglevel", "error",
		// -fflags nobuffer is left out on purpose: with a pipe it drops
		// frames.
		"-flags", "low_delay", "-probesize", "32", "-analyzeduration", "0",
		"-f", "h264", "-framerate", fmt.Sprint(b.FPS), "-i", "pipe:0",
		"-vf", "format=yuv420p", "-f", "v4l2", loop.Path)
	cmd.Stdin = tc
	var stderr lockedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		fail(fmt.Errorf("start ffmpeg: %w", err))
		return
	}
	// Report the camera as live once ffmpeg runs with the stream.
	go func() {
		select {
		case <-time.After(1500 * time.Millisecond):
		case <-ctx.Done():
			return
		}
		d.mu.Lock()
		s.view.Active = true
		d.mu.Unlock()
		_ = l.Send(proto.New(proto.TypeFluxWebcam, map[string]any{"state": "live", "device": loop.Path, "label": loop.Label}))
		d.toast("%s is live as %s", dev.Name, loop.Label)
		d.markDirty()
	}()
	err = cmd.Wait()
	if err != nil && ctx.Err() == nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		fail(fmt.Errorf("the video stream stopped: %s", lastLine(msg)))
		return
	}
	d.logf("%s: webcam stopped", dev.Name)
}

// endWebcam stops the session. An empty ID stops any session.
func (d *Daemon) endWebcam(deviceID string) {
	d.mu.Lock()
	s := d.webcam
	d.mu.Unlock()
	if s != nil && (deviceID == "" || s.dev.ID == deviceID) {
		s.cancel()
	}
}

// StopWebcam stops the phone camera from this computer and tells the phone.
func (d *Daemon) StopWebcam() error {
	d.mu.Lock()
	s := d.webcam
	d.mu.Unlock()
	if s == nil {
		return apiErr("not_active", "No phone camera is live")
	}
	_ = s.link.Send(proto.New(proto.TypeFluxWebcam, map[string]any{"state": "stop"}))
	s.cancel()
	return nil
}

// loopbackDevice returns the Flux Camera device and creates it on first
// use. The device stays until fluxd stops, so video apps keep it in their
// camera list between sessions.
func (d *Daemon) loopbackDevice() (*desktop.Loopback, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.loopback != nil {
		return d.loopback, nil
	}
	l, err := desktop.OpenLoopback(webcamLabel)
	if err != nil {
		return nil, err
	}
	d.loopback = l
	return l, nil
}

func (d *Daemon) webcamViewLocked() *WebcamView {
	if d.webcam != nil {
		v := d.webcam.view
		return &v
	}
	if d.webcamErr != "" {
		return &WebcamView{Error: d.webcamErr, Label: webcamLabel}
	}
	return nil
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}

// lockedBuffer collects the output of ffmpeg, which writes from its own
// goroutine.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.buf.Len() < 8192 {
		b.buf.Write(p)
	}
	return len(p), nil
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

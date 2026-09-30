package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os/exec"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"flux/internal/desktop"
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
	// Config and Caps are the camera settings and their ranges, as the
	// phone last reported them.
	Config json.RawMessage `json:"config,omitempty"`
	Caps   json.RawMessage `json:"caps,omitempty"`
}

type webcamSession struct {
	dev    *Device
	link   streamLink
	cancel context.CancelFunc
	view   WebcamView

	// ctx ends with the session. done closes when runWebcam returns, and
	// prev is done of the session before, or nil.
	ctx        context.Context
	done, prev chan struct{}
}

type webcamStart struct {
	State   string          `json:"state"`
	Port    int             `json:"port"`
	Width   int             `json:"width"`
	Height  int             `json:"height"`
	FPS     int             `json:"fps"`
	Codec   string          `json:"codec"`
	Message string          `json:"message"`
	Config  json.RawMessage `json:"config"`
	Caps    json.RawMessage `json:"caps"`
}

func (d *Daemon) handleWebcam(dev *Device, l streamLink, p *proto.Packet) {
	var b webcamStart
	if p.Decode(&b) != nil {
		return
	}
	switch b.State {
	case "start":
		if s := d.claimWebcam(dev, l, b); s != nil {
			go d.runWebcam(s, b)
		}
	case "stop":
		d.endWebcam(dev.ID)
	case "config":
		// The phone reports its settings after a start and after each
		// change. Only the device of the session can report them.
		config, caps, err := cleanWebcamConfig(b.Config, b.Caps)
		if err != nil {
			d.logf("%s: webcam: ignored the settings: %s", dev.Name, peerText(err.Error()))
			return
		}
		d.mu.Lock()
		if d.webcam != nil && d.webcam.dev.ID == dev.ID {
			if config != nil {
				d.webcamConfig = config
			}
			if caps != nil {
				d.webcamCaps = caps
			}
		}
		d.mu.Unlock()
		d.markDirty()
	case "error":
		d.logf("%s: webcam: %s", dev.Name, peerText(b.Message))
	}
}

// Limits for the webcam settings from the phone. The window shows each
// value, so a larger value is refused. The Mac names each camera by its
// device name, so maxWebcamText also fits a long camera name.
const (
	maxWebcamJSON    = 4096
	maxWebcamList    = 16
	maxWebcamText    = 128
	maxWebcamNumbers = 1 << 16
)

// webcamConfig is the camera settings that the phone reports. A field that
// the phone does not send stays out.
type webcamConfig struct {
	Aspect       string   `json:"aspect,omitempty"`
	Resolution   *int     `json:"resolution,omitempty"`
	Camera       string   `json:"camera,omitempty"`
	Mirror       *bool    `json:"mirror,omitempty"`
	Zoom         *float64 `json:"zoom,omitempty"`
	Exposure     *float64 `json:"exposure,omitempty"`
	WhiteBalance string   `json:"whiteBalance,omitempty"`
	Brightness   *float64 `json:"brightness,omitempty"`
	Contrast     *float64 `json:"contrast,omitempty"`
	Saturation   *float64 `json:"saturation,omitempty"`
	Warmth       *float64 `json:"warmth,omitempty"`
}

// webcamCaps is what the camera of the phone supports.
type webcamCaps struct {
	ZoomMax      *float64 `json:"zoomMax,omitempty"`
	ExposureMin  *float64 `json:"exposureMin,omitempty"`
	ExposureMax  *float64 `json:"exposureMax,omitempty"`
	ExposureStep *float64 `json:"exposureStep,omitempty"`
	WhiteBalance []string `json:"whiteBalance,omitempty"`
	Cameras      []string `json:"cameras,omitempty"`
	Aspects      []string `json:"aspects,omitempty"`
	Resolutions  []int    `json:"resolutions,omitempty"`
}

// cleanWebcamConfig checks the settings from the phone and returns them
// with only the known fields. A nil result means that the phone did not
// send that value.
func cleanWebcamConfig(rawConfig, rawCaps json.RawMessage) (json.RawMessage, json.RawMessage, error) {
	if len(rawConfig) > maxWebcamJSON || len(rawCaps) > maxWebcamJSON {
		return nil, nil, fmt.Errorf("the settings have more than %d bytes", maxWebcamJSON)
	}
	var config, caps json.RawMessage
	if len(rawConfig) > 0 {
		var c webcamConfig
		if err := json.Unmarshal(rawConfig, &c); err != nil {
			return nil, nil, err
		}
		for _, t := range []string{c.Aspect, c.Camera, c.WhiteBalance} {
			if !webcamText(t) {
				return nil, nil, errors.New("a text value is too long")
			}
		}
		for _, v := range []*float64{c.Zoom, c.Exposure, c.Brightness, c.Contrast, c.Saturation, c.Warmth} {
			if !webcamNumber(v) {
				return nil, nil, errors.New("a number is out of range")
			}
		}
		if c.Resolution != nil && (*c.Resolution < 0 || *c.Resolution > maxWebcamNumbers) {
			return nil, nil, errors.New("the resolution is out of range")
		}
		config, _ = json.Marshal(c)
	}
	if len(rawCaps) > 0 {
		var c webcamCaps
		if err := json.Unmarshal(rawCaps, &c); err != nil {
			return nil, nil, err
		}
		for _, list := range [][]string{c.WhiteBalance, c.Cameras, c.Aspects} {
			if len(list) > maxWebcamList {
				return nil, nil, fmt.Errorf("a list has more than %d values", maxWebcamList)
			}
			for _, t := range list {
				if !webcamText(t) {
					return nil, nil, errors.New("a text value is too long")
				}
			}
		}
		if len(c.Resolutions) > maxWebcamList {
			return nil, nil, fmt.Errorf("a list has more than %d values", maxWebcamList)
		}
		for _, v := range []*float64{c.ZoomMax, c.ExposureMin, c.ExposureMax, c.ExposureStep} {
			if !webcamNumber(v) {
				return nil, nil, errors.New("a number is out of range")
			}
		}
		caps, _ = json.Marshal(c)
	}
	return config, caps, nil
}

func webcamText(s string) bool { return utf8.RuneCountInString(s) <= maxWebcamText }

func webcamNumber(v *float64) bool {
	return v == nil || (finite(*v) && math.Abs(*v) <= maxWebcamNumbers)
}

// claimWebcam makes a new session the webcam session before any slow work,
// and stops the session that ran before. It returns nil when the webcam
// cannot start, and then it tells the phone.
func (d *Daemon) claimWebcam(dev *Device, l streamLink, b webcamStart) *webcamSession {
	var err error
	d.mu.Lock()
	switch {
	case b.Codec != "" && b.Codec != "h264":
		err = fmt.Errorf("the codec %s is not supported. Send h264", peerText(b.Codec))
	case d.opts.Headless:
		err = errors.New("the webcam is off in headless mode")
	case !dev.Paired:
		err = fmt.Errorf("%s is not paired with %s", dev.Name, d.nameLocked())
	}
	if err != nil {
		d.mu.Unlock()
		d.failWebcam(nil, dev, l, err)
		return nil
	}
	if b.FPS <= 0 {
		b.FPS = 30
	}
	ctx, cancel := context.WithCancel(d.ctx)
	s := &webcamSession{dev: dev, link: l, cancel: cancel, ctx: ctx, view: WebcamView{
		Label: webcamLabel, From: dev.ID, FromName: dev.Name, Width: b.Width, Height: b.Height, FPS: b.FPS,
	}}
	s.done, s.prev = d.sessions.webcamTurn.take()
	old := d.webcam
	d.webcam, d.webcamErr = s, ""
	// The settings of the last session belong to that session.
	d.webcamConfig, d.webcamCaps = nil, nil
	d.mu.Unlock()
	if old != nil {
		old.cancel()
	}
	d.watchSession(ctx, cancel, dev, l, nil)
	d.markDirty()
	return s
}

// failWebcam tells the phone why the webcam stopped, and shows the error in
// the window.
func (d *Daemon) failWebcam(s *webcamSession, dev *Device, l streamLink, err error) {
	d.logf("%s: webcam: %v", dev.Name, err)
	_ = l.Send(proto.New(proto.TypeFluxWebcam, map[string]any{"state": "error", "message": err.Error()}))
	d.mu.Lock()
	if d.webcam == nil || d.webcam == s {
		d.webcamErr = err.Error()
	}
	d.mu.Unlock()
	d.markDirty()
}

// runWebcam runs 1 webcam session until the phone stops, the link drops,
// or the user stops it on this computer.
func (d *Daemon) runWebcam(s *webcamSession, b webcamStart) {
	dev, l, ctx := s.dev, s.link, s.ctx
	defer endTurn(s.done, s.prev)
	defer d.dropWebcam(s)
	defer s.cancel()
	fail := func(err error) {
		if ctx.Err() == nil {
			d.failWebcam(s, dev, l, err)
		}
	}
	// The ffmpeg of the session before stops first.
	if !waitTurn(ctx, s.prev) {
		return
	}
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		fail(errors.New("ffmpeg is not installed on the computer. Install it with: sudo pacman -S ffmpeg"))
		return
	}
	loop, err := d.loopbackDevice()
	if err != nil {
		fail(err)
		return
	}
	tc, err := l.DialPeer(ctx, b.Port)
	if err != nil {
		fail(fmt.Errorf("connect to the phone camera: %w", err))
		return
	}
	defer tc.Close()
	// A stop or a dropped link closes the stream, so that the copy to the
	// process ends at once.
	defer context.AfterFunc(ctx, func() { tc.Close() })()
	// Only the current session writes to the loopback device.
	d.mu.Lock()
	current := d.webcam == s && dev.Paired
	s.view.Device, s.view.Label = loop.Path, loop.Label
	d.mu.Unlock()
	if !current || ctx.Err() != nil {
		return
	}
	d.markDirty()

	fps := b.FPS
	if fps <= 0 {
		fps = 30
	}
	cmd := childCommand(ctx, ffmpeg,
		"-hide_banner", "-loglevel", "error",
		// -fflags nobuffer is left out on purpose: with a pipe it drops
		// frames.
		"-flags", "low_delay", "-probesize", "32", "-analyzeduration", "0",
		"-f", "h264", "-framerate", fmt.Sprint(fps), "-i", "pipe:0",
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

// dropWebcam removes a session that ended, with its settings.
func (d *Daemon) dropWebcam(s *webcamSession) {
	d.mu.Lock()
	if d.webcam == s {
		d.webcam = nil
		d.webcamConfig, d.webcamCaps = nil, nil
	}
	d.mu.Unlock()
	d.markDirty()
}

// takeWebcam removes the session from the slot and returns it, or nil. An
// empty ID takes any session. The caller stops the session.
func (d *Daemon) takeWebcam(deviceID string) *webcamSession {
	d.mu.Lock()
	defer d.mu.Unlock()
	s := d.webcam
	if s == nil || (deviceID != "" && s.dev.ID != deviceID) {
		return nil
	}
	d.webcam = nil
	d.webcamConfig, d.webcamCaps = nil, nil
	return s
}

// endWebcam stops the session, also while fluxd still sets it up. An empty
// ID stops any session.
func (d *Daemon) endWebcam(deviceID string) {
	if s := d.takeWebcam(deviceID); s != nil {
		s.cancel()
		d.markDirty()
	}
}

// StopWebcam stops the phone camera from this computer and tells the phone.
func (d *Daemon) StopWebcam() error {
	s := d.takeWebcam("")
	if s == nil {
		return apiErr("not_active", "No phone camera is live")
	}
	_ = s.link.Send(proto.New(proto.TypeFluxWebcam, map[string]any{"state": "stop"}))
	s.cancel()
	d.markDirty()
	return nil
}

// ConfigureWebcam sends changed settings to the phone that streams. With
// reset, the phone goes back to the neutral values. A change of the format
// or the camera makes the phone restart the stream. fluxd sends only the
// known settings, with the limits of the settings from the phone, so that
// a value cannot stop an older app.
func (d *Daemon) ConfigureWebcam(config json.RawMessage, reset bool) error {
	d.mu.Lock()
	s := d.webcam
	d.mu.Unlock()
	if s == nil {
		return apiErr("not_active", "No phone camera is live")
	}
	body := map[string]any{"state": "config"}
	switch {
	case reset:
		body["reset"] = true
	case len(config) > 0:
		dec := json.NewDecoder(bytes.NewReader(config))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&webcamConfig{}); err != nil {
			return apiErr("bad_params", "The webcam settings are not valid: %v", err)
		}
		clean, _, err := cleanWebcamConfig(config, nil)
		if err != nil {
			return apiErr("bad_params", "The webcam settings are not valid: %v", err)
		}
		if string(clean) == "{}" {
			return apiErr("bad_params", "config must be an object with at least 1 setting")
		}
		body["config"] = clean
	default:
		return apiErr("bad_params", "Give config or reset")
	}
	return s.link.Send(proto.New(proto.TypeFluxWebcam, body))
}

// loopbackDevice returns the Flux Camera device and creates it on first
// use. The device stays until fluxd stops, so video apps keep it in their
// camera list between sessions.
// The creation can wait 2 seconds for udev, so it holds loopMu and not d.mu.
func (d *Daemon) loopbackDevice() (*desktop.Loopback, error) {
	d.loopMu.Lock()
	defer d.loopMu.Unlock()
	d.mu.Lock()
	l := d.loopback
	d.mu.Unlock()
	if l != nil {
		return l, nil
	}
	l, err := desktop.OpenLoopback(webcamLabel)
	if err != nil {
		return nil, err
	}
	d.mu.Lock()
	d.loopback = l
	d.mu.Unlock()
	return l, nil
}

func (d *Daemon) webcamViewLocked() *WebcamView {
	if d.webcam != nil {
		v := d.webcam.view
		v.Config, v.Caps = d.webcamConfig, d.webcamCaps
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

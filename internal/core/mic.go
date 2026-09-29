package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"

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
	link   streamLink
	cancel context.CancelFunc
	view   MicView

	// ctx ends with the session. done closes when runMic returns, and
	// prev is done of the session before, or nil.
	ctx        context.Context
	done, prev chan struct{}
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
		return fmt.Errorf("the format %s is not supported. Send s16le", peerText(b.Format))
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

func (d *Daemon) handleMic(dev *Device, l streamLink, p *proto.Packet) {
	var b micStart
	if p.Decode(&b) != nil {
		return
	}
	switch b.State {
	case "start":
		if s := d.claimMic(dev, l, &b); s != nil {
			go d.runMic(s, b)
		}
	case "stop":
		d.endMic(dev.ID)
	case "error":
		d.logf("%s: microphone: %s", dev.Name, peerText(b.Message))
	}
}

// claimMic makes a new session the microphone session before any slow
// work, and stops the session that ran before. It returns nil when the
// microphone cannot start, and then it tells the phone.
func (d *Daemon) claimMic(dev *Device, l streamLink, b *micStart) *micSession {
	err := b.check()
	d.mu.Lock()
	switch {
	case err != nil:
	case d.opts.Headless:
		err = errors.New("the microphone is off in headless mode")
	case !dev.Paired:
		err = fmt.Errorf("%s is not paired with %s", dev.Name, d.nameLocked())
	}
	if err != nil {
		d.mu.Unlock()
		d.failMic(nil, dev, l, err)
		return nil
	}
	ctx, cancel := context.WithCancel(d.ctx)
	s := &micSession{dev: dev, link: l, cancel: cancel, ctx: ctx, view: MicView{
		Source: micSource, From: dev.ID, FromName: dev.Name, Rate: b.Rate, Channels: b.Channels,
	}}
	s.done, s.prev = d.sessions.micTurn.take()
	old := d.mic
	d.mic, d.micErr = s, ""
	d.mu.Unlock()
	if old != nil {
		old.cancel()
	}
	d.watchSession(ctx, cancel, dev, l, nil)
	d.markDirty()
	return s
}

// failMic tells the phone why the microphone stopped, and shows the error
// in the window.
func (d *Daemon) failMic(s *micSession, dev *Device, l streamLink, err error) {
	d.logf("%s: microphone: %v", dev.Name, err)
	_ = l.Send(proto.New(proto.TypeFluxMic, map[string]any{"state": "error", "message": err.Error()}))
	d.mu.Lock()
	if d.mic == nil || d.mic == s {
		d.micErr = err.Error()
	}
	d.mu.Unlock()
	d.markDirty()
}

// runMic runs 1 microphone session until the phone stops, the link drops,
// or the user stops it on this computer.
func (d *Daemon) runMic(s *micSession, b micStart) {
	dev, l, ctx := s.dev, s.link, s.ctx
	defer endTurn(s.done, s.prev)
	defer d.dropMic(s)
	defer s.cancel()
	fail := func(err error) {
		if ctx.Err() == nil {
			d.failMic(s, dev, l, err)
		}
	}
	// The pw-cat of the session before stops first.
	if !waitTurn(ctx, s.prev) {
		return
	}
	pwcat, err := exec.LookPath("pw-cat")
	if err != nil {
		fail(errors.New("pw-cat is not installed on the computer. Install it with: sudo pacman -S pipewire"))
		return
	}
	tc, err := l.DialPeer(ctx, b.Port)
	if err != nil {
		fail(fmt.Errorf("connect to the phone microphone: %w", err))
		return
	}
	defer tc.Close()
	// A stop or a dropped link closes the stream, so that the copy to the
	// process ends at once.
	defer context.AfterFunc(ctx, func() { tc.Close() })()
	// Only the current session makes a Flux Microphone source.
	d.mu.Lock()
	current := d.mic == s && dev.Paired
	d.mu.Unlock()
	if !current || ctx.Err() != nil {
		return
	}

	// pw-cat reads from a small pipe, and micPump keeps at most
	// micBacklog of audio in front of it. The delay then stays short after
	// a stall of the network.
	pr, pw, err := os.Pipe()
	if err != nil {
		fail(err)
		return
	}
	defer pw.Close()
	if sc, err := pw.SyscallConn(); err == nil {
		_ = sc.Control(func(fd uintptr) { _, _ = unix.FcntlInt(fd, unix.F_SETPIPE_SZ, micPipeSize) })
	}
	cmd := childCommand(ctx, pwcat, micArgs(b.Rate, b.Channels)...)
	cmd.Stdin = pr
	var stderr lockedBuffer
	cmd.Stderr = &stderr
	err = cmd.Start()
	pr.Close()
	if err != nil {
		fail(fmt.Errorf("start pw-cat: %w", err))
		return
	}
	frame := 2 * b.Channels
	limit := int(micBacklog.Seconds()*float64(b.Rate)) * frame
	go func() {
		dropped := false
		_ = micPump(pw, tc, frame, limit, func() {
			if !dropped {
				dropped = true
				d.logf("%s: microphone: dropped audio after a network stall, to keep the delay short", dev.Name)
			}
		})
		// pw-cat ends at the end of its input.
		pw.Close()
	}()
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

const (
	// micBacklog is the most audio that fluxd keeps for pw-cat. Older
	// audio is dropped, so a stall of the network adds no lasting delay.
	micBacklog = 150 * time.Millisecond
	// micPipeSize is the size of the pipe to pw-cat, about 40 ms of audio.
	micPipeSize = 4096
)

// micPump copies the audio from src to dst. It keeps at most limit bytes
// that dst did not take yet, and drops the oldest whole frames of frame
// bytes when more arrive. It calls dropped for each drop. It returns when
// src ends or dst fails.
func micPump(dst io.Writer, src io.Reader, frame, limit int, dropped func()) error {
	var (
		mu   sync.Mutex
		cond = sync.NewCond(&mu)
		buf  []byte
		done bool
		werr error
	)
	go func() {
		chunk := make([]byte, 4096)
		for {
			n, err := src.Read(chunk)
			mu.Lock()
			if werr != nil {
				mu.Unlock()
				return
			}
			buf = append(buf, chunk[:n]...)
			if over := len(buf) - limit; over > 0 {
				// Drop whole frames, so that the samples stay aligned.
				over = (over + frame - 1) / frame * frame
				buf = buf[:copy(buf, buf[min(over, len(buf)):])]
				dropped()
			}
			if err != nil {
				done = true
			}
			cond.Signal()
			mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	out := make([]byte, micPipeSize)
	for {
		mu.Lock()
		for len(buf) == 0 && !done {
			cond.Wait()
		}
		if len(buf) == 0 {
			mu.Unlock()
			return nil
		}
		n := copy(out, buf)
		buf = buf[:copy(buf, buf[n:])]
		mu.Unlock()
		if _, err := dst.Write(out[:n]); err != nil {
			mu.Lock()
			werr = err
			mu.Unlock()
			return err
		}
	}
}

// dropMic removes a session that ended.
func (d *Daemon) dropMic(s *micSession) {
	d.mu.Lock()
	if d.mic == s {
		d.mic = nil
	}
	d.mu.Unlock()
	d.markDirty()
}

// takeMic removes the session from the slot and returns it, or nil. An
// empty ID takes any session. The caller stops the session.
func (d *Daemon) takeMic(deviceID string) *micSession {
	d.mu.Lock()
	defer d.mu.Unlock()
	s := d.mic
	if s == nil || (deviceID != "" && s.dev.ID != deviceID) {
		return nil
	}
	d.mic = nil
	return s
}

// endMic stops the session, also while fluxd still sets it up. An empty ID
// stops any session.
func (d *Daemon) endMic(deviceID string) {
	if s := d.takeMic(deviceID); s != nil {
		s.cancel()
		d.markDirty()
	}
}

// StopMic stops the phone microphone from this computer and tells the phone.
func (d *Daemon) StopMic() error {
	s := d.takeMic("")
	if s == nil {
		return apiErr("not_active", "No phone microphone is live")
	}
	_ = s.link.Send(proto.New(proto.TypeFluxMic, map[string]any{"state": "stop"}))
	s.cancel()
	d.markDirty()
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

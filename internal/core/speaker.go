package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"flux/internal/config"
	"flux/internal/desktop"
	"flux/internal/proto"
)

// The phone as a speaker of this computer. The phone opens a TLS listener
// and sends its port in a flux.speaker packet, as for the microphone.
// fluxd connects out to it, captures the monitor of the default output
// with pw-record, and writes the audio as frames of the remote desktop:
// 20 ms of stereo, 48 kHz, signed 16-bit little-endian PCM in each frame.
// The stream needs no remote desktop.
//
// PCM needs about 1.54 Mbit/s. That is a small part of a Wi-Fi link, and
// PCM adds no codec delay and no CPU work on either side. Opus would need
// about 128 kbit/s, which matters only on a slow link, such as Tailscale
// over mobile data.
//
// With mute, fluxd mutes the default output while the phone plays, and
// turns its sound on again when the stream ends. The monitor of an output
// carries the sound before its volume and its mute, so the phone still
// gets the audio.

// speakerSource is the name of the capture stream in the PipeWire tools.
const speakerSource = "Flux Speaker"

// SpeakerView is the state of the phone speaker for the window.
type SpeakerView struct {
	Active   bool   `json:"active"`
	To       string `json:"to"`
	ToName   string `json:"toName"`
	Rate     int    `json:"rate"`
	Channels int    `json:"channels"`
	// Mute is true when the phone asks fluxd to mute the output of this
	// computer. Muted is the description of the output that fluxd muted,
	// or "". MuteError tells why fluxd could not mute the output.
	Mute      bool   `json:"mute"`
	Muted     string `json:"muted,omitempty"`
	MuteError string `json:"muteError,omitempty"`
	Error     string `json:"error,omitempty"`
}

type speakerSession struct {
	dev    *Device
	link   streamLink
	cancel context.CancelFunc
	view   SpeakerView
	// notice is the desktop notification that shows while the phone plays
	// the audio of this computer.
	notice uint32
	// muteWake makes the mute loop apply a new mute choice at once.
	muteWake chan struct{}

	// ctx ends with the session. done closes when runSpeaker returns, and
	// prev is done of the session before, or nil.
	ctx        context.Context
	done, prev chan struct{}
}

type speakerStart struct {
	State   string `json:"state"`
	Port    int    `json:"port"`
	Mute    bool   `json:"mute"`
	Message string `json:"message"`
}

// speakerArgs returns the pw-record arguments that capture the monitor of
// the default output as raw stereo, 48 kHz, s16 PCM on stdout.
func speakerArgs() []string {
	props := fmt.Sprintf(`{ stream.capture.sink = true node.description = %q media.name = %q }`, speakerSource, speakerSource)
	return []string{"--raw", "--rate", "48000", "--channels", "2", "--format", "s16", "--latency", "20ms",
		"--properties", props, "-"}
}

const (
	// speakerBacklog is the most audio, in frames of 20 ms, that fluxd
	// keeps for a slow network. Older audio is dropped, so a stall of
	// the network adds no lasting delay.
	speakerBacklog = 5
	// speakerSendBuffer is the socket buffer of the stream, about 80 ms of
	// audio. The kernel doubles it.
	speakerSendBuffer = 16 << 10
	// speakerMuteCheck is the time between 2 checks of the default output
	// while fluxd mutes it. When the user selects another output, fluxd
	// turns the sound of the old one on and mutes the new one.
	speakerMuteCheck = 2 * time.Second
)

func (d *Daemon) handleSpeaker(dev *Device, l streamLink, p *proto.Packet) {
	var b speakerStart
	if p.Decode(&b) != nil {
		return
	}
	switch b.State {
	case "start":
		if s := d.claimSpeaker(dev, l, b); s != nil {
			go d.runSpeaker(s, b)
		}
	case "stop":
		d.endSpeaker(dev.ID)
	case "mute":
		d.setSpeakerMute(dev.ID, b.Mute)
	case "error":
		d.logf("%s: speaker: %s", dev.Name, peerText(b.Message))
	}
}

// claimSpeaker makes a new session the speaker session before any slow
// work, and stops the session that ran before. It returns nil when the
// stream cannot start, and then it tells the phone.
func (d *Daemon) claimSpeaker(dev *Device, l streamLink, b speakerStart) *speakerSession {
	d.mu.Lock()
	var err error
	switch {
	case b.Port <= 0 || b.Port > 65535:
		err = fmt.Errorf("the port %d is not valid", b.Port)
	case d.opts.Headless:
		err = errors.New("the phone speaker is off in headless mode")
	case !dev.Paired:
		err = fmt.Errorf("%s is not paired with %s", dev.Name, d.nameLocked())
	}
	if err != nil {
		d.mu.Unlock()
		d.failSpeaker(nil, dev, l, err)
		return nil
	}
	ctx, cancel := context.WithCancel(d.ctx)
	s := &speakerSession{dev: dev, link: l, cancel: cancel, ctx: ctx, muteWake: make(chan struct{}, 1), view: SpeakerView{
		To: dev.ID, ToName: dev.Name, Rate: 48000, Channels: 2, Mute: b.Mute,
	}}
	s.done, s.prev = d.sessions.speakerTurn.take()
	old := d.speaker
	d.speaker, d.speakerErr = s, ""
	d.mu.Unlock()
	if old != nil {
		old.cancel()
	}
	d.watchSession(ctx, cancel, dev, l, nil)
	d.markDirty()
	return s
}

// failSpeaker tells the phone why the stream stopped, and shows the error
// in the window.
func (d *Daemon) failSpeaker(s *speakerSession, dev *Device, l streamLink, err error) {
	d.logf("%s: speaker: %v", dev.Name, err)
	_ = l.Send(proto.New(proto.TypeFluxSpeaker, map[string]any{"state": "error", "message": err.Error()}))
	d.mu.Lock()
	if d.speaker == nil || d.speaker == s {
		d.speakerErr = err.Error()
	}
	d.mu.Unlock()
	d.markDirty()
}

// runSpeaker runs 1 speaker session until the phone stops, the link drops,
// the capture stops, or the user stops it on this computer.
func (d *Daemon) runSpeaker(s *speakerSession, b speakerStart) {
	dev, l, ctx := s.dev, s.link, s.ctx
	defer endTurn(s.done, s.prev)
	defer d.dropSpeaker(s)
	defer s.cancel()
	fail := func(err error) {
		if ctx.Err() == nil {
			d.failSpeaker(s, dev, l, err)
		}
	}
	// The capture of the session before stops first, and that session
	// turns the sound of the output on again.
	if !waitTurn(ctx, s.prev) {
		return
	}
	path, err := exec.LookPath("pw-record")
	if err != nil {
		fail(errors.New("pw-record is not installed on the computer. Install it with: sudo pacman -S pipewire"))
		return
	}
	tc, err := l.DialPeer(ctx, b.Port)
	if err != nil {
		fail(fmt.Errorf("connect to the phone: %w", err))
		return
	}
	defer tc.Close()
	if c, ok := tc.NetConn().(*net.TCPConn); ok {
		_ = c.SetWriteBuffer(speakerSendBuffer)
	}
	// A stop closes the stream, so that a blocked write ends.
	defer context.AfterFunc(ctx, func() { tc.Close() })()
	d.mu.Lock()
	current := d.speaker == s && dev.Paired
	d.mu.Unlock()
	if !current || ctx.Err() != nil {
		return
	}
	// The phone sends nothing on the stream. A read that ends means that
	// the phone closed it.
	go func() {
		_, _ = io.Copy(io.Discard, tc)
		s.cancel()
	}()

	cmd := childCommand(ctx, path, speakerArgs()...)
	cmd.WaitDelay = time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fail(err)
		return
	}
	var stderr lockedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		fail(fmt.Errorf("start pw-record: %w", err))
		return
	}
	var muting sync.WaitGroup
	defer muting.Wait()
	live := func() {
		_ = l.Send(proto.New(proto.TypeFluxSpeaker, map[string]any{"state": "live", "rate": 48000, "channels": 2}))
		notice := d.notify(desktop.Notification{
			AppName: "Flux", Title: dev.Name + " plays the audio of this computer",
			Body:    "The phone plays what this computer plays.",
			Actions: []desktop.Action{{Key: "speaker-stop", Label: "Stop"}},
		})
		d.mu.Lock()
		s.view.Active = true
		s.notice = notice
		d.mu.Unlock()
		// The session can end during the notification. Its cleanup then did not see it.
		if ctx.Err() != nil && notice != 0 && d.notifier != nil {
			_ = d.notifier.Close(notice)
		}
		d.logf("%s: plays the audio of this computer", dev.Name)
		d.toast("%s plays the audio of this computer", dev.Name)
		d.markDirty()
		muting.Add(1)
		go func() {
			defer muting.Done()
			d.speakerMuteLoop(s)
		}()
	}
	dropped := false
	err = pumpSpeaker(stdout, tc, speakerBacklog, func() { live() }, func() {
		if !dropped {
			dropped = true
			d.logf("%s: speaker: dropped audio after a network stall, to keep the delay short", dev.Name)
		}
	})
	stopped := ctx.Err() != nil
	s.cancel()
	_ = stdout.Close()
	_ = cmd.Wait()
	var closed writeError
	switch {
	case stopped:
		d.logf("%s: speaker stopped", dev.Name)
	case errors.As(err, &closed):
		d.logf("%s: speaker closed: %v", dev.Name, closed.err)
	default:
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = "pw-record exited"
		}
		d.failSpeaker(s, dev, l, fmt.Errorf("the audio capture stopped: %s", lastLine(msg)))
	}
}

// pumpSpeaker reads frames of 20 ms from r and writes them to w as audio
// frames. It keeps at most keep frames that w did not take yet, and drops
// the oldest frame when a new one comes, so that r never waits for the
// network. It calls dropped for each drop, and first once before the first
// frame. It returns the read error of r, or a writeError when w fails.
func pumpSpeaker(r io.Reader, w io.Writer, keep int, first, dropped func()) error {
	frames := make(chan []byte, keep)
	failed := make(chan error, 1)
	go func() {
		fw := frameWriter{w: w}
		for f := range frames {
			if err := fw.write(frameAudio, f); err != nil {
				failed <- writeError{err}
				return
			}
		}
		close(failed)
	}()
	started := false
	for {
		buf := make([]byte, desktopAudioBytes)
		if _, err := io.ReadFull(r, buf); err != nil {
			// The writer can wait for a stalled network, so the pump does
			// not wait for it. The caller closes the stream, and the
			// writer then ends.
			close(frames)
			return err
		}
		if !started {
			started = true
			first()
		}
		select {
		case err := <-failed:
			return err
		default:
		}
		select {
		case frames <- buf:
		default:
			// Only this loop sends, so after it takes the oldest frame the
			// new one fits.
			select {
			case <-frames:
				dropped()
			default:
			}
			frames <- buf
		}
	}
}

// speakerMuteLoop mutes the default output while the phone asks for it,
// and turns its sound on again when the phone no longer asks or the
// session ends. It checks the default output each speakerMuteCheck, so
// that another default output gets muted too.
func (d *Daemon) speakerMuteLoop(s *speakerSession) {
	if d.outputs == nil {
		return
	}
	tick := time.NewTicker(speakerMuteCheck)
	defer tick.Stop()
	for {
		d.mu.Lock()
		want := s.view.Mute
		d.mu.Unlock()
		d.applySpeakerMute(s, want)
		select {
		case <-s.ctx.Done():
			d.restoreSpeakerMute(s)
			return
		case <-s.muteWake:
		case <-tick.C:
		}
	}
}

// applySpeakerMute makes the mute state of the outputs follow want.
func (d *Daemon) applySpeakerMute(s *speakerSession, want bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	muted, err := d.speakerMute.apply(ctx, d.outputs, want, speakerMuteFile())
	d.mu.Lock()
	changed := s.view.Muted != muted || (err == nil) != (s.view.MuteError == "")
	s.view.Muted = muted
	s.view.MuteError = ""
	if err != nil {
		s.view.MuteError = err.Error()
	}
	d.mu.Unlock()
	if !changed {
		return
	}
	body := map[string]any{"state": "muted", "output": muted}
	if err != nil {
		d.logf("%s: speaker: mute the output: %v", s.dev.Name, err)
		body["message"] = "The computer could not mute its output: " + err.Error()
	}
	if s.ctx.Err() == nil {
		_ = s.link.Send(proto.New(proto.TypeFluxSpeaker, body))
	}
	d.markDirty()
}

// restoreSpeakerMute turns the sound of the output on again that fluxd
// muted for the session.
func (d *Daemon) restoreSpeakerMute(s *speakerSession) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := d.speakerMute.restore(ctx, d.outputs, speakerMuteFile()); err != nil {
		d.logf("%s: speaker: turn the sound of the output on again: %v", s.dev.Name, err)
	}
	d.mu.Lock()
	s.view.Muted = ""
	d.mu.Unlock()
}

// setSpeakerMute changes the mute choice of the phone while the stream
// runs.
func (d *Daemon) setSpeakerMute(deviceID string, mute bool) {
	d.mu.Lock()
	s := d.speaker
	if s == nil || s.dev.ID != deviceID {
		d.mu.Unlock()
		return
	}
	s.view.Mute = mute
	d.mu.Unlock()
	select {
	case s.muteWake <- struct{}{}:
	default:
	}
	d.markDirty()
}

// speakerMuteFile is the file that names the output that fluxd muted for
// the phone. After a crash of fluxd, the next start turns the sound of
// that output on again.
func speakerMuteFile() string { return filepath.Join(config.DataDir(), "speaker-muted") }

// outputMute is the output that fluxd muted for the phone speaker. Its own
// lock guards it, because the end of the daemon can restore it while the
// mute loop of a session runs.
type outputMute struct {
	mu sync.Mutex
	// name and description are those of the output that fluxd muted, or
	// "".
	name, description string
}

// apply mutes the default output when want is true, and turns the sound of
// the output that fluxd muted on again when the default output changed or
// want is false. An output that was muted before stays muted at the end.
// It returns the description of the output that fluxd muted, or "".
func (m *outputMute) apply(ctx context.Context, outs audioOutputs, want bool, file string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !want {
		return "", m.restoreLocked(ctx, outs, file)
	}
	def, err := outs.Default(ctx)
	if err != nil {
		return m.description, err
	}
	if def == "" || def == m.name {
		return m.description, nil
	}
	if err := m.restoreLocked(ctx, outs, file); err != nil {
		return m.description, err
	}
	o, err := outs.Find(ctx, def)
	if err != nil {
		return "", err
	}
	if o.Muted {
		// The user muted it. fluxd leaves it as it is at the end too.
		return "", nil
	}
	// The file comes first, so that a crash after the mute still finds it.
	_ = os.MkdirAll(filepath.Dir(file), 0o700)
	if err := os.WriteFile(file, []byte(def+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("save the muted output: %w", err)
	}
	if err := outs.SetMute(ctx, def, true); err != nil {
		_ = os.Remove(file)
		return "", err
	}
	m.name, m.description = def, o.Description
	return o.Description, nil
}

// restore turns the sound of the output on again that fluxd muted.
func (m *outputMute) restore(ctx context.Context, outs audioOutputs, file string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.restoreLocked(ctx, outs, file)
}

func (m *outputMute) restoreLocked(ctx context.Context, outs audioOutputs, file string) error {
	if m.name == "" {
		return nil
	}
	if err := outs.SetMute(ctx, m.name, false); err != nil {
		return err
	}
	m.name, m.description = "", ""
	_ = os.Remove(file)
	return nil
}

// restoreCrashedMute turns the sound of an output on again that fluxd
// muted before a crash. PipeWire can start after fluxd at login, so it
// tries again for a short time.
func (d *Daemon) restoreCrashedMute(ctx context.Context, file string, tries int, gap time.Duration) {
	if d.outputs == nil {
		return
	}
	for i := 0; i < tries; i++ {
		if i > 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(gap):
			}
		}
		done, err := d.restoreMuteFile(ctx, file)
		if done {
			return
		}
		if i == tries-1 {
			d.logf("turn the sound of the output on again that fluxd muted for the phone speaker: %v", err)
		}
	}
}

// restoreMuteFile turns the sound on again of the output in file. It
// returns true when no more work is left: the output has its sound again,
// there is no file, or a new stream of the phone speaker owns the file.
func (d *Daemon) restoreMuteFile(ctx context.Context, file string) (bool, error) {
	m := &d.speakerMute
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.name != "" {
		return true, nil
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return true, nil
	}
	name := strings.TrimSpace(string(data))
	if name != "" {
		if err := d.outputs.SetMute(ctx, name, false); err != nil {
			return false, err
		}
		d.logf("turned the sound of %s on again, which fluxd muted for the phone speaker before it stopped", name)
	}
	_ = os.Remove(file)
	return true, nil
}

// dropSpeaker removes a session that ended and closes its notification.
func (d *Daemon) dropSpeaker(s *speakerSession) {
	d.mu.Lock()
	if d.speaker == s {
		d.speaker = nil
	}
	notice := s.notice
	d.mu.Unlock()
	if notice != 0 && d.notifier != nil {
		_ = d.notifier.Close(notice)
	}
	d.markDirty()
}

// takeSpeaker removes the session from the slot and returns it, or nil.
// An empty ID takes any session. The caller stops the session.
func (d *Daemon) takeSpeaker(deviceID string) *speakerSession {
	d.mu.Lock()
	defer d.mu.Unlock()
	s := d.speaker
	if s == nil || (deviceID != "" && s.dev.ID != deviceID) {
		return nil
	}
	d.speaker = nil
	return s
}

// endSpeaker stops the session, also while fluxd still sets it up. An
// empty ID stops any session.
func (d *Daemon) endSpeaker(deviceID string) {
	if s := d.takeSpeaker(deviceID); s != nil {
		s.cancel()
		d.markDirty()
	}
}

// StopSpeaker stops the phone speaker from this computer and tells the
// phone.
func (d *Daemon) StopSpeaker() error {
	s := d.takeSpeaker("")
	if s == nil {
		return apiErr("not_active", "No phone plays the audio of this computer")
	}
	_ = s.link.Send(proto.New(proto.TypeFluxSpeaker, map[string]any{"state": "stop"}))
	s.cancel()
	d.markDirty()
	return nil
}

// RequestSpeaker asks a device to play the audio of this computer. It
// selects the device as RequestWebcam does. The user of the device must
// tap start before the stream starts.
func (d *Daemon) RequestSpeaker(device string) error {
	_, _, err := d.requestStream("speaker", device)
	return err
}

func (d *Daemon) speakerViewLocked() *SpeakerView {
	if d.speaker != nil {
		v := d.speaker.view
		return &v
	}
	if d.speakerErr != "" {
		return &SpeakerView{Error: d.speakerErr}
	}
	return nil
}

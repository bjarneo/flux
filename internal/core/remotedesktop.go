package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"time"

	"flux/internal/desktop"
	"flux/internal/proto"
)

// The screen of this computer on the phone. The phone opens a TLS listener
// and sends its port in a flux.desktop packet. fluxd connects out to it, as
// for the webcam. gpu-screen-recorder captures 1 monitor as H.264 in FLV,
// and fluxd writes each frame to the phone with its size, see pumpDesktop.
// On a GPU that gpu-screen-recorder does not support, such as one on
// nouveau, wf-recorder captures the monitor and encodes it on the CPU.
// The phone shows the stream and sends its touches as
// flux.mousepad.request packets with a position on the monitor. The
// stream needs remote_desktop, and the touches also need remote_input.

const (
	// desktopRecorder captures the monitor and encodes it on the GPU.
	desktopRecorder = "gpu-screen-recorder"
	// desktopCPURecorder captures the monitor through Hyprland and encodes
	// it on the CPU, for a GPU that desktopRecorder does not support.
	desktopCPURecorder = "wf-recorder"
	// desktopSize is the default longest side of the stream, in pixels.
	// The phone can ask for a size from desktopMinSize to desktopMaxSize.
	desktopSize    = 1920
	desktopMinSize = 640
	desktopMaxSize = 3840
	// desktopSendBuffer is the socket buffer for the stream. A small
	// buffer keeps the delay short on a slow network, because the recorder
	// then waits and skips frames.
	desktopSendBuffer = 256 << 10
)

// DesktopView is the remote desktop state for the window.
type DesktopView struct {
	Audio      bool   `json:"audio"`
	AudioError string `json:"audioError,omitempty"`
	Active     bool   `json:"active"`
	To         string `json:"to"`
	ToName     string `json:"toName"`
	Monitor    string `json:"monitor"`
	Width      int    `json:"width"`
	Height     int    `json:"height"`
	Error      string `json:"error,omitempty"`
}

type desktopSession struct {
	dev    *Device
	link   streamLink
	cancel context.CancelFunc
	view   DesktopView
	// notice is the desktop notification that shows while the phone
	// shows this screen.
	notice uint32

	// ctx ends with the session: at a stop, at a later start, when the
	// switch turns off, or when the device is no longer paired. done
	// closes when runDesktop returns, and prev is done of the session
	// before, or nil.
	ctx        context.Context
	done, prev chan struct{}
}

type desktopStart struct {
	Audio   bool   `json:"audio"`
	State   string `json:"state"`
	Port    int    `json:"port"`
	Monitor string `json:"monitor"`
	MaxSize int    `json:"maxSize"`
	Message string `json:"message"`
}

// monitor is 1 monitor that the recorder can capture, with its size in
// pixels.
type monitor struct {
	Name          string
	Width, Height int
}

// parseMonitors reads the output of gpu-screen-recorder --list-monitors:
// 1 monitor on each line, as "eDP-1|2880x1800".
func parseMonitors(out string) []monitor {
	var ms []monitor
	for line := range strings.Lines(out) {
		name, size, ok := strings.Cut(strings.TrimSpace(line), "|")
		if !ok || name == "" {
			continue
		}
		var w, h int
		if _, err := fmt.Sscanf(size, "%dx%d", &w, &h); err != nil || w <= 0 || h <= 0 {
			continue
		}
		ms = append(ms, monitor{name, w, h})
	}
	return ms
}

// pickMonitor returns the monitor that the phone asks for, else the
// focused monitor, else the first monitor.
func pickMonitor(ms []monitor, asked, focused string) monitor {
	for _, name := range []string{asked, focused} {
		for _, m := range ms {
			if name != "" && m.Name == name {
				return m
			}
		}
	}
	return ms[0]
}

// streamSize returns the size of the stream for a monitor of w × h pixels:
// the same shape, the longest side at most limit, and even sides for the
// encoder.
func streamSize(w, h, limit int) (int, int) {
	scale := min(1, float64(limit)/float64(w), float64(limit)/float64(h))
	even := func(v int) int { return max(2, int(float64(v)*scale)/2*2) }
	return even(w), even(h)
}

// desktopLimit returns the longest side of the stream for the size that
// the phone asks for. Zero selects the default.
func desktopLimit(asked int) int {
	if asked <= 0 {
		return desktopSize
	}
	return max(desktopMinSize, min(desktopMaxSize, asked))
}

// desktopArgs returns the arguments of the recorder for a monitor and a
// stream size. The recorder writes FLV to stdout, 1 tag for each frame. The
// constant quality keeps text sharp, and a still screen then needs almost
// no data.
func desktopArgs(name string, w, h int) []string {
	return []string{
		"-w", name, "-c", "flv", "-k", "h264",
		"-s", fmt.Sprintf("%dx%d", w, h), "-f", "30",
		"-bm", "qp", "-q", "high", "-keyint", "2",
		"-cursor", "yes", "-fallback-cpu-encoding", "yes", "-v", "no",
	}
}

// cpuRecorderArgs returns the arguments of wf-recorder for a monitor and a
// stream size. wf-recorder captures a frame only when the screen changes,
// so a still screen needs almost no CPU. x264 encodes without B-frames
// and with a key frame each 60 frames.
func cpuRecorderArgs(name string, w, h int) []string {
	return []string{
		"-o", name, "-c", "libx264", "-x", "yuv420p", "-m", "flv", "-f", "pipe:1",
		"-F", fmt.Sprintf("scale=%d:%d", w, h),
		"-p", "preset=ultrafast", "-p", "tune=zerolatency", "-p", "crf=23", "-p", "g=60",
	}
}

// recorder is the program that captures a monitor as H.264 in FLV on
// stdout.
type recorder struct {
	name string
	path string
	list func(ctx context.Context) ([]monitor, error)
	args func(name string, w, h int) []string
}

func gpuRecorder(path string) recorder {
	return recorder{desktopRecorder, path,
		func(ctx context.Context) ([]monitor, error) { return listMonitors(ctx, path) }, desktopArgs}
}

func cpuRecorder(path string) recorder {
	return recorder{desktopCPURecorder, path, hyprMonitors, cpuRecorderArgs}
}

// pickRecorder returns gpu-screen-recorder when it runs on this GPU, else
// wf-recorder. gpu-screen-recorder fails to list the monitors on a GPU
// that it does not support, and it lists no monitor when the displays are
// off. Only the failure selects wf-recorder.
func pickRecorder(ctx context.Context, lookPath func(string) (string, error)) (recorder, error) {
	gpu, gpuErr := lookPath(desktopRecorder)
	cpu, cpuErr := lookPath(desktopCPURecorder)
	switch {
	case gpuErr != nil && cpuErr != nil:
		return recorder{}, errors.New("the remote desktop needs gpu-screen-recorder on the computer. Install it with: sudo pacman -S gpu-screen-recorder")
	case gpuErr != nil:
		return cpuRecorder(cpu), nil
	case cpuErr != nil:
		return gpuRecorder(gpu), nil
	}
	var exit *exec.ExitError
	if _, err := listMonitors(ctx, gpu); errors.As(err, &exit) {
		return cpuRecorder(cpu), nil
	}
	return gpuRecorder(gpu), nil
}

// hyprMonitor is 1 monitor in the output of hyprctl monitors -j.
type hyprMonitor struct {
	Name       string `json:"name"`
	Width      int    `json:"width"`
	Height     int    `json:"height"`
	Transform  int    `json:"transform"`
	DPMSStatus bool   `json:"dpmsStatus"`
	Disabled   bool   `json:"disabled"`
}

// parseHyprMonitors returns the monitors in the output of hyprctl
// monitors -j that show an image, with their size in pixels as the
// capture has it. A rotated monitor swaps its width and height.
func parseHyprMonitors(out []byte) ([]monitor, error) {
	var hms []hyprMonitor
	if err := json.Unmarshal(out, &hms); err != nil {
		return nil, fmt.Errorf("read the Hyprland monitors: %w", err)
	}
	var ms []monitor
	for _, hm := range hms {
		if hm.Disabled || !hm.DPMSStatus || hm.Name == "" || hm.Width <= 0 || hm.Height <= 0 {
			continue
		}
		w, h := hm.Width, hm.Height
		if hm.Transform%2 == 1 {
			w, h = h, w
		}
		ms = append(ms, monitor{hm.Name, w, h})
	}
	return ms, nil
}

// hyprMonitors returns the monitors that wf-recorder can capture.
func hyprMonitors(ctx context.Context) ([]monitor, error) {
	out, err := hyprctl(ctx, "monitors", "-j")
	if err != nil {
		return nil, fmt.Errorf("list the monitors: %w", err)
	}
	ms, err := parseHyprMonitors(out)
	if err != nil {
		return nil, err
	}
	if len(ms) == 0 {
		return nil, errors.New("no monitor of Hyprland shows an image to capture")
	}
	return ms, nil
}

// listMonitors returns the monitors that the recorder can capture.
func listMonitors(ctx context.Context, path string) ([]monitor, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, path, "--list-monitors").Output()
	ms := parseMonitors(string(out))
	if len(ms) == 0 {
		if err != nil {
			return nil, fmt.Errorf("list the monitors: %w", err)
		}
		return nil, errors.New("gpu-screen-recorder finds no monitor to capture")
	}
	return ms, nil
}

// desktopWakeWait is the longest time that fluxd waits for the displays to
// turn on, and desktopWakePoll is the time between 2 lists.
var (
	desktopWakeWait = 3 * time.Second
	desktopWakePoll = 200 * time.Millisecond
)

// wakeMonitors returns the monitors from list. A display that is off has no
// image, so the recorder lists no monitor for it. The Omarchy lock screen
// turns the displays off 5 seconds after the last key or pointer move. When
// list finds no monitor, wakeMonitors turns the displays on with wake and
// lists them again until desktopWakeWait ends. A recorder that runs
// continues when the lock screen turns the displays off again.
func wakeMonitors(ctx context.Context, list func() ([]monitor, error), wake func() error) ([]monitor, error) {
	ms, err := list()
	if err == nil || wake() != nil {
		return ms, err
	}
	deadline := time.Now().Add(desktopWakeWait)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(desktopWakePoll):
		}
		if ms, err = list(); err == nil {
			return ms, nil
		}
	}
	return nil, err
}

// wakeDisplays turns on each display that is off. A Hyprland with a Lua
// configuration takes a Lua dispatcher. An older Hyprland takes "dpms on".
func wakeDisplays(ctx context.Context) error {
	if _, err := hyprctl(ctx, "dispatch", `hl.dsp.dpms({ action = "enable" })`); err == nil {
		return nil
	}
	_, err := hyprctl(ctx, "dispatch", "dpms", "on")
	return err
}

// focusedMonitor returns the monitor with the focus in Hyprland, or an
// empty string when hyprctl does not answer.
func focusedMonitor(ctx context.Context) string {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "hyprctl", "monitors", "-j").Output()
	if err != nil {
		return ""
	}
	var ms []struct {
		Name    string `json:"name"`
		Focused bool   `json:"focused"`
	}
	if json.Unmarshal(out, &ms) != nil {
		return ""
	}
	for _, m := range ms {
		if m.Focused {
			return m.Name
		}
	}
	return ""
}

// recorderError returns the line of the recorder output that tells why it
// stopped: the last error line, else the last line.
func recorderError(name, out string) string {
	if strings.TrimSpace(out) == "" {
		return name + " exited"
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if strings.Contains(strings.ToLower(lines[i]), "error") {
			return strings.TrimSpace(lines[i])
		}
	}
	return strings.TrimSpace(lines[len(lines)-1])
}

func (d *Daemon) handleDesktop(dev *Device, l streamLink, p *proto.Packet) {
	var b desktopStart
	if p.Decode(&b) != nil {
		return
	}
	switch b.State {
	case "start":
		if s := d.claimDesktop(dev, l); s != nil {
			go d.runDesktop(s, b)
		}
	case "stop":
		d.endDesktop(dev.ID)
	case "error":
		d.logf("%s: remote desktop: %s", dev.Name, peerText(b.Message))
	}
}

// desktopRefusal returns why the device cannot see this screen now, or
// nil. d.mu must be held.
func (d *Daemon) desktopRefusal(dev *Device) error {
	switch {
	case d.opts.Headless:
		return errors.New("the remote desktop is off in headless mode")
	case !d.cfg.RemoteDesktop || !d.permittedLocked(dev.ID, "remoteDesktop"):
		return fmt.Errorf("the remote desktop is off on %s. Turn it on in the Flux window, or run: flux-cli desktop on", d.nameLocked())
	case !dev.Paired:
		return fmt.Errorf("%s is not paired with %s", dev.Name, d.nameLocked())
	}
	return nil
}

// failDesktop tells the phone why the remote desktop did not start, and
// shows the error in the window.
func (d *Daemon) failDesktop(s *desktopSession, dev *Device, l streamLink, err error) {
	d.logf("%s: remote desktop: %v", dev.Name, err)
	_ = l.Send(proto.New(proto.TypeFluxDesktop, map[string]any{"state": "error", "message": err.Error()}))
	d.mu.Lock()
	if d.desktop == nil || d.desktop == s {
		d.desktopErr = err.Error()
	}
	d.mu.Unlock()
	d.markDirty()
}

// claimDesktop makes a new session the remote desktop session before any
// slow work, and stops the session that ran before. It returns nil when
// the device cannot see this screen, and then it tells the phone.
func (d *Daemon) claimDesktop(dev *Device, l streamLink) *desktopSession {
	d.mu.Lock()
	if err := d.desktopRefusal(dev); err != nil {
		d.mu.Unlock()
		d.failDesktop(nil, dev, l, err)
		return nil
	}
	ctx, cancel := context.WithCancel(d.ctx)
	s := &desktopSession{dev: dev, link: l, cancel: cancel, ctx: ctx, view: DesktopView{To: dev.ID, ToName: dev.Name}}
	s.done, s.prev = d.sessions.desktopTurn.take()
	old := d.desktop
	d.desktop, d.desktopErr = s, ""
	d.mu.Unlock()
	if old != nil {
		old.cancel()
	}
	d.watchSession(ctx, cancel, dev, l, func() bool { return d.cfg.RemoteDesktop && d.permittedLocked(dev.ID, "remoteDesktop") })
	d.markDirty()
	return s
}

// runDesktop runs 1 remote desktop session until the phone stops, the link
// drops, the recorder stops, or the user stops it on this computer.
func (d *Daemon) runDesktop(s *desktopSession, b desktopStart) {
	dev, l, ctx := s.dev, s.link, s.ctx
	defer endTurn(s.done, s.prev)
	defer d.dropDesktop(s)
	defer s.cancel()
	// A stop, the switch, or a later start ends the setup without an error.
	fail := func(err error) {
		if ctx.Err() == nil {
			d.failDesktop(s, dev, l, err)
		}
	}
	// The recorder of the session before stops first.
	if !waitTurn(ctx, s.prev) {
		return
	}
	rec, err := pickRecorder(ctx, exec.LookPath)
	if err != nil {
		fail(err)
		return
	}
	ms, err := wakeMonitors(ctx,
		func() ([]monitor, error) { return rec.list(ctx) },
		func() error { return wakeDisplays(ctx) })
	if err != nil {
		fail(err)
		return
	}
	mon := pickMonitor(ms, b.Monitor, focusedMonitor(ctx))
	w, h := streamSize(mon.Width, mon.Height, desktopLimit(b.MaxSize))
	d.mu.Lock()
	s.view.Monitor, s.view.Width, s.view.Height = mon.Name, w, h
	d.mu.Unlock()

	tc, err := l.DialPeer(ctx, b.Port)
	if err != nil {
		fail(fmt.Errorf("connect to the phone: %w", err))
		return
	}
	defer tc.Close()
	if c, ok := tc.NetConn().(*net.TCPConn); ok {
		_ = c.SetWriteBuffer(desktopSendBuffer)
	}
	// A stop closes the stream, so that a blocked write ends.
	defer context.AfterFunc(ctx, func() { tc.Close() })()

	// The switch or the pairing can change while fluxd dials the phone.
	d.mu.Lock()
	err = d.desktopRefusal(dev)
	current := d.desktop == s
	d.mu.Unlock()
	if !current || ctx.Err() != nil {
		return
	}
	if err != nil {
		fail(err)
		return
	}
	// The phone sends nothing on the stream. A read that ends means that
	// the phone closed it, also when the screen does not change and the
	// recorder writes no frame.
	go func() {
		_, _ = io.Copy(io.Discard, tc)
		s.cancel()
	}()

	cmd := childCommand(ctx, rec.path, rec.args(mon.Name, w, h)...)
	// The recorder stops cleanly on SIGINT.
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 3 * time.Second
	// The recorder opens /dev/stdout by its path, so stdout must be a pipe,
	// not the socket.
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		fail(err)
		return
	}
	var stderr lockedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		fail(fmt.Errorf("start %s: %w", rec.name, err))
		return
	}
	live := func() {
		if ctx.Err() != nil {
			return
		}
		names := make([]string, 0, len(ms))
		for _, m := range ms {
			names = append(names, m.Name)
		}
		_ = l.Send(proto.New(proto.TypeFluxDesktop, map[string]any{
			"state": "live", "monitor": mon.Name, "monitors": names, "width": w, "height": h,
			"audio": b.Audio,
		}))
		if b.Audio {
			go d.runDesktopAudio(ctx, s, tc)
		}
		notice := d.notify(desktop.Notification{
			AppName: "Flux", Title: dev.Name + " shows this screen",
			Body:    "The phone sees " + mon.Name + ".",
			Actions: []desktop.Action{{Key: "desktop-stop", Label: "Stop"}},
		})
		d.mu.Lock()
		s.view.Active = true
		s.notice = notice
		d.mu.Unlock()
		// The session can end during the notification. Its cleanup then did not see it.
		if ctx.Err() != nil && notice != 0 && d.notifier != nil {
			_ = d.notifier.Close(notice)
		}
		d.logf("%s: remote desktop of %s at %dx%d with %s", dev.Name, mon.Name, w, h, rec.name)
		d.markDirty()
	}
	err = pumpDesktop(stdout, tc, w, h, func() { go live() })
	stopped := ctx.Err() != nil
	// The recorder gets SIGINT, and EPIPE on its next write.
	s.cancel()
	_ = stdout.Close()
	_ = cmd.Wait()
	var closed writeError
	switch {
	case stopped:
		d.logf("%s: remote desktop stopped", dev.Name)
	case errors.As(err, &closed):
		d.logf("%s: remote desktop closed: %v", dev.Name, closed.err)
	case errors.Is(err, io.EOF):
		d.failDesktop(s, dev, l, fmt.Errorf("the screen capture stopped: %s", recorderError(rec.name, stderr.String())))
	default:
		d.failDesktop(s, dev, l, fmt.Errorf("the screen capture failed: %w", err))
	}
}

// dropDesktop removes a session that ended and closes its notification.
func (d *Daemon) dropDesktop(s *desktopSession) {
	d.mu.Lock()
	if d.desktop == s {
		d.desktop = nil
	}
	notice := s.notice
	d.mu.Unlock()
	if notice != 0 && d.notifier != nil {
		_ = d.notifier.Close(notice)
	}
	d.markDirty()
}

// takeDesktop removes the session from the slot and returns it, or nil.
// An empty ID takes any session. The caller stops the session.
func (d *Daemon) takeDesktop(deviceID string) *desktopSession {
	d.mu.Lock()
	defer d.mu.Unlock()
	s := d.desktop
	if s == nil || (deviceID != "" && s.dev.ID != deviceID) {
		return nil
	}
	d.desktop = nil
	return s
}

// endDesktop stops the session, also while fluxd still sets it up. An
// empty ID stops any session.
func (d *Daemon) endDesktop(deviceID string) {
	if s := d.takeDesktop(deviceID); s != nil {
		s.cancel()
		d.markDirty()
	}
}

// StopDesktop stops the remote desktop from this computer and tells the
// phone. It also stops a session that fluxd still sets up.
func (d *Daemon) StopDesktop() error {
	s := d.takeDesktop("")
	if s == nil {
		return apiErr("not_active", "No phone shows this screen")
	}
	_ = s.link.Send(proto.New(proto.TypeFluxDesktop, map[string]any{"state": "stop"}))
	s.cancel()
	d.markDirty()
	return nil
}

func (d *Daemon) desktopViewLocked() *DesktopView {
	if d.desktop != nil {
		v := d.desktop.view
		return &v
	}
	if d.desktopErr != "" {
		return &DesktopView{Error: d.desktopErr}
	}
	return nil
}

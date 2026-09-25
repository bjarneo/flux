package core

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// The phone screen in a window. The phone streams its screen as raw H.264,
// and mpv, or else ffplay, shows it. The window only shows the screen. It
// sends no input to the phone. Closing the window stops the stream.

// screenAppID is the Wayland app id of the mirror window, for window rules.
const screenAppID = "flux-screen"

// ScreenView is the screen mirror state for the window.
type ScreenView struct {
	Active   bool   `json:"active"`
	From     string `json:"from"`
	FromName string `json:"fromName"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
	Player   string `json:"player"`
	Error    string `json:"error,omitempty"`
}

type screenSession struct {
	dev    *Device
	link   *lan.Link
	cancel context.CancelFunc
	view   ScreenView
}

type screenStart struct {
	State   string `json:"state"`
	Port    int    `json:"port"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
	Codec   string `json:"codec"`
	Message string `json:"message"`
}

// screenPlayer is the command that shows the stream: the program, its
// arguments, and extra environment variables.
type screenPlayer struct {
	Name string
	Path string
	Args []string
	Env  []string
}

// findScreenPlayer returns mpv, or ffplay when mpv is not installed. Both
// read raw H.264 from stdin with the lowest delay that they offer.
func findScreenPlayer(lookPath func(string) (string, error), title string) (screenPlayer, error) {
	if path, err := lookPath("mpv"); err == nil {
		return screenPlayer{Name: "mpv", Path: path, Args: []string{
			// The user mpv.conf can keep the window open at the end of the
			// stream or add scripts, so it is not read.
			"--no-config", "--really-quiet",
			"--profile=low-latency", "--untimed", "--no-cache",
			"--demuxer-lavf-format=h264", "--demuxer-lavf-probesize=32", "--demuxer-lavf-analyzeduration=0.1",
			"--hwdec=auto-safe", "--force-window=immediate", "--keep-open=no", "--osc=no", "--audio=no",
			"--autofit-larger=90%x85%",
			"--title=" + title, "--wayland-app-id=" + screenAppID,
			"-",
		}}, nil
	}
	if path, err := lookPath("ffplay"); err == nil {
		return screenPlayer{Name: "ffplay", Path: path, Args: []string{
			"-hide_banner", "-loglevel", "error",
			"-window_title", title,
			"-flags", "low_delay", "-framedrop", "-probesize", "32", "-analyzeduration", "0",
			"-f", "h264", "-framerate", "30", "-i", "pipe:0",
		}, Env: []string{
			// SDL takes the Wayland app id from these variables.
			"SDL_VIDEO_WAYLAND_WMCLASS=" + screenAppID, "SDL_APP_ID=" + screenAppID,
		}}, nil
	}
	return screenPlayer{}, errors.New("the screen mirror needs mpv or ffplay on the computer. Install one with: sudo pacman -S mpv")
}

func screenTitle(name string) string { return "Flux · " + name + " screen" }

func (d *Daemon) handleScreen(dev *Device, l *lan.Link, p *proto.Packet) {
	var b screenStart
	if p.Decode(&b) != nil {
		return
	}
	switch b.State {
	case "start":
		go d.runScreen(dev, l, b)
	case "stop":
		d.endScreen(dev.ID)
	case "error":
		d.logf("%s: screen mirror: %s", dev.Name, b.Message)
	}
}

// runScreen runs 1 mirror session until the phone stops, the link drops,
// the user closes the window, or the user stops it on this computer.
func (d *Daemon) runScreen(dev *Device, l *lan.Link, b screenStart) {
	fail := func(err error) {
		d.logf("%s: screen mirror: %v", dev.Name, err)
		_ = l.Send(proto.New(proto.TypeFluxScreen, map[string]any{"state": "error", "message": err.Error()}))
		d.mu.Lock()
		d.screenErr = err.Error()
		d.mu.Unlock()
		d.markDirty()
	}
	switch {
	case b.Codec != "" && b.Codec != "h264":
		fail(fmt.Errorf("the codec %q is not supported. Send h264", b.Codec))
		return
	case b.Port <= 0 || b.Port > 65535:
		fail(fmt.Errorf("the port %d is not valid", b.Port))
		return
	case d.opts.Headless:
		fail(errors.New("the screen mirror is off in headless mode"))
		return
	}
	player, err := findScreenPlayer(exec.LookPath, screenTitle(dev.Name))
	if err != nil {
		fail(err)
		return
	}
	d.endScreen("")
	ctx, cancel := context.WithCancel(d.ctx)
	defer cancel()
	tc, err := l.DialPeer(ctx, b.Port)
	if err != nil {
		fail(fmt.Errorf("connect to the phone screen: %w", err))
		return
	}
	defer tc.Close()
	s := &screenSession{dev: dev, link: l, cancel: cancel, view: ScreenView{
		From: dev.ID, FromName: dev.Name, Width: b.Width, Height: b.Height, Player: player.Name,
	}}
	d.mu.Lock()
	d.screen, d.screenErr = s, ""
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		if d.screen == s {
			d.screen = nil
		}
		d.mu.Unlock()
		d.markDirty()
	}()
	cancelOnLinkDown(ctx, l, cancel)

	cmd := childCommand(ctx, player.Path, player.Args...)
	cmd.Stdin = tc
	cmd.Env = append(os.Environ(), player.Env...)
	var stderr lockedBuffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		fail(fmt.Errorf("start %s: %w", player.Name, err))
		return
	}
	go func() {
		select {
		case <-time.After(time.Second):
		case <-ctx.Done():
			return
		}
		d.mu.Lock()
		s.view.Active = true
		d.mu.Unlock()
		_ = l.Send(proto.New(proto.TypeFluxScreen, map[string]any{"state": "live", "player": player.Name}))
		d.markDirty()
	}()
	started := time.Now()
	err = cmd.Wait()
	if ctx.Err() != nil {
		d.logf("%s: screen mirror stopped", dev.Name)
		return
	}
	// The player ended by itself. A quick exit with an error is a problem,
	// for example no display. Otherwise the user closed the window, and the
	// phone stops its stream.
	if err != nil && time.Since(started) < 3*time.Second {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		fail(fmt.Errorf("%s stopped: %s", player.Name, lastLine(msg)))
		return
	}
	_ = l.Send(proto.New(proto.TypeFluxScreen, map[string]any{"state": "stop"}))
	d.logf("%s: screen mirror window closed", dev.Name)
}

// endScreen stops the session. An empty ID stops any session.
func (d *Daemon) endScreen(deviceID string) {
	d.mu.Lock()
	s := d.screen
	d.mu.Unlock()
	if s != nil && (deviceID == "" || s.dev.ID == deviceID) {
		s.cancel()
	}
}

// StopScreen stops the screen mirror from this computer and tells the phone.
func (d *Daemon) StopScreen() error {
	d.mu.Lock()
	s := d.screen
	d.mu.Unlock()
	if s == nil {
		return apiErr("not_active", "No phone screen is mirrored")
	}
	_ = s.link.Send(proto.New(proto.TypeFluxScreen, map[string]any{"state": "stop"}))
	s.cancel()
	return nil
}

func (d *Daemon) screenViewLocked() *ScreenView {
	if d.screen != nil {
		v := d.screen.view
		return &v
	}
	if d.screenErr != "" {
		return &ScreenView{Error: d.screenErr}
	}
	return nil
}

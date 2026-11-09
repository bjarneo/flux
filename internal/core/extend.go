package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// The extended screen: the phone or the tablet becomes a second monitor of
// this computer. The phone sends a flux.desktop start with "extend": true
// and the size of its screen. fluxd adds a virtual monitor of that size to
// Hyprland, streams it as the remote desktop streams a real monitor, and
// removes it when the session ends.
//
// gpu-screen-recorder captures the monitors through KMS, and a virtual
// monitor has no KMS plane. wf-recorder captures it through the screencopy
// protocol of Hyprland, so the extended screen always uses wf-recorder.

const (
	// extendOutput is the name of the virtual monitor. Hyprland gives a
	// monitor that comes back with the same name its workspaces again, so
	// each session uses the same name.
	extendOutput = "FLUX-1"
	// extendRate is the refresh rate of the virtual monitor. Hyprland draws
	// it at most this often, so the CPU encoder gets at most 30 frames
	// each second, as from gpu-screen-recorder.
	extendRate = 30
	// extendMinSide is the shortest side of the virtual monitor that
	// fluxd accepts, in pixels.
	extendMinSide = 240
)

// extendRestartGap is the shortest time between 2 starts of the recorder
// in 1 session. A recorder that stops again faster is an error. Tests
// make it shorter.
var extendRestartGap = 5 * time.Second

// extendScales are the scales that fluxd gives the virtual monitor.
var extendScales = []float64{1, 1.25, 1.5, 1.6, 1.75, 2}

// errNoExtendRecorder tells the user to install wf-recorder.
var errNoExtendRecorder = errors.New("the extended screen needs wf-recorder on the computer. Install it with: sudo pacman -S wf-recorder")

// extendWait is the longest time that fluxd waits for the virtual monitor
// to show its mode, and extendPoll is the time between 2 checks.
var (
	extendWait = 3 * time.Second
	extendPoll = 100 * time.Millisecond
)

// extendRecorder returns wf-recorder, the recorder of the virtual monitor.
func extendRecorder(lookPath func(string) (string, error)) (recorder, error) {
	path, err := lookPath(desktopCPURecorder)
	if err != nil {
		return recorder{}, errNoExtendRecorder
	}
	return cpuRecorder(path), nil
}

// extendSize returns the size of the virtual monitor for a phone screen of
// w × h pixels: the same shape, the longest side at most limit, and even
// sides for the encoder. The stream then has the size of the monitor.
func extendSize(w, h, limit int) (int, int, error) {
	if w < extendMinSide || h < extendMinSide || w > 2*desktopMaxSize || h > 2*desktopMaxSize {
		return 0, 0, fmt.Errorf("the phone asked for a screen of %dx%d pixels, which fluxd cannot add", w, h)
	}
	w, h = streamSize(w, h, limit)
	return w, h, nil
}

// cleanScale reports whether Hyprland takes the scale for a monitor of
// w × h pixels without a correction: the logical size must have whole
// pixels. Hyprland shows a warning for another scale.
func cleanScale(w, h int, scale float64) bool {
	lw, lh := float64(w)/scale, float64(h)/scale
	return lw == math.Round(lw) && lh == math.Round(lh)
}

// extendScale returns the scale of the virtual monitor for a phone with the
// Android density, such as 2.625. Text on the monitor then has about the
// size of text in Android apps. The scale is from 1 to 2, so a phone keeps
// room for windows, and Hyprland takes it without a correction. Scale 1
// and 2 are clean for each even size. Of 2 scales at the same distance,
// the smaller one wins, because it gives more room.
func extendScale(w, h int, density float64) float64 {
	want := 1.0
	if density > 0 && !math.IsInf(density, 0) {
		want = max(1, min(2, density))
	}
	best := 1.0
	for _, s := range extendScales {
		if cleanScale(w, h, s) && math.Abs(s-want) < math.Abs(best-want) {
			best = s
		}
	}
	return best
}

// formatScale writes a scale with the fewest digits that read back as the
// same number, such as 1.6.
func formatScale(scale float64) string {
	return strconv.FormatFloat(scale, 'f', -1, 64)
}

// extendRule returns the Lua code that sets the mode, the place, and the
// scale of the virtual monitor. The monitor goes at the right of the other
// monitors.
func extendRule(name string, w, h int, scale float64) string {
	return fmt.Sprintf(`hl.monitor({ output = %q, mode = "%dx%d@%d", position = "auto-right", scale = %s })`,
		name, w, h, extendRate, formatScale(scale))
}

// extendKeyword returns the same rule as extendRule for the hyprctl keyword
// monitor of a Hyprland without a Lua configuration.
func extendKeyword(name string, w, h int, scale float64) string {
	return fmt.Sprintf("%s,%dx%d@%d,auto-right,%s", name, w, h, extendRate, formatScale(scale))
}

// hyprOK runs hyprctl and returns an error unless Hyprland answers "ok".
// hyprctl exits with 0 also for some refusals, such as "unknown request".
func hyprOK(ctx context.Context, args ...string) error {
	out, err := hyprctl(ctx, args...)
	if err != nil {
		return err
	}
	if msg := strings.TrimSpace(string(out)); msg != "ok" {
		return fmt.Errorf("hyprland: %s", msg)
	}
	return nil
}

// applyExtendRule sets the mode of the virtual monitor. A Hyprland with a
// Lua configuration takes the rule through hyprctl eval. An older Hyprland
// takes hyprctl keyword monitor. A monitor that exists changes at once.
func applyExtendRule(ctx context.Context, w, h int, scale float64) error {
	luaErr := hyprOK(ctx, "eval", extendRule(extendOutput, w, h, scale))
	if luaErr == nil {
		return nil
	}
	if hyprOK(ctx, "keyword", "monitor", extendKeyword(extendOutput, w, h, scale)) == nil {
		return nil
	}
	return fmt.Errorf("set the mode of the monitor %s: %w", extendOutput, luaErr)
}

// extendShown reports whether the output of hyprctl monitors -j has the
// virtual monitor with the size w × h. A display that is off still counts.
func extendShown(out []byte, w, h int) (bool, error) {
	var hms []hyprMonitor
	if err := json.Unmarshal(out, &hms); err != nil {
		return false, fmt.Errorf("read the Hyprland monitors: %w", err)
	}
	for _, m := range hms {
		if m.Name == extendOutput {
			return m.Width == w && m.Height == h, nil
		}
	}
	return false, nil
}

// waitExtendOutput waits until Hyprland shows the virtual monitor with the
// size w × h.
func waitExtendOutput(ctx context.Context, w, h int) error {
	deadline := time.Now().Add(extendWait)
	for {
		out, err := hyprctl(ctx, "monitors", "-j")
		if err != nil {
			return fmt.Errorf("list the monitors: %w", err)
		}
		if ok, err := extendShown(out, w, h); err != nil || ok {
			return err
		}
		if !time.Now().Before(deadline) {
			return fmt.Errorf("Hyprland shows no monitor %s of %dx%d pixels", extendOutput, w, h)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(extendPoll):
		}
	}
}

// addExtendOutput adds the virtual monitor to Hyprland with the size
// w × h. It sets the rule first, so that the monitor starts with its mode.
// A monitor that an earlier fluxd left gets the mode, and the session uses
// it.
func (d *Daemon) addExtendOutput(ctx context.Context, w, h int, scale float64) error {
	if _, err := exec.LookPath("hyprctl"); err != nil {
		return errors.New("the extended screen needs Hyprland, and hyprctl is not installed")
	}
	if err := applyExtendRule(ctx, w, h, scale); err != nil {
		return err
	}
	// fluxd removes the monitor at its stop also when the add fails
	// after Hyprland added it.
	d.mu.Lock()
	d.extended = true
	d.mu.Unlock()
	out, err := hyprctl(ctx, "output", "create", "headless", extendOutput)
	if err != nil {
		return fmt.Errorf("add the monitor %s: %w", extendOutput, err)
	}
	if err := waitExtendOutput(ctx, w, h); err != nil {
		if msg := strings.TrimSpace(string(out)); msg != "ok" {
			return fmt.Errorf("add the monitor %s: hyprland: %s", extendOutput, msg)
		}
		return err
	}
	return nil
}

// removeExtendOutput removes the virtual monitor that addExtendOutput
// added. Hyprland moves its windows to another monitor. The session and
// the stop of fluxd both call it, and only the first call removes the
// monitor.
func (d *Daemon) removeExtendOutput() {
	d.mu.Lock()
	added := d.extended
	d.extended = false
	d.mu.Unlock()
	if !added {
		return
	}
	// The context of the session has ended, so the removal has its own.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := hyprOK(ctx, "output", "remove", extendOutput); err != nil {
		d.logf("remove the monitor %s: %v", extendOutput, err)
	}
}

// removeLeftoverOutput removes a virtual monitor that a fluxd left when it
// stopped without its cleanup, for example after a crash.
func (d *Daemon) removeLeftoverOutput(ctx context.Context) {
	if _, err := exec.LookPath("hyprctl"); err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	out, err := hyprctl(ctx, "monitors", "all", "-j")
	if err != nil {
		return
	}
	var hms []hyprMonitor
	if json.Unmarshal(out, &hms) != nil {
		return
	}
	for _, m := range hms {
		if m.Name != extendOutput {
			continue
		}
		if err := hyprOK(ctx, "output", "remove", extendOutput); err != nil {
			d.logf("remove the monitor %s that an earlier fluxd left: %v", extendOutput, err)
		} else {
			d.logf("removed the monitor %s that an earlier fluxd left", extendOutput)
		}
		return
	}
}

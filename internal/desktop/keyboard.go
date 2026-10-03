package desktop

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"
)

// errNoWtype is the error when wtype is missing.
var errNoWtype = errors.New("wtype is not installed on the computer. Install it with: sudo pacman -S wtype")

// Keyboard types text and presses keys with wtype, which speaks the
// zwp_virtual_keyboard_v1 Wayland protocol. wtype sends each character
// as its own key symbol, so the text does not depend on the keyboard
// layout of the desktop.
type Keyboard struct{}

// Modifiers that wtype accepts, as Keyboard takes them.
var wtypeMods = map[string]bool{"shift": true, "ctrl": true, "alt": true, "logo": true}

// Type types text while it holds the modifiers mods, such as "ctrl". It
// stops when ctx ends.
func (Keyboard) Type(ctx context.Context, text string, mods []string) error {
	if text == "" {
		return nil
	}
	// wtype reads the text from stdin, so the text is not in the process list.
	return runWtype(ctx, withMods(mods, "-"), text, utf8.RuneCountInString(text))
}

// Key presses and releases the key with the XKB name, such as "Return",
// times times, while it holds the modifiers mods. It stops when ctx ends.
func (Keyboard) Key(ctx context.Context, name string, mods []string, times int) error {
	var keys []string
	for range max(1, times) {
		keys = append(keys, "-k", name)
	}
	return runWtype(ctx, withMods(mods, keys...), "", max(1, times))
}

// withMods returns the wtype arguments that press mods, run args, and then
// release mods in the reverse order. Hyprland 0.56 keeps a modifier down
// after wtype exits, so a modifier that wtype does not release changes
// each later key into a shortcut.
func withMods(mods []string, args ...string) []string {
	var press, release []string
	for _, m := range mods {
		if wtypeMods[m] {
			press = append(press, "-M", m)
			release = append([]string{"-m", m}, release...)
		}
	}
	return append(append(press, args...), release...)
}

// wtypeTimeout returns the longest time that wtype can take for a text of
// n characters, or for n key presses. wtype waits about 4 ms for each character. A compositor
// that does not answer then does not stop the next keys.
func wtypeTimeout(n int) time.Duration {
	return 5*time.Second + time.Duration(n)*5*time.Millisecond
}

// runWtype runs wtype with the args and the text on stdin. n is the number
// of characters or key presses, for the timeout.
func runWtype(ctx context.Context, args []string, stdin string, n int) error {
	timeout := wtypeTimeout(n)
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "wtype", args...)
	// The kernel stops wtype when fluxd exits.
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	cmd.Stdin = strings.NewReader(stdin)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return errNoWtype
		}
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("wtype did not finish in %s", timeout)
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return fmt.Errorf("wtype: %s", msg)
		}
		return fmt.Errorf("wtype: %w", err)
	}
	return nil
}

// Input is the pointer and the keyboard of the desktop.
type Input struct {
	*Pointer
	Keyboard

	// monitor positions the pointer on 1 monitor for MoveTo. The
	// compositor maps its absolute motion to that monitor.
	mu      sync.Mutex
	monitor *Pointer
}

// NewInput returns the input of the desktop.
func NewInput() *Input { return &Input{Pointer: NewPointer()} }

// MoveTo moves the pointer to x and y on the monitor with the name, such as
// "eDP-1". The values go from 0 at the top left corner to 1 at the bottom
// right corner.
func (in *Input) MoveTo(monitor string, x, y float64) error {
	in.mu.Lock()
	if in.monitor == nil || in.monitor.output != monitor {
		if in.monitor != nil {
			in.monitor.Close()
		}
		in.monitor = NewMonitorPointer(monitor)
	}
	p := in.monitor
	in.mu.Unlock()
	return p.MoveTo(x, y)
}

// Close removes the virtual pointers.
func (in *Input) Close() {
	in.Pointer.Close()
	in.mu.Lock()
	defer in.mu.Unlock()
	if in.monitor != nil {
		in.monitor.Close()
		in.monitor = nil
	}
}

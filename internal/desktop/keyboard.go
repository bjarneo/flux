package desktop

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	"strings"
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

// Type types text while it holds the modifiers mods, such as "ctrl".
func (Keyboard) Type(text string, mods []string) error {
	if text == "" {
		return nil
	}
	// wtype reads the text from stdin, so the text is not in the process list.
	return runWtype(append(modArgs(mods), "-"), text)
}

// Key presses and releases the key with the XKB name, such as "Return",
// while it holds the modifiers mods.
func (Keyboard) Key(name string, mods []string) error {
	return runWtype(append(modArgs(mods), "-k", name), "")
}

// modArgs returns the wtype arguments that press mods. wtype releases the
// modifiers when it exits.
func modArgs(mods []string) []string {
	var args []string
	for _, m := range mods {
		if wtypeMods[m] {
			args = append(args, "-M", m)
		}
	}
	return args
}

func runWtype(args []string, stdin string) error {
	cmd := exec.Command("wtype", args...)
	cmd.Stdin = strings.NewReader(stdin)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return errNoWtype
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
}

// NewInput returns the input of the desktop.
func NewInput() *Input { return &Input{Pointer: NewPointer()} }

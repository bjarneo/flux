package desktop

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
	"time"
)

// Literal text through a zwp_virtual_keyboard_v1 of fluxd. wtype 0.4 puts
// the first character of each text on key code 1, the Escape key. fluxd
// runs 1 wtype for each change of the phone keyboard, so each character
// was on Escape, and the address bar of Chromium dropped each space. fluxd
// now puts each character on a key of the printable part of a PC
// keyboard, as wtype 0.5 does, and Return and Tab on their own keys. The
// keymap of the virtual keyboard gives each key its character, so the
// text does not depend on the keyboard layout of the desktop.

const (
	keyboardManager = "zwp_virtual_keyboard_manager_v1"
	seatInterface   = "wl_seat"
)

// Opcodes of the requests of the virtual keyboard.
const (
	vkmCreate = 0 // zwp_virtual_keyboard_manager_v1.create_virtual_keyboard
	vkKeymap  = 0 // zwp_virtual_keyboard_v1.keymap
	vkKey     = 1 // zwp_virtual_keyboard_v1.key
	vkDestroy = 3 // zwp_virtual_keyboard_v1.destroy
)

// keymapXKB is WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1.
const keymapXKB = 1

// Linux evdev codes. textCodes is the printable part of a PC keyboard:
// the digit row, the 3 letter rows, and the space bar. A client such as
// Chromium can use the physical key of an event also when its keysym is
// a character, so text never goes on Escape, Backspace, Tab, Enter, or a
// modifier.
const (
	evTab   = 15
	evEnter = 28
)

var textCodes = []uint32{
	2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27,
	30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41,
	43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 57,
}

// textBatch is 1 keymap and the evdev codes of the keys to type with it.
type textBatch struct {
	keymap string
	keys   []uint32
}

// planText splits text into batches. Each batch has a keymap with at most
// len(textCodes) characters. It types a line break as Return and a tab
// as Tab, and it drops other control characters. It returns no batch for
// a text with no key to type.
func planText(text string) []textBatch {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	var batches []textBatch
	codes := map[rune]uint32{}
	var order []rune
	var keys []uint32
	flush := func() {
		if len(keys) > 0 {
			batches = append(batches, textBatch{textKeymap(order, codes), keys})
		}
		codes, order, keys = map[rune]uint32{}, nil, nil
	}
	for _, r := range text {
		switch {
		case r == '\n' || r == '\r':
			keys = append(keys, evEnter)
			continue
		case r == '\t':
			keys = append(keys, evTab)
			continue
		case r < 0x20 || (r >= 0x7f && r < 0xa0):
			continue
		}
		code, ok := codes[r]
		if !ok {
			if len(order) == len(textCodes) {
				flush()
			}
			code = textCodes[len(order)]
			codes[r] = code
			order = append(order, r)
		}
		keys = append(keys, code)
	}
	flush()
	return batches
}

// textKeymap returns an XKB keymap that gives each rune of order the key
// in codes, and has Return and Tab on their own keys. An XKB key code is
// the evdev code plus 8. A name Uxxxx is the keysym of the Unicode
// character, and libxkbcommon gives a Latin-1 character its legacy
// keysym.
func textKeymap(order []rune, codes map[rune]uint32) string {
	var b strings.Builder
	b.WriteString("xkb_keymap {\nxkb_keycodes \"flux\" {\nminimum = 8;\n")
	fmt.Fprintf(&b, "maximum = %d;\n", textCodes[len(textCodes)-1]+8)
	key := func(code uint32) { fmt.Fprintf(&b, "<K%d> = %d;\n", code+8, code+8) }
	key(evTab)
	key(evEnter)
	for _, r := range order {
		key(codes[r])
	}
	b.WriteString("};\n")
	b.WriteString("xkb_types \"flux\" { include \"complete\" };\n")
	b.WriteString("xkb_compatibility \"flux\" { include \"complete\" };\n")
	b.WriteString("xkb_symbols \"flux\" {\n")
	fmt.Fprintf(&b, "key <K%d> {[ Tab ]};\n", evTab+8)
	fmt.Fprintf(&b, "key <K%d> {[ Return ]};\n", evEnter+8)
	for _, r := range order {
		fmt.Fprintf(&b, "key <K%d> {[ U%04X ]};\n", codes[r]+8, r)
	}
	b.WriteString("};\n};\n")
	return b.String()
}

// errNoVirtualKeyboard wraps the error when fluxd cannot create its
// virtual keyboard. Keyboard.Type then uses wtype.
var errNoVirtualKeyboard = errors.New("no virtual keyboard")

// typeText types text through a virtual keyboard of its own. It stops
// when ctx ends. A failure before the first key wraps
// errNoVirtualKeyboard.
func typeText(ctx context.Context, text string) error {
	batches := planText(text)
	if len(batches) == 0 {
		return nil
	}
	w, kb, err := dialKeyboard()
	if err != nil {
		return fmt.Errorf("%w: %w", errNoVirtualKeyboard, err)
	}
	defer w.close()
	// A stop closes the connection, so that a blocked read ends.
	defer context.AfterFunc(ctx, w.close)()
	for i, b := range batches {
		if err := w.sendKeymap(kb, b.keymap); err != nil {
			if i == 0 && ctx.Err() == nil {
				// No key went out, so wtype can type the text.
				return fmt.Errorf("%w: %w", errNoVirtualKeyboard, err)
			}
			return ctxErr(ctx, err)
		}
		for _, code := range b.keys {
			for _, state := range []uint32{1, 0} {
				_ = w.c.SetReadDeadline(time.Now().Add(3 * time.Second))
				t := uint32(time.Now().UnixMilli())
				if err := w.roundTrip(w.msg(kb, vkKey, t, code, state), nil); err != nil {
					return ctxErr(ctx, err)
				}
			}
		}
	}
	return w.write(w.msg(kb, vkDestroy))
}

// ctxErr returns the error of ctx when ctx ended, else err.
func ctxErr(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

// dialKeyboard connects to the compositor and creates a virtual keyboard
// on the default seat. It returns the connection and the object ID of the
// keyboard.
func dialKeyboard() (*wlConn, uint32, error) {
	w, err := dialWayland()
	if err != nil {
		return nil, 0, err
	}
	fail := func(err error) (*wlConn, uint32, error) {
		w.close()
		return nil, 0, err
	}
	_ = w.c.SetReadDeadline(time.Now().Add(3 * time.Second))
	registry := w.newID()
	var manager, seat wlGlobal
	var haveManager, haveSeat bool
	err = w.roundTrip(w.msg(displayID, displayGetRegistry, registry), func(obj uint32, op uint16, body []byte) {
		if obj != registry || op != 0 {
			return
		}
		name, rest := wlUint(body)
		iface, rest := wlString(rest)
		version, _ := wlUint(rest)
		switch {
		case iface == keyboardManager:
			manager, haveManager = wlGlobal{name, version}, true
		case iface == seatInterface && !haveSeat:
			seat, haveSeat = wlGlobal{name, version}, true
		}
	})
	if err != nil {
		return fail(err)
	}
	if !haveManager {
		return fail(errors.New("the compositor does not offer " + keyboardManager))
	}
	if !haveSeat {
		return fail(errors.New("the compositor has no seat"))
	}
	seatID, mgr, kb := w.newID(), w.newID(), w.newID()
	err = w.roundTrip(append(append(
		w.msg(registry, registryBind, seat.name, seatInterface, uint32(1), seatID),
		w.msg(registry, registryBind, manager.name, keyboardManager, uint32(1), mgr)...),
		w.msg(mgr, vkmCreate, seatID, kb)...,
	), nil)
	if err != nil {
		return fail(err)
	}
	return w, kb, nil
}

// sendKeymap gives the keyboard kb the keymap, and waits until the
// compositor has it. The keymap goes in a file that only the 2 processes
// can open: fluxd removes its name at once and passes the descriptor.
func (w *wlConn) sendKeymap(kb uint32, keymap string) error {
	f, err := os.CreateTemp(os.Getenv("XDG_RUNTIME_DIR"), "flux-keymap-*")
	if err != nil {
		return fmt.Errorf("keymap: %w", err)
	}
	defer f.Close()
	_ = os.Remove(f.Name())
	data := append([]byte(keymap), 0)
	if _, err := f.Write(data); err != nil {
		return fmt.Errorf("keymap: %w", err)
	}
	// An fd argument takes no space in the body of a request.
	if err := w.writeFD(w.msg(kb, vkKeymap, uint32(keymapXKB), uint32(len(data))), int(f.Fd())); err != nil {
		return err
	}
	_ = w.c.SetReadDeadline(time.Now().Add(3 * time.Second))
	return w.roundTrip(nil, nil)
}

// writeFD sends msg with the file descriptor fd.
func (w *wlConn) writeFD(msg []byte, fd int) error {
	if err := w.failed(); err != nil {
		return err
	}
	_ = w.c.SetWriteDeadline(time.Now().Add(wlWriteWait))
	n, _, err := w.c.WriteMsgUnix(msg, syscall.UnixRights(fd), nil)
	if err == nil && n != len(msg) {
		err = fmt.Errorf("wayland: wrote %d of %d bytes", n, len(msg))
	}
	return err
}

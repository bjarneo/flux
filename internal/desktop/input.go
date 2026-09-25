package desktop

import (
	"errors"
	"fmt"
	"math"
	"os"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

// Linux input event types and codes from linux/input-event-codes.h.
const (
	evSyn = 0x00
	evKey = 0x01
	evRel = 0x02

	synReport = 0

	relX           = 0x00
	relY           = 0x01
	relHWheel      = 0x06
	relWheel       = 0x08
	relWheelHiRes  = 0x0b
	relHWheelHiRes = 0x0c

	btnLeft   = 0x110
	btnRight  = 0x111
	btnMiddle = 0x112

	keyEsc        = 1
	keyBackspace  = 14
	keyTab        = 15
	keyEnter      = 28
	keyLeftCtrl   = 29
	keyLeftShift  = 42
	keyLeftAlt    = 56
	keySpace      = 57
	keyF1         = 59
	keyF11        = 87
	keyF12        = 88
	keySysRq      = 99
	keyHome       = 102
	keyUp         = 103
	keyPageUp     = 104
	keyLeft       = 105
	keyRight      = 106
	keyEnd        = 107
	keyDown       = 108
	keyPageDown   = 109
	keyDelete     = 111
	keyScrollLock = 70
	keyLeftMeta   = 125
	keyMax        = 248

	busVirtual = 0x06
)

// uinput ioctl requests from linux/uinput.h.
const (
	uiDevCreate  = 0x5501
	uiDevDestroy = 0x5502
	uiDevSetup   = 0x405c5503
	uiSetEvBit   = 0x40045564
	uiSetKeyBit  = 0x40045565
	uiSetRelBit  = 0x40045566
)

// Scroll scale: the phone sends pixels. 15 pixels are one wheel notch,
// and one notch is 120 high-resolution units.
const (
	pixelsPerNotch = 15.0
	hiResPerNotch  = 120
)

type inputID struct {
	Bustype, Vendor, Product, Version uint16
}

type uinputSetup struct {
	ID           inputID
	Name         [80]byte
	FFEffectsMax uint32
}

type inputEvent struct {
	Time  unix.Timeval
	Type  uint16
	Code  uint16
	Value int32
}

func (e *inputEvent) bytes() []byte {
	return unsafe.Slice((*byte)(unsafe.Pointer(e)), unsafe.Sizeof(*e))
}

// Input is a uinput virtual device with a pointer and a keyboard. The phone
// touchpad and keyboard use it.
//
// The compositor applies the active keyboard layout to the key codes. Text
// types correctly only with a US layout.
type Input struct {
	mu     sync.Mutex
	fd     int
	fx, fy float64 // pointer motion remainders
	sx, sy float64 // scroll remainders in high-resolution units
	nx, ny int     // high-resolution units since the last full notch
}

// NewInput creates the "Flux remote input" uinput device.
func NewInput() (*Input, error) {
	fd, err := unix.Open("/dev/uinput", unix.O_WRONLY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		if errors.Is(err, os.ErrPermission) {
			return nil, fmt.Errorf("open /dev/uinput: %w. Install the Flux udev rule 60-flux-uinput.rules, then log out and log in again", err)
		}
		return nil, fmt.Errorf("open /dev/uinput: %w", err)
	}
	fail := func(err error) (*Input, error) {
		unix.Close(fd)
		return nil, fmt.Errorf("set up uinput device: %w", err)
	}
	for _, ev := range []int{evSyn, evKey, evRel} {
		if err := unix.IoctlSetInt(fd, uiSetEvBit, ev); err != nil {
			return fail(err)
		}
	}
	for code := 1; code <= keyMax; code++ {
		if err := unix.IoctlSetInt(fd, uiSetKeyBit, code); err != nil {
			return fail(err)
		}
	}
	for _, code := range []int{btnLeft, btnRight, btnMiddle} {
		if err := unix.IoctlSetInt(fd, uiSetKeyBit, code); err != nil {
			return fail(err)
		}
	}
	for _, code := range []int{relX, relY, relWheel, relHWheel, relWheelHiRes, relHWheelHiRes} {
		if err := unix.IoctlSetInt(fd, uiSetRelBit, code); err != nil {
			return fail(err)
		}
	}
	setup := uinputSetup{ID: inputID{Bustype: busVirtual, Vendor: 0x1209, Product: 0xf10c, Version: 1}}
	copy(setup.Name[:], "Flux remote input")
	if _, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), uiDevSetup, uintptr(unsafe.Pointer(&setup))); errno != 0 {
		return fail(errno)
	}
	if err := unix.IoctlSetInt(fd, uiDevCreate, 0); err != nil {
		return fail(err)
	}
	return &Input{fd: fd}, nil
}

// emit writes one event. The caller holds i.mu.
func (i *Input) emit(typ, code uint16, value int32) {
	ev := inputEvent{Type: typ, Code: code, Value: value}
	_, _ = unix.Write(i.fd, ev.bytes())
}

func (i *Input) sync() { i.emit(evSyn, synReport, 0) }

// Move moves the pointer. It keeps the fractional part for the next move.
func (i *Input) Move(dx, dy float64) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.fx += dx
	i.fy += dy
	x, y := math.Trunc(i.fx), math.Trunc(i.fy)
	i.fx -= x
	i.fy -= y
	if x == 0 && y == 0 {
		return
	}
	if x != 0 {
		i.emit(evRel, relX, int32(x))
	}
	if y != 0 {
		i.emit(evRel, relY, int32(y))
	}
	i.sync()
}

func buttonCode(button string) uint16 {
	switch button {
	case "right":
		return btnRight
	case "middle":
		return btnMiddle
	}
	return btnLeft
}

// Click presses and releases a button: "left", "right", or "middle".
func (i *Input) Click(button string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.tap(buttonCode(button))
}

// DoubleClick clicks the left button 2 times.
func (i *Input) DoubleClick() {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.tap(btnLeft)
	time.Sleep(30 * time.Millisecond)
	i.tap(btnLeft)
}

// Press holds a button down.
func (i *Input) Press(button string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.emit(evKey, buttonCode(button), 1)
	i.sync()
}

// Release lets a held button go.
func (i *Input) Release(button string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	i.emit(evKey, buttonCode(button), 0)
	i.sync()
}

// tap presses and releases a key or button. The caller holds i.mu.
func (i *Input) tap(code uint16) {
	i.emit(evKey, code, 1)
	i.sync()
	i.emit(evKey, code, 0)
	i.sync()
}

// Scroll scrolls by dx and dy pixels. A positive dy scrolls up, the same
// as KDE Connect on X11. A positive dx scrolls right. It sends
// high-resolution wheel events, and a classic wheel event for each full
// notch.
func (i *Input) Scroll(dx, dy float64) {
	i.mu.Lock()
	defer i.mu.Unlock()
	hy, ny := scrollStep(&i.sy, &i.ny, dy)
	hx, nx := scrollStep(&i.sx, &i.nx, dx)
	if hy == 0 && hx == 0 {
		return
	}
	if hy != 0 {
		i.emit(evRel, relWheelHiRes, hy)
		if ny != 0 {
			i.emit(evRel, relWheel, ny)
		}
	}
	if hx != 0 {
		i.emit(evRel, relHWheelHiRes, hx)
		if nx != 0 {
			i.emit(evRel, relHWheel, nx)
		}
	}
	i.sync()
}

// scrollStep converts pixels to high-resolution units. It returns the
// units to send now and the full notches that these units complete.
func scrollStep(remainder *float64, sinceNotch *int, pixels float64) (hiRes, notches int32) {
	*remainder += pixels * hiResPerNotch / pixelsPerNotch
	whole := math.Trunc(*remainder)
	*remainder -= whole
	hiRes = int32(whole)
	*sinceNotch += int(hiRes)
	notches = int32(*sinceNotch / hiResPerNotch)
	*sinceNotch -= int(notches) * hiResPerNotch
	return hiRes, notches
}

// keyStroke is the key code and the shift state that type one character.
type keyStroke struct {
	code  uint16
	shift bool
}

// usKeymap maps printable ASCII characters to US layout key codes.
var usKeymap = buildUSKeymap()

func buildUSKeymap() map[rune]keyStroke {
	m := map[rune]keyStroke{
		' ': {keySpace, false}, '\n': {keyEnter, false}, '\t': {keyTab, false},
	}
	rows := []struct {
		plain, shifted string
		first          uint16
	}{
		{"1234567890-=", "!@#$%^&*()_+", 2},
		{"qwertyuiop[]", "QWERTYUIOP{}", 16},
		{"asdfghjkl;'`", "ASDFGHJKL:\"~", 30},
		{"\\zxcvbnm,./", "|ZXCVBNM<>?", 43},
	}
	for _, row := range rows {
		for n, r := range row.plain {
			m[r] = keyStroke{row.first + uint16(n), false}
		}
		for n, r := range row.shifted {
			m[r] = keyStroke{row.first + uint16(n), true}
		}
	}
	return m
}

// TypeText types the characters of s that the US keymap has. It skips the
// other characters and returns the number of typed characters.
func (i *Input) TypeText(s string) int {
	i.mu.Lock()
	defer i.mu.Unlock()
	typed := 0
	for _, r := range s {
		ks, ok := usKeymap[r]
		if !ok {
			continue
		}
		i.stroke(ks.code, ks.shift, false, false, false)
		typed++
	}
	return typed
}

// specialKeys maps the KDE Connect specialKey numbers to key codes.
// Number 3 is Linefeed in KDE Connect. Flux sends Enter for it, because
// most keymaps do not map the Linefeed key.
var specialKeys = map[int]uint16{
	1: keyBackspace, 2: keyTab, 3: keyEnter, 4: keyLeft, 5: keyUp,
	6: keyRight, 7: keyDown, 8: keyPageUp, 9: keyPageDown, 10: keyHome,
	11: keyEnd, 12: keyEnter, 13: keyDelete, 14: keyEsc, 15: keySysRq,
	16: keyScrollLock,
	21: keyF1, 22: keyF1 + 1, 23: keyF1 + 2, 24: keyF1 + 3, 25: keyF1 + 4,
	26: keyF1 + 5, 27: keyF1 + 6, 28: keyF1 + 7, 29: keyF1 + 8, 30: keyF1 + 9,
	31: keyF11, 32: keyF12,
}

// SpecialKey presses a key from the KDE Connect specialKey table with
// modifiers. It ignores numbers that are not in the table.
func (i *Input) SpecialKey(code int, shift, ctrl, alt, super bool) {
	key, ok := specialKeys[code]
	if !ok {
		return
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	i.stroke(key, shift, ctrl, alt, super)
}

// KeyWithMods presses one printable character with modifiers, such as
// Ctrl+C. It adds Shift when the character needs it.
func (i *Input) KeyWithMods(key string, shift, ctrl, alt, super bool) {
	r := []rune(key)
	if len(r) != 1 {
		return
	}
	ks, ok := usKeymap[r[0]]
	if !ok {
		return
	}
	i.mu.Lock()
	defer i.mu.Unlock()
	i.stroke(ks.code, shift || ks.shift, ctrl, alt, super)
}

// stroke holds the modifiers, taps the key, and releases the modifiers.
// The caller holds i.mu.
func (i *Input) stroke(code uint16, shift, ctrl, alt, super bool) {
	mods := make([]uint16, 0, 4)
	if ctrl {
		mods = append(mods, keyLeftCtrl)
	}
	if shift {
		mods = append(mods, keyLeftShift)
	}
	if alt {
		mods = append(mods, keyLeftAlt)
	}
	if super {
		mods = append(mods, keyLeftMeta)
	}
	for _, m := range mods {
		i.emit(evKey, m, 1)
	}
	if len(mods) > 0 {
		i.sync()
	}
	i.tap(code)
	for n := len(mods) - 1; n >= 0; n-- {
		i.emit(evKey, mods[n], 0)
	}
	if len(mods) > 0 {
		i.sync()
	}
}

// Close removes the virtual device.
func (i *Input) Close() error {
	i.mu.Lock()
	defer i.mu.Unlock()
	_ = unix.IoctlSetInt(i.fd, uiDevDestroy, 0)
	return unix.Close(i.fd)
}

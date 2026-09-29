package desktop

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Linux input button codes for Pointer.Button.
const (
	BtnLeft   = 0x110
	BtnRight  = 0x111
	BtnMiddle = 0x112
)

// pointerIdle is the time without input after which Pointer closes its
// Wayland connection. The next input connects again.
const pointerIdle = 5 * time.Minute

// Pointer moves the pointer of the desktop, presses its buttons, and
// scrolls. It speaks the zwlr_virtual_pointer_v1 Wayland protocol, which
// Hyprland supports, so it needs no access to /dev/uinput. It connects at
// the first input and again after an error.
type Pointer struct {
	mu   sync.Mutex
	conn *wlConn
	ptr  uint32 // the object ID of the virtual pointer
	idle *time.Timer
	// output is the monitor that MoveTo positions on, or empty for the
	// monitor that the compositor selects.
	output string
}

// NewPointer returns a pointer that connects to $WAYLAND_DISPLAY.
func NewPointer() *Pointer { return &Pointer{} }

// NewMonitorPointer returns a pointer whose MoveTo positions on the
// monitor with the name, such as "eDP-1".
func NewMonitorPointer(output string) *Pointer { return &Pointer{output: output} }

// absExtent is the range of the positions that MoveTo sends.
const absExtent = 1<<16 - 1

// MoveTo moves the pointer to x and y on the monitor of the pointer. The
// values go from 0 at the top left corner to 1 at the bottom right corner.
func (p *Pointer) MoveTo(x, y float64) error {
	pos := func(v float64) uint32 { return uint32(math.Round(max(0, min(1, v)) * absExtent)) }
	return p.do(func(w *wlConn, ptr uint32, t uint32) [][]byte {
		return [][]byte{w.msg(ptr, vpMotionAbsolute, t, pos(x), pos(y), uint32(absExtent), uint32(absExtent)), w.msg(ptr, vpFrame)}
	})
}

// Move moves the pointer by dx and dy in logical pixels.
func (p *Pointer) Move(dx, dy float64) error {
	return p.do(func(w *wlConn, ptr uint32, t uint32) [][]byte {
		return [][]byte{w.msg(ptr, vpMotion, t, fixed(dx), fixed(dy)), w.msg(ptr, vpFrame)}
	})
}

// Button presses or releases a button, such as BtnLeft.
func (p *Pointer) Button(button uint32, pressed bool) error {
	state := uint32(0)
	if pressed {
		state = 1
	}
	return p.do(func(w *wlConn, ptr uint32, t uint32) [][]byte {
		return [][]byte{w.msg(ptr, vpButton, t, button, state), w.msg(ptr, vpFrame)}
	})
}

// Scroll scrolls like 2 fingers on a touchpad. A positive dy scrolls down,
// and a positive dx scrolls right.
func (p *Pointer) Scroll(dx, dy float64) error {
	return p.do(func(w *wlConn, ptr uint32, t uint32) [][]byte {
		msgs := [][]byte{w.msg(ptr, vpAxisSource, uint32(axisSourceFinger))}
		if dy != 0 {
			msgs = append(msgs, w.msg(ptr, vpAxis, t, uint32(axisVertical), fixed(dy)))
		}
		if dx != 0 {
			msgs = append(msgs, w.msg(ptr, vpAxis, t, uint32(axisHorizontal), fixed(dx)))
		}
		return append(msgs, w.msg(ptr, vpFrame))
	})
}

// Close removes the virtual pointer and closes the connection.
func (p *Pointer) Close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.closeLocked()
}

func (p *Pointer) closeLocked() {
	if p.idle != nil {
		p.idle.Stop()
		p.idle = nil
	}
	if p.conn == nil {
		return
	}
	_ = p.conn.write(p.conn.msg(p.ptr, vpDestroy))
	p.conn.close()
	p.conn = nil
}

// do sends the messages of build. After a failed write, it connects again
// and sends them once more.
func (p *Pointer) do(build func(w *wlConn, ptr uint32, t uint32) [][]byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	t := uint32(time.Now().UnixMilli())
	var err error
	for range 2 {
		if p.conn == nil || p.conn.failed() != nil {
			p.closeLocked()
			if p.conn, p.ptr, err = dialPointer(p.output); err != nil {
				return err
			}
		}
		if err = p.conn.write(build(p.conn, p.ptr, t)...); err == nil {
			p.armIdle()
			return nil
		}
		p.closeLocked()
	}
	return err
}

func (p *Pointer) armIdle() {
	if p.idle != nil {
		p.idle.Reset(pointerIdle)
		return
	}
	p.idle = time.AfterFunc(pointerIdle, func() {
		p.mu.Lock()
		defer p.mu.Unlock()
		p.closeLocked()
	})
}

// Opcodes of the requests that Pointer sends.
const (
	displaySync        = 0 // wl_display.sync
	displayGetRegistry = 1 // wl_display.get_registry
	registryBind       = 0 // wl_registry.bind
	vpmCreate          = 0 // zwlr_virtual_pointer_manager_v1.create_virtual_pointer
	vpmCreateOnOutput  = 2 // zwlr_virtual_pointer_manager_v1.create_virtual_pointer_with_output
	vpMotion           = 0 // zwlr_virtual_pointer_v1.motion
	vpMotionAbsolute   = 1
	vpButton           = 2
	vpAxis             = 3
	vpFrame            = 4
	vpAxisSource       = 5
	vpDestroy          = 8
)

// Values of wl_pointer.axis and wl_pointer.axis_source.
const (
	axisVertical     = 0
	axisHorizontal   = 1
	axisSourceFinger = 1
)

const pointerManager = "zwlr_virtual_pointer_manager_v1"

// Requests and events of wl_output. The name event needs version 4.
const (
	outputInterface = "wl_output"
	outputRelease   = 0 // wl_output.release, from version 3
	outputName      = 4 // the wl_output.name event
)

// displayID is the object ID of wl_display.
const displayID = 1

// dialPointer connects to the compositor and creates a virtual pointer. With
// an output name, the absolute motion of the pointer maps to that monitor.
// It returns the connection and the object ID of the pointer.
func dialPointer(output string) (*wlConn, uint32, error) {
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
	var manager wlGlobal
	var found bool
	var outputs []wlGlobal
	err = w.roundTrip(w.msg(displayID, displayGetRegistry, registry), func(obj uint32, op uint16, body []byte) {
		if obj != registry || op != 0 {
			return
		}
		// wl_registry.global: name, interface, version.
		name, rest := wlUint(body)
		iface, rest := wlString(rest)
		version, _ := wlUint(rest)
		switch iface {
		case pointerManager:
			manager, found = wlGlobal{name, version}, true
		case outputInterface:
			outputs = append(outputs, wlGlobal{name, version})
		}
	})
	if err != nil {
		return fail(err)
	}
	if !found {
		return fail(errors.New("the compositor does not offer " + pointerManager))
	}
	var out uint32
	if output != "" {
		if manager.version < 2 {
			return fail(fmt.Errorf("the compositor does not offer version 2 of %s, which the monitor %s needs", pointerManager, output))
		}
		if out, err = w.bindOutput(registry, outputs, output); err != nil {
			return fail(err)
		}
	}
	mgr, ptr := w.newID(), w.newID()
	// A null wl_seat selects the default seat.
	create := w.msg(mgr, vpmCreate, uint32(0), ptr)
	if out != 0 {
		create = w.msg(mgr, vpmCreateOnOutput, uint32(0), out, ptr)
	}
	err = w.roundTrip(append(
		w.msg(registry, registryBind, manager.name, pointerManager, min(manager.version, 2), mgr),
		create...,
	), nil)
	if err != nil {
		return fail(err)
	}
	_ = w.c.SetReadDeadline(time.Time{})
	go w.drain()
	return w, ptr, nil
}

// wlGlobal is a global of the Wayland registry.
type wlGlobal struct{ name, version uint32 }

// bindOutput binds each wl_output global, reads the names, and returns the
// object ID of the output with the name. It releases the other outputs.
func (w *wlConn) bindOutput(registry uint32, globals []wlGlobal, name string) (uint32, error) {
	var req []byte
	ids := map[uint32]bool{}
	for _, g := range globals {
		if g.version < 4 {
			continue
		}
		id := w.newID()
		ids[id] = true
		req = append(req, w.msg(registry, registryBind, g.name, outputInterface, uint32(4), id)...)
	}
	if len(ids) == 0 {
		return 0, fmt.Errorf("the compositor does not name its monitors, so the pointer cannot use %s", name)
	}
	var match uint32
	err := w.roundTrip(req, func(obj uint32, op uint16, body []byte) {
		if !ids[obj] || op != outputName {
			return
		}
		if s, _ := wlString(body); s == name {
			match = obj
		}
	})
	if err != nil {
		return 0, err
	}
	var release []byte
	for id := range ids {
		if id != match {
			release = append(release, w.msg(id, outputRelease)...)
		}
	}
	if len(release) > 0 {
		if err := w.write(release); err != nil {
			return 0, err
		}
	}
	if match == 0 {
		return 0, fmt.Errorf("the monitor %s is not connected", name)
	}
	return match, nil
}

// wlConn is a small Wayland client connection. It sends requests and reads
// the events of the setup. After the setup, drain reads the events and
// records a protocol error or a closed connection.
type wlConn struct {
	c      *net.UnixConn
	r      *bufio.Reader
	nextID uint32

	mu  sync.Mutex
	err error
}

// dialWayland connects to the socket of $WAYLAND_DISPLAY.
func dialWayland() (*wlConn, error) {
	name := os.Getenv("WAYLAND_DISPLAY")
	if name == "" {
		name = "wayland-0"
	}
	path := name
	if !filepath.IsAbs(path) {
		dir := os.Getenv("XDG_RUNTIME_DIR")
		if dir == "" {
			return nil, errors.New("XDG_RUNTIME_DIR is not set")
		}
		path = filepath.Join(dir, name)
	}
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		return nil, fmt.Errorf("connect to the Wayland display: %w", err)
	}
	return &wlConn{c: c, r: bufio.NewReader(c), nextID: displayID + 1}, nil
}

func (w *wlConn) newID() uint32 {
	id := w.nextID
	w.nextID++
	return id
}

// fixed is a wl_fixed_t argument.
type fixed float64

// msg encodes a request. The arguments are uint32, int32, fixed, or
// string values.
func (w *wlConn) msg(obj uint32, op uint16, args ...any) []byte {
	b := make([]byte, 8, 32)
	for _, a := range args {
		switch v := a.(type) {
		case uint32:
			b = binary.NativeEndian.AppendUint32(b, v)
		case int32:
			b = binary.NativeEndian.AppendUint32(b, uint32(v))
		case fixed:
			b = binary.NativeEndian.AppendUint32(b, uint32(int32(math.Round(float64(v)*256))))
		case string:
			b = binary.NativeEndian.AppendUint32(b, uint32(len(v)+1))
			b = append(b, v...)
			b = append(b, 0)
			for len(b)%4 != 0 {
				b = append(b, 0)
			}
		default:
			panic(fmt.Sprintf("wayland: argument of type %T", a))
		}
	}
	binary.NativeEndian.PutUint32(b[0:], obj)
	binary.NativeEndian.PutUint32(b[4:], uint32(len(b))<<16|uint32(op))
	return b
}

// wlWriteWait is the longest time that a write to the compositor can
// take. A compositor that does not read then does not stop the input.
const wlWriteWait = 2 * time.Second

// write sends messages in 1 write.
func (w *wlConn) write(msgs ...[]byte) error {
	if err := w.failed(); err != nil {
		return err
	}
	var b []byte
	for _, m := range msgs {
		b = append(b, m...)
	}
	_ = w.c.SetWriteDeadline(time.Now().Add(wlWriteWait))
	_, err := w.c.Write(b)
	return err
}

// read reads 1 event.
func (w *wlConn) read() (obj uint32, op uint16, body []byte, err error) {
	var hdr [8]byte
	if _, err = io.ReadFull(w.r, hdr[:]); err != nil {
		return
	}
	obj = binary.NativeEndian.Uint32(hdr[0:])
	so := binary.NativeEndian.Uint32(hdr[4:])
	size, op := so>>16, uint16(so&0xffff)
	if size < 8 {
		return 0, 0, nil, fmt.Errorf("wayland: event of %d bytes", size)
	}
	body = make([]byte, size-8)
	_, err = io.ReadFull(w.r, body)
	return
}

// roundTrip sends req and a wl_display.sync, and reads the events until
// the sync is done. It passes each other event to handle. It returns a
// protocol error of the compositor.
func (w *wlConn) roundTrip(req []byte, handle func(obj uint32, op uint16, body []byte)) error {
	done := w.newID()
	if err := w.write(req, w.msg(displayID, displaySync, done)); err != nil {
		return err
	}
	for {
		obj, op, body, err := w.read()
		if err != nil {
			return fmt.Errorf("wayland: %w", err)
		}
		switch {
		case obj == displayID && op == 0:
			return displayError(body)
		case obj == done:
			return nil
		case handle != nil:
			handle(obj, op, body)
		}
	}
}

// drain reads events until the connection ends. It records a protocol
// error, so that the next write fails and Pointer connects again.
func (w *wlConn) drain() {
	for {
		obj, op, body, err := w.read()
		if err == nil && obj == displayID && op == 0 {
			err = displayError(body)
		}
		if err != nil {
			w.mu.Lock()
			if w.err == nil {
				w.err = err
			}
			w.mu.Unlock()
			w.c.Close()
			return
		}
	}
}

func (w *wlConn) failed() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.err
}

func (w *wlConn) close() {
	w.mu.Lock()
	if w.err == nil {
		w.err = net.ErrClosed
	}
	w.mu.Unlock()
	w.c.Close()
}

// displayError decodes wl_display.error: object, code, message.
func displayError(body []byte) error {
	obj, rest := wlUint(body)
	code, rest := wlUint(rest)
	msg, _ := wlString(rest)
	return fmt.Errorf("wayland error on object %d, code %d: %s", obj, code, msg)
}

func wlUint(b []byte) (uint32, []byte) {
	if len(b) < 4 {
		return 0, nil
	}
	return binary.NativeEndian.Uint32(b), b[4:]
}

// wlString decodes a string argument: a length with the terminating 0, the
// bytes, and padding to 4 bytes.
func wlString(b []byte) (string, []byte) {
	n, rest := wlUint(b)
	if n == 0 || int(n) > len(rest) {
		return "", nil
	}
	s := string(rest[:n-1])
	padded := (int(n) + 3) &^ 3
	if padded > len(rest) {
		padded = len(rest)
	}
	return s, rest[padded:]
}

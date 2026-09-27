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
}

// NewPointer returns a pointer that connects to $WAYLAND_DISPLAY.
func NewPointer() *Pointer { return &Pointer{} }

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
			if p.conn, p.ptr, err = dialPointer(); err != nil {
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
	vpMotion           = 0 // zwlr_virtual_pointer_v1.motion
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

// displayID is the object ID of wl_display.
const displayID = 1

// dialPointer connects to the compositor and creates a virtual pointer. It
// returns the connection and the object ID of the pointer.
func dialPointer() (*wlConn, uint32, error) {
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
	var manager struct {
		name    uint32
		version uint32
		found   bool
	}
	err = w.roundTrip(w.msg(displayID, displayGetRegistry, registry), func(obj uint32, op uint16, body []byte) {
		if obj != registry || op != 0 {
			return
		}
		// wl_registry.global: name, interface, version.
		name, rest := wlUint(body)
		iface, rest := wlString(rest)
		version, _ := wlUint(rest)
		if iface == pointerManager {
			manager.name, manager.version, manager.found = name, version, true
		}
	})
	if err != nil {
		return fail(err)
	}
	if !manager.found {
		return fail(errors.New("the compositor does not offer " + pointerManager))
	}
	mgr, ptr := w.newID(), w.newID()
	// A null wl_seat selects the default seat.
	err = w.roundTrip(append(
		w.msg(registry, registryBind, manager.name, pointerManager, min(manager.version, 2), mgr),
		w.msg(mgr, vpmCreate, uint32(0), ptr)...,
	), nil)
	if err != nil {
		return fail(err)
	}
	_ = w.c.SetReadDeadline(time.Time{})
	go w.drain()
	return w, ptr, nil
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

// write sends messages in 1 write.
func (w *wlConn) write(msgs ...[]byte) error {
	if err := w.failed(); err != nil {
		return err
	}
	var b []byte
	for _, m := range msgs {
		b = append(b, m...)
	}
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

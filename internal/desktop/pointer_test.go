package desktop

import (
	"bufio"
	"encoding/binary"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// request is 1 request that the fake compositor received.
type request struct {
	obj  uint32
	op   uint16
	body []byte
}

// fakeCompositor answers the Wayland setup of Pointer. It offers the
// globals in globals, answers wl_display.sync, and sends the other
// requests to reqs. A global "wl_output=NAME" is an output with that name. It closes each connection after closeAfter requests of
// the virtual pointer, or never when closeAfter is 0.
func fakeCompositor(t *testing.T, globals []string, closeAfter int) (reqs chan request, accepts chan struct{}) {
	t.Helper()
	dir := t.TempDir()
	ln, err := net.Listen("unix", filepath.Join(dir, "wayland-test"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("WAYLAND_DISPLAY", "wayland-test")
	reqs = make(chan request, 64)
	accepts = make(chan struct{}, 4)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			accepts <- struct{}{}
			go serveFake(c, globals, closeAfter, reqs)
		}
	}()
	return reqs, accepts
}

func serveFake(c net.Conn, globals []string, closeAfter int, reqs chan request) {
	defer c.Close()
	var enc wlConn
	r := bufio.NewReader(c)
	seen := 0
	var reg uint32
	for {
		var hdr [8]byte
		if _, err := io.ReadFull(r, hdr[:]); err != nil {
			return
		}
		obj := binary.NativeEndian.Uint32(hdr[0:])
		so := binary.NativeEndian.Uint32(hdr[4:])
		body := make([]byte, so>>16-8)
		if _, err := io.ReadFull(r, body); err != nil {
			return
		}
		op := uint16(so & 0xffff)
		switch {
		case obj == displayID && op == displayGetRegistry:
			reg, _ = wlUint(body)
			for i, g := range globals {
				iface, _, isOutput := strings.Cut(g, "=")
				version := uint32(2)
				if isOutput {
					version = 4
				}
				_, _ = c.Write(enc.msg(reg, 0, uint32(i+1), iface, version))
			}
		case obj == displayID && op == displaySync:
			cb, _ := wlUint(body)
			_, _ = c.Write(enc.msg(cb, 0, uint32(1)))
		default:
			if obj == reg && op == registryBind {
				// An output sends its name when a client binds it.
				global, rest := wlUint(body)
				_, rest = wlString(rest)
				_, rest = wlUint(rest)
				id, _ := wlUint(rest)
				if _, name, ok := strings.Cut(globals[global-1], "="); ok {
					_, _ = c.Write(enc.msg(id, outputName, name))
				}
			}
			reqs <- request{obj, op, body}
			seen++
			if closeAfter > 0 && seen >= closeAfter+2 {
				return
			}
		}
	}
}

func next(t *testing.T, reqs chan request) request {
	t.Helper()
	select {
	case r := <-reqs:
		return r
	case <-time.After(3 * time.Second):
		t.Fatal("no request within 3 seconds")
		return request{}
	}
}

func TestPointerRequests(t *testing.T) {
	reqs, _ := fakeCompositor(t, []string{"wl_seat", pointerManager, "wl_output"}, 0)
	p := NewPointer()
	defer p.Close()
	if err := p.Move(1.5, -2); err != nil {
		t.Fatal(err)
	}

	// The bind names the manager global and its interface.
	bind := next(t, reqs)
	name, rest := wlUint(bind.body)
	iface, rest := wlString(rest)
	version, rest := wlUint(rest)
	mgr, _ := wlUint(rest)
	if bind.op != registryBind || name != 2 || iface != pointerManager || version != 2 {
		t.Fatalf("bind %+v: name %d %q version %d", bind, name, iface, version)
	}
	create := next(t, reqs)
	seat, rest := wlUint(create.body)
	ptr, _ := wlUint(rest)
	if create.obj != mgr || create.op != vpmCreate || seat != 0 {
		t.Fatalf("create %+v", create)
	}

	motion := next(t, reqs)
	_, rest = wlUint(motion.body)
	dx, rest := wlUint(rest)
	dy, _ := wlUint(rest)
	if motion.obj != ptr || motion.op != vpMotion || int32(dx) != 384 || int32(dy) != -512 {
		t.Fatalf("motion %+v: dx %d dy %d", motion, int32(dx), int32(dy))
	}
	if f := next(t, reqs); f.op != vpFrame {
		t.Fatalf("no frame after the motion: %+v", f)
	}

	if err := p.Button(BtnRight, true); err != nil {
		t.Fatal(err)
	}
	button := next(t, reqs)
	_, rest = wlUint(button.body)
	code, rest := wlUint(rest)
	state, _ := wlUint(rest)
	if button.op != vpButton || code != BtnRight || state != 1 {
		t.Fatalf("button %+v", button)
	}
	next(t, reqs) // frame

	if err := p.Scroll(0, 15); err != nil {
		t.Fatal(err)
	}
	if src := next(t, reqs); src.op != vpAxisSource {
		t.Fatalf("no axis source: %+v", src)
	}
	axis := next(t, reqs)
	_, rest = wlUint(axis.body)
	which, rest := wlUint(rest)
	value, _ := wlUint(rest)
	if axis.op != vpAxis || which != axisVertical || int32(value) != 15*256 {
		t.Fatalf("axis %+v", axis)
	}
	if f := next(t, reqs); f.op != vpFrame {
		t.Fatalf("scroll without a horizontal axis sent %+v", f)
	}
}

func TestMonitorPointer(t *testing.T) {
	reqs, _ := fakeCompositor(t, []string{pointerManager, "wl_output=HDMI-A-1", "wl_output=eDP-1"}, 0)
	p := NewMonitorPointer("eDP-1")
	defer p.Close()
	if err := p.MoveTo(0.5, 2); err != nil {
		t.Fatal(err)
	}
	// Both outputs are bound. The other output is released.
	outputs := map[uint32]uint32{} // object ID to global name
	for range 2 {
		bind := next(t, reqs)
		name, rest := wlUint(bind.body)
		iface, rest := wlString(rest)
		version, rest := wlUint(rest)
		id, _ := wlUint(rest)
		if bind.op != registryBind || iface != outputInterface || version != 4 {
			t.Fatalf("output bind %+v: %q version %d", bind, iface, version)
		}
		outputs[id] = name
	}
	release := next(t, reqs)
	if release.op != outputRelease || outputs[release.obj] != 2 {
		t.Fatalf("release %+v, want the release of HDMI-A-1", release)
	}
	var edp uint32
	for id, name := range outputs {
		if name == 3 {
			edp = id
		}
	}

	bind := next(t, reqs)
	_, rest := wlUint(bind.body)
	iface, rest := wlString(rest)
	version, rest := wlUint(rest)
	mgr, _ := wlUint(rest)
	if iface != pointerManager || version != 2 {
		t.Fatalf("manager bind %q version %d", iface, version)
	}
	create := next(t, reqs)
	seat, rest := wlUint(create.body)
	out, rest := wlUint(rest)
	ptr, _ := wlUint(rest)
	if create.obj != mgr || create.op != vpmCreateOnOutput || seat != 0 || out != edp {
		t.Fatalf("create %+v: output %d, want %d", create, out, edp)
	}

	motion := next(t, reqs)
	_, rest = wlUint(motion.body)
	x, rest := wlUint(rest)
	y, rest := wlUint(rest)
	xExtent, rest := wlUint(rest)
	yExtent, _ := wlUint(rest)
	if motion.obj != ptr || motion.op != vpMotionAbsolute || x != 32768 || y != absExtent || xExtent != absExtent || yExtent != absExtent {
		t.Fatalf("motion %+v: %d %d of %d %d", motion, x, y, xExtent, yExtent)
	}
	if f := next(t, reqs); f.op != vpFrame {
		t.Fatalf("no frame after the motion: %+v", f)
	}
}

func TestMonitorPointerMissing(t *testing.T) {
	fakeCompositor(t, []string{pointerManager, "wl_output=eDP-1"}, 0)
	err := NewMonitorPointer("DP-2").MoveTo(0, 0)
	if err == nil || !strings.Contains(err.Error(), "DP-2 is not connected") {
		t.Fatalf("err %v", err)
	}
}

func TestPointerWithoutProtocol(t *testing.T) {
	fakeCompositor(t, []string{"wl_seat"}, 0)
	err := NewPointer().Move(1, 1)
	if err == nil || !strings.Contains(err.Error(), pointerManager) {
		t.Fatalf("err %v", err)
	}
}

// TestPointerReconnects checks that Pointer connects again after the
// compositor closes the connection.
func TestPointerReconnects(t *testing.T) {
	reqs, accepts := fakeCompositor(t, []string{pointerManager}, 2)
	p := NewPointer()
	defer p.Close()
	if err := p.Move(1, 0); err != nil {
		t.Fatal(err)
	}
	<-accepts
	for range 4 {
		next(t, reqs) // bind, create, motion, frame
	}
	// The fake closed the connection. Wait until the client sees it.
	deadline := time.Now().Add(3 * time.Second)
	for p.conn.failed() == nil && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if err := p.Move(2, 0); err != nil {
		t.Fatal(err)
	}
	select {
	case <-accepts:
	case <-time.After(3 * time.Second):
		t.Fatal("Pointer did not connect again")
	}
}

func TestStringArgument(t *testing.T) {
	var w wlConn
	m := w.msg(3, 0, "abc", uint32(7))
	if len(m) != 8+4+4+4 {
		t.Fatalf("message of %d bytes", len(m))
	}
	s, rest := wlString(m[8:])
	v, _ := wlUint(rest)
	if s != "abc" || v != 7 {
		t.Fatalf("decoded %q %d", s, v)
	}
	if size := binary.NativeEndian.Uint32(m[4:]) >> 16; int(size) != len(m) {
		t.Fatalf("header size %d", size)
	}
}

// TestWithMods checks that wtype releases each modifier that it presses,
// in the reverse order, after the keys.
func TestWithMods(t *testing.T) {
	got := strings.Join(withMods([]string{"ctrl", "bogus", "logo"}, "-k", "c"), " ")
	if got != "-M ctrl -M logo -k c -m logo -m ctrl" {
		t.Fatalf("withMods %q", got)
	}
	if got := strings.Join(withMods(nil, "-"), " "); got != "-" {
		t.Fatalf("withMods without modifiers %q", got)
	}
}

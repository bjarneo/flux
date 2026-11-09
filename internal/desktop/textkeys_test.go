package desktop

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestPlanText(t *testing.T) {
	cases := []struct {
		text string
		keys []uint32
	}{
		{"a b", []uint32{2, 3, 4}},
		{"a a", []uint32{2, 3, 2}},
		{" ", []uint32{2}},
		{"x\r\ny\n", []uint32{2, evEnter, 3, evEnter}},
		{"\tz", []uint32{evTab, 2}},
		{"a\x00\x1b\x7fb", []uint32{2, 3}},
	}
	for _, c := range cases {
		batches := planText(c.text)
		if len(batches) != 1 || !slices.Equal(batches[0].keys, c.keys) {
			t.Fatalf("%q: batches %+v, want 1 batch with keys %v", c.text, batches, c.keys)
		}
	}
	if b := planText("\x00\x01"); len(b) != 0 {
		t.Fatalf("control characters gave batches %+v", b)
	}
}

// TestPlanTextNeverUsesControlCodes checks that no character goes on
// Escape, Backspace, Tab, Enter, or a modifier, and that a text with more
// characters than textCodes splits into batches.
func TestPlanTextNeverUsesControlCodes(t *testing.T) {
	var text []rune
	for r := rune(0x4e00); r < 0x4e00+100; r++ {
		text = append(text, r)
	}
	batches := planText(string(text) + "\n")
	if len(batches) != 3 {
		t.Fatalf("%d batches, want 3", len(batches))
	}
	n := 0
	for _, b := range batches {
		for _, k := range b.keys {
			n++
			if k == evEnter && n == 101 {
				continue
			}
			if !slices.Contains(textCodes, k) {
				t.Fatalf("a character went on evdev code %d", k)
			}
		}
	}
	if n != 101 {
		t.Fatalf("%d keys, want 101", n)
	}
}

// TestTextKeymapCompiles compiles a keymap with libxkbcommon and checks
// the keysym of each key.
func TestTextKeymapCompiles(t *testing.T) {
	if _, err := exec.LookPath("xkbcli"); err != nil {
		t.Skip("xkbcli is not installed")
	}
	b := planText("A é€ ")
	path := filepath.Join(t.TempDir(), "keymap.xkb")
	if err := os.WriteFile(path, []byte(b[0].keymap), 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command("xkbcli", "compile-keymap", "--keymap", path).CombinedOutput()
	if err != nil {
		t.Fatalf("xkbcli: %v\n%s\n%s", err, out, b[0].keymap)
	}
	// Each line of xkb_symbols is like: key <K10> { [ A ] };
	syms := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(strings.NewReplacer("{", " ", "}", " ", "[", " ", "]", " ", ";", " ").Replace(line))
		if len(f) == 3 && f[0] == "key" {
			syms[f[1]] = f[2]
		}
	}
	want := map[string][]string{
		"<K10>": {"A"}, "<K11>": {"space"}, "<K12>": {"eacute"}, "<K13>": {"EuroSign", "U20AC"},
		"<K23>": {"Tab"}, "<K36>": {"Return"},
	}
	for key, names := range want {
		if !slices.Contains(names, syms[key]) {
			t.Fatalf("key %s has %q, want one of %q:\n%s", key, syms[key], names, out)
		}
	}
}

// fdRequest is 1 request of the fake keyboard compositor, with the
// content of the file that came with it.
type fdRequest struct {
	obj  uint32
	op   uint16
	body []byte
	file []byte
}

// fakeKeyboardCompositor offers the globals, answers wl_display.sync, and
// sends the other requests to reqs. It reads each passed file.
func fakeKeyboardCompositor(t *testing.T, globals []string) chan fdRequest {
	t.Helper()
	dir := t.TempDir()
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(dir, "wayland-test"), Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("WAYLAND_DISPLAY", "wayland-test")
	reqs := make(chan fdRequest, 256)
	go func() {
		c, err := ln.AcceptUnix()
		if err != nil {
			return
		}
		defer c.Close()
		var enc wlConn
		var buf []byte
		var files []*os.File
		var reg uint32
		for {
			b := make([]byte, 4096)
			oob := make([]byte, 64)
			n, oobn, _, _, err := c.ReadMsgUnix(b, oob)
			if err != nil {
				return
			}
			if oobn > 0 {
				msgs, _ := syscall.ParseSocketControlMessage(oob[:oobn])
				for _, m := range msgs {
					fds, _ := syscall.ParseUnixRights(&m)
					for _, fd := range fds {
						files = append(files, os.NewFile(uintptr(fd), "keymap"))
					}
				}
			}
			buf = append(buf, b[:n]...)
			for len(buf) >= 8 {
				obj := binary.NativeEndian.Uint32(buf[0:])
				so := binary.NativeEndian.Uint32(buf[4:])
				size := int(so >> 16)
				if len(buf) < size {
					break
				}
				op := uint16(so & 0xffff)
				body := slices.Clone(buf[8:size])
				buf = buf[size:]
				switch {
				case obj == displayID && op == displayGetRegistry:
					reg, _ = wlUint(body)
					for i, g := range globals {
						_, _ = c.Write(enc.msg(reg, 0, uint32(i+1), g, uint32(1)))
					}
				case obj == displayID && op == displaySync:
					cb, _ := wlUint(body)
					_, _ = c.Write(enc.msg(cb, 0, uint32(1)))
				default:
					r := fdRequest{obj: obj, op: op, body: body}
					if op == vkKeymap && obj != reg && len(files) > 0 {
						f := files[0]
						files = files[1:]
						// A compositor maps the file from its start.
						r.file, _ = io.ReadAll(io.NewSectionReader(f, 0, 1<<20))
						f.Close()
					}
					reqs <- r
				}
			}
		}
	}()
	return reqs
}

func nextFD(t *testing.T, reqs chan fdRequest) fdRequest {
	t.Helper()
	select {
	case r := <-reqs:
		return r
	case <-time.After(3 * time.Second):
		t.Fatal("no request within 3 seconds")
		return fdRequest{}
	}
}

// TestTypeTextRequests checks the requests of typeText: the binds, the
// keyboard, the keymap with its file, and a press and a release for each
// character.
func TestTypeTextRequests(t *testing.T) {
	reqs := fakeKeyboardCompositor(t, []string{"wl_compositor", seatInterface, keyboardManager})
	if err := typeText(context.Background(), "hi h"); err != nil {
		t.Fatal(err)
	}
	seatBind := nextFD(t, reqs)
	if _, rest := wlUint(seatBind.body); !strings.HasPrefix(string(rest[4:]), seatInterface) {
		t.Fatalf("first request %+v, want the bind of the seat", seatBind)
	}
	nextFD(t, reqs) // the bind of the manager
	create := nextFD(t, reqs)
	seat, rest := wlUint(create.body)
	kb, _ := wlUint(rest)
	if create.op != vkmCreate || seat == 0 || kb == 0 {
		t.Fatalf("create %+v", create)
	}
	keymap := nextFD(t, reqs)
	format, rest := wlUint(keymap.body)
	size, _ := wlUint(rest)
	if keymap.obj != kb || keymap.op != vkKeymap || format != keymapXKB || int(size) != len(keymap.file) {
		t.Fatalf("keymap %+v, file of %d bytes", keymap, len(keymap.file))
	}
	if !bytes.HasSuffix(keymap.file, []byte{0}) || !bytes.Contains(keymap.file, []byte("U0020")) {
		t.Fatalf("keymap file %q", keymap.file)
	}
	var keys []uint32
	for range 8 {
		r := nextFD(t, reqs)
		_, rest := wlUint(r.body)
		code, rest := wlUint(rest)
		state, _ := wlUint(rest)
		if r.obj != kb || r.op != vkKey {
			t.Fatalf("request %+v, want a key", r)
		}
		if want := uint32(len(keys) % 2); state != 1-want {
			t.Fatalf("key %d has state %d", len(keys), state)
		}
		keys = append(keys, code)
	}
	if want := []uint32{2, 2, 3, 3, 4, 4, 2, 2}; !slices.Equal(keys, want) {
		t.Fatalf("keys %v, want %v", keys, want)
	}
	if r := nextFD(t, reqs); r.obj != kb || r.op != vkDestroy {
		t.Fatalf("last request %+v, want destroy", r)
	}
}

// TestTypeTextWithoutProtocol checks that typeText reports a compositor
// without the virtual keyboard, so that Keyboard.Type uses wtype.
func TestTypeTextWithoutProtocol(t *testing.T) {
	fakeKeyboardCompositor(t, []string{"wl_compositor", seatInterface})
	if err := typeText(context.Background(), "a"); !errors.Is(err, errNoVirtualKeyboard) {
		t.Fatalf("got %v, want errNoVirtualKeyboard", err)
	}
}

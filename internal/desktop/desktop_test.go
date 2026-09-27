package desktop

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/xml"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/godbus/dbus/v5/introspect"
)

func TestShortNames(t *testing.T) {
	if got := shortName("org.mpris.MediaPlayer2.firefox.instance_1_42"); got != "firefox" {
		t.Errorf("firefox: got %q", got)
	}
	if got := shortName("org.mpris.MediaPlayer2.chromium.instance12345"); got != "chromium" {
		t.Errorf("chromium: got %q", got)
	}
	if got := shortName("org.mpris.MediaPlayer2.mpv.instance-IbWwwPyh"); got != "mpv" {
		t.Errorf("mpv: got %q", got)
	}
	if got := shortName("org.mpris.MediaPlayer2.spotify"); got != "spotify" {
		t.Errorf("spotify: got %q", got)
	}
	names := shortNames([]string{
		"org.mpris.MediaPlayer2.firefox.instance_1_99",
		"org.mpris.MediaPlayer2.spotify",
		"org.mpris.MediaPlayer2.firefox.instance_1_42",
	})
	want := map[string]string{
		"firefox":   "org.mpris.MediaPlayer2.firefox.instance_1_42",
		"firefox 2": "org.mpris.MediaPlayer2.firefox.instance_1_99",
		"spotify":   "org.mpris.MediaPlayer2.spotify",
	}
	if len(names) != len(want) {
		t.Fatalf("got %v", names)
	}
	for k, v := range want {
		if names[k] != v {
			t.Errorf("%s: got %q, want %q", k, names[k], v)
		}
	}
}

func writeSupply(t *testing.T, root, name string, files map[string]string) {
	t.Helper()
	dir := filepath.Join(root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for k, v := range files {
		if err := os.WriteFile(filepath.Join(dir, k), []byte(v+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestReadBattery(t *testing.T) {
	old := powerSupplyRoot
	t.Cleanup(func() { powerSupplyRoot = old })

	root := t.TempDir()
	powerSupplyRoot = root
	if b := ReadBattery(); b.Present {
		t.Fatalf("empty dir: got %+v", b)
	}

	writeSupply(t, root, "AC", map[string]string{"type": "Mains", "online": "0"})
	writeSupply(t, root, "BAT0", map[string]string{"type": "Battery", "capacity": "80", "status": "Discharging"})
	writeSupply(t, root, "BAT1", map[string]string{"type": "Battery", "capacity": "60", "status": "Discharging"})
	writeSupply(t, root, "hid-mouse-battery", map[string]string{"type": "Battery", "scope": "Device", "capacity": "5", "status": "Discharging"})
	if b := ReadBattery(); !b.Present || b.Charge != 70 || b.Charging {
		t.Fatalf("2 batteries: got %+v", b)
	}

	writeSupply(t, root, "BAT1", map[string]string{"status": "Charging"})
	if b := ReadBattery(); !b.Charging {
		t.Fatalf("charging: got %+v", b)
	}

	root = t.TempDir()
	powerSupplyRoot = root
	writeSupply(t, root, "BAT0", map[string]string{"type": "Battery", "capacity": "100", "status": "Full"})
	writeSupply(t, root, "ucsi-source-psy-USBC000:001", map[string]string{"type": "USB", "online": "1"})
	if b := ReadBattery(); !b.Charging || b.Charge != 100 {
		t.Fatalf("full on USB power: got %+v", b)
	}
}

// fakeWlCopy puts a wl-copy in PATH that reads its input and exits.
func fakeWlCopy(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "wl-copy"), []byte("#!/bin/sh\ncat >/dev/null\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// record returns the lines that watchScript prints for data with the
// MIME types.
func record(state string, data []byte, types string) [3]string {
	return [3]string{state, base64.StdEncoding.EncodeToString(data), types}
}

func TestClipboardRecordText(t *testing.T) {
	fakeWlCopy(t)
	c := NewClipboard()
	var got []string
	onText := func(s string) { got = append(got, s) }
	onImage := func([]byte, string) { t.Fatal("a text selection reported an image") }
	plain := "text/plain;charset=utf-8 UTF8_STRING"

	c.record("text", record("data", []byte("start"), plain), true, onText, onImage)
	c.record("text", record("data", []byte("new"), plain), false, onText, onImage)
	c.record("text", record("data", []byte("new"), plain), false, onText, onImage)
	c.record("text", record("sensitive", []byte("password"), plain), false, onText, onImage)
	// A browser offers a copied image as HTML and as a PNG. The image
	// watcher reports it.
	c.record("text", record("data", []byte(`<img src="a.png">`), "text/html image/png"), false, onText, onImage)
	if err := c.Set("from phone"); err != nil {
		t.Fatal(err)
	}
	c.record("text", record("data", []byte("from phone"), plain), false, onText, onImage)
	// Office programs offer cells as plain text and as an image.
	c.record("text", record("data", []byte("A1\tB1"), plain+" image/png"), false, onText, onImage)

	if want := []string{"new", "A1\tB1"}; !slices.Equal(got, want) {
		t.Fatalf("reported %q, want %q", got, want)
	}
}

func TestClipboardRecordImage(t *testing.T) {
	fakeWlCopy(t)
	c := NewClipboard()
	var got [][]byte
	onText := func(string) { t.Fatal("an image selection reported text") }
	onImage := func(b []byte, mime string) {
		if mime != ImageType {
			t.Errorf("mime %s", mime)
		}
		got = append(got, b)
	}
	a := append(slices.Clone(pngMagic), 'a')
	b := append(slices.Clone(pngMagic), 'b')
	fromPhone := append(slices.Clone(pngMagic), 'p')

	c.record(ImageType, record("data", a, "image/png"), true, onText, onImage)
	c.record(ImageType, record("data", b, "text/html image/png"), false, onText, onImage)
	c.record(ImageType, record("data", b, "image/png"), false, onText, onImage)
	c.record(ImageType, record("data", a, "text/plain image/png"), false, onText, onImage)
	c.record(ImageType, record("data", []byte("GIF89a"), "image/png"), false, onText, onImage)
	c.record(ImageType, record("sensitive", a, "image/png"), false, onText, onImage)
	if err := c.SetImage(fromPhone, ImageType); err != nil {
		t.Fatal(err)
	}
	c.record(ImageType, record("data", fromPhone, "image/png"), false, onText, onImage)

	if len(got) != 1 || !bytes.Equal(got[0], b) {
		t.Fatalf("reported %q, want only %q", got, b)
	}

	// Text that equals the text before the image is a new change.
	var texts []string
	c.record("text", record("data", []byte("same"), "text/plain"), false, func(s string) { texts = append(texts, s) }, onImage)
	c.record(ImageType, record("data", a, "image/png"), false, onText, onImage)
	c.record("text", record("data", []byte("same"), "text/plain"), false, func(s string) { texts = append(texts, s) }, onImage)
	if len(texts) != 2 {
		t.Fatalf("reported %q, want the text twice", texts)
	}
}

func TestIsImage(t *testing.T) {
	cases := map[string]bool{
		"image/png":                       true,
		"text/html image/png":             true,
		"image/png text/plain":            false,
		"UTF8_STRING image/png":           false,
		"image/jpeg":                      false,
		"text/plain;charset=utf-8 STRING": false,
		"":                                false,
	}
	for types, want := range cases {
		if got := isImage(strings.Fields(types)); got != want {
			t.Errorf("isImage(%q) = %v, want %v", types, got, want)
		}
	}
}

// TestClipboardWatch runs Watch with a fake wl-paste. The fake runs the
// watch command once for each selection in a folder, as the real wl-paste
// does for each change, and answers --list-types for that selection.
func TestClipboardWatch(t *testing.T) {
	dir := t.TempDir()
	fake := `#!/bin/sh
if [ "$1" = "--list-types" ]; then cat "$FAKE_TYPES"; exit 0; fi
kind=text
[ "$2" = "image/png" ] && kind=image
shift 3
for data in "` + dir + `/$kind"/*.data; do
	[ -e "$data" ] || continue
	FAKE_TYPES="${data%.data}.types" CLIPBOARD_STATE=data "$@" <"$data"
done
exec sleep 30
`
	if err := os.WriteFile(filepath.Join(dir, "wl-paste"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	b := append(slices.Clone(pngMagic), 0, '\n', 'b')
	selections := map[string][2]string{
		"text/1":  {"start", "text/plain"},
		"text/2":  {"line 1\nline 2", "text/plain;charset=utf-8"},
		"image/1": {string(pngMagic) + "a", "image/png"},
		"image/2": {string(b), "text/html image/png"},
	}
	for name, sel := range selections {
		if err := os.MkdirAll(filepath.Join(dir, filepath.Dir(name)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name+".data"), []byte(sel[0]), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name+".types"), []byte(strings.ReplaceAll(sel[1], " ", "\n")+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	texts := make(chan string, 4)
	images := make(chan []byte, 4)
	done := make(chan struct{})
	go func() {
		NewClipboard().Watch(ctx, func(s string) { texts <- s }, func(b []byte, _ string) { images <- b })
		close(done)
	}()
	for range 2 {
		select {
		case s := <-texts:
			if s != "line 1\nline 2" {
				t.Errorf("text %q", s)
			}
		case img := <-images:
			if !bytes.Equal(img, b) {
				t.Errorf("image %q", img)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("Watch reported no change")
		}
	}
	cancel()
	<-done
	if len(texts)+len(images) != 0 {
		t.Errorf("Watch reported the current content")
	}
}

func TestLoopbackABI(t *testing.T) {
	if got := unsafe.Sizeof(loopbackConfig{}); got != 72 {
		t.Fatalf("struct v4l2_loopback_config has %d bytes, want 72", got)
	}
	if loopbackAdd != 0x40487e01 || loopbackRemove != 0x40047e02 {
		t.Fatalf("ioctl numbers %#x %#x", loopbackAdd, loopbackRemove)
	}
}

func TestFindLoopback(t *testing.T) {
	dir := t.TempDir()
	old := sysfsVideo
	sysfsVideo = dir
	defer func() { sysfsVideo = old }()
	for nr, name := range map[string]string{"video50": "Hardware ISP Camera", "video51": "Flux Camera"} {
		if err := os.MkdirAll(filepath.Join(dir, nr), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, nr, "name"), []byte(name+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if nr, ok := findLoopback("Flux Camera"); !ok || nr != 51 {
		t.Fatalf("findLoopback = %d, %v", nr, ok)
	}
	if _, ok := findLoopback("Nothing"); ok {
		t.Fatal("found a device that does not exist")
	}
}

// TestClipboardSetImage checks that SetImage gives wl-copy the MIME type
// and the exact bytes of the image.
func TestClipboardSetImage(t *testing.T) {
	dir := t.TempDir()
	fake := "#!/bin/sh\nprintf '%s\\n' \"$@\" >'" + dir + "/args'\ncat >'" + dir + "/stdin'\n"
	if err := os.WriteFile(filepath.Join(dir, "wl-copy"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	data := []byte("\x89PNG\r\n\x1a\n\x00\x01\x02")
	if err := NewClipboard().SetImage(data, "image/png"); err != nil {
		t.Fatal(err)
	}
	args, _ := os.ReadFile(filepath.Join(dir, "args"))
	if string(args) != "--type\nimage/png\n" {
		t.Errorf("args %q", args)
	}
	stdin, _ := os.ReadFile(filepath.Join(dir, "stdin"))
	if string(stdin) != string(data) {
		t.Errorf("stdin %q", stdin)
	}
}

// TestClipboardSetReturnsWhileWlCopyServes uses a fake wl-copy that, like
// the real one, leaves a background process that keeps its stdout and
// stderr open. Set must return at once and not wait for that process.
func TestClipboardSetReturnsWhileWlCopyServes(t *testing.T) {
	dir := t.TempDir()
	fake := "#!/bin/sh\ncat >/dev/null\n(sleep 30) &\nexit 0\n"
	if err := os.WriteFile(filepath.Join(dir, "wl-copy"), []byte(fake), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	done := make(chan error, 1)
	go func() { done <- NewClipboard().Set("hello") }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Set waits for the background wl-copy process")
	}
}

func TestWritableVolume(t *testing.T) {
	player := func(access string) string {
		return `<node><interface name="org.mpris.MediaPlayer2.Player">` +
			`<property name="Volume" type="d" access="` + access + `"/></interface></node>`
	}
	for _, c := range []struct {
		name, xml string
		want      bool
	}{
		{"readwrite", player("readwrite"), true},
		{"read only", player("read"), false},
		{"no introspection data", `<node/>`, false},
		{"volume on another interface", `<node><interface name="org.example.Player">` +
			`<property name="Volume" type="d" access="readwrite"/></interface></node>`, false},
	} {
		var node introspect.Node
		if err := xml.Unmarshal([]byte(c.xml), &node); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got := writableVolume(&node); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

package core

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"flux/internal/config"
	"flux/internal/proto"
)

func TestExtendSize(t *testing.T) {
	for _, c := range []struct {
		w, h, limit, wantW, wantH int
		ok                        bool
	}{
		{2182, 1080, 3840, 2182, 1080, true},
		{2183, 1081, 3840, 2182, 1080, true},
		{2400, 1080, 1920, 1920, 864, true},
		{2560, 1600, 1920, 1920, 1200, true},
		{0, 1080, 1920, 0, 0, false},
		{2400, 100, 1920, 0, 0, false},
		{9000, 1080, 1920, 0, 0, false},
	} {
		w, h, err := extendSize(c.w, c.h, c.limit)
		if (err == nil) != c.ok || w != c.wantW || h != c.wantH {
			t.Errorf("extendSize(%d, %d, %d) = %d, %d, %v, want %d, %d, ok %v", c.w, c.h, c.limit, w, h, err, c.wantW, c.wantH, c.ok)
		}
	}
}

// The scale follows the Android density from 1 to 2, and Hyprland takes
// it without the warning about a scale that is not clean.
func TestExtendScale(t *testing.T) {
	for _, c := range []struct {
		w, h    int
		density float64
		want    float64
	}{
		{2182, 1080, 2.625, 2},
		{1920, 1200, 1.5, 1.5},
		{2000, 1200, 1.5, 1.6},
		{2000, 1202, 1.5, 1}, // 1 and 2 are both 0.5 away, and the smaller scale gives more room
		{1280, 800, 1.25, 1.25},
		{1920, 1080, 0, 1},
		{1920, 1080, -3, 1},
		{1920, 1080, 9, 2},
	} {
		got := extendScale(c.w, c.h, c.density)
		if got != c.want {
			t.Errorf("extendScale(%d, %d, %v) = %v, want %v", c.w, c.h, c.density, got, c.want)
		}
		if !cleanScale(c.w, c.h, got) {
			t.Errorf("scale %v of %dx%d is not clean", got, c.w, c.h)
		}
	}
	for _, d := range []float64{float64(0) / zero(), 1 / zero()} {
		if got := extendScale(1920, 1080, d); got != 1 {
			t.Errorf("extendScale with density %v = %v, want 1", d, got)
		}
	}
}

// zero returns 0 at run time, so that the test can divide by it.
func zero() float64 { return 0 }

func TestExtendRule(t *testing.T) {
	if got, want := extendRule("FLUX-1", 2000, 1200, 1.6), `hl.monitor({ output = "FLUX-1", mode = "2000x1200@30", position = "auto-right", scale = 1.6 })`; got != want {
		t.Errorf("extendRule = %s, want %s", got, want)
	}
	if got, want := extendKeyword("FLUX-1", 2182, 1080, 2), "FLUX-1,2182x1080@30,auto-right,2"; got != want {
		t.Errorf("extendKeyword = %s, want %s", got, want)
	}
}

func TestExtendShown(t *testing.T) {
	out := []byte(`[{"name":"eDP-1","width":2880,"height":1800,"dpmsStatus":true},{"name":"FLUX-1","width":1920,"height":1080,"dpmsStatus":false}]`)
	for _, c := range []struct {
		w, h int
		want bool
	}{{1920, 1080, true}, {2182, 1080, false}} {
		got, err := extendShown(out, c.w, c.h)
		if err != nil || got != c.want {
			t.Errorf("extendShown(%d, %d) = %v, %v, want %v", c.w, c.h, got, err, c.want)
		}
	}
	if got, _ := extendShown([]byte(`[{"name":"eDP-1","width":1920,"height":1080}]`), 1920, 1080); got {
		t.Error("extendShown found a monitor of another name")
	}
	if _, err := extendShown([]byte("not json"), 1, 1); err == nil {
		t.Error("extendShown read text that is not JSON")
	}
}

func TestExtendRecorder(t *testing.T) {
	missing := func(string) (string, error) { return "", errors.New("not found") }
	if _, err := extendRecorder(missing); !errors.Is(err, errNoExtendRecorder) {
		t.Errorf("without wf-recorder: %v", err)
	}
	found := func(name string) (string, error) { return "/usr/bin/" + name, nil }
	rec, err := extendRecorder(found)
	if err != nil || rec.path != "/usr/bin/wf-recorder" {
		t.Fatalf("extendRecorder = %+v, %v", rec, err)
	}
	if args := rec.args(extendOutput, 1920, 1080); !slices.Contains(args, extendOutput) {
		t.Errorf("wf-recorder args %q do not name the monitor", args)
	}
}

// fakeExtendHyprctl puts a hyprctl on PATH that answers "ok" and lists the
// virtual monitor with the size w × h. It returns the file of the calls.
func fakeExtendHyprctl(t *testing.T, dir string, w, h int) string {
	t.Helper()
	calls := filepath.Join(dir, "hyprctl-calls")
	monitors := fmt.Sprintf(`[{"name":"eDP-1","width":2880,"height":1800,"dpmsStatus":true},{"name":%q,"width":%d,"height":%d,"dpmsStatus":true}]`, extendOutput, w, h)
	script := "#!/bin/sh\n" +
		"echo \"$*\" >> " + calls + "\n" +
		"case \"$1\" in\n" +
		"monitors) echo '" + monitors + "' ;;\n" +
		"*) echo ok ;;\n" +
		"esac\n"
	if err := os.WriteFile(filepath.Join(dir, "hyprctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return calls
}

// fakeWFRecorder puts a wf-recorder on PATH. Each run adds its arguments
// to the file runs and writes the FLV stream of flvStream. The first run
// then exits, as wf-recorder does after a mode change. A later run waits
// until it gets SIGINT.
func fakeWFRecorder(t *testing.T, dir string) string {
	t.Helper()
	stream := filepath.Join(dir, "stream.flv")
	if err := os.WriteFile(stream, flvStream(), 0o644); err != nil {
		t.Fatal(err)
	}
	runs := filepath.Join(dir, "runs")
	script := "#!/bin/sh\n" +
		"echo \"$*\" >> " + runs + "\n" +
		"/usr/bin/cat " + stream + "\n" +
		"if [ \"$(/usr/bin/wc -l < " + runs + ")\" -lt 2 ]; then exit 0; fi\n" +
		"trap '/usr/bin/kill $pid; exit 0' INT\n" +
		"/usr/bin/sleep 10 >/dev/null & pid=$!\n" +
		"wait $pid\n"
	if err := os.WriteFile(filepath.Join(dir, desktopCPURecorder), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return runs
}

// tlsStreamLink is a fakeStreamLink whose phone end reads the TLS stream
// and counts the frames by their flags.
type tlsStreamLink struct {
	*fakeStreamLink
	cert tls.Certificate

	mu     sync.Mutex
	frames []byte
}

func (f *tlsStreamLink) DialPeer(ctx context.Context, _ int) (*tls.Conn, error) {
	f.dials <- ctx
	c1, c2 := net.Pipe()
	go func() {
		phone := tls.Server(c2, &tls.Config{Certificates: []tls.Certificate{f.cert}})
		defer phone.Close()
		for {
			var head [5]byte
			if _, err := io.ReadFull(phone, head[:]); err != nil {
				return
			}
			if _, err := io.CopyN(io.Discard, phone, int64(binary.BigEndian.Uint32(head[:4]))); err != nil {
				return
			}
			f.mu.Lock()
			f.frames = append(f.frames, head[4])
			f.mu.Unlock()
		}
	}()
	context.AfterFunc(ctx, func() { c2.Close() })
	return tls.Client(c1, &tls.Config{InsecureSkipVerify: true}), nil
}

// count returns the number of frames with the flags.
func (f *tlsStreamLink) count(flags byte) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, b := range f.frames {
		if b == flags {
			n++
		}
	}
	return n
}

func extendPacket(port int) *proto.Packet {
	return proto.New(proto.TypeFluxDesktop, map[string]any{
		"state": "start", "port": port, "maxSize": 1920,
		"extend": true, "width": 2400, "height": 1080, "density": 2.625,
	})
}

// An extended screen adds the virtual monitor with the size of the phone,
// streams it with wf-recorder, starts the recorder again after a mode
// change, and removes the monitor at the stop.
func TestExtendedScreen(t *testing.T) {
	gap := extendRestartGap
	extendRestartGap = 0
	t.Cleanup(func() { extendRestartGap = gap })
	dir := t.TempDir()
	// The phone asks for 2400 × 1080 and a stream of at most 1920 pixels.
	calls := fakeExtendHyprctl(t, dir, 1920, 864)
	runs := fakeWFRecorder(t, dir)
	t.Setenv("PATH", dir)
	cert, _, err := proto.LoadOrCreateCert(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := &tlsStreamLink{fakeStreamLink: newFakeStreamLink(), cert: cert}
	d.handleDesktop(dev, l, extendPacket(12071))
	l.waitDial(t)
	waitFor(t, "the second recorder sends its frames", func() bool { return l.count(frameFormat) == 2 })
	waitFor(t, "the live packet", func() bool { return slices.Contains(l.states(), "live") })

	s := d.currentDesktop()
	if s == nil {
		t.Fatal("no session")
	}
	d.mu.Lock()
	view := s.view
	extended := d.extended
	d.mu.Unlock()
	if !view.Extend || view.Monitor != extendOutput || view.Width != 1920 || view.Height != 864 || !extended {
		t.Fatalf("view %+v, extended %v", view, extended)
	}
	recs := readLines(t, runs)
	if len(recs) != 2 || !strings.Contains(recs[0], "-o "+extendOutput) {
		t.Fatalf("recorder runs %q, want 2 runs of %s", recs, extendOutput)
	}
	l.mu.Lock()
	live := 0
	for _, b := range l.sent {
		if b["state"] == "live" {
			live++
			if b["extend"] != true || b["monitor"] != extendOutput {
				t.Errorf("live packet %v", b)
			}
		}
	}
	l.mu.Unlock()
	if live != 1 {
		t.Errorf("%d live packets, want 1", live)
	}

	if err := d.StopDesktop(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "the session ends", func() bool { return d.currentDesktop() == nil })
	waitFor(t, "the monitor goes", func() bool { return slices.Contains(readLines(t, calls), "output remove "+extendOutput) })
	got := readLines(t, calls)
	rule := "eval " + extendRule(extendOutput, 1920, 864, 2)
	create := slices.Index(got, "output create headless "+extendOutput)
	if first := slices.Index(got, rule); first < 0 || create < 0 || first > create {
		t.Fatalf("hyprctl calls %q, want the rule before the create", got)
	}
	// The rule comes again before the second recorder.
	if n := countOf(got, rule); n != 2 {
		t.Errorf("the rule ran %d times, want 2: %q", n, got)
	}
	d.mu.Lock()
	extended = d.extended
	d.mu.Unlock()
	if extended {
		t.Error("the daemon still has the monitor")
	}
}

// Without wf-recorder, the phone gets the error, and fluxd adds no monitor.
func TestExtendedScreenNeedsWFRecorder(t *testing.T) {
	dir := t.TempDir()
	calls := fakeExtendHyprctl(t, dir, 1920, 864)
	t.Setenv("PATH", dir)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: true})
	l := newFakeStreamLink()
	d.handleDesktop(dev, l, extendPacket(12071))
	waitFor(t, "the session ends", func() bool { return d.currentDesktop() == nil })
	if got := l.states(); len(got) != 1 || !strings.Contains(got[0], "needs wf-recorder") {
		t.Fatalf("the phone got %q, want the wf-recorder error", got)
	}
	if got := readLines(t, calls); len(got) != 0 {
		t.Errorf("hyprctl ran %q", got)
	}
}

// A refusal comes before the monitor: with the switch off, fluxd adds no
// monitor.
func TestExtendedScreenChecksTheSwitchFirst(t *testing.T) {
	dir := t.TempDir()
	calls := fakeExtendHyprctl(t, dir, 1920, 864)
	fakeWFRecorder(t, dir)
	t.Setenv("PATH", dir)
	d, dev := sessionDaemon(t, &config.Config{RemoteDesktop: false})
	l := newFakeStreamLink()
	d.handleDesktop(dev, l, extendPacket(12071))
	if got := l.states(); len(got) != 1 || !strings.Contains(got[0], "the remote desktop is off") {
		t.Fatalf("the phone got %q, want the error", got)
	}
	if got := readLines(t, calls); len(got) != 0 {
		t.Errorf("hyprctl ran %q", got)
	}
}

// The stop of fluxd removes the monitor once, also when the session
// removes it too.
func TestRemoveExtendOutputOnce(t *testing.T) {
	dir := t.TempDir()
	calls := fakeExtendHyprctl(t, dir, 1920, 864)
	t.Setenv("PATH", dir)
	d, _ := sessionDaemon(t, &config.Config{})
	d.removeExtendOutput()
	if got := readLines(t, calls); len(got) != 0 {
		t.Fatalf("hyprctl ran %q without a monitor", got)
	}
	d.extended = true
	d.removeExtendOutput()
	d.removeExtendOutput()
	if got := readLines(t, calls); !slices.Equal(got, []string{"output remove " + extendOutput}) {
		t.Fatalf("hyprctl calls %q", got)
	}
}

// fluxd removes a virtual monitor that an earlier fluxd left.
func TestRemoveLeftoverOutput(t *testing.T) {
	dir := t.TempDir()
	calls := fakeExtendHyprctl(t, dir, 1920, 864)
	t.Setenv("PATH", dir)
	d, _ := sessionDaemon(t, &config.Config{})
	d.removeLeftoverOutput(context.Background())
	if got := readLines(t, calls); !slices.Equal(got, []string{"monitors all -j", "output remove " + extendOutput}) {
		t.Fatalf("hyprctl calls %q", got)
	}
}

func readLines(t *testing.T, path string) []string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	var out []string
	for line := range strings.Lines(string(b)) {
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	return out
}

func countOf(list []string, s string) int {
	n := 0
	for _, v := range list {
		if v == s {
			n++
		}
	}
	return n
}

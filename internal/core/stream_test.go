package core

import (
	"bytes"
	"errors"
	"io"
	"slices"
	"strings"
	"sync"
	"testing"
)

func TestMicStartCheck(t *testing.T) {
	b := micStart{State: "start", Port: 12070}
	if err := b.check(); err != nil {
		t.Fatalf("defaults: %v", err)
	}
	if b.Rate != 48000 || b.Channels != 1 || b.Format != "s16le" {
		t.Fatalf("defaults: %+v", b)
	}
	bad := []micStart{
		{Port: 0},
		{Port: 70000},
		{Port: 12070, Format: "f32le"},
		{Port: 12070, Rate: 4000},
		{Port: 12070, Rate: 192000},
		{Port: 12070, Channels: 6},
	}
	for _, b := range bad {
		if err := b.check(); err == nil {
			t.Errorf("%+v: want an error", b)
		}
	}
}

func TestMicArgs(t *testing.T) {
	args := micArgs(48000, 1)
	for _, want := range [][]string{
		{"--playback", "--raw"},
		{"--format", "s16"},
		{"--rate", "48000"},
		{"--channels", "1"},
	} {
		i := slices.Index(args, want[0])
		if i < 0 || i+len(want) > len(args) || !slices.Equal(args[i:i+len(want)], want) {
			t.Errorf("args %q do not have %q", args, want)
		}
	}
	if args[len(args)-1] != "-" {
		t.Errorf("the stream must come from stdin: %q", args)
	}
	i := slices.Index(args, "--properties")
	if i < 0 {
		t.Fatalf("no --properties in %q", args)
	}
	props := args[i+1]
	for _, want := range []string{`media.class = "Audio/Source"`, `node.name = "flux_mic"`, `node.description = "Flux Microphone"`} {
		if !strings.Contains(props, want) {
			t.Errorf("properties %q do not have %q", props, want)
		}
	}
}

func TestFindScreenPlayer(t *testing.T) {
	has := func(names ...string) func(string) (string, error) {
		return func(n string) (string, error) {
			if slices.Contains(names, n) {
				return "/usr/bin/" + n, nil
			}
			return "", errors.New("not found")
		}
	}
	title := screenTitle("Pixel 8")
	if title != "Flux · Pixel 8 screen" {
		t.Fatalf("title: %q", title)
	}

	p, err := findScreenPlayer(has("mpv", "ffplay"), title)
	if err != nil || p.Name != "mpv" || p.Path != "/usr/bin/mpv" {
		t.Fatalf("mpv first: %+v, %v", p, err)
	}
	for _, want := range []string{"--demuxer-lavf-format=h264", "--title=" + title, "--wayland-app-id=flux-screen", "--no-config"} {
		if !slices.Contains(p.Args, want) {
			t.Errorf("mpv args %q do not have %q", p.Args, want)
		}
	}
	if p.Args[len(p.Args)-1] != "-" {
		t.Errorf("mpv must read stdin: %q", p.Args)
	}

	p, err = findScreenPlayer(has("ffplay"), title)
	if err != nil || p.Name != "ffplay" {
		t.Fatalf("ffplay fallback: %+v, %v", p, err)
	}
	if i := slices.Index(p.Args, "-window_title"); i < 0 || p.Args[i+1] != title {
		t.Errorf("ffplay title: %q", p.Args)
	}
	if !slices.Contains(p.Env, "SDL_VIDEO_WAYLAND_WMCLASS=flux-screen") {
		t.Errorf("ffplay app id: %q", p.Env)
	}
	// ffplay closes its window at the end of the stream, so the mirror ends.
	if !slices.Contains(p.Args, "-autoexit") {
		t.Errorf("ffplay args %q do not have -autoexit", p.Args)
	}

	if _, err := findScreenPlayer(has(), title); err == nil || !strings.Contains(err.Error(), "mpv") {
		t.Errorf("no player: %v", err)
	}
}

// oddReader returns the data in reads of 1001 bytes, so that a read ends
// inside a frame. It closes eof when it returns the end of the data.
type oddReader struct {
	r    io.Reader
	eof  chan struct{}
	once sync.Once
}

func (o *oddReader) Read(b []byte) (int, error) {
	n, err := o.r.Read(b[:min(len(b), 1001)])
	if err == io.EOF {
		o.once.Do(func() { close(o.eof) })
	}
	return n, err
}

// stallWriter blocks its first write until the test opens it, as pw-cat
// does when the pipe is full.
type stallWriter struct {
	open chan struct{}
	mu   sync.Mutex
	out  bytes.Buffer
}

func (w *stallWriter) Write(b []byte) (int, error) {
	<-w.open
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.out.Write(b)
}

// After a stall of the network, 1 second of audio comes at once. micPump
// keeps at most micBacklog of it and drops whole frames.
func TestMicPumpDropsOldAudio(t *testing.T) {
	const frame, frames = 4, 48000
	var in bytes.Buffer
	for i := range frames {
		in.Write([]byte{byte(i), byte(i >> 8), 0xAA, 0xBB})
	}
	limit := int(micBacklog.Seconds()*48000) * frame
	w := &stallWriter{open: make(chan struct{})}
	src, feed := io.Pipe()
	drops := 0
	done := make(chan error, 1)
	r := &oddReader{r: src, eof: make(chan struct{})}
	go func() { done <- micPump(w, r, frame, limit, func() { drops++ }) }()
	if _, err := feed.Write(in.Bytes()); err != nil {
		t.Fatal(err)
	}
	feed.Close()
	// pw-cat reads again after micPump has read all of the audio.
	<-r.eof
	close(w.open)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	out := w.out.Bytes()
	if drops == 0 {
		t.Fatal("nothing was dropped")
	}
	if len(out) > limit+micPipeSize || len(out)%frame != 0 {
		t.Fatalf("wrote %d bytes, want at most %d whole frames", len(out), limit+micPipeSize)
	}
	for i := 0; i < len(out); i += frame {
		if out[i+2] != 0xAA || out[i+3] != 0xBB {
			t.Fatalf("the frame at %d is broken: % x", i, out[i:i+frame])
		}
	}
	// The newest audio stays.
	n := frames - 1
	if last := out[len(out)-frame:]; last[0] != byte(n) || last[1] != byte(n>>8) {
		t.Fatalf("the last frame is % x", last)
	}
}

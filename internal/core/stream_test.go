package core

import (
	"errors"
	"slices"
	"strings"
	"testing"
)

func TestMicStartCheck(t *testing.T) {
	b := micStart{State: "start", Port: 1739}
	if err := b.check(); err != nil {
		t.Fatalf("defaults: %v", err)
	}
	if b.Rate != 48000 || b.Channels != 1 || b.Format != "s16le" {
		t.Fatalf("defaults: %+v", b)
	}
	bad := []micStart{
		{Port: 0},
		{Port: 70000},
		{Port: 1739, Format: "f32le"},
		{Port: 1739, Rate: 4000},
		{Port: 1739, Rate: 192000},
		{Port: 1739, Channels: 6},
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

	if _, err := findScreenPlayer(has(), title); err == nil || !strings.Contains(err.Error(), "mpv") {
		t.Errorf("no player: %v", err)
	}
}

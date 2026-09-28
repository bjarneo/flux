package core

import (
	"slices"
	"testing"
)

func TestParseMonitors(t *testing.T) {
	got := parseMonitors("eDP-1|2880x1800\nDP-1|3840x2160\nbad line\nHDMI-A-1|0x0\n|1920x1080\n")
	want := []monitor{{"eDP-1", 2880, 1800}, {"DP-1", 3840, 2160}}
	if !slices.Equal(got, want) {
		t.Fatalf("monitors %+v, want %+v", got, want)
	}
}

func TestPickMonitor(t *testing.T) {
	ms := []monitor{{"eDP-1", 2880, 1800}, {"DP-1", 3840, 2160}}
	cases := []struct{ asked, focused, want string }{
		{"DP-1", "eDP-1", "DP-1"},
		{"", "DP-1", "DP-1"},
		{"HDMI-A-1", "", "eDP-1"},
		{"", "", "eDP-1"},
	}
	for _, c := range cases {
		if got := pickMonitor(ms, c.asked, c.focused); got.Name != c.want {
			t.Errorf("asked %q, focused %q: got %s, want %s", c.asked, c.focused, got.Name, c.want)
		}
	}
}

func TestStreamSize(t *testing.T) {
	cases := []struct{ w, h, limit, ww, wh int }{
		{2880, 1800, 1920, 1920, 1200},
		{3840, 2160, 1920, 1920, 1080},
		{1080, 1920, 1920, 1080, 1920},
		{1366, 768, 1920, 1366, 768},
		{3440, 1440, 1920, 1920, 802},
		{1921, 1081, 1920, 1920, 1080},
	}
	for _, c := range cases {
		w, h := streamSize(c.w, c.h, c.limit)
		if w != c.ww || h != c.wh {
			t.Errorf("%dx%d at %d: got %dx%d, want %dx%d", c.w, c.h, c.limit, w, h, c.ww, c.wh)
		}
	}
}

func TestDesktopLimit(t *testing.T) {
	for asked, want := range map[int]int{0: desktopSize, -5: desktopSize, 100: desktopMinSize, 2560: 2560, 9000: desktopMaxSize} {
		if got := desktopLimit(asked); got != want {
			t.Errorf("desktopLimit(%d) = %d, want %d", asked, got, want)
		}
	}
}

func TestDesktopArgs(t *testing.T) {
	args := desktopArgs("DP-1", 1920, 1080)
	for _, want := range [][]string{
		{"-w", "DP-1"},
		{"-c", "flv"},
		{"-k", "h264"},
		{"-s", "1920x1080"},
		{"-bm", "qp"},
		{"-cursor", "yes"},
	} {
		i := slices.Index(args, want[0])
		if i < 0 || i+1 >= len(args) || args[i+1] != want[1] {
			t.Errorf("args %q do not have %q", args, want)
		}
	}
	// The stream goes to stdout, so no output file is set.
	if slices.Contains(args, "-o") {
		t.Errorf("args %q set an output file", args)
	}
}

func TestRecorderError(t *testing.T) {
	out := "gsr info: the monitor is connected\ngsr error: failed to create encoder\ngsr info: exiting\n"
	if got := recorderError(out); got != "gsr error: failed to create encoder" {
		t.Errorf("got %q", got)
	}
	if got := recorderError("only info\n"); got != "only info" {
		t.Errorf("got %q", got)
	}
}

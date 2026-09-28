package core

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

func TestParseMonitors(t *testing.T) {
	got := parseMonitors("eDP-1|2880x1800\nDP-1|3840x2160\nbad line\nHDMI-A-1|0x0\n|1920x1080\n")
	want := []monitor{{"eDP-1", 2880, 1800}, {"DP-1", 3840, 2160}}
	if !slices.Equal(got, want) {
		t.Fatalf("monitors %+v, want %+v", got, want)
	}
}

func TestWakeMonitors(t *testing.T) {
	wait, poll := desktopWakeWait, desktopWakePoll
	desktopWakeWait, desktopWakePoll = 100*time.Millisecond, time.Millisecond
	t.Cleanup(func() { desktopWakeWait, desktopWakePoll = wait, poll })
	on := []monitor{{"eDP-1", 2880, 1800}}
	off := errors.New("gpu-screen-recorder finds no monitor to capture")

	// lists returns off for the first n lists, then on.
	lists := func(n int) (func() ([]monitor, error), *int) {
		calls := 0
		return func() ([]monitor, error) {
			calls++
			if calls <= n {
				return nil, off
			}
			return on, nil
		}, &calls
	}

	t.Run("on", func(t *testing.T) {
		list, _ := lists(0)
		woke := false
		ms, err := wakeMonitors(t.Context(), list, func() error { woke = true; return nil })
		if err != nil || !slices.Equal(ms, on) || woke {
			t.Fatalf("got %+v, %v, woke %v; want the monitor and no wake", ms, err, woke)
		}
	})
	t.Run("off", func(t *testing.T) {
		list, calls := lists(3)
		woke := false
		ms, err := wakeMonitors(t.Context(), list, func() error { woke = true; return nil })
		if err != nil || !slices.Equal(ms, on) || !woke || *calls != 4 {
			t.Fatalf("got %+v, %v, woke %v, %d lists; want the monitor after 1 wake and 4 lists", ms, err, woke, *calls)
		}
	})
	t.Run("no wake", func(t *testing.T) {
		list, calls := lists(1)
		_, err := wakeMonitors(t.Context(), list, func() error { return errors.New("no hyprctl") })
		if err != off || *calls != 1 {
			t.Fatalf("got %v after %d lists, want %v after 1 list", err, *calls, off)
		}
	})
	t.Run("stays off", func(t *testing.T) {
		list, _ := lists(1 << 30)
		_, err := wakeMonitors(t.Context(), list, func() error { return nil })
		if err != off {
			t.Fatalf("got %v, want %v", err, off)
		}
	})
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
	if got := recorderError("gpu-screen-recorder", out); got != "gsr error: failed to create encoder" {
		t.Errorf("got %q", got)
	}
	if got := recorderError("gpu-screen-recorder", "only info\n"); got != "only info" {
		t.Errorf("got %q", got)
	}
	if got := recorderError("wf-recorder", ""); got != "wf-recorder exited" {
		t.Errorf("got %q", got)
	}
}

func TestCPURecorderArgs(t *testing.T) {
	args := cpuRecorderArgs("HEADLESS-1", 1280, 720)
	for _, want := range [][]string{
		{"-o", "HEADLESS-1"},
		{"-c", "libx264"},
		{"-x", "yuv420p"},
		{"-m", "flv"},
		{"-f", "pipe:1"},
		{"-F", "scale=1280:720"},
	} {
		i := slices.Index(args, want[0])
		if i < 0 || i+1 >= len(args) || args[i+1] != want[1] {
			t.Errorf("args %q do not have %q", args, want)
		}
	}
	// B-frames would delay each frame on the Mac or the phone.
	if !slices.Contains(args, "tune=zerolatency") {
		t.Errorf("args %q do not tune for latency", args)
	}
}

func TestParseHyprMonitors(t *testing.T) {
	out := []byte(`[
		{"name":"HEADLESS-1","width":1280,"height":720,"transform":0,"dpmsStatus":true,"disabled":false},
		{"name":"DP-1","width":2560,"height":1440,"transform":1,"dpmsStatus":true,"disabled":false},
		{"name":"DP-2","width":1920,"height":1080,"transform":0,"dpmsStatus":false,"disabled":false},
		{"name":"HDMI-A-1","width":1920,"height":1080,"transform":0,"dpmsStatus":true,"disabled":true}
	]`)
	got, err := parseHyprMonitors(out)
	want := []monitor{{"HEADLESS-1", 1280, 720}, {"DP-1", 1440, 2560}}
	if err != nil || !slices.Equal(got, want) {
		t.Fatalf("got %+v, %v; want %+v", got, err, want)
	}
	if _, err := parseHyprMonitors([]byte("not json")); err == nil {
		t.Fatal("got no error for output that is not JSON")
	}
}

// fakeTool writes an executable shell script and returns its path.
func fakeTool(t *testing.T, name, script string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestPickRecorder(t *testing.T) {
	supported := fakeTool(t, "gpu-screen-recorder", `echo "eDP-1|2880x1800"`)
	displaysOff := fakeTool(t, "gpu-screen-recorder", `exit 0`)
	// gpu-screen-recorder on nouveau: "unknown gpu vendor: Mesa", exit 22.
	unsupported := fakeTool(t, "gpu-screen-recorder", `echo "gsr error: unknown gpu vendor: Mesa" >&2; exit 22`)
	cpu := "/usr/bin/wf-recorder"
	missing := errors.New("not found")

	paths := func(gpu, cpuPath string) func(string) (string, error) {
		return func(name string) (string, error) {
			switch {
			case name == desktopRecorder && gpu != "":
				return gpu, nil
			case name == desktopCPURecorder && cpuPath != "":
				return cpuPath, nil
			}
			return "", missing
		}
	}
	cases := []struct {
		name, gpu, cpu, want string
	}{
		{"supported GPU", supported, cpu, desktopRecorder},
		{"displays off", displaysOff, cpu, desktopRecorder},
		{"unsupported GPU", unsupported, cpu, desktopCPURecorder},
		{"unsupported GPU without wf-recorder", unsupported, "", desktopRecorder},
		{"only wf-recorder", "", cpu, desktopCPURecorder},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec, err := pickRecorder(t.Context(), paths(c.gpu, c.cpu))
			if err != nil || rec.name != c.want {
				t.Fatalf("got %q, %v; want %q", rec.name, err, c.want)
			}
		})
	}
	t.Run("none", func(t *testing.T) {
		if _, err := pickRecorder(t.Context(), paths("", "")); err == nil {
			t.Fatal("got no error without a recorder")
		}
	})
}

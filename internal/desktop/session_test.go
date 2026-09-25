package desktop

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

type proc struct {
	ppid int
	comm string
	args []string
}

type fakeProcs map[int]proc

func (f fakeProcs) Info(pid int) (int, string, []string, bool) {
	p, ok := f[pid]
	return p.ppid, p.comm, p.args, ok
}

func (f fakeProcs) PIDs() []int {
	var out []int
	for pid := range f {
		out = append(out, pid)
	}
	return out
}

func writeLock(t *testing.T, dir, sig string, pid int, socket string) {
	t.Helper()
	d := filepath.Join(dir, "hypr", sig)
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	content := []byte(strconv.Itoa(pid) + "\n" + socket + "\n")
	if err := os.WriteFile(filepath.Join(d, "hyprland.lock"), content, 0o644); err != nil {
		t.Fatal(err)
	}
}

// A desktop that started a chain of nested Hyprland instances, as on the
// test laptop. The environment points at a nested instance.
func TestHyprlandSessionSkipsNestedInstances(t *testing.T) {
	dir := t.TempDir()
	writeLock(t, dir, "abc_1_1", 1704, "wayland-1")
	writeLock(t, dir, "abc_2_2", 1819, "wayland-2")
	writeLock(t, dir, "abc_3_3", 5372, "wayland-6")
	writeLock(t, dir, "abc_4_4", 6556, "wayland-7")
	writeLock(t, dir, "abc_5_5", 9999, "wayland-9") // stale: the process is gone
	procs := fakeProcs{
		1699: {1, "start-hyprland", nil},
		1704: {1699, "Hyprland", []string{"Hyprland"}},
		1819: {1704, "hyprland", []string{"/usr/bin/hyprland"}},
		4817: {1819, "hyprland", []string{"/usr/bin/hyprland"}},
		5372: {4817, "hyprland", []string{"/usr/bin/hyprland"}},
		6556: {5372, "hyprland", []string{"/usr/bin/hyprland"}},
		1843: {1704, "Xwayland", []string{"Xwayland", ":0", "-rootless"}},
		5988: {5372, "Xwayland", []string{"Xwayland", ":5", "-rootless"}},
	}
	s, ok := HyprlandSession(dir, procs)
	if !ok {
		t.Fatal("want the top instance")
	}
	if s.Wayland != "wayland-1" || s.Signature != "abc_1_1" || s.X11 != ":0" || s.PID != 1704 {
		t.Fatalf("session = %+v", s)
	}
}

func TestHyprlandSessionNeedsOneTopInstance(t *testing.T) {
	if _, ok := HyprlandSession(t.TempDir(), fakeProcs{}); ok {
		t.Fatal("no Hyprland must give no session")
	}
	dir := t.TempDir()
	writeLock(t, dir, "a", 10, "wayland-1")
	writeLock(t, dir, "b", 20, "wayland-2")
	procs := fakeProcs{10: {1, "Hyprland", nil}, 20: {1, "Hyprland", nil}}
	if _, ok := HyprlandSession(dir, procs); ok {
		t.Fatal("2 top instances must give no session, so fluxd keeps its environment")
	}
}

func TestUseSession(t *testing.T) {
	t.Setenv("WAYLAND_DISPLAY", "wayland-6")
	t.Setenv("HYPRLAND_INSTANCE_SIGNATURE", "nested")
	t.Setenv("DISPLAY", ":5")
	old, changed := UseSession(Session{Signature: "top", Wayland: "wayland-1", X11: ":0"})
	if !changed || old != "wayland-6" {
		t.Fatalf("changed=%v old=%q", changed, old)
	}
	if os.Getenv("WAYLAND_DISPLAY") != "wayland-1" || os.Getenv("HYPRLAND_INSTANCE_SIGNATURE") != "top" || os.Getenv("DISPLAY") != ":0" {
		t.Fatal("the variables must point at the top instance")
	}
	if _, changed := UseSession(Session{Signature: "top", Wayland: "wayland-1", X11: ":0"}); changed {
		t.Fatal("a second call must change nothing")
	}
}

func TestSystemProcsReadsThisProcess(t *testing.T) {
	ppid, comm, args, ok := SystemProcs{}.Info(os.Getpid())
	if !ok || ppid != os.Getppid() || comm == "" || len(args) == 0 {
		t.Fatalf("ppid=%d comm=%q args=%v ok=%v", ppid, comm, args, ok)
	}
}

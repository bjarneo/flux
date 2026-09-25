package desktop

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Session is the display of the desktop that the user sees.
type Session struct {
	// Signature is the HYPRLAND_INSTANCE_SIGNATURE of the instance.
	Signature string
	// Wayland is the WAYLAND_DISPLAY of the instance, such as wayland-1.
	Wayland string
	// X11 is the DISPLAY of its Xwayland, such as :0, or empty.
	X11 string
	PID int
}

// Procs reads processes. Tests give a fake.
type Procs interface {
	// Info returns the parent, the name, and the arguments of pid.
	Info(pid int) (ppid int, comm string, args []string, ok bool)
	// PIDs returns every process ID.
	PIDs() []int
}

// SystemProcs reads /proc.
type SystemProcs struct{}

func (SystemProcs) Info(pid int) (int, string, []string, bool) {
	stat, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return 0, "", nil, false
	}
	// The name is inside parentheses and can hold spaces, so parse from the
	// last ")".
	s := string(stat)
	open, close := strings.IndexByte(s, '('), strings.LastIndexByte(s, ')')
	if open < 0 || close < open {
		return 0, "", nil, false
	}
	fields := strings.Fields(s[close+1:])
	if len(fields) < 2 {
		return 0, "", nil, false
	}
	ppid, _ := strconv.Atoi(fields[1])
	var args []string
	if b, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline")); err == nil {
		args = strings.Split(strings.TrimRight(string(b), "\x00"), "\x00")
	}
	return ppid, s[open+1 : close], args, true
}

func (SystemProcs) PIDs() []int {
	entries, _ := os.ReadDir("/proc")
	var out []int
	for _, e := range entries {
		if pid, err := strconv.Atoi(e.Name()); err == nil {
			out = append(out, pid)
		}
	}
	return out
}

// HyprlandSession finds the Hyprland instance that the user sees. A
// Hyprland that another Hyprland started runs nested and has no screen of
// its own. When such an instance imports its environment into systemd, a
// service such as fluxd gets its display, and the windows of fluxd open
// where nobody sees them. The instance that the user sees is the top one:
// its parent is not a Hyprland. ok is false when there is no Hyprland, or
// when more than 1 top instance runs.
func HyprlandSession(runtimeDir string, procs Procs) (Session, bool) {
	locks, _ := filepath.Glob(filepath.Join(runtimeDir, "hypr", "*", "hyprland.lock"))
	type instance struct {
		sig, socket string
		pid         int
	}
	var all []instance
	pids := map[int]bool{}
	for _, lock := range locks {
		b, err := os.ReadFile(lock)
		if err != nil {
			continue
		}
		lines := strings.Fields(string(b))
		if len(lines) < 2 {
			continue
		}
		pid, err := strconv.Atoi(lines[0])
		if err != nil {
			continue
		}
		if _, _, _, alive := procs.Info(pid); !alive {
			continue
		}
		all = append(all, instance{sig: filepath.Base(filepath.Dir(lock)), socket: lines[1], pid: pid})
		pids[pid] = true
	}
	var top []instance
	for _, in := range all {
		ppid, _, _, _ := procs.Info(in.pid)
		_, pcomm, _, _ := procs.Info(ppid)
		if pids[ppid] || strings.EqualFold(pcomm, "hyprland") {
			continue
		}
		top = append(top, in)
	}
	if len(top) != 1 {
		return Session{}, false
	}
	s := Session{Signature: top[0].sig, Wayland: top[0].socket, PID: top[0].pid}
	// The Xwayland of the instance is its child.
	var displays []string
	for _, pid := range procs.PIDs() {
		ppid, comm, args, ok := procs.Info(pid)
		if !ok || ppid != s.PID || comm != "Xwayland" {
			continue
		}
		for _, a := range args[1:] {
			if strings.HasPrefix(a, ":") {
				displays = append(displays, a)
				break
			}
		}
	}
	sort.Strings(displays)
	if len(displays) > 0 {
		s.X11 = displays[0]
	}
	return s, true
}

// UseSession points the display variables of this process at s, so that
// every program that fluxd starts opens on the desktop that the user sees.
// It returns the old WAYLAND_DISPLAY when it changed a variable.
func UseSession(s Session) (old string, changed bool) {
	old = os.Getenv("WAYLAND_DISPLAY")
	set := func(key, value string) {
		if value != "" && os.Getenv(key) != value {
			os.Setenv(key, value)
			changed = true
		}
	}
	set("WAYLAND_DISPLAY", s.Wayland)
	set("HYPRLAND_INSTANCE_SIGNATURE", s.Signature)
	set("DISPLAY", s.X11)
	return old, changed
}

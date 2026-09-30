package desktop

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/godbus/dbus/v5"
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
		// The arguments are empty when the process exits during the scan.
		if !ok || ppid != s.PID || comm != "Xwayland" || len(args) < 2 {
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

// lockWait is the longest time that 1 check of the lock state can take.
const lockWait = 2 * time.Second

// Locked reports whether the screen of the user is locked. 1 of 3 checks
// is enough: the LockedHint of the graphical logind session of the user, a
// running hyprlock, and a session lock that holds a monitor of Hyprland.
// The Omarchy lock screen sets no LockedHint and is not hyprlock, so only
// the last check finds it. omarchy-hyprland-session-locked reads the same
// value. A check that fails counts as unlocked.
func Locked(ctx context.Context) bool {
	return logindLocked(ctx) || procRuns(SystemProcs{}, "hyprlock") || hyprlandLocked(ctx)
}

// logindLocked reads the LockedHint of the graphical session of the user
// from logind on the system bus.
func logindLocked(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, lockWait)
	defer cancel()
	conn, err := dbus.SystemBus()
	if err != nil {
		return false
	}
	get := func(path dbus.ObjectPath, iface, prop string) (any, bool) {
		var v dbus.Variant
		err := conn.Object("org.freedesktop.login1", path).
			CallWithContext(ctx, "org.freedesktop.DBus.Properties.Get", 0, iface, prop).Store(&v)
		return v.Value(), err == nil
	}
	// Display is the graphical session of the user, as a session ID and
	// an object path.
	display, ok := get("/org/freedesktop/login1/user/self", "org.freedesktop.login1.User", "Display")
	if !ok {
		return false
	}
	fields, _ := display.([]any)
	if len(fields) != 2 {
		return false
	}
	path, _ := fields[1].(dbus.ObjectPath)
	if !path.IsValid() || path == "/" {
		return false
	}
	locked, ok := get(path, "org.freedesktop.login1.Session", "LockedHint")
	hint, _ := locked.(bool)
	return ok && hint
}

// procRuns reports whether a process with the name runs.
func procRuns(procs Procs, name string) bool {
	for _, pid := range procs.PIDs() {
		if _, comm, _, ok := procs.Info(pid); ok && comm == name {
			return true
		}
	}
	return false
}

// hyprlandLocked asks Hyprland whether a session lock holds a monitor.
func hyprlandLocked(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, lockWait)
	defer cancel()
	out, err := exec.CommandContext(ctx, "hyprctl", "-j", "monitors").Output()
	return err == nil && monitorsLocked(out)
}

// monitorsLocked reads the output of hyprctl -j monitors. An active
// ext-session-lock is 1 of the reasons in solitaryBlockedBy, as "LOCK".
func monitorsLocked(out []byte) bool {
	var ms []struct {
		Blocked []string `json:"solitaryBlockedBy"`
	}
	if json.Unmarshal(out, &ms) != nil {
		return false
	}
	for _, m := range ms {
		if slices.Contains(m.Blocked, "LOCK") {
			return true
		}
	}
	return false
}

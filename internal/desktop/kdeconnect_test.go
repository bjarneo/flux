package desktop

import (
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestKDEConnectPIDsFindsOnlyTheDaemon(t *testing.T) {
	procs := fakeProcs{10: {comm: "kdeconnectd"}, 11: {comm: "kdeconnect-app"}, 12: {comm: "fluxd"}, 13: {comm: "kdeconnectd"}}
	if got := KDEConnectPIDs(procs); !slices.Equal(got, []int{10, 13}) {
		t.Fatalf("pids: %v", got)
	}
	if got := KDEConnectPIDs(fakeProcs{12: {comm: "fluxd"}}); len(got) != 0 {
		t.Fatalf("pids without kdeconnectd: %v", got)
	}
}

// The autostart entry must hide the entry of the package with the same
// file name, and the D-Bus service must take the name of the package
// service, or kdeconnectd still starts at login or on demand.
func TestKDEConnectOverrides(t *testing.T) {
	files := KDEConnectOverrides("/home/u/.config", "/home/u/.local/share")
	if len(files) != 2 {
		t.Fatalf("files: %v", files)
	}
	autostart, dbus := files[0], files[1]
	if autostart.Path != filepath.Join("/home/u/.config", "autostart", "org.kde.kdeconnect.daemon.desktop") {
		t.Errorf("autostart path: %s", autostart.Path)
	}
	if !strings.Contains(autostart.Content, "\nHidden=true\n") {
		t.Errorf("autostart content:\n%s", autostart.Content)
	}
	if dbus.Path != filepath.Join("/home/u/.local/share", "dbus-1", "services", "org.kde.kdeconnect.service") {
		t.Errorf("dbus path: %s", dbus.Path)
	}
	for _, line := range []string{"[D-BUS Service]", "Name=org.kde.kdeconnect", "Exec=/bin/false"} {
		if !strings.Contains(dbus.Content, "\n"+line+"\n") {
			t.Errorf("dbus content has no %q:\n%s", line, dbus.Content)
		}
	}
}

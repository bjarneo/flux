package desktop

import (
	"path/filepath"
	"slices"
)

// kdeconnectd listens on UDP port 1716 like fluxd, and it can take the
// identities that phones send to fluxd. It starts at login from an XDG
// autostart entry, and on demand when a program calls its D-Bus name. So a
// stopped kdeconnectd comes back, unless both ways are closed.
const kdeConnectDaemon = "kdeconnectd"

// File is a file that Flux writes into the home folder of the user.
type File struct {
	Path    string
	Content string
}

// KDEConnectPIDs returns the processes of kdeconnectd, in order.
func KDEConnectPIDs(procs Procs) []int {
	var pids []int
	for _, pid := range procs.PIDs() {
		if _, comm, _, ok := procs.Info(pid); ok && comm == kdeConnectDaemon {
			pids = append(pids, pid)
		}
	}
	slices.Sort(pids)
	return pids
}

// KDEConnectOverrides returns the user files that keep kdeconnectd from
// starting. The autostart entry has the file name of the entry of the
// package, so it hides that entry. The D-Bus service has the name of the
// service of the package, and the user folder comes first, so a call to
// that name runs /bin/false. Removing both files turns KDE Connect back on.
func KDEConnectOverrides(configHome, dataHome string) []File {
	return []File{
		{
			Path: filepath.Join(configHome, "autostart", "org.kde.kdeconnect.daemon.desktop"),
			Content: "# flux-cli setup wrote this file. kdeconnectd uses UDP port 1716 like fluxd.\n" +
				"# Remove the file to start KDE Connect at login again.\n" +
				"[Desktop Entry]\nType=Application\nName=KDE Connect\nHidden=true\n",
		},
		{
			Path: filepath.Join(dataHome, "dbus-1", "services", "org.kde.kdeconnect.service"),
			Content: "# flux-cli setup wrote this file. kdeconnectd uses UDP port 1716 like fluxd.\n" +
				"# Remove the file to let D-Bus start KDE Connect again.\n" +
				"[D-BUS Service]\nName=org.kde.kdeconnect\nExec=/bin/false\n",
		},
	}
}

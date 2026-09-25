package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"flux/internal/config"
	"golang.org/x/sys/unix"
)

// doctor checks the parts that Flux needs and prints a fix for each
// problem.
func doctor() {
	problems := 0
	check := func(ok bool, pass, fix string) {
		if ok {
			fmt.Println("✓", pass)
			return
		}
		problems++
		fmt.Println("✗", fix)
	}

	var s State
	err := callInto("state", nil, &s)
	check(err == nil, "fluxd is running",
		"fluxd is not running. Run: systemctl --user enable --now fluxd")
	if err == nil {
		check(s.Self.TCPPort > 0, fmt.Sprintf("fluxd listens on TCP %d", s.Self.TCPPort),
			"fluxd has no TCP port. Check: journalctl --user -u fluxd")
	}

	check(!running("kdeconnectd"), "kdeconnectd is not running",
		"kdeconnectd also uses ports 1714 to 1764. Stop it: pkill kdeconnectd")

	// Flux needs no open port. fluxd opens every connection, and mDNS
	// finds the phones. The default ufw rules let mDNS in.
	before, berr := os.ReadFile("/etc/ufw/before.rules")
	switch {
	case !active("ufw"):
		fmt.Println("✓ no firewall runs, so every route is open")
	case berr != nil:
		fmt.Println("? Cannot read /etc/ufw/before.rules. Flux needs its mDNS rule for 224.0.0.251 port 5353")
	default:
		check(strings.Contains(string(before), "224.0.0.251") && strings.Contains(string(before), "5353"),
			"ufw lets mDNS in, so fluxd finds phones with no open port",
			"ufw blocks mDNS, so fluxd cannot find phones. Restore the mDNS line in /etc/ufw/before.rules")
	}

	check(active("avahi-daemon"), "avahi-daemon runs, so fluxd can find phones with mDNS",
		"avahi-daemon is not running, so fluxd cannot find phones. Run: sudo systemctl enable --now avahi-daemon")

	// The phone as webcam needs ffmpeg and access to the v4l2loopback
	// control device. Both are optional.
	_, ffErr := exec.LookPath("ffmpeg")
	check(ffErr == nil, "ffmpeg is installed, so the phone can be a webcam",
		"The phone as webcam needs ffmpeg. Install it with: sudo pacman -S ffmpeg")
	switch {
	case unix.Access("/dev/v4l2loopback", unix.F_OK) != nil:
		check(false, "", "The phone as webcam needs v4l2loopback. Install v4l2loopback-dkms, then run: sudo modprobe v4l2loopback devices=0")
	default:
		check(unix.Access("/dev/v4l2loopback", unix.W_OK) == nil, "fluxd can add the Flux Camera device",
			"fluxd cannot add the Flux Camera device. Install /usr/lib/udev/rules.d/61-flux-v4l2loopback.rules, then run: sudo udevadm trigger /dev/v4l2loopback")
	}

	for _, bin := range []string{"wl-copy", "wl-paste", "pw-play", "xdg-open"} {
		_, lerr := exec.LookPath(bin)
		check(lerr == nil, bin+" is installed", bin+" is missing. Flux needs it for the clipboard, the ring sound, and opening files")
	}
	_, aerr := appPath()
	plugin := pluginInstalled()
	check(aerr == nil || plugin, "a Flux window is available: "+windowName(aerr == nil, plugin),
		"No Flux window is installed. Install flux-gui, or add the flux plugin to omarchy-shell")

	fmt.Println()
	fmt.Println("Config:", config.Path())
	fmt.Println("Data:  ", config.DataDir())
	if problems > 0 {
		fmt.Printf("%d problem(s) found\n", problems)
		os.Exit(1)
	}
}

func windowName(app, plugin bool) string {
	switch {
	case app && plugin:
		return "the flux plugin and flux-gui"
	case plugin:
		return "the flux plugin"
	}
	return "flux-gui"
}

func running(name string) bool {
	return exec.Command("pgrep", "-x", name).Run() == nil
}

func active(unit string) bool {
	return exec.Command("systemctl", "is-active", "--quiet", unit).Run() == nil
}

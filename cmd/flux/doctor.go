package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"flux/internal/config"
	"flux/internal/herdr"
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

	// Extra addresses reach a paired device outside the local network, for
	// example through Tailscale. A host name must resolve to be of use.
	if err == nil {
		tailscale := active("tailscaled")
		for _, d := range s.Devices {
			if !d.Paired {
				continue
			}
			if len(d.Addresses) == 0 && tailscale {
				fmt.Printf("- Tailscale runs. To reach %s away from this network, run: flux-cli --device %q addresses add HOST\n", d.Name, d.Name)
			}
			for _, a := range d.Addresses {
				if net.ParseIP(a) != nil {
					continue
				}
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				_, rerr := net.DefaultResolver.LookupHost(ctx, a)
				cancel()
				check(rerr == nil, fmt.Sprintf("%s resolves, so fluxd can reach %s through it", a, d.Name),
					fmt.Sprintf("%s does not resolve, so fluxd cannot reach %s through it. For a Tailscale name, check: tailscale status", a, d.Name))
			}
		}
	}

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

	// The phone as microphone needs pw-cat, and the screen mirror needs
	// mpv or ffplay. Both are optional.
	_, pwErr := exec.LookPath("pw-cat")
	check(pwErr == nil, "pw-cat is installed, so the phone can be a microphone",
		"The phone as microphone needs pw-cat. Install it with: sudo pacman -S pipewire")
	_, mpvErr := exec.LookPath("mpv")
	_, ffplayErr := exec.LookPath("ffplay")
	check(mpvErr == nil || ffplayErr == nil, "mpv or ffplay is installed, so the phone screen can show here",
		"The screen mirror needs mpv or ffplay. Install mpv with: sudo pacman -S mpv")
	_, wtypeErr := exec.LookPath("wtype")
	check(wtypeErr == nil, "wtype is installed, so the phone keyboard can type here",
		"The phone keyboard needs wtype. Install it with: sudo pacman -S wtype")
	// The remote desktop is optional. It shows this screen on the phone.
	// Without its capability, gsr-kms-server asks for a password at each
	// start of the stream.
	gsr, gsrErr := exec.LookPath("gpu-screen-recorder")
	check(gsrErr == nil, "gpu-screen-recorder is installed, so the phone can show this screen",
		"The remote desktop needs gpu-screen-recorder. Install it with: sudo pacman -S gpu-screen-recorder")
	if gsrErr == nil {
		kms := filepath.Join(filepath.Dir(gsr), "gsr-kms-server")
		_, capErr := unix.Getxattr(kms, "security.capability", make([]byte, 64))
		check(capErr == nil, "gsr-kms-server can capture the screen without a password",
			"gsr-kms-server has no cap_sys_admin, so each stream asks for a password. Run: sudo setcap cap_sys_admin+ep "+kms)
	}

	// herdr is optional. When it runs, the phone shows its agents.
	if _, err := exec.LookPath("herdr"); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		pong, perr := herdr.Ping(ctx, herdr.SocketPath())
		cancel()
		if perr != nil {
			fmt.Println("- herdr does not run. Start herdr to show its agents on the phone")
		} else {
			check(pong.Protocol >= herdr.MinProtocol, fmt.Sprintf("herdr %s runs, so the phone can show its agents", pong.Version),
				fmt.Sprintf("herdr %s uses API protocol %d, and Flux needs %d or newer. Run: herdr update", pong.Version, pong.Protocol, herdr.MinProtocol))
		}
	}

	for _, bin := range []string{"wl-copy", "wl-paste", "xdg-open"} {
		_, lerr := exec.LookPath(bin)
		check(lerr == nil, bin+" is installed", bin+" is missing. Flux needs it for the clipboard and to open files")
	}
	fmt.Println(shortName())

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

// shortName tells which program the short name flux runs. The package puts
// its flux link at the end of PATH, so another flux command, such as the
// one of fluxcd, comes first.
func shortName() string {
	p, err := exec.LookPath("flux")
	if err != nil {
		return "- The short name flux is not in PATH. Use flux-cli, or log in again after the install"
	}
	if real, err := filepath.EvalSymlinks(p); err == nil && filepath.Base(real) == "flux-cli" {
		return "✓ The short name flux runs flux-cli"
	}
	return fmt.Sprintf("- The short name flux runs %s, not flux-cli. Use flux-cli", p)
}

func running(name string) bool {
	return exec.Command("pgrep", "-x", name).Run() == nil
}

func active(unit string) bool {
	return exec.Command("systemctl", "is-active", "--quiet", unit).Run() == nil
}

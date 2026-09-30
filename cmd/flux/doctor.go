package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
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
	check(err == nil, "fluxd is running", notRunning(err))
	checkUnit(check)
	if err == nil {
		check(s.Self.TCPPort > 0, fmt.Sprintf("fluxd listens on TCP %d", s.Self.TCPPort),
			"fluxd has no TCP port. Check: journalctl --user -u fluxd")
		checkVersion(s, check)
	}

	// Phones send their identity to UDP port 1716. A second program on the
	// port can take the identities that fluxd needs.
	if others, err := udpHolders(discoveryPort); err != nil {
		fmt.Printf("? Cannot run ss, so Flux cannot check UDP port %d\n", discoveryPort)
	} else if len(others) == 0 {
		fmt.Printf("✓ no other program uses UDP port %d\n", discoveryPort)
	} else {
		for _, name := range others {
			fix := fmt.Sprintf("Stop it: pkill -x %s", name)
			if name == "" {
				name, fix = "a program of another user", fmt.Sprintf("Find it: sudo ss -ulnp 'sport = :%d'", discoveryPort)
			}
			check(false, "", fmt.Sprintf("%s also uses UDP port %d, so phones cannot always reach fluxd. %s", name, discoveryPort, fix))
		}
	}

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
	_, wfErr := exec.LookPath("wf-recorder")
	check(gsrErr == nil || wfErr == nil, "gpu-screen-recorder is installed, so the phone can show this screen",
		"The remote desktop needs gpu-screen-recorder. Install it with: sudo pacman -S gpu-screen-recorder")
	if wfErr == nil {
		fmt.Println("✓ wf-recorder is installed, so the remote desktop also works on a GPU that gpu-screen-recorder does not support")
	}
	if gsrErr == nil {
		kms := filepath.Join(filepath.Dir(gsr), "gsr-kms-server")
		_, capErr := unix.Getxattr(kms, "security.capability", make([]byte, 64))
		check(capErr == nil, "gsr-kms-server can capture the screen without a password",
			"gsr-kms-server has no cap_sys_admin, so each stream asks for a password. Run: sudo setcap cap_sys_admin+ep "+kms)
	}

	// herdr is optional. When it runs, the phone shows its agents.
	if _, err := exec.LookPath("herdr"); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		path := herdr.SocketPath()
		pong, perr := herdr.Ping(ctx, path)
		cancel()
		switch {
		case herdrDown(perr):
			fmt.Println("- herdr does not run. Start herdr to show its agents on the phone")
		case perr != nil:
			// For example, the socket belongs to another user.
			check(false, "", safe(fmt.Sprintf("The herdr socket %s does not work: %v", path, perr)))
		default:
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

// notRunning returns the fix for a fluxd that does not answer.
func notRunning(err error) string {
	if err == nil {
		return ""
	}
	if config.IsOff() {
		return "fluxd is off. To turn it on, run: flux-cli on"
	}
	if cerr := config.Check(); cerr != nil {
		return fmt.Sprintf("fluxd cannot start, because config.toml has an error: %v. Fix the file, then run: flux-cli on", cerr)
	}
	return fmt.Sprintf("fluxd does not answer: %v. To see why, run: journalctl --user -u fluxd -e", err)
}

// checkUnit checks the unit file that systemd loads for fluxd.service. A
// user unit from an earlier install hides the unit of the package, and
// its fluxd can be gone.
func checkUnit(check func(ok bool, pass, fix string)) {
	out, err := exec.Command("systemctl", "--user", "show", "-p", "FragmentPath", "-p", "ExecStart", "fluxd.service").Output()
	if err != nil {
		fmt.Println("? Cannot ask systemd which fluxd.service it loads")
		return
	}
	props := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			props[k] = v
		}
	}
	frag := props["FragmentPath"]
	if frag == "" {
		check(false, "", "fluxd.service is not installed. Run: flux-cli setup")
		return
	}
	if _, err := os.Stat(systemUnit); err == nil && frag != systemUnit {
		fix := fmt.Sprintf("%s hides %s, so the service does not run the fluxd of the package. ", frag, systemUnit)
		if b, err := os.ReadFile(frag); err == nil && setupWrote(string(b)) {
			fix += "To remove it, run: flux-cli setup"
		} else {
			fix += "Remove it, then run: systemctl --user daemon-reload"
		}
		check(false, "", fix)
	}
	if path := execPath(props["ExecStart"]); path != "" {
		_, serr := os.Stat(path)
		check(serr == nil, "fluxd.service runs "+path,
			fmt.Sprintf("fluxd.service runs %s, which does not exist. Run: flux-cli setup", path))
	}
}

// execPath returns the program of an ExecStart value of systemctl show,
// such as "{ path=/usr/bin/fluxd ; argv[]=/usr/bin/fluxd ; ... }".
func execPath(v string) string {
	_, rest, ok := strings.Cut(v, "path=")
	if !ok {
		return ""
	}
	path, _, _ := strings.Cut(rest, " ;")
	return strings.TrimSpace(path)
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

// discoveryPort is the UDP port that fluxd listens on for identities.
const discoveryPort = 1716

// udpHolders returns the programs other than fluxd that listen on the UDP
// port. The name of a program of another user is empty, because ss shows
// only the sockets of this user.
func udpHolders(port int) ([]string, error) {
	out, err := exec.Command("ss", "-Hulnp", fmt.Sprintf("sport = :%d", port)).Output()
	if err != nil {
		return nil, err
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		name := ""
		if _, rest, ok := strings.Cut(line, `users:(("`); ok {
			name, _, _ = strings.Cut(rest, `"`)
		}
		if name != "fluxd" && !slices.Contains(names, name) {
			names = append(names, name)
		}
	}
	return names, nil
}

func active(unit string) bool {
	return exec.Command("systemctl", "is-active", "--quiet", unit).Run() == nil
}

// herdrDown reports whether err is a plain connection failure to the
// herdr socket: the socket does not exist, or nothing listens on it.
func herdrDown(err error) bool {
	return errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED)
}

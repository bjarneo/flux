// Command flux-cli is the command line client of fluxd. It also opens the
// Flux window. The package installs the short name flux too, when no other
// program uses it.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"

	"flux/internal/config"
	"flux/internal/ipc"
	"flux/internal/proto"
)

var version = "dev"

const usage = `Usage: flux-cli [command] [--device NAME] [args]

Commands:
  open [page]            Open the Flux window: the omarchy-shell plugin when it is
                         enabled, else flux-gui. Pages: overview, clipboard, files,
                         notifications, messages, commands
  status [--json]        Show this computer and the known devices
  discover               Broadcast this computer on the network now
  pair DEVICE            Ask a device to pair, show the verification key, and
                         ask you to confirm it
  accept DEVICE [KEY]    Accept a pair request, or confirm a pairing that the
                         device accepted. With KEY, only the pairing with that key.
                         Without KEY, show the key and ask you to compare it
  reject DEVICE [KEY]    Reject a pair request or a pairing. With KEY, only the
                         pairing with that key
  unpair DEVICE          Remove a paired device
  addresses              List the extra addresses of the paired devices
  addresses add HOST     Add a host name or IP address, for example the Tailscale
                         name of the phone. fluxd tries it while the device is offline
  addresses remove HOST  Remove an extra address
  ring                   Ring the phone
  ping [MESSAGE]         Send a ping
  send FILE...           Send files
  clip [TEXT]            Send the clipboard, or TEXT
  url URL                Open a URL on the phone
  sms NUMBER TEXT...     Send a text message through the phone
  notifications          List the phone notifications
  notifications clear    Dismiss the phone notifications, on the phone and here.
                         Ongoing notifications, such as a media player, stay
  notify TITLE [BODY]    Show a notification on the phone
  notify --run -- CMD…   Run CMD, then show on the phone how it ended. Exits with
                         the exit code of CMD. The phone gets only the program
                         name, unless you add --show-command
  commands               List the commands that the phone can run
  commands add NAME CMD  Add a command, for example: commands add "Lock" omarchy-system-lock
  commands remove ID     Remove a command
  run ID                 Run a command on this computer
  webcam [stop]          Show the phone camera state, or stop the phone camera
  webcam set KEY=VALUE…  Change the phone camera, for example: webcam set aspect=1:1 brightness=0.2
  webcam reset           Set the phone camera back to the neutral values
  mic [stop]             Show the phone microphone state, or stop the phone microphone
  screen [stop]          Show the phone screen mirror state, or stop the mirror
  desktop [stop]         Show whether a phone shows this screen, or stop it
  desktop on|off         Let a paired phone or Mac show this screen, or stop that
  browse [stop]          Show the devices that browse this computer, or stop them
  input [on|off]         Show whether a paired phone or Mac can move the pointer
                         and type on this computer, or turn that on or off
  approve [status]       Show whether a phone can approve sudo with a fingerprint
  approve setup [SVC…]   Enroll the phone and turn approval on for sudo, or for
                         polkit-1 and hyprlock. Run it with sudo.
  approve enroll         Enroll the phone only. Run it with sudo.
  approve enable [SVC…]  Turn approval on in PAM for an enrolled phone. Run it with sudo.
  approve disable [SVC…] Turn approval off in PAM. Run it with sudo.
  approve remove         Delete the phone key and turn approval off. Run it with sudo.
  watch                  Print each state change as one JSON line
  setup [--dry-run]      Start fluxd for this user and add the omarchy-shell plugin
  off                    Stop fluxd, and do not start it at login
  on                     Start fluxd, and start it at each login
  doctor                 Check the setup and print the fixes
  update [--check]       Install the latest release, or only check for it
  update --phone         Send the latest Flux for Android to the phone
  version                Print the versions of flux-cli and the running fluxd

Without --device, flux-cli uses the only connected paired device. Put
--device NAME before the command or right after it.
`

func main() {
	args, device := splitDevice(os.Args[1:])
	cmd := "open"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "open":
		err = openWindow(first(args))
	case "status", "devices":
		err = status(len(args) > 0 && args[0] == "--json")
	case "discover":
		err = call("discover", nil)
	case "pair":
		err = pair(need(args, "DEVICE"))
	case "accept":
		name := need(args, "DEVICE")
		err = accept(name, keyArg(args[1:]))
	case "reject":
		name := need(args, "DEVICE")
		err = reject(name, keyArg(args[1:]))
	case "unpair":
		err = unpair(need(args, "DEVICE"))
	case "addresses":
		err = addresses(device, args)
	case "ring":
		err = call("ring", map[string]any{"device": device})
	case "ping":
		err = call("ping", map[string]any{"device": device, "message": strings.Join(args, " ")})
	case "send":
		err = send(device, args)
	case "clip":
		err = call("clipboard.send", map[string]any{"device": device, "text": strings.Join(args, " ")})
	case "url":
		err = call("share.url", map[string]any{"device": device, "url": need(args, "URL")})
	case "sms":
		if len(args) < 2 {
			fail("Usage: flux-cli sms NUMBER TEXT...")
		}
		err = call("sms.send", map[string]any{"device": device, "addresses": []string{args[0]}, "body": strings.Join(args[1:], " ")})
	case "notifications":
		if first(args) == "clear" {
			err = clearNotifications(device)
		} else {
			err = notifications(device)
		}
	case "notify":
		err = notify(device, args)
	case "commands":
		err = commands(args)
	case "run":
		err = call("commands.run", map[string]any{"id": need(args, "ID")})
	case "webcam":
		err = webcam(args)
	case "mic":
		err = mic(args)
	case "screen":
		err = screen(args)
	case "desktop":
		err = remoteDesktop(args)
	case "browse":
		err = browse(args, device)
	case "input":
		err = remoteInput(args)
	case "approve":
		err = approveCmd(args, device)
	case "watch":
		err = watch()
	case "off":
		err = power(false)
	case "on":
		err = power(true)
	case "setup":
		err = setup(args)
	case "doctor":
		doctor()
	case "update":
		err = update(args, device)
	case "version", "--version":
		printVersion()
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "flux-cli: unknown command %q\n\n%s", cmd, usage)
		os.Exit(2)
	}
	if err != nil {
		fail("flux-cli: %v", err)
	}
}

// splitDevice removes --device NAME, -d NAME, and --device=NAME from the
// flags before the command and from the flags right after the command.
// It stops at the first other argument after the command and at --, so
// that free text, such as the command of `commands add` or the body of a
// text message, stays as it is.
func splitDevice(in []string) (out []string, device string) {
	command := false
	for i := 0; i < len(in); i++ {
		a := in[i]
		switch {
		case a == "--":
			return append(out, in[i:]...), device
		case (a == "--device" || a == "-d") && i+1 < len(in):
			device = in[i+1]
			i++
		case strings.HasPrefix(a, "--device="):
			device = strings.TrimPrefix(a, "--device=")
		case !command:
			out = append(out, a)
			command = true
		case strings.HasPrefix(a, "-"):
			// A flag of the command, such as --json or --run.
			out = append(out, a)
		default:
			return append(out, in[i:]...), device
		}
	}
	return out, device
}

func first(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	return ""
}

func need(args []string, name string) string {
	if len(args) == 0 || args[0] == "" {
		fail("flux-cli: give %s", name)
	}
	return args[0]
}

func fail(format string, args ...any) {
	// An error can have more than 1 line. safe cleans each line.
	lines := strings.Split(fmt.Sprintf(format, args...), "\n")
	for i := range lines {
		lines[i] = safe(lines[i])
	}
	fmt.Fprintln(os.Stderr, strings.Join(lines, "\n"))
	os.Exit(1)
}

func dial() (*ipc.Client, error) {
	path := config.SocketPath()
	c, err := ipc.Dial(path)
	switch {
	case err == nil:
		return c, nil
	case config.IsOff():
		return nil, errors.New("fluxd is off. To turn it on, run: flux-cli on")
	case errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.ECONNREFUSED):
		return nil, errors.New("fluxd does not run. To start it, run: flux-cli on. To find the cause, run: flux-cli doctor")
	default:
		return nil, fmt.Errorf("cannot connect to fluxd on %s: %w", path, err)
	}
}

func call(method string, params any) error { return callInto(method, params, nil) }

// callInto runs a method of fluxd and decodes the result into result. It
// replaces the control characters in the strings of the result and of an
// error, so that the callers can print them.
func callInto(method string, params, result any) error {
	c, err := dial()
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Call(method, params, result); err != nil {
		return cleanErr(err)
	}
	cleanAll(result)
	return nil
}

// State mirrors the parts of the fluxd state that the CLI prints.
type State struct {
	Self struct {
		ID             string `json:"id"`
		Name           string `json:"name"`
		Type           string `json:"type"`
		TCPPort        int    `json:"tcpPort"`
		Version        string `json:"version"`
		PendingVersion string `json:"pendingVersion"`
	} `json:"self"`
	Update struct {
		Enabled   bool   `json:"enabled"`
		Latest    string `json:"latest"`
		Available bool   `json:"available"`
		CheckedAt int64  `json:"checkedAt"`
		Error     string `json:"error"`
	} `json:"update"`
	Devices []struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		Type       string `json:"type"`
		IP         string `json:"ip"`
		Paired     bool   `json:"paired"`
		Online     bool   `json:"online"`
		PairState  string `json:"pairState"`
		PairKey    string `json:"pairKey"`
		App        string `json:"app"`
		AppVersion string `json:"appVersion"`
		AppUpdate  string `json:"appUpdate"`
		Battery    *struct {
			Charge   int  `json:"charge"`
			Charging bool `json:"charging"`
		} `json:"battery"`
		Addresses     []string `json:"addresses"`
		Notifications []struct {
			ID    string `json:"id"`
			App   string `json:"app"`
			Title string `json:"title"`
			Text  string `json:"text"`
		} `json:"notifications"`

		// Fingerprint is 16 hex digits from the certificate of the device,
		// or "".
		Fingerprint string `json:"fingerprint"`
	} `json:"devices"`
	Commands []config.Command `json:"commands"`
}

func status(asJSON bool) error {
	var raw json.RawMessage
	if err := callInto("state", nil, &raw); err != nil {
		return err
	}
	if asJSON {
		fmt.Println(string(safeJSON(raw)))
		return nil
	}
	var s State
	if err := json.Unmarshal(raw, &s); err != nil {
		return err
	}
	cleanAll(&s)
	printStatus(os.Stdout, &s)
	return nil
}

// printStatus writes this computer and the known devices to w. The line
// under each device has its ID and the fingerprint of its certificate, so
// that the user can give the ID when 2 devices have 1 name.
func printStatus(w io.Writer, s *State) {
	fmt.Fprintf(w, "%s (%s) · TCP %d\n", s.Self.Name, s.Self.Type, s.Self.TCPPort)
	if len(s.Devices) == 0 {
		fmt.Fprintln(w, "No devices. Open Flux on the phone, on the same network.")
		return
	}
	for _, d := range s.Devices {
		state := "offline"
		if d.Online {
			state = "connected"
		}
		pair := d.PairState
		if d.PairKey != "" {
			pair += " " + proto.FormatKey(d.PairKey)
		}
		bat := "—"
		if d.Battery != nil {
			bat = fmt.Sprintf("%d%%", d.Battery.Charge)
			if d.Battery.Charging {
				bat += " +"
			}
		}
		fmt.Fprintf(w, "  %-22s %-7s %-10s %-6s %-15s %s\n", d.Name, d.Type, state, bat, d.IP, pair)
		id := "ID " + d.ID
		if d.Fingerprint != "" {
			id += " · certificate " + proto.FormatKey(d.Fingerprint)
		}
		fmt.Fprintf(w, "  %-22s %s\n", "", id)
		if d.AppUpdate != "" {
			fmt.Fprintf(w, "  %-22s Flux for Android %s is available. To send it, run: flux-cli --device %s update --phone\n", "", d.AppUpdate, d.ID)
		}
	}
}

// pairResult is the answer of fluxd to pair.request, pair.accept, and
// pair.unpair: the device that the method acted on, the verification key
// of the pairing, and the fingerprint of the certificate of the device.
type pairResult struct {
	Device      string `json:"device"`
	Name        string `json:"name"`
	Key         string `json:"key"`
	Fingerprint string `json:"fingerprint"`
}

// pair asks a device to pair and waits for the answer. It follows the
// device ID that fluxd resolved, so another device with the same name
// cannot change the result. After the device accepts, the user of this
// computer confirms the key: at a prompt when stdin is a terminal, else
// with flux-cli accept.
func pair(device string) error {
	c, err := dial()
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Call("subscribe", nil, nil); err != nil {
		return cleanErr(err)
	}
	var res pairResult
	if err := c.Call("pair.request", map[string]any{"device": device}, &res); err != nil {
		return cleanErr(err)
	}
	cleanAll(&res)
	fmt.Printf("Confirm %s on %s (%s)…\n", proto.FormatKey(res.Key), res.Name, res.Device)
	var in io.Reader
	if isTerminal(os.Stdin) {
		in = os.Stdin
	}
	return waitPair(c, in, os.Stdout, res)
}

// pairClient is the part of ipc.Client that waitPair uses.
type pairClient interface {
	Call(method string, params, result any) error
	Events() <-chan ipc.Message
}

// waitPair follows the state of the device of res until the pairing ends.
// After the device accepts, it asks on in whether the device shows the
// key. It follows the state also while the question waits for an answer,
// so the question ends when the pairing ends in another way: a confirm in
// the Flux window, a pair false, or the timeout of fluxd. When in is nil,
// waitPair prints the command that confirms the pairing, and returns.
func waitPair(c pairClient, in io.Reader, out io.Writer, res pairResult) error {
	key := proto.FormatKey(res.Key)
	requested := false
	// answer gets the answer to the question. It is nil until the question
	// shows.
	var answer chan bool
	// endLine ends the line of an open question before a message.
	endLine := func() {
		if answer != nil {
			fmt.Fprintln(out)
		}
	}
	// stop returns the error for a pairing that ended.
	stop := func(name string) error {
		endLine()
		if answer != nil {
			return fmt.Errorf("the pairing with %s ended before you answered", name)
		}
		return fmt.Errorf("%s did not pair", name)
	}
	for {
		var ev ipc.Message
		select {
		case yes := <-answer:
			return answerPair(c, out, res, yes)
		case m, ok := <-c.Events():
			if !ok {
				endLine()
				return errors.New("fluxd closed the connection")
			}
			ev = m
		}
		if ev.Event != "state" {
			continue
		}
		var s State
		if json.Unmarshal(ev.Data, &s) != nil {
			continue
		}
		cleanAll(&s)
		found := false
		for _, d := range s.Devices {
			if d.ID != res.Device {
				continue
			}
			found = true
			res.Name = d.Name
			switch {
			case d.Paired:
				endLine()
				fmt.Fprintf(out, "✓ %s (%s) paired with the key %s\n", d.Name, d.ID, key)
				return nil
			case d.PairState == "requested":
				requested = true
			case d.PairState == "confirm" && d.PairKey == res.Key:
				requested = true
				if answer == nil && in == nil {
					fmt.Fprintf(out, "%s accepted. Compare the key. When %s shows %s, run:\n  flux-cli accept %s %s\n", d.Name, d.Name, key, res.Device, key)
					return nil
				}
				if answer == nil {
					answer = ask(in, out, d.Name, key)
				}
			case requested:
				return stop(d.Name)
			}
		}
		// A device that is not paired leaves the state when its link ends.
		if requested && !found {
			return stop(res.Name)
		}
	}
}

// answerPair sends the answer of the user of this computer for the
// pairing with the key of res. It accepts the pairing when yes is true,
// and rejects it else.
func answerPair(c pairClient, out io.Writer, res pairResult, yes bool) error {
	params := map[string]any{"device": res.Device, "key": res.Key}
	if !yes {
		if err := c.Call("pair.reject", params, nil); err != nil {
			return cleanErr(err)
		}
		return fmt.Errorf("you rejected the pairing with %s", res.Name)
	}
	if err := c.Call("pair.accept", params, nil); err != nil {
		return cleanErr(err)
	}
	fmt.Fprintf(out, "✓ %s (%s) paired with the key %s\n", res.Name, res.Device, proto.FormatKey(res.Key))
	return nil
}

// ask asks whether the device shows the key, and reads the answer from in
// in the background. The channel gets true when the user answers y.
func ask(in io.Reader, out io.Writer, name, key string) chan bool {
	fmt.Fprintf(out, "Does %s show %s? [y/N] ", name, key)
	ch := make(chan bool, 1)
	go func() { ch <- sameKey(bufio.NewReader(in)) }()
	return ch
}

// sameKey reads the answer to the key question from in, and reports
// whether the user answered y.
func sameKey(in *bufio.Reader) bool {
	line, _ := in.ReadString('\n')
	switch strings.ToLower(strings.TrimSpace(line)) {
	case "y", "yes":
		return true
	}
	return false
}

// isTerminal reports whether f is a terminal.
func isTerminal(f *os.File) bool {
	_, err := unix.IoctlGetTermios(int(f.Fd()), unix.TCGETS)
	return err == nil
}

// accept accepts the pairing of a device and prints the device and the
// key that it accepted: a pair request of the device, or a pairing that
// this computer started and the device accepted. flux-cli always sends
// the key, so fluxd accepts only the pairing with that key. Without key,
// askAccept asks the user to compare the key of the open pairing first.
func accept(device, key string) error {
	if key == "" {
		c, err := dial()
		if err != nil {
			return err
		}
		defer c.Close()
		var in io.Reader
		if isTerminal(os.Stdin) {
			in = os.Stdin
		}
		return askAccept(c, in, os.Stdout, device)
	}
	device, key, err := pairingArgs("accept", device, key, false)
	if err != nil {
		return err
	}
	var res pairResult
	if err := callInto("pair.accept", map[string]any{"device": device, "key": key}, &res); err != nil {
		return err
	}
	fmt.Printf("✓ %s (%s) paired with the key %s\n", res.Name, res.Device, proto.FormatKey(res.Key))
	return nil
}

// askAccept shows the key of the open pairing of device from the state,
// and asks on in whether the device shows it. It sends that key with the
// answer: pair.accept on y, else pair.reject. So fluxd refuses the answer
// when another pairing opened after the question. When in is nil,
// askAccept accepts nothing and returns the command with the key.
func askAccept(c pairClient, in io.Reader, out io.Writer, device string) error {
	var s State
	if err := c.Call("state", nil, &s); err != nil {
		return cleanErr(err)
	}
	cleanAll(&s)
	id, key, err := findPairing(&s, device, false)
	if err != nil {
		return err
	}
	res := pairResult{Device: id, Name: id, Key: key}
	for _, d := range s.Devices {
		if d.ID == id {
			res.Name = d.Name
		}
	}
	shown := proto.FormatKey(key)
	if in == nil {
		return fmt.Errorf("compare the key first. When %s shows %s, run:\n  flux-cli accept %s %s", res.Name, shown, id, shown)
	}
	return answerPair(c, out, res, <-ask(in, out, res.Name, shown))
}

// reject rejects the pairing of a device: a pair request of the device, a
// pairing in state "confirm", or a request of this computer that the ID
// names. Like accept, it always sends the key.
func reject(device, key string) error {
	device, key, err := pairingArgs("reject", device, key, true)
	if err != nil {
		return err
	}
	return call("pair.reject", map[string]any{"device": device, "key": key})
}

// keyArg returns the KEY of flux-cli accept and flux-cli reject from the
// arguments after the device. The key can come in 1 argument or in
// groups, with or without spaces, and in lower case.
func keyArg(args []string) string {
	return strings.ToUpper(strings.Join(strings.Fields(strings.Join(args, " ")), ""))
}

// pairingArgs returns the device and the key that flux-cli cmd sends to
// fluxd. Without key, both come from the open pairing in the state. See
// openPairing for outgoing.
func pairingArgs(cmd, device, key string, outgoing bool) (string, string, error) {
	if key == "" {
		return openPairing(device, outgoing)
	}
	if !validKey(key) {
		return "", "", fmt.Errorf("a key has 16 hex digits, for example: flux-cli %s %s 5EE6 825F 974E D59A", cmd, device)
	}
	return device, key, nil
}

// openPairing returns the ID and the key of the open pairing of the
// device that the argument names. An exact device ID wins. A name matches
// without case, and only a device in state "incoming" or "confirm". When
// outgoing is true, an exact ID also finds a request of this computer in
// state "requested".
func openPairing(device string, outgoing bool) (id, key string, err error) {
	var s State
	if err := callInto("state", nil, &s); err != nil {
		return "", "", err
	}
	return findPairing(&s, device, outgoing)
}

// findPairing is openPairing for the state s.
func findPairing(s *State, device string, outgoing bool) (id, key string, err error) {
	var ids, keys []string
	for _, d := range s.Devices {
		open := d.PairState == "incoming" || d.PairState == "confirm"
		if d.ID == device {
			if !open && !(outgoing && d.PairState == "requested") {
				return "", "", fmt.Errorf("%s has no open pair request", d.Name)
			}
			return d.ID, d.PairKey, nil
		}
		if open && strings.EqualFold(d.Name, device) {
			ids, keys = append(ids, d.ID), append(keys, d.PairKey)
		}
	}
	switch len(ids) {
	case 0:
		return "", "", fmt.Errorf("no device named %q has an open pair request", device)
	case 1:
		return ids[0], keys[0], nil
	}
	sort.Strings(ids)
	return "", "", fmt.Errorf("%d devices are named %q: %s. Give the device ID", len(ids), device, strings.Join(ids, ", "))
}

// validKey reports whether key has 16 uppercase hex digits.
func validKey(key string) bool {
	if len(key) != 16 {
		return false
	}
	for _, r := range key {
		if !strings.ContainsRune("0123456789ABCDEF", r) {
			return false
		}
	}
	return true
}

// unpair removes a paired device and prints the device that it removed.
func unpair(device string) error {
	var res pairResult
	if err := callInto("pair.unpair", map[string]any{"device": device}, &res); err != nil {
		return err
	}
	fmt.Printf("Unpaired %s (%s), certificate %s\n", res.Name, res.Device, proto.FormatKey(res.Fingerprint))
	return nil
}

// addresses lists, adds, or removes the extra addresses of a paired
// device. fluxd dials them while the device is offline, for example
// through Tailscale.
func addresses(device string, args []string) error {
	switch first(args) {
	case "add", "remove", "rm":
		method, verb := "addresses.add", "Added"
		if args[0] != "add" {
			method, verb = "addresses.remove", "Removed"
		}
		var res struct {
			Device    string   `json:"device"`
			Address   string   `json:"address"`
			Addresses []string `json:"addresses"`
		}
		if err := callInto(method, map[string]any{"device": device, "address": need(args[1:], "HOST")}, &res); err != nil {
			return err
		}
		fmt.Printf("%s %s. Addresses of %s: %s\n", verb, res.Address, res.Device, joinOrNone(res.Addresses))
		return nil
	case "", "list":
	default:
		return fmt.Errorf("unknown addresses action %q. Use add, remove, or list", args[0])
	}
	var s State
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	shown, empty := 0, 0
	for _, d := range s.Devices {
		if !d.Paired || (device != "" && d.ID != device && !strings.EqualFold(d.Name, device)) {
			continue
		}
		shown++
		if len(d.Addresses) == 0 {
			empty++
		}
		fmt.Printf("  %-22s %s\n", d.Name, joinOrNone(d.Addresses))
	}
	switch {
	case shown == 0 && device != "":
		return fmt.Errorf("no paired device named %q", device)
	case shown == 0:
		fmt.Println("No paired devices. Pair a device on the local network first.")
	case empty > 0:
		fmt.Println("To add one, run: flux-cli --device NAME addresses add HOST")
	}
	return nil
}

func joinOrNone(list []string) string {
	if len(list) == 0 {
		return "none"
	}
	return strings.Join(list, ", ")
}

func send(device string, files []string) error {
	if len(files) == 0 {
		fail("Usage: flux-cli send FILE...")
	}
	paths := make([]string, 0, len(files))
	for _, f := range files {
		abs, err := filepath.Abs(f)
		if err != nil {
			return err
		}
		paths = append(paths, abs)
	}
	var res struct {
		Transfers []string `json:"transfers"`
	}
	if err := callInto("share.files", map[string]any{"device": device, "paths": paths}, &res); err != nil {
		return err
	}
	fmt.Printf("Sending %d file(s)\n", len(res.Transfers))
	return nil
}

func notifications(device string) error {
	var s State
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	for _, d := range s.Devices {
		if device != "" && d.ID != device && !strings.EqualFold(d.Name, device) {
			continue
		}
		if !d.Paired {
			continue
		}
		for _, n := range d.Notifications {
			fmt.Printf("%s · %s: %s %s\n", d.Name, n.App, n.Title, n.Text)
		}
	}
	return nil
}

func clearNotifications(device string) error {
	var res struct {
		Dismissed int `json:"dismissed"`
	}
	if err := callInto("notification.dismissAll", map[string]any{"device": device}, &res); err != nil {
		return err
	}
	if res.Dismissed == 1 {
		fmt.Println("Dismissed 1 notification")
	} else {
		fmt.Printf("Dismissed %d notifications\n", res.Dismissed)
	}
	return nil
}

func commands(args []string) error {
	switch first(args) {
	case "add":
		if len(args) < 3 {
			fail("Usage: flux-cli commands add NAME COMMAND...")
		}
		var res struct {
			ID string `json:"id"`
		}
		if err := callInto("commands.add", map[string]any{"name": args[1], "command": commandLine(args[2:])}, &res); err != nil {
			return err
		}
		fmt.Printf("Added %s with ID %s\n", args[1], res.ID)
		return nil
	case "remove", "rm":
		return call("commands.remove", map[string]any{"id": need(args[1:], "ID")})
	case "", "list":
	default:
		return fmt.Errorf("unknown commands action %q. Use add, remove, or list", args[0])
	}
	var s State
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	if len(s.Commands) == 0 {
		fmt.Println(`No commands. Add one: flux-cli commands add "Lock screen" omarchy-system-lock`)
		return nil
	}
	for _, c := range s.Commands {
		fmt.Printf("%-10s %-18s $ %s\n", c.ID, c.Name, c.Command)
	}
	return nil
}

// commandLine returns the shell command of `commands add`. 1 argument is
// the full command, for example "rsync -a src dst". More arguments are
// the words of the command, and each word keeps its spaces and special
// characters.
func commandLine(words []string) string {
	if len(words) == 1 {
		return words[0]
	}
	quoted := make([]string, len(words))
	for i, w := range words {
		quoted[i] = shellQuote(w)
	}
	return strings.Join(quoted, " ")
}

// shellQuote quotes a word for sh when it has characters that sh reads in
// a special way.
func shellQuote(w string) string {
	if w != "" && strings.Trim(w, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-") == "" {
		return w
	}
	return "'" + strings.ReplaceAll(w, "'", `'\''`) + "'"
}

func webcam(args []string) error {
	switch first(args) {
	case "stop":
		return call("webcam.stop", nil)
	case "reset":
		return call("webcam.config", map[string]any{"reset": true})
	case "set":
		cfg, err := webcamSettings(args[1:])
		if err != nil {
			return err
		}
		return call("webcam.config", map[string]any{"config": cfg})
	}
	var s struct {
		Webcam *struct {
			Active   bool           `json:"active"`
			Device   string         `json:"device"`
			Label    string         `json:"label"`
			FromName string         `json:"fromName"`
			Width    int            `json:"width"`
			Height   int            `json:"height"`
			FPS      int            `json:"fps"`
			Error    string         `json:"error"`
			Config   map[string]any `json:"config"`
		} `json:"webcam"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	w := s.Webcam
	switch {
	case w == nil:
		fmt.Println("No phone camera. Start it in Flux for Android: Camera, then Webcam.")
	case w.Error != "":
		fmt.Println("The phone camera failed:", w.Error)
	case w.Active:
		fmt.Printf("%s is live as %s on %s, %dx%d at %d fps\n", w.FromName, w.Label, w.Device, w.Width, w.Height, w.FPS)
	default:
		fmt.Printf("%s is starting as %s on %s\n", w.FromName, w.Label, w.Device)
	}
	if w != nil && len(w.Config) > 0 {
		keys := make([]string, 0, len(w.Config))
		for k := range w.Config {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			parts = append(parts, fmt.Sprintf("%s=%v", k, w.Config[k]))
		}
		fmt.Println("Settings:", strings.Join(parts, " "))
	}
	return nil
}

// webcamKeys are the settings that Flux for Android reads. The phone
// ignores other keys, so the CLI refuses them.
var webcamKeys = []string{"aspect", "resolution", "camera", "mirror", "zoom", "exposure", "whiteBalance", "brightness", "contrast", "saturation", "warmth"}

// maxWebcamNumber is the largest size of a webcam setting number that
// fluxd sends to the phone.
const maxWebcamNumber = 1 << 16

// webcamSettings turns KEY=VALUE arguments into a config object. true and
// false become booleans, numbers become numbers, and the rest stays text.
// A number must be finite and in the range that fluxd accepts. The
// resolution must be a whole number that is not negative.
func webcamSettings(args []string) (map[string]any, error) {
	if len(args) == 0 {
		return nil, errors.New("give at least 1 KEY=VALUE, for example: flux-cli webcam set aspect=16:9")
	}
	cfg := map[string]any{}
	for _, a := range args {
		k, v, ok := strings.Cut(a, "=")
		if !ok || k == "" {
			return nil, fmt.Errorf("%q is not KEY=VALUE", a)
		}
		if !slices.Contains(webcamKeys, k) {
			return nil, fmt.Errorf("%q is not a setting. Use one of: %s", k, strings.Join(webcamKeys, ", "))
		}
		switch {
		case v == "true" || v == "false":
			cfg[k] = v == "true"
		default:
			if n, err := strconv.ParseFloat(v, 64); err == nil {
				if math.IsNaN(n) || math.Abs(n) > maxWebcamNumber || (k == "resolution" && (n < 0 || n != math.Trunc(n))) {
					return nil, fmt.Errorf("%s=%s is out of range", k, v)
				}
				cfg[k] = n
			} else {
				cfg[k] = v
			}
		}
	}
	return cfg, nil
}

func watch() error {
	c, err := dial()
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Call("subscribe", nil, nil); err != nil {
		return cleanErr(err)
	}
	for ev := range c.Events() {
		b, _ := json.Marshal(ev)
		fmt.Println(string(safeJSON(b)))
	}
	// Ctrl+C ends the process, so the loop ends only when fluxd stops.
	return errors.New("fluxd closed the connection")
}

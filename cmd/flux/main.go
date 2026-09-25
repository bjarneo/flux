// Command flux is the command line client of fluxd. It also opens the Flux
// window.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"flux/internal/config"
	"flux/internal/ipc"
)

var version = "dev"

const usage = `Usage: flux [command] [--device NAME] [args]

Commands:
  open [page]            Open the Flux window: the omarchy-shell plugin when it is
                         enabled, else flux-gui. Pages: overview, clipboard, files,
                         notifications, media, messages, commands, input, browse
  status [--json]        Show this computer and the known devices
  discover               Broadcast this computer on the network now
  pair DEVICE            Ask a device to pair and show the verification key
  accept DEVICE          Accept a pair request
  reject DEVICE          Reject a pair request
  unpair DEVICE          Remove a paired device
  ring                   Ring the phone
  ping [MESSAGE]         Send a ping
  send FILE...           Send files
  clip [TEXT]            Send the clipboard, or TEXT
  url URL                Open a URL on the phone
  sms NUMBER TEXT...     Send a text message through the phone
  media ACTION           play-pause, play, pause, next, previous, or stop
  notifications          List the phone notifications
  commands               List the commands that the phone can run
  commands add NAME CMD  Add a command, for example: commands add "Lock" omarchy-system-lock
  commands remove ID     Remove a command
  run ID                 Run a command on this computer
  watch                  Print each state change as one JSON line
  doctor                 Check the setup and print the fixes
  version                Print the version

Without --device, flux uses the only connected paired device.
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
		err = call("pair.accept", map[string]any{"device": need(args, "DEVICE")})
	case "reject":
		err = call("pair.reject", map[string]any{"device": need(args, "DEVICE")})
	case "unpair":
		err = call("pair.unpair", map[string]any{"device": need(args, "DEVICE")})
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
			fail("Usage: flux sms NUMBER TEXT...")
		}
		err = call("sms.send", map[string]any{"device": device, "addresses": []string{args[0]}, "body": strings.Join(args[1:], " ")})
	case "media":
		err = media(device, need(args, "ACTION"))
	case "notifications":
		err = notifications(device)
	case "commands":
		err = commands(args)
	case "run":
		err = call("commands.run", map[string]any{"id": need(args, "ID")})
	case "watch":
		err = watch()
	case "doctor":
		doctor()
	case "version", "--version":
		fmt.Println("flux", version)
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "flux: unknown command %q\n\n%s", cmd, usage)
		os.Exit(2)
	}
	if err != nil {
		fail("flux: %v", err)
	}
}

// splitDevice removes --device NAME, -d NAME, and --device=NAME from args.
func splitDevice(in []string) (out []string, device string) {
	for i := 0; i < len(in); i++ {
		a := in[i]
		switch {
		case (a == "--device" || a == "-d") && i+1 < len(in):
			device = in[i+1]
			i++
		case strings.HasPrefix(a, "--device="):
			device = strings.TrimPrefix(a, "--device=")
		default:
			out = append(out, a)
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
		fail("flux: give %s", name)
	}
	return args[0]
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

func dial() (*ipc.Client, error) {
	c, err := ipc.Dial(config.SocketPath())
	if err != nil {
		return nil, errors.New("fluxd is not running. Start it with: systemctl --user enable --now fluxd")
	}
	return c, nil
}

func call(method string, params any) error { return callInto(method, params, nil) }

func callInto(method string, params, result any) error {
	c, err := dial()
	if err != nil {
		return err
	}
	defer c.Close()
	return c.Call(method, params, result)
}

// State mirrors the parts of the fluxd state that the CLI prints.
type State struct {
	Self struct {
		ID      string `json:"id"`
		Name    string `json:"name"`
		Type    string `json:"type"`
		TCPPort int    `json:"tcpPort"`
	} `json:"self"`
	Devices []struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		Type      string `json:"type"`
		IP        string `json:"ip"`
		Paired    bool   `json:"paired"`
		Online    bool   `json:"online"`
		PairState string `json:"pairState"`
		PairKey   string `json:"pairKey"`
		Battery   *struct {
			Charge   int  `json:"charge"`
			Charging bool `json:"charging"`
		} `json:"battery"`
		Notifications []struct {
			ID    string `json:"id"`
			App   string `json:"app"`
			Title string `json:"title"`
			Text  string `json:"text"`
		} `json:"notifications"`
	} `json:"devices"`
	Commands []config.Command `json:"commands"`
}

func status(asJSON bool) error {
	var raw json.RawMessage
	if err := callInto("state", nil, &raw); err != nil {
		return err
	}
	if asJSON {
		fmt.Println(string(raw))
		return nil
	}
	var s State
	if err := json.Unmarshal(raw, &s); err != nil {
		return err
	}
	fmt.Printf("%s (%s) · TCP %d\n", s.Self.Name, s.Self.Type, s.Self.TCPPort)
	if len(s.Devices) == 0 {
		fmt.Println("No devices. Open Flux on the phone, on the same network.")
		return nil
	}
	for _, d := range s.Devices {
		state := "offline"
		if d.Online {
			state = "connected"
		}
		pair := d.PairState
		if d.PairKey != "" {
			pair += " " + d.PairKey
		}
		bat := "—"
		if d.Battery != nil {
			bat = fmt.Sprintf("%d%%", d.Battery.Charge)
			if d.Battery.Charging {
				bat += " +"
			}
		}
		fmt.Printf("  %-22s %-7s %-10s %-6s %-15s %s\n", d.Name, d.Type, state, bat, d.IP, pair)
	}
	return nil
}

func pair(device string) error {
	c, err := dial()
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Call("subscribe", nil, nil); err != nil {
		return err
	}
	if err := c.Call("pair.request", map[string]any{"device": device}, nil); err != nil {
		return err
	}
	shown := false
	for ev := range c.Events() {
		if ev.Event != "state" {
			continue
		}
		var s State
		if json.Unmarshal(ev.Data, &s) != nil {
			continue
		}
		for _, d := range s.Devices {
			if d.ID != device && !strings.EqualFold(d.Name, device) {
				continue
			}
			switch {
			case d.Paired:
				fmt.Printf("✓ %s paired\n", d.Name)
				return nil
			case d.PairState == "requested" && !shown:
				fmt.Printf("Confirm %s on %s…\n", d.PairKey, d.Name)
				shown = true
			case d.PairState == "none" && shown:
				return fmt.Errorf("%s did not pair", d.Name)
			}
		}
	}
	return errors.New("fluxd closed the connection")
}

func send(device string, files []string) error {
	if len(files) == 0 {
		fail("Usage: flux send FILE...")
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

func media(device, action string) error {
	actions := map[string]string{
		"play-pause": "PlayPause", "play": "Play", "pause": "Pause",
		"next": "Next", "previous": "Previous", "prev": "Previous", "stop": "Stop",
	}
	a, ok := actions[action]
	if !ok {
		return fmt.Errorf("unknown media action %q", action)
	}
	return call("media.action", map[string]any{"device": device, "action": a})
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

func commands(args []string) error {
	switch first(args) {
	case "add":
		if len(args) < 3 {
			fail("Usage: flux commands add NAME COMMAND...")
		}
		var res struct {
			ID string `json:"id"`
		}
		if err := callInto("commands.add", map[string]any{"name": args[1], "command": strings.Join(args[2:], " ")}, &res); err != nil {
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
		fmt.Println(`No commands. Add one: flux commands add "Lock screen" omarchy-system-lock`)
		return nil
	}
	for _, c := range s.Commands {
		fmt.Printf("%-10s %-18s $ %s\n", c.ID, c.Name, c.Command)
	}
	return nil
}

func watch() error {
	c, err := dial()
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Call("subscribe", nil, nil); err != nil {
		return err
	}
	for ev := range c.Events() {
		b, _ := json.Marshal(ev)
		fmt.Println(string(b))
	}
	return nil
}

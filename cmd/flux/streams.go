package main

import (
	"fmt"
	"io"
	"os"
	"time"
)

// streamStart asks a device to start its camera or its microphone for this
// computer, or to play the audio of this computer. kind is "webcam", "mic",
// or "speaker", and args starts with "start". The device flag can also
// come after start. The device starts the stream only after its user taps
// start, so streamStart tells the user to confirm.
func streamStart(kind string, args []string, device string, out io.Writer) error {
	rest, named := splitDevice(args)
	if len(rest) > 1 {
		return fmt.Errorf("unknown argument %q. Usage: flux-cli %s start [--device NAME]", rest[1], kind)
	}
	if named != "" {
		device = named
	}
	var res struct {
		Device string `json:"device"`
		Name   string `json:"name"`
	}
	if err := callInto(kind+".start", map[string]any{"device": device}, &res); err != nil {
		return err
	}
	what := "start the webcam"
	switch kind {
	case "mic":
		what = "start the mic"
	case "speaker":
		what = "play the audio of this computer"
	}
	fmt.Fprintf(out, "Asked %s to %s. Confirm on %s.\n", res.Name, what, res.Name)
	return nil
}

// speakerState is the phone speaker in the state of fluxd.
type speakerState struct {
	Active    bool   `json:"active"`
	ToName    string `json:"toName"`
	Rate      int    `json:"rate"`
	Channels  int    `json:"channels"`
	Muted     string `json:"muted"`
	MuteError string `json:"muteError"`
	Error     string `json:"error"`
}

// speaker shows whether a phone plays the audio of this computer, asks the
// phone to start, or stops it.
func speaker(args []string, device string, out io.Writer) error {
	switch first(args) {
	case "start":
		return streamStart("speaker", args, device, out)
	case "stop":
		return call("speaker.stop", nil)
	case "":
	default:
		return fmt.Errorf("unknown argument %q. Usage: flux-cli speaker [start|stop]", first(args))
	}
	var s struct {
		Speaker *speakerState `json:"speaker"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	printSpeaker(out, s.Speaker)
	return nil
}

func printSpeaker(out io.Writer, v *speakerState) {
	switch {
	case v == nil:
		fmt.Fprintln(out, "No phone plays the audio of this computer. Start it in Flux for Android: Media, then Play on phone.")
		fmt.Fprintln(out, "To ask the phone from this computer, run: flux-cli speaker start")
	case v.Error != "":
		fmt.Fprintln(out, "The phone speaker failed:", safe(v.Error))
	case v.Active:
		fmt.Fprintf(out, "%s plays the audio of this computer, %d Hz, %s\n", safe(v.ToName), v.Rate, channelsName(v.Channels))
		if v.Muted != "" {
			fmt.Fprintf(out, "%s is muted until the stream stops.\n", safe(v.Muted))
		}
		if v.MuteError != "" {
			fmt.Fprintln(out, "The output of this computer is not muted:", safe(v.MuteError))
		}
		fmt.Fprintln(out, "Stop it with: flux-cli speaker stop")
	default:
		fmt.Fprintf(out, "%s starts to play the audio of this computer\n", safe(v.ToName))
	}
}

// mic shows the phone microphone state, asks the phone to start it, or
// stops it.
func mic(args []string, device string) error {
	switch first(args) {
	case "start":
		return streamStart("mic", args, device, os.Stdout)
	case "stop":
		return call("mic.stop", nil)
	}
	var s struct {
		Mic *struct {
			Active   bool   `json:"active"`
			Source   string `json:"source"`
			FromName string `json:"fromName"`
			Rate     int    `json:"rate"`
			Channels int    `json:"channels"`
			Error    string `json:"error"`
		} `json:"mic"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	m := s.Mic
	switch {
	case m == nil:
		fmt.Println("No phone microphone. Start it in Flux for Android: Microphone, then Start.")
		fmt.Println("To ask the phone from this computer, run: flux-cli mic start")
	case m.Error != "":
		fmt.Println("The phone microphone failed:", m.Error)
	case m.Active:
		fmt.Printf("%s is live as %s, %d Hz, %s\n", m.FromName, m.Source, m.Rate, channelsName(m.Channels))
	default:
		fmt.Printf("%s is starting as %s\n", m.FromName, m.Source)
	}
	return nil
}

func channelsName(n int) string {
	if n == 2 {
		return "stereo"
	}
	return "mono"
}

// remoteSettings holds the settings that give a paired device access to
// this computer.
type remoteSettings struct {
	RemoteDesktop bool `json:"remoteDesktop"`
	RemoteInput   bool `json:"remoteInput"`
}

// setRemote turns a remote setting on or off. fluxd saves the change in
// config.toml. setRemote returns the settings after the change.
func setRemote(key string, on bool) (remoteSettings, error) {
	var s struct {
		Settings remoteSettings `json:"settings"`
	}
	if err := call("settings.set", map[string]any{"key": key, "value": on}); err != nil {
		return s.Settings, err
	}
	err := callInto("state", nil, &s)
	return s.Settings, err
}

// remoteInput turns remote input on or off, or shows its state.
func remoteInput(args []string) error {
	switch first(args) {
	case "on":
		if _, err := setRemote("remoteInput", true); err != nil {
			return err
		}
		fmt.Println("Remote input is on. A paired phone or Mac can move the pointer and type on this computer.")
		return nil
	case "off":
		if _, err := setRemote("remoteInput", false); err != nil {
			return err
		}
		fmt.Println("Remote input is off.")
		return nil
	case "":
	default:
		return fmt.Errorf("unknown argument %q. Usage: flux-cli input [on|off]", first(args))
	}
	var s struct {
		Settings remoteSettings `json:"settings"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	if s.Settings.RemoteInput {
		fmt.Println("Remote input is on. Turn it off with: flux-cli input off")
	} else {
		fmt.Println("Remote input is off. Turn it on with: flux-cli input on")
	}
	return nil
}

// remoteDesktop turns the remote desktop on or off, shows whether a phone
// shows this screen, or stops it.
func remoteDesktop(args []string) error {
	switch first(args) {
	case "stop":
		return call("desktop.stop", nil)
	case "on":
		s, err := setRemote("remoteDesktop", true)
		if err != nil {
			return err
		}
		fmt.Println("The remote desktop is on. A paired phone or Mac can show this screen.")
		if !s.RemoteInput {
			fmt.Println("To also control this computer from it, run: flux-cli input on")
		}
		return nil
	case "off":
		if _, err := setRemote("remoteDesktop", false); err != nil {
			return err
		}
		fmt.Println("The remote desktop is off.")
		return nil
	case "":
	default:
		return fmt.Errorf("unknown argument %q. Usage: flux-cli desktop [on|off|stop]", first(args))
	}
	var s struct {
		Settings remoteSettings `json:"settings"`
		Desktop  *struct {
			Active  bool   `json:"active"`
			ToName  string `json:"toName"`
			Monitor string `json:"monitor"`
			Width   int    `json:"width"`
			Height  int    `json:"height"`
			Error   string `json:"error"`
			Extend  bool   `json:"extend"`
		} `json:"desktop"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	v := s.Desktop
	switch {
	case v != nil && v.Error != "":
		fmt.Println("The remote desktop failed:", v.Error)
	case v != nil && v.Active && v.Extend:
		fmt.Printf("%s extends this screen as the monitor %s, %dx%d. Stop it with: flux-cli desktop stop\n", v.ToName, v.Monitor, v.Width, v.Height)
	case v != nil && v.Active:
		fmt.Printf("%s shows %s, %dx%d. Stop it with: flux-cli desktop stop\n", v.ToName, v.Monitor, v.Width, v.Height)
	case v != nil && v.Extend:
		fmt.Printf("%s is starting the extended screen %s\n", v.ToName, v.Monitor)
	case v != nil:
		fmt.Printf("%s is starting the remote desktop of %s\n", v.ToName, v.Monitor)
	case !s.Settings.RemoteDesktop:
		fmt.Println("The remote desktop is off. Turn it on with: flux-cli desktop on")
	default:
		fmt.Println("No phone shows this screen. Start it in Flux for Android: Remote desktop or Extend screen.")
	}
	return nil
}

// screen shows the screen mirror state, or stops it.
func screen(args []string) error {
	if first(args) == "stop" {
		return call("screen.stop", nil)
	}
	var s struct {
		Screen *struct {
			Active   bool   `json:"active"`
			FromName string `json:"fromName"`
			Width    int    `json:"width"`
			Height   int    `json:"height"`
			Player   string `json:"player"`
			Error    string `json:"error"`
		} `json:"screen"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	v := s.Screen
	switch {
	case v == nil:
		fmt.Println("No phone screen. Start it in Flux for Android: Mirror screen.")
	case v.Error != "":
		fmt.Println("The screen mirror failed:", v.Error)
	case v.Active:
		fmt.Printf("%s shows its screen in %s, %dx%d\n", v.FromName, v.Player, v.Width, v.Height)
	default:
		fmt.Printf("%s is starting its screen mirror\n", v.FromName)
	}
	return nil
}

// browse lists the devices that browse this computer with Browse PC, or
// stops them. Without --device, stop ends every session.
func browse(args []string, device string) error {
	switch first(args) {
	case "stop":
		return call("browse.stop", map[string]any{"device": device})
	case "":
	default:
		return fmt.Errorf("unknown argument %q. Usage: flux-cli browse [stop]", first(args))
	}
	var s struct {
		Browse []struct {
			Name  string `json:"name"`
			Since int64  `json:"since"`
		} `json:"browse"`
	}
	if err := callInto("state", nil, &s); err != nil {
		return err
	}
	if len(s.Browse) == 0 {
		fmt.Println("No device browses this computer.")
		return nil
	}
	for _, b := range s.Browse {
		fmt.Printf("%s browses this computer since %s\n", safe(b.Name), time.Unix(b.Since, 0).Format("15:04"))
	}
	fmt.Println("Stop it with: flux-cli browse stop")
	return nil
}

// Command flux-native is the native messaging host of the Flux browser
// extension. Chromium, Firefox, Brave, Edge, and Zen start it, and the
// extension asks it to send a link to the phone.
//
// The host only answers the commands below. It never takes a fluxd method
// name from the browser, so a browser extension cannot reach a part of
// fluxd that Flux did not offer here.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"flux/internal/config"
	"flux/internal/ipc"
	"flux/internal/nativemsg"
)

func main() {
	if err := serve(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, nativemsg.Host+":", err)
		os.Exit(1)
	}
}

// request is one message from the extension.
type request struct {
	// Command is "devices" or "send".
	Command string `json:"command"`
	// Device is the phone name or device ID. Empty means the only
	// connected paired device.
	Device string `json:"device"`
	// URL is the link to send.
	URL string `json:"url"`
}

// device is one paired phone in the "devices" reply.
type device struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Online bool   `json:"online"`
}

// reply is one answer to the extension. A fluxd error keeps its code, so
// the extension can tell an offline phone from a missing one.
type reply struct {
	OK      bool       `json:"ok"`
	Devices []device   `json:"devices,omitempty"`
	Error   *ipc.Error `json:"error,omitempty"`
}

// maxURL is the longest URL that Flux sends. A longer one is a bug in the
// page, and cutting it would send a link that goes nowhere.
const maxURL = 8 << 10

// serve answers the messages of one browser until it closes the pipe. A
// message that the host cannot use gets an error reply, so that the
// extension can show the reason and the host stays up for the next one.
func serve(in io.Reader, out io.Writer) error {
	for {
		raw, err := nativemsg.Read(in)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		rep, err := handle(raw)
		if err != nil {
			rep = fail(err)
		}
		if err := nativemsg.Write(out, rep); err != nil {
			return err
		}
	}
}

// handle turns one message into one reply.
func handle(raw []byte) (reply, error) {
	var req request
	if err := json.Unmarshal(raw, &req); err != nil {
		return reply{}, fmt.Errorf("the message is not a Flux request: %v", err)
	}
	switch req.Command {
	case "devices":
		return devices()
	case "send":
		return send(req)
	case "":
		return reply{}, errors.New(`the message has no "command"`)
	}
	return reply{}, fmt.Errorf("unknown command %q", req.Command)
}

// devices lists the paired phones, so that the extension can show which one
// is connected and let the user pick one.
func devices() (reply, error) {
	var state struct {
		Devices []struct {
			ID     string `json:"id"`
			Name   string `json:"name"`
			Paired bool   `json:"paired"`
			Online bool   `json:"online"`
		} `json:"devices"`
	}
	if err := call("state", nil, &state); err != nil {
		return reply{}, err
	}
	found := []device{}
	for _, d := range state.Devices {
		if !d.Paired {
			continue
		}
		found = append(found, device{ID: d.ID, Name: d.Name, Online: d.Online})
	}
	return reply{OK: true, Devices: found}, nil
}

// send puts a link on the phone. It is the share that Flux for Android
// already handles: the link opens as an event.
func send(req request) (reply, error) {
	link := strings.TrimSpace(req.URL)
	if link == "" {
		return reply{}, errors.New("there is no link to send")
	}
	if len(req.URL) > maxURL {
		return reply{}, fmt.Errorf("the link is %d bytes, over the %d limit", len(req.URL), maxURL)
	}
	if err := call("share.url", map[string]any{"device": req.Device, "url": link}, nil); err != nil {
		return fail(err), nil
	}
	return reply{OK: true}, nil
}

// fail turns an error into the reply that the extension reads. A fluxd
// error keeps its code and message.
func fail(err error) reply {
	var e *ipc.Error
	if errors.As(err, &e) {
		return reply{Error: e}
	}
	return reply{Error: &ipc.Error{Code: "error", Message: err.Error()}}
}

func call(method string, params, result any) error {
	c, err := ipc.Dial(config.SocketPath())
	if err != nil {
		return errors.New("fluxd is not running. Start it with: systemctl --user enable --now fluxd")
	}
	defer c.Close()
	return c.Call(method, params, result)
}

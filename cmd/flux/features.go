package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

func transferCommand(args []string) error {
	if len(args) == 2 && (args[0] == "retry" || args[0] == "cancel") {
		return call("transfer."+args[0], map[string]any{"id": args[1]})
	}
	if len(args) != 0 {
		return fmt.Errorf("use: flux-cli transfers [retry ID|cancel ID]")
	}
	var state struct {
		Transfers []struct {
			ID, Name, State, Error string
			Done, Size             int64
		}
	}
	if err := callInto("state", nil, &state); err != nil {
		return err
	}
	for _, t := range state.Transfers {
		fmt.Printf("%s  %-9s %d/%d  %s  %s\n", t.ID, t.State, t.Done, t.Size, t.Name, t.Error)
	}
	return nil
}

func printCall(method string, params any) error {
	var result json.RawMessage
	if err := callInto(method, params, &result); err != nil {
		return err
	}
	fmt.Println(string(result))
	return nil
}

func snippetCommand(args []string) error {
	if len(args) == 0 {
		return printCall("clipboard.search", nil)
	}
	if args[0] == "search" {
		return printCall("clipboard.search", map[string]any{"text": strings.Join(args[1:], " ")})
	}
	if len(args) < 2 {
		return fmt.Errorf("give a clipboard entry ID")
	}
	p := map[string]any{"id": args[1]}
	switch args[0] {
	case "save":
		if len(args) > 2 {
			duration, err := time.ParseDuration(args[2])
			if err != nil || duration <= 0 {
				return fmt.Errorf("give a positive duration, such as 24h")
			}
			p["expires"] = time.Now().Add(duration).Unix()
		}
		return printCall("clipboard.pin", p)
	case "remove":
		return call("clipboard.unpin", p)
	case "copy":
		return call("clipboard.copy", p)
	}
	return fmt.Errorf("use snippets search, save, remove, or copy")
}

func printSetting(key string) error {
	var state struct{ Settings map[string]json.RawMessage }
	if err := callInto("state", nil, &state); err != nil {
		return err
	}
	value := state.Settings[key]
	if len(value) == 0 {
		value = json.RawMessage("[]")
	}
	fmt.Println(string(value))
	return nil
}

func automationCommand(device string, args []string) error {
	if len(args) == 0 {
		return printSetting("automationRules")
	}
	if len(args) == 2 && args[0] == "remove" {
		return call("automation.remove", map[string]any{"id": args[1]})
	}
	if len(args) < 3 || len(args) > 4 || args[0] != "add" {
		return fmt.Errorf("use: flux-cli automation add EVENT COMMAND_ID [BELOW]")
	}
	r := map[string]any{"event": args[1], "command": args[2]}
	if device != "" {
		var s State
		if err := callInto("state", nil, &s); err != nil {
			return err
		}
		for _, d := range s.Devices {
			if d.Paired && (d.ID == device || strings.EqualFold(d.Name, device)) {
				r["device"] = d.ID
				break
			}
		}
		if r["device"] == nil {
			return fmt.Errorf("no paired device named %q", device)
		}
	}
	if len(args) == 4 {
		below, err := strconv.Atoi(args[3])
		if err != nil {
			return err
		}
		r["below"] = below
	}
	return printCall("automation.add", map[string]any{"config": r})
}

func deviceSettingsCommand(device string, args []string) error {
	if len(args) == 0 {
		return printCall("device.settings", map[string]any{"device": device})
	}
	if len(args) != 2 {
		return fmt.Errorf("use: flux-cli --device NAME device-settings KEY true|false|inherit")
	}
	var value any
	if args[1] != "inherit" {
		b, err := strconv.ParseBool(args[1])
		if err != nil {
			return err
		}
		value = b
	}
	return call("device.settings.set", map[string]any{"device": device, "key": args[0], "value": value})
}

func notificationRulesCommand(device string, args []string) error {
	if len(args) == 0 {
		return printSetting("notificationRules")
	}
	if args[0] == "remove" && len(args) == 2 {
		return call("notification.rule.remove", map[string]any{"id": args[1]})
	}
	rule := map[string]any{"device": device}
	if device != "" {
		var s State
		if err := callInto("state", nil, &s); err != nil {
			return err
		}
		found := false
		for _, d := range s.Devices {
			if d.Paired && (d.ID == device || strings.EqualFold(d.Name, device)) {
				rule["device"], found = d.ID, true
				break
			}
		}
		if !found {
			return fmt.Errorf("no paired device named %q", device)
		}
	}
	switch {
	case args[0] == "add" && (len(args) == 3 || len(args) == 4):
		rule["app"], rule["mode"] = args[1], args[2]
		if len(args) == 4 {
			duration, err := time.ParseDuration(args[3])
			if err != nil || duration <= 0 {
				return fmt.Errorf("give a positive duration, such as 1h")
			}
			rule["until"] = time.Now().Add(duration).Unix()
		}
	case args[0] == "quiet" && len(args) == 3:
		rule["app"], rule["mode"], rule["start"], rule["end"] = "*", "silent", args[1], args[2]
	default:
		return fmt.Errorf("use notification-rules add APP MODE [DURATION], quiet START END, or remove ID")
	}
	return printCall("notification.rule.add", map[string]any{"config": rule})
}

package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"flux/internal/lan"
	"flux/internal/proto"
)

// The phone moves around Omarchy with flux.shortcuts. It asks for the key
// bindings of Hyprland and the workspaces, runs 1 of the bindings, or runs
// a fixed action such as "switch to workspace 3". fluxd runs a binding in
// Hyprland itself, not as keys, because the virtual keyboard of wtype has
// its own keymap: a binding such as SUPER + code:10 never matches it. Each
// action needs remote_input, like the keys.
//
// Hyprland 0.56 and later use a Lua configuration. Each binding then calls
// a Lua function, and hyprctl binds shows the dispatcher "__lua" with the
// registry reference of that function. fluxd calls a binding only by a
// reference that the current binding list holds.

// Shortcut is 1 key binding of Hyprland with a description.
type Shortcut struct {
	// Ref is the Lua registry reference of the binding. It changes when
	// Hyprland reads its configuration again.
	Ref string `json:"ref"`
	// Keys is the key combination, such as "SUPER SHIFT RETURN", with the
	// key name as Hyprland writes it. It is only the modifiers for a
	// binding to a key code.
	Keys        string `json:"keys"`
	Description string `json:"description"`
}

// Workspace is 1 normal workspace of Hyprland.
type Workspace struct {
	ID      int `json:"id"`
	Windows int `json:"windows"`
}

// hyprBind is 1 entry of hyprctl -j binds.
type hyprBind struct {
	Mouse          bool   `json:"mouse"`
	CatchAll       bool   `json:"catch_all"`
	HasDescription bool   `json:"has_description"`
	Modmask        uint32 `json:"modmask"`
	Submap         string `json:"submap"`
	Key            string `json:"key"`
	Description    string `json:"description"`
	Dispatcher     string `json:"dispatcher"`
	Arg            string `json:"arg"`
}

// Modifier bits of a Hyprland binding, in the order that a label shows them.
var hyprMods = []struct {
	bit  uint32
	name string
}{{64, "SUPER"}, {4, "CTRL"}, {8, "ALT"}, {1, "SHIFT"}}

var luaRef = regexp.MustCompile(`^[0-9]{1,9}$`)

// parseShortcuts returns the bindings that the phone can run: the key
// bindings with a description, 1 for each description, in the order of the
// configuration. It skips the mouse bindings and the bindings of a submap.
func parseShortcuts(data []byte) ([]Shortcut, error) {
	var binds []hyprBind
	if err := json.Unmarshal(data, &binds); err != nil {
		return nil, fmt.Errorf("read the Hyprland bindings: %w", err)
	}
	seen := map[string]bool{}
	out := []Shortcut{}
	for _, b := range binds {
		d := strings.TrimSpace(b.Description)
		if b.Mouse || b.CatchAll || !b.HasDescription || d == "" || b.Submap != "" ||
			b.Dispatcher != "__lua" || !luaRef.MatchString(b.Arg) || seen[d] {
			continue
		}
		seen[d] = true
		var keys []string
		for _, m := range hyprMods {
			if b.Modmask&m.bit != 0 {
				keys = append(keys, m.name)
			}
		}
		if b.Key != "" {
			keys = append(keys, b.Key)
		}
		out = append(out, Shortcut{Ref: b.Arg, Keys: strings.Join(keys, " "), Description: d})
	}
	return out, nil
}

// parseWorkspaces returns the normal workspaces, without the special ones.
func parseWorkspaces(data []byte) ([]Workspace, error) {
	var all []struct {
		ID      int `json:"id"`
		Windows int `json:"windows"`
	}
	if err := json.Unmarshal(data, &all); err != nil {
		return nil, fmt.Errorf("read the workspaces: %w", err)
	}
	out := []Workspace{}
	for _, w := range all {
		if w.ID > 0 {
			out = append(out, Workspace{ID: w.ID, Windows: w.Windows})
		}
	}
	return out, nil
}

// shortcutBody is the body of flux.shortcuts from the phone.
type shortcutBody struct {
	Request   bool   `json:"request"`
	Run       string `json:"run"`
	Action    string `json:"action"`
	Workspace int    `json:"workspace"`
	Direction string `json:"direction"`
}

// fixedActions are the actions without a value, as Lua dispatchers. They
// are the dispatchers of the Omarchy bindings.
var fixedActions = map[string]string{
	"close":             `hl.dsp.window.close()`,
	"fullscreen":        `hl.dsp.window.fullscreen({ mode = "fullscreen" })`,
	"float":             `hl.dsp.window.float({ action = "toggle" })`,
	"split":             `hl.dsp.layout("togglesplit")`,
	"scratchpad":        `hl.dsp.workspace.toggle_special("scratchpad")`,
	"nextWindow":        `hl.dsp.window.cycle_next()`,
	"nextWorkspace":     `hl.dsp.focus({ workspace = "e+1" })`,
	"previousWorkspace": `hl.dsp.focus({ workspace = "e-1" })`,
}

var directions = map[string]bool{"l": true, "r": true, "u": true, "d": true}

// maxWorkspace is the highest workspace that the phone can select.
const maxWorkspace = 10

// actionLua returns the Lua dispatcher of an action from the phone. The
// values come from fixed text and checked numbers, never from the phone.
func actionLua(b shortcutBody) (string, error) {
	if lua, ok := fixedActions[b.Action]; ok {
		return lua, nil
	}
	switch b.Action {
	case "workspace", "moveToWorkspace":
		if b.Workspace < 1 || b.Workspace > maxWorkspace {
			return "", fmt.Errorf("workspace %d is not from 1 to %d", b.Workspace, maxWorkspace)
		}
		if b.Action == "workspace" {
			return fmt.Sprintf(`hl.dsp.focus({ workspace = "%d" })`, b.Workspace), nil
		}
		return fmt.Sprintf(`hl.dsp.window.move({ workspace = "%d" })`, b.Workspace), nil
	case "focus", "swap":
		if !directions[b.Direction] {
			return "", fmt.Errorf("the direction %q is not l, r, u, or d", b.Direction)
		}
		if b.Action == "focus" {
			return fmt.Sprintf(`hl.dsp.focus({ direction = "%s" })`, b.Direction), nil
		}
		return fmt.Sprintf(`hl.dsp.window.swap({ direction = "%s" })`, b.Direction), nil
	}
	return "", fmt.Errorf("the action %q is not known", b.Action)
}

// hyprctl runs hyprctl with args and returns its output. hyprctl reports a
// failed request on stdout, with the prefix "error".
func hyprctl(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "hyprctl", args...).Output()
	if errors.Is(err, exec.ErrNotFound) {
		return nil, errors.New("the shortcuts need Hyprland, and hyprctl is not installed")
	}
	if err != nil {
		return nil, fmt.Errorf("hyprctl %s: %w", args[0], err)
	}
	if msg := strings.TrimSpace(string(out)); strings.HasPrefix(strings.ToLower(msg), "error") {
		return nil, fmt.Errorf("hyprland: %s", msg)
	}
	return out, nil
}

func (d *Daemon) handleShortcuts(dev *Device, l *lan.Link, p *proto.Packet) {
	var b shortcutBody
	if p.Decode(&b) != nil {
		return
	}
	d.mu.Lock()
	on := d.cfg.RemoteInput && d.input != nil
	d.mu.Unlock()
	if !on {
		_ = l.Send(proto.New(proto.TypeFluxShortcuts, map[string]any{"error": "Remote input is off. Set remote_input = true in ~/.config/flux/config.toml, then run: systemctl --user reload fluxd"}))
		return
	}
	// hyprctl can wait, so the link goes on reading.
	go func() {
		if err := d.runShortcut(b); err != nil {
			d.logf("%s: shortcut: %v", dev.Name, err)
			_ = l.Send(proto.New(proto.TypeFluxShortcuts, map[string]any{"error": err.Error()}))
			return
		}
		body, err := d.shortcutState(b.Request)
		if err != nil {
			_ = l.Send(proto.New(proto.TypeFluxShortcuts, map[string]any{"error": err.Error()}))
			return
		}
		_ = l.Send(proto.New(proto.TypeFluxShortcuts, body))
	}()
}

// runShortcut runs the binding or the action of b. A request only runs
// nothing.
func (d *Daemon) runShortcut(b shortcutBody) error {
	ctx := d.ctx
	switch {
	case b.Run != "":
		if !luaRef.MatchString(b.Run) {
			return fmt.Errorf("the shortcut %q is not valid", b.Run)
		}
		data, err := hyprctl(ctx, "-j", "binds")
		if err != nil {
			return err
		}
		shortcuts, err := parseShortcuts(data)
		if err != nil {
			return err
		}
		found := false
		for _, s := range shortcuts {
			found = found || s.Ref == b.Run
		}
		if !found {
			return errors.New("the shortcut is gone. Hyprland read its configuration again")
		}
		_, err = hyprctl(ctx, "eval", "debug.getregistry()["+b.Run+"]()")
		return err
	case b.Action != "":
		lua, err := actionLua(b)
		if err != nil {
			return err
		}
		_, err = hyprctl(ctx, "dispatch", lua)
		return err
	}
	return nil
}

// shortcutState returns the workspaces and the active workspace. With
// list, it also returns the shortcuts.
func (d *Daemon) shortcutState(list bool) (map[string]any, error) {
	ctx := d.ctx
	body := map[string]any{}
	if list {
		data, err := hyprctl(ctx, "-j", "binds")
		if err != nil {
			return nil, err
		}
		shortcuts, err := parseShortcuts(data)
		if err != nil {
			return nil, err
		}
		body["shortcuts"] = shortcuts
	}
	data, err := hyprctl(ctx, "-j", "workspaces")
	if err != nil {
		return nil, err
	}
	workspaces, err := parseWorkspaces(data)
	if err != nil {
		return nil, err
	}
	body["workspaces"] = workspaces
	data, err = hyprctl(ctx, "-j", "activeworkspace")
	if err != nil {
		return nil, err
	}
	var active struct {
		ID int `json:"id"`
	}
	if err := json.Unmarshal(data, &active); err != nil {
		return nil, fmt.Errorf("read the active workspace: %w", err)
	}
	body["active"] = active.ID
	return body, nil
}

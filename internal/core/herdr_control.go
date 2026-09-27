package core

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode"

	"flux/internal/herdr"
	"flux/internal/proto"
)

// herdrReplyKeys are the key names that a phone can send to an agent.
// They answer the dialogs of an agent and move in its menus. ctrl+c is not
// in the list, because it can end the agent.
var herdrReplyKeys = map[string]bool{
	"enter": true, "esc": true, "tab": true, "shift+tab": true,
	"up": true, "down": true, "left": true, "right": true,
	"backspace": true, "space": true, "y": true, "n": true,
	"0": true, "1": true, "2": true, "3": true, "4": true,
	"5": true, "6": true, "7": true, "8": true, "9": true,
}

// Limits of a reply from a phone.
const (
	herdrMaxKeys   = 8
	herdrMaxPrompt = 16 << 10
)

// errHerdrControlOff is the reply when herdr_control is off.
const errHerdrControlOff = "Replies from the phone are off on this computer. Set herdr_control = true in ~/.config/flux/config.toml."

// herdrRefusal is a reply that fluxd refuses before it calls herdr. Its
// text goes to the phone.
type herdrRefusal string

func (r herdrRefusal) Error() string { return string(r) }

// herdrKeys sends key presses from a phone to an agent and returns the
// sent packet for the phone.
func (d *Daemon) herdrKeys(dev *Device, pane string, keys []string) *proto.Packet {
	return d.herdrReply(pane, "keys", func(ctx context.Context) error {
		if len(keys) == 0 || len(keys) > herdrMaxKeys {
			return herdrRefusal(fmt.Sprintf("Send 1 to %d keys", herdrMaxKeys))
		}
		for _, k := range keys {
			if !herdrReplyKeys[k] {
				return herdrRefusal(fmt.Sprintf("The key %q is not allowed", k))
			}
		}
		if err := herdr.SendKeys(ctx, d.herdrPath, pane, keys); err != nil {
			return err
		}
		d.logf("%s sent the keys %s to the herdr agent in %s", dev.Name, strings.Join(keys, " "), pane)
		return nil
	})
}

// herdrPrompt sends text from a phone to an agent and returns the sent
// packet for the phone. An agent that waits for an answer refuses a
// prompt. Then fluxd types the text and presses Enter, which answers a
// question that needs free text. The log gets the length, not the text.
func (d *Daemon) herdrPrompt(dev *Device, pane, text string) *proto.Packet {
	return d.herdrReply(pane, "prompt", func(ctx context.Context) error {
		text = cleanPrompt(text)
		switch {
		case text == "":
			return herdrRefusal("The text is empty")
		case len(text) > herdrMaxPrompt:
			return herdrRefusal(fmt.Sprintf("The text is longer than %d KB", herdrMaxPrompt>>10))
		}
		err := herdr.Prompt(ctx, d.herdrPath, pane, text)
		var he *herdr.Error
		if errors.As(err, &he) && he.Code == "agent_blocked" {
			// A line break in typed text is an Enter key, so the answer
			// goes on one line.
			err = herdr.SendInput(ctx, d.herdrPath, pane, strings.ReplaceAll(text, "\n", " "), []string{"enter"})
		}
		if err != nil {
			return err
		}
		d.logf("%s sent %d characters to the herdr agent in %s", dev.Name, len([]rune(text)), pane)
		return nil
	})
}

// herdrReply runs a reply from a phone after the checks that all replies
// share. send returns a herdrRefusal, a herdr error, or a connection
// error.
func (d *Daemon) herdrReply(pane, action string, send func(ctx context.Context) error) *proto.Packet {
	reply := map[string]any{"kind": "sent", "pane": pane, "action": action}
	d.mu.Lock()
	enabled, control := d.cfg.Herdr, d.cfg.HerdrControl
	known := slices.ContainsFunc(d.herdrAgents, func(a HerdrAgent) bool { return a.Pane == pane })
	d.mu.Unlock()
	switch {
	case !enabled:
		reply["error"] = "herdr sync is off on this computer"
	case !control:
		reply["error"] = errHerdrControlOff
	case !known:
		reply["error"] = fmt.Sprintf("No agent runs in %s", pane)
	default:
		ctx, cancel := context.WithTimeout(d.ctx, herdrReadTimeout)
		err := send(ctx)
		cancel()
		var refusal herdrRefusal
		switch {
		case err == nil:
		case errors.As(err, &refusal):
			reply["error"] = string(refusal)
		default:
			reply["error"] = herdrError(pane, err)
		}
	}
	return proto.New(proto.TypeFluxHerdr, reply)
}

// cleanPrompt removes control characters except line breaks and tabs, and
// the blanks at the start and end. A terminal can read a control
// character as a key.
func cleanPrompt(text string) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.Map(func(r rune) rune {
		if r != '\n' && r != '\t' && unicode.IsControl(r) {
			return -1
		}
		return r
	}, text)
	return strings.TrimSpace(text)
}

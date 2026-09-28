package core

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
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

// herdrTerminalKeys are the key names that a phone can send to a
// terminal. The phone has a shell there, so Ctrl and a letter are allowed,
// for example ctrl+c to stop a command.
var herdrTerminalKeys = func() map[string]bool {
	keys := map[string]bool{
		"enter": true, "esc": true, "tab": true, "shift+tab": true,
		"up": true, "down": true, "left": true, "right": true,
		"backspace": true, "space": true,
	}
	for c := 'a'; c <= 'z'; c++ {
		keys["ctrl+"+string(c)] = true
	}
	return keys
}()

// Limits of a reply from a phone.
const (
	herdrMaxKeys   = 8
	herdrMaxPrompt = 16 << 10
)

// herdrStartTimeout limits the start of an agent: the shell prompt of the
// new pane, the agent command, and the detection of the agent.
const herdrStartTimeout = 45 * time.Second

// herdrFindTimeout is how long fluxd waits for herdr to find a new agent.
const herdrFindTimeout = 30 * time.Second

// herdrStateWait is how long fluxd waits for a new pane in its state.
const herdrStateWait = 3 * time.Second

// errHerdrControlOff is the reply when herdr_control is off.
const errHerdrControlOff = "Replies from the phone are off on this computer. Set herdr_control = true in ~/.config/flux/config.toml."

// errHerdrTerminalsOff is the reply when herdr_terminals is off.
const errHerdrTerminalsOff = "Terminals from the phone are off on this computer. Set herdr_terminals = true in ~/.config/flux/config.toml."

// herdrRefusal is a reply that fluxd refuses before it calls herdr. Its
// text goes to the phone.
type herdrRefusal string

func (r herdrRefusal) Error() string { return string(r) }

// herdrKeys sends key presses from a phone to an agent and returns the
// sent packet for the phone.
func (d *Daemon) herdrKeys(dev *Device, pane string, keys []string) *proto.Packet {
	return d.herdrReply(pane, "keys", false, func(ctx context.Context) error {
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
	return d.herdrReply(pane, "prompt", false, func(ctx context.Context) error {
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

// herdrInput types text and then sends keys to a terminal, and returns
// the sent packet for the phone. The text goes on one line. The log gets
// the length of the text, not the text.
func (d *Daemon) herdrInput(dev *Device, pane, text string, keys []string) *proto.Packet {
	return d.herdrReply(pane, "input", true, func(ctx context.Context) error {
		text = strings.Map(func(r rune) rune {
			switch {
			case r == '\n' || r == '\t':
				return ' '
			case unicode.IsControl(r):
				return -1
			}
			return r
		}, strings.ReplaceAll(text, "\r\n", "\n"))
		switch {
		case text == "" && len(keys) == 0:
			return herdrRefusal("Send text or a key")
		case len(text) > herdrMaxPrompt:
			return herdrRefusal(fmt.Sprintf("The text is longer than %d KB", herdrMaxPrompt>>10))
		case len(keys) > herdrMaxKeys:
			return herdrRefusal(fmt.Sprintf("Send 0 to %d keys", herdrMaxKeys))
		}
		for _, k := range keys {
			if !herdrTerminalKeys[k] {
				return herdrRefusal(fmt.Sprintf("The key %q is not allowed", k))
			}
		}
		if err := herdr.SendInput(ctx, d.herdrPath, pane, text, keys); err != nil {
			return err
		}
		d.logf("%s sent %d characters and the keys %q to the herdr terminal %s", dev.Name, len([]rune(text)), strings.Join(keys, " "), pane)
		return nil
	})
}

// herdrReply runs a reply from a phone after the checks that all replies
// share. A reply to a terminal needs herdr_terminals and a pane without
// an agent. Another reply needs a pane with an agent. send returns a
// herdrRefusal, a herdr error, or a connection error.
func (d *Daemon) herdrReply(pane, action string, terminal bool, send func(ctx context.Context) error) *proto.Packet {
	reply := map[string]any{"kind": "sent", "pane": pane, "action": action}
	d.mu.Lock()
	enabled, control, terminals := d.cfg.Herdr, d.cfg.HerdrControl, d.herdrTerminalsLocked()
	known := d.herdrAgentLocked(pane)
	if terminal {
		known = d.herdrTerminalLocked(pane)
	}
	d.mu.Unlock()
	switch {
	case !enabled:
		reply["error"] = "herdr sync is off on this computer"
	case !control:
		reply["error"] = errHerdrControlOff
	case terminal && !terminals:
		reply["error"] = errHerdrTerminalsOff
	case !known && terminal:
		reply["error"] = fmt.Sprintf("No terminal is in %s", pane)
	case !known:
		reply["error"] = fmt.Sprintf("No agent runs in %s", pane)
	default:
		ctx, cancel := context.WithTimeout(d.ctx, herdrCallTimeout)
		err := send(ctx)
		cancel()
		if err != nil {
			reply["error"] = herdrReplyError(pane, err)
		}
	}
	return proto.New(proto.TypeFluxHerdr, reply)
}

// herdrReplyError returns the text for a phone about a failed reply.
func herdrReplyError(pane string, err error) string {
	var refusal herdrRefusal
	if errors.As(err, &refusal) {
		return string(refusal)
	}
	return herdrError(pane, err)
}

// herdrCreate opens a terminal or starts an agent for a phone, and returns
// the created packet for the phone. what is "agent" or "terminal". kind is
// the agent kind, such as claude. The pane opens in a new tab of the
// workspace, or in a new workspace when workspace is empty. cwd is the
// folder. An empty cwd is the home folder.
func (d *Daemon) herdrCreate(dev *Device, what, kind, cwd, workspace string) *proto.Packet {
	reply := map[string]any{"kind": "created", "what": what}
	d.mu.Lock()
	enabled, control, terminals := d.cfg.Herdr, d.cfg.HerdrControl, d.herdrTerminalsLocked()
	kindKnown := slices.Contains(d.herdrKinds, kind)
	placeKnown := workspace == "" || slices.ContainsFunc(d.herdrPlaces, func(w HerdrWorkspace) bool { return w.ID == workspace })
	d.mu.Unlock()
	var err error
	switch {
	case !enabled:
		err = herdrRefusal("herdr sync is off on this computer")
	case !control:
		err = herdrRefusal(errHerdrControlOff)
	case what == "terminal" && !terminals:
		err = herdrRefusal(errHerdrTerminalsOff)
	case what != "terminal" && what != "agent":
		err = herdrRefusal(fmt.Sprintf("Flux cannot open a %q", what))
	case what == "agent" && !kindKnown:
		err = herdrRefusal(fmt.Sprintf("herdr cannot start the agent %q on this computer", kind))
	case !placeKnown:
		err = herdrRefusal(fmt.Sprintf("The workspace %s is gone", workspace))
	}
	if err == nil {
		cwd, err = herdrDir(cwd)
	}
	var pane string
	if err == nil {
		ctx, cancel := context.WithTimeout(d.ctx, herdrStartTimeout)
		pane, err = d.openHerdrPane(ctx, what, kind, cwd, workspace)
		cancel()
	}
	if err != nil {
		reply["error"] = herdrReplyError(pane, err)
		return proto.New(proto.TypeFluxHerdr, reply)
	}
	if what == "agent" {
		d.logf("%s started the herdr agent %s in %s (%s)", dev.Name, kind, pane, cwd)
	} else {
		d.logf("%s opened the herdr terminal %s (%s)", dev.Name, pane, cwd)
	}
	d.waitHerdrPane(pane)
	reply["pane"] = pane
	return proto.New(proto.TypeFluxHerdr, reply)
}

// openHerdrPane opens a tab or a workspace, and starts the agent in its
// pane. When the agent does not start, it closes the pane again.
func (d *Daemon) openHerdrPane(ctx context.Context, what, kind, cwd, workspace string) (string, error) {
	var c herdr.Created
	var err error
	if workspace == "" {
		c, err = herdr.CreateWorkspace(ctx, d.herdrPath, cwd)
	} else {
		c, err = herdr.CreateTab(ctx, d.herdrPath, workspace, cwd)
	}
	if err != nil {
		return "", err
	}
	pane := c.RootPane.ID
	if pane == "" {
		return "", herdrRefusal("herdr did not report the new pane")
	}
	if what == "terminal" {
		return pane, nil
	}
	if err := d.startHerdrAgent(ctx, kind, pane, cwd); err != nil {
		// Close with a new context, because ctx can be at its end.
		cctx, cancel := context.WithTimeout(d.ctx, herdrCallTimeout)
		_ = herdr.ClosePane(cctx, d.herdrPath, pane)
		cancel()
		return pane, err
	}
	return pane, nil
}

// startHerdrAgent starts an agent in the shell of a new pane and waits
// until herdr finds it. A new shell needs a moment before its prompt
// shows, so fluxd tries again while herdr says that the pane is busy.
// When herdr does not find the agent, the error has the last line of the
// pane, such as "command not found".
func (d *Daemon) startHerdrAgent(ctx context.Context, kind, pane, cwd string) error {
	for try := 0; ; {
		err := herdr.StartAgent(ctx, d.herdrPath, agentName(kind, cwd, try), kind, pane)
		if err == nil {
			break
		}
		switch herdr.Code(err) {
		case "agent_pane_busy":
			if werr := sleepCtx(ctx, 250*time.Millisecond); werr != nil {
				return herdrRefusal("The shell of the new pane did not start")
			}
		case "agent_name_taken":
			if try++; try > 9 {
				return err
			}
		default:
			return err
		}
	}
	fctx, cancel := context.WithTimeout(ctx, herdrFindTimeout)
	defer cancel()
	for {
		a, err := herdr.GetAgent(fctx, d.herdrPath, pane)
		if err == nil && a.Agent != "" {
			return nil
		}
		if sleepCtx(fctx, 500*time.Millisecond) != nil {
			break
		}
	}
	msg := fmt.Sprintf("%s did not start", kind)
	rctx, rcancel := context.WithTimeout(d.ctx, herdrCallTimeout)
	defer rcancel()
	if r, err := herdr.ReadPane(rctx, d.herdrPath, pane, 20, false); err == nil {
		if line := strings.TrimSpace(lastLine(r.Text)); line != "" {
			msg += ": " + line
		}
	}
	return herdrRefusal(msg)
}

// waitHerdrPane makes the herdr loop read the session, and waits until
// the state has the pane or herdrStateWait passes.
func (d *Daemon) waitHerdrPane(pane string) {
	d.wakeHerdr()
	deadline := time.Now().Add(herdrStateWait)
	for time.Now().Before(deadline) {
		d.mu.Lock()
		known := d.herdrAgentLocked(pane) || d.herdrTerminalLocked(pane)
		d.mu.Unlock()
		if known {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// herdrClose closes the pane of an agent, or a terminal, for a phone, and
// returns the closed packet for the phone. The process in the pane ends.
func (d *Daemon) herdrClose(dev *Device, pane string) *proto.Packet {
	reply := map[string]any{"kind": "closed", "pane": pane}
	d.mu.Lock()
	enabled, control, terminals := d.cfg.Herdr, d.cfg.HerdrControl, d.herdrTerminalsLocked()
	agent := d.herdrAgentLocked(pane)
	terminal := terminals && d.herdrTerminalLocked(pane)
	d.mu.Unlock()
	switch {
	case !enabled:
		reply["error"] = "herdr sync is off on this computer"
	case !control:
		reply["error"] = errHerdrControlOff
	case !agent && !terminal:
		reply["error"] = fmt.Sprintf("No agent runs in %s", pane)
	default:
		ctx, cancel := context.WithTimeout(d.ctx, herdrCallTimeout)
		err := herdr.ClosePane(ctx, d.herdrPath, pane)
		cancel()
		if err != nil {
			reply["error"] = herdrError(pane, err)
			break
		}
		d.logf("%s closed the herdr pane %s", dev.Name, pane)
		d.wakeHerdr()
	}
	return proto.New(proto.TypeFluxHerdr, reply)
}

// herdrDir returns the absolute folder for a new pane. An empty folder
// and ~ are the home folder, and ~/ starts a path in it. The folder must
// exist.
func herdrDir(dir string) (string, error) {
	dir = strings.TrimSpace(dir)
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	switch {
	case dir == "" || dir == "~":
		dir = home
	case strings.HasPrefix(dir, "~/"):
		dir = filepath.Join(home, dir[2:])
	case !filepath.IsAbs(dir):
		return "", herdrRefusal(fmt.Sprintf("Give the folder as a full path or with ~/: %s", dir))
	}
	dir = filepath.Clean(dir)
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return "", herdrRefusal(fmt.Sprintf("The folder %s does not exist", dir))
	}
	return dir, nil
}

// agentName returns a name for a new agent from its kind and folder, such
// as claude-flux. herdr needs a unique name that matches
// [a-z][a-z0-9_-]{0,31}. try counts the names that herdr refused, so the
// second try gives claude-flux-2.
func agentName(kind, cwd string, try int) string {
	base := kind
	if p := filepath.Base(cwd); p != "" && p != "/" && p != "." {
		base += "-" + p
	}
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(base) {
		ok := r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_'
		switch {
		case ok:
			b.WriteRune(r)
			dash = false
		case !dash && b.Len() > 0:
			b.WriteByte('-')
			dash = true
		}
	}
	name := strings.TrimRight(b.String(), "-")
	if name == "" || name[0] < 'a' || name[0] > 'z' {
		name = "agent-" + name
	}
	suffix := ""
	if try > 0 {
		suffix = fmt.Sprintf("-%d", try+1)
	}
	if len(name)+len(suffix) > 32 {
		name = strings.TrimRight(name[:32-len(suffix)], "-")
	}
	return name + suffix
}

// sleepCtx waits for the delay or the end of ctx.
func sleepCtx(ctx context.Context, delay time.Duration) error {
	t := time.NewTimer(delay)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
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

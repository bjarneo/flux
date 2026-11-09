package core

// The herdr app runs its agents in herdr-core, not in the herdr server of
// the terminal app, so the two do not share agents. fluxd follows
// herdr-core as one more session, herdrAppSession, next to the herdr
// sessions. Its IDs are the terminal addresses of herdr-core after the
// session name, such as "herdr-app/t4", or "herdr-app/yoga/t1" for a
// terminal on another machine. herdrSplit cuts at the first slash, so
// the address stays whole.
//
// herdr-core knows no workspaces, layouts, or agent kinds, and it has no
// live terminal stream that the phone speaks. Its screens have colors only
// with the ansi option of terminal.read, which an older herdr-core lacks. The phone can see the
// agents and terminals, read them, answer them, and close them. It cannot
// start agents or open the live terminal there.

import (
	"context"
	"errors"
	"strings"
	"time"

	"flux/internal/hc"
	"flux/internal/herdr"
)

// herdrAppSession is the session name of the herdr app. A herdr session
// with the same name is not followed.
const herdrAppSession = "herdr-app"

// errHerdrAppCreate is the answer to a start in the herdr app.
const errHerdrAppCreate = "Flux cannot start agents or open terminals in the herdr app yet"

// errHerdrAppTerminal is the answer to a live terminal in the herdr app.
const errHerdrAppTerminal = "the live terminal does not work with the herdr app yet"

// herdrAppHistoryTimeout limits the history part of a read. The read of
// the screen alone then has the rest of herdrReadTimeout.
const herdrAppHistoryTimeout = 5 * time.Second

// herdrApp reports whether a qualified ID belongs to the herdr app.
func herdrApp(id string) bool { return herdrSessionOf(id) == herdrAppSession }

// herdrAppSessionFollow follows herdr-core until the connection fails or
// the user turns the feature off. herdr-core sends an event for each
// change of a terminal, and fluxd reads the terminals again after it.
func (d *Daemon) herdrAppSessionFollow(ctx context.Context, wake <-chan struct{}, logged *string) error {
	h, err := hc.Hi(ctx, d.hcPath)
	if err != nil {
		return err
	}
	d.logf("herdr app (herdr-core %s): following its agents", h.Version)
	*logged = ""

	s, err := hc.Subscribe(ctx, d.hcPath)
	if err != nil {
		return err
	}
	defer s.Close()
	events := make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() {
		for {
			method, err := s.Next()
			if err != nil {
				done <- err
				return
			}
			// A heartbeat changes nothing.
			if method == "heartbeat" {
				continue
			}
			select {
			case events <- struct{}{}:
			default:
			}
		}
	}()
	tick := time.NewTicker(herdrPoll)
	defer tick.Stop()
	for {
		terms, err := hc.List(ctx, d.hcPath)
		if err != nil {
			return err
		}
		d.setHerdrSession(ctx, herdrAppSession, true, qualifyHerdrLive(herdrAppSession, herdrAppLive(terms)))

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-wake:
			if !d.herdrEnabled() {
				return errHerdrOff
			}
		case err := <-done:
			return err
		case <-tick.C:
		case <-events:
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(herdrSettle):
			}
			select {
			case <-events:
			default:
			}
		}
	}
}

// herdrAppLive converts the live terminals of herdr-core for the phone. A
// terminal whose program reports a status with its app is an agent. The
// others are terminals.
func herdrAppLive(terms []hc.Terminal) herdrLive {
	var live herdrLive
	for _, t := range terms {
		if !t.Live() || t.Address == "" {
			continue
		}
		place := cleanLabel(herdrAppPlace(t))
		project := cleanLabel(projectName(t.Dir()))
		if t.Status != nil && t.Status.App != "" {
			title := t.Status.Title
			if title == "" {
				title = t.Title
			}
			live.Agents = append(live.Agents, HerdrAgent{
				Pane: t.Address, Agent: herdrAppKind(t.Status.App), Status: herdrAppStatus(t.Status.State),
				Title: cleanLabel(title), Project: project, Workspace: place,
			})
			continue
		}
		live.Terminals = append(live.Terminals, HerdrTerminal{
			Pane: t.Address, Title: cleanLabel(t.Title), Project: project, Workspace: place,
		})
	}
	return live
}

// herdrAppPlace returns the space of a terminal in the herdr app. The app
// labels each terminal with "where", the space and the tab number, such
// as "Work / 1". A terminal on another machine gets the machine name in
// front, such as "yoga: Work".
func herdrAppPlace(t hc.Terminal) string {
	place := t.Labels["where"]
	if i := strings.LastIndex(place, " / "); i >= 0 {
		place = place[:i]
	}
	if machine, _, ok := strings.Cut(t.Address, "/"); ok {
		if place == "" {
			return machine
		}
		return machine + ": " + place
	}
	return place
}

// herdrAppKind returns the agent kind of herdr for the app that reports a
// status, so the phone shows the same agent for both. herdr calls Claude
// Code claude.
func herdrAppKind(app string) string {
	if app == "claude-code" {
		return "claude"
	}
	return app
}

// herdrAppStatus returns the herdr status for a state word of herdr-core.
// A word that herdr does not know, such as error, is unknown.
func herdrAppStatus(state string) string {
	switch state {
	case herdr.StatusIdle, herdr.StatusWorking, herdr.StatusBlocked, herdr.StatusDone:
		return state
	}
	return herdr.StatusUnknown
}

// herdrAppAddress returns the herdr-core address of a qualified ID.
func herdrAppAddress(id string) string {
	_, raw := herdrSplit(id)
	return raw
}

// readHerdrApp reads the screen of a terminal in the herdr app with the
// history above it. herdr-core reads the history as plain text. For
// ansi, fluxd also reads the screen with its styles, when herdr-core can,
// and puts it under the plain history, as readAgentOutput does for herdr.
// An older herdr-core gives an ANSI read the plain text. readHerdrApp
// removes the sidebar of opencode, as readAgentOutput does.
func (d *Daemon) readHerdrApp(ctx context.Context, pane string, lines int, ansi bool) (string, bool, error) {
	addr := herdrAppAddress(pane)
	// herdr-core collects the history of a terminal on another machine
	// there, which a slow machine does not finish in time. The screen
	// alone comes fast, so a failed history read falls back to it.
	hctx, cancel := context.WithTimeout(ctx, herdrAppHistoryTimeout)
	r, err := hc.ReadTerminal(hctx, d.hcPath, addr, lines)
	cancel()
	if err != nil && ctx.Err() == nil && hc.Kind(err) != "not_found" && hc.Kind(err) != "finished" {
		r, err = hc.ReadTerminal(ctx, d.hcPath, addr, 0)
		r.Complete = false
	}
	if err != nil {
		return "", false, err
	}
	history := strings.Split(cleanPlain(r.Text), "\n")
	var screen []string
	if ansi {
		if s, err := hc.ReadScreenANSI(ctx, d.hcPath, addr); err == nil && s.How == "ansi" {
			screen = strings.Split(cleanANSI(s.Text), "\n")
		}
	}
	d.mu.Lock()
	kind := d.herdrKindLocked(pane)
	d.mu.Unlock()
	if kind == "opencode" {
		col := sidebarColumn(history, screen)
		history, screen = dropSidebar(history, col, false), dropSidebar(screen, col, true)
	}
	rows := history
	if screen != nil {
		rows = spliceScreen(history, screen)
	}
	truncated := !r.Complete
	if len(rows) > lines {
		rows, truncated = rows[len(rows)-lines:], true
	}
	return strings.Join(rows, "\n"), truncated, nil
}

// herdrAppPrompt sends text to an agent in the herdr app. herdr-core
// pastes it and presses Enter. It refuses a blocked agent, because the
// text would answer its dialog. With answer, the phone answers a question
// that needs free text, so fluxd checks that the agent still waits and
// sends the text on one line with force.
func (d *Daemon) herdrAppPrompt(ctx context.Context, pane, text string, answer bool) (string, error) {
	addr := herdrAppAddress(pane)
	err := hc.Send(ctx, d.hcPath, addr, text, false)
	if hc.Kind(err) != "blocked" {
		return "a prompt", err
	}
	if !answer {
		return "", errHerdrBlocked
	}
	t, err := hc.Get(ctx, d.hcPath, addr)
	if err != nil {
		return "", err
	}
	if t.Status == nil || t.Status.State != herdr.StatusBlocked {
		return "", herdrRefusal("The agent does not wait for an answer now. Send the text again.")
	}
	return "an answer", hc.Send(ctx, d.hcPath, addr, strings.ReplaceAll(text, "\n", " "), true)
}

// herdrAppInput types text and keys in a terminal of the herdr app.
// herdr-core types text only with Enter after it, so text needs the keys
// to be enter alone.
func (d *Daemon) herdrAppInput(ctx context.Context, pane, text string, keys []string) error {
	addr := herdrAppAddress(pane)
	switch {
	case text == "":
		return hc.Keys(ctx, d.hcPath, addr, keys)
	case len(keys) == 1 && keys[0] == "enter":
		return hc.Send(ctx, d.hcPath, addr, text, false)
	}
	return herdrRefusal("The herdr app takes text only with Enter after it")
}

// herdrAppDir returns the project folder of an agent in the herdr app.
func (d *Daemon) herdrAppDir(ctx context.Context, pane string) (string, error) {
	t, err := hc.Get(ctx, d.hcPath, herdrAppAddress(pane))
	if err != nil {
		return "", err
	}
	if dir := t.Dir(); dir != "" {
		return dir, nil
	}
	return "", errors.New("the agent has no project folder")
}

package core

// fluxd follows the default herdr session and each named session at the
// same time. The default session keeps the pane and workspace IDs of
// herdr, so an older phone sees the default session as before. A named
// session puts its name and a slash before each ID, such as
// "omarchy/w5:p1". herdr IDs have no slash, and a session name is a
// folder name, so the slash splits them. A phone uses the IDs as they
// are, so each reply, read, and live terminal finds its session.

import (
	"context"
	"sort"
	"strings"
	"time"

	"flux/internal/herdr"
)

// herdrSessionSep separates the session name from a herdr ID.
const herdrSessionSep = "/"

// HerdrSession is one herdr session as the phone sees it. The default
// session has an empty Name in fluxd and the name "default" on the
// wire, so a phone can show it.
type HerdrSession struct {
	Name       string           `json:"name"`
	Default    bool             `json:"default"`
	Running    bool             `json:"running"`
	Agents     []HerdrAgent     `json:"agents"`
	Panes      []HerdrTerminal  `json:"panes"`
	Workspaces []HerdrWorkspace `json:"workspaces"`
}

// herdrDefaultName is the name of the default session on the wire. herdr
// uses the same name in herdr session list.
const herdrDefaultName = "default"

// herdrQualify returns the ID of a pane or a workspace of the session as
// the phone sees it.
func herdrQualify(session, id string) string {
	if session == "" || id == "" {
		return id
	}
	return session + herdrSessionSep + id
}

// herdrSplit returns the session and the herdr ID of a qualified ID.
func herdrSplit(id string) (session, raw string) {
	if s, r, ok := strings.Cut(id, herdrSessionSep); ok {
		return s, r
	}
	return "", id
}

// herdrSessionOf returns the session of a qualified ID.
func herdrSessionOf(id string) string {
	s, _ := herdrSplit(id)
	return s
}

// herdrSocket returns the API socket of the session.
func (d *Daemon) herdrSocket(session string) string {
	if session == "" {
		return d.herdrPath
	}
	return herdr.SessionSocket(d.herdrSessionsDir, session)
}

// herdrAt returns the API socket and the herdr ID of a qualified ID.
func (d *Daemon) herdrAt(id string) (socket, raw string) {
	session, raw := herdrSplit(id)
	return d.herdrSocket(session), raw
}

// herdrSessionName returns the session name from a phone: an empty
// string for the default session.
func herdrSessionName(name string) string {
	if name == herdrDefaultName {
		return ""
	}
	return name
}

// herdrSessionKnownLocked reports whether fluxd follows the session and
// the session runs.
func (d *Daemon) herdrSessionKnownLocked(session string) bool {
	if session == "" {
		return true
	}
	return d.herdrNamed[session]
}

// qualifyHerdrLive puts the session name before each ID of live.
func qualifyHerdrLive(session string, live herdrLive) herdrLive {
	if session == "" {
		return live
	}
	out := herdrLive{Kinds: live.Kinds}
	for _, a := range live.Agents {
		a.Pane = herdrQualify(session, a.Pane)
		out.Agents = append(out.Agents, a)
	}
	for _, t := range live.Terminals {
		t.Pane = herdrQualify(session, t.Pane)
		out.Terminals = append(out.Terminals, t)
	}
	for _, w := range live.Workspaces {
		w.ID = herdrQualify(session, w.ID)
		out.Workspaces = append(out.Workspaces, w)
	}
	return out
}

// ofHerdrSession returns the items of the session in list.
func ofHerdrSession[T any](list []T, session string, id func(T) string) []T {
	var out []T
	for _, x := range list {
		if herdrSessionOf(id(x)) == session {
			out = append(out, x)
		}
	}
	return out
}

// mergeHerdrSession replaces the items of the session in list with items,
// and keeps the default session first and the named sessions in name
// order. It returns nil for an empty list.
func mergeHerdrSession[T any](list, items []T, session string, id func(T) string) []T {
	var out []T
	for _, x := range list {
		if herdrSessionOf(id(x)) != session {
			out = append(out, x)
		}
	}
	out = append(out, items...)
	sort.SliceStable(out, func(i, j int) bool {
		a, b := herdrSessionOf(id(out[i])), herdrSessionOf(id(out[j]))
		return a < b
	})
	if len(out) == 0 {
		return nil
	}
	return out
}

func agentPane(a HerdrAgent) string       { return a.Pane }
func terminalPane(t HerdrTerminal) string { return t.Pane }
func workspaceID(w HerdrWorkspace) string { return w.ID }

// herdrSessionsLocked returns the default session and each named session
// that runs, with their agents, terminals, and workspaces.
func (d *Daemon) herdrSessionsLocked() []HerdrSession {
	out := []HerdrSession{d.herdrSessionLocked("", d.cfg.Herdr && d.herdrRunning)}
	var names []string
	for name, running := range d.herdrNamed {
		if running {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		out = append(out, d.herdrSessionLocked(name, d.cfg.Herdr))
	}
	return out
}

func (d *Daemon) herdrSessionLocked(name string, running bool) HerdrSession {
	s := HerdrSession{
		Name: name, Default: name == "", Running: running,
		Agents:     ofHerdrSession(d.herdrAgents, name, agentPane),
		Panes:      ofHerdrSession(d.herdrTerms, name, terminalPane),
		Workspaces: ofHerdrSession(d.herdrPlaces, name, workspaceID),
	}
	if s.Default {
		s.Name = herdrDefaultName
	}
	if s.Agents == nil {
		s.Agents = []HerdrAgent{}
	}
	if s.Panes == nil {
		s.Panes = []HerdrTerminal{}
	}
	if s.Workspaces == nil {
		s.Workspaces = []HerdrWorkspace{}
	}
	return s
}

// herdrLoop follows the default herdr session and each named session.
// It looks for new and removed named sessions at each poll and wake.
func (d *Daemon) herdrLoop(ctx context.Context) {
	done := make(chan struct{})
	go func() {
		d.herdrFollow(ctx, "")
		close(done)
	}()
	followers := map[string]context.CancelFunc{}
	stop := func(name string) {
		followers[name]()
		delete(followers, name)
		d.dropHerdrSession(name)
	}
	tick := time.NewTicker(herdrPoll)
	defer tick.Stop()
	for {
		want := map[string]bool{}
		if d.herdrEnabled() && d.herdrSessionsDir != "" {
			for _, name := range herdr.Sessions(d.herdrSessionsDir, d.herdrPath) {
				// The phone names the default session "default", and the
				// herdr app has its own name.
				if name != herdrDefaultName && name != herdrAppSession {
					want[name] = true
				}
			}
		}
		if d.herdrEnabled() && d.hcPath != "" {
			want[herdrAppSession] = true
		}
		for name := range followers {
			if !want[name] {
				stop(name)
			}
		}
		for name := range want {
			if followers[name] == nil {
				fctx, cancel := context.WithCancel(ctx)
				followers[name] = cancel
				go d.herdrFollow(fctx, name)
			}
		}
		select {
		case <-ctx.Done():
			for name := range followers {
				stop(name)
			}
			<-done
			return
		case <-d.herdrWake:
		case <-tick.C:
		}
	}
}

// dropHerdrSession forgets a named session that fluxd follows no longer.
// Its follower stopped before, so no new state of it comes.
func (d *Daemon) dropHerdrSession(name string) {
	d.mu.Lock()
	_, known := d.herdrNamed[name]
	delete(d.herdrNamed, name)
	d.mu.Unlock()
	if known {
		d.setHerdrSession(nil, name, false, herdrLive{})
	}
}

// addHerdrWaker returns a channel that wakeHerdr signals, and a function
// that removes it.
func (d *Daemon) addHerdrWaker() (chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	d.herdrWakeMu.Lock()
	if d.herdrWakers == nil {
		d.herdrWakers = map[chan struct{}]bool{}
	}
	d.herdrWakers[ch] = true
	d.herdrWakeMu.Unlock()
	return ch, func() {
		d.herdrWakeMu.Lock()
		delete(d.herdrWakers, ch)
		d.herdrWakeMu.Unlock()
	}
}

// herdrSessionLabel names the session in the log.
func herdrSessionLabel(session string) string {
	if session == "" {
		return "herdr"
	}
	return "herdr session " + session
}

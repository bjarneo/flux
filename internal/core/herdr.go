package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"runtime/debug"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"flux/internal/herdr"
	"flux/internal/lan"
	"flux/internal/proto"
)

// herdrPoll is how often fluxd reads the herdr session when no event
// arrives. Events bring most changes sooner. The poll also finds title
// changes, because fluxd does not subscribe to them.
const herdrPoll = 10 * time.Second

// herdrRetry is how long fluxd waits before it connects to herdr again.
const herdrRetry = 5 * time.Second

// herdrSettle collects a burst of herdr events into one read.
const herdrSettle = 200 * time.Millisecond

// herdrReadTimeout limits an output read for a phone. herdr scrolls an
// idle agent to collect its history, which can take 2 seconds for 1000
// lines.
const herdrReadTimeout = 10 * time.Second

// herdrCallTimeout limits a reply, a close, and the other short calls.
const herdrCallTimeout = 5 * time.Second

// herdrHistoryTTL is how long fluxd uses the plain history of an idle
// agent again without a new read. herdr scrolls the agent for each read of
// the history.
const herdrHistoryTTL = 3 * time.Second

// Limits of an output read for a phone.
const (
	herdrDefaultLines = 200
	herdrMaxLines     = 1000
	herdrMaxText      = 1 << 20
)

// herdrGap separates the history of an agent from its screen when fluxd
// cannot find where they meet. The rows between them come with the first
// read after the agent stops.
const herdrGap = "\x1b[2m··· More lines show here when the agent stops ···\x1b[0m"

// errHerdrOff ends a herdr session when the user turns the feature off.
var errHerdrOff = errors.New("herdr sync is off")

// errHerdrDisabled is the answer to a phone while herdr is off.
const errHerdrDisabled = "herdr sync is off on this computer"

// HerdrAgent is one herdr agent as the phone sees it.
type HerdrAgent struct {
	Pane      string `json:"pane"`
	Agent     string `json:"agent"`
	Status    string `json:"status"`
	Title     string `json:"title"`
	Project   string `json:"project"`
	Workspace string `json:"workspace"`
}

// HerdrTerminal is a herdr pane without an agent, as the phone sees it.
type HerdrTerminal struct {
	Pane      string `json:"pane"`
	Title     string `json:"title"`
	Project   string `json:"project"`
	Workspace string `json:"workspace"`
}

// HerdrWorkspace is a herdr workspace that can get a new tab. Cwd is the
// folder of the first pane in its active tab.
type HerdrWorkspace struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Cwd   string `json:"cwd"`
}

// herdrLive is what the herdr loop read from the session. Kinds are the
// agent kinds that this computer can start.
type herdrLive struct {
	Agents     []HerdrAgent
	Terminals  []HerdrTerminal
	Workspaces []HerdrWorkspace
	Kinds      []string
}

// herdrJobs keeps the herdr work that runs for the phones. d.mu guards
// it. reads has a key for each read that runs. creating has the ID of
// each device that starts an agent or opens a terminal. kinds is the
// result of the last lookup of the agent kinds, at kindsAt. kindsBusy is
// true while a lookup runs.
type herdrJobs struct {
	reads     map[herdrReadKey]herdrRead
	creating  map[string]bool
	kinds     []string
	kindsAt   time.Time
	kindsBusy bool

	// sending counts the keys, prompt, input, and close jobs that run for
	// each device ID.
	sending map[string]int
}

// herdrMaxSends is the number of keys, prompt, input, and close jobs that
// can run at a time for each device. Each job opens a connection to herdr.
const herdrMaxSends = 4

// errHerdrBusy is the reply when herdrMaxSends jobs of the device run.
const errHerdrBusy = "fluxd is busy with earlier replies from this device. Try again."

// herdrReadKey selects the reads of one pane on one link. One read of
// the pane runs at a time for each link.
type herdrReadKey struct {
	link *lan.Link
	pane string
}

// herdrRead is the state of a read that runs. waiting is true when
// another read of the pane came during the read. stale is true when a
// reply went to the pane during the herdr calls, so the answer can be
// older than the reply.
type herdrRead struct {
	waiting bool
	stale   bool

	// lines and ansi are the line count and the format of the newest read
	// that waits.
	lines int
	ansi  bool
}

// agentHistory is the last plain history of an agent. asked is the line
// count of the read. agent is the kind of the agent, so a new agent in the
// same pane does not show it. The history is fresh from at until
// herdrHistoryTTL passes. A new status of the agent and a reply to it
// clear at, because the agent then writes new lines.
type agentHistory struct {
	lines     []string
	truncated bool
	asked     int
	agent     string
	at        time.Time
}

// herdrView is the herdr state in a flux.herdr state packet and in the
// IPC state. Control is true when a phone can reply to the agents, start
// agents, and close them. Terminals is true when a phone can also open
// terminals and type in them. Panes are the terminals, and they are empty
// when Terminals is false. Workspaces and Kinds are empty when Control is
// false.
type herdrView struct {
	Review     bool             `json:"review"`
	Enabled    bool             `json:"enabled"`
	Running    bool             `json:"running"`
	Control    bool             `json:"control"`
	Terminals  bool             `json:"terminals"`
	Agents     []HerdrAgent     `json:"agents"`
	Panes      []HerdrTerminal  `json:"panes"`
	Workspaces []HerdrWorkspace `json:"workspaces"`
	Kinds      []string         `json:"kinds"`
}

func (d *Daemon) herdrViewLocked() herdrView {
	v := herdrView{
		Review:  d.cfg.Herdr,
		Enabled: d.cfg.Herdr, Running: d.cfg.Herdr && d.herdrRunning,
		Control: d.herdrControlLocked(), Terminals: d.herdrTerminalsLocked(),
		Agents: d.herdrAgents, Panes: d.herdrTerms, Workspaces: d.herdrPlaces, Kinds: d.herdrKinds,
	}
	if !v.Enabled || v.Agents == nil {
		v.Agents = []HerdrAgent{}
	}
	if !v.Terminals || v.Panes == nil {
		v.Panes = []HerdrTerminal{}
	}
	if !v.Control || v.Workspaces == nil {
		v.Workspaces = []HerdrWorkspace{}
	}
	if !v.Control || v.Kinds == nil {
		v.Kinds = []string{}
	}
	return v
}

// herdrControlLocked reports whether a phone can reply to agents, start
// them, and close them.
func (d *Daemon) herdrControlLocked() bool { return d.cfg.Herdr && d.cfg.HerdrControl }

// herdrTerminalsLocked reports whether a phone can open terminals and type
// in them. It needs herdr_control too.
func (d *Daemon) herdrTerminalsLocked() bool { return d.herdrControlLocked() && d.cfg.HerdrTerminals }

func herdrStatePacket(v herdrView) *proto.Packet {
	return proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "state", "enabled": v.Enabled, "running": v.Running, "control": v.Control,
		"terminals": v.Terminals, "agents": v.Agents, "panes": v.Panes, "workspaces": v.Workspaces, "kinds": v.Kinds,
		"review": v.Review,
	})
}

// herdrLoop follows the agents of the herdr session and sends each change
// to the phones. It connects again after herdr stops or restarts.
func (d *Daemon) herdrLoop(ctx context.Context) {
	logged := ""
	for ctx.Err() == nil {
		if !d.herdrEnabled() {
			d.setHerdr(false, herdrLive{})
			d.herdrPause(ctx, 0)
			continue
		}
		err := d.herdrSession(ctx, &logged)
		d.setHerdr(false, herdrLive{})
		if ctx.Err() != nil {
			return
		}
		if errors.Is(err, errHerdrOff) {
			continue
		}
		// herdr is often not running. Log each problem once, not at each
		// retry.
		if msg := err.Error(); msg != logged {
			d.logf("herdr: %v", err)
			logged = msg
		}
		d.herdrPause(ctx, herdrRetry)
	}
}

// herdrSession follows one herdr server until the connection fails or the
// user turns the feature off. The status events of herdr need a pane ID,
// so fluxd subscribes to each agent pane. It opens a new subscription
// when the set of agent panes changes. A connection clears logged, so the
// next failure goes to the log again.
func (d *Daemon) herdrSession(ctx context.Context, logged *string) error {
	pong, err := herdr.Ping(ctx, d.herdrPath)
	if err != nil {
		return err
	}
	if pong.Protocol < herdr.MinProtocol {
		return fmt.Errorf("herdr %s uses API protocol %d, and Flux needs %d or newer", pong.Version, pong.Protocol, herdr.MinProtocol)
	}
	d.logf("herdr %s: following its agents", pong.Version)
	*logged = ""
	// This herdr can have other agent kinds than the last one.
	d.herdrKindsDue()

	var feed *herdrFeed
	var panes []string
	defer func() {
		if feed != nil {
			feed.stream.Close()
		}
	}()
	tick := time.NewTicker(herdrPoll)
	defer tick.Stop()
	for {
		snap, err := herdr.GetSnapshot(ctx, d.herdrPath)
		if err != nil {
			return err
		}
		agents := herdrAgents(snap)
		live := herdrLive{Agents: agents, Terminals: herdrTerminals(snap), Workspaces: herdrWorkspaces(snap), Kinds: d.herdrKindsNow(ctx)}
		if want := herdrPanes(agents); feed == nil || !slices.Equal(want, panes) {
			if feed != nil {
				feed.stream.Close()
			}
			s, err := herdr.Subscribe(ctx, d.herdrPath, herdrSubscriptions(want))
			if err != nil {
				return err
			}
			feed, panes = follow(s, d.forgetHerdrHistory), want
			// A change between the read and the subscription has no
			// event, so read the session again.
			continue
		}
		d.setHerdr(true, live)

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-d.herdrWake:
			if !d.herdrEnabled() {
				return errHerdrOff
			}
		case err := <-feed.done:
			return err
		case <-tick.C:
		case <-feed.events:
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(herdrSettle):
			}
			select {
			case <-feed.events:
			default:
			}
		}
	}
}

// herdrFeed turns the events of a subscription into signals. fluxd reads
// the whole session after an event, so the content of most events does
// not matter.
type herdrFeed struct {
	stream *herdr.Stream
	events chan struct{}
	done   chan error
}

// follow reads the events of s. It calls detected with the pane of each
// new agent before the signal, so the history of an agent that ran in
// that pane before goes away.
func follow(s *herdr.Stream, detected func(pane string)) *herdrFeed {
	f := &herdrFeed{stream: s, events: make(chan struct{}, 1), done: make(chan error, 1)}
	go func() {
		for {
			ev, err := s.Next()
			if err != nil {
				f.done <- err
				return
			}
			if pane := detectedPane(ev); pane != "" {
				detected(pane)
			}
			select {
			case f.events <- struct{}{}:
			default:
			}
		}
	}()
	return f
}

// detectedPane returns the pane of a pane_agent_detected event, or an
// empty string for another event.
func detectedPane(ev herdr.Event) string {
	if ev.Name != "pane_agent_detected" && ev.Name != "pane.agent_detected" {
		return ""
	}
	var data struct {
		PaneID string `json:"pane_id"`
	}
	if json.Unmarshal(ev.Data, &data) != nil {
		return ""
	}
	return data.PaneID
}

// herdrSubscriptions returns the events that change the state: new and
// removed agents, panes, tabs, and workspaces, pane moves, workspace
// labels, and the status of each agent pane.
func herdrSubscriptions(panes []string) []herdr.Subscription {
	subs := []herdr.Subscription{
		{Type: "pane.agent_detected"},
		{Type: "pane.created"},
		{Type: "tab.created"},
		{Type: "tab.closed"},
		{Type: "workspace.created"},
		{Type: "pane.closed"},
		{Type: "pane.exited"},
		{Type: "pane.moved"},
		{Type: "workspace.renamed"},
		{Type: "workspace.reordered"},
		{Type: "workspace.closed"},
	}
	for _, p := range panes {
		subs = append(subs, herdr.Subscription{Type: "pane.agent_status_changed", PaneID: p})
	}
	return subs
}

// herdrAgents converts the agents of a herdr snapshot for the phone. The
// agents keep the sidebar order of their workspaces.
func herdrAgents(snap herdr.Snapshot) []HerdrAgent {
	workspaces := map[string]herdr.Workspace{}
	for _, w := range snap.Workspaces {
		workspaces[w.ID] = w
	}
	order := func(a herdr.Agent) int {
		if w, ok := workspaces[a.WorkspaceID]; ok {
			return w.Number
		}
		return math.MaxInt
	}
	agents := slices.Clone(snap.Agents)
	sort.SliceStable(agents, func(i, j int) bool { return order(agents[i]) < order(agents[j]) })
	out := make([]HerdrAgent, 0, len(agents))
	for _, a := range agents {
		if a.PaneID == "" {
			continue
		}
		cwd := a.ForegroundCwd
		if cwd == "" {
			cwd = a.Cwd
		}
		status := a.Status
		if status == "" {
			status = herdr.StatusUnknown
		}
		out = append(out, HerdrAgent{
			Pane: a.PaneID, Agent: a.Agent, Status: status, Title: cleanLabel(a.Title),
			Project: cleanLabel(projectName(cwd)), Workspace: cleanLabel(workspaces[a.WorkspaceID].Label),
		})
	}
	return out
}

// herdrTerminals returns the panes without an agent, in the sidebar order
// of their workspaces.
func herdrTerminals(snap herdr.Snapshot) []HerdrTerminal {
	workspaces := map[string]herdr.Workspace{}
	for _, w := range snap.Workspaces {
		workspaces[w.ID] = w
	}
	agents := map[string]bool{}
	for _, a := range snap.Agents {
		agents[a.PaneID] = true
	}
	order := func(p herdr.Pane) int {
		if w, ok := workspaces[p.WorkspaceID]; ok {
			return w.Number
		}
		return math.MaxInt
	}
	panes := slices.Clone(snap.Panes)
	sort.SliceStable(panes, func(i, j int) bool { return order(panes[i]) < order(panes[j]) })
	out := []HerdrTerminal{}
	for _, p := range panes {
		if p.ID == "" || agents[p.ID] {
			continue
		}
		out = append(out, HerdrTerminal{
			Pane: p.ID, Title: cleanLabel(p.Title), Project: cleanLabel(projectName(paneCwd(p))),
			Workspace: cleanLabel(workspaces[p.WorkspaceID].Label),
		})
	}
	return out
}

// herdrWorkspaces returns the workspaces in sidebar order, each with the
// folder of the first pane in its active tab. A folder in the home folder
// starts with ~/, which is shorter on the phone. herdrDir reads it back.
func herdrWorkspaces(snap herdr.Snapshot) []HerdrWorkspace {
	home, _ := os.UserHomeDir()
	ws := slices.Clone(snap.Workspaces)
	sort.SliceStable(ws, func(i, j int) bool { return ws[i].Number < ws[j].Number })
	out := make([]HerdrWorkspace, 0, len(ws))
	for _, w := range ws {
		cwd := ""
		for _, p := range snap.Panes {
			if p.WorkspaceID == w.ID && (w.ActiveTab == "" || p.TabID == w.ActiveTab) {
				cwd = paneCwd(p)
				break
			}
		}
		out = append(out, HerdrWorkspace{ID: w.ID, Label: cleanLabel(w.Label), Cwd: homeRelative(cwd, home)})
	}
	return out
}

// paneCwd returns the folder of the program in the pane, or the folder of
// the pane when herdr does not know it.
func paneCwd(p herdr.Pane) string {
	if p.ForegroundCwd != "" {
		return p.ForegroundCwd
	}
	return p.Cwd
}

// homeRelative writes a folder in the home folder as ~ or ~/path.
func homeRelative(dir, home string) string {
	switch {
	case home == "" || home == "/" || dir == "":
		return dir
	case dir == home:
		return "~"
	case strings.HasPrefix(dir, home+"/"):
		return "~/" + dir[len(home)+1:]
	}
	return dir
}

// projectName returns the base name of a folder, or an empty string.
func projectName(cwd string) string {
	if cwd == "" {
		return ""
	}
	return filepath.Base(cwd)
}

// herdrPanes returns the sorted pane IDs of the agents.
func herdrPanes(agents []HerdrAgent) []string {
	panes := make([]string, 0, len(agents))
	for _, a := range agents {
		panes = append(panes, a.Pane)
	}
	sort.Strings(panes)
	return panes
}

func (d *Daemon) herdrEnabled() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.cfg.Herdr
}

// herdrPause waits for the delay, a wake signal, or the end of ctx. A zero
// delay waits with no limit.
func (d *Daemon) herdrPause(ctx context.Context, delay time.Duration) {
	var after <-chan time.Time
	if delay > 0 {
		t := time.NewTimer(delay)
		defer t.Stop()
		after = t.C
	}
	select {
	case <-ctx.Done():
	case <-d.herdrWake:
	case <-after:
	}
}

// wakeHerdr makes the herdr loop check the setting and read the session
// now. A loop that waits to connect again tries at once.
func (d *Daemon) wakeHerdr() {
	select {
	case d.herdrWake <- struct{}{}:
	default:
	}
}

// setHerdr records the herdr state and sends it to the phones when it
// changed. It forgets the history of the agents that are gone, and of a
// pane that has an agent of another kind now. A new status makes the
// history of the agent old.
func (d *Daemon) setHerdr(running bool, live herdrLive) {
	d.mu.Lock()
	if d.herdrRunning == running && slices.Equal(d.herdrAgents, live.Agents) && slices.Equal(d.herdrTerms, live.Terminals) &&
		slices.Equal(d.herdrPlaces, live.Workspaces) && slices.Equal(d.herdrKinds, live.Kinds) {
		d.mu.Unlock()
		return
	}
	for pane, h := range d.herdrHistory {
		i := slices.IndexFunc(live.Agents, func(a HerdrAgent) bool { return a.Pane == pane })
		switch {
		case i < 0 || live.Agents[i].Agent != h.agent:
			delete(d.herdrHistory, pane)
		case live.Agents[i].Status != d.herdrStatusLocked(pane):
			h.at = time.Time{}
			d.herdrHistory[pane] = h
		}
	}
	d.herdrRunning, d.herdrAgents, d.herdrTerms, d.herdrPlaces, d.herdrKinds = running, live.Agents, live.Terminals, live.Workspaces, live.Kinds
	d.mu.Unlock()
	d.sendHerdr()
}

// forgetHerdrHistory removes the history of the agent in the pane.
func (d *Daemon) forgetHerdrHistory(pane string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	delete(d.herdrHistory, pane)
}

// staleHerdrOutput makes the output of the pane old after a reply. The
// next read of the history of the agent gets it from herdr again. A read
// of the pane that runs can have output from before the reply, so the
// reads that wait for it get a new read.
func (d *Daemon) staleHerdrOutput(pane string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if h, ok := d.herdrHistory[pane]; ok {
		h.at = time.Time{}
		d.herdrHistory[pane] = h
	}
	for key, r := range d.herdrJobs.reads {
		if key.pane == pane {
			r.stale = true
			d.herdrJobs.reads[key] = r
		}
	}
}

// herdrChanged sends the state after the user changes the herdr setting.
func (d *Daemon) herdrChanged() {
	d.wakeHerdr()
	d.sendHerdr()
}

// sendHerdr sends the herdr state to each paired phone that is connected
// and accepts flux.herdr.
func (d *Daemon) sendHerdr() {
	d.mu.Lock()
	var links []*lan.Link
	packets := map[*lan.Link]*proto.Packet{}
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.accepts(proto.TypeFluxHerdr) {
			links = append(links, dev.link)
			packets[dev.link] = herdrStatePacket(d.herdrViewForLocked(dev.ID))
		}
	}
	d.mu.Unlock()
	for _, l := range links {
		_ = l.Send(packets[l])
	}
	d.markDirty()
}

// handleHerdr answers a flux.herdr packet from a phone. A phone asks for
// the state or for the recent output of an agent. When herdr_control is
// on, it also sends keys and prompts to an agent, starts agents, and
// closes them. When herdr_terminals is on too, it opens terminals and
// types in them.
func (d *Daemon) handleHerdr(dev *Device, l *lan.Link, p *proto.Packet) {
	var body struct {
		Kind      string   `json:"kind"`
		Pane      string   `json:"pane"`
		Lines     int      `json:"lines"`
		Format    string   `json:"format"`
		Keys      []string `json:"keys"`
		Text      string   `json:"text"`
		What      string   `json:"what"`
		Agent     string   `json:"agent"`
		Cwd       string   `json:"cwd"`
		Workspace string   `json:"workspace"`
		Answer    bool     `json:"answer"`
		// Request is the number of a keys, prompt, input, create, or close
		// packet. The answer carries the same number, so the phone matches
		// a late answer to its packet.
		Request json.RawMessage `json:"request"`
		Path    string          `json:"path"`
	}
	if p.Decode(&body) != nil {
		return
	}
	req := herdrRequest(body.Request)
	if body.Kind != "request" {
		d.mu.Lock()
		v := d.herdrViewForLocked(dev.ID)
		terminal := d.herdrTerminalLocked(body.Pane) || (body.Kind == "create" && body.What == "terminal")
		d.mu.Unlock()
		read := body.Kind == "read" || body.Kind == "diff"
		if !v.Enabled || (!read && !v.Control) || ((body.Kind == "input" || terminal) && !v.Terminals) {
			kind := "sent"
			if read {
				kind = "output"
			}
			if body.Kind == "diff" {
				kind = "diff"
			}
			if body.Kind == "create" {
				kind = "created"
			}
			if body.Kind == "close" {
				kind = "closed"
			}
			failed := proto.New(proto.TypeFluxHerdr, map[string]any{"kind": kind, "pane": body.Pane, "action": body.Kind, "what": body.What, "error": "This feature is off for this device"})
			if body.Kind == "read" {
				failed = viewResponse(failed, reviewRead{format: body.Format, path: body.Path, request: req})
			}
			d.herdrSend(dev, l, withRequest(failed, req))
			return
		}
	}
	switch body.Kind {
	case "request":
		// The phone opened its agent list. When herdr was not running,
		// fluxd tries to connect again now.
		d.wakeHerdr()
		d.mu.Lock()
		state := herdrStatePacket(d.herdrViewForLocked(dev.ID))
		d.mu.Unlock()
		_ = l.Send(state)
	case "read":
		if body.Format == "diff" || req != "" {
			d.readHerdrView(dev, l, reviewRead{pane: body.Pane, path: body.Path, format: body.Format, lines: body.Lines, request: req})
		} else {
			d.readHerdrOnce(dev, l, body.Pane, body.Lines, body.Format == "ansi", func(p *proto.Packet) { _ = l.Send(p) })
		}
	case "keys", "prompt", "input", "close":
		failed := map[string]any{"kind": "sent", "pane": body.Pane, "action": body.Kind, "error": "fluxd could not send the reply"}
		if body.Kind == "close" {
			failed = map[string]any{"kind": "closed", "pane": body.Pane, "error": "fluxd could not close the pane"}
		}
		run := func() *proto.Packet {
			switch body.Kind {
			case "keys":
				return d.herdrKeys(dev, body.Pane, body.Keys)
			case "prompt":
				return d.herdrPrompt(dev, body.Pane, body.Text, body.Answer)
			case "input":
				return d.herdrInput(dev, body.Pane, body.Text, body.Keys)
			}
			return d.herdrClose(dev, body.Pane)
		}
		switch d.startHerdrSend(dev, body.Pane) {
		case herdrSendUnknown:
			// The checks in run refuse a pane that fluxd does not know
			// before a herdr call, so the answer goes at once.
			d.herdrSend(dev, l, withRequest(run(), req))
		case herdrSendBusy:
			failed["error"] = errHerdrBusy
			d.herdrSend(dev, l, withRequest(proto.New(proto.TypeFluxHerdr, failed), req))
		default:
			go func() {
				defer d.endHerdrSend(dev)
				defer d.herdrRecover(body.Kind, d.herdrFailed(dev, l, req, failed))
				d.herdrSend(dev, l, withRequest(run(), req))
			}()
		}
	case "create":
		go func() {
			failed := map[string]any{"kind": "created", "what": body.What, "error": "fluxd could not open the pane"}
			defer d.herdrRecover("create", d.herdrFailed(dev, l, req, failed))
			reply := d.herdrCreate(dev, body.What, body.Agent, body.Cwd, body.Workspace)
			// The phone opens the new pane at once, so it must know the
			// pane before the answer.
			d.mu.Lock()
			state := herdrStatePacket(d.herdrViewForLocked(dev.ID))
			d.mu.Unlock()
			d.herdrSend(dev, l, state, withRequest(reply, req))
		}()
	default:
		d.logf("%s: unknown flux.herdr kind %q", d.nameOf(dev), body.Kind)
	}
}

// The results of startHerdrSend.
const (
	herdrSendStarted = iota
	herdrSendUnknown
	herdrSendBusy
)

// startHerdrSend counts a new keys, prompt, input, or close job of the
// device for the pane. It returns herdrSendUnknown and counts nothing for
// a pane that fluxd does not know. It returns herdrSendBusy when
// herdrMaxSends jobs of the device run. Call endHerdrSend when a started
// job ends.
func (d *Daemon) startHerdrSend(dev *Device, pane string) int {
	d.mu.Lock()
	defer d.mu.Unlock()
	switch {
	case !d.herdrAgentLocked(pane) && !d.herdrTerminalLocked(pane):
		return herdrSendUnknown
	case d.herdrJobs.sending[dev.ID] >= herdrMaxSends:
		return herdrSendBusy
	}
	if d.herdrJobs.sending == nil {
		d.herdrJobs.sending = map[string]int{}
	}
	d.herdrJobs.sending[dev.ID]++
	return herdrSendStarted
}

// endHerdrSend ends a job that startHerdrSend counted.
func (d *Daemon) endHerdrSend(dev *Device) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.herdrJobs.sending[dev.ID]--; d.herdrJobs.sending[dev.ID] <= 0 {
		delete(d.herdrJobs.sending, dev.ID)
	}
}

// herdrSend sends the packets on the link l while the device is paired.
func (d *Daemon) herdrSend(dev *Device, l *lan.Link, packets ...*proto.Packet) {
	for _, p := range packets {
		if !d.stillPaired(dev) {
			return
		}
		_ = l.Send(p)
	}
}

// herdrFailed returns a function that sends a flux.herdr packet with the
// body and the request number req to the device. herdrRecover calls it
// after a panic.
func (d *Daemon) herdrFailed(dev *Device, l *lan.Link, req json.Number, body map[string]any) func() {
	return func() { d.herdrSend(dev, l, withRequest(proto.New(proto.TypeFluxHerdr, body), req)) }
}

// herdrRequest returns the request number of a flux.herdr packet, or ""
// when the packet has no number in the field.
func herdrRequest(raw json.RawMessage) json.Number {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if dec.Decode(&v) != nil {
		return ""
	}
	n, _ := v.(json.Number)
	return n
}

// withRequest adds the request number req to the answer p. An answer to a
// packet without a number stays as it is.
func withRequest(p *proto.Packet, req json.Number) *proto.Packet {
	if req == "" {
		return p
	}
	var body map[string]json.RawMessage
	if p.Decode(&body) != nil {
		return p
	}
	body["request"] = json.RawMessage(req)
	return proto.New(p.Type, body)
}

// herdrRecover logs a panic in the answer to a flux.herdr packet and ends
// that answer, so one bad reply from herdr does not stop fluxd. Then it
// calls fail, which sends an error to the phone. Without it, the phone
// waits for the answer until its own time limit. Call herdrRecover with
// defer at the start of the goroutine.
func (d *Daemon) herdrRecover(what string, fail func()) {
	if r := recover(); r != nil {
		d.logf("herdr: the %s failed: %v\n%s", what, r, debug.Stack())
		fail()
	}
}

// readHerdrOnce answers a read of the pane that came on the link l. One
// read of a pane runs at a time for each link, from the herdr calls until
// the answer is sent. A read that comes during the herdr calls gets the
// answer of that read, so a flood of reads does not make more herdr calls
// and large packets. fluxd reads once more when the agent status changed
// during the herdr calls, when a reply went to the pane during them, when
// the read that came asks for another line count or format, or when a
// read came during the send. That read uses the line count and the format
// of the newest read, so the phone gets the answer to its last request.
// A pane that fluxd does not know gets its answer at once, with no herdr
// call. The answer does not go out after an unpair. send sends the answer.
func (d *Daemon) readHerdrOnce(dev *Device, l *lan.Link, pane string, lines int, ansi bool, send func(*proto.Packet)) {
	key := herdrReadKey{link: l, pane: pane}
	lines = herdrLines(lines)
	d.mu.Lock()
	if !d.herdrAgentLocked(pane) && !d.herdrTerminalLocked(pane) {
		d.mu.Unlock()
		if d.stillPaired(dev) {
			send(d.readHerdr(pane, lines, ansi))
		}
		return
	}
	if r, running := d.herdrJobs.reads[key]; running {
		r.waiting, r.lines, r.ansi = true, lines, ansi
		d.herdrJobs.reads[key] = r
		d.mu.Unlock()
		return
	}
	if d.herdrJobs.reads == nil {
		d.herdrJobs.reads = map[herdrReadKey]herdrRead{}
	}
	d.herdrJobs.reads[key] = herdrRead{}
	d.mu.Unlock()
	go func() {
		defer d.herdrRecover("read", func() {
			failed := map[string]any{"kind": "output", "pane": pane, "error": "fluxd could not read the pane"}
			if ansi {
				failed["format"] = "ansi"
			}
			if d.stillPaired(dev) {
				send(proto.New(proto.TypeFluxHerdr, failed))
			}
		})
		finished := false
		defer func() {
			// After a panic, the next read of the pane must run.
			if !finished {
				d.mu.Lock()
				delete(d.herdrJobs.reads, key)
				d.mu.Unlock()
			}
		}()
		for !finished {
			d.mu.Lock()
			status := d.herdrStatusLocked(pane)
			d.mu.Unlock()
			p := d.readHerdr(pane, lines, ansi)
			d.mu.Lock()
			r := d.herdrJobs.reads[key]
			again := r.waiting && (r.stale || d.herdrStatusLocked(pane) != status || r.lines != lines || r.ansi != ansi)
			d.herdrJobs.reads[key] = herdrRead{}
			paired := dev.Paired
			d.mu.Unlock()
			if paired {
				send(p)
			}
			if r.waiting {
				lines, ansi = r.lines, r.ansi
			}
			d.mu.Lock()
			if w := d.herdrJobs.reads[key]; paired && dev.Paired && (again || w.waiting) {
				if w.waiting {
					lines, ansi = w.lines, w.ansi
				}
				d.herdrJobs.reads[key] = herdrRead{}
			} else {
				delete(d.herdrJobs.reads, key)
				finished = true
			}
			d.mu.Unlock()
		}
	}()
}

// readHerdr returns an output packet with the recent output of an agent.
// It reads only a pane that holds an agent in the last state, or a
// terminal when herdr_terminals is on, so a phone cannot read other
// terminals. It checks the settings again after the read, so the text
// does not go out when the user turned the feature off during the read.
// With ansi, the text keeps its colors and styles as SGR sequences.
func (d *Daemon) readHerdr(pane string, lines int, ansi bool) *proto.Packet {
	reply := map[string]any{"kind": "output", "pane": pane}
	if ansi {
		reply["format"] = "ansi"
	}
	d.mu.Lock()
	enabled := d.cfg.Herdr
	agent := d.herdrAgentLocked(pane)
	terminal := d.herdrTerminalsLocked() && d.herdrTerminalLocked(pane)
	d.mu.Unlock()
	switch {
	case !enabled:
		reply["error"] = errHerdrDisabled
	case !agent && !terminal:
		reply["error"] = fmt.Sprintf("No agent runs in %s", pane)
	default:
		ctx, cancel := context.WithTimeout(d.ctx, herdrReadTimeout)
		var text string
		var truncated bool
		var err error
		if agent {
			text, truncated, err = d.readAgentOutput(ctx, pane, herdrLines(lines), ansi)
		} else {
			text, truncated, err = d.readTerminal(ctx, pane, herdrLines(lines), ansi)
		}
		cancel()
		d.mu.Lock()
		enabled, terminals := d.cfg.Herdr, d.herdrTerminalsLocked()
		d.mu.Unlock()
		switch {
		case !enabled:
			reply["error"] = errHerdrDisabled
		case !agent && !terminals:
			reply["error"] = errHerdrTerminalsOff
		case err != nil:
			reply["error"] = herdrError(pane, err)
		default:
			text, cut := tailText(text, herdrMaxText)
			reply["text"], reply["truncated"] = text, truncated || cut
		}
	}
	return proto.New(proto.TypeFluxHerdr, reply)
}

// herdrAgentLocked reports whether an agent is in the pane.
func (d *Daemon) herdrAgentLocked(pane string) bool {
	return slices.ContainsFunc(d.herdrAgents, func(a HerdrAgent) bool { return a.Pane == pane })
}

// herdrStatusLocked returns the status of the agent in the pane, or an
// empty string when the pane has no agent.
func (d *Daemon) herdrStatusLocked(pane string) string {
	if i := slices.IndexFunc(d.herdrAgents, func(a HerdrAgent) bool { return a.Pane == pane }); i >= 0 {
		return d.herdrAgents[i].Status
	}
	return ""
}

// herdrKindLocked returns the kind of the agent in the pane, or an empty
// string when the pane has no agent.
func (d *Daemon) herdrKindLocked(pane string) string {
	if i := slices.IndexFunc(d.herdrAgents, func(a HerdrAgent) bool { return a.Pane == pane }); i >= 0 {
		return d.herdrAgents[i].Agent
	}
	return ""
}

// herdrTerminalLocked reports whether the pane is a terminal without an
// agent.
func (d *Daemon) herdrTerminalLocked(pane string) bool {
	return slices.ContainsFunc(d.herdrTerms, func(t HerdrTerminal) bool { return t.Pane == pane })
}

// readTerminal reads the recent output of a terminal. A shell keeps its
// scrollback in herdr, so one read gets the history with its colors.
func (d *Daemon) readTerminal(ctx context.Context, pane string, lines int, ansi bool) (string, bool, error) {
	r, err := herdr.ReadPane(ctx, d.herdrPath, pane, lines, ansi)
	if err != nil {
		return "", false, err
	}
	if ansi {
		return cleanANSI(r.Text), r.Truncated, nil
	}
	return cleanPlain(r.Text), r.Truncated, nil
}

// readAgentOutput reads the recent output of an agent. Many agents draw in
// the alternate screen. herdr collects the history of such an agent only
// in a plain read and only while the agent is idle. An ANSI read gets only
// the screen. So for ANSI, fluxd reads both and puts the colored screen
// under the plain history. While the agent works, it uses the history of
// the last idle read.
func (d *Daemon) readAgentOutput(ctx context.Context, pane string, lines int, ansi bool) (string, bool, error) {
	r, err := herdr.ReadAgent(ctx, d.herdrPath, pane, lines, ansi)
	if err != nil {
		return "", false, err
	}
	if !ansi {
		return cleanPlain(r.Text), r.Truncated, nil
	}
	screen := strings.Split(cleanANSI(r.Text), "\n")
	if len(screen) >= lines {
		return strings.Join(screen, "\n"), r.Truncated, nil
	}
	history, truncated := d.readAgentHistory(ctx, pane, lines)
	truncated = truncated || r.Truncated
	out := spliceScreen(history, screen)
	if len(out) > lines {
		out, truncated = out[len(out)-lines:], true
	}
	return strings.Join(out, "\n"), truncated, nil
}

// readAgentHistory returns the plain history of an agent and reports
// whether herdr cut it. A fresh history from the last read needs no new
// read. While the agent works, herdr refuses the read, and the history of
// the last idle read stays.
func (d *Daemon) readAgentHistory(ctx context.Context, pane string, lines int) ([]string, bool) {
	d.mu.Lock()
	last, ok := d.herdrHistory[pane]
	d.mu.Unlock()
	if ok && !last.at.IsZero() && time.Since(last.at) < herdrHistoryTTL && last.asked >= lines {
		return last.lines, last.truncated
	}
	h, err := herdr.ReadAgent(ctx, d.herdrPath, pane, lines, false)
	switch {
	case err == nil:
		next := agentHistory{lines: strings.Split(cleanPlain(h.Text), "\n"), truncated: h.Truncated, asked: lines, at: time.Now()}
		d.mu.Lock()
		next.agent = d.herdrKindLocked(pane)
		if d.herdrHistory == nil {
			d.herdrHistory = map[string]agentHistory{}
		}
		d.herdrHistory[pane] = next
		d.mu.Unlock()
		return next.lines, next.truncated
	case herdr.Code(err) == "agent_not_idle":
		d.mu.Lock()
		defer d.mu.Unlock()
		return d.herdrHistory[pane].lines, false
	}
	return nil, false
}

// spliceScreen puts the colored screen rows of an agent under its plain
// history rows. When both come from the same moment, the history ends
// with the rows of the screen. While the agent works, the history is
// older, and the screen shows newer rows. spliceScreen finds the first
// screen row with text in the history, and the screen replaces the
// history from there. The place with the most rows in common wins, and
// the newest place wins a tie. A place needs 2 rows in common. One row is
// enough at the end of the history, or when the row is only once in the
// history. When no place is good, spliceScreen keeps the whole history
// and puts herdrGap between.
func spliceScreen(history, screen []string) []string {
	if len(history) == 0 {
		return screen
	}
	rows := make([]string, len(screen))
	for i, l := range screen {
		rows[i] = plainRow(l)
	}
	anchor := slices.IndexFunc(rows, hasWord)
	if anchor < 0 {
		return append(slices.Clip(history), screen...)
	}
	past := make([]string, len(history))
	copies := 0
	for i, l := range history {
		past[i] = plainRow(l)
		if past[i] == rows[anchor] {
			copies++
		}
	}
	best, bestRun := -1, 0
	for i := len(past) - 1; i >= 0; i-- {
		run := 0
		for i+run < len(past) && anchor+run < len(rows) && past[i+run] == rows[anchor+run] {
			run++
		}
		if run == 0 || run == 1 && i+1 < len(past) && copies > 1 {
			continue
		}
		if run > bestRun {
			best, bestRun = i, run
		}
	}
	if best < 0 {
		out := append(slices.Clip(history), herdrGap)
		return append(out, screen...)
	}
	return append(slices.Clip(history[:max(best-anchor, 0)]), screen...)
}

// sgr matches an SGR sequence.
var sgr = regexp.MustCompile("\x1b\\[[0-9;:]*m")

// plainRow returns a row without SGR sequences and without the blanks,
// no-break spaces, and carriage returns at its end. A plain read and an
// ANSI read of the same row can differ in these.
func plainRow(row string) string {
	return strings.TrimRight(sgr.ReplaceAllString(row, ""), " \t\r\u00a0")
}

// hasWord reports whether the row has a letter or a digit. A row of only
// frame characters or blanks is in many places of a screen.
func hasWord(row string) bool {
	return strings.IndexFunc(row, func(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }) >= 0
}

// herdrError returns the text for a phone about a failed herdr call.
func herdrError(pane string, err error) string {
	var he *herdr.Error
	switch {
	case errors.As(err, &he) && he.Code == "agent_not_found":
		return fmt.Sprintf("The agent in %s is gone", pane)
	case errors.As(err, &he) && he.Code == "agent_not_ready":
		return fmt.Sprintf("The agent in %s is not ready for input", pane)
	case errors.As(err, &he):
		return "herdr: " + he.Message
	}
	return "herdr does not answer on this computer"
}

// herdrLines returns the line count for a read. Zero or less means the
// default.
func herdrLines(n int) int {
	switch {
	case n <= 0:
		return herdrDefaultLines
	case n > herdrMaxLines:
		return herdrMaxLines
	}
	return n
}

// trimLineEnds removes the spaces and tabs at the end of each line. The
// rows of a terminal often end in padding. It also changes CRLF line ends
// to LF.
func trimLineEnds(text string) string {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t\r")
	}
	return strings.Join(lines, "\n")
}

// cleanPlain prepares plain output for a phone. It removes and marks
// characters as textRune does, and it removes the blanks at the end of
// each line.
func cleanPlain(text string) string {
	return trimLineEnds(strings.Map(textRune, text))
}

// cleanLabel prepares a title or a name for a phone. A program sets the
// title of its pane, and an agent can make its title from the
// conversation. cleanLabel removes and marks characters as textRune does,
// and it changes line breaks and tabs to spaces, because a label has one
// line.
func cleanLabel(label string) string {
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return ' '
		}
		return textRune(r)
	}, label)
}

// textRune returns the character that a phone gets for a character of
// terminal output, or -1 to remove it. It removes the C0 and C1 control
// characters except line breaks and tabs. The phone shows text with the
// Unicode bidirectional algorithm, and a terminal does not. So a
// character that sets the direction of text can show a command in another
// order on the phone. textRune changes each such character, and the line
// and paragraph separators, to U+FFFD, so the phone shows a mark in its
// place.
func textRune(r rune) rune {
	switch {
	case r == '\n' || r == '\t':
		return r
	case r < 0x20 || r >= 0x7f && r <= 0x9f:
		return -1
	case r == 0x061c || r == 0x200e || r == 0x200f || r >= 0x202a && r <= 0x202e || r >= 0x2066 && r <= 0x2069,
		r == 0x2028 || r == 0x2029:
		return utf8.RuneError
	}
	return r
}

// cleanANSI prepares ANSI output for a phone. It keeps the SGR sequences
// of colors and styles and removes all other escape sequences. It removes
// and marks the other characters as textRune does. It changes CRLF to LF
// and removes the blanks at the end of each line, also when SGR sequences
// follow them.
func cleanANSI(text string) string {
	var b strings.Builder
	b.Grow(len(text))
	for i := 0; i < len(text); {
		c := text[i]
		switch {
		case c == 0x1b && i+1 < len(text) && text[i+1] == '[':
			// A CSI sequence has parameter and intermediate bytes from 0x20
			// to 0x3f, and then a final byte from 0x40 to 0x7e. Another
			// byte ends the sequence, and fluxd drops the sequence. That
			// byte, for example a line break, then goes through the loop.
			j := i + 2
			for j < len(text) && text[j] >= 0x20 && text[j] <= 0x3f {
				j++
			}
			if j < len(text) && text[j] >= 0x40 && text[j] <= 0x7e {
				if text[j] == 'm' && sgrParams(text[i+2:j]) {
					b.WriteString(text[i : j+1])
				}
				j++
			}
			i = j
		case c == 0x1b && i+1 < len(text) && strings.IndexByte("]PX^_", text[i+1]) >= 0:
			// An OSC, DCS, SOS, PM, or APC string ends with BEL or with ST,
			// which is ESC and a backslash. Another ESC ends the string
			// and starts the next sequence.
			j := i + 2
			for j < len(text) && text[j] != 0x07 && text[j] != 0x1b {
				j++
			}
			switch {
			case j < len(text) && text[j] == 0x07:
				j++
			case j+1 < len(text) && text[j+1] == '\\':
				j += 2
			}
			i = j
		case c == 0x1b:
			// Another escape sequence has intermediate bytes from 0x20 to
			// 0x2f and then a final byte from 0x30 to 0x7e.
			j := i + 1
			for j < len(text) && text[j] >= 0x20 && text[j] <= 0x2f {
				j++
			}
			if j < len(text) && text[j] >= 0x30 && text[j] <= 0x7e {
				j++
			}
			i = j
		default:
			r, n := utf8.DecodeRuneInString(text[i:])
			if r = textRune(r); r >= 0 {
				b.WriteRune(r)
			}
			i += n
		}
	}
	lines := strings.Split(b.String(), "\n")
	for i, l := range lines {
		lines[i] = trimStyledEnd(l)
	}
	return strings.Join(lines, "\n")
}

// sgrParams reports whether params can be the parameters of an SGR
// sequence: digits, semicolons, and colons. sgr matches the same
// sequences.
func sgrParams(params string) bool {
	for i := 0; i < len(params); i++ {
		if c := params[i]; (c < '0' || c > '9') && c != ';' && c != ':' {
			return false
		}
	}
	return true
}

// trimStyledEnd removes the spaces and tabs with the default background at
// the end of a line and keeps the SGR sequences among them. Blanks with a
// background stay, because they draw the panels of full-screen agents such
// as opencode. cleanANSI leaves only SGR sequences in the line.
func trimStyledEnd(line string) string {
	bg := false
	keep := 0
	for i := 0; i < len(line); {
		if line[i] == 0x1b {
			end := strings.IndexByte(line[i:], 'm')
			if end < 2 || line[i+1] != '[' {
				// This is not an SGR sequence. Skip the ESC and do not
				// parse the bytes after it.
				i++
				continue
			}
			bg = sgrBackground(line[i+2:i+end], bg)
			i += end + 1
			continue
		}
		if bg || line[i] != ' ' && line[i] != '\t' {
			keep = i + 1
		}
		i++
	}
	return line[:keep] + strings.Join(sgr.FindAllString(line[keep:], -1), "")
}

// sgrBackground reports whether a background color is set after the SGR
// parameters params, when bg reports it before them.
func sgrBackground(params string, bg bool) bool {
	parts := strings.Split(params, ";")
	for i := 0; i < len(parts); i++ {
		p := parts[i]
		if strings.Contains(p, ":") {
			// The colon form keeps a color in 1 parameter, for example 48:2::1:2:3.
			if strings.HasPrefix(p, "48:") {
				bg = true
			}
			continue
		}
		n, _ := strconv.Atoi(p)
		switch {
		case n == 0 || n == 49:
			bg = false
		case n >= 40 && n <= 47 || n >= 100 && n <= 107:
			bg = true
		case n == 38 || n == 48:
			if n == 48 {
				bg = true
			}
			// Skip the color: 5;N or 2;R;G;B.
			if i+1 < len(parts) && parts[i+1] == "5" {
				i += 2
			} else if i+1 < len(parts) && parts[i+1] == "2" {
				i += 4
			}
		}
	}
	return bg
}

// tailText returns the end of text in at most max bytes. The cut text
// starts at a line when the end has a line break, and it always starts at
// a whole UTF-8 character. The second result reports a cut.
func tailText(text string, max int) (string, bool) {
	if len(text) <= max {
		return text, false
	}
	tail := text[len(text)-max:]
	if i := strings.IndexByte(tail, '\n'); i >= 0 && i < len(tail)-1 {
		return tail[i+1:], true
	}
	for len(tail) > 0 && !utf8.RuneStart(tail[0]) {
		tail = tail[1:]
	}
	return tail, true
}

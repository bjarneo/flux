package core

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
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

// herdrView is the herdr state in a flux.herdr state packet and in the
// IPC state. Control is true when a phone can reply to the agents, start
// agents, and close them. Terminals is true when a phone can also open
// terminals and type in them. Panes are the terminals, and they are empty
// when Terminals is false. Workspaces and Kinds are empty when Control is
// false.
type herdrView struct {
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

// herdrControlOn reports whether herdr_control is on.
func (d *Daemon) herdrControlOn() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.herdrControlLocked()
}

// herdrTerminalsLocked reports whether a phone can open terminals and type
// in them. It needs herdr_control too.
func (d *Daemon) herdrTerminalsLocked() bool { return d.herdrControlLocked() && d.cfg.HerdrTerminals }

func herdrStatePacket(v herdrView) *proto.Packet {
	return proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "state", "enabled": v.Enabled, "running": v.Running, "control": v.Control,
		"terminals": v.Terminals, "agents": v.Agents, "panes": v.Panes, "workspaces": v.Workspaces, "kinds": v.Kinds,
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
	var kinds []string
	var kindsAt time.Time

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
		// An agent that the user installs or removes shows after a
		// minute. Only herdr_control uses the list, so fluxd skips the
		// lookup while it is off.
		if !d.herdrControlOn() {
			kinds, kindsAt = nil, time.Time{}
		} else if time.Since(kindsAt) > herdrKindsTTL {
			kinds, kindsAt = d.herdrAvailableKinds(ctx), time.Now()
		}
		agents := herdrAgents(snap)
		live := herdrLive{Agents: agents, Terminals: herdrTerminals(snap), Workspaces: herdrWorkspaces(snap), Kinds: kinds}
		if want := herdrPanes(agents); feed == nil || !slices.Equal(want, panes) {
			if feed != nil {
				feed.stream.Close()
			}
			s, err := herdr.Subscribe(ctx, d.herdrPath, herdrSubscriptions(want))
			if err != nil {
				return err
			}
			feed, panes = follow(s), want
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
// the whole session after an event, so the content of an event does not
// matter.
type herdrFeed struct {
	stream *herdr.Stream
	events chan struct{}
	done   chan error
}

func follow(s *herdr.Stream) *herdrFeed {
	f := &herdrFeed{stream: s, events: make(chan struct{}, 1), done: make(chan error, 1)}
	go func() {
		for {
			if _, err := s.Next(); err != nil {
				f.done <- err
				return
			}
			select {
			case f.events <- struct{}{}:
			default:
			}
		}
	}()
	return f
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
			Pane: a.PaneID, Agent: a.Agent, Status: status, Title: a.Title,
			Project: projectName(cwd), Workspace: workspaces[a.WorkspaceID].Label,
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
			Pane: p.ID, Title: p.Title, Project: projectName(paneCwd(p)), Workspace: workspaces[p.WorkspaceID].Label,
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
		out = append(out, HerdrWorkspace{ID: w.ID, Label: w.Label, Cwd: homeRelative(cwd, home)})
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
// changed. It forgets the history of the agents that are gone.
func (d *Daemon) setHerdr(running bool, live herdrLive) {
	d.mu.Lock()
	if d.herdrRunning == running && slices.Equal(d.herdrAgents, live.Agents) && slices.Equal(d.herdrTerms, live.Terminals) &&
		slices.Equal(d.herdrPlaces, live.Workspaces) && slices.Equal(d.herdrKinds, live.Kinds) {
		d.mu.Unlock()
		return
	}
	d.herdrRunning, d.herdrAgents, d.herdrTerms, d.herdrPlaces, d.herdrKinds = running, live.Agents, live.Terminals, live.Workspaces, live.Kinds
	for pane := range d.herdrHistory {
		if !slices.ContainsFunc(live.Agents, func(a HerdrAgent) bool { return a.Pane == pane }) {
			delete(d.herdrHistory, pane)
		}
	}
	d.mu.Unlock()
	d.sendHerdr()
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
	p := herdrStatePacket(d.herdrViewLocked())
	var links []*lan.Link
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && dev.accepts(proto.TypeFluxHerdr) {
			links = append(links, dev.link)
		}
	}
	d.mu.Unlock()
	for _, l := range links {
		_ = l.Send(p)
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
	}
	if p.Decode(&body) != nil {
		return
	}
	switch body.Kind {
	case "request":
		// The phone opened its agent list. When herdr was not running,
		// fluxd tries to connect again now.
		d.wakeHerdr()
		d.mu.Lock()
		state := herdrStatePacket(d.herdrViewLocked())
		d.mu.Unlock()
		_ = l.Send(state)
	case "read":
		go func() { _ = l.Send(d.readHerdr(body.Pane, body.Lines, body.Format == "ansi")) }()
	case "keys":
		go func() { _ = l.Send(d.herdrKeys(dev, body.Pane, body.Keys)) }()
	case "prompt":
		go func() { _ = l.Send(d.herdrPrompt(dev, body.Pane, body.Text)) }()
	case "input":
		go func() { _ = l.Send(d.herdrInput(dev, body.Pane, body.Text, body.Keys)) }()
	case "create":
		go func() {
			reply := d.herdrCreate(dev, body.What, body.Agent, body.Cwd, body.Workspace)
			// The phone opens the new pane at once, so it must know the
			// pane before the answer.
			d.mu.Lock()
			state := herdrStatePacket(d.herdrViewLocked())
			d.mu.Unlock()
			_ = l.Send(state)
			_ = l.Send(reply)
		}()
	case "close":
		go func() { _ = l.Send(d.herdrClose(dev, body.Pane)) }()
	default:
		d.logf("%s: unknown flux.herdr kind %q", dev.Name, body.Kind)
	}
}

// readHerdr returns an output packet with the recent output of an agent.
// It reads only a pane that holds an agent in the last state, or a
// terminal when herdr_terminals is on, so a phone cannot read other
// terminals. With ansi, the text keeps its colors and styles as SGR
// sequences.
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
		reply["error"] = "herdr sync is off on this computer"
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
		if err != nil {
			reply["error"] = herdrError(pane, err)
			break
		}
		text, cut := tailText(text, herdrMaxText)
		reply["text"], reply["truncated"] = text, truncated || cut
	}
	return proto.New(proto.TypeFluxHerdr, reply)
}

// herdrAgentLocked reports whether an agent is in the pane.
func (d *Daemon) herdrAgentLocked(pane string) bool {
	return slices.ContainsFunc(d.herdrAgents, func(a HerdrAgent) bool { return a.Pane == pane })
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
	return trimLineEnds(r.Text), r.Truncated, nil
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
		return trimLineEnds(r.Text), r.Truncated, nil
	}
	screen := strings.Split(cleanANSI(r.Text), "\n")
	if len(screen) >= lines {
		return strings.Join(screen, "\n"), r.Truncated, nil
	}
	truncated := r.Truncated
	var history []string
	h, err := herdr.ReadAgent(ctx, d.herdrPath, pane, lines, false)
	switch {
	case err == nil:
		history = strings.Split(trimLineEnds(h.Text), "\n")
		truncated = truncated || h.Truncated
		d.mu.Lock()
		if d.herdrHistory == nil {
			d.herdrHistory = map[string][]string{}
		}
		d.herdrHistory[pane] = history
		d.mu.Unlock()
	case herdr.Code(err) == "agent_not_idle":
		d.mu.Lock()
		history = d.herdrHistory[pane]
		d.mu.Unlock()
	}
	out := spliceScreen(history, screen)
	if len(out) > lines {
		out, truncated = out[len(out)-lines:], true
	}
	return strings.Join(out, "\n"), truncated, nil
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

// sgrEnd matches an SGR sequence at the end of a line.
var sgrEnd = regexp.MustCompile("\x1b\\[[0-9;:]*m$")

// cleanANSI prepares ANSI output for a phone. It keeps the SGR sequences
// of colors and styles and removes all other escape sequences and control
// characters. It changes CRLF to LF and removes the blanks at the end of
// each line, also when SGR sequences follow them.
func cleanANSI(text string) string {
	var b strings.Builder
	b.Grow(len(text))
	for i := 0; i < len(text); i++ {
		c := text[i]
		switch {
		case c == 0x1b && i+1 < len(text) && text[i+1] == '[':
			// A CSI sequence ends with a byte from 0x40 to 0x7e.
			j := i + 2
			for j < len(text) && (text[j] < 0x40 || text[j] > 0x7e) {
				j++
			}
			if j < len(text) && text[j] == 'm' {
				b.WriteString(text[i : j+1])
			}
			i = j
		case c == 0x1b && i+1 < len(text) && text[i+1] == ']':
			// An OSC sequence ends with BEL or with ESC and a backslash.
			j := i + 2
			for j < len(text) && text[j] != 0x07 && (text[j] != 0x1b || j+1 >= len(text) || text[j+1] != '\\') {
				j++
			}
			if j < len(text) && text[j] == 0x1b {
				j++
			}
			i = j
		case c == 0x1b:
			// Another escape sequence has intermediate bytes from 0x20 to
			// 0x2f and then one final byte.
			i++
			for i < len(text) && text[i] >= 0x20 && text[i] <= 0x2f {
				i++
			}
		case c == '\n' || c == '\t' || c >= 0x20 && c != 0x7f:
			b.WriteByte(c)
		}
	}
	lines := strings.Split(b.String(), "\n")
	for i, l := range lines {
		lines[i] = trimStyledEnd(l)
	}
	return strings.Join(lines, "\n")
}

// trimStyledEnd removes the spaces and tabs at the end of a line and keeps
// the SGR sequences among them.
func trimStyledEnd(line string) string {
	var tail []string
	for {
		line = strings.TrimRight(line, " \t")
		loc := sgrEnd.FindStringIndex(line)
		if loc == nil {
			break
		}
		tail = append(tail, line[loc[0]:])
		line = line[:loc[0]]
	}
	for i := len(tail) - 1; i >= 0; i-- {
		line += tail[i]
	}
	return line
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

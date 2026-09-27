package core

import (
	"context"
	"errors"
	"fmt"
	"math"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
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

// herdrReadTimeout limits an output read for a phone.
const herdrReadTimeout = 5 * time.Second

// Limits of an output read for a phone.
const (
	herdrDefaultLines = 200
	herdrMaxLines     = 400
	herdrMaxText      = 256 << 10
)

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

// herdrView is the herdr state in a flux.herdr state packet and in the
// IPC state. Control is true when a phone can reply to the agents.
type herdrView struct {
	Enabled bool         `json:"enabled"`
	Running bool         `json:"running"`
	Control bool         `json:"control"`
	Agents  []HerdrAgent `json:"agents"`
}

func (d *Daemon) herdrViewLocked() herdrView {
	v := herdrView{
		Enabled: d.cfg.Herdr, Running: d.cfg.Herdr && d.herdrRunning,
		Control: d.cfg.Herdr && d.cfg.HerdrControl, Agents: d.herdrAgents,
	}
	if !v.Enabled || v.Agents == nil {
		v.Agents = []HerdrAgent{}
	}
	return v
}

func herdrStatePacket(v herdrView) *proto.Packet {
	return proto.New(proto.TypeFluxHerdr, map[string]any{
		"kind": "state", "enabled": v.Enabled, "running": v.Running, "control": v.Control, "agents": v.Agents,
	})
}

// herdrLoop follows the agents of the herdr session and sends each change
// to the phones. It connects again after herdr stops or restarts.
func (d *Daemon) herdrLoop(ctx context.Context) {
	logged := ""
	for ctx.Err() == nil {
		if !d.herdrEnabled() {
			d.setHerdr(false, nil)
			d.herdrPause(ctx, 0)
			continue
		}
		err := d.herdrSession(ctx, &logged)
		d.setHerdr(false, nil)
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
		d.setHerdr(true, agents)

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

// herdrSubscriptions returns the events that change the agent list: new
// and removed agents, pane moves, workspace labels, and the status of each
// agent pane.
func herdrSubscriptions(panes []string) []herdr.Subscription {
	subs := []herdr.Subscription{
		{Type: "pane.agent_detected"},
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
		project := ""
		if cwd != "" {
			project = filepath.Base(cwd)
		}
		status := a.Status
		if status == "" {
			status = herdr.StatusUnknown
		}
		out = append(out, HerdrAgent{
			Pane: a.PaneID, Agent: a.Agent, Status: status, Title: a.Title,
			Project: project, Workspace: workspaces[a.WorkspaceID].Label,
		})
	}
	return out
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
// changed.
func (d *Daemon) setHerdr(running bool, agents []HerdrAgent) {
	d.mu.Lock()
	if d.herdrRunning == running && slices.Equal(d.herdrAgents, agents) {
		d.mu.Unlock()
		return
	}
	d.herdrRunning, d.herdrAgents = running, agents
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
// on, it also sends keys and prompts to an agent.
func (d *Daemon) handleHerdr(dev *Device, l *lan.Link, p *proto.Packet) {
	var body struct {
		Kind   string   `json:"kind"`
		Pane   string   `json:"pane"`
		Lines  int      `json:"lines"`
		Format string   `json:"format"`
		Keys   []string `json:"keys"`
		Text   string   `json:"text"`
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
	default:
		d.logf("%s: unknown flux.herdr kind %q", dev.Name, body.Kind)
	}
}

// readHerdr returns an output packet with the recent output of an agent.
// It reads only a pane that holds an agent in the last state, so a phone
// cannot read other terminals. With ansi, the text keeps its colors and
// styles as SGR sequences.
func (d *Daemon) readHerdr(pane string, lines int, ansi bool) *proto.Packet {
	reply := map[string]any{"kind": "output", "pane": pane}
	if ansi {
		reply["format"] = "ansi"
	}
	d.mu.Lock()
	enabled := d.cfg.Herdr
	known := slices.ContainsFunc(d.herdrAgents, func(a HerdrAgent) bool { return a.Pane == pane })
	d.mu.Unlock()
	switch {
	case !enabled:
		reply["error"] = "herdr sync is off on this computer"
	case !known:
		reply["error"] = fmt.Sprintf("No agent runs in %s", pane)
	default:
		ctx, cancel := context.WithTimeout(d.ctx, herdrReadTimeout)
		r, err := herdr.ReadAgent(ctx, d.herdrPath, pane, herdrLines(lines), ansi)
		cancel()
		if err != nil {
			reply["error"] = herdrError(pane, err)
			break
		}
		text := trimLineEnds(r.Text)
		if ansi {
			text = cleanANSI(r.Text)
		}
		text, cut := tailText(text, herdrMaxText)
		reply["text"], reply["truncated"] = text, r.Truncated || cut
	}
	return proto.New(proto.TypeFluxHerdr, reply)
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

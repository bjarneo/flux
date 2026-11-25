package core

import (
	"context"
	"encoding/json"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"syscall"
	"time"

	"flux/internal/config"
	"flux/internal/herdr"
)

type automationEvent struct {
	Kind, Device, Path string
	Charge             int
	Charging           bool

	// Rule limits the event to the rule with this ID, for example a
	// device.disconnected rule whose wait ended. Empty means each rule.
	Rule string
	// Subject separates the cooldowns of 1 rule, for example the pane of
	// an agent, so that 2 agents that block at once both run the rule.
	Subject string
	// Env holds the extra variables of the event, such as FLUX_APP.
	Env map[string]string
}

// defaultDisconnectWait is the time that a paired device stays offline
// before a device.disconnected rule runs, when the rule sets no after.
const defaultDisconnectWait = 30 * time.Second

// agentDoneWait is the time that an agent stays done or idle before an
// agent.done rule runs. The status can change between 2 tool calls.
const agentDoneWait = 2 * time.Second

func (d *Daemon) emitAutomation(e automationEvent) {
	select {
	case d.automationQ <- e:
	default:
	}
}

func automationMatches(r config.AutomationRule, e automationEvent, low map[string]bool) bool {
	if r.Disabled || r.Event != e.Kind || (r.Device != "" && r.Device != e.Device) || (e.Rule != "" && e.Rule != r.ID) {
		return false
	}
	if e.Kind != "battery.low" {
		return true
	}
	below := r.Below
	if below == 0 {
		below = 15
	}
	key := r.ID + ":" + e.Device
	was := low[key]
	low[key] = !e.Charging && e.Charge >= 0 && e.Charge < below
	return low[key] && !was
}

func (d *Daemon) automationLoop(ctx context.Context) {
	last := map[string]time.Time{}
	low := map[string]bool{}
	for {
		var event automationEvent
		select {
		case <-ctx.Done():
			return
		case event = <-d.automationQ:
		}
		// An event of this computer, such as agent.blocked, has no device.
		computer := event.Device == ""
		d.mu.Lock()
		rules := append([]config.AutomationRule{}, d.cfg.AutomationRules...)
		dev := d.devices[event.Device]
		paired := dev != nil && dev.Paired
		d.mu.Unlock()
		if !paired && !computer {
			continue
		}
		for _, rule := range rules {
			d.mu.Lock()
			current := false
			for _, r := range d.cfg.AutomationRules {
				if r == rule && !r.Disabled {
					current = true
					break
				}
			}
			dev = d.devices[event.Device]
			current = current && (computer || dev != nil && dev.Paired)
			d.mu.Unlock()
			if !current {
				continue
			}
			if !automationMatches(rule, event, low) {
				continue
			}
			key := rule.ID + ":" + event.Device + ":" + event.Subject
			cooldown := rule.Cooldown
			if cooldown == 0 {
				cooldown = 60
			}
			if time.Since(last[key]) < time.Duration(cooldown)*time.Second {
				continue
			}
			command, ok := d.command(rule.Command)
			if !ok {
				d.logf("automation %s: command %s does not exist", rule.ID, rule.Command)
				continue
			}
			last[key] = time.Now()
			runCtx, cancel := context.WithTimeout(ctx, time.Minute)
			cmd := exec.CommandContext(runCtx, "sh", "-c", command.Command)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGKILL}
			cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
			cmd.WaitDelay = time.Second
			cmd.Env = append(os.Environ(), "FLUX_EVENT="+event.Kind, "FLUX_DEVICE_ID="+event.Device,
				"FLUX_FILE="+event.Path, "FLUX_BATTERY="+strconv.Itoa(event.Charge))
			for _, k := range slices.Sorted(maps.Keys(event.Env)) {
				cmd.Env = append(cmd.Env, k+"="+event.Env[k])
			}
			err := cmd.Run()
			cancel()
			if err != nil {
				d.logf("automation %s failed: %v", rule.ID, err)
			} else {
				d.logf("automation %s ran command %s", rule.ID, command.ID)
			}
		}
	}
}

func (d *Daemon) addAutomation(raw json.RawMessage) (config.AutomationRule, error) {
	cfgSaves.Lock()
	defer cfgSaves.Unlock()
	var r config.AutomationRule
	if err := json.Unmarshal(raw, &r); err != nil {
		return r, err
	}
	if err := r.Validate(); err != nil {
		return r, err
	}
	if _, ok := d.command(r.Command); !ok {
		return r, fmt.Errorf("no configured command with ID %s", r.Command)
	}
	r.ID = config.NewID(6)
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.cfg.AutomationRules) >= 100 {
		return r, apiErr("full", "At most 100 automation rules can be saved")
	}
	cfg := *d.cfg
	cfg.AutomationRules = append(append([]config.AutomationRule{}, cfg.AutomationRules...), r)
	if err := config.Save(&cfg); err != nil {
		return r, err
	}
	d.cfg = &cfg
	d.markDirty()
	return r, nil
}

func (d *Daemon) removeAutomation(id string) error {
	cfgSaves.Lock()
	defer cfgSaves.Unlock()
	d.mu.Lock()
	defer d.mu.Unlock()
	cfg := *d.cfg
	cfg.AutomationRules = []config.AutomationRule{}
	for _, r := range d.cfg.AutomationRules {
		if r.ID != id {
			cfg.AutomationRules = append(cfg.AutomationRules, r)
		}
	}
	if len(cfg.AutomationRules) == len(d.cfg.AutomationRules) {
		return apiErr("not_found", "No automation rule with ID %s", id)
	}
	if err := config.Save(&cfg); err != nil {
		return err
	}
	d.cfg = &cfg
	d.markDirty()
	return nil
}

// watchDisconnect starts the wait of each device.disconnected rule of the
// paired device dev, after its link dropped. A rule runs when dev is still
// offline at the end of its wait. A device that leaves the Wi-Fi can come
// back at once through Tailscale, and then no rule runs.
func (d *Daemon) watchDisconnect(dev *Device) {
	d.mu.Lock()
	var waits []config.AutomationRule
	for _, r := range d.cfg.AutomationRules {
		if r.Event == "device.disconnected" && !r.Disabled && (r.Device == "" || r.Device == dev.ID) {
			waits = append(waits, r)
		}
	}
	d.mu.Unlock()
	for _, r := range waits {
		wait := defaultDisconnectWait
		if r.After > 0 {
			wait = time.Duration(r.After) * time.Second
		}
		time.AfterFunc(wait, func() {
			if d.ctx.Err() != nil {
				return
			}
			d.mu.Lock()
			offline := dev.Paired && dev.link == nil && d.devices[dev.ID] == dev
			d.mu.Unlock()
			if offline {
				d.emitAutomation(automationEvent{Kind: "device.disconnected", Device: dev.ID, Rule: r.ID})
			}
		})
	}
}

// agentEventsLocked returns the automation events of the change from the
// agents that fluxd knows to the agents in live. A new agent that blocks
// counts too. agent.done waits agentDoneWait, see emitAgentDone.
func (d *Daemon) agentEventsLocked(live []HerdrAgent) (blocked, done []HerdrAgent) {
	for _, a := range live {
		old := d.herdrStatusLocked(a.Pane)
		switch {
		case a.Status == herdr.StatusBlocked && old != herdr.StatusBlocked:
			blocked = append(blocked, a)
		case old == herdr.StatusWorking && (a.Status == herdr.StatusDone || a.Status == herdr.StatusIdle):
			done = append(done, a)
		}
	}
	return blocked, done
}

// agentEvent returns the automation event of kind for the agent a.
func agentEvent(kind string, a HerdrAgent) automationEvent {
	return automationEvent{Kind: kind, Subject: a.Pane, Env: map[string]string{
		"FLUX_AGENT": a.Agent, "FLUX_AGENT_PANE": a.Pane, "FLUX_AGENT_TITLE": a.Title,
		"FLUX_AGENT_PROJECT": a.Project, "FLUX_AGENT_STATUS": a.Status,
	}}
}

// emitAgentDone runs the agent.done rules for a when its agent is still
// done or idle after agentDoneWait.
func (d *Daemon) emitAgentDone(a HerdrAgent) {
	time.AfterFunc(agentDoneWait, func() {
		d.mu.Lock()
		status := d.herdrStatusLocked(a.Pane)
		d.mu.Unlock()
		if status == herdr.StatusDone || status == herdr.StatusIdle {
			a.Status = status
			d.emitAutomation(agentEvent("agent.done", a))
		}
	})
}

package core

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"syscall"
	"time"

	"flux/internal/config"
)

type automationEvent struct {
	Kind, Device, Path string
	Charge             int
	Charging           bool
}

func (d *Daemon) emitAutomation(e automationEvent) {
	select {
	case d.automationQ <- e:
	default:
	}
}

func automationMatches(r config.AutomationRule, e automationEvent, low map[string]bool) bool {
	if r.Disabled || r.Event != e.Kind || (r.Device != "" && r.Device != e.Device) {
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
		d.mu.Lock()
		rules := append([]config.AutomationRule{}, d.cfg.AutomationRules...)
		dev := d.devices[event.Device]
		paired := dev != nil && dev.Paired
		d.mu.Unlock()
		if !paired {
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
			current = current && dev != nil && dev.Paired
			d.mu.Unlock()
			if !current {
				continue
			}
			if !automationMatches(rule, event, low) {
				continue
			}
			key := rule.ID + ":" + event.Device
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

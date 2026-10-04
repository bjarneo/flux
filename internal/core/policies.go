package core

import (
	"encoding/json"
	"maps"
	"time"

	"flux/internal/config"
	"flux/internal/lan"
)

// Device restrictions apply in addition to the global feature switch.
func (d *Daemon) permittedLocked(device, feature string) bool {
	v, present := d.cfg.Devices[device][feature]
	return !present || v
}

func (d *Daemon) permitted(device, feature string) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.permittedLocked(device, feature)
}

func (d *Daemon) featureLinks(feature string) []*lan.Link {
	d.mu.Lock()
	defer d.mu.Unlock()
	var links []*lan.Link
	for _, dev := range d.devices {
		if dev.Paired && dev.link != nil && d.permittedLocked(dev.ID, feature) {
			links = append(links, dev.link)
		}
	}
	return links
}

func (d *Daemon) setDevicePolicy(dev *Device, key string, value any) error {
	cfgSaves.Lock()
	defer cfgSaves.Unlock()
	if !config.DeviceFeatures[key] {
		return apiErr("bad_setting", "Unknown device feature %q", key)
	}
	if _, ok := value.(bool); !ok && value != nil {
		return apiErr("bad_setting", "Use true, false, or null")
	}
	d.mu.Lock()
	cfg := *d.cfg
	cfg.Devices = maps.Clone(cfg.Devices)
	if cfg.Devices == nil {
		cfg.Devices = map[string]map[string]bool{}
	}
	values := maps.Clone(cfg.Devices[dev.ID])
	if values == nil {
		values = map[string]bool{}
	}
	if value == nil {
		delete(values, key)
	} else {
		values[key] = value.(bool)
	}
	cfg.Devices[dev.ID] = values
	if err := config.Save(&cfg); err != nil {
		d.mu.Unlock()
		return err
	}
	d.cfg = &cfg
	d.mu.Unlock()
	d.policiesChanged()
	return nil
}

func (d *Daemon) policiesChanged() {
	d.mu.Lock()
	for _, session := range d.sessions.browse {
		if !d.cfg.ShareHome || !d.permittedLocked(session.dev.ID, "shareHome") {
			session.cancel()
		}
	}
	if d.desktop != nil && !d.permittedLocked(d.desktop.dev.ID, "remoteDesktop") {
		d.desktop.cancel()
	}
	d.mu.Unlock()
	d.inputChanged()
	d.herdrChanged()
	d.markDirty()
}

func (d *Daemon) notificationModeLocked(device, app string, now time.Time) string {
	mode := "normal"
	for _, r := range d.cfg.NotificationRules {
		if r.Matches(device, app, now) {
			mode = r.Mode
		}
	}
	if !d.permittedLocked(device, "notifications") {
		return "mute"
	}
	return mode
}

func (d *Daemon) addNotificationRule(raw json.RawMessage) (config.NotificationRule, error) {
	cfgSaves.Lock()
	defer cfgSaves.Unlock()
	var r config.NotificationRule
	if err := json.Unmarshal(raw, &r); err != nil {
		return r, err
	}
	if err := r.Validate(); err != nil {
		return r, err
	}
	r.ID = config.NewID(6)
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.cfg.NotificationRules) >= 200 {
		return r, apiErr("full", "At most 200 notification rules can be saved")
	}
	cfg := *d.cfg
	cfg.NotificationRules = append(append([]config.NotificationRule{}, cfg.NotificationRules...), r)
	if err := config.Save(&cfg); err != nil {
		return r, err
	}
	d.cfg = &cfg
	d.markDirty()
	return r, nil
}

func (d *Daemon) removeNotificationRule(id string) error {
	cfgSaves.Lock()
	defer cfgSaves.Unlock()
	d.mu.Lock()
	defer d.mu.Unlock()
	cfg := *d.cfg
	cfg.NotificationRules = []config.NotificationRule{}
	for _, r := range d.cfg.NotificationRules {
		if r.ID != id {
			cfg.NotificationRules = append(cfg.NotificationRules, r)
		}
	}
	if len(cfg.NotificationRules) == len(d.cfg.NotificationRules) {
		return apiErr("not_found", "No notification rule with ID %s", id)
	}
	if err := config.Save(&cfg); err != nil {
		return err
	}
	d.cfg = &cfg
	d.markDirty()
	return nil
}

func (d *Daemon) herdrViewForLocked(device string) herdrView {
	v := d.herdrViewLocked()
	v.Enabled = v.Enabled && d.permittedLocked(device, "herdr")
	v.Running = v.Running && v.Enabled
	v.Review = v.Review && v.Enabled
	v.Control = v.Control && v.Enabled && d.permittedLocked(device, "herdrControl")
	v.Terminals = v.Terminals && v.Control && d.permittedLocked(device, "herdrTerminals")
	if !v.Enabled {
		v.Agents = []HerdrAgent{}
	}
	if !v.Control {
		v.Workspaces = []HerdrWorkspace{}
		v.Kinds = []string{}
	}
	if !v.Terminals {
		v.Panes = []HerdrTerminal{}
	}
	return v
}

package config

import "fmt"

type AutomationRule struct {
	ID       string `toml:"id" json:"id"`
	Event    string `toml:"event" json:"event"`
	Device   string `toml:"device,omitempty" json:"device,omitempty"`
	Command  string `toml:"command" json:"command"`
	Below    int    `toml:"below,omitempty" json:"below,omitempty"`
	Cooldown int    `toml:"cooldown,omitempty" json:"cooldown,omitempty"`
	Disabled bool   `toml:"disabled,omitempty" json:"disabled,omitempty"`
}

func (r AutomationRule) Validate() error {
	if r.Event != "device.connected" && r.Event != "file.received" && r.Event != "battery.low" {
		return fmt.Errorf("event must be device.connected, file.received, or battery.low")
	}
	if r.Command == "" {
		return fmt.Errorf("an automation rule needs a configured command ID")
	}
	if r.Below < 0 || r.Below > 100 {
		return fmt.Errorf("battery threshold must be from 0 to 100")
	}
	if r.Cooldown < 0 || r.Cooldown > 86400 {
		return fmt.Errorf("cooldown must be from 0 to 86400 seconds")
	}
	return nil
}

package config

import (
	"fmt"
	"slices"
	"strings"
)

// AutomationEvents are the events that an automation rule can use.
var AutomationEvents = []string{
	"device.connected", "device.disconnected", "file.received", "battery.low",
	"call.ringing", "call.missed", "notification.received",
	"agent.blocked", "agent.done",
}

// ComputerEvent reports whether event comes from this computer and not
// from a device, so a rule for it takes no device.
func ComputerEvent(event string) bool { return strings.HasPrefix(event, "agent.") }

type AutomationRule struct {
	ID       string `toml:"id" json:"id"`
	Event    string `toml:"event" json:"event"`
	Device   string `toml:"device,omitempty" json:"device,omitempty"`
	Command  string `toml:"command" json:"command"`
	Below    int    `toml:"below,omitempty" json:"below,omitempty"`
	Cooldown int    `toml:"cooldown,omitempty" json:"cooldown,omitempty"`
	Disabled bool   `toml:"disabled,omitempty" json:"disabled,omitempty"`

	// After is the number of seconds that a paired device stays offline
	// before a device.disconnected rule runs. Zero means 30.
	After int `toml:"after,omitempty" json:"after,omitempty"`
}

func (r AutomationRule) Validate() error {
	if !slices.Contains(AutomationEvents, r.Event) {
		return fmt.Errorf("event must be one of %s", strings.Join(AutomationEvents, ", "))
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
	if r.After < 0 || r.After > 86400 {
		return fmt.Errorf("after must be from 0 to 86400 seconds")
	}
	if r.Device != "" && ComputerEvent(r.Event) {
		return fmt.Errorf("%s comes from this computer, so the rule takes no device", r.Event)
	}
	return nil
}

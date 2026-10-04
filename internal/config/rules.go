package config

import (
	"fmt"
	"time"
)

var DeviceFeatures = map[string]bool{
	"clipboard": true, "notifications": true, "shareHome": true,
	"remoteInput": true, "remoteDesktop": true, "herdr": true,
	"herdrControl": true, "herdrTerminals": true,
}

type NotificationRule struct {
	ID     string `toml:"id" json:"id"`
	Device string `toml:"device,omitempty" json:"device,omitempty"`
	App    string `toml:"app" json:"app"`
	Mode   string `toml:"mode" json:"mode"`
	Until  int64  `toml:"until,omitempty" json:"until,omitempty"`
	Start  string `toml:"start,omitempty" json:"start,omitempty"`
	End    string `toml:"end,omitempty" json:"end,omitempty"`
}

func (r NotificationRule) Validate() error {
	if r.App == "" {
		return fmt.Errorf("a notification rule needs an app name or *")
	}
	if r.Mode != "normal" && r.Mode != "silent" && r.Mode != "mute" {
		return fmt.Errorf("notification mode must be normal, silent, or mute")
	}
	if r.Until < 0 {
		return fmt.Errorf("notification expiry cannot be negative")
	}
	if r.Start != "" || r.End != "" {
		if _, err := time.Parse("15:04", r.Start); err != nil {
			return fmt.Errorf("start must use HH:MM")
		}
		if _, err := time.Parse("15:04", r.End); err != nil {
			return fmt.Errorf("end must use HH:MM")
		}
		if r.Start == r.End {
			return fmt.Errorf("the quiet period needs different start and end times")
		}
	}
	return nil
}

func (r NotificationRule) Matches(device, app string, now time.Time) bool {
	if (r.Device != "" && r.Device != device) || (r.App != "*" && r.App != app) || (r.Until > 0 && now.Unix() >= r.Until) {
		return false
	}
	if r.Start == "" {
		return true
	}
	clock := now.Format("15:04")
	if r.Start < r.End {
		return clock >= r.Start && clock < r.End
	}
	return clock >= r.Start || clock < r.End
}

func (c *Config) ValidateRules() error {
	for _, rule := range c.AutomationRules {
		if err := rule.Validate(); err != nil {
			return err
		}
	}
	for _, values := range c.Devices {
		for key := range values {
			if !DeviceFeatures[key] {
				return fmt.Errorf("unknown device feature %q", key)
			}
		}
	}
	for _, rule := range c.NotificationRules {
		if err := rule.Validate(); err != nil {
			return err
		}
	}
	return nil
}

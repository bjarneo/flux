package core

import (
	"testing"
	"time"

	"flux/internal/config"
)

func TestDevicePolicyStateAndNotifications(t *testing.T) {
	d := &Daemon{cfg: &config.Config{Herdr: true, HerdrControl: true, HerdrTerminals: true,
		Devices:           map[string]map[string]bool{"limited": {"herdrControl": false, "notifications": false}},
		NotificationRules: []config.NotificationRule{{App: "Chat", Mode: "silent"}, {Device: "one", App: "Chat", Mode: "mute"}}},
		herdrAgents: []HerdrAgent{{Pane: "one"}}, herdrTerms: []HerdrTerminal{{Pane: "two"}}}
	limited := d.herdrViewForLocked("limited")
	if !limited.Enabled || limited.Control || limited.Terminals || len(limited.Panes) != 0 {
		t.Fatal(limited)
	}
	if !d.herdrViewForLocked("full").Control {
		t.Fatal("an unrelated device lost control")
	}
	for device, mode := range map[string]string{"one": "mute", "two": "silent", "limited": "mute"} {
		if got := d.notificationModeLocked(device, "Chat", time.Now()); got != mode {
			t.Fatalf("%s: %s", device, got)
		}
	}
}

package core

import (
	"flux/internal/config"
	"testing"
)

func TestAutomationBatteryTransitions(t *testing.T) {
	r := config.AutomationRule{ID: "rule", Event: "battery.low", Command: "notice", Below: 20, Device: "one"}
	low := map[string]bool{}
	for _, tc := range []struct {
		charge         int
		charging, fire bool
	}{
		{50, false, false}, {20, false, false}, {19, false, true}, {10, false, false},
		{10, true, false}, {10, false, true}, {50, false, false}, {19, false, true},
	} {
		e := automationEvent{Kind: "battery.low", Device: "one", Charge: tc.charge, Charging: tc.charging}
		if automationMatches(r, e, low) != tc.fire {
			t.Fatal(tc)
		}
	}
	if automationMatches(r, automationEvent{Kind: "battery.low", Device: "two", Charge: 1}, low) {
		t.Fatal("rule matched another device")
	}
}

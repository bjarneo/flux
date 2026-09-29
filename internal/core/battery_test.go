package core

import "testing"

func TestLowBatteryAlertsOncePerDischarge(t *testing.T) {
	steps := []struct {
		low      bool
		charge   int
		charging bool
		alert    bool
	}{
		{false, 16, false, false},
		{true, 15, false, true},
		// A Flux phone marks each reading at or below 15% as low.
		{true, 14, false, false},
		{true, 13, false, false},
		// A reconnect sends the same reading again.
		{true, 13, false, false},
		// The protocol marks only the first low reading. The next one
		// does not end the discharge.
		{false, 12, false, false},
		{true, 12, false, false},
		// Charging ends the discharge.
		{false, 12, true, false},
		{true, 11, false, true},
		// A charge above 15% ends the discharge.
		{false, 16, false, false},
		{true, 15, false, true},
	}
	var dev Device
	for i, s := range steps {
		if got := dev.lowBatteryAlert(s.low, s.charge, s.charging); got != s.alert {
			t.Fatalf("step %d, low=%v charge=%d charging=%v: alert=%v, want %v", i, s.low, s.charge, s.charging, got, s.alert)
		}
	}
}

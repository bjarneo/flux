package core

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/lan"
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

// TestAutomationRuleLimit checks that an event with a rule ID matches only
// that rule, as the end of the wait of a device.disconnected rule does.
func TestAutomationRuleLimit(t *testing.T) {
	r := config.AutomationRule{ID: "one", Event: "device.disconnected", Command: "lock"}
	e := automationEvent{Kind: "device.disconnected", Device: "phone", Rule: "one"}
	if !automationMatches(r, e, nil) {
		t.Fatal("the rule of the event did not match")
	}
	r.ID = "two"
	if automationMatches(r, e, nil) {
		t.Fatal("another rule matched an event for rule one")
	}
}

// TestAgentAutomationEvents checks the agent changes that run rules: a
// status that changes to blocked, a new agent that blocks, and a working
// agent that becomes done or idle.
func TestAgentAutomationEvents(t *testing.T) {
	d := testDaemon()
	d.herdrAgents = []HerdrAgent{
		{Pane: "p1", Status: "working"}, {Pane: "p2", Status: "idle"},
		{Pane: "p3", Status: "blocked"}, {Pane: "p5", Status: "working"},
		{Pane: "p6", Status: "done"},
	}
	blocked, done := d.agentEventsLocked([]HerdrAgent{
		{Pane: "p1", Status: "done"}, {Pane: "p2", Status: "blocked"},
		{Pane: "p3", Status: "blocked"}, {Pane: "p4", Status: "blocked"},
		{Pane: "p5", Status: "idle"}, {Pane: "p6", Status: "idle"},
	})
	panes := func(as []HerdrAgent) []string {
		var out []string
		for _, a := range as {
			out = append(out, a.Pane)
		}
		return out
	}
	if got := panes(blocked); !slices.Equal(got, []string{"p2", "p4"}) {
		t.Fatalf("blocked %v, want p2 and p4", got)
	}
	if got := panes(done); !slices.Equal(got, []string{"p1", "p5"}) {
		t.Fatalf("done %v, want p1 and p5", got)
	}
	e := agentEvent("agent.blocked", HerdrAgent{Pane: "p2", Agent: "claude", Title: "Fix", Project: "flux", Status: "blocked"})
	if e.Device != "" || e.Subject != "p2" || e.Env["FLUX_AGENT"] != "claude" || e.Env["FLUX_AGENT_PROJECT"] != "flux" {
		t.Fatalf("event %+v", e)
	}
}

// TestComputerEventRunsCommand checks that an agent event, which has no
// device, runs its rule with the variables of the agent.
func TestComputerEventRunsCommand(t *testing.T) {
	out := filepath.Join(t.TempDir(), "out")
	d := testDaemon()
	d.automationQ = make(chan automationEvent, 4)
	d.cfg.Commands = []config.Command{{ID: "c1", Name: "Save", Command: `printf '%s %s' "$FLUX_EVENT" "$FLUX_AGENT_PROJECT" > "$OUT"`}}
	d.cfg.AutomationRules = []config.AutomationRule{{ID: "r1", Event: "agent.blocked", Command: "c1"}}
	t.Setenv("OUT", out)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.automationLoop(ctx)
	d.emitAutomation(agentEvent("agent.blocked", HerdrAgent{Pane: "p1", Project: "flux", Status: "blocked"}))
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(out); err == nil && string(b) == "agent.blocked flux" {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	b, _ := os.ReadFile(out)
	t.Fatalf("the rule wrote %q, want %q", b, "agent.blocked flux")
}

// TestDisconnectWait checks that device.disconnected runs only when the
// device is still offline at the end of the wait of the rule.
func TestDisconnectWait(t *testing.T) {
	d := testDaemon()
	d.ctx = context.Background()
	d.automationQ = make(chan automationEvent, 4)
	d.cfg.AutomationRules = []config.AutomationRule{
		{ID: "r1", Event: "device.disconnected", Command: "c1", After: 1},
		{ID: "r2", Event: "device.disconnected", Command: "c1", After: 1, Device: "other"},
	}
	away := &Device{ID: "away", Paired: true}
	back := &Device{ID: "back", Paired: true}
	d.devices["away"], d.devices["back"] = away, back
	d.watchDisconnect(away)
	d.watchDisconnect(back)
	d.mu.Lock()
	back.link = &lan.Link{}
	d.mu.Unlock()
	select {
	case e := <-d.automationQ:
		if e.Kind != "device.disconnected" || e.Device != "away" || e.Rule != "r1" {
			t.Fatalf("event %+v", e)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no device.disconnected event")
	}
	select {
	case e := <-d.automationQ:
		t.Fatalf("second event %+v", e)
	case <-time.After(1500 * time.Millisecond):
	}
}

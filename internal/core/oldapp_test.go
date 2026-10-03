package core

import (
	"bytes"
	"log"
	"strings"
	"testing"

	"flux/internal/proto"
)

// A paired phone with an app from before Flux 0.8 is marked, and fluxd
// logs it once. A device that is not paired, such as a phone with KDE
// Connect, is not.
func TestOnOldApp(t *testing.T) {
	d := testDaemon()
	var logs bytes.Buffer
	d.logger = log.New(&logs, "", 0)
	phone := newDevice("b8657d84254547ff8f465063b44b840d")
	phone.Name, phone.Paired = "Fairphone 5", true
	d.devices[phone.ID] = phone

	old := proto.NewIdentity(phone.ID, "Fairphone 5", 1716)
	d.onOldApp(old, "192.168.1.125")
	d.onOldApp(old, "192.168.1.125")
	if !phone.view().OldApp {
		t.Fatal("the paired phone is not marked")
	}
	if n := strings.Count(logs.String(), "older than 0.8"); n != 1 {
		t.Fatalf("logged %d times:\n%s", n, logs.String())
	}

	// A device that fluxd knows but did not pair, and one it does not know.
	seen := newDevice("0123456789abcdef0123456789abcdef")
	d.devices[seen.ID] = seen
	d.onOldApp(proto.NewIdentity(seen.ID, "KDE phone", 1716), "192.168.1.50")
	if seen.view().OldApp {
		t.Fatal("a device that is not paired is marked")
	}
	d.onOldApp(proto.NewIdentity("fedcba9876543210fedcba9876543210", "stranger", 1716), "192.168.1.51")
	if _, ok := d.devices["fedcba9876543210fedcba9876543210"]; ok {
		t.Fatal("an unknown device was added")
	}

	// A link means the app is new now.
	phone.setIdentity(proto.NewIdentity(phone.ID, "Fairphone 5", 0))
	if phone.view().OldApp {
		t.Fatal("the mark stays after a link")
	}
}

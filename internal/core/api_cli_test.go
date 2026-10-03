package core

import (
	"context"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"

	"flux/internal/config"
	"flux/internal/lan"
)

// An unknown method returns unknown_method, also when no device is
// connected, so that a typo does not look like a missing device.
func TestUnknownMethod(t *testing.T) {
	d, dev := approveDaemon()
	dev.Paired = false
	if _, err := d.Call(context.Background(), "no.such.method", nil); errCode(err) != "unknown_method" {
		t.Fatalf("no device: %v", err)
	}
	if _, err := d.Call(context.Background(), "ring", nil); errCode(err) != "no_device" {
		t.Fatalf("a known method with no device: %v", err)
	}
}

// deviceMethods must name each method of the device switches in Call, and
// only those. A method that it does not name returns unknown_method.
func TestDeviceMethodsMatchCall(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "api.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var switches [][]string
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Name.Name != "Call" || fn.Recv == nil {
			continue
		}
		ast.Inspect(fn.Body, func(n ast.Node) bool {
			sw, ok := n.(*ast.SwitchStmt)
			if !ok {
				return true
			}
			if tag, ok := sw.Tag.(*ast.Ident); !ok || tag.Name != "method" {
				return true
			}
			var names []string
			for _, stmt := range sw.Body.List {
				for _, e := range stmt.(*ast.CaseClause).List {
					if lit, ok := e.(*ast.BasicLit); ok && lit.Kind == token.STRING {
						name, _ := strconv.Unquote(lit.Value)
						names = append(names, name)
					}
				}
			}
			switches = append(switches, names)
			return true
		})
	}
	if len(switches) < 2 {
		t.Fatalf("found %d method switches in Call", len(switches))
	}
	found := map[string]bool{}
	for _, names := range switches[1:] {
		for _, name := range names {
			found[name] = true
			if !deviceMethods[name] {
				t.Errorf("deviceMethods does not name %q", name)
			}
		}
	}
	for name := range deviceMethods {
		if !found[name] {
			t.Errorf("deviceMethods names %q, which is not a device method of Call", name)
		}
	}
	for _, name := range switches[0] {
		if deviceMethods[name] {
			t.Errorf("%q needs no device, but deviceMethods names it", name)
		}
	}
}

// A button of an old desktop notification does not reach a device after an
// unpair, also while the device stays connected.
func TestSendNeedsPairedDevice(t *testing.T) {
	d, dev := approveDaemon()
	dev.Paired = false
	// The check comes before the link, so this empty link gets nothing.
	dev.link = &lan.Link{}
	// The notification and its action exist, so only the pair check can
	// stop the packet.
	dev.notifications = []*PhoneNotification{{ID: "n1", Actions: []string{"Mark as read"}}}
	if err := d.NotificationAction(dev, "n1", "Mark as read"); errCode(err) != "not_paired" {
		t.Fatalf("got %v", err)
	}
}

// update.sendApp sends a file, so it needs a paired device.
func TestSendAppNeedsPairedDevice(t *testing.T) {
	d, dev := approveDaemon()
	dev.Paired = false
	if _, err := d.Call(context.Background(), "update.sendApp", []byte(`{"device":"phone1"}`)); errCode(err) != "not_paired" {
		t.Fatalf("got %v", err)
	}
}

// A request ends when the connection of its helper closes.
func TestApprovalEndsWithItsConnection(t *testing.T) {
	d, _ := approveDaemon()
	a := &approval{id: "a1", kind: "request", device: "phone1", deadline: time.Now().Add(time.Minute)}
	if err := d.approvals.add(a); err != nil {
		t.Fatal(err)
	}
	ctx, closeConn := context.WithCancel(context.Background())
	d.cancelOnClose(ctx, a.id)
	closeConn()
	deadline := time.Now().Add(2 * time.Second)
	for d.approvals.pending() > 0 {
		if time.Now().After(deadline) {
			t.Fatal("the request stays after its connection closed")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// The phone is free for the next request at once.
	if err := d.approvals.add(&approval{id: "a2", kind: "request", device: "phone1", deadline: time.Now().Add(time.Minute)}); err != nil {
		t.Fatalf("the next request: %v", err)
	}
}

// Changes that come at the same time reach config.toml in their order, so
// the file holds the newest value.
func TestSettingsSaveInOrder(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	cfg, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	d, _ := approveDaemon()
	d.cfg = cfg
	var wg sync.WaitGroup
	for i := range 40 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := d.setSetting("autoClipboard", i%2 == 0); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	saved, err := config.Load()
	if err != nil {
		t.Fatal(err)
	}
	if saved.AutoClipboard != d.cfg.AutoClipboard {
		t.Fatalf("config.toml has auto_clipboard = %v, and fluxd has %v", saved.AutoClipboard, d.cfg.AutoClipboard)
	}
}

// The state has no phone data of a device that is not paired, for
// example after an unpair while the device stays connected.
func TestSnapshotHidesDataOfUnpairedDevice(t *testing.T) {
	d, dev := approveDaemon()
	dev.Paired = false
	// A device that is not paired shows only while it is connected.
	dev.link = &lan.Link{}
	dev.battery = &Battery{Charge: 50}
	dev.notifications = []*PhoneNotification{{ID: "n1", Title: "Code 1234"}}
	dev.conversations = map[int64]*Conversation{1: {}}
	dev.outbox = []OutboxMessage{{Thread: 1, Body: "On my way", Pending: true}}
	var s struct {
		Devices []struct {
			ID            string            `json:"id"`
			Battery       *Battery          `json:"battery"`
			Notifications []json.RawMessage `json:"notifications"`
			Conversations []json.RawMessage `json:"conversations"`
			Outbox        []json.RawMessage `json:"outbox"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(d.Snapshot(), &s); err != nil {
		t.Fatal(err)
	}
	if len(s.Devices) != 1 || s.Devices[0].ID != "phone1" {
		t.Fatalf("devices %+v", s.Devices)
	}
	if v := s.Devices[0]; v.Battery != nil || len(v.Notifications) != 0 || len(v.Conversations) != 0 || v.Outbox == nil || len(v.Outbox) != 0 {
		t.Fatalf("the state of an unpaired device has phone data: %+v", v)
	}
}

// An unpair that cannot change devices.json returns an error, because the
// device is paired again after a restart.
func TestUnpairReportsATrustError(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root can write to a read-only folder")
	}
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	ts, err := config.LoadTrust()
	if err != nil {
		t.Fatal(err)
	}
	if err := ts.Put(config.TrustedDevice{ID: "phone1", Name: "Pixel 8"}); err != nil {
		t.Fatal(err)
	}
	dir := config.DataDir()
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o700) })
	d, dev := approveDaemon()
	d.trust = ts
	if err := d.Unpair(dev); errCode(err) != "not_saved" {
		t.Fatalf("got %v", err)
	}
	if dev.Paired {
		t.Fatal("the device stays paired in fluxd")
	}
}

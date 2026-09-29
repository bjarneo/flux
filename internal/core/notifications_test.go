package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"flux/internal/config"
	"flux/internal/proto"
)

// waitIdle waits until the worker of q has run all its jobs.
func waitIdle(t *testing.T, d *Daemon, q *contentQueue) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		d.mu.Lock()
		idle := !q.running && len(q.jobs) == 0
		d.mu.Unlock()
		if idle {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the worker did not finish within 5 seconds")
}

func testDaemon() *Daemon {
	return &Daemon{
		cfg:     &config.Config{Notifications: true, AutoClipboard: true},
		clip:    &memClipboard{},
		devices: map[string]*Device{},
		logger:  log.New(io.Discard, "", 0),
	}
}

func notificationPacket(body map[string]any) *proto.Packet {
	return proto.New(proto.TypeNotification, body)
}

func TestDismissable(t *testing.T) {
	list := []*PhoneNotification{
		{ID: "a", Clear: true},
		{ID: "media", Clear: false},
		{ID: "b", Clear: true},
	}
	if got := dismissable(list); !slices.Equal(got, []string{"a", "b"}) {
		t.Fatalf("dismissable: %v", got)
	}
	if got := dismissable(nil); len(got) != 0 {
		t.Fatalf("no notifications: %v", got)
	}
}

func TestDismissAllNotificationsOffline(t *testing.T) {
	d := &Daemon{}
	dev := newDevice("p1")
	dev.Name = "Pixel 8"

	// Only an ongoing notification: nothing to send, so no link is needed.
	dev.notifications = []*PhoneNotification{{ID: "media"}}
	if n, err := d.DismissAllNotifications(dev); n != 0 || err != nil {
		t.Fatalf("ongoing only: %d, %v", n, err)
	}

	// An offline phone keeps its notifications.
	dev.notifications = []*PhoneNotification{{ID: "a", Clear: true}, {ID: "media"}}
	var e *Error
	if n, err := d.DismissAllNotifications(dev); n != 0 || !errors.As(err, &e) || e.Code != "offline" {
		t.Fatalf("offline: %d, %v", n, err)
	}
	if len(dev.notifications) != 2 {
		t.Fatalf("an offline phone lost notifications: %d left", len(dev.notifications))
	}
}

// TestHandleNotificationLimits checks that fluxd cuts the text of a phone
// notification and keeps a limited number of short actions.
func TestHandleNotificationLimits(t *testing.T) {
	d := testDaemon()
	dev := newDevice("p1")
	dev.Paired = true
	actions := []string{"Reply", strings.Repeat("a", maxNotifAction+1)}
	for i := range 10000 {
		actions = append(actions, fmt.Sprint("Action ", i))
	}
	d.handleNotification(dev, nil, notificationPacket(map[string]any{
		"id": "k1", "appName": strings.Repeat("é", maxNotifApp), "title": strings.Repeat("t", 5000),
		"text": strings.Repeat("ü", 1<<20), "actions": actions, "requestReplyId": strings.Repeat("r", maxNotifID+1),
	}))
	if len(dev.notifications) != 1 {
		t.Fatalf("%d notifications", len(dev.notifications))
	}
	n := dev.notifications[0]
	if len(n.App) > maxNotifApp || len(n.Title) > maxNotifTitle || len(n.Text) > maxNotifText {
		t.Errorf("app %d, title %d, text %d bytes", len(n.App), len(n.Title), len(n.Text))
	}
	if !utf8.ValidString(n.App) || !utf8.ValidString(n.Text) {
		t.Error("a cut made invalid UTF-8")
	}
	if len(n.Actions) != maxNotifActions || n.Actions[0] != "Reply" || n.Actions[1] != "Action 0" {
		t.Errorf("actions %q", n.Actions)
	}
	if n.ReplyID != "" {
		t.Errorf("reply ID of %d bytes", len(n.ReplyID))
	}

	// An ID that is too long drops the notification.
	d.handleNotification(dev, nil, notificationPacket(map[string]any{"id": strings.Repeat("x", maxNotifID+1), "title": "x"}))
	if len(dev.notifications) != 1 {
		t.Fatalf("%d notifications after a long ID", len(dev.notifications))
	}
}

func TestNotificationActionNeedsKnownAction(t *testing.T) {
	d := testDaemon()
	dev := newDevice("p1")
	dev.Name = "Pixel 8"
	dev.notifications = []*PhoneNotification{{ID: "k1", Actions: []string{"Mark as read"}}}
	var e *Error
	for _, c := range [][2]string{{"k1", "Delete"}, {"k2", "Mark as read"}} {
		if err := d.NotificationAction(dev, c[0], c[1]); !errors.As(err, &e) || e.Code != "not_found" {
			t.Errorf("%s %s: %v", c[0], c[1], err)
		}
	}
	// A known action passes the check and needs the link.
	if err := d.NotificationAction(dev, "k1", "Mark as read"); !errors.As(err, &e) || e.Code != "offline" {
		t.Errorf("known action: %v", err)
	}
}

// TestSnapshotUnderLoad reads the state while phone packets change it. The
// race detector checks that Snapshot encodes only a copy of the state.
func TestSnapshotUnderLoad(t *testing.T) {
	d := testDaemon()
	dev := newDevice("p1")
	dev.Name, dev.Paired = "Pixel 8", true
	d.devices[dev.ID] = dev
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := range 300 {
			d.handleNotification(dev, nil, notificationPacket(map[string]any{"id": fmt.Sprint(i % 7), "title": "t", "text": fmt.Sprint(i)}))
			if i%5 == 0 {
				d.handleNotification(dev, nil, notificationPacket(map[string]any{"id": fmt.Sprint(i % 7), "isCancel": true}))
			}
			d.handleSms(dev, smsPacket(map[string]any{"messages": []any{wireMessage(int64(i), int64(i%600), int64(i), 1, 0)}}))
			tr := d.newTransfer(dev, "a.txt", "", "in", 10)
			d.progress(tr)(5)
		}
	}()
	for range 50 {
		var state struct {
			Devices []DeviceView `json:"devices"`
		}
		if err := json.Unmarshal(d.Snapshot(), &state); err != nil {
			t.Fatal(err)
		}
	}
	wg.Wait()
}

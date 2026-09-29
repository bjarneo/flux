package core

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

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

func TestPruneIcons(t *testing.T) {
	dir := t.TempDir()
	oldIcon, newIcon := filepath.Join(dir, "old.png"), filepath.Join(dir, "new.png")
	for _, p := range []string{oldIcon, newIcon} {
		if err := os.WriteFile(p, []byte("png"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-2 * iconMaxAge)
	if err := os.Chtimes(oldIcon, past, past); err != nil {
		t.Fatal(err)
	}
	pruneIcons(dir, iconMaxAge)
	if _, err := os.Stat(oldIcon); !os.IsNotExist(err) {
		t.Error("the old icon is still there")
	}
	if _, err := os.Stat(newIcon); err != nil {
		t.Errorf("the new icon is gone: %v", err)
	}
}

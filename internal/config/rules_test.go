package config

import (
	"testing"
	"time"
)

func TestNotificationQuietHours(t *testing.T) {
	r := NotificationRule{App: "*", Mode: "silent", Start: "22:00", End: "07:00"}
	if err := r.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		hour  int
		match bool
	}{{6, true}, {7, false}, {12, false}, {22, true}, {23, true}} {
		now := time.Date(2026, 10, 3, tc.hour, 0, 0, 0, time.UTC)
		if r.Matches("phone", "Chat", now) != tc.match {
			t.Fatal(tc)
		}
	}
	r.Device, r.App = "one", "Chat"
	now := time.Date(2026, 10, 3, 23, 0, 0, 0, time.UTC)
	if r.Matches("two", "Chat", now) || r.Matches("one", "Other", now) {
		t.Fatal("rule crossed a device or app boundary")
	}
	r.Until = now.Unix()
	if r.Matches("one", "Chat", now) {
		t.Fatal("expired rule matched")
	}
}

package main

import (
	"errors"
	"testing"

	"flux/internal/approve"
)

func testEnv(vars map[string]string) env {
	return env{
		getenv: func(k string) string { return vars[k] },
		getuid: func() int { return 0 },
		lookup: func(name string) (approve.User, error) {
			switch name {
			case "alice":
				return approve.User{Name: "alice", UID: 1000}, nil
			case "root":
				return approve.User{Name: "root", UID: 0}, nil
			}
			return approve.User{}, errors.New("no such user")
		},
		hostname: func() (string, error) { return "omarchy-xps", nil },
	}
}

func TestRunNeedsAuthType(t *testing.T) {
	for _, typ := range []string{"", "account", "session", "password", "open_session"} {
		if _, err := options(testEnv(map[string]string{"PAM_TYPE": typ, "PAM_USER": "alice", "PAM_SERVICE": "sudo"})); err == nil {
			t.Errorf("PAM_TYPE %q: want an error", typ)
		}
	}
}

func TestRunRefusesRootUser(t *testing.T) {
	for _, user := range []string{"root", "nobody-here", "", "../alice"} {
		if _, err := options(testEnv(map[string]string{"PAM_TYPE": "auth", "PAM_USER": user, "PAM_SERVICE": "sudo"})); err == nil {
			t.Errorf("PAM_USER %q: want an error", user)
		}
	}
}

// The key path and the socket come from fixed rules. The environment of
// the PAM caller cannot move them.
func TestRunUsesFixedPaths(t *testing.T) {
	o, err := options(testEnv(map[string]string{
		"PAM_TYPE": "auth", "PAM_USER": "alice", "PAM_SERVICE": "sudo", "PAM_RUSER": "alice", "PAM_TTY": "/dev/pts/3",
		"FLUX_SOCKET": "/tmp/evil.sock", "XDG_RUNTIME_DIR": "/tmp/evil",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if o.KeyPath != "/etc/flux/approve/alice.pub" || o.KeyOwner != 0 {
		t.Errorf("key %s owned by %d", o.KeyPath, o.KeyOwner)
	}
	if o.Socket != "/run/user/1000/flux/fluxd.sock" || o.PeerUID != 1000 {
		t.Errorf("socket %s of user %d", o.Socket, o.PeerUID)
	}
	if o.RUser != "alice" || o.UserUID != 1000 || o.CallerUID != 0 || o.TTY != "/dev/pts/3" || o.Host != "omarchy-xps" {
		t.Errorf("options %+v", o)
	}
}

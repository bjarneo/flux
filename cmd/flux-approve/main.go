// Command flux-approve is the PAM helper for approval with a fingerprint.
// pam_exec runs it with this line in a PAM file:
//
//	auth sufficient pam_exec.so quiet stdout /usr/lib/flux/flux-approve
//
// It exits with 0 only when the paired phone signed the request. Any other
// result is exit 1, and PAM then asks for the password. The key path, the
// socket, and the host come from fixed rules, never from a flag or the
// environment. docs/approve.md is the security design.
package main

import (
	"context"
	"errors"
	"os"
	"os/signal"
	"syscall"
	"time"

	"golang.org/x/sys/unix"

	"flux/internal/approve"
)

func main() { os.Exit(run()) }

// env is what the helper reads from the process: the PAM variables, the
// real user ID, the user database, and the host name. Tests replace it.
type env struct {
	getenv   func(string) string
	getuid   func() int
	lookup   func(string) (approve.User, error)
	hostname func() (string, error)
}

var system = env{getenv: os.Getenv, getuid: os.Getuid, lookup: approve.LookupUser, hostname: os.Hostname}

// options returns the options of 1 approval from e.
func options(e env) (approve.Options, error) {
	// pam_exec sets PAM_TYPE. The helper only authenticates.
	if e.getenv("PAM_TYPE") != "auth" {
		return approve.Options{}, errors.New("PAM_TYPE is not auth")
	}
	name := e.getenv("PAM_USER")
	u, err := e.lookup(name)
	if err != nil {
		return approve.Options{}, err
	}
	if u.UID <= 0 {
		return approve.Options{}, errors.New("the helper does not approve for root")
	}
	host, err := e.hostname()
	if err != nil {
		return approve.Options{}, err
	}
	return approve.Options{
		User:    name,
		Service: e.getenv("PAM_SERVICE"),
		TTY:     e.getenv("PAM_TTY"),
		RHost:   e.getenv("PAM_RHOST"),
		Host:    host,
		KeyPath: approve.KeyPath(name),
		// Only root can own the key file.
		KeyOwner: 0,
		Socket:   approve.SocketPath(u.UID),
		PeerUID:  u.UID,
		MaxWait:  approve.MaxWait,
		Out:      os.Stdout,

		RUser:     e.getenv("PAM_RUSER"),
		CallerUID: e.getuid(),
		UserUID:   u.UID,
	}, nil
}

func run() int {
	// pam_exec starts the helper in a new session, so Ctrl+C in the
	// terminal does not reach it. The helper stops when its PAM caller
	// stops, and the request then ends on the phone.
	parent := os.Getppid()
	_ = unix.Prctl(unix.PR_SET_PDEATHSIG, uintptr(syscall.SIGTERM), 0, 0, 0)
	if os.Getppid() != parent {
		return 1
	}
	o, err := options(system)
	if err != nil {
		return 1
	}
	ctx, cancel := context.WithTimeout(context.Background(), approve.MaxWait+10*time.Second)
	defer cancel()
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stop()
	if err := approve.Run(ctx, o); err != nil {
		return 1
	}
	return 0
}

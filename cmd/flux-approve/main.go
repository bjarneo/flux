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
	"fmt"
	"os"
	"os/user"
	"strconv"
	"time"

	"flux/internal/approve"
)

func main() { os.Exit(run()) }

func run() int {
	// pam_exec sets PAM_TYPE. The helper only authenticates.
	if os.Getenv("PAM_TYPE") != "auth" {
		return 1
	}
	name := os.Getenv("PAM_USER")
	if !approve.ValidUser(name) {
		return 1
	}
	u, err := user.Lookup(name)
	if err != nil {
		return 1
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil || uid <= 0 {
		return 1
	}
	host, err := os.Hostname()
	if err != nil {
		return 1
	}
	o := approve.Options{
		User:    name,
		Service: os.Getenv("PAM_SERVICE"),
		TTY:     os.Getenv("PAM_TTY"),
		RHost:   os.Getenv("PAM_RHOST"),
		Host:    host,
		KeyPath: approve.KeyPath(name),
		// Only root can own the key file.
		KeyOwner: 0,
		Socket:   fmt.Sprintf("/run/user/%d/flux/fluxd.sock", uid),
		PeerUID:  uid,
		MaxWait:  approve.MaxWait,
		Out:      os.Stdout,
	}
	ctx, cancel := context.WithTimeout(context.Background(), approve.MaxWait+10*time.Second)
	defer cancel()
	if err := approve.Run(ctx, o); err != nil {
		return 1
	}
	return 0
}

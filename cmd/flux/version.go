package main

import (
	"fmt"
	"strings"

	"flux/internal/config"
)

// printVersion prints the version of flux-cli, then the version of the
// running fluxd and of a new fluxd that waits for its restart.
func printVersion() {
	fmt.Println("flux-cli", version)
	var s State
	if err := callInto("state", nil, &s); err != nil {
		fmt.Println("fluxd does not run")
		return
	}
	if s.Self.Version == "" {
		fmt.Println("fluxd runs an earlier version. To use the installed version, run: systemctl --user restart fluxd")
		return
	}
	fmt.Println("fluxd", s.Self.Version)
	if p := s.Self.PendingVersion; p != "" {
		fmt.Printf("fluxd %s is installed. fluxd.service restarts into it when no transfer or stream runs\n", p)
	}
	if u := s.Update; u.Available {
		fmt.Printf("Flux %s is available. To update, run: flux-cli update\n", u.Latest)
	}
}

// checkVersion compares the running fluxd with the installed fluxd and
// with flux-cli.
func checkVersion(s State, check func(ok bool, pass, fix string)) {
	running, pending := s.Self.Version, s.Self.PendingVersion
	switch {
	case running == "":
		check(false, "", "fluxd runs an earlier version. To use the installed version, run: systemctl --user restart fluxd")
	case pending != "":
		fmt.Printf("- fluxd %s runs, and fluxd %s is installed. fluxd.service restarts into it when no transfer or stream runs\n", running, pending)
	case sameVersion(running, version):
		check(true, fmt.Sprintf("fluxd %s runs, the same version as flux-cli", running), "")
	default:
		fmt.Printf("- fluxd %s runs, and flux-cli is %s. They come from different installs. To see the fluxd path, run: systemctl --user cat fluxd\n", running, version)
	}

	u := s.Update
	switch {
	case !u.Enabled:
		fmt.Println("- The release check is off. To turn it on, set check_updates = true in", config.Path())
	case u.Available:
		fmt.Printf("- Flux %s is available. To update, run: flux-cli update\n", u.Latest)
	case u.Error != "":
		fmt.Println("- The last release check failed:", u.Error)
		fmt.Println("  Flux works without the internet. fluxd tries again in 1 hour or after a network change")
	case u.CheckedAt > 0:
		check(true, fmt.Sprintf("Flux %s is the latest release", u.Latest), "")
	}
}

// sameVersion compares 2 build versions. The package gives 0.7.0, and git
// describe gives v0.7.0.
func sameVersion(a, b string) bool {
	return strings.TrimPrefix(a, "v") == strings.TrimPrefix(b, "v")
}

package main

import "fmt"

// latestRelease is the page with the latest apps.
const latestRelease = "https://github.com/bjarneo/flux/releases/latest"

// oldAppFix is the fix for a device with a Flux app from before 0.8. That
// app cannot connect to this fluxd, so flux-cli update --phone cannot send
// the new app either.
func oldAppFix(name string) string {
	return fmt.Sprintf("%s runs a Flux app older than 0.8, which cannot connect to this computer. Install the latest app from %s", name, latestRelease)
}

// oldAppProblems returns the fix for each paired device with an app from
// before Flux 0.8.
func oldAppProblems(s *State) []string {
	var out []string
	for _, d := range s.Devices {
		if d.Paired && d.OldApp {
			out = append(out, oldAppFix(d.Name))
		}
	}
	return out
}

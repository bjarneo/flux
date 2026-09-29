package main

import (
	"strings"
	"testing"
)

func TestVersionCheck(t *testing.T) {
	ok, pass, _, _ := versionCheck("0.6.0", "0.6.0")
	if !ok {
		t.Error("the same version should pass:", pass)
	}

	ok, _, fix, _ := versionCheck("0.5.0", "0.6.0")
	if ok {
		t.Error("a mismatch should fail")
	}
	if !strings.Contains(fix, "flux-cli is 0.6.0") || !strings.Contains(fix, "systemctl --user restart fluxd") {
		t.Errorf("the fix should name the versions and the command, got %q", fix)
	}

	ok, _, fix, _ = versionCheck("", "0.6.0")
	if ok {
		t.Error("a daemon without a version should fail")
	}
	if !strings.Contains(fix, "no version") {
		t.Errorf("the fix should explain the empty version, got %q", fix)
	}
}

func TestVersionCheckReleases(t *testing.T) {
	for _, running := range []string{"v0.6.0-1-ga21d58c", "v0.6.0-12-gabc-dirty", "v0.6.0+build5"} {
		if ok, _, _, _ := versionCheck(running, "0.6.0"); !ok {
			t.Errorf("a build of release 0.6.0 should pass, got %q", running)
		}
	}
	if ok, _, _, _ := versionCheck("v0.6.0-1-ga21d58c", "v0.6.0-2-gdeadbee"); !ok {
		t.Error("two builds of the same release should pass")
	}

	ok, _, _, note := versionCheck("dev", "0.6.0")
	if !ok {
		t.Error("a build without a release should not fail")
	}
	if note == "" {
		t.Error("a build without a release should get a note")
	}

	if ok, _, _, _ := versionCheck("v0.5.0-14-gabc", "0.6.0"); ok {
		t.Error("an older release should still fail")
	}
}

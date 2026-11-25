package main

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestPrintSSH(t *testing.T) {
	v := sshKeys{Socket: "/run/user/1000/flux/ssh-agent.sock", Keys: []sshKey{{
		Device: "abc", Name: "Pixel 8", Key: "ecdsa-sha2-nistp256 AAAA Flux on Pixel 8", Fingerprint: "SHA256:xyz",
	}}}
	var b bytes.Buffer
	if err := printSSH(&b, v, ""); err != nil {
		t.Fatal(err)
	}
	want := "Pixel 8 · SHA256:xyz\necdsa-sha2-nistp256 AAAA Flux on Pixel 8\n\nexport SSH_AUTH_SOCK=/run/user/1000/flux/ssh-agent.sock\n"
	if b.String() != want {
		t.Fatalf("got %q, want %q", b.String(), want)
	}
	b.Reset()
	if err := printSSH(&b, v, "key"); err != nil || b.String() != "ecdsa-sha2-nistp256 AAAA Flux on Pixel 8\n" {
		t.Fatalf("key: %v %q", err, b.String())
	}
	b.Reset()
	if err := printSSH(&b, v, "socket"); err != nil || b.String() != v.Socket+"\n" {
		t.Fatalf("socket: %v %q", err, b.String())
	}

	// Without a key, the socket still prints, and the command fails.
	v.Keys = nil
	v.Socket = "/tmp/a b/ssh-agent.sock"
	b.Reset()
	if err := printSSH(&b, v, ""); !errors.Is(err, errNoSSHKey) || !strings.Contains(b.String(), "export SSH_AUTH_SOCK='/tmp/a b/ssh-agent.sock'") {
		t.Fatalf("no key: %v %q", err, b.String())
	}
	b.Reset()
	if err := printSSH(&b, v, "socket"); err != nil {
		t.Fatalf("socket without a key: %v", err)
	}
	// Without a socket, only the keys can print.
	v.Socket, v.Error = "", "permission denied"
	if err := printSSH(&b, v, ""); err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("no socket: %v", err)
	}
}

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
)

// sshKeys is the answer of the fluxd method ssh.keys.
type sshKeys struct {
	Socket string   `json:"socket"`
	Error  string   `json:"error,omitempty"`
	Keys   []sshKey `json:"keys"`
}

// sshKey is the key of 1 connected phone. Key is the line for
// authorized_keys.
type sshKey struct {
	Device      string `json:"device"`
	Name        string `json:"name"`
	Key         string `json:"key"`
	Fingerprint string `json:"fingerprint"`
}

// errNoSSHKey tells the user how to turn the key on.
var errNoSSHKey = errors.New("no connected phone offers an SSH key. In Flux on the phone, open Computers, then SSH key, and turn on SSH key")

// sshCmd runs flux-cli ssh, ssh key, and ssh socket, each with --json.
// docs/ssh.md describes the agent.
func sshCmd(args []string, device string) error {
	asJSON := slices.Contains(args, "--json")
	args = slices.DeleteFunc(slices.Clone(args), func(a string) bool { return a == "--json" })
	what := first(args)
	if what != "" && what != "key" && what != "socket" {
		return fmt.Errorf("unknown command: ssh %s. Use key or socket", what)
	}
	var v sshKeys
	if err := callInto("ssh.keys", nil, &v); err != nil {
		return err
	}
	if device != "" {
		v.Keys = slices.DeleteFunc(v.Keys, func(k sshKey) bool {
			return k.Device != device && !strings.EqualFold(k.Name, device)
		})
	}
	if asJSON {
		b, err := json.MarshalIndent(v, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(b))
		return nil
	}
	return printSSH(os.Stdout, v, what)
}

// printSSH writes the keys and the socket of v to w. what is "" for both,
// "key" for the keys only, and "socket" for the path only.
func printSSH(w io.Writer, v sshKeys, what string) error {
	if what != "key" && v.Socket == "" {
		return fmt.Errorf("fluxd has no ssh-agent socket: %s", v.Error)
	}
	switch what {
	case "socket":
		fmt.Fprintln(w, v.Socket)
		return nil
	case "key":
		for _, k := range v.Keys {
			fmt.Fprintln(w, k.Key)
		}
	default:
		for _, k := range v.Keys {
			fmt.Fprintf(w, "%s · %s\n%s\n\n", k.Name, k.Fingerprint, k.Key)
		}
		fmt.Fprintf(w, "export SSH_AUTH_SOCK=%s\n", shellQuote(v.Socket))
	}
	if len(v.Keys) == 0 {
		return errNoSSHKey
	}
	return nil
}

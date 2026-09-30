// Command signsums signs the SHA256SUMS file of a Flux release with
// Ed25519, and makes the key pair. The release workflow runs it. See
// docs/releasing.md.
//
//	go run ./scripts/signsums keygen FILE
//	    Writes a new private key to FILE and prints its public key.
//	go run ./scripts/signsums key
//	    Prints release.PublicKey, or nothing while the constant is empty.
//	go run ./scripts/signsums sign SHA256SUMS
//	    Writes SHA256SUMS.sig with the private key in RELEASE_SIGNING_KEY.
//	    When release.PublicKey is set, the private key must match it.
//	go run ./scripts/signsums verify SHA256SUMS [KEY]
//	    Checks SHA256SUMS.sig with the public key KEY, or with
//	    release.PublicKey.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strings"

	"flux/internal/release"
)

const usage = "usage: signsums keygen FILE | key | sign SHA256SUMS | verify SHA256SUMS [KEY]"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "signsums:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	switch {
	case len(args) == 2 && args[0] == "keygen":
		return keygen(args[1])
	case len(args) == 1 && args[0] == "key":
		if release.PublicKey != "" {
			fmt.Println(release.PublicKey)
		}
		return nil
	case len(args) == 2 && args[0] == "sign":
		return sign(args[1], os.Getenv("RELEASE_SIGNING_KEY"), release.PublicKey)
	case len(args) == 2 && args[0] == "verify":
		return verify(args[1], release.PublicKey)
	case len(args) == 3 && args[0] == "verify":
		return verify(args[1], args[2])
	}
	return errors.New(usage)
}

// keygen writes a new seed to path, readable only by the user, and prints
// the public key for release.PublicKey.
func keygen(path string) error {
	seed := make([]byte, ed25519.SeedSize)
	if _, err := rand.Read(seed); err != nil {
		return err
	}
	text := base64.StdEncoding.EncodeToString(seed)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintln(f, text); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	key, err := release.KeyOf(text)
	if err != nil {
		return err
	}
	fmt.Println(key)
	return nil
}

// sign writes path.sig with seed. When want is not empty, the public key
// of seed must be want, because flux-cli and fluxd check the signature
// with want. So a wrong secret stops the release before it publishes a
// signature that the installed copies refuse.
func sign(path, seed, want string) error {
	if seed == "" {
		return errors.New("RELEASE_SIGNING_KEY is not set")
	}
	key, err := release.KeyOf(seed)
	if err != nil {
		return err
	}
	if want = strings.TrimSpace(want); want != "" && key != want {
		return fmt.Errorf("the public key of RELEASE_SIGNING_KEY is %s, and internal/release has %s. flux-cli and fluxd refuse a release with this signature", key, want)
	}
	sums, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	sig, err := release.Sign(sums, seed)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path+".sig", sig, 0o644); err != nil {
		return err
	}
	fmt.Printf("Signed %s with the public key %s\n", path, key)
	return nil
}

// verify checks path.sig with the public key key. The key of this
// checkout is release.PublicKey. Before the constant is set, give the key
// from keygen.
func verify(path, key string) error {
	if key == "" {
		return errors.New("internal/release has no PublicKey. Give the public key from keygen: signsums verify SHA256SUMS KEY")
	}
	sums, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	sig, err := os.ReadFile(path + ".sig")
	if err != nil {
		return err
	}
	if err := release.CheckSignature(sums, sig, key); err != nil {
		return err
	}
	fmt.Printf("%s.sig is a valid signature of %s\n", path, path)
	return nil
}

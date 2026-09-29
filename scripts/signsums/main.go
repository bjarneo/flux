// Command signsums signs the SHA256SUMS file of a Flux release with
// Ed25519, and makes the key pair. The release workflow runs it. See
// docs/releasing.md.
//
//	go run ./scripts/signsums keygen FILE
//	    Writes a new private key to FILE and prints its public key.
//	go run ./scripts/signsums sign SHA256SUMS
//	    Writes SHA256SUMS.sig with the private key in RELEASE_SIGNING_KEY.
//	go run ./scripts/signsums verify SHA256SUMS
//	    Checks SHA256SUMS.sig with release.PublicKey.
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"

	"flux/internal/release"
)

const usage = "usage: signsums keygen FILE | sign SHA256SUMS | verify SHA256SUMS"

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "signsums:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) != 2 {
		return errors.New(usage)
	}
	switch args[0] {
	case "keygen":
		return keygen(args[1])
	case "sign":
		return sign(args[1])
	case "verify":
		return verify(args[1])
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

// sign writes path.sig with the seed in RELEASE_SIGNING_KEY.
func sign(path string) error {
	seed := os.Getenv("RELEASE_SIGNING_KEY")
	if seed == "" {
		return errors.New("RELEASE_SIGNING_KEY is not set")
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
	key, err := release.KeyOf(seed)
	if err != nil {
		return err
	}
	fmt.Printf("Signed %s with the public key %s\n", path, key)
	return nil
}

// verify checks path.sig with the public key of this checkout.
func verify(path string) error {
	if release.PublicKey == "" {
		return errors.New("internal/release has no PublicKey")
	}
	sums, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	sig, err := os.ReadFile(path + ".sig")
	if err != nil {
		return err
	}
	if err := release.CheckSignature(sums, sig, release.PublicKey); err != nil {
		return err
	}
	fmt.Printf("%s.sig is a valid signature of %s\n", path, path)
	return nil
}

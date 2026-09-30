package release

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
)

// PublicKey is the Ed25519 public key of the Flux releases, in base64. The
// release workflow signs SHA256SUMS with the private key and publishes the
// signature as SHA256SUMS.sig. Fetch accepts a release file only when the
// signature matches. While PublicKey is empty, Flux does not check the
// signature, and the callers of Fetch log that. docs/releasing.md tells
// how to make the key pair.
const PublicKey = ""

// releaseKey is the key that Fetch uses. Tests change it.
var releaseKey = PublicKey

// Signed reports whether this build checks the signature of SHA256SUMS.
func Signed() bool { return releaseKey != "" }

// CheckSignature returns nil when sig is a valid signature of sums with
// the public key key. sig is the text of SHA256SUMS.sig: the Ed25519
// signature of the exact bytes of SHA256SUMS, in base64.
func CheckSignature(sums, sig []byte, key string) error {
	pub, err := base64.StdEncoding.DecodeString(strings.TrimSpace(key))
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return errors.New("the release key of this build is not a valid Ed25519 key")
	}
	s, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sig)))
	if err != nil || len(s) != ed25519.SignatureSize {
		return errors.New("SHA256SUMS.sig is not a valid signature")
	}
	if !ed25519.Verify(pub, sums, s) {
		return errors.New("SHA256SUMS.sig does not match SHA256SUMS and the release key, so Flux does not trust this release")
	}
	return nil
}

// Sign returns the text of SHA256SUMS.sig for sums. seed is the private
// key: an Ed25519 seed of 32 bytes in base64.
func Sign(sums []byte, seed string) ([]byte, error) {
	priv, err := privateKey(seed)
	if err != nil {
		return nil, err
	}
	return []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(priv, sums)) + "\n"), nil
}

// KeyOf returns the public key of seed in base64, the value for PublicKey.
func KeyOf(seed string) (string, error) {
	priv, err := privateKey(seed)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(priv.Public().(ed25519.PublicKey)), nil
}

func privateKey(seed string) (ed25519.PrivateKey, error) {
	b, err := base64.StdEncoding.DecodeString(strings.TrimSpace(seed))
	if err != nil || len(b) != ed25519.SeedSize {
		return nil, errors.New("the signing key is not an Ed25519 seed of 32 bytes in base64")
	}
	return ed25519.NewKeyFromSeed(b), nil
}

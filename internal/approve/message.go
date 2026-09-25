// Package approve lets a paired phone approve a PAM login with a
// fingerprint. docs/approve.md is the security design.
package approve

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

// The first line of each signed message names the version and the
// purpose, so that an enrollment signature is never a valid approval.
const (
	approveVersion = "flux-approve-v1"
	enrollVersion  = "flux-approve-enroll-v1"
)

// maxField is the longest field value in bytes.
const maxField = 256

// maxFuture is how far in the future a signed time can be.
const maxFuture = 5 * time.Second

var (
	// ErrBadSignature means that the signature does not match the key and
	// the message.
	ErrBadSignature = errors.New("the signature is not valid")
	// ErrStale means that the signed time is too old or in the future.
	ErrStale = errors.New("the signed time is out of range")
)

// Request is 1 approval request. The helper makes it, and the phone signs
// it.
type Request struct {
	Host    string
	User    string
	Service string
	TTY     string
	RHost   string
	// Time is the Unix time in seconds when the helper made the request.
	Time int64
	// Nonce is 32 random bytes as 64 lowercase hex digits.
	Nonce string
}

// Message returns the exact bytes that the phone signs.
func (r Request) Message() ([]byte, error) {
	if err := checkFields(map[string]string{"host": r.Host, "user": r.User, "service": r.Service}, true); err != nil {
		return nil, err
	}
	if err := checkFields(map[string]string{"tty": r.TTY, "rhost": r.RHost}, false); err != nil {
		return nil, err
	}
	if err := checkNonce(r.Nonce); err != nil {
		return nil, err
	}
	var b strings.Builder
	b.WriteString(approveVersion + "\n")
	b.WriteString("host=" + r.Host + "\n")
	b.WriteString("user=" + r.User + "\n")
	b.WriteString("service=" + r.Service + "\n")
	b.WriteString("tty=" + r.TTY + "\n")
	b.WriteString("rhost=" + r.RHost + "\n")
	b.WriteString("time=" + strconv.FormatInt(r.Time, 10) + "\n")
	b.WriteString("nonce=" + r.Nonce + "\n")
	return []byte(b.String()), nil
}

// Enrollment is 1 enrollment request. The phone signs it with the new key.
type Enrollment struct {
	Host  string
	User  string
	Time  int64
	Nonce string
}

// Message returns the exact bytes that the phone signs for the key in
// spki, the public key in DER.
func (e Enrollment) Message(spki []byte) ([]byte, error) {
	if err := checkFields(map[string]string{"host": e.Host, "user": e.User}, true); err != nil {
		return nil, err
	}
	if err := checkNonce(e.Nonce); err != nil {
		return nil, err
	}
	sum := sha256.Sum256(spki)
	var b strings.Builder
	b.WriteString(enrollVersion + "\n")
	b.WriteString("host=" + e.Host + "\n")
	b.WriteString("user=" + e.User + "\n")
	b.WriteString("key=" + hex.EncodeToString(sum[:]) + "\n")
	b.WriteString("time=" + strconv.FormatInt(e.Time, 10) + "\n")
	b.WriteString("nonce=" + e.Nonce + "\n")
	return []byte(b.String()), nil
}

// CheckField reports whether a value can be in a signed message: valid
// UTF-8, at most 256 bytes, and no control character.
func CheckField(name, v string) error {
	if len(v) > maxField {
		return fmt.Errorf("%s is longer than %d bytes", name, maxField)
	}
	if !utf8.ValidString(v) {
		return fmt.Errorf("%s is not valid UTF-8", name)
	}
	for _, r := range v {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			return fmt.Errorf("%s has a control character", name)
		}
	}
	return nil
}

func checkFields(fields map[string]string, required bool) error {
	for name, v := range fields {
		if required && v == "" {
			return fmt.Errorf("%s is empty", name)
		}
		if err := CheckField(name, v); err != nil {
			return err
		}
	}
	return nil
}

func checkNonce(n string) error {
	if len(n) != 64 {
		return errors.New("the nonce must have 64 hex digits")
	}
	for _, c := range n {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return errors.New("the nonce must have lowercase hex digits only")
		}
	}
	return nil
}

// ParsePublicKey parses a public key in DER and accepts only EC P-256.
func ParsePublicKey(spki []byte) (*ecdsa.PublicKey, error) {
	k, err := x509.ParsePKIXPublicKey(spki)
	if err != nil {
		return nil, fmt.Errorf("the public key: %w", err)
	}
	ec, ok := k.(*ecdsa.PublicKey)
	if !ok || ec.Curve != elliptic.P256() {
		return nil, errors.New("the public key is not an EC P-256 key")
	}
	return ec, nil
}

// Fingerprint returns the key code that the terminal and the phone show:
// the first 8 bytes of the SHA-256 of the key in DER, as 4 groups of 4
// uppercase hex digits.
func Fingerprint(spki []byte) string {
	sum := sha256.Sum256(spki)
	h := strings.ToUpper(hex.EncodeToString(sum[:8]))
	return h[0:4] + " " + h[4:8] + " " + h[8:12] + " " + h[12:16]
}

// verify checks an ASN.1 DER ECDSA signature over the SHA-256 of msg.
func verify(pub *ecdsa.PublicKey, msg, sig []byte) error {
	if pub == nil || len(sig) == 0 || len(sig) > 128 {
		return ErrBadSignature
	}
	sum := sha256.Sum256(msg)
	if !ecdsa.VerifyASN1(pub, sum[:], sig) {
		return ErrBadSignature
	}
	return nil
}

// Verify checks the signature of an approval. The message comes from r,
// which the helper made itself. The signed time must be at most maxAge in
// the past and at most 5 seconds in the future.
func Verify(r Request, sig []byte, pub *ecdsa.PublicKey, now time.Time, maxAge time.Duration) error {
	msg, err := r.Message()
	if err != nil {
		return err
	}
	if err := checkTime(r.Time, now, maxAge); err != nil {
		return err
	}
	return verify(pub, msg, sig)
}

// VerifyEnrollment checks the proof that the phone holds the private key
// of spki. It returns the parsed key.
func VerifyEnrollment(e Enrollment, spki, sig []byte, now time.Time, maxAge time.Duration) (*ecdsa.PublicKey, error) {
	pub, err := ParsePublicKey(spki)
	if err != nil {
		return nil, err
	}
	msg, err := e.Message(spki)
	if err != nil {
		return nil, err
	}
	if err := checkTime(e.Time, now, maxAge); err != nil {
		return nil, err
	}
	if err := verify(pub, msg, sig); err != nil {
		return nil, err
	}
	return pub, nil
}

func checkTime(signed int64, now time.Time, maxAge time.Duration) error {
	t := time.Unix(signed, 0)
	if now.Sub(t) > maxAge || t.Sub(now) > maxFuture {
		return ErrStale
	}
	return nil
}

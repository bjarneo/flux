// Package sshagent serves the ssh-agent protocol for the SSH keys of the
// paired phones. The private key of a phone never leaves the phone. Each
// sign request goes to the phone, and the phone signs only after its user
// approves with a fingerprint or the screen lock. docs/ssh.md describes
// the feature.
package sshagent

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/asn1"
	"encoding/binary"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/ssh"

	"flux/internal/proto"
)

// The kinds of data that a phone signs.
const (
	// KindLogin is an SSH login request of RFC 4252, section 7.
	KindLogin = "login"
	// KindSignature is the signed data of an SSH signature, as
	// ssh-keygen -Y sign makes it. PROTOCOL.sshsig describes it.
	KindSignature = "signature"
)

// MaxData is the largest data that the agent sends to a phone, in bytes.
// A login request and the signed data of an SSH signature need less than
// 2 KiB.
const MaxData = 8 << 10

// maxText is the longest user name and namespace, in bytes.
const maxText = 256

// Data tells what the data of a sign request is.
type Data struct {
	// Kind is KindLogin or KindSignature.
	Kind string
	// User is the user of a login.
	User string
	// Namespace is the namespace of an SSH signature, for example git or
	// file.
	Namespace string
}

func (d Data) String() string {
	if d.Kind == KindLogin {
		return "an SSH login as " + d.User
	}
	return "an SSH signature in the namespace " + d.Namespace
}

// The login methods that sign with a key. OpenSSH 8.9 and later use the
// second method, which adds the host key of the server.
const (
	methodPublicKey = "publickey"
	methodHostBound = "publickey-hostbound-v00@openssh.com"
)

// ParseData reads the data of a sign request for the key keyBlob. A phone
// signs only 2 kinds of data: an SSH login request with this key, and the
// signed data of an SSH signature. ParseData returns an error for each
// other data, so the key cannot sign a message of another protocol.
func ParseData(data, keyBlob []byte) (Data, error) {
	if len(data) > MaxData {
		return Data{}, fmt.Errorf("the data has %d bytes, more than %d", len(data), MaxData)
	}
	if rest, ok := bytes.CutPrefix(data, []byte("SSHSIG")); ok {
		return parseSignature(rest)
	}
	return parseLogin(data, keyBlob)
}

func parseSignature(b []byte) (Data, error) {
	r := reader{b: b}
	namespace := r.text()
	_ = r.str(1024) // reserved
	hash := string(r.str(16))
	digest := r.str(64)
	switch {
	case r.err != nil:
		return Data{}, fmt.Errorf("an SSH signature that does not parse: %w", r.err)
	case len(r.b) > 0:
		return Data{}, errors.New("an SSH signature with extra bytes")
	case namespace == "":
		return Data{}, errors.New("an SSH signature without a namespace")
	case !(hash == "sha256" && len(digest) == 32) && !(hash == "sha512" && len(digest) == 64):
		return Data{}, errors.New("an SSH signature with an unknown hash")
	}
	return Data{Kind: KindSignature, Namespace: namespace}, nil
}

func parseLogin(b []byte, keyBlob []byte) (Data, error) {
	r := reader{b: b}
	session := r.str(64)
	msg := r.byte()
	user := r.text()
	service := string(r.str(64))
	method := string(r.str(64))
	signs := r.byte()
	alg := string(r.str(64))
	key := r.str(1024)
	var host []byte
	if method == methodHostBound {
		host = r.str(16 << 10)
	}
	switch {
	case r.err != nil:
		return Data{}, errors.New("the data is not an SSH login and not an SSH signature")
	case len(r.b) > 0:
		return Data{}, errors.New("a login request with extra bytes")
	case len(session) == 0 || msg != 50 || signs != 1:
		return Data{}, errors.New("the data is not an SSH login and not an SSH signature")
	case user == "":
		return Data{}, errors.New("a login request without a user")
	case service != "ssh-connection":
		return Data{}, errors.New("a login request for another service")
	case method != methodPublicKey && method != methodHostBound:
		return Data{}, errors.New("a login request with another method")
	case method == methodHostBound && len(host) == 0:
		return Data{}, errors.New("a login request without the host key")
	case alg != ssh.KeyAlgoECDSA256:
		return Data{}, errors.New("a login request for another key type")
	case !bytes.Equal(key, keyBlob):
		return Data{}, errors.New("a login request for another key")
	}
	return Data{Kind: KindLogin, User: user}, nil
}

// reader reads the SSH wire format. After the first error, each read
// returns nothing.
type reader struct {
	b   []byte
	err error
}

func (r *reader) byte() byte {
	if r.err != nil || len(r.b) < 1 {
		r.fail()
		return 0
	}
	c := r.b[0]
	r.b = r.b[1:]
	return c
}

// str reads a string of at most max bytes.
func (r *reader) str(max int) []byte {
	if r.err != nil || len(r.b) < 4 {
		r.fail()
		return nil
	}
	n := binary.BigEndian.Uint32(r.b)
	if uint64(n) > uint64(max) || uint64(n) > uint64(len(r.b)-4) {
		r.fail()
		return nil
	}
	s := r.b[4 : 4+n]
	r.b = r.b[4+n:]
	return s
}

// text reads a string that the phone can show: valid UTF-8, at most
// maxText bytes, and no control character.
func (r *reader) text() string {
	s := r.str(maxText)
	if r.err == nil && !ValidText(string(s)) {
		r.err = errors.New("a text with a control character or invalid UTF-8")
	}
	return string(s)
}

func (r *reader) fail() {
	if r.err == nil {
		r.err = errors.New("the data is too short")
	}
}

// ValidText reports whether s is valid UTF-8 with no control character and
// no bidi control. The phone shows such text as it is.
func ValidText(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	return !strings.ContainsFunc(s, proto.IsControl)
}

// KeyFromSPKI reads the public key that a phone sends: an EC P-256 key as
// a SubjectPublicKeyInfo in DER.
func KeyFromSPKI(der []byte) (ssh.PublicKey, error) {
	k, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, err
	}
	ec, ok := k.(*ecdsa.PublicKey)
	if !ok || ec.Curve != elliptic.P256() {
		return nil, errors.New("the key is not an EC P-256 key")
	}
	return ssh.NewPublicKey(ec)
}

// AuthorizedKey returns the line of key for authorized_keys, with comment
// at the end.
func AuthorizedKey(key ssh.PublicKey, comment string) string {
	line := strings.TrimSpace(string(ssh.MarshalAuthorizedKey(key)))
	if comment = strings.TrimSpace(comment); comment != "" {
		line += " " + comment
	}
	return line
}

// Signature turns the ASN.1 DER signature of a phone into an SSH signature
// of the type ecdsa-sha2-nistp256, with r and s as mpints. It checks the
// signature with key over data, so the agent never returns a signature
// that the server or ssh-keygen refuses.
func Signature(key ssh.PublicKey, data, der []byte) (*ssh.Signature, error) {
	var rs struct{ R, S *big.Int }
	rest, err := asn1.Unmarshal(der, &rs)
	if err != nil || len(rest) > 0 || rs.R == nil || rs.S == nil || rs.R.Sign() <= 0 || rs.S.Sign() <= 0 {
		return nil, errors.New("the phone sent a signature that does not parse")
	}
	sig := &ssh.Signature{Format: ssh.KeyAlgoECDSA256, Blob: ssh.Marshal(rs)}
	if err := key.Verify(data, sig); err != nil {
		return nil, errors.New("the phone sent a signature that is not valid for its key")
	}
	return sig, nil
}

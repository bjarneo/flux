package proto

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Identity files in the data directory.
const (
	certFile = "certificate.pem"
	keyFile  = "privateKey.pem"
)

// LoadOrCreateCert returns the TLS certificate of this device. The first
// run generates a self-signed ECDSA P-256 certificate with CN set to a new
// device ID. The device ID is the CN of the certificate.
func LoadOrCreateCert(dir string) (tls.Certificate, string, error) {
	certPath, keyPath := filepath.Join(dir, certFile), filepath.Join(dir, keyFile)
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err == nil {
		protect(dir, keyPath)
		leaf, perr := x509.ParseCertificate(cert.Certificate[0])
		if perr != nil {
			return tls.Certificate{}, "", perr
		}
		cert.Leaf = leaf
		return cert, leaf.Subject.CommonName, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return tls.Certificate{}, "", fmt.Errorf("load certificate: %w", err)
	}
	// A new identity never replaces a private key. The paired devices
	// pinned the certificate of that key, so the user decides.
	if _, err := os.Lstat(keyPath); err == nil {
		return tls.Certificate{}, "", fmt.Errorf("%s is missing, but %s exists. Restore the certificate, or remove the key to make a new identity that each device must pair with again", certPath, keyPath)
	}
	id := strings.ReplaceAll(newUUID(), "-", "")
	certPEM, keyPEM, err := generateCert(id)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return tls.Certificate{}, "", err
	}
	// The certificate comes first. A stop between the 2 writes then leaves
	// a certificate without its key, which the next start replaces.
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return tls.Certificate{}, "", err
	}
	f, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	if _, err := f.Write(keyPEM); err != nil {
		f.Close()
		return tls.Certificate{}, "", err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return tls.Certificate{}, "", err
	}
	if err := f.Close(); err != nil {
		return tls.Certificate{}, "", err
	}
	return LoadOrCreateCert(dir)
}

// protect removes the access of other users to the data directory and to
// the private key. A restore from a backup or a copy can give them access,
// and the key is the proof of this computer for every paired device.
func protect(dir, keyPath string) {
	for _, path := range []string{dir, keyPath} {
		if info, err := os.Stat(path); err == nil && info.Mode().Perm()&0o077 != 0 {
			_ = os.Chmod(path, info.Mode().Perm()&^0o077)
		}
	}
}

func generateCert(id string) (certPEM, keyPEM []byte, err error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(10),
		Subject: pkix.Name{
			CommonName:         id,
			Organization:       []string{"Omarchy"},
			OrganizationalUnit: []string{"Flux"},
		},
		NotBefore:          now.AddDate(-1, 0, 0),
		NotAfter:           now.AddDate(10, 0, 0),
		SignatureAlgorithm: x509.ECDSAWithSHA512,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}

func newUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

// CertPEM encodes a certificate as PEM.
func CertPEM(c *x509.Certificate) string {
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: c.Raw}))
}

// ParseCertPEM decodes a PEM certificate.
func ParseCertPEM(s string) (*x509.Certificate, error) {
	block, _ := pem.Decode([]byte(s))
	if block == nil {
		return nil, errors.New("no PEM block")
	}
	return x509.ParseCertificate(block.Bytes)
}

// VerificationKey returns the 16-character key that both devices show
// while they pair. It hashes the 2 public keys, larger first, and the
// pairing timestamp in seconds as decimal text. The key is the first 8
// bytes of the SHA-256 in uppercase hex. 64 bits keep a man in the middle
// from finding a certificate with the same key in the pair time.
func VerificationKey(own, peer *x509.Certificate, timestamp int64) string {
	return verificationKey(own.RawSubjectPublicKeyInfo, peer.RawSubjectPublicKeyInfo, timestamp)
}

func verificationKey(a, b []byte, timestamp int64) string {
	if bytes.Compare(a, b) < 0 {
		a, b = b, a
	}
	h := sha256.New()
	h.Write(a)
	h.Write(b)
	if timestamp > 0 {
		h.Write([]byte(strconv.FormatInt(timestamp, 10)))
	}
	return strings.ToUpper(hex.EncodeToString(h.Sum(nil)[:8]))
}

// Fingerprint returns 16 uppercase hex digits for a certificate: the first
// 8 bytes of the SHA-256 of its public key. It returns "" for nil.
func Fingerprint(c *x509.Certificate) string {
	if c == nil {
		return ""
	}
	sum := sha256.Sum256(c.RawSubjectPublicKeyInfo)
	return strings.ToUpper(hex.EncodeToString(sum[:8]))
}

// FormatKey writes a key or a fingerprint in groups of 4 characters, for
// example "5EE6 825F 974E D59A". Every UI shows the key in this form.
func FormatKey(key string) string {
	var b strings.Builder
	for i, r := range []rune(key) {
		if i > 0 && i%4 == 0 {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
	}
	return b.String()
}

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
// device ID, as current KDE Connect versions do. The device ID is the CN of
// the certificate.
func LoadOrCreateCert(dir string) (tls.Certificate, string, error) {
	certPath, keyPath := filepath.Join(dir, certFile), filepath.Join(dir, keyFile)
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err == nil {
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
	id := strings.ReplaceAll(newUUID(), "-", "")
	certPEM, keyPEM, err := generateCert(id)
	if err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return tls.Certificate{}, "", err
	}
	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return tls.Certificate{}, "", err
	}
	return LoadOrCreateCert(dir)
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
			Organization:       []string{"KDE"},
			OrganizationalUnit: []string{"KDE Connect"},
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

// VerificationKey returns the 8-character key that both devices show while
// they pair. It hashes the 2 public keys, larger first, and the pairing
// timestamp in seconds.
func VerificationKey(own, peer *x509.Certificate, timestamp int64) string {
	a, b := own.RawSubjectPublicKeyInfo, peer.RawSubjectPublicKeyInfo
	if bytes.Compare(a, b) < 0 {
		a, b = b, a
	}
	h := sha256.New()
	h.Write(a)
	h.Write(b)
	if timestamp > 0 {
		h.Write([]byte(strconv.FormatInt(timestamp, 10)))
	}
	return strings.ToUpper(hex.EncodeToString(h.Sum(nil))[:8])
}

// Package lan is the KDE Connect LAN backend: UDP discovery, TCP links
// with TLS, and payload sockets.
package lan

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
)

// Port ranges from the KDE Connect protocol.
const (
	UDPPort         = 1716
	MinTCPPort      = 1716
	MaxTCPPort      = 1764
	MinPayloadPort  = 1739
	MaxPayloadPort  = 1764
	maxIdentitySize = 64 << 10
)

// cipherSuites limits TLS 1.2 to forward-secret suites. The CBC suites keep
// older Android and Qt peers working. TLS 1.3 ignores this list.
var cipherSuites = []uint16{
	tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
	tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
	tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
	tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
	tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
	tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
	tls.TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA,
	tls.TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
	tls.TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
}

// serverConfig is for the side that acts as TLS server. KDE Connect needs a
// certificate from both sides, so the server asks for one. Flux checks the
// certificate after the handshake, because peers use self-signed
// certificates.
func serverConfig(cert tls.Certificate) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAnyClientCert,
		MinVersion:   tls.VersionTLS12,
		CipherSuites: cipherSuites,
	}
}

// clientConfig is for the side that acts as TLS client. It always sends the
// certificate, also when the server lists no acceptable CAs.
func clientConfig(cert tls.Certificate) *tls.Config {
	return &tls.Config{
		GetClientCertificate: func(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
			return &cert, nil
		},
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS12,
		CipherSuites:       cipherSuites,
	}
}

// peerCert returns the leaf certificate of the peer.
func peerCert(c *tls.Conn) (*x509.Certificate, error) {
	certs := c.ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return nil, errors.New("peer sent no certificate")
	}
	return certs[0], nil
}

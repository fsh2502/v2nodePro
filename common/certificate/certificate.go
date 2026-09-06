// Package certificate reads the public fingerprints of a local TLS key pair.
package certificate

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
)

type Fingerprint struct {
	SHA256          string
	PublicKeySHA256 string
	NotAfter        int64
	Issuer          string
}

func Read(certFile, keyFile string) (*Fingerprint, error) {
	// Validate the pair before reloading during non-atomic renewals.
	pair, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, err
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return nil, err
	}
	certHash := sha256.Sum256(leaf.Raw)
	keyHash := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	return &Fingerprint{
		SHA256:          hex.EncodeToString(certHash[:]),
		PublicKeySHA256: base64.StdEncoding.EncodeToString(keyHash[:]),
		NotAfter:        leaf.NotAfter.Unix(),
		Issuer:          leaf.Issuer.String(),
	}, nil
}

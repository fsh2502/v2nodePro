package certificate

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestReadLeafAndSPKI(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	leaf := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "node.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, _ := x509.MarshalECPrivateKey(key)
	dir := t.TempDir()
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	// The leaf is the first certificate of a chain.
	os.WriteFile(certFile, append(certPEM, certPEM...), 0600)
	os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0600)
	got, err := Read(certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	parsed, _ := x509.ParseCertificate(der)
	certHash, keyHash := sha256.Sum256(der), sha256.Sum256(parsed.RawSubjectPublicKeyInfo)
	if got.SHA256 != hex.EncodeToString(certHash[:]) {
		t.Fatal("wrong leaf hash")
	}
	if got.PublicKeySHA256 != base64.StdEncoding.EncodeToString(keyHash[:]) {
		t.Fatal("wrong SPKI hash")
	}
	if got.NotAfter != parsed.NotAfter.Unix() || got.Issuer != "CN=node.test" {
		t.Fatal("wrong metadata")
	}
	leaf.SerialNumber = big.NewInt(2)
	renewed, _ := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
	os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: renewed}), 0600)
	next, err := Read(certFile, keyFile)
	if err != nil {
		t.Fatal(err)
	}
	if next.SHA256 == got.SHA256 || next.PublicKeySHA256 != got.PublicKeySHA256 {
		t.Fatal("renewal must change cert hash while retaining SPKI for same key")
	}
	otherKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	otherDER, _ := x509.MarshalECPrivateKey(otherKey)
	os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: otherDER}), 0600)
	if _, err := Read(certFile, keyFile); err == nil {
		t.Fatal("accepted mismatched key pair")
	}
	os.WriteFile(certFile, []byte("invalid"), 0600)
	if _, err := Read(certFile, keyFile); err == nil {
		t.Fatal("accepted invalid certificate")
	}
	if _, err := Read(filepath.Join(dir, "missing"), keyFile); err == nil {
		t.Fatal("accepted missing certificate")
	}
}

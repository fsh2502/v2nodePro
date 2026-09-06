package node

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	panel "github.com/fsh2502/v2nodePro/api/v2board"
	"github.com/fsh2502/v2nodePro/conf"
	"github.com/fsh2502/v2nodePro/core"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestCertificateReportingLifecycle(t *testing.T) {
	var reports atomic.Int32
	var enabled atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var report panel.CertificateReport
		if err := json.NewDecoder(r.Body).Decode(&report); err != nil {
			t.Error(err)
		}
		enabled.Store(report.TLSEnabled)
		reports.Add(1)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data":true}`))
	}))
	defer srv.Close()
	api, _ := panel.New(&conf.NodeConfig{APIHost: srv.URL, NodeID: 7, Key: "test-token"})
	dir := t.TempDir()
	certFile, keyFile := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	keyDER, _ := x509.MarshalECPrivateKey(key)
	os.WriteFile(keyFile, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}), 0600)
	writeCert := func(serial int64) {
		leaf := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: "node.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
		der, err := x509.CreateCertificate(rand.Reader, leaf, leaf, &key.PublicKey, key)
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(certFile, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600)
	}
	writeCert(1)
	c := &Controller{apiClient: api, server: &core.V2Core{ReloadCh: make(chan struct{}, 1)}, info: &panel.NodeInfo{
		Security: panel.Tls, Common: &panel.CommonNode{BaseConfig: &panel.BaseConfig{CertificateReport: true, CertificateRevision: "revision"}, CertInfo: &panel.CertInfo{CertMode: "file", CertFile: certFile, KeyFile: keyFile}},
	}}
	c.captureCertificate()
	if c.loadedCertificate == nil {
		t.Fatal("did not capture certificate")
	}
	c.reportCertificateTask()
	if reports.Load() != 1 || !enabled.Load() {
		t.Fatal("did not report initial TLS certificate")
	}
	writeCert(2)
	c.reportCertificateTask()
	if reports.Load() != 1 || len(c.server.ReloadCh) != 1 {
		t.Fatal("new pin published before runtime reload")
	}
	<-c.server.ReloadCh
	c.captureCertificate() // A new, successfully started controller captures this.
	c.reportCertificateTask()
	if reports.Load() != 2 {
		t.Fatal("did not report certificate after reload")
	}
	os.WriteFile(certFile, []byte("broken"), 0600)
	c.reportCertificateTask()
	if reports.Load() != 2 || len(c.server.ReloadCh) != 0 {
		t.Fatal("bad file must retain last report without reload")
	}
	c.info.Security = panel.Reality
	c.reportCertificateTask()
	if reports.Load() != 3 || enabled.Load() {
		t.Fatal("REALITY must clear ordinary TLS report")
	}
	c.info.Common.BaseConfig.CertificateReport = false
	c.reportCertificateTask()
	if reports.Load() != 3 {
		t.Fatal("legacy panel must not receive certificate requests")
	}
}

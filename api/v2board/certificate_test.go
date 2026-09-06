package panel

import (
	"encoding/json"
	"github.com/fsh2502/v2nodePro/conf"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCertificateReport(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
		ok     bool
	}{
		{"accepted", 200, `{"data":true}`, true},
		{"business failure", 200, `{"status":"fail"}`, false},
		{"unauthorized", 401, `secret-token`, false},
		{"configuration changed", 409, `{}`, false},
		{"malformed", 200, `not json`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "POST" || r.URL.Path != "/api/v2/server/certificate" {
					t.Error("wrong method or path")
				}
				if r.URL.Query().Get("token") != "secret-token" || r.URL.Query().Get("node_id") != "7" {
					t.Error("missing existing node authentication")
				}
				var got CertificateReport
				if json.NewDecoder(r.Body).Decode(&got) != nil || got.SHA256 != strings.Repeat("ab", 32) || got.Revision != strings.Repeat("c", 64) {
					t.Error("wrong report payload")
				}
				w.WriteHeader(tc.status)
				w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			client, err := New(&conf.NodeConfig{APIHost: srv.URL, NodeID: 7, Key: "secret-token"})
			if err != nil {
				t.Fatal(err)
			}
			err = client.ReportCertificate(CertificateReport{Revision: strings.Repeat("c", 64), TLSEnabled: true, SHA256: strings.Repeat("ab", 32)})
			if (err == nil) != tc.ok {
				t.Fatalf("unexpected result: %v", err)
			}
			if err != nil && strings.Contains(err.Error(), "secret-token") {
				t.Fatal("error leaked token")
			}
		})
	}
}

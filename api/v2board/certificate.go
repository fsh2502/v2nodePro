package panel

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type CertificateReport struct {
	Revision        string `json:"revision"`
	TLSEnabled      bool   `json:"tls_enabled"`
	SHA256          string `json:"tls_certificate_sha256,omitempty"`
	PublicKeySHA256 string `json:"tls_public_key_sha256,omitempty"`
	NotAfter        int64  `json:"tls_not_after,omitempty"`
	Issuer          string `json:"tls_issuer,omitempty"`
}

func (c *Client) ReportCertificate(report CertificateReport) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// Use the existing HTTP transport without Resty's URL-bearing error hooks.
	payload, err := json.Marshal(report)
	if err != nil {
		return fmt.Errorf("cannot encode certificate report")
	}
	endpoint, err := url.Parse(strings.TrimRight(c.APIHost, "/") + "/api/v2/server/certificate")
	if err != nil {
		return fmt.Errorf("invalid certificate report endpoint")
	}
	query := endpoint.Query()
	query.Set("node_type", "v2node")
	query.Set("node_id", strconv.Itoa(c.NodeId))
	query.Set("token", c.Token)
	endpoint.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint.String(), bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("cannot create certificate report request")
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	r, err := c.client.GetClient().Do(req)
	if err != nil {
		return fmt.Errorf("certificate report request failed")
	}
	defer r.Body.Close()
	if r.StatusCode != 200 {
		return fmt.Errorf("certificate report HTTP %d", r.StatusCode)
	}
	var result struct {
		Data bool `json:"data"`
	}
	if json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&result) != nil || !result.Data {
		return fmt.Errorf("certificate report was not accepted")
	}
	return nil
}

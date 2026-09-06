package core

import (
	"testing"

	panel "github.com/fsh2502/v2nodePro/api/v2board"
)

func TestShouldEnableInboundTLS(t *testing.T) {
	plainWS := &panel.NodeInfo{Common: &panel.CommonNode{
		Network:     "ws",
		TlsSettings: panel.TlsSettings{TerminateTLSAtProxy: "1"},
	}}
	enabled, err := shouldEnableInboundTLS(plainWS)
	if err != nil || enabled {
		t.Fatalf("proxy-terminated websocket must keep inbound TLS disabled: enabled=%v err=%v", enabled, err)
	}

	directTLS := &panel.NodeInfo{Common: &panel.CommonNode{Network: "ws"}}
	enabled, err = shouldEnableInboundTLS(directTLS)
	if err != nil || !enabled {
		t.Fatalf("direct websocket must retain inbound TLS: enabled=%v err=%v", enabled, err)
	}

	invalid := &panel.NodeInfo{Common: &panel.CommonNode{
		Network:     "tcp",
		TlsSettings: panel.TlsSettings{TerminateTLSAtProxy: true},
	}}
	if _, err = shouldEnableInboundTLS(invalid); err == nil {
		t.Fatal("proxy TLS termination accepted a non-websocket transport")
	}
}

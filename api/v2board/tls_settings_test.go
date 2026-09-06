package panel

import "testing"

func TestTLSIsTerminatedAtProxy(t *testing.T) {
	truthy := []interface{}{true, "1", "true", "YES", "on", float64(1), int(1), int64(1)}
	for _, value := range truthy {
		if !(TlsSettings{TerminateTLSAtProxy: value}).TLSIsTerminatedAtProxy() {
			t.Fatalf("expected %#v to enable proxy TLS termination", value)
		}
	}
	falsy := []interface{}{nil, false, "", "0", "false", float64(0), int(2)}
	for _, value := range falsy {
		if (TlsSettings{TerminateTLSAtProxy: value}).TLSIsTerminatedAtProxy() {
			t.Fatalf("expected %#v to disable proxy TLS termination", value)
		}
	}
}

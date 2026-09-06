package core

import (
	"bufio"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"testing"
	"time"

	panel "github.com/fsh2502/v2nodePro/api/v2board"
	"github.com/fsh2502/v2nodePro/conf"
	"github.com/fsh2502/v2nodePro/limiter"
	"github.com/gorilla/websocket"
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

// Exercise actual Xray listeners, not only the TLS decision helper. Node IDs
// can repeat across panels; the panel URL in the tag must keep listeners apart.
func TestProxyTLSMultiplePanelListeners(t *testing.T) {
	var infos []*panel.NodeInfo
	for i, domain := range []string{"node-a.example.com", "node-b.example.com"} {
		probe, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := probe.Addr().(*net.TCPAddr).Port
		probe.Close()
		settings, _ := json.Marshal(map[string]any{"path": fmt.Sprintf("/panel-%d", i), "host": domain})
		infos = append(infos, &panel.NodeInfo{
			Id: 1, Type: "trojan", Security: panel.Tls,
			Tag: fmt.Sprintf("[https://panel-%d.example.com]-trojan:1", i),
			Common: &panel.CommonNode{
				ListenIP: "127.0.0.1", ServerPort: port, Network: "ws", NetworkSettings: settings,
				TlsSettings: panel.TlsSettings{TerminateTLSAtProxy: "1"},
				CertInfo:    &panel.CertInfo{CertMode: "file", CertFile: "unused.cer", KeyFile: "unused.key"},
			},
		})
	}
	v := New(conf.New())
	if err := v.Start(infos); err != nil {
		t.Fatal(err)
	}
	defer v.Close()
	for _, info := range infos {
		if err := v.AddNode(info.Tag, info); err != nil {
			t.Fatal(err)
		}
	}
	for round := 0; round < 2; round++ {
		for i, info := range infos {
			conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", info.Common.ServerPort), 3*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			conn.SetDeadline(time.Now().Add(3 * time.Second))
			fmt.Fprintf(conn, "GET /panel-%d HTTP/1.1\r\nHost: node-%c.example.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", i, 'a'+i)
			response, err := http.ReadResponse(bufio.NewReader(conn), nil)
			conn.Close()
			if err != nil {
				t.Fatalf("%s: %v", info.Tag, err)
			}
			if response.StatusCode != http.StatusSwitchingProtocols {
				t.Fatalf("%s: expected WS upgrade, got %s", info.Tag, response.Status)
			}
		}
	}

	// Authenticate both panels' users and forward data through their separate
	// inbound handlers/limiters to a local echo destination.
	limiter.Init()
	users := []panel.UserInfo{{Id: 1, Uuid: "00000000-0000-4000-8000-000000000001"}}
	for _, info := range infos {
		limiter.AddLimiter(info.Type, info.Tag, users, map[int]int{})
		defer limiter.DeleteLimiter(info.Tag)
		if _, err := v.AddUsers(&AddUsersParams{Tag: info.Tag, Users: users, NodeInfo: info}); err != nil {
			t.Fatal(err)
		}
	}
	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			conn, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { defer conn.Close(); conn.SetDeadline(time.Now().Add(5 * time.Second)); io.Copy(conn, conn) }()
		}
	}()
	echoPort := echo.Addr().(*net.TCPAddr).Port
	passwordHash := sha256.Sum224([]byte(users[0].Uuid))
	for i, info := range infos {
		url := fmt.Sprintf("ws://127.0.0.1:%d/panel-%d", info.Common.ServerPort, i)
		header := http.Header{"Host": {fmt.Sprintf("node-%c.example.com", 'a'+i)}}
		conn, _, err := websocket.DefaultDialer.Dial(url, header)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		payload := []byte(fmt.Sprintf("panel-%d-authenticated-traffic", i))
		packet := []byte(fmt.Sprintf("%x\r\n", passwordHash))
		packet = append(packet, 1, 1, 127, 0, 0, 1, byte(echoPort>>8), byte(echoPort), '\r', '\n')
		packet = append(packet, payload...)
		if err := conn.WriteMessage(websocket.BinaryMessage, packet); err != nil {
			t.Fatal(err)
		}
		var received []byte
		for len(received) < len(payload) {
			_, chunk, err := conn.ReadMessage()
			if err != nil {
				t.Fatalf("%s authenticated traffic failed: %v", info.Tag, err)
			}
			received = append(received, chunk...)
		}
		if string(received) != string(payload) {
			t.Fatalf("%s unexpected echo %q", info.Tag, received)
		}
	}
}

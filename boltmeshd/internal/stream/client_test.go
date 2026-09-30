package stream

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"testing"
	"time"
)

// stubNode is the node half, reduced to what the client bridge needs: a TLS
// listener that verifies the key proof and echoes datagrams. The real server
// half lives in the agent repo (internal/stream) and is proven against the
// same golden vectors; this stub exists so the client's datagram path,
// pinning, and auth failure modes are testable here.
type stubNode struct {
	ln       net.Listener
	psk      []byte
	pin      []byte
	clientID []byte

	sessions chan net.Conn
	// autoEcho makes every authenticated session echo each datagram back, the
	// node's way of proving the reverse path works.
	autoEcho bool
	// refuse makes the node answer a hello with a refusal.
	refuse bool
}

func newStubNode(t *testing.T, psk, clientID []byte, refuse bool) *stubNode {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "stream.test"},
		// Valid window wide enough that the pinned-leaf test never races a
		// clock; the pin is what authenticates the node, not validity dates.
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
		DNSNames:              []string{"stream.test"},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	})
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	t.Cleanup(func() { _ = ln.Close() })
	n := &stubNode{
		ln:       ln,
		psk:      psk,
		pin:      sum[:],
		clientID: clientID,
		sessions: make(chan net.Conn, 4),
		refuse:   refuse,
	}
	go n.accept()
	return n
}

func (n *stubNode) addr() string { return n.ln.Addr().String() }

func (n *stubNode) accept() {
	for {
		conn, err := n.ln.Accept()
		if err != nil {
			return
		}
		go n.handle(conn)
	}
}

// handle authenticates one session. The connection's lifetime belongs to
// whoever takes it over — the echo loop or the test — so this must not close
// it on return.
func (n *stubNode) handle(conn net.Conn) {
	typ, payload, err := readOneFrame(conn)
	if err != nil || typ != TypeHello {
		_ = conn.Close()
		return
	}
	if n.refuse {
		_, _ = conn.Write(BuildHelloFail("nop"))
		_ = conn.Close()
		return
	}
	clientID, err := VerifyHello(n.psk, payload, time.Now())
	if err != nil {
		// Refuse exactly as a real node would: the client retries on the
		// backoff, and learns nothing about which check failed.
		_, _ = conn.Write(BuildHelloFail("nop"))
		_ = conn.Close()
		return
	}
	if string(clientID) != string(n.clientID) {
		_, _ = conn.Write(BuildHelloFail("nop"))
		_ = conn.Close()
		return
	}
	if _, err := conn.Write(BuildHelloAck()); err != nil {
		_ = conn.Close()
		return
	}
	if n.autoEcho {
		// The echo loop owns the connection from here.
		go func() {
			defer func() { _ = conn.Close() }()
			for {
				typ, payload, err := readOneFrame(conn)
				if err != nil || typ != TypeDatagram {
					return
				}
				frameBytes, err := BuildDatagram(payload)
				if err != nil {
					return
				}
				if _, err := conn.Write(frameBytes); err != nil {
					return
				}
			}
		}()
		return
	}
	select {
	case n.sessions <- conn:
	default:
		// Nobody is watching: close rather than leak the session.
		_ = conn.Close()
	}
}

func testKeyPair(t *testing.T, seed byte) ([]byte, []byte) {
	t.Helper()
	psk := make([]byte, PSKSize)
	for i := range psk {
		psk[i] = seed + byte(i)
	}
	cid := make([]byte, ClientIDSize)
	for i := range cid {
		cid[i] = seed + byte(i)
	}
	return psk, cid
}

// newTestClient wires a client to the stub node, with the deliver address on
// a loopback socket the test reads to observe the reverse path. The returned
// channel carries the client's session reports.
func newTestClient(t *testing.T, node *stubNode, psk, cid []byte, pins [][]byte) (*Client, *net.UDPConn, chan bool) {
	t.Helper()
	// Deliver into a socket the test owns, standing in for the local
	// WireGuard listen port.
	deliver, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = deliver.Close() })
	if pins == nil {
		pins = [][]byte{node.pin}
	}
	reports := make(chan bool, 32)
	client, err := NewClient(ClientConfig{
		ListenAddr:   "127.0.0.1:0",
		DeliverAddr:  deliver.LocalAddr().String(),
		ServerAddr:   node.addr(),
		ServerName:   "stream.test",
		SPKIPins:     pins,
		PSK:          psk,
		ClientID:     cid,
		ReconnectMin: 10 * time.Millisecond,
		ReconnectMax: 20 * time.Millisecond,
		OnSession: func(up bool, _ error) {
			select {
			case reports <- up:
			default:
			}
		},
	})
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	t.Cleanup(func() { _ = client.Stop() })
	return client, deliver, reports
}

func TestClientCarriesADatagramBothWays(t *testing.T) {
	psk, cid := testKeyPair(t, 1)
	node := newStubNode(t, psk, cid, false)
	node.autoEcho = true
	client, deliver, reports := newTestClient(t, node, psk, cid, nil)
	client.Start()

	// Wait for a live session before sending: a datagram with no session is
	// dropped by design, so the test would race its own bridge.
	select {
	case up := <-reports:
		if !up {
			t.Fatal("first session report was not up")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no session established")
	}

	payload := []byte("wireguard-handshake")
	if _, err := client.socket.WriteToUDP(payload, mustAddr(t, client.Addr())); err != nil {
		t.Fatalf("send datagram: %v", err)
	}
	// The node echoes it, so the reverse path delivers it to our own
	// deliver socket.
	_ = deliver.SetReadDeadline(time.Now().Add(3 * time.Second))
	buf := make([]byte, MaxDatagramSize)
	n, _, err := deliver.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("deliver read: %v", err)
	}
	if string(buf[:n]) != string(payload) {
		t.Errorf("delivered %q, want %q", buf[:n], payload)
	}
}

func TestClientRejectsAnUnpinnedNode(t *testing.T) {
	psk, cid := testKeyPair(t, 2)
	node := newStubNode(t, psk, cid, false)
	wrongPin := make([]byte, 32)
	wrongPin[0] = 0xff
	client, _, reports := newTestClient(t, node, psk, cid, [][]byte{wrongPin})
	client.Start()

	// The pin check fails inside the TLS handshake, so no session is ever
	// reported up.
	deadline := time.After(2 * time.Second)
	for {
		select {
		case up := <-reports:
			if up {
				t.Fatal("session reported up against an unpinned certificate")
			}
		case <-deadline:
			// Refusals keep coming; that is the expected steady state.
			return
		}
	}
}

func TestClientSurvivesANodeRefusingTheKey(t *testing.T) {
	psk, cid := testKeyPair(t, 3)
	node := newStubNode(t, psk, cid, true)
	client, _, reports := newTestClient(t, node, psk, cid, nil)
	client.Start()

	// A refusal is an auth failure, never a silent success: the client keeps
	// retrying but must never report a session up.
	deadline := time.After(500 * time.Millisecond)
	for {
		select {
		case up := <-reports:
			if up {
				t.Fatal("session reported up after a key refusal")
			}
		case <-deadline:
			return
		}
	}
}

func TestClientStopIsIdempotentAndEndsTheSession(t *testing.T) {
	psk, cid := testKeyPair(t, 4)
	node := newStubNode(t, psk, cid, false)
	client, _, _ := newTestClient(t, node, psk, cid, nil)
	client.Start()
	if err := client.Stop(); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if err := client.Stop(); err != nil {
		t.Fatalf("Stop (second): %v", err)
	}
	// A stopped client has no session and no live socket.
	if client.currentSession() != nil {
		t.Error("a stopped client still reports a session")
	}
}

func TestNewClientRejectsBadConfigurations(t *testing.T) {
	psk, cid := testKeyPair(t, 5)
	base := ClientConfig{
		ListenAddr:  "127.0.0.1:0",
		DeliverAddr: "127.0.0.1:51820",
		ServerAddr:  "127.0.0.1:443",
		ServerName:  "stream.test",
		SPKIPins:    [][]byte{make([]byte, 32)},
		PSK:         psk,
		ClientID:    cid,
	}
	cases := []struct {
		name string
		mut  func(*ClientConfig)
	}{
		{"missing listen", func(c *ClientConfig) { c.ListenAddr = "" }},
		{"missing deliver", func(c *ClientConfig) { c.DeliverAddr = "" }},
		{"missing server", func(c *ClientConfig) { c.ServerAddr = "" }},
		{"no pin", func(c *ClientConfig) { c.SPKIPins = nil }},
		// A non-loopback listen would make the daemon forward arbitrary UDP
		// into the process.
		{"listen not loopback", func(c *ClientConfig) { c.ListenAddr = "10.0.0.1:51821" }},
		{"deliver not loopback", func(c *ClientConfig) { c.DeliverAddr = "0.0.0.0:51820" }},
		{"short psk", func(c *ClientConfig) { c.PSK = make([]byte, 31) }},
		{"short client id", func(c *ClientConfig) { c.ClientID = make([]byte, 15) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := base
			tc.mut(&cfg)
			c, err := NewClient(cfg)
			if err == nil {
				_ = c.Stop()
				t.Fatalf("NewClient(%s) = nil, want error", tc.name)
			}
		})
	}
}

func TestClientRecoversAfterTheNodeDropsTheSession(t *testing.T) {
	psk, cid := testKeyPair(t, 6)
	node := newStubNode(t, psk, cid, false)
	client, _, reports := newTestClient(t, node, psk, cid, nil)
	client.Start()

	// Wait for the first session, then drop it the way a flaky network would.
	select {
	case up := <-reports:
		if !up {
			t.Fatal("first session report was not up")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no first session")
	}
	select {
	case conn := <-node.sessions:
		_ = conn.Close()
	default:
		// The session may not have been handed over yet; closing the
		// listener forces the next dial to fail instead, which still
		// exercises the reconnect path.
		_ = node.ln.Close()
	}

	// The client must bring a session back up on its own.
	deadline := time.After(5 * time.Second)
	for {
		select {
		case up := <-reports:
			if up {
				return
			}
		case <-deadline:
			t.Fatal("the client never re-established a session")
		}
	}
}

func mustAddr(t *testing.T, addr string) *net.UDPAddr {
	t.Helper()
	a, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		t.Fatalf("resolve %s: %v", addr, err)
	}
	return a
}

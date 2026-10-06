package stream

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"syscall"
	"time"
)

// Session-reconnect bounds. The stream is the rung for a broken network, so a
// session that drops must come back on its own without the tunnel being
// rebuilt; the backoff keeps a node that is refusing us from being hammered.
const (
	defaultReconnectMin = 250 * time.Millisecond
	defaultReconnectMax = 5 * time.Second
	dialTimeout         = 10 * time.Second
	sessionQueueDepth   = 64
)

// ClientConfig is the client half's configuration. The three addresses are
// explicit rather than derived, and each exists for a concrete reason:
//
//   - [ListenAddr] is the loopback address the tunnel's peer endpoint points
//     at: the local WireGuard interface sends its datagrams here.
//   - [DeliverAddr] is the local WireGuard listen port, where the node's
//     datagrams are handed back. It cannot be derived — a kernel interface
//     with ListenPort=0 picks an ephemeral port nobody can guess — so stream
//     mode pins the local port and passes the same value here.
//   - [ServerAddr] is the node's TLS endpoint.
//
// The node's identity is a certificate pin ([SPKIPins]) plus a per-device
// pre-shared key ([PSK]). There is no CA chain to trust: the peer is a single
// known node whose key the control plane hands out.
type ClientConfig struct {
	ListenAddr  string
	DeliverAddr string
	ServerAddr  string
	ServerName  string
	// SPKIPins are SHA-256 digests of the node's leaf SPKI. At least one is
	// required: a pinned stream with no pin is a stream to whoever answers.
	SPKIPins [][]byte
	PSK      []byte
	ClientID []byte

	// RootCAs, when set, additionally requires a normal chain to validate.
	// Pinning alone already defeats an active middlebox; the pool is for
	// deployments that also want issuer and expiry checks.
	RootCAs *x509.CertPool

	ReconnectMin time.Duration
	ReconnectMax time.Duration

	// DialControl, when set, is installed on the dialer and runs after the
	// socket is created but before it is connected. The Android build uses it
	// to protect the socket from its own VpnService — the only window in which
	// the kernel route can still be chosen for the physical network. Returning
	// an error aborts the dial, so a failure to protect fails closed instead of
	// leaking a connection into the tunnel this bridge exists to bypass.
	DialControl func(network, address string, c syscall.RawConn) error

	// OnSession reports session transitions, so the caller can gate
	// readiness on a live session rather than on a bound socket.
	OnSession func(up bool, err error)
	// Logf receives diagnostics; nil discards them.
	Logf func(format string, args ...any)
}

func (c *ClientConfig) logf(format string, args ...any) {
	if c.Logf != nil {
		c.Logf(format, args...)
	}
}

// Client is the client half of the stream transport: a loopback UDP
// listener whose datagrams travel to the node inside a pinned, key-
// authenticated TLS session, and whose node-bound datagrams come back the
// same way. It reconnects on its own for as long as it is started.
type Client struct {
	cfg     ClientConfig
	socket  *net.UDPConn
	deliver *net.UDPAddr

	mu      sync.Mutex
	active  *session
	running bool
	stopped chan struct{}
	wg      sync.WaitGroup
}

// NewClient validates the configuration and binds the loopback socket. The
// socket binds before [Client.Start] so a tunnel pointed at [ListenAddr]
// never meets a refused port: its datagrams queue in the socket's receive
// buffer and go out with the first session, rather than being lost while the
// TLS handshake is still in flight.
func NewClient(cfg ClientConfig) (*Client, error) {
	if cfg.ListenAddr == "" || cfg.DeliverAddr == "" || cfg.ServerAddr == "" {
		return nil, errors.New("stream: listen, deliver and server addresses are required")
	}
	if len(cfg.SPKIPins) == 0 {
		return nil, errors.New("stream: at least one certificate pin is required")
	}
	if err := verifyLoopback("listen", cfg.ListenAddr); err != nil {
		return nil, err
	}
	if err := verifyLoopback("deliver", cfg.DeliverAddr); err != nil {
		return nil, err
	}
	if _, err := DeriveSessionKey(cfg.PSK, cfg.ClientID); err != nil {
		return nil, err
	}
	listenAddr, err := net.ResolveUDPAddr("udp", cfg.ListenAddr)
	if err != nil {
		return nil, fmt.Errorf("stream: listen address: %w", err)
	}
	socket, err := net.ListenUDP("udp", listenAddr)
	if err != nil {
		return nil, fmt.Errorf("stream: bind %s: %w", cfg.ListenAddr, err)
	}
	deliver, err := net.ResolveUDPAddr("udp", cfg.DeliverAddr)
	if err != nil {
		_ = socket.Close()
		return nil, fmt.Errorf("stream: deliver address: %w", err)
	}
	if cfg.ReconnectMin <= 0 {
		cfg.ReconnectMin = defaultReconnectMin
	}
	if cfg.ReconnectMax <= 0 {
		cfg.ReconnectMax = defaultReconnectMax
	}
	return &Client{cfg: cfg, socket: socket, deliver: deliver}, nil
}

// verifyLoopback requires a loopback address: this bridge exists to hand
// datagrams to a local interface, and a non-loopback listen address would
// make the daemon forward arbitrary UDP into the process.
func verifyLoopback(field, addr string) error {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("stream: %s must be host:port", field)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("stream: %s must be a loopback address", field)
	}
	if port == "" {
		return fmt.Errorf("stream: %s has no port", field)
	}
	return nil
}

// session is one live TLS connection. Writes are serialized by writeMu so
// both pumps can share the stream.
type session struct {
	conn    net.Conn
	writeMu sync.Mutex
	out     chan []byte
	closed  chan struct{}
	once    sync.Once
}

func (s *session) send(frameBytes []byte) {
	select {
	case s.out <- frameBytes:
	case <-s.closed:
	}
}

func (s *session) close() {
	s.once.Do(func() {
		close(s.closed)
		_ = s.conn.Close()
	})
}

// Start begins serving. Idempotent.
func (c *Client) Start() {
	c.mu.Lock()
	if c.running {
		c.mu.Unlock()
		return
	}
	c.running = true
	c.stopped = make(chan struct{})
	stopped := c.stopped
	c.mu.Unlock()

	c.wg.Add(2)
	// Reader: local interface -> stream.
	go func() {
		defer c.wg.Done()
		c.readLocal(stopped)
	}()
	// Writer: stream -> local interface, owning session (re)connects.
	go func() {
		defer c.wg.Done()
		c.serve(stopped)
	}()
}

// Stop closes the socket and ends the session, waiting for the loops so
// nothing is still touching the tunnel's datagrams once it returns.
// Idempotent.
func (c *Client) Stop() error {
	c.mu.Lock()
	if !c.running {
		c.mu.Unlock()
		return nil
	}
	c.running = false
	stopped := c.stopped
	c.mu.Unlock()

	close(stopped)
	_ = c.socket.Close()
	c.wg.Wait()
	return nil
}

// Addr is the loopback address actually bound, which matters when the
// configuration asked for port 0.
func (c *Client) Addr() string { return c.socket.LocalAddr().String() }

// readLocal moves datagrams from the local interface toward the node. A
// datagram with no session to ride is dropped rather than queued: WireGuard
// re-sends on its own timer, and blocking here would fill the socket's
// receive buffer and eventually stall the local interface's sends.
func (c *Client) readLocal(stopped <-chan struct{}) {
	// One byte over the limit so an oversized datagram is *detected* rather than
	// silently truncated into a frame that still looks valid. A tunnel MTU
	// larger than the format's cap (which a loopback peer endpoint makes
	// wg-quick derive from lo) would otherwise ship a corrupt WireGuard message
	// the node drops with no trace on either end. The real fix is the MTU the
	// caller builds the conf with; this is the guard that keeps a misconfigured
	// one observable instead of silent.
	buf := make([]byte, MaxDatagramSize+1)
	for {
		n, _, err := c.socket.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-stopped:
				return
			default:
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			c.cfg.logf("stream: local read failed: %v", err)
			continue
		}
		select {
		case <-stopped:
			return
		default:
		}
		if n > MaxDatagramSize {
			c.cfg.logf("stream: dropping %d-byte datagram over the %d-byte cap (check the tunnel MTU)", n, MaxDatagramSize)
			continue
		}
		frameBytes, err := BuildDatagram(buf[:n])
		if err != nil {
			c.cfg.logf("stream: dropping %d-byte datagram: %v", n, err)
			continue
		}
		if s := c.currentSession(); s != nil {
			s.send(frameBytes)
		}
	}
}

// serve owns the session lifecycle: dial, authenticate, pump, reconnect with
// backoff until stopped.
func (c *Client) serve(stopped <-chan struct{}) {
	backoff := c.cfg.ReconnectMin
	for {
		select {
		case <-stopped:
			return
		default:
		}
		err := c.runSession(stopped)
		if isClosed(stopped) {
			return
		}
		c.report(false, err)
		c.cfg.logf("stream: session ended: %v", err)
		select {
		case <-stopped:
			return
		case <-time.After(backoff):
		}
		// Exponential to the configured ceiling: a node refusing us must not
		// be dialled in a tight loop.
		backoff *= 2
		if backoff > c.cfg.ReconnectMax {
			backoff = c.cfg.ReconnectMax
		}
	}
}

func isClosed(ch <-chan struct{}) bool {
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

// runSession establishes one session and pumps both directions until it fails.
func (c *Client) runSession(stopped <-chan struct{}) error {
	key, err := DeriveSessionKey(c.cfg.PSK, c.cfg.ClientID)
	if err != nil {
		return err
	}

	dialer := &tls.Dialer{
		NetDialer: &net.Dialer{Timeout: dialTimeout, Control: c.cfg.DialControl},
		Config:    c.tlsConfig(),
	}
	ctx, cancel := context.WithTimeout(context.Background(), dialTimeout)
	defer cancel()
	conn, err := dialer.DialContext(ctx, "tcp", c.cfg.ServerAddr)
	if err != nil {
		return fmt.Errorf("dial %s: %w", c.cfg.ServerAddr, err)
	}

	// The connection is closed on stop as well as on session end, so a stop
	// unblocks the reader pump immediately instead of waiting for a timeout.
	sessionDone := make(chan struct{})
	defer close(sessionDone)
	go func() {
		select {
		case <-stopped:
			_ = conn.Close()
		case <-sessionDone:
		}
	}()

	if err := c.handshake(conn, key); err != nil {
		_ = conn.Close()
		return err
	}

	s := &session{
		conn:   conn,
		out:    make(chan []byte, sessionQueueDepth),
		closed: make(chan struct{}),
	}
	defer s.close()
	c.setSession(s)
	defer c.setSession(nil)
	c.report(true, nil)
	c.cfg.logf("stream: session established with %s", c.cfg.ServerAddr)

	// Writer pump: local -> node. It owns nothing but the shared write lock.
	var pumps sync.WaitGroup
	pumps.Add(1)
	go func() {
		defer pumps.Done()
		for {
			select {
			case <-s.closed:
				return
			case frameBytes := <-s.out:
				s.writeMu.Lock()
				_, err := conn.Write(frameBytes)
				s.writeMu.Unlock()
				if err != nil {
					s.close()
					return
				}
			}
		}
	}()

	// Reader pump: node -> local interface. This loop is the session's
	// lifetime; it returns when the connection breaks, which ends the session
	// and lets serve reconnect.
	for {
		typ, payload, err := readOneFrame(conn)
		if err != nil {
			s.close()
			pumps.Wait()
			if errors.Is(err, net.ErrClosed) && isClosed(stopped) {
				return nil
			}
			return fmt.Errorf("read stream: %w", err)
		}
		if typ != TypeDatagram {
			// A repeated acknowledgement, or anything else: the node does not
			// renegotiate mid-session.
			s.close()
			pumps.Wait()
			return fmt.Errorf("%w: unexpected frame type 0x%04x mid-session", ErrProtocol, typ)
		}
		if _, err := c.socket.WriteToUDP(payload, c.deliver); err != nil {
			s.close()
			pumps.Wait()
			return fmt.Errorf("deliver datagram: %w", err)
		}
	}
}

// handshake runs the client half of the key exchange: send the hello (with a
// fresh nonce and the current timestamp), then require exactly one
// acknowledgement.
func (c *Client) handshake(conn net.Conn, sessionKey []byte) error {
	hello, err := BuildHello(sessionKey, c.cfg.ClientID)
	if err != nil {
		return err
	}
	if _, err := conn.Write(hello); err != nil {
		return fmt.Errorf("write hello: %w", err)
	}
	typ, _, err := readOneFrame(conn)
	if err != nil {
		return fmt.Errorf("read hello answer: %w", err)
	}
	switch typ {
	case TypeHelloAck:
		return nil
	case TypeHelloFail:
		// The node refused the key. The credential may be rotated, so this
		// retries on the backoff rather than giving up, but it is reported as
		// an auth failure rather than a transient dial error.
		return ErrAuth
	default:
		return fmt.Errorf("%w: unexpected hello answer type 0x%04x", ErrProtocol, typ)
	}
}

// readOneFrame reads exactly one frame off a stream connection.
func readOneFrame(conn net.Conn) (uint16, []byte, error) {
	header := make([]byte, 7)
	if _, err := io.ReadFull(conn, header); err != nil {
		return 0, nil, err
	}
	length := int(uint32(header[3])<<24 | uint32(header[4])<<16 | uint32(header[5])<<8 | uint32(header[6]))
	if length > MaxPayloadSize {
		return 0, nil, fmt.Errorf("%w: payload length %d exceeds %d", ErrProtocol, length, MaxPayloadSize)
	}
	frameBytes := make([]byte, 0, 7+length)
	frameBytes = append(frameBytes, header...)
	if length > 0 {
		payload := make([]byte, length)
		if _, err := io.ReadFull(conn, payload); err != nil {
			return 0, nil, err
		}
		frameBytes = append(frameBytes, payload...)
	}
	return parseFrame(frameBytes)
}

// tlsConfig builds the node's TLS configuration: the server name for SNI, and
// a leaf-SPKI pin enforced in the verifier. Pinning lives there because a
// node's certificate is issued for a name we control and rotates
// independently of any CA chain.
// alpnProtocols is the ALPN list the bridge offers.
//
// Camouflage, not negotiation: the session carries WireGuard datagrams either
// way, but a ClientHello with no ALPN extension is one of the few things a
// passive observer can use to tell this session from an ordinary HTTPS one —
// every browser offers ALPN. The list is what the node advertises (the agent's
// `stream.ALPNProtocols`), so the ServerHello answers it and both directions of
// the handshake look ordinary.
var alpnProtocols = []string{"h2", "http/1.1"}

func (c *Client) tlsConfig() *tls.Config {
	cfg := &tls.Config{
		ServerName: c.cfg.ServerName,
		NextProtos: alpnProtocols,
		// The chain check is replaced by the SPKI pin below, which is
		// strictly narrower than a public-CA validation for a single known
		// peer. RootCAs, when set, adds the normal verification on top.
		InsecureSkipVerify:    true, //nolint:gosec // see VerifyPeerCertificate
		MinVersion:            tls.VersionTLS13,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error { return c.verifyPeer(rawCerts) },
	}
	if c.cfg.RootCAs != nil {
		cfg.RootCAs = c.cfg.RootCAs
	}
	return cfg
}

// verifyPeer checks the leaf's SPKI against the pins, and the chain when a
// pool was supplied. Pin comparison is constant-time.
func (c *Client) verifyPeer(rawCerts [][]byte) error {
	if len(rawCerts) == 0 {
		return errors.New("stream: node presented no certificate")
	}
	leaf, err := x509.ParseCertificate(rawCerts[0])
	if err != nil {
		return fmt.Errorf("stream: node certificate: %w", err)
	}
	if c.cfg.RootCAs != nil {
		intermediates := x509.NewCertPool()
		for _, raw := range rawCerts[1:] {
			if cert, err := x509.ParseCertificate(raw); err == nil {
				intermediates.AddCert(cert)
			}
		}
		if _, err := leaf.Verify(x509.VerifyOptions{
			Roots:         c.cfg.RootCAs,
			Intermediates: intermediates,
			DNSName:       c.cfg.ServerName,
		}); err != nil {
			return fmt.Errorf("stream: node certificate chain: %w", err)
		}
	}
	sum := sha256.Sum256(leaf.RawSubjectPublicKeyInfo)
	for _, pin := range c.cfg.SPKIPins {
		if len(pin) == sha256.Size && hmac.Equal(sum[:], pin) {
			return nil
		}
	}
	return errors.New("stream: node certificate does not match any pin")
}

func (c *Client) setSession(s *session) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.active = s
}

func (c *Client) currentSession() *session {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.active
}

func (c *Client) report(up bool, err error) {
	if c.cfg.OnSession != nil {
		c.cfg.OnSession(up, err)
	}
}

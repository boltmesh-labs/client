//go:build darwin

package tunnel

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"golang.zx2c4.com/wireguard/tun"

	"boltmeshd/internal/protocol"
)

// fakeDevice is a [wireguardDevice] that records the UAPI body it was
// configured with and replays a canned dump.
type fakeDevice struct {
	configured []string
	dumpBody   []byte
	setErr     error
	dumpErr    error
	closed     int
}

func (f *fakeDevice) configure(_ context.Context, body []byte) error {
	f.configured = append(f.configured, string(body))
	return f.setErr
}

func (f *fakeDevice) dump(_ context.Context) ([]byte, error) {
	if f.dumpErr != nil {
		return nil, f.dumpErr
	}
	if f.dumpBody == nil {
		return []byte(`{"listen_port":0,"peers":[]}`), nil
	}
	return f.dumpBody, nil
}

func (f *fakeDevice) close() error {
	f.closed++
	return nil
}

// fakeTun is a [systemTun] that records the network work the manager asked for
// without touching a real interface.
type fakeTun struct {
	created      int
	closed       int
	configured   []string
	tornDown     []string
	configureErr error
	teardownErr  error
}

func (f *fakeTun) create(context.Context) (string, func() error, error) {
	f.created++
	return "utun9", func() error { f.closed++; return nil }, nil
}

func (f *fakeTun) configure(_ context.Context, name, address string, _ []string, dns string) error {
	if f.configureErr != nil {
		return f.configureErr
	}
	f.configured = append(f.configured, name+"|"+address+"|"+dns)
	return nil
}

func (f *fakeTun) teardown(_ context.Context, name string) error {
	if f.teardownErr != nil {
		return f.teardownErr
	}
	f.tornDown = append(f.tornDown, name)
	return nil
}

func newDarwinManager(t *testing.T) (*Manager, *fakeTun, *fakeDevice) {
	t.Helper()
	ft := &fakeTun{}
	dev := &fakeDevice{}
	m := NewManager(t.TempDir(), DefaultInterface)
	m.makeTun = ft
	m.makeDevice = func(_ tun.Device) (wireguardDevice, error) { return dev, nil }
	return m, ft, dev
}

func TestDarwinUpConfiguresDeviceAndNetwork(t *testing.T) {
	m, ft, dev := newDarwinManager(t)

	st, err := m.Up(context.Background(), validConfig)
	if err != nil {
		t.Fatalf("Up: %v", err)
	}
	if st.Stage != protocol.StageConnected || !st.Up {
		t.Errorf("want a connected status, got %+v", st)
	}
	if len(dev.configured) != 1 {
		t.Fatalf("expected exactly one configure, got %d", len(dev.configured))
	}
	if ft.created != 1 {
		t.Errorf("expected one utun, got %d", ft.created)
	}
	if len(ft.configured) != 1 || ft.configured[0] == "" {
		t.Errorf("the interface was never configured: %v", ft.configured)
	}
	// The config file is the daemon's durable record of the live peer.
	if _, err := os.Stat(m.configPath()); err != nil {
		t.Errorf("config not persisted: %v", err)
	}
}

func TestDarwinUpRejectsBadConfigBeforeTouchingTheTunnel(t *testing.T) {
	m, ft, _ := newDarwinManager(t)

	// A PreUp hook is the injection vector config.Validate exists to stop.
	_, err := m.Up(context.Background(), "[Interface]\nPreUp = touch /tmp/pwned\n")
	if err == nil {
		t.Fatal("expected the hook to be rejected")
	}
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Errorf("want CodeBadConfig, got %v", err)
	}
	if ft.created != 0 {
		t.Error("a rejected config must not create a utun")
	}
}

// A failed up must leave nothing behind: a retry has to start from a clean
// slate, and the user must not be left with traffic pointed at a dead tunnel.
func TestDarwinUpFailureCleansUp(t *testing.T) {
	m, ft, dev := newDarwinManager(t)
	dev.setErr = errors.New("device refused the config")

	_, err := m.Up(context.Background(), validConfig)
	if err == nil {
		t.Fatal("expected the failure to surface")
	}
	if len(ft.tornDown) == 0 {
		t.Error("routes must be torn down after a failed up")
	}
	if dev.closed != 1 {
		t.Errorf("the device must be closed, closed=%d", dev.closed)
	}
	if ft.closed == 0 {
		t.Error("the utun must be closed after a failed up")
	}
	if _, statErr := os.Stat(m.configPath()); statErr == nil {
		t.Error("a failed up must not leave a config file behind")
	}
}

func TestDarwinDownIsIdempotent(t *testing.T) {
	m, ft, dev := newDarwinManager(t)

	if _, err := m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("Up: %v", err)
	}
	for i := 0; i < 2; i++ {
		st, err := m.Down(context.Background())
		if err != nil {
			t.Fatalf("Down %d: %v", i, err)
		}
		if st.Stage != protocol.StageDisconnected || st.Up {
			t.Errorf("Down %d: want disconnected, got %+v", i, st)
		}
	}
	if dev.closed != 1 {
		t.Errorf("the device must be closed once, closed=%d", dev.closed)
	}
	// A second Down with nothing live must not fail on a missing interface.
	if len(ft.tornDown) != 1 {
		t.Errorf("teardown ran %d times, want 1", len(ft.tornDown))
	}
}

// Up always tears the previous device down first, so the requested config is
// the one that ends up live.
func TestDarwinUpReplacesAnExistingTunnel(t *testing.T) {
	m, ft, _ := newDarwinManager(t)

	if _, err := m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("first Up: %v", err)
	}
	if _, err := m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("second Up: %v", err)
	}
	if ft.created != 2 {
		t.Errorf("expected a second utun, created=%d", ft.created)
	}
	if len(ft.tornDown) != 1 {
		t.Errorf("the first tunnel must be torn down, tornDown=%v", ft.tornDown)
	}
}

func TestDarwinStatusProjectsPeers(t *testing.T) {
	m, _, dev := newDarwinManager(t)
	dev.dumpBody = FormatPeersAsUAPI(51820, []peer{{
		publicKey: mustHexDarwin(t, keyB),
		endpoint:  "203.0.113.10:51820",
		rxBytes:   11,
		txBytes:   22,
	}})

	if _, err := m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("Up: %v", err)
	}
	dev.dumpBody = FormatPeersAsUAPI(51820, []peer{{
		publicKey: mustHexDarwin(t, keyB),
		endpoint:  "203.0.113.10:51820",
		rxBytes:   11,
		txBytes:   22,
	}})

	st, err := m.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if !st.Up || st.Stage != protocol.StageConnected {
		t.Fatalf("want connected, got %+v", st)
	}
	if st.PublicKey != mustHexDarwin(t, keyB) {
		t.Errorf("peer key not projected: %q", st.PublicKey)
	}
	if st.RxBytes != 11 || st.TxBytes != 22 {
		t.Errorf("counters not projected: rx=%d tx=%d", st.RxBytes, st.TxBytes)
	}
}

// An unreadable device is unknown, never disconnected: reporting it as down
// would make the client tear down a working tunnel.
func TestDarwinStatusReadErrorIsNotDisconnected(t *testing.T) {
	m, _, dev := newDarwinManager(t)
	if _, err := m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("Up: %v", err)
	}
	dev.dumpErr = errors.New("device wedged")

	st, err := m.Status(context.Background())
	if err == nil {
		t.Fatalf("a read failure must be reported, got %+v", st)
	}
	if st != nil {
		t.Errorf("no status may be returned alongside an error, got %+v", st)
	}
}

func TestDarwinStatusDisconnectedWhenDown(t *testing.T) {
	m, _, _ := newDarwinManager(t)

	st, err := m.Status(context.Background())
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if st.Stage != protocol.StageDisconnected || st.Up {
		t.Errorf("want disconnected, got %+v", st)
	}
}

func TestParseClientSettings(t *testing.T) {
	settings, err := parseClientSettings(validConfig)
	if err != nil {
		t.Fatalf("parseClientSettings: %v", err)
	}
	if settings.address != "10.8.0.5/32" {
		t.Errorf("address not parsed: %q", settings.address)
	}
	if settings.dns != "10.8.0.1" {
		t.Errorf("dns not parsed: %q", settings.dns)
	}
	if len(settings.allowedIPs) != 1 || settings.allowedIPs[0] != "0.0.0.0/0" {
		t.Errorf("allowed IPs not parsed: %v", settings.allowedIPs)
	}
}

// A config with no Address cannot be brought up: the interface would come up
// with no tunnel address and carry nothing.
func TestParseClientSettingsRequiresAddress(t *testing.T) {
	_, err := parseClientSettings("[Interface]\nPrivateKey = " + keyA + "\n\n[Peer]\nPublicKey = " + keyB + "\n")
	if err == nil {
		t.Error("expected a missing Address to be rejected")
	}
}

func TestDarwinManagerHonorsCanceledContext(t *testing.T) {
	m, ft, _ := newDarwinManager(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	if _, err := m.Up(ctx, validConfig); err == nil {
		t.Fatal("a canceled request must not start a tunnel")
	}
	if ft.created != 0 {
		t.Error("a canceled request must not create a utun")
	}
}

func TestDarwinConfigDirIsCreated(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "nested", "config")
	m := NewManager(dir, DefaultInterface)
	m.makeTun = &fakeTun{}
	m.makeDevice = func(_ tun.Device) (wireguardDevice, error) { return &fakeDevice{}, nil }

	if _, err := m.Up(context.Background(), validConfig); err != nil {
		t.Fatalf("Up: %v", err)
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		t.Errorf("config dir not created: %v", err)
	}
	// The config holds the private key, so it must not be world readable.
	info, err := os.Stat(m.configPath())
	if err != nil {
		t.Fatalf("stat config: %v", err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		t.Errorf("config is accessible beyond its owner: %04o", perm)
	}
}

// mustHexDarwin is the darwin suite's key helper, kept separate from the
// uapi_test one so that file stays buildable on every platform.
func mustHexDarwin(t *testing.T, b64 string) string {
	t.Helper()
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatalf("decode key: %v", err)
	}
	return hex.EncodeToString(raw)
}

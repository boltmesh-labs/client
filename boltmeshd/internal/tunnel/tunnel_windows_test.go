//go:build windows

package tunnel

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

	"boltmeshd/internal/protocol"
)

// TestWGStructLayout pins the wireguard.dll ABI. If any of these change, the
// driver reads would land on the wrong offsets.
func TestWGStructLayout(t *testing.T) {
	if size := int(unsafe.Sizeof(wgInterface{})); size != 80 {
		t.Fatalf("wgInterface size = %d, want 80", size)
	}
	if off := int(unsafe.Offsetof(wgInterface{}.PeersCount)); off != 72 {
		t.Fatalf("wgInterface.PeersCount offset = %d, want 72", off)
	}
	if size := int(unsafe.Sizeof(wgPeer{})); size != 136 {
		t.Fatalf("wgPeer size = %d, want 136", size)
	}
	peer := wgPeer{}
	if off := int(unsafe.Offsetof(peer.Endpoint)); off != 76 {
		t.Fatalf("wgPeer.Endpoint offset = %d, want 76", off)
	}
	if off := int(unsafe.Offsetof(peer.TxBytes)); off != 104 {
		t.Fatalf("wgPeer.TxBytes offset = %d, want 104", off)
	}
	if off := int(unsafe.Offsetof(peer.LastHandshake)); off != 120 {
		t.Fatalf("wgPeer.LastHandshake offset = %d, want 120", off)
	}
}

func TestPeersFromConfigParsesPeer(t *testing.T) {
	buffer := make([]byte, int(unsafe.Sizeof(wgInterface{}))+int(unsafe.Sizeof(wgPeer{})))
	iface := (*wgInterface)(unsafe.Pointer(&buffer[0]))
	iface.PeersCount = 1

	peer := (*wgPeer)(unsafe.Pointer(&buffer[int(unsafe.Sizeof(wgInterface{}))]))
	copy(peer.PublicKey[:], []byte{1, 2, 3})
	binary.LittleEndian.PutUint16(peer.Endpoint[0:2], afInet)
	binary.BigEndian.PutUint16(peer.Endpoint[2:4], 51820)
	copy(peer.Endpoint[4:8], net.ParseIP("203.0.113.10").To4())
	peer.RxBytes = 100
	peer.TxBytes = 200
	peer.LastHandshake = filetimeUnixEpoch + 2*filetimePerSecond

	peers, err := peersFromConfig(buffer)
	if err != nil {
		t.Fatalf("peersFromConfig() = %v", err)
	}
	if len(peers) != 1 {
		t.Fatalf("len(peers) = %d, want 1", len(peers))
	}
	got := peers[0]
	if got.endpoint != "203.0.113.10:51820" {
		t.Fatalf("endpoint = %q", got.endpoint)
	}
	if got.rxBytes != 100 || got.txBytes != 200 {
		t.Fatalf("counters = %d/%d", got.rxBytes, got.txBytes)
	}
	if !got.lastHandshake.Equal(time.Unix(2, 0).UTC()) {
		t.Fatalf("lastHandshake = %v", got.lastHandshake)
	}
	if got.publicKey != encodeKey([32]byte{1, 2, 3}) {
		t.Fatalf("publicKey = %q", got.publicKey)
	}
}

func TestPeersFromConfigRejectsTruncated(t *testing.T) {
	buffer := make([]byte, int(unsafe.Sizeof(wgInterface{})))
	(*wgInterface)(unsafe.Pointer(&buffer[0])).PeersCount = 1
	if _, err := peersFromConfig(buffer); err == nil {
		t.Fatal("peersFromConfig(truncated) = nil, want error")
	}
}

type fakeService struct {
	mu       sync.Mutex
	started  bool
	starts   int
	stops    int
	exe      string
	args     []string
	stageVal string
	stageErr error
	startErr error
	stopErr  error
}

func (f *fakeService) start(_ context.Context, exe string, args []string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.starts++
	f.exe, f.args = exe, args
	if f.startErr != nil {
		return f.startErr
	}
	f.started = true
	f.stageVal = protocol.StageConnected
	return nil
}

func (f *fakeService) stop(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stops++
	if f.stopErr != nil {
		return f.stopErr
	}
	f.started = false
	f.stageVal = protocol.StageDisconnected
	return nil
}

func (f *fakeService) stage(context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.stageErr != nil {
		return "", f.stageErr
	}
	if f.stageVal == "" {
		return protocol.StageDisconnected, nil
	}
	return f.stageVal, nil
}

type fakeDevice struct {
	peers []peer
	err   error
}

func (f *fakeDevice) read(context.Context, string) ([]peer, error) { return f.peers, f.err }

func newTestManager(t *testing.T) (*Manager, *fakeService, *fakeDevice) {
	t.Helper()
	svc := &fakeService{}
	dev := &fakeDevice{}
	m := NewManager(t.TempDir(), DefaultInterface)
	m.service = svc
	m.device = dev
	m.exeDir = func() (string, error) { return `C:\app`, nil }
	// The ACL helpers are exercised by their own tests; no-op here so the
	// temp config dir stays writable for the rest of the suite.
	m.protectDir = func(string) error { return nil }
	m.protectFile = func(string) error { return nil }
	return m, svc, dev
}

// aceSIDs returns the SID strings of every ACE in acl.
func aceSIDs(t *testing.T, acl *windows.ACL) map[string]bool {
	t.Helper()
	sids := make(map[string]bool)
	for i := uint32(0); i < uint32(acl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(acl, i, &ace); err != nil {
			t.Fatalf("GetAce(%d) = %v", i, err)
		}
		sids[(*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()] = true
	}
	return sids
}

// TestConfigACLPolicy pins the policy: exactly SYSTEM and Administrators, no
// BUILTIN\Users (which ProgramData inheritance would otherwise add).
func TestConfigACLPolicy(t *testing.T) {
	acl, err := configACL(windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT)
	if err != nil {
		t.Fatalf("configACL() = %v", err)
	}
	if acl.AceCount != 2 {
		t.Fatalf("AceCount = %d, want 2", acl.AceCount)
	}
	sids := aceSIDs(t, acl)
	if !sids[localSystemSID] || !sids[administratorsSID] {
		t.Fatalf("ACL SIDs = %v, want %s and %s", sids, localSystemSID, administratorsSID)
	}
}

// TestProtectConfigDirAppliesACL proves the syscall path works end to end.
func TestProtectConfigDirAppliesACL(t *testing.T) {
	dir := t.TempDir()
	// Grant cleanup access back afterwards: the protected DACL denies the
	// invoking (non-SYSTEM) test account, which would otherwise make
	// t.TempDir() removal fail.
	t.Cleanup(func() {
		everyone, err := windows.StringToSid("S-1-1-0")
		if err != nil {
			return
		}
		acl, err := windows.ACLFromEntries([]windows.EXPLICIT_ACCESS{{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.GRANT_ACCESS,
			Inheritance:       windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
			Trustee: windows.TRUSTEE{
				TrusteeForm:  windows.TRUSTEE_IS_SID,
				TrusteeType:  windows.TRUSTEE_IS_WELL_KNOWN_GROUP,
				TrusteeValue: windows.TrusteeValueFromSID(everyone),
			},
		}}, nil)
		if err != nil {
			return
		}
		_ = windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
			windows.DACL_SECURITY_INFORMATION, nil, nil, acl, nil)
	})

	if err := protectConfigDir(dir); err != nil {
		t.Fatalf("protectConfigDir() = %v", err)
	}

	sd, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatalf("GetNamedSecurityInfo() = %v", err)
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		t.Fatalf("DACL() = %v", err)
	}
	if dacl.AceCount != 2 {
		t.Fatalf("applied DACL has %d ACEs, want 2", dacl.AceCount)
	}
	sids := aceSIDs(t, dacl)
	if !sids[localSystemSID] || !sids[administratorsSID] {
		t.Fatalf("applied DACL SIDs = %v, want %s and %s", sids, localSystemSID, administratorsSID)
	}
}

func TestUpWritesConfigAndStartsService(t *testing.T) {
	m, svc, dev := newTestManager(t)
	dev.peers = []peer{{publicKey: "pub", endpoint: "203.0.113.10:51820", lastHandshake: time.Unix(2000, 0), rxBytes: 5, txBytes: 6}}

	status, err := m.Up(context.Background(), validConfig)
	if err != nil {
		t.Fatalf("Up() = %v", err)
	}
	if !status.Up || status.Stage != protocol.StageConnected || status.RxBytes != 5 {
		t.Fatalf("Up() status = %+v", status)
	}
	if svc.starts != 1 {
		t.Fatalf("starts = %d, want 1", svc.starts)
	}
	if svc.stops != 1 {
		t.Fatalf("stops = %d, want 1 (teardown before start)", svc.stops)
	}
	if svc.exe != `C:\app\`+wireguardSvcExe {
		t.Fatalf("exe = %q", svc.exe)
	}
	if len(svc.args) != 2 || svc.args[0] != "-service" || !strings.HasPrefix(svc.args[1], "-config-file=") {
		t.Fatalf("args = %v", svc.args)
	}
	if _, err := os.Stat(m.configPath()); err != nil {
		t.Fatalf("config not written: %v", err)
	}
}

func TestUpRejectsInvalidConfigWithoutTouchingService(t *testing.T) {
	m, svc, _ := newTestManager(t)

	_, err := m.Up(context.Background(), "not a config")
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeBadConfig {
		t.Fatalf("Up(invalid) = %v, want bad_config", err)
	}
	if svc.starts != 0 || svc.stops != 0 {
		t.Fatalf("service touched: starts=%d stops=%d", svc.starts, svc.stops)
	}
	if _, statErr := os.Stat(m.configPath()); !os.IsNotExist(statErr) {
		t.Fatal("config written for invalid input")
	}
}

func TestDownIsIdempotent(t *testing.T) {
	m, svc, _ := newTestManager(t)

	status, err := m.Down(context.Background())
	if err != nil {
		t.Fatalf("Down() = %v", err)
	}
	if status.Up || status.Stage != protocol.StageDisconnected {
		t.Fatalf("Down() status = %+v", status)
	}
	if svc.stops != 1 {
		t.Fatalf("stops = %d, want 1", svc.stops)
	}
}

func TestStatusReportsConnecting(t *testing.T) {
	m, svc, _ := newTestManager(t)
	svc.stageVal = protocol.StageConnecting

	status := m.Status()
	if status.Up || status.Stage != protocol.StageConnecting {
		t.Fatalf("Status() = %+v, want connecting", status)
	}
}

func TestStatusUpSurvivesDeviceReadFailure(t *testing.T) {
	m, svc, dev := newTestManager(t)
	svc.stageVal = protocol.StageConnected
	dev.err = errors.New("no device")

	status := m.Status()
	if !status.Up || status.Stage != protocol.StageConnected {
		t.Fatalf("Status() = %+v, want connected despite read failure", status)
	}
	if status.RxBytes != 0 || status.LastHandshake != 0 {
		t.Fatalf("counters = %+v, want unknown", status)
	}
}

func TestStatusDisconnectedWhenServiceQueryFails(t *testing.T) {
	m, svc, _ := newTestManager(t)
	svc.stageErr = errors.New("scm down")

	status := m.Status()
	if status.Up || status.Stage != protocol.StageDisconnected {
		t.Fatalf("Status() = %+v, want disconnected", status)
	}
}

func TestFormatEndpointIPv4(t *testing.T) {
	var raw [28]byte
	binary.LittleEndian.PutUint16(raw[0:2], afInet)
	binary.BigEndian.PutUint16(raw[2:4], 51820)
	copy(raw[4:8], net.ParseIP("203.0.113.10").To4())

	if got := formatEndpoint(raw); got != "203.0.113.10:51820" {
		t.Fatalf("formatEndpoint = %q, want 203.0.113.10:51820", got)
	}
}

func TestFormatEndpointIPv6(t *testing.T) {
	var raw [28]byte
	binary.LittleEndian.PutUint16(raw[0:2], afInet6)
	binary.BigEndian.PutUint16(raw[2:4], 51820)
	copy(raw[8:24], net.ParseIP("2001:db8::1").To16())

	if got := formatEndpoint(raw); got != "[2001:db8::1]:51820" {
		t.Fatalf("formatEndpoint = %q, want [2001:db8::1]:51820", got)
	}
}

func TestFormatEndpointUnknownFamily(t *testing.T) {
	var raw [28]byte
	if got := formatEndpoint(raw); got != "" {
		t.Fatalf("formatEndpoint = %q, want empty", got)
	}
}

func TestFiletimeToTime(t *testing.T) {
	if got := filetimeToTime(0); !got.IsZero() {
		t.Fatalf("filetimeToTime(0) = %v, want zero", got)
	}
	value := uint64(filetimeUnixEpoch + 2*filetimePerSecond)
	if got := filetimeToTime(value); !got.Equal(time.Unix(2, 0).UTC()) {
		t.Fatalf("filetimeToTime = %v, want %v", got, time.Unix(2, 0).UTC())
	}
}

func TestEncodeKey(t *testing.T) {
	var key [32]byte
	want := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	if got := encodeKey(key); got != want {
		t.Fatalf("encodeKey = %q, want %q", got, want)
	}
}

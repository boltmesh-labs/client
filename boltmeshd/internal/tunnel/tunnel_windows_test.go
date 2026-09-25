//go:build windows

package tunnel

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
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
	mu         sync.Mutex
	started    bool
	starts     int
	stops      int
	removes    int
	stageCalls int
	exe        string
	args       []string
	stageVal   string
	stageErr   error
	startErr   error
	stopErr    error
	removeErr  error
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

func (f *fakeService) remove(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stops++
	f.removes++
	if f.removeErr != nil {
		return f.removeErr
	}
	f.started = false
	f.stageVal = protocol.StageDisconnected
	return nil
}

func (f *fakeService) stage(context.Context) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.stageCalls++
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
	m.stat = func(string) (os.FileInfo, error) { return nil, nil }
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

// TestConfigOwnerSIDIsLocalSystem pins the production owner. The end-to-end test
// above may retarget configOwnerSID when the runner token cannot assign a
// foreign owner, so the default has to be asserted on its own.
func TestConfigOwnerSIDIsLocalSystem(t *testing.T) {
	if configOwnerSID != localSystemSID {
		t.Fatalf("configOwnerSID = %q, want %q", configOwnerSID, localSystemSID)
	}
}

// retargetConfigOwnerToCurrentUser points configOwnerSID at the invoking account,
// which is always assignable, and restores it when the test ends. Production
// runs as LocalSystem, where the SYSTEM owner assignment is a no-op; this only
// keeps the rest of protectConfigDir covered on a token without
// SE_RESTORE_NAME.
func retargetConfigOwnerToCurrentUser(t *testing.T) {
	t.Helper()
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatalf("read the current token user: %v", err)
	}
	if user.User.Sid == nil {
		t.Fatal("current token user has no SID")
	}
	previous := configOwnerSID
	configOwnerSID = user.User.Sid.String()
	t.Cleanup(func() { configOwnerSID = previous })
}

// TestEnableRestorePrivilegeRestoresToken covers the privilege handling that
// lets the elevated installer make the directory SYSTEM-owned. A token that
// holds SE_RESTORE_NAME must have it enabled only for the duration of the call,
// and a token that does not hold it must be left alone rather than reporting a
// failure of its own.
func TestEnableRestorePrivilegeRestoresToken(t *testing.T) {
	name, err := windows.UTF16PtrFromString("SeRestorePrivilege")
	if err != nil {
		t.Fatal(err)
	}
	var luid windows.LUID
	if err := windows.LookupPrivilegeValue(nil, name, &luid); err != nil {
		t.Fatal(err)
	}
	token := windows.GetCurrentProcessToken()
	restorePrivilegeState := func() (bool, error) {
		_, enabled, err := tokenPrivilegeState(token, luid)
		return enabled, err
	}

	before, err := restorePrivilegeState()
	if err != nil {
		t.Fatal(err)
	}
	restore, canAssign, err := enableRestorePrivilege()
	if err != nil {
		t.Fatalf("enableRestorePrivilege() = %v", err)
	}
	if restore == nil {
		t.Fatal("enableRestorePrivilege() returned a nil restore function")
	}
	during, err := restorePrivilegeState()
	if err != nil {
		restore()
		t.Fatal(err)
	}
	restore()
	after, err := restorePrivilegeState()
	if err != nil {
		t.Fatal(err)
	}
	if after != before {
		t.Fatalf("SE_RESTORE_NAME enabled = %v after restore, want %v", after, before)
	}
	if canAssign && !during {
		t.Fatal("canAssign = true but SE_RESTORE_NAME is not enabled during the call")
	}
	// Whatever it reported, the only state a caller may observe afterwards is
	// the one it started in.
	if canAssign != during && before {
		t.Fatalf("canAssign = %v, want %v for an already-enabled privilege", canAssign, during)
	}
}

// TestOwnerIsCurrentUser pins the predicate that decides whether a failed
// ownership transfer is reported as needing elevation. It must recognise the
// daemon's own account, or the LocalSystem service path would be told to run as
// an administrator.
func TestOwnerIsCurrentUser(t *testing.T) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	if user.User.Sid == nil {
		t.Fatal("current token user has no SID")
	}
	system, err := windows.StringToSid(configOwnerSID)
	if err != nil {
		t.Fatal(err)
	}
	current, ok := ownerIsCurrentUser(system)
	if !ok {
		t.Fatal("ownerIsCurrentUser() could not read the token user")
	}
	if want := user.User.Sid.Equals(system); current != want {
		t.Fatalf("ownerIsCurrentUser(%s) = %v, want %v", configOwnerSID, current, want)
	}
}

// restoreEveryoneAccess grants cleanup access back after a test protected a
// directory: the protected DACL denies the invoking (non-SYSTEM) test account,
// which would otherwise make t.TempDir() removal fail.
func restoreEveryoneAccess(t *testing.T, dir string) {
	t.Helper()
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
}

// protectDirForTest runs protectConfigDir, retargeting the owner at the current
// account when the token cannot assign a foreign owner. A non-elevated CI runner
// has no SERestorePrivilege, so Windows rejects the SYSTEM owner outright;
// SetSecurityInfo applies the whole descriptor in one call, so the failed
// attempt left the directory untouched and the retry starts from the same state.
func protectDirForTest(t *testing.T, dir string) {
	t.Helper()
	err := protectConfigDir(dir)
	if err == nil {
		return
	}
	if !errors.Is(err, windows.ERROR_INVALID_OWNER) {
		t.Fatalf("protectConfigDir() = %v", err)
	}
	retargetConfigOwnerToCurrentUser(t)
	if err := protectConfigDir(dir); err != nil {
		t.Fatalf("protectConfigDir() with a self-assignable owner = %v", err)
	}
}

// TestProtectConfigDirStripsForeignACE covers the case a CI temp directory
// cannot reproduce. ProgramData's default ACL carries an inheritable
// CREATOR OWNER entry, so a directory an interactive admin creates under it
// arrives already granting that account full control, inheritable by
// everything below. A t.TempDir() has no such ACE, which is why
// TestProtectConfigDirAppliesACL passes without ever seeing one. Asserting the
// policy on a pristine directory only proves the code can build the right DACL;
// this proves it discards a pre-existing one that is not the policy.
func TestProtectConfigDirStripsForeignACE(t *testing.T) {
	dir := t.TempDir()
	restoreEveryoneAccess(t, dir)

	// Seed the DACL ProgramData hands a newly-created subdirectory: SYSTEM and
	// Administrators as full control, plus the creating account.
	seed := []windows.EXPLICIT_ACCESS{}
	for _, entry := range []struct {
		sid         string
		trusteeType windows.TRUSTEE_TYPE
	}{
		{localSystemSID, windows.TRUSTEE_IS_USER},
		{administratorsSID, windows.TRUSTEE_IS_GROUP},
	} {
		sid, err := windows.StringToSid(entry.sid)
		if err != nil {
			t.Fatal(err)
		}
		seed = append(seed, windows.EXPLICIT_ACCESS{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.GRANT_ACCESS,
			Inheritance:       windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
			Trustee: windows.TRUSTEE{
				TrusteeForm:  windows.TRUSTEE_IS_SID,
				TrusteeType:  entry.trusteeType,
				TrusteeValue: windows.TrusteeValueFromSID(sid),
			},
		})
	}
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		t.Fatal(err)
	}
	seed = append(seed, windows.EXPLICIT_ACCESS{
		AccessPermissions: windows.GENERIC_ALL,
		AccessMode:        windows.GRANT_ACCESS,
		Inheritance:       windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT,
		Trustee: windows.TRUSTEE{
			TrusteeForm:  windows.TRUSTEE_IS_SID,
			TrusteeType:  windows.TRUSTEE_IS_USER,
			TrusteeValue: windows.TrusteeValueFromSID(user.User.Sid),
		},
	})
	seedACL, err := windows.ACLFromEntries(seed, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := windows.SetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION, nil, nil, seedACL, nil); err != nil {
		t.Fatalf("seed the directory DACL: %v", err)
	}

	protectDirForTest(t, dir)

	sd, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatalf("GetNamedSecurityInfo() = %v", err)
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		t.Fatalf("DACL() = %v", err)
	}
	allowed := make(map[string]bool)
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			t.Fatalf("GetAce(%d) = %v", i, err)
		}
		allowed[(*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()] = true
	}
	for _, unwanted := range []string{user.User.Sid.String(), "S-1-1-0"} {
		if allowed[unwanted] {
			t.Fatalf("protected DACL still grants %s", unwanted)
		}
	}
	if !allowed[localSystemSID] || !allowed[administratorsSID] {
		t.Fatalf("protected DACL = %v, want SYSTEM and Administrators", allowed)
	}
	if len(allowed) != 2 {
		t.Fatalf("protected DACL grants %d principals, want exactly 2: %v", len(allowed), allowed)
	}
}

// TestProtectConfigDirAppliesACL proves the syscall path works end to end.
func TestProtectConfigDirAppliesACL(t *testing.T) {
	dir := t.TempDir()
	restoreEveryoneAccess(t, dir)

	protectDirForTest(t, dir)

	sd, err := windows.GetNamedSecurityInfo(dir, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		t.Fatalf("GetNamedSecurityInfo() = %v", err)
	}
	// The DACL must be protected. This is the load-bearing check: an
	// inherited (unprotected) DACL is what ProgramData would leave behind, so
	// it is what fails when protectConfigDir is a no-op.
	control, _, err := sd.Control()
	if err != nil {
		t.Fatalf("Control() = %v", err)
	}
	if control&windows.SE_DACL_PROTECTED == 0 {
		t.Fatal("applied DACL is not protected (SE_DACL_PROTECTED unset)")
	}

	dacl, _, err := sd.DACL()
	if err != nil {
		t.Fatalf("DACL() = %v", err)
	}
	// Windows splits each inheritable GENERIC_ALL entry on a directory into an
	// effective ACE plus an INHERIT_ONLY ACE that keeps the generic bits for
	// children to map, so the two entries applied above read back as four
	// ACEs. Assert the policy, not the count: every ACE is a non-inherited
	// allow for SYSTEM or Administrators, and nobody else.
	sids := make(map[string]bool)
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			t.Fatalf("GetAce(%d) = %v", i, err)
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			t.Fatalf("ACE %d type = %d, want ACCESS_ALLOWED", i, ace.Header.AceType)
		}
		if ace.Header.AceFlags&windows.INHERITED_ACE != 0 {
			t.Fatalf("ACE %d is inherited; the DACL is not fully protected", i)
		}
		sids[(*windows.SID)(unsafe.Pointer(&ace.SidStart)).String()] = true
	}
	if len(sids) != 2 || !sids[localSystemSID] || !sids[administratorsSID] {
		t.Fatalf("applied DACL SIDs = %v, want exactly %s and %s", sids, localSystemSID, administratorsSID)
	}
}

func TestWritePrivateFileProtectsBeforeWritingAndReplacesDestination(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "boltmesh0.conf")
	if err := os.WriteFile(path, []byte("attacker-controlled"), 0o600); err != nil {
		t.Fatal(err)
	}

	protected := false
	if err := writePrivateFile(path, []byte("fresh-secret"), func(tempPath string) error {
		protected = true
		data, err := os.ReadFile(tempPath)
		if err != nil {
			return err
		}
		if len(data) != 0 {
			return fmt.Errorf("temporary file contains %d bytes before protection", len(data))
		}
		return nil
	}); err != nil {
		t.Fatalf("writePrivateFile() = %v", err)
	}
	if !protected {
		t.Fatal("temporary file was not protected")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(data); got != "fresh-secret" {
		t.Fatalf("config = %q, want fresh-secret", got)
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

func TestUpReportsMissingWireGuardServiceBeforeTouchingTunnel(t *testing.T) {
	m, svc, _ := newTestManager(t)
	want := errors.New("file not found")
	m.stat = func(string) (os.FileInfo, error) { return nil, want }

	_, err := m.Up(context.Background(), validConfig)
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Up() = %v, want internal error", err)
	}
	if !strings.Contains(err.Error(), "wireguard_svc.exe") || !strings.Contains(err.Error(), "wireguard.dll") {
		t.Fatalf("Up() = %v, want missing bundle diagnostic", err)
	}
	if svc.starts != 0 || svc.stops != 0 {
		t.Fatalf("service touched: starts=%d stops=%d", svc.starts, svc.stops)
	}
	if _, statErr := os.Stat(m.configPath()); !os.IsNotExist(statErr) {
		t.Fatal("config written when tunnel service executable was missing")
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

func TestUninstallStopsRemovesConfigAndService(t *testing.T) {
	m, svc, _ := newTestManager(t)
	if err := os.WriteFile(m.configPath(), []byte("private-key"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := m.Uninstall(context.Background()); err != nil {
		t.Fatalf("Uninstall() = %v", err)
	}
	if svc.stops != 1 || svc.removes != 1 {
		t.Fatalf("service calls: stops=%d removes=%d, want one of each", svc.stops, svc.removes)
	}
	if _, err := os.Stat(m.configPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("config still exists after Uninstall: %v", err)
	}
}

func TestUninstallLeavesConfigWhenServiceRemovalFails(t *testing.T) {
	m, svc, _ := newTestManager(t)
	if err := os.WriteFile(m.configPath(), []byte("private-key"), 0o600); err != nil {
		t.Fatal(err)
	}
	want := errors.New("service still stopping")
	svc.removeErr = want

	if err := m.Uninstall(context.Background()); !errors.Is(err, want) {
		t.Fatalf("Uninstall() = %v, want %v", err, want)
	}
	if _, err := os.Stat(m.configPath()); err != nil {
		t.Fatalf("config was removed despite failed service cleanup: %v", err)
	}
}

func TestStatusReportsConnecting(t *testing.T) {
	m, svc, _ := newTestManager(t)
	svc.stageVal = protocol.StageConnecting

	status, err := m.Status(context.Background())
	if err != nil {
		t.Fatalf("Status() = %v", err)
	}
	if status.Up || status.Stage != protocol.StageConnecting {
		t.Fatalf("Status() = %+v, want connecting", status)
	}
}

func TestStatusReportsDisconnectedWhenServiceIsNotInstalled(t *testing.T) {
	m, _, _ := newTestManager(t)

	status, err := m.Status(context.Background())
	if err != nil {
		t.Fatalf("Status() = %v, want absent service", err)
	}
	if status.Up || status.Stage != protocol.StageDisconnected {
		t.Fatalf("Status() = %+v, want disconnected", status)
	}
}

func TestBusyStatusPrecedesRunningService(t *testing.T) {
	m, svc, _ := newTestManager(t)
	svc.stageVal = protocol.StageConnected
	m.busy.Store(true)

	status, err := m.Status(context.Background())
	if err != nil {
		t.Fatalf("Status() = %v", err)
	}
	if status.Up || status.Stage != protocol.StageConnecting {
		t.Fatalf("Status() = %+v, want connecting without an Up flag", status)
	}
	if svc.stageCalls != 0 {
		t.Fatalf("SCM queried %d times while up was in flight", svc.stageCalls)
	}
}

func TestStatusHonorsCanceledContext(t *testing.T) {
	m, svc, _ := newTestManager(t)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	status, err := m.Status(ctx)
	if status != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("Status() = (%+v, %v), want context cancellation", status, err)
	}
	if svc.stageCalls != 0 {
		t.Fatalf("SCM queried %d times after cancellation", svc.stageCalls)
	}
}

func TestStatusUpSurvivesDeviceReadFailure(t *testing.T) {
	m, svc, dev := newTestManager(t)
	svc.stageVal = protocol.StageConnected
	dev.err = errors.New("no device")

	status, err := m.Status(context.Background())
	if err != nil {
		t.Fatalf("Status() = %v", err)
	}
	if !status.Up || status.Stage != protocol.StageConnected {
		t.Fatalf("Status() = %+v, want connected despite read failure", status)
	}
	if status.RxBytes != 0 || status.LastHandshake != 0 {
		t.Fatalf("counters = %+v, want unknown", status)
	}
}

func TestStatusReturnsServiceReadError(t *testing.T) {
	want := errors.New("scm down")
	m, svc, _ := newTestManager(t)
	svc.stageErr = want

	status, err := m.Status(context.Background())
	if status != nil || !errors.Is(err, want) {
		t.Fatalf("Status() = (%+v, %v), want SCM read error", status, err)
	}
	var opErr *protocol.OpError
	if !errors.As(err, &opErr) || opErr.Code != protocol.CodeInternal {
		t.Fatalf("Status() error = %v, want internal", err)
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

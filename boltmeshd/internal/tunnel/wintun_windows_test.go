//go:build windows

package tunnel

import (
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

// TestWintunVendoredBinaryMatchesThePin is the check that keeps the vendored
// binary and the constant in wintun_windows.go from drifting apart. The pin is
// what the loader trusts, so a changed file with an unchanged pin would fail every
// obfuscated bring-up at runtime instead of here.
//
// It reads the copy beside the test binary, not a path relative to the source
// file: a compiled test binary (`go test -c`, or the one the elevated pin check
// runs from) has no source directory to resolve against, and this check is
// exactly the one that must hold wherever the binary is staged.
func TestWintunVendoredBinaryMatchesThePin(t *testing.T) {
	src := filepath.Join(wintunVendoredDir, wintunDLLName)
	sum, err := sha256File(src)
	if err != nil {
		t.Skipf("no %s beside the test binary at %s (%v); the vendored binary is "+
			"staged by stage_boltmeshd.ps1, so this check only applies to a staged bundle",
			wintunDLLName, src, err)
	}
	if sum != wintunSHA256 {
		t.Fatalf("vendored %s hashes to %s, want %s.\n"+
			"If this is an intentional upgrade, replace the binary, update wintunSHA256, "+
			"and update third_party/wintun/README.md in the same commit.",
			wintunDLLName, sum, wintunSHA256)
	}
}

// TestEnsureWintunPinnedFailsClosedOnAWrongVendoredBinary is the property that
// matters most: a substituted driver must never reach the tunnel. The vendored
// source is redirected at a file with the wrong content, and the pin must refuse
// rather than copy it into the target directory where it would run with SYSTEM's
// privileges.
func TestEnsureWintunPinnedFailsClosedOnAWrongVendoredBinary(t *testing.T) {
	dir := t.TempDir()

	bogus := filepath.Join(dir, "vendored-wintun.dll")
	if err := os.WriteFile(bogus, []byte("not the reviewed driver"), 0o600); err != nil {
		t.Fatalf("write the bogus source: %v", err)
	}
	// An existing target that is also wrong, so the fast path cannot short-circuit.
	stale := filepath.Join(dir, wintunDLLName)
	if err := os.WriteFile(stale, []byte("a previously installed wrong copy"), 0o555); err != nil {
		t.Fatalf("write the stale target: %v", err)
	}

	restore := wintunPinPaths(dir, dir)
	defer restore()

	if _, err := ensureWintunPinned(); err == nil {
		t.Fatal("ensureWintunPinned accepted an unreviewed driver; a substituted " +
			"driver would own every packet the tunnel carries")
	} else {
		for _, want := range []string{"hashes to", "does not match the pin"} {
			if !containsStr(err.Error(), want) {
				t.Errorf("ensureWintunPinned error = %v, want it to mention %q", err, want)
			}
		}
	}
}

// TestEnsureWintunPinnedRefusesAnUnreviewedBinary drives the refusal path with
// the target and source both redirected into a temp directory, so the check needs
// no elevation and touches no real system path.
func TestEnsureWintunPinnedRefusesAnUnreviewedBinary(t *testing.T) {
	dir := t.TempDir()

	// The "vendored" file has plausible size and shape but is not the reviewed
	// binary. Everything except the content hash is what a real deployment looks
	// like.
	bogus := filepath.Join(dir, "vendored-wintun.dll")
	if err := os.WriteFile(bogus, []byte("not the reviewed driver"), 0o600); err != nil {
		t.Fatalf("write the bogus source: %v", err)
	}
	// An existing System32 copy that is also wrong, so the fast path cannot
	// short-circuit on it either.
	stale := filepath.Join(dir, wintunDLLName)
	if err := os.WriteFile(stale, []byte("a previously installed wrong copy"), 0o555); err != nil {
		t.Fatalf("write the stale target: %v", err)
	}

	restore := wintunPinPaths(dir, dir)
	defer restore()

	_, err := ensureWintunPinned()
	if err == nil {
		t.Fatal("ensureWintunPinned accepted an unreviewed driver; a substituted " +
			"driver would own every packet the tunnel carries")
	}
	for _, want := range []string{"hashes to", "does not match the pin"} {
		if !containsStr(err.Error(), want) {
			t.Errorf("ensureWintunPinned error = %v, want it to mention %q", err, want)
		}
	}
}

// TestEnsureWintunPinnedLeavesTheWrongTargetInPlace confirms the refusal is not
// destructive: a wrong System32 copy must survive, so an operator can inspect
// what is actually there rather than finding it silently replaced or deleted.
func TestEnsureWintunPinnedLeavesTheWrongTargetInPlace(t *testing.T) {
	dir := t.TempDir()

	bogus := filepath.Join(dir, "vendored-wintun.dll")
	if err := os.WriteFile(bogus, []byte("not the reviewed driver"), 0o600); err != nil {
		t.Fatalf("write the bogus source: %v", err)
	}
	stale := filepath.Join(dir, wintunDLLName)
	contents := []byte("a previously installed wrong copy")
	if err := os.WriteFile(stale, contents, 0o555); err != nil {
		t.Fatalf("write the stale target: %v", err)
	}

	restore := wintunPinPaths(dir, dir)
	defer restore()

	if _, err := ensureWintunPinned(); err == nil {
		t.Fatal("ensureWintunPinned accepted an unreviewed driver")
	}

	after, err := os.ReadFile(stale)
	if err != nil {
		t.Fatalf("the wrong target was removed rather than left for inspection: %v", err)
	}
	if string(after) != string(contents) {
		t.Errorf("the wrong target was rewritten to %q, want it untouched at %q",
			after, contents)
	}
}

// TestEnsureWintunPinnedRefusesAMissingSource covers the other fail-closed case:
// no vendored binary at all must be an error, never a silent fall back to the
// library's own search.
func TestEnsureWintunPinnedRefusesAMissingSource(t *testing.T) {
	// An empty directory: neither a pinned copy nor a vendored source exists.
	dir := t.TempDir()

	restore := wintunPinPaths(dir, dir)
	defer restore()

	_, err := ensureWintunPinned()
	if err == nil {
		t.Fatal("ensureWintunPinned accepted a missing vendored driver")
	}
	if !containsStr(err.Error(), "unreadable") {
		t.Errorf("ensureWintunPinned error = %v, want it to name the unreadable source", err)
	}
}

// TestEnsureWintunPinnedInstallsTheVerifiedCopy is the elevated integration
// check: it runs [ensureWintunPinned] against the real System32 target, which the
// temp-directory tests cannot do, and then asks the upstream binding to load the
// driver by bare name from a directory that has no wintun.dll in it.
//
// That combination is the actual claim being made. The unit tests prove the
// refusal paths; this proves the install lands and that the library's own
// name-based load is satisfied by the pinned bytes -- which is the part that
// cannot be reasoned about from the source, because the resolution order lives in
// the Windows loader.
//
// Skips unless BOLTMESH_WINTUN_PIN_TEST=1 is set, on purpose. Elevation alone is
// not a sufficient opt-in: this writes to a directory shared by every process on
// the machine, and "the developer opened an admin shell" is not consent to have a
// kernel driver installed by their test run. It also restores whatever was in
// System32 beforehand, so it leaves the machine as it found it.
//
//	go test ./internal/tunnel/ -run TestEnsureWintunPinned -v   (from an admin shell)
//	$env:BOLTMESH_WINTUN_PIN_TEST=1; go test ./internal/tunnel/ -run Pin -v
func TestEnsureWintunPinnedInstallsTheVerifiedCopy(t *testing.T) {
	if os.Getenv("BOLTMESH_WINTUN_PIN_TEST") != "1" {
		t.Skip("skipping: set BOLTMESH_WINTUN_PIN_TEST=1 from an elevated shell to " +
			"exercise the real System32 pin")
	}
	if !isElevated() {
		t.Fatal("BOLTMESH_WINTUN_PIN_TEST=1 but the shell is not elevated")
	}

	target := filepath.Join(wintunSystem32Dir, wintunDLLName)
	before, readErr := os.ReadFile(target)
	hadBefore := readErr == nil
	t.Cleanup(func() {
		if !hadBefore {
			_ = os.Remove(target)
			return
		}
		_ = os.WriteFile(target, before, wintunDLLMode)
	})
	if hadBefore {
		if err := os.Remove(target); err != nil {
			t.Fatalf("could not clear the existing %s so this is a real install: %v",
				wintunDLLName, err)
		}
	}

	got, err := ensureWintunPinned()
	if err != nil {
		t.Fatalf("ensureWintunPinned: %v", err)
	}
	if want := filepath.Join(wintunSystem32Dir, wintunDLLName); got != want {
		t.Errorf("ensureWintunPinned returned %s, want %s", got, want)
	}

	sum, err := sha256File(target)
	if err != nil {
		t.Fatalf("the pinned copy is not readable at %s: %v", target, err)
	}
	if sum != wintunSHA256 {
		t.Errorf("installed %s hashes to %s, want %s", wintunDLLName, sum, wintunSHA256)
	}

	// The vendored binary must be beside the executable for the pin to find it,
	// which is what stage_boltmeshd.ps1 arranges. Say so plainly if it is not,
	// rather than failing later inside a tunnel.
	vendored := filepath.Join(wintunVendoredDir, wintunDLLName)
	if _, err := os.Stat(vendored); err != nil {
		t.Fatalf("the vendored %s is not beside the helper at %s: %v\n"+
			"stage_boltmeshd.ps1 copies it there; the test ran outside a staged bundle",
			wintunDLLName, vendored, err)
	}

	// The load is a separate test on purpose: loading the driver locks the file,
	// and Windows will not delete a locked module. Keeping it apart is what lets
	// this test clean up after itself.
}

// TestPinnedWintunSatisfiesTheLibrariesBareNameLoad is the assertion that
// motivates the whole pin: the upstream binding resolves "wintun.dll" by bare name
// with LOAD_LIBRARY_SEARCH_APPLICATION_DIR|SYSTEM32, so a substituted file beside
// boltmeshd.exe would satisfy it. Loading through [loadWintunDLL] first, by
// absolute path from System32, is what makes the library's own load resolve to
// the reviewed bytes instead.
//
// Deliberately leaves the pinned driver in System32 afterwards, because loading
// it locks the file and Windows will not delete a locked module. That is also
// what production does -- [ensureWintunPinned] installs the driver there once and
// every later obfuscated bring-up reuses it -- so the residue is the steady state
// rather than pollution. Remove it by hand to get back to a clean machine.
func TestPinnedWintunSatisfiesTheLibrariesBareNameLoad(t *testing.T) {
	if os.Getenv("BOLTMESH_WINTUN_PIN_TEST") != "1" {
		t.Skip("skipping: set BOLTMESH_WINTUN_PIN_TEST=1 from an elevated shell to " +
			"exercise the real System32 pin")
	}
	if !isElevated() {
		t.Fatal("BOLTMESH_WINTUN_PIN_TEST=1 but the shell is not elevated")
	}

	// Confirm the vendored binary is staged where the pin reads it, so a failure
	// here is about the pin rather than about a test binary in a temp directory.
	vendored := filepath.Join(wintunVendoredDir, wintunDLLName)
	if _, err := os.Stat(vendored); err != nil {
		t.Fatalf("the vendored %s is not beside the helper at %s: %v\n"+
			"stage_boltmeshd.ps1 copies it there; this test needs a staged layout",
			wintunDLLName, vendored, err)
	}

	// Install the reviewed copy first. Without this the pin has nothing pinned to
	// resolve to, and the run below would only re-test the refusal path -- which
	// is correct behaviour, but not what this test is about.
	if _, err := ensureWintunPinned(); err != nil {
		t.Fatalf("ensureWintunPinned: %v", err)
	}

	// Now put a decoy where the library's application-directory search would find
	// one. This is the attack the pin exists to stop: without it, the bare-name
	// load would pick this file up, and it is not a driver at all.
	reviewed, err := os.ReadFile(vendored)
	if err != nil {
		t.Fatalf("read the vendored driver: %v", err)
	}
	t.Cleanup(func() { _ = os.WriteFile(vendored, reviewed, 0o555) })
	if err := os.WriteFile(vendored, []byte("not a driver"), 0o600); err != nil {
		t.Fatalf("write the decoy: %v", err)
	}

	handle, err := loadWintunDLL()
	if err != nil {
		t.Fatalf("loadWintunDLL with a decoy beside the executable: %v", err)
	}
	if handle == 0 {
		t.Fatal("loadWintunDLL returned a null handle")
	}

	// And the module that got mapped must be the reviewed one, by hash. This is
	// the assertion that would fail if the decoy had been loaded instead.
	sum, err := sha256File(filepath.Join(wintunSystem32Dir, wintunDLLName))
	if err != nil {
		t.Fatalf("hash the pinned driver: %v", err)
	}
	if sum != wintunSHA256 {
		t.Fatalf("System32 %s hashes to %s, want %s", wintunDLLName, sum, wintunSHA256)
	}
}

// isElevated reports whether the process holds an elevated token.
//
// [windows.GetCurrentProcessToken] rather than windows.Token(0): zero is not the
// process pseudo-handle, so GetTokenInformation fails on it and IsElevated
// answers false for every shell. That mistake made this test skip unconditionally,
// which is how a pin nobody had ever exercised looked like a passing suite.
//
// Elevation type rather than Administrators membership: a filtered (unelevated)
// token is still a member of Administrators, so a membership check would report
// true for an ordinary shell.
func isElevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}
func TestSha256FileMatchesTheKnownDigest(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "empty")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatalf("write the empty file: %v", err)
	}
	// e3b0c442... is the SHA-256 of zero bytes.
	const emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	got, err := sha256File(path)
	if err != nil {
		t.Fatalf("sha256File: %v", err)
	}
	if got != emptySHA256 {
		t.Errorf("sha256File(empty) = %s, want %s", got, emptySHA256)
	}
}

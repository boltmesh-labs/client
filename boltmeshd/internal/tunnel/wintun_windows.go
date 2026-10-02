//go:build windows

package tunnel

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// Wintun is the L3 TUN driver the AmneziaWG data plane needs on Windows: the
// WireGuard-for-Windows kernel service has no concept of the obfuscation
// directives, so an obfuscated tunnel runs a userspace device over a Wintun
// adapter instead. The binary is vendored (see third_party/wintun) because
// nothing embeds it.
//
// The problem this file exists to solve: golang.zx2c4.com/wintun resolves its DLL
// by bare name with LOAD_LIBRARY_SEARCH_APPLICATION_DIR|SYSTEM32, so a
// wintun.dll sitting beside boltmeshd.exe would satisfy the load. The daemon runs
// as LocalSystem, and its own directory is the one an attacker most wants write
// access to — so that is precisely the substitution that must not be possible.
// A substituted driver would own every packet the tunnel carries.
//
// So the DLL is copied to a hardened location and pinned to System32 before the
// library resolves it. The copy is verified by hash, so a file already sitting in
// the target directory cannot be trusted either.
const (
	wintunDLLName = "wintun.dll"

	// wintunSystem32Dir is where the pinned copy lives. System32 rather than a
	// BoltMesh-owned ProgramData directory: it is writable by neither the
	// service account nor an administrator's unelevated processes, and it is
	// already on the search path for every process on the machine.
	wintunSystem32Dir = `C:\Windows\System32`

	// wintunDLLMode is what the pinned copy is set to: readable and
	// executable by everyone, writable only by SYSTEM and Administrators. The
	// default inherited ACL on a file copied into System32 is already close to
	// this; it is set explicitly so the guarantee does not depend on the
	// directory's inheritance being what it is assumed to be.
	wintunDLLMode = 0o555
)

// wintunPinPaths returns the paths [ensureWintunPinned] reads and writes, and is
// the seam that lets a test exercise the refusal paths without elevation.
//
// The production values are System32 and the executable's own directory. A test
// substitutes a temp directory for both: the install logic, the hashing and the
// fail-closed behaviour are what is under test, and none of them care that the
// real target happens to need administrator rights to write.
func wintunPinPaths(target, source string) func() {
	prevDir, prevSrc := wintunDLLDir, wintunVendoredDir
	wintunDLLDir, wintunVendoredDir = target, source
	return func() { wintunDLLDir, wintunVendoredDir = prevDir, prevSrc }
}

// wintunSHA256 is the pinned copy's content hash, lower-case hex.
//
// A hash rather than a signature check because the vendored binary's certificate
// expired in 2021 and is kept valid only by a counter-signature: verifying that
// chain means trusting the timestamper's policy, which is a larger dependency
// than a build-time constant. The hash pins the exact bytes reviewed into the
// repository; `third_party/wintun/README.md` records the Authenticode details and
// the upstream archive hash for a human who wants to re-verify provenance.
const wintunSHA256 = "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce"

// wintunDLLDir and wintunVendoredDir are the two directories the pin reads from
// and writes to. Vars rather than constants so [wintunPinPaths] can redirect them
// at a temp directory; nothing else assigns them.
var (
	wintunDLLDir      = wintunSystem32Dir
	wintunVendoredDir string
)

func init() {
	// The vendored binary is copied beside the helper at build time (see
	// stage_boltmeshd.ps1), so it sits in the same directory as boltmeshd.exe.
	// Resolved through the executable rather than the working tree, so a
	// developer's edited checkout cannot change what ships.
	if exe, err := executableDir(); err == nil {
		wintunVendoredDir = exe
	}
}

// sha256File streams a file through SHA-256 and returns the lower-case hex
// digest. Used to verify the copy before it is trusted with SYSTEM's privileges.
func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() { _ = f.Close() }()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// copyBinary copies src to dst with no permission bits carried over, so the
// staged copy's mode is set by the caller and not inherited from the source.
// Deliberately not sharing tun_darwin.go's copyFile: that one preserves the mode,
// which is the opposite of what a hardened copy wants, and it is a darwin build
// tag either way.
func copyBinary(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer func() { _ = in.Close() }()

	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		_ = os.Remove(dst)
		return err
	}
	// Close before the caller renames: on Windows a rename over an open file
	// fails, so the descriptor has to be released first.
	return out.Close()
}

// ensureWintunPinned copies the vendored wintun.dll into System32 and returns the
// absolute path the library must be pointed at.
//
// Idempotent and cheap on the common path: an existing System32 copy whose
// content already hashes to the pinned value is left alone, so this costs one
// file read per obfuscated bring-up rather than a copy every time.
//
// Fails closed. A hash mismatch, an unwritable target, or a missing vendored
// source is an error rather than a fallback to the library's own search: the
// whole point is that the load is predictable, and "let the loader decide" is the
// behaviour being removed.
func ensureWintunPinned() (string, error) {
	target := filepath.Join(wintunDLLDir, wintunDLLName)

	// Fast path: already pinned. The hash is re-read rather than trusting the
	// file's presence, because presence is exactly what an attacker would forge.
	if sum, err := sha256File(target); err == nil && sum == wintunSHA256 {
		return target, nil
	}

	src := filepath.Join(wintunVendoredDir, wintunDLLName)
	sum, err := sha256File(src)
	if err != nil {
		return "", fmt.Errorf("vendored %s is unreadable at %s: %w", wintunDLLName, src, err)
	}
	if sum != wintunSHA256 {
		return "", fmt.Errorf(
			"vendored %s hashes to %s, want %s: the reviewed binary does not match the pin",
			wintunDLLName, sum, wintunSHA256)
	}

	// Copy through a temporary name and rename into place. A partial copy at the
	// real name would be found by the fast path on the next run and hashed as
	// wrong, so this is belt-and-braces rather than the primary defence — but it
	// also means a concurrent second bring-up never observes a half-written DLL.
	staging := target + ".bmstaging"
	if err := copyBinary(src, staging); err != nil {
		return "", fmt.Errorf("stage %s: %w", wintunDLLName, err)
	}
	if err := os.Chmod(staging, wintunDLLMode); err != nil {
		_ = os.Remove(staging)
		return "", fmt.Errorf("harden staged %s: %w", wintunDLLName, err)
	}
	if err := os.Rename(staging, target); err != nil {
		_ = os.Remove(staging)
		return "", fmt.Errorf("install %s into %s: %w", wintunDLLName, wintunDLLDir, err)
	}

	// Read back what actually landed rather than assuming the rename was the
	// whole story: a filesystem that silently truncated the copy would otherwise
	// leave a driver that fails much later, inside the tunnel.
	installed, err := sha256File(target)
	if err != nil {
		return "", fmt.Errorf("verify installed %s: %w", wintunDLLName, err)
	}
	if installed != wintunSHA256 {
		return "", fmt.Errorf(
			"installed %s hashes to %s, want %s", wintunDLLName, installed, wintunSHA256)
	}
	return target, nil
}

// loadWintunDLL loads the pinned wintun.dll by absolute path and returns the
// module handle. The handle is deliberately not released: it must stay mapped for
// the life of the process, because that is what makes the upstream library's own
// bare-name load resolve to these bytes rather than re-searching the disk.
//
// This exists because the upstream Go binding cannot be told where its DLL is: it
// resolves "wintun.dll" by name at first use. Loading it here first, by absolute
// path, puts a verified copy in the process under that name, so the library's own
// load resolves to the already-mapped module rather than searching the
// application directory for whatever is there.
//
// The alternative — reimplementing the tun adapter's ~200 lines of device and
// session management against the raw Wintun C API — would duplicate a maintained
// upstream for no gain. Pre-loading pins the bytes; it does not change what the
// library then calls.
func loadWintunDLL() (windows.Handle, error) {
	path, err := ensureWintunPinned()
	if err != nil {
		return 0, err
	}
	// Absolute path with the application directory excluded from the search: the
	// loader must never be able to satisfy this from beside the executable.
	handle, err := windows.LoadLibraryEx(
		path, 0, windows.LOAD_LIBRARY_SEARCH_SYSTEM32,
	)
	if err != nil {
		return 0, fmt.Errorf("load pinned %s: %w", path, err)
	}
	return handle, nil
}

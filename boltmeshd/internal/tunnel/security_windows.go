//go:build windows

package tunnel

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Well-known SIDs: LocalSystem (the daemon's own account) and the built-in
// Administrators group.
const (
	localSystemSID    = "S-1-5-18"
	administratorsSID = "S-1-5-32-544"
)

// configOwnerSID is the owner setConfigSecurity applies and verifyConfigSecurity
// requires. Assigning an owner other than the caller's own token SID needs
// SE_RESTORE_NAME, so it is a variable only so the Windows tests can retarget
// the assertion at the current user when the runner token lacks that privilege
// (a non-elevated CI runner, an unelevated shell). Production always runs
// boltmeshd as LocalSystem, where S-1-5-18 is a no-op assignment.
// TestConfigOwnerSIDIsLocalSystem pins the production value.
var configOwnerSID = localSystemSID

const (
	// Do not request DELETE while applying security to a path. Apart from
	// being unnecessary, it lets an already-open handle with a permissive
	// share mode turn a hardening operation into a replacement race.
	configSecurityAccess = windows.GENERIC_READ | windows.GENERIC_WRITE |
		windows.WRITE_DAC | windows.WRITE_OWNER | windows.READ_CONTROL
	configDirectoryShare = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE
	allPathShares        = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE
)

// protectConfigDir creates dir if necessary, rejects reparse points in its
// path, and makes the directory itself SYSTEM-owned with a protected DACL.
// The DACL is propagated to children so a newly-created config cannot inherit
// ProgramData's BUILTIN\Users access. The DACL alone is not sufficient: the
// owner must also be changed, otherwise the user who created a directory (or
// file) before installation can change it back later. If an existing object
// cannot be opened for a handle-based owner/DACL update, the operation fails
// closed rather than falling back to a pathname security update.
func protectConfigDir(dir string) error {
	if dir == "" {
		return errors.New("config directory is empty")
	}
	if !filepath.IsAbs(dir) {
		absolute, err := filepath.Abs(dir)
		if err != nil {
			return fmt.Errorf("resolve config directory %q: %w", dir, err)
		}
		dir = absolute
	}
	if err := ensureDirectory(dir); err != nil {
		return fmt.Errorf("create config directory: %w", err)
	}

	handle, err := openPathNoReparse(dir, configSecurityAccess, configDirectoryShare)
	if err != nil {
		return fmt.Errorf("open config directory %q: %w", dir, err)
	}
	defer func() { _ = windows.CloseHandle(handle) }()

	if err := requireDirectory(handle, dir); err != nil {
		return err
	}
	if err := setConfigSecurity(handle, windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT); err != nil {
		return fmt.Errorf("protect config directory %q: %w", dir, err)
	}
	if err := rejectReparseHandle(handle, dir); err != nil {
		return err
	}
	if err := verifyConfigSecurity(handle); err != nil {
		return fmt.Errorf("verify config directory %q: %w", dir, err)
	}
	return nil
}

// setConfigDACL is retained for package-level Windows callers that supplied
// an ACL explicitly. New code uses setConfigSecurity, which also changes the
// owner through a verified handle.
//
//nolint:unused // kept as a compatibility seam for Windows package tests.
func setConfigDACL(path string, acl *windows.ACL) error {
	owner, err := windows.StringToSid(localSystemSID)
	if err != nil {
		return fmt.Errorf("resolve SYSTEM SID: %w", err)
	}
	handle, err := openPathNoReparse(path, configSecurityAccess, configDirectoryShare)
	if err != nil {
		return fmt.Errorf("open %s: %w", path, err)
	}
	defer func() { _ = windows.CloseHandle(handle) }()
	if err := setConfigSecurityOnHandle(handle, owner, acl); err != nil {
		return fmt.Errorf("set security on %s: %w", path, err)
	}
	return nil
}

// setConfigSecurityOnHandle applies owner and DACL to an already-open object.
func setConfigSecurityOnHandle(handle windows.Handle, owner *windows.SID, acl *windows.ACL) error {
	restorePrivilege, err := enableRestorePrivilege()
	if err != nil {
		return fmt.Errorf("prepare the owner assignment: %w", err)
	}
	defer restorePrivilege()

	if err := windows.SetSecurityInfo(
		handle,
		windows.SE_FILE_OBJECT,
		windows.OWNER_SECURITY_INFORMATION|
			windows.DACL_SECURITY_INFORMATION|
			windows.PROTECTED_DACL_SECURITY_INFORMATION,
		owner,
		nil,
		acl,
		nil,
	); err != nil {
		return fmt.Errorf("set owner and DACL: %w", err)
	}
	return nil
}

// enableRestorePrivilege turns SE_RESTORE_NAME on for the process token and
// returns the function that puts it back. Assigning an owner other than the
// caller's own token SID requires that privilege, and the accounts that have a
// business reassigning ownership hold it disabled by default: LocalSystem, and
// the elevated administrator the Windows installer runs as. Without enabling
// it here, SetSecurityInfo rejects the SYSTEM owner with ERROR_INVALID_OWNER
// and protectConfigDir fails closed, so the installer could never harden the
// config directory it creates.
//
// A token that does not hold the privilege at all is left untouched: the
// privilege cannot be granted from inside the process, and letting
// SetSecurityInfo report ERROR_INVALID_OWNER keeps the failure attributable.
// The returned function is never nil and is safe to call when nothing changed.
func enableRestorePrivilege() (func(), error) {
	name, err := windows.UTF16PtrFromString("SeRestorePrivilege")
	if err != nil {
		return nil, fmt.Errorf("encode the privilege name: %w", err)
	}
	var luid windows.LUID
	if err := windows.LookupPrivilegeValue(nil, name, &luid); err != nil {
		return nil, fmt.Errorf("look up SE_RESTORE_NAME: %w", err)
	}

	token := windows.GetCurrentProcessToken()
	present, enabled, err := tokenPrivilegeState(token, luid)
	if err != nil {
		return nil, err
	}
	if !present || enabled {
		return func() {}, nil
	}
	if err := setPrivilegeEnabled(token, luid, true); err != nil {
		// ERROR_NOT_ALL_ASSIGNED means the token lists the privilege but
		// does not really hold it, so there is nothing to enable. Anything
		// else is a genuine failure to report.
		if !errors.Is(err, windows.ERROR_NOT_ALL_ASSIGNED) {
			return nil, fmt.Errorf("enable SE_RESTORE_NAME: %w", err)
		}
		return func() {}, nil
	}
	return func() { _ = setPrivilegeEnabled(token, luid, false) }, nil
}

// tokenPrivilegeState reports whether the token holds the privilege and whether
// it is currently enabled.
func tokenPrivilegeState(token windows.Token, luid windows.LUID) (present, enabled bool, err error) {
	var returned uint32
	// The first call exists only to fill in the required size.
	_ = windows.GetTokenInformation(token, windows.TokenPrivileges, nil, 0, &returned)
	if returned == 0 {
		return false, false, errors.New("process token reported an empty privilege set")
	}
	buffer := make([]byte, returned)
	if err := windows.GetTokenInformation(
		token, windows.TokenPrivileges, &buffer[0], uint32(len(buffer)), &returned,
	); err != nil {
		return false, false, fmt.Errorf("read the process token privileges: %w", err)
	}
	privileges := (*windows.Tokenprivileges)(unsafe.Pointer(&buffer[0])).AllPrivileges()
	for _, privilege := range privileges {
		if privilege.Luid == luid {
			return true, privilege.Attributes&windows.SE_PRIVILEGE_ENABLED != 0, nil
		}
	}
	return false, false, nil
}

// setPrivilegeEnabled enables or disables a single privilege. The privileges
// left out of state keep their current state because disableAllPrivileges is
// false, so this never disturbs a concurrent operation on another goroutine's
// token use.
func setPrivilegeEnabled(token windows.Token, luid windows.LUID, enable bool) error {
	attributes := uint32(0)
	if enable {
		attributes = windows.SE_PRIVILEGE_ENABLED
	}
	state := windows.Tokenprivileges{PrivilegeCount: 1}
	state.Privileges[0] = windows.LUIDAndAttributes{Luid: luid, Attributes: attributes}
	return windows.AdjustTokenPrivileges(token, false, &state, uint32(unsafe.Sizeof(state)), nil, nil)
}

// ProtectDir applies the same SYSTEM + Administrators owner and protected
// DACL to dir. It is exported so the persistent failure log can live in a
// directory beside the config without inheriting ProgramData's world-readable
// ACE.
func ProtectDir(dir string) error { return protectConfigDir(dir) }

// protectConfigFile applies the owner and DACL to an existing regular file
// without following a reparse point. The file is normally a freshly-created
// temporary file; the path-based API is kept small so the manager can inject
// a no-op in platform tests.
func protectConfigFile(path string) error {
	handle, err := openPathNoReparse(path, configSecurityAccess, configDirectoryShare)
	if err != nil {
		return fmt.Errorf("open config file %q: %w", path, err)
	}
	defer func() { _ = windows.CloseHandle(handle) }()

	if err := requireRegularFile(handle, path); err != nil {
		return err
	}
	if err := setConfigSecurity(handle, windows.NO_INHERITANCE); err != nil {
		return fmt.Errorf("protect config file %q: %w", path, err)
	}
	if err := rejectReparseHandle(handle, path); err != nil {
		return err
	}
	if err := verifyConfigSecurity(handle); err != nil {
		return fmt.Errorf("verify config file %q: %w", path, err)
	}
	return nil
}

// configACL builds the SYSTEM + Administrators DACL. inheritance is
// windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT for a directory and
// windows.NO_INHERITANCE for a file.
func configACL(inheritance uint32) (*windows.ACL, error) {
	system, err := windows.StringToSid(localSystemSID)
	if err != nil {
		return nil, fmt.Errorf("resolve SYSTEM SID: %w", err)
	}
	admins, err := windows.StringToSid(administratorsSID)
	if err != nil {
		return nil, fmt.Errorf("resolve Administrators SID: %w", err)
	}

	entries := []windows.EXPLICIT_ACCESS{
		{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.GRANT_ACCESS,
			Inheritance:       inheritance,
			Trustee: windows.TRUSTEE{
				TrusteeForm:  windows.TRUSTEE_IS_SID,
				TrusteeType:  windows.TRUSTEE_IS_USER,
				TrusteeValue: windows.TrusteeValueFromSID(system),
			},
		},
		{
			AccessPermissions: windows.GENERIC_ALL,
			AccessMode:        windows.GRANT_ACCESS,
			Inheritance:       inheritance,
			Trustee: windows.TRUSTEE{
				TrusteeForm:  windows.TRUSTEE_IS_SID,
				TrusteeType:  windows.TRUSTEE_IS_GROUP,
				TrusteeValue: windows.TrusteeValueFromSID(admins),
			},
		},
	}

	acl, err := windows.ACLFromEntries(entries, nil)
	if err != nil {
		return nil, fmt.Errorf("build config ACL: %w", err)
	}
	return acl, nil
}

// setConfigSecurity changes both pieces of state that an untrusted creator can
// otherwise retain: the owner and the protected DACL. Applying them through a
// handle also means a path swap cannot redirect the operation to another
// object between the open and the security update.
func setConfigSecurity(handle windows.Handle, inheritance uint32) error {
	owner, err := windows.StringToSid(configOwnerSID)
	if err != nil {
		return fmt.Errorf("resolve SYSTEM SID: %w", err)
	}
	acl, err := configACL(inheritance)
	if err != nil {
		return err
	}
	return setConfigSecurityOnHandle(handle, owner, acl)
}

// verifyConfigSecurity makes a successful SetSecurityInfo call meaningful. In
// particular, an inherited or third-party ACE would reintroduce the original
// ProgramData disclosure even if the API reported success.
func verifyConfigSecurity(handle windows.Handle) error {
	sd, err := windows.GetSecurityInfo(
		handle,
		windows.SE_FILE_OBJECT,
		windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION,
	)
	if err != nil {
		return fmt.Errorf("read security descriptor: %w", err)
	}

	owner, _, err := sd.Owner()
	if err != nil {
		return fmt.Errorf("read owner: %w", err)
	}
	system, err := windows.StringToSid(configOwnerSID)
	if err != nil {
		return fmt.Errorf("resolve SYSTEM SID: %w", err)
	}
	if owner == nil || !owner.Equals(system) {
		ownerSID := "<nil>"
		if owner != nil {
			ownerSID = owner.String()
		}
		return fmt.Errorf("owner is %s, want %s", ownerSID, configOwnerSID)
	}

	control, _, err := sd.Control()
	if err != nil {
		return fmt.Errorf("read DACL control: %w", err)
	}
	if control&windows.SE_DACL_PROTECTED == 0 {
		return errors.New("DACL is inheritable; expected a protected DACL")
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return fmt.Errorf("read DACL: %w", err)
	}
	if dacl == nil || dacl.AceCount == 0 {
		return errors.New("DACL is empty")
	}

	admins, err := windows.StringToSid(administratorsSID)
	if err != nil {
		return fmt.Errorf("resolve Administrators SID: %w", err)
	}
	seenSystem, seenAdmins := false, false
	for i := uint32(0); i < uint32(dacl.AceCount); i++ {
		var ace *windows.ACCESS_ALLOWED_ACE
		if err := windows.GetAce(dacl, i, &ace); err != nil {
			return fmt.Errorf("read DACL ACE %d: %w", i, err)
		}
		if ace.Header.AceType != windows.ACCESS_ALLOWED_ACE_TYPE {
			return fmt.Errorf("DACL ACE %d is not an allow ACE", i)
		}
		if ace.Header.AceFlags&windows.INHERITED_ACE != 0 {
			return fmt.Errorf("DACL ACE %d is inherited", i)
		}
		sid := (*windows.SID)(unsafe.Pointer(&ace.SidStart))
		switch {
		case sid.Equals(system):
			seenSystem = true
		case sid.Equals(admins):
			seenAdmins = true
		default:
			return fmt.Errorf("DACL contains unexpected SID %s", sid.String())
		}
	}
	if !seenSystem || !seenAdmins {
		return errors.New("DACL does not contain both SYSTEM and Administrators")
	}
	return nil
}

// ensureDirectory creates each missing component separately and inspects
// every existing component with FILE_FLAG_OPEN_REPARSE_POINT. os.MkdirAll is
// intentionally not used here: it can traverse a junction created by a user
// before the elevated installer gets a chance to harden the final directory.
func ensureDirectory(path string) error {
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return fmt.Errorf("resolve directory path %q: %w", path, err)
		}
		path = filepath.Clean(absolute)
	}

	parent := filepath.Dir(path)
	if parent != path {
		if err := ensureDirectory(parent); err != nil {
			return err
		}
	}

	handle, err := openPathNoReparse(path, 0, allPathShares)
	if err == nil {
		defer func() { _ = windows.CloseHandle(handle) }()
		return requireDirectory(handle, path)
	}
	if !isMissingPathError(err) {
		return fmt.Errorf("inspect directory %q: %w", path, err)
	}

	if mkdirErr := os.Mkdir(path, 0o700); mkdirErr != nil && !isAlreadyExistsError(mkdirErr) {
		return fmt.Errorf("create directory %q: %w", path, mkdirErr)
	}
	handle, err = openPathNoReparse(path, 0, allPathShares)
	if err != nil {
		return fmt.Errorf("inspect created directory %q: %w", path, err)
	}
	defer func() { _ = windows.CloseHandle(handle) }()
	return requireDirectory(handle, path)
}

func openPathNoReparse(path string, access, share uint32) (windows.Handle, error) {
	pathp, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	handle, err := windows.CreateFile(
		pathp,
		access,
		share,
		nil,
		windows.OPEN_EXISTING,
		windows.FILE_FLAG_OPEN_REPARSE_POINT|windows.FILE_FLAG_BACKUP_SEMANTICS,
		0,
	)
	if err != nil {
		return 0, err
	}
	if err := rejectReparseHandle(handle, path); err != nil {
		_ = windows.CloseHandle(handle)
		return 0, err
	}
	return handle, nil
}

func rejectReparseHandle(handle windows.Handle, path string) error {
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		return fmt.Errorf("read attributes for %q: %w", path, err)
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return fmt.Errorf("%q is a reparse point", path)
	}
	return nil
}

func requireDirectory(handle windows.Handle, path string) error {
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		return fmt.Errorf("read directory attributes for %q: %w", path, err)
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_DEVICE != 0 {
		return fmt.Errorf("%q is a device", path)
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return fmt.Errorf("%q is not a directory", path)
	}
	return nil
}

func requireRegularFile(handle windows.Handle, path string) error {
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(handle, &info); err != nil {
		return fmt.Errorf("read file attributes for %q: %w", path, err)
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_DEVICE != 0 {
		return fmt.Errorf("%q is a device, not a file", path)
	}
	if info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0 {
		return fmt.Errorf("%q is a directory, not a file", path)
	}
	return nil
}

func isMissingPathError(err error) bool {
	return errors.Is(err, windows.ERROR_FILE_NOT_FOUND) || errors.Is(err, windows.ERROR_PATH_NOT_FOUND)
}

func isAlreadyExistsError(err error) bool {
	return errors.Is(err, windows.ERROR_ALREADY_EXISTS) || errors.Is(err, windows.ERROR_FILE_EXISTS)
}

// rejectReparseFile checks an optional destination without following a link.
// A missing destination is fine; a directory or reparse point is not. If the
// destination denies metadata access, it is deliberately not opened: the
// subsequent MoveFileEx operates on the directory entry and must not turn a
// user-created deny ACE into a denial of service. MoveFileEx never writes
// through a destination reparse point, so an uninspectable entry is safe to
// replace.
func rejectReparseFile(path string) error {
	// A zero desired access is intentional: Windows can inspect attributes for
	// an existing object even when a deny ACE blocks SYSTEM's read access.
	handle, err := openPathNoReparse(path, 0, allPathShares)
	if err == nil {
		defer func() { _ = windows.CloseHandle(handle) }()
		return requireRegularFile(handle, path)
	}
	if isMissingPathError(err) {
		return nil
	}
	if !errors.Is(err, windows.ERROR_ACCESS_DENIED) {
		return fmt.Errorf("inspect destination %q: %w", path, err)
	}

	// A deny ACE on a pre-created destination must not make the privileged
	// writer depend on access to that object. GetFileAttributes is only a
	// best-effort reparse check here; MoveFileEx still replaces the directory
	// entry itself, never the target of a link.
	pathp, pathErr := windows.UTF16PtrFromString(path)
	if pathErr != nil {
		return pathErr
	}
	attrs, attrErr := windows.GetFileAttributes(pathp)
	if attrErr != nil {
		if isMissingPathError(attrErr) || errors.Is(attrErr, windows.ERROR_ACCESS_DENIED) {
			return nil
		}
		return fmt.Errorf("inspect destination %q: %w", path, attrErr)
	}
	if attrs&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return fmt.Errorf("%q is a reparse point", path)
	}
	if attrs&windows.FILE_ATTRIBUTE_DEVICE != 0 {
		return fmt.Errorf("%q is a device, not a file", path)
	}
	if attrs&windows.FILE_ATTRIBUTE_DIRECTORY != 0 {
		return fmt.Errorf("%q is a directory, not a file", path)
	}
	return nil
}

// writePrivateFile writes data to a newly-created exclusive temporary file,
// applies the private owner/DACL before the first write, and only then
// atomically replaces path. The source is never opened or truncated through a
// pre-existing destination, so an old read handle cannot observe the new
// secret. A failed operation removes the temporary file.
func writePrivateFile(path string, data []byte, protect func(string) error) error {
	if path == "" {
		return errors.New("destination path is empty")
	}
	path = filepath.Clean(path)
	dir := filepath.Dir(path)
	if err := ensureDirectory(dir); err != nil {
		return fmt.Errorf("verify parent directory: %w", err)
	}
	// Keep a no-delete-share handle on the parent for the whole staging and
	// replacement operation. Once the directory has been secured, this also
	// prevents a path swap from redirecting the temporary-file operations.
	dirHandle, err := openPathNoReparse(dir, windows.FILE_READ_ATTRIBUTES, configDirectoryShare)
	if err != nil {
		return fmt.Errorf("open parent directory: %w", err)
	}
	parentClosed := false
	closeParent := func() {
		if !parentClosed {
			_ = windows.CloseHandle(dirHandle)
			parentClosed = true
		}
	}
	defer closeParent()
	if err := requireDirectory(dirHandle, dir); err != nil {
		return err
	}
	if err := rejectReparseFile(path); err != nil {
		return err
	}

	// os.CreateTemp opens with O_CREATE|O_EXCL (CREATE_NEW on Windows), so a
	// pre-created name or reparse entry can never be opened and truncated.
	temp, err := os.CreateTemp(dir, ".boltmeshd-*.tmp")
	if err != nil {
		return fmt.Errorf("create temporary file: %w", err)
	}
	tempPath := temp.Name()
	committed := false
	defer func() {
		_ = temp.Close()
		closeParent()
		if !committed {
			_ = os.Remove(tempPath)
		}
	}()

	if protect == nil {
		protect = protectConfigFile
	}
	if err := protect(tempPath); err != nil {
		return fmt.Errorf("protect temporary file: %w", err)
	}
	if _, err := temp.Write(data); err != nil {
		return fmt.Errorf("write temporary file: %w", err)
	}
	if err := temp.Sync(); err != nil {
		return fmt.Errorf("sync temporary file: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("close temporary file: %w", err)
	}

	// Re-check both directory entries immediately before replacement. This
	// closes the common installer/startup race where another process creates a
	// reparse point after the first inspection.
	if err := rejectReparseFile(tempPath); err != nil {
		return fmt.Errorf("inspect temporary file: %w", err)
	}
	if err := rejectReparseFile(path); err != nil {
		return err
	}
	from, err := windows.UTF16PtrFromString(tempPath)
	if err != nil {
		return err
	}
	to, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	// REPLACE_EXISTING performs the old-entry cleanup as part of the same
	// directory operation. There is no remove/truncate window in which a
	// pre-existing object can be mistaken for the new config.
	if err := windows.MoveFileEx(
		from,
		to,
		windows.MOVEFILE_REPLACE_EXISTING|windows.MOVEFILE_WRITE_THROUGH,
	); err != nil {
		return fmt.Errorf("replace destination %q: %w", path, err)
	}
	committed = true
	return nil
}

// SecureLogFile prepares a fresh, private active log file. The logging
// package subsequently opens this already-hardened path with append mode; it
// never gets to follow a pre-existing file or reparse point. A fresh file is
// intentional: a pre-created log can have an owner-controlled DACL or an open
// read handle, neither of which can safely be repaired in place.
func SecureLogFile(path string) error {
	if path == "" {
		return nil
	}
	if !filepath.IsAbs(path) {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return fmt.Errorf("resolve log file path %q: %w", path, err)
		}
		path = absolute
	}
	if err := protectConfigDir(filepath.Dir(path)); err != nil {
		return fmt.Errorf("protect log directory: %w", err)
	}
	if err := writePrivateFile(path, nil, protectConfigFile); err != nil {
		return fmt.Errorf("create private log file: %w", err)
	}
	return nil
}

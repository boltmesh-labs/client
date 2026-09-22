//go:build windows

package tunnel

import (
	"fmt"

	"golang.org/x/sys/windows"
)

// Well-known SIDs: LocalSystem (the daemon's own account) and the built-in
// Administrators group.
const (
	localSystemSID    = "S-1-5-18"
	administratorsSID = "S-1-5-32-544"
)

// protectConfigDir tightens the DACL on dir to SYSTEM and Administrators only,
// propagating the ACEs to child files (the wg-quick config). os.Chmod is a
// no-op protection on Windows, so without this the privileged config — which
// carries the WireGuard private key — inherits ProgramData's default ACE for
// BUILTIN\Users and is readable by every local user.
//
// The DACL is protected (PROTECTED_DACL_SECURITY_INFORMATION), so inheritance
// from C:\ProgramData cannot widen it.
func protectConfigDir(dir string) error {
	acl, err := configACL(windows.SUB_CONTAINERS_AND_OBJECTS_INHERIT)
	if err != nil {
		return err
	}
	return setConfigDACL(dir, acl)
}

// ProtectDir applies the same SYSTEM + Administrators protected DACL to dir.
// Exported so the persistent failure log can live in a directory beside the
// config without inheriting ProgramData's world-readable ACE.
func ProtectDir(dir string) error { return protectConfigDir(dir) }

// protectConfigFile applies the same ACEs to an existing config file without
// inheritance, so a file left with a loose DACL by an older build is tightened
// on the next write.
func protectConfigFile(path string) error {
	acl, err := configACL(windows.NO_INHERITANCE)
	if err != nil {
		return err
	}
	return setConfigDACL(path, acl)
}

func setConfigDACL(path string, acl *windows.ACL) error {
	if err := windows.SetNamedSecurityInfo(
		path,
		windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION,
		nil,
		nil,
		acl,
		nil,
	); err != nil {
		return fmt.Errorf("set DACL on %s: %w", path, err)
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

//go:build windows

// The per-interface network configuration the userspace AmneziaWG data plane
// needs on Windows: an address on the Wintun adapter, and the DNS servers the
// tunnel resolves through.
//
// None of the entry points involved are bound by x/sys/windows, so they are bound
// by hand here against the same absolute-path System32 iphlpapi load
// routes_windows.go uses. That is the reason for binding at all rather than
// shelling out to netsh or PowerShell: the daemon runs as LocalSystem, and handing
// a network-configuration step to a tool resolved by name would put a search path
// in front of it.
//
// Every constant and offset below was read out of the Windows SDK headers on the
// target platform (MSVC 14.51, SDK 10.0.26100.0) rather than transcribed from
// documentation. DNS_INTERFACE_SETTINGS in particular has no Go equivalent anywhere,
// so a member at the wrong offset writes into the wrong field;
// netif_windows_binding_test.go pins the layout against those readings.
//
// The teardown needs almost nothing from here, and that is not an oversight. An
// address, the routes on an interface, and its DNS servers are all properties of the
// adapter, and closing the Wintun handle deletes the adapter along with all three —
// so this file is deliberately only what a bring-up needs, and the obfuscated
// teardown leans on the adapter's removal rather than unwinding each piece. The one
// thing that does not die with the adapter is the endpoint's underlay host route,
// which lives on the physical interface and is swept through routes_windows.go.
package tunnel

import (
	"fmt"
	"net"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	procCreateUnicastAddr = iphlpapi.NewProc("CreateUnicastIpAddressEntry")
	procSetInterfaceDNS   = iphlpapi.NewProc("SetInterfaceDnsSettings")
)

// Unicast address row constants.
//
// The NL_PREFIX_ORIGIN and NL_SUFFIX_ORIGIN enumerations are declared in nldef.h,
// which no user-mode header includes, so an application cannot name their members.
// These are the values from there, which is how an address configured by hand rather
// than by DHCP presents itself to GetUnicastIpAddressEntry afterwards.
//
// Both enumerations open with an "other" member, so Manual is 1 in each -- not 2, which
// is WellKnown for a prefix and Dhcp for a suffix. A row that carried 2 would be
// accepted and would describe the tunnel address as somebody else's.
const (
	ipOriginManual       = 1
	ipSuffixOriginManual = 1
	// infiniteLifetime is what the entry point expects for a prefix that must not
	// age out: unsigned 0xFFFFFFFF, i.e. ULONG(-1).
	infiniteLifetime = 0xFFFFFFFF

	// ipDadStatePreferred asks the stack to treat the address as usable immediately
	// and to do optimistic duplicate-address detection, instead of leaving it tentative
	// until the probe completes.
	//
	// That is not an optimisation here, it is the only way the address works. The
	// tunnel runs on a Wintun adapter, which is point-to-point L3: nothing answers the
	// probe, so ordinary duplicate address detection never completes and the address
	// settles on a failed DAD state, which the stack treats as unusable. A tunnel that
	// came up and then routed nowhere is the symptom, and it is indistinguishable from a
	// broken tunnel until somebody reads DadState.
	ipDadStatePreferred = 1
)

// dnsInterfaceSettings is MIB's DNS_INTERFACE_SETTINGS.
//
// Offsets as the SDK declares them, verified on the target platform:
//
//	Version             @  0   ULONG      DNS_INTERFACE_SETTINGS_VERSION1
//	(pad)               @  4
//	Flags               @  8   ULONG64    DNS_SETTING_*
//	Domain              @ 16   PWSTR
//	NameServer          @ 24   PWSTR
//	SearchList          @ 32   PWSTR
//	RegistrationEnabled @ 40   ULONG
//	RegisterAdapterName @ 44   ULONG
//	EnableLLMNR         @ 48   ULONG
//	QueryAdapterName    @ 52   ULONG
//	ProfileNameServer   @ 56   PWSTR      total 64
//
// The padding is written out rather than left to the compiler. Go would insert the
// same four bytes on amd64, but "Go happens to pad this identically" is not a
// property a reader should have to infer, and Flags landing at 4 instead of 8 would
// corrupt every member after it while still looking like a plausible struct.
//
// The PWSTR members are unsafe.Pointer rather than uintptr so the memory they name
// stays reachable for the duration of the call. A uintptr field is invisible to the
// collector, so the wide string could be collected while the kernel is still reading
// it — a failure that surfaces as a garbled resolver list on somebody else's
// machine, and only sometimes.
type dnsInterfaceSettings struct {
	Version             uint32
	_                   uint32
	Flags               uint64
	Domain              unsafe.Pointer
	NameServer          unsafe.Pointer
	SearchList          unsafe.Pointer
	RegistrationEnabled uint32
	RegisterAdapterName uint32
	EnableLLMNR         uint32
	QueryAdapterName    uint32
	ProfileNameServer   unsafe.Pointer
}

// DNS_INTERFACE_SETTINGS flags. Only the two this daemon sets are listed: the entry
// point requires every unflagged member to be zeroed, so a struct naming more of
// them would be describing settings nobody asked for.
const (
	dnsInterfaceSettingsVersion1 = 1
	dnsSettingNameServer         = 0x0002
	dnsSettingIPV6               = 0x0001
)

// mibIfEntry2 is the GetIfEntry2Ex level that fills a MIB_IF_ROW2.
const mibIfEntry2 = 2

// windowsNetIf is the seam the obfuscated bring-up drives. Tests substitute a
// recorder, so the ordering guarantees — the endpoint pinned before the address
// exists, the address before the routes that need it — are checkable without
// touching this machine's configuration.
type windowsNetIf interface {
	// interfaceGUID resolves a LUID to the GUID that SetInterfaceDnsSettings
	// requires. Both names are needed and neither is derivable from the other: the
	// forward and address entry points take the LUID, the DNS entry point takes only
	// the GUID, and converting between them needs a lookup. So it is resolved once, at
	// bring-up, rather than rediscovered per call.
	interfaceGUID(luid uint64) (windows.GUID, error)
	// addAddress puts an address/prefix on the interface named by luid.
	addAddress(luid uint64, ip net.IP, bits uint8) error
	// setDNS points the interface at these resolvers, replacing whatever it had.
	setDNS(guid windows.GUID, servers []net.IP) error
}

// liveWindowsNetIf configures this machine's real interfaces.
type liveWindowsNetIf struct{}

// interfaceGUID reads the adapter's GUID from its LUID. A LUID no adapter answers to
// is an error rather than a zero-valued GUID, because every address and route installed
// afterwards would then be addressed to interface 0.
func (liveWindowsNetIf) interfaceGUID(luid uint64) (windows.GUID, error) {
	var row windows.MibIfRow2
	row.InterfaceLuid = luid
	if err := windows.GetIfEntry2Ex(mibIfEntry2, &row); err != nil {
		return windows.GUID{}, fmt.Errorf("look up interface %d: %w", luid, err)
	}
	return row.InterfaceGuid, nil
}

// addAddress installs the tunnel's own address on the Wintun adapter.
//
// The row is marked manual with an infinite lifetime because the tunnel address is
// not one anything else should expire: it is removed by deleting the adapter, not
// by a lease running out.
//
// An address that already exists is an error, not a success. The bring-up tears the
// previous tunnel down first, and that teardown closes the adapter — which is what
// takes its addresses with it — so an entry already present means the adapter
// outlived the teardown meant to remove it. That is worth surfacing rather than
// swallowing: Windows reports this condition as ERROR_OBJECT_ALREADY_EXISTS (1839)
// while x/sys's identically named constant is a different value (183), so there is
// no honest way to recognize it here without guessing, and a guess that silently
// matches the wrong code is how a real fault becomes an invisible one.
func (liveWindowsNetIf) addAddress(luid uint64, ip net.IP, bits uint8) error {
	sa, err := rawInetUnion(ip)
	if err != nil {
		return err
	}
	row := windows.MibUnicastIpAddressRow{
		Address:            sa,
		InterfaceLuid:      luid,
		PrefixOrigin:       ipOriginManual,
		SuffixOrigin:       ipSuffixOriginManual,
		ValidLifetime:      infiniteLifetime,
		PreferredLifetime:  infiniteLifetime,
		OnLinkPrefixLength: bits,
		DadState:           ipDadStatePreferred,
	}
	if ret := callCreateUnicastAddr(newUnicastAddrCall(&row)); ret != 0 {
		return fmt.Errorf("assign %s/%d to interface %d: %w",
			ip, bits, luid, routeError(windows.NTStatus(ret)))
	}
	return nil
}

// rawInetUnion renders an address as the union MIB_UNICASTIPADDRESS_ROW.Address holds.
//
// The row names SOCKADDR_INET, and x/sys represents that with RawSockaddrInet6 — the
// IPv6 arm's layout. That is right for an IPv6 address and wrong for an IPv4 one,
// because SOCKADDR_INET is a *union*: the IPv4 arm's four address bytes sit at offset 4,
// where the IPv6 arm uses its flowinfo field, while the IPv6 arm's sixteen start at 8.
// Filling the union's Addr field with an IPv4 address therefore lands it four bytes past
// where the stack reads it, and the entry point answers ERROR_INVALID_PARAMETER — with
// a row that is otherwise entirely valid.
//
// Re-viewing the union [rawInet] already builds is the fix: it fills the IPv4 arm at the
// offset the IPv4 arm actually occupies, and the two representations are the same 28
// bytes of storage.
func rawInetUnion(ip net.IP) (windows.RawSockaddrInet6, error) {
	sa, _, err := rawInet(ip)
	if err != nil {
		return windows.RawSockaddrInet6{}, err
	}
	return *(*windows.RawSockaddrInet6)(unsafe.Pointer(&sa)), nil
}

// setDNS points the adapter at the tunnel's resolvers.
//
// The entry point applies to one stack per call: DNS_SETTING_IPV6 selects IPv6, and
// every server named in that call must belong to the selected family. A mixed list
// therefore becomes one call per family rather than a single call that would be
// rejected — the same split any resolver-aware client has to make.
func (liveWindowsNetIf) setDNS(guid windows.GUID, servers []net.IP) error {
	var v4, v6 []net.IP
	for _, ip := range servers {
		switch {
		case ip.To4() != nil:
			v4 = append(v4, ip)
		case ip.To16() != nil:
			v6 = append(v6, ip)
		default:
			return fmt.Errorf("not an IP address: %v", ip)
		}
	}
	for _, group := range []struct {
		servers []net.IP
		ipv6    bool
	}{{v4, false}, {v6, true}} {
		if len(group.servers) == 0 {
			continue
		}
		if err := applyDNSServers(guid, group.servers, group.ipv6); err != nil {
			return err
		}
	}
	return nil
}

// applyDNSServers performs one per-stack DNS write.
func applyDNSServers(guid windows.GUID, servers []net.IP, ipv6 bool) error {
	flags := uint64(dnsSettingNameServer)
	if ipv6 {
		flags |= dnsSettingIPV6
	}
	// Settings is a pointer parameter, so the only lifetime question is NameServer's
	// buffer, which settings holds as an unsafe.Pointer and therefore keeps alive.
	wide, err := windows.UTF16PtrFromString(dnsServerString(servers))
	if err != nil {
		return err
	}
	settings := dnsInterfaceSettings{
		Version:    dnsInterfaceSettingsVersion1,
		Flags:      flags,
		NameServer: unsafe.Pointer(wide),
	}
	call := newDnsSettingsCall(&guid, &settings)
	if ret := callSetInterfaceDNS(call); ret != 0 {
		return fmt.Errorf("set DNS servers %q on adapter %s: %w",
			dnsServerString(servers), guid.String(), routeError(windows.NTStatus(ret)))
	}
	return nil
}

// dnsServerString renders the resolvers as the comma-separated list the entry point
// reads. Every token has already been through net.IP's own parser, so the rendered
// form cannot carry a separator into the list.
func dnsServerString(servers []net.IP) string {
	parts := make([]string, 0, len(servers))
	for _, ip := range servers {
		parts = append(parts, ip.String())
	}
	return strings.Join(parts, ",")
}

// unicastAddrCall is one CreateUnicastIpAddressEntry invocation: the variadic
// argument list as the kernel sees it, plus the typed buffer that slot points at.
//
// Both are carried for the reason bestRoute2Call carries both. Reading a pointer back
// out of a []uintptr would mean converting a uintptr to a pointer, which govet
// rejects because a uintptr carries no provenance — so the argument list can only be
// asserted if the typed buffer travels alongside it.
type unicastAddrCall struct {
	args []uintptr
	row  *windows.MibUnicastIpAddressRow
}

// newUnicastAddrCall builds the single-argument list the address entry point takes:
//
//	MIB_UNICASTIPADDRESS_ROW* (populated by the caller, read by the kernel)
func newUnicastAddrCall(row *windows.MibUnicastIpAddressRow) unicastAddrCall {
	return unicastAddrCall{
		args: []uintptr{uintptr(unsafe.Pointer(row))},
		row:  row,
	}
}

// callCreateUnicastAddr is the seam over the bound entry point, so a test can assert
// the argument list without loading iphlpapi.
var callCreateUnicastAddr = func(call unicastAddrCall) uintptr {
	ret, _, _ := procCreateUnicastAddr.Call(call.args...)
	return ret
}

// dnsSettingsCall is one SetInterfaceDnsSettings invocation.
//
// The argument count here was read off MSVC's generated assembly rather than reasoned
// about, because the declaration is the kind that invites a wrong count. The SDK
// declares the interface as a GUID *by value*, and on x64 a 16-byte argument arrives
// in a register holding a pointer to the caller's own copy — which makes this a
// TWO-argument call (the GUID's address, then the settings pointer), not the
// three-argument shape a by-value 16-byte POD is usually assumed to take.
//
// Guessing wrong is neither a compile error nor a wrong value in the settings struct.
// The settings pointer simply lands in a register the kernel is not reading, so the
// call faults on a garbage address — from a privileged daemon, on a user's machine.
type dnsSettingsCall struct {
	args     []uintptr
	guid     *windows.GUID
	settings *dnsInterfaceSettings
}

// newDnsSettingsCall builds the argument list in the order the entry point declares
// its parameters:
//
//	GUID Interface (16 bytes, passed by reference), DNS_INTERFACE_SETTINGS* Settings
func newDnsSettingsCall(guid *windows.GUID, settings *dnsInterfaceSettings) dnsSettingsCall {
	return dnsSettingsCall{
		args: []uintptr{
			uintptr(unsafe.Pointer(guid)),
			uintptr(unsafe.Pointer(settings)),
		},
		guid:     guid,
		settings: settings,
	}
}

var callSetInterfaceDNS = func(call dnsSettingsCall) uintptr {
	ret, _, _ := procSetInterfaceDNS.Call(call.args...)
	return ret
}

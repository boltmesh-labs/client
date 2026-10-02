//go:build windows

package tunnel

import (
	"net"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The IP Helper entry points used by the obfuscated data plane are bound by hand, so
// nothing in the type system checks their signatures. The calls are variadic, which
// makes a wrong argument count or order invisible to the compiler and reaches the kernel
// as garbage.
//
// This is not hypothetical. GetBestRoute2 takes seven parameters, and binding three of
// them with the destination first made the kernel read an address as a NET_LUID, so
// every real bring-up failed with a status no message table could name. The transport
// suite could not see it either, because those tests drive the windowsRoutes seam and
// the binding lives behind it.
//
// So the unit under test here is the argument *list*, not a typed helper wrapping the
// call: a typed helper would let a test assert "the right pointers reached the helper"
// and stay green while the list inside it was still wrong.
//
// Every expectation below was read off the Windows SDK headers and MSVC's generated
// assembly on the target platform (MSVC 14.51, SDK 10.0.26100.0), not taken from
// documentation prose.

// Parameter slots for SetInterfaceDnsSettings, per its declaration:
//
//	GUID Interface (16 bytes, by reference), DNS_INTERFACE_SETTINGS* Settings
const (
	argSlotDNSInterface = 0
	argSlotDNSSettings  = 1
	dnsSettingsArgs     = 2
)

// TestDnsSettingsStructLayout pins DNS_INTERFACE_SETTINGS against the SDK's offsets.
//
// There is no Go equivalent of this structure anywhere, so every member is placed by
// hand. A member one slot out writes into a neighbour that is also plausible — Flags at
// 4 instead of 8 lands on the padding and silently drops every DNS_SETTING_* bit,
// which shows up as a tunnel that routes but never resolves.
func TestDnsSettingsStructLayout(t *testing.T) {
	offsets := map[string]uintptr{
		"Version":             0,
		"Flags":               8,
		"Domain":              16,
		"NameServer":          24,
		"SearchList":          32,
		"RegistrationEnabled": 40,
		"RegisterAdapterName": 44,
		"EnableLLMNR":         48,
		"QueryAdapterName":    52,
		"ProfileNameServer":   56,
	}
	var s dnsInterfaceSettings
	got := map[string]uintptr{
		"Version":             unsafe.Offsetof(s.Version),
		"Flags":               unsafe.Offsetof(s.Flags),
		"Domain":              unsafe.Offsetof(s.Domain),
		"NameServer":          unsafe.Offsetof(s.NameServer),
		"SearchList":          unsafe.Offsetof(s.SearchList),
		"RegistrationEnabled": unsafe.Offsetof(s.RegistrationEnabled),
		"RegisterAdapterName": unsafe.Offsetof(s.RegisterAdapterName),
		"EnableLLMNR":         unsafe.Offsetof(s.EnableLLMNR),
		"QueryAdapterName":    unsafe.Offsetof(s.QueryAdapterName),
		"ProfileNameServer":   unsafe.Offsetof(s.ProfileNameServer),
	}
	for name, want := range offsets {
		if got[name] != want {
			t.Errorf("DNS_INTERFACE_SETTINGS.%s offset = %d, want %d", name, got[name], want)
		}
	}
	if size := unsafe.Sizeof(s); size != 64 {
		t.Errorf("sizeof(DNS_INTERFACE_SETTINGS) = %d, want 64", size)
	}
}

// TestDnsSettingsVersionAndFlags pins the values the entry point branches on. Version 1
// is what selects the DNS_INTERFACE_SETTINGS layout at all; a zero here is rejected, and
// a Flags value missing DNS_SETTING_NAMESERVER applies the struct and nothing in it.
func TestDnsSettingsVersionAndFlags(t *testing.T) {
	if dnsInterfaceSettingsVersion1 != 1 {
		t.Errorf("DNS_INTERFACE_SETTINGS_VERSION1 = %d, want 1", dnsInterfaceSettingsVersion1)
	}
	if dnsSettingNameServer != 0x0002 {
		t.Errorf("DNS_SETTING_NAMESERVER = %#x, want 0x0002", dnsSettingNameServer)
	}
	if dnsSettingIPV6 != 0x0001 {
		t.Errorf("DNS_SETTING_IPV6 = %#x, want 0x0001", dnsSettingIPV6)
	}
	// The two are distinct bits, so selecting the v6 stack must not clear the
	// name-server bit: a combined flag that lost either one produces a call that
	// succeeds and changes nothing.
	if dnsSettingIPV6&dnsSettingNameServer != 0 {
		t.Error("DNS_SETTING_IPV6 and DNS_SETTING_NAMESERVER overlap")
	}
}

// TestSetInterfaceDnsSettingsBindsTwoArguments pins the argument count and order.
//
// This is the assertion the entry point's declaration invites getting wrong. The SDK
// takes the interface as a by-value GUID, and on x64 a 16-byte argument arrives in a
// register holding a pointer to the caller's own copy — so this is a TWO-argument call.
// The natural reading, that a by-value 16-byte POD is passed as two 8-byte integers,
// makes it a three-argument call, and the settings pointer then lands in a register the
// kernel is not reading: a fault on a garbage address, in a LocalSystem daemon.
//
// MSVC's generated assembly for a forwarding call settles it, and it moves a 16-byte
// GUID into a stack temporary and loads its address into the first register, leaving the
// caller's own settings pointer in the second untouched.
func TestSetInterfaceDnsSettingsBindsTwoArguments(t *testing.T) {
	guid := windows.GUID{Data1: 0x11223344}
	var settings dnsInterfaceSettings

	call := newDnsSettingsCall(&guid, &settings)

	if len(call.args) != dnsSettingsArgs {
		t.Fatalf("SetInterfaceDnsSettings bound with %d arguments, want %d: %v",
			len(call.args), dnsSettingsArgs, call.args)
	}
	if call.args[argSlotDNSInterface] != uintptr(unsafe.Pointer(&guid)) {
		t.Errorf("argument %d = %#x, want the bound GUID address %#x",
			argSlotDNSInterface, call.args[argSlotDNSInterface], uintptr(unsafe.Pointer(&guid)))
	}
	if call.args[argSlotDNSSettings] != uintptr(unsafe.Pointer(&settings)) {
		t.Errorf("argument %d = %#x, want the bound settings address %#x",
			argSlotDNSSettings, call.args[argSlotDNSSettings], uintptr(unsafe.Pointer(&settings)))
	}
	// The typed buffers must be the caller's own: the entry point writes through
	// neither, but a test can only check the list against them.
	if call.guid != &guid {
		t.Error("the call does not carry the caller's GUID buffer")
	}
	if call.settings != &settings {
		t.Error("the call does not carry the caller's settings buffer")
	}
	// Three arguments is the shape a reader would guess. Assert its absence explicitly
	// so the count above cannot be "fixed" back toward it without failing here too.
	if len(call.args) > dnsSettingsArgs {
		t.Errorf("SetInterfaceDnsSettings bound %d arguments; the GUID is passed by "+
			"reference, so a third slot would shift Settings out of its register",
			len(call.args))
	}
}

// TestUnicastAddrCallBindsOneArgument pins the address entry point's shape.
func TestUnicastAddrCallBindsOneArgument(t *testing.T) {
	var row windows.MibUnicastIpAddressRow
	call := newUnicastAddrCall(&row)
	if len(call.args) != 1 {
		t.Fatalf("bound with %d arguments, want 1: %v", len(call.args), call.args)
	}
	if call.args[0] != uintptr(unsafe.Pointer(&row)) {
		t.Errorf("argument = %#x, want the bound row address %#x",
			call.args[0], uintptr(unsafe.Pointer(&row)))
	}
	if call.row != &row {
		t.Error("the call does not carry the caller's row buffer")
	}
}

// TestUnicastAddrRowLayout pins MIB_UNICASTIPADDRESS_ROW as x/sys declares it against
// the SDK's offsets. This one is not hand-written, so the risk is a future x/sys bump
// that reorders the struct under a comment claiming it cannot.
func TestUnicastAddrRowLayout(t *testing.T) {
	offsets := map[string]uintptr{
		"Address":            0,
		"InterfaceLuid":      32,
		"InterfaceIndex":     40,
		"PrefixOrigin":       44,
		"SuffixOrigin":       48,
		"ValidLifetime":      52,
		"PreferredLifetime":  56,
		"OnLinkPrefixLength": 60,
		"SkipAsSource":       61,
		"DadState":           64,
		"ScopeId":            68,
		"CreationTimeStamp":  72,
	}
	var row windows.MibUnicastIpAddressRow
	for name, want := range offsets {
		var got uintptr
		switch name {
		case "Address":
			got = unsafe.Offsetof(row.Address)
		case "InterfaceLuid":
			got = unsafe.Offsetof(row.InterfaceLuid)
		case "InterfaceIndex":
			got = unsafe.Offsetof(row.InterfaceIndex)
		case "PrefixOrigin":
			got = unsafe.Offsetof(row.PrefixOrigin)
		case "SuffixOrigin":
			got = unsafe.Offsetof(row.SuffixOrigin)
		case "ValidLifetime":
			got = unsafe.Offsetof(row.ValidLifetime)
		case "PreferredLifetime":
			got = unsafe.Offsetof(row.PreferredLifetime)
		case "OnLinkPrefixLength":
			got = unsafe.Offsetof(row.OnLinkPrefixLength)
		case "SkipAsSource":
			got = unsafe.Offsetof(row.SkipAsSource)
		case "DadState":
			got = unsafe.Offsetof(row.DadState)
		case "ScopeId":
			got = unsafe.Offsetof(row.ScopeId)
		case "CreationTimeStamp":
			got = unsafe.Offsetof(row.CreationTimeStamp)
		}
		if got != want {
			t.Errorf("MIB_UNICASTIPADDRESS_ROW.%s offset = %d, want %d", name, got, want)
		}
	}
	if size := unsafe.Sizeof(row); size != 80 {
		t.Errorf("sizeof(MIB_UNICASTIPADDRESS_ROW) = %d, want 80", size)
	}
}

// TestAddressRowOriginsAndLifetimes pins the constants that make an address read back as
// manually configured with no expiry. The enums these mirror are kernel-only, so the
// numbers cannot be imported and a typo would produce a DHCP-scoped, expiring address on
// the tunnel interface.
func TestAddressRowOriginsAndLifetimes(t *testing.T) {
	// Both enumerations open with an "other" member, so Manual is 1 in each. Reading 2
	// here instead would describe the tunnel address as WellKnown (prefix) or Dhcp
	// (suffix), which the stack accepts and then reports back.
	if ipOriginManual != 1 {
		t.Errorf("IpPrefixOriginManual = %d, want 1", ipOriginManual)
	}
	if ipSuffixOriginManual != 1 {
		t.Errorf("IpSuffixOriginManual = %d, want 1", ipSuffixOriginManual)
	}
	if infiniteLifetime != 0xFFFFFFFF {
		t.Errorf("INFINITE_LIFETIME = %#x, want 0xffffffff", infiniteLifetime)
	}
	// IpDadStatePreferred, not IpDadStateParent. Leaving DAD to run on a point-to-point
	// adapter never completes, and a failed DAD state leaves the address unusable.
	if ipDadStatePreferred != 1 {
		t.Errorf("IpDadStatePreferred = %d, want 1", ipDadStatePreferred)
	}
}

// TestSockaddrInetIsAUnionPinsTheAddressOffset pins the layout the IPv4 arm occupies.
//
// SOCKADDR_INET is declared as a union of SOCKADDR_IN and SOCKADDR_IN6, so the two arms
// place their addresses at different offsets: 4 for IPv4, 8 for IPv6. x/sys models the
// whole union as its IPv6 arm, which is why a row filled through it has to write an
// IPv4 address four bytes earlier than Addr suggests.
//
// This is measured, not derived: MSVC on the target platform reports sizeof = 28 with
// Ipv4.sin_addr at 4 and Ipv6.sin6_addr at 8.
func TestSockaddrInetIsAUnionPinsTheAddressOffset(t *testing.T) {
	v4 := rawInetUnionMust(t, net.ParseIP("10.8.0.5"))
	if off := unsafe.Offsetof(v4.Addr); off != 8 {
		t.Errorf("IPv6 arm's Addr is at offset %d, want 8", off)
	}
	// The IPv4 arm's four bytes share the field the IPv6 arm calls Flowinfo.
	if off := unsafe.Offsetof(v4.Flowinfo); off != 4 {
		t.Errorf("IPv4 arm's address is at offset %d, want 4", off)
	}
	if off := unsafe.Offsetof(v4.Scope_id); off != 24 {
		t.Errorf("scope id is at offset %d, want 24", off)
	}
	if size := unsafe.Sizeof(v4); size != 28 {
		t.Errorf("sizeof(SOCKADDR_INET) = %d, want 28", size)
	}

	// And the IPv4 address must actually be at offset 4, read back as the union the
	// route code knows how to interpret.
	raw := *(*windows.RawSockaddrInet)(unsafe.Pointer(&v4))
	back, err := rawInetIP(raw)
	if err != nil {
		t.Fatalf("read the union back: %v", err)
	}
	if !back.Equal(net.ParseIP("10.8.0.5")) {
		t.Errorf("IPv4 address read back from the union = %v, want 10.8.0.5", back)
	}
}

func rawInetUnionMust(t *testing.T, ip net.IP) windows.RawSockaddrInet6 {
	t.Helper()
	sa, err := rawInetUnion(ip)
	if err != nil {
		t.Fatalf("rawInetUnion(%v): %v", ip, err)
	}
	return sa
}

// TestRawInetUnionPlacesAddressesInTheUnionArm checks that both families land where
// their arm puts them, read back through the union the route code already interprets.
//
// SOCKADDR_INET is a union whose IPv4 and IPv6 arms disagree about where the address
// begins — 4 versus 8 — so a conversion that gets one right can get the other wrong.
// Both are read back here rather than inspected in place, because that is the check
// that would catch an address landing at the wrong offset.
func TestRawInetUnionPlacesAddressesInTheUnionArm(t *testing.T) {
	v4 := rawInetUnionMust(t, net.ParseIP("10.8.0.5"))
	if v4.Family != windows.AF_INET {
		t.Errorf("IPv4 family = %d, want AF_INET (%d)", v4.Family, windows.AF_INET)
	}
	// Read through the IPv4 arm, which is where an AF_INET address belongs.
	if got := net.IP((*windows.RawSockaddrInet4)(unsafe.Pointer(&v4)).Addr[:]); !got.Equal(net.ParseIP("10.8.0.5")) {
		t.Errorf("IPv4 address in the union arm = %v, want 10.8.0.5", got)
	}

	v6 := rawInetUnionMust(t, net.ParseIP("fd00::1"))
	if v6.Family != windows.AF_INET6 {
		t.Errorf("IPv6 family = %d, want AF_INET6 (%d)", v6.Family, windows.AF_INET6)
	}
	if got := net.IP(v6.Addr[:]); !got.Equal(net.ParseIP("fd00::1")) {
		t.Errorf("IPv6 address in the union arm = %v, want fd00::1", got)
	}

	if _, err := rawInetUnion(net.IP{1, 2, 3}); err == nil {
		t.Error("rawInetUnion accepted a non-address")
	}
}

// TestSetDNSSplitsPerFamily drives the family split over the call seam. The entry point
// applies to one stack per call and rejects a list mixing the two, so a config naming
// both has to become two calls.
func TestSetDNSSplitsPerFamily(t *testing.T) {
	original := callSetInterfaceDNS
	t.Cleanup(func() { callSetInterfaceDNS = original })

	var seen []dnsSettingsCall
	callSetInterfaceDNS = func(call dnsSettingsCall) uintptr {
		seen = append(seen, call)
		return 0
	}

	guid := windows.GUID{Data1: 7}
	err := liveWindowsNetIf{}.setDNS(guid, []net.IP{
		net.ParseIP("10.8.0.1"),
		net.ParseIP("fd00::1"),
		net.ParseIP("10.8.0.2"),
	})
	if err != nil {
		t.Fatalf("setDNS = %v, want nil", err)
	}
	if len(seen) != 2 {
		t.Fatalf("setDNS made %d calls, want one per family: %d", len(seen), len(seen))
	}

	// First call: IPv4 only, no IPV6 flag.
	if seen[0].settings.Flags != dnsSettingNameServer {
		t.Errorf("IPv4 call flags = %#x, want DNS_SETTING_NAMESERVER alone", seen[0].settings.Flags)
	}
	// Second call: IPv6, with the name-server bit still set.
	wantV6 := uint64(dnsSettingNameServer) | dnsSettingIPV6
	if seen[1].settings.Flags != wantV6 {
		t.Errorf("IPv6 call flags = %#x, want %#x", seen[1].settings.Flags, wantV6)
	}
	for i, call := range seen {
		if call.settings.Version != dnsInterfaceSettingsVersion1 {
			t.Errorf("call %d version = %d, want %d", i, call.settings.Version, dnsInterfaceSettingsVersion1)
		}
		// Only the members the flags name may be non-zero.
		if call.settings.Domain != nil || call.settings.SearchList != nil ||
			call.settings.ProfileNameServer != nil {
			t.Errorf("call %d populated members no flag selects", i)
		}
	}
}

// TestDNSServerStringIsCommaSeparated pins the rendering the entry point reads.
func TestDNSServerStringIsCommaSeparated(t *testing.T) {
	got := dnsServerString([]net.IP{net.ParseIP("10.8.0.1"), net.ParseIP("10.8.0.2")})
	if got != "10.8.0.1,10.8.0.2" {
		t.Errorf("dnsServerString = %q, want %q", got, "10.8.0.1,10.8.0.2")
	}
	if single := dnsServerString(nil); single != "" {
		t.Errorf("dnsServerString(nil) = %q, want empty", single)
	}
}

// TestAddAddressTranslatesAFailureStatus covers the other half of the binding: a
// non-zero return is a status that must reach the caller as a wrapped error naming the
// address and the interface, not as a silently ignored value.
func TestAddAddressTranslatesAFailureStatus(t *testing.T) {
	original := callCreateUnicastAddr
	t.Cleanup(func() { callCreateUnicastAddr = original })
	callCreateUnicastAddr = func(unicastAddrCall) uintptr {
		return uintptr(windows.STATUS_NOT_FOUND)
	}

	err := liveWindowsNetIf{}.addAddress(42, net.ParseIP("10.8.0.5"), 32)
	if err == nil {
		t.Fatal("addAddress returned nil for a failing CreateUnicastIpAddressEntry")
	}
	if !isMissingErrno(err) {
		t.Errorf("addAddress error = %v, want a translated no-such-interface", err)
	}
	// Which address could not be configured is the actionable part, so it has to be in
	// the message along with the interface it was aimed at.
	if !containsStr(err.Error(), "10.8.0.5") || !containsStr(err.Error(), "42") {
		t.Errorf("addAddress error = %v, want it to name the address and the interface", err)
	}
}

// TestAddAddressFillsTheRowTheKernelReads checks the row the entry point is handed. A
// row with a zero prefix length or a finite lifetime is accepted by the kernel and
// produces an address that is wrong rather than absent, which is the harder failure.
func TestAddAddressFillsTheRowTheKernelReads(t *testing.T) {
	original := callCreateUnicastAddr
	t.Cleanup(func() { callCreateUnicastAddr = original })

	var seen windows.MibUnicastIpAddressRow
	callCreateUnicastAddr = func(call unicastAddrCall) uintptr {
		seen = *call.row
		return 0
	}

	if err := (liveWindowsNetIf{}).addAddress(42, net.ParseIP("10.8.0.5"), 32); err != nil {
		t.Fatalf("addAddress = %v, want nil", err)
	}
	if seen.InterfaceLuid != 42 {
		t.Errorf("InterfaceLuid = %d, want 42", seen.InterfaceLuid)
	}
	if seen.InterfaceIndex != 0 {
		t.Errorf("InterfaceIndex = %d, want 0: the LUID is the identifier in use, and "+
			"naming both is how the two are read as disagreeing", seen.InterfaceIndex)
	}
	if seen.OnLinkPrefixLength != 32 {
		t.Errorf("OnLinkPrefixLength = %d, want the 32 the caller asked for", seen.OnLinkPrefixLength)
	}
	if seen.PrefixOrigin != ipOriginManual || seen.SuffixOrigin != ipSuffixOriginManual {
		t.Errorf("origins = %d/%d, want manual (%d/%d)",
			seen.PrefixOrigin, seen.SuffixOrigin, ipOriginManual, ipSuffixOriginManual)
	}
	if seen.ValidLifetime != infiniteLifetime || seen.PreferredLifetime != infiniteLifetime {
		t.Errorf("lifetimes = %#x/%#x, want INFINITE_LIFETIME",
			seen.ValidLifetime, seen.PreferredLifetime)
	}
	if seen.Address.Family != windows.AF_INET {
		t.Errorf("row address family = %d, want AF_INET (%d)", seen.Address.Family, windows.AF_INET)
	}
	// Read through the IPv4 arm: an AF_INET address sits at offset 4, not in Addr.
	arm := (*windows.RawSockaddrInet4)(unsafe.Pointer(&seen.Address))
	if got := net.IP(arm.Addr[:]); !got.Equal(net.ParseIP("10.8.0.5")) {
		t.Errorf("row address = %v, want 10.8.0.5", got)
	}
}

// TestOnLinkNextHopMatchesTheFamily checks the "no gateway" value carries the family of
// the prefix it belongs to. An IPv4-shaped zero next hop on an IPv6 route makes the
// entry point reject the row.
func TestOnLinkNextHopMatchesTheFamily(t *testing.T) {
	v4, _, err := rawInet(net.ParseIP("10.8.0.0"))
	if err != nil {
		t.Fatal(err)
	}
	if got := onLinkNextHop(v4); !got.IsUnspecified() {
		t.Errorf("IPv4 on-link next hop = %v, want the unspecified v4 address", got)
	}
	v6, _, err := rawInet(net.ParseIP("fd00::"))
	if err != nil {
		t.Fatal(err)
	}
	if got := onLinkNextHop(v6); !got.IsUnspecified() {
		t.Errorf("IPv6 on-link next hop = %v, want the unspecified v6 address", got)
	}
}

//go:build windows

// The Windows route primitives both tunnel backends are built from.
//
// Three IP Helper entry points are needed and `golang.org/x/sys/windows` binds
// only some of them: `GetIpForwardEntry2` and `GetIpForwardTable2` come from
// the package, `GetBestRoute2`, `CreateIpForwardEntry2`, and
// `DeleteIpForwardEntry2` are bound here. They live in iphlpapi.dll, a system
// library, so a lazy system-DLL load is the right scope — there is no
// caller-influenceable search path here the way there is for a bare tool name.
//
// Everything sits behind [windowsRoutes] so a backend's sequencing is testable
// without touching this machine's routing table. The real implementation reads
// and writes the live table; tests substitute a recorder.
//
// Two callers share it, and they want different shapes of the same entry point.
// The stream transport installs a /32 for one destination through a gateway it
// asked the table for; the obfuscated data plane installs one route per AllowedIPs
// prefix, on-link, on an interface it just created. So [windowsRoutes] carries both
// a host-route form and a prefix form, over a shared [installRoute] core.
//
// Unlike the Linux backend, there is no fwmark policy-rule complication. The
// tunnel's own route for AllowedIPs = 0.0.0.0/0 is a default route, and
// Windows matches the longest prefix first, so a /32 host route through the
// physical interface wins on specificity alone — no metric race to lose. The
// reverse does need one: a second /0 competes on metric, which is why the tunnel
// route's metric is lower than the physical default's rather than absent.
package tunnel

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"unsafe"

	"golang.org/x/sys/windows"
)

// iphlpapi is the system library holding the route entry points bound below.
// It is loaded by absolute path with the System32-only search flag rather than
// by bare name: the daemon runs as LocalSystem, so a DLL sitting beside the
// helper in Program Files must not be able to satisfy this and run in its
// place. This mirrors what the package's own iphlpapi bindings do, and what
// [wireGuardReader] does for the bundled WireGuard DLLs by absolute path.
var iphlpapi = windows.NewLazyDLL(system32DLL("iphlpapi.dll"))

var (
	procGetBestRoute2 = iphlpapi.NewProc("GetBestRoute2")
	procCreateRoute2  = iphlpapi.NewProc("CreateIpForwardEntry2")
	procDeleteRoute2  = iphlpapi.NewProc("DeleteIpForwardEntry2")
)

// hostRouteMetric is the metric given to a bypass host route. It does not have
// to beat the tunnel's default route — longest-prefix matching already decides
// that — but a finite low value keeps the entry deterministic if a /32 for the
// same destination is ever installed by something else.
const hostRouteMetric = 1

// system32DLL renders a system library's absolute path. NewLazyDLL resolves
// through LoadLibraryEx with the application directory in its search list, so
// naming the library by full path is what removes that directory from the
// search: a caller-supplied name could otherwise be satisfied by a file in the
// helper's own directory.
func system32DLL(name string) string {
	return filepath.Join(os.Getenv("SystemRoot"), "System32", name)
}

// physicalRoute is where a destination goes today: the interface it leaves by
// and the next hop it is handed to. Both come from the live routing table, so
// this must be asked *before* the tunnel installs its own routes — afterwards
// the answer is the tunnel, which is the loop this whole file exists to avoid.
type physicalRoute struct {
	luid    uint64
	nextHop net.IP
}

// windowsRoutes is the seam the transport drives. The production
// implementation is [liveWindowsRoutes].
//
// Note what the seam does *not* cover: a route that is already gone is treated as
// success inside [liveWindowsRoutes.deleteHostRoute], not here, so no unit test
// through this interface can observe that tolerance — a fake that reports an
// error is reporting something the real implementation never would. That
// tolerance is only exercisable against a live forward table.
type windowsRoutes interface {
	// bestRoute reports where dst currently goes.
	bestRoute(dst net.IP) (physicalRoute, error)
	// addHostRoute installs a /32 (or /128) route for dst through route.
	addHostRoute(dst net.IP, route physicalRoute) error
	// deleteHostRoute removes it. An absent route is success: the goal is "no
	// bypass route left", not one call per installed route.
	deleteHostRoute(dst net.IP) error
	// addPrefixRoute installs a route for an arbitrary prefix on one interface. A
	// nil nextHop means on-link, which is what a route into the tunnel wants: the
	// next hop is the tunnel adapter the prefix already names.
	addPrefixRoute(prefix net.IP, bits uint8, luid uint64, nextHop net.IP, metric uint32) error
	// deletePrefixRoute removes it. As with deleteHostRoute, an absent route is
	// success.
	deletePrefixRoute(prefix net.IP, bits uint8) error
}

// liveWindowsRoutes reads and writes this machine's IP forward table.
type liveWindowsRoutes struct{}

// bestRoute asks the IP forward table which route a destination currently
// takes. GetBestRoute2 applies the same longest-prefix selection the stack
// would, so this is the authoritative answer rather than a reimplementation of
// it.
//
// A route with no next hop (the table's way of saying on-link) is rejected
// rather than installed as one: a /32 with an unspecified next hop is not a
// route the stack can use, and silently creating one would leave the daemon
// believing it had cut around the tunnel when it had not.
func (liveWindowsRoutes) bestRoute(dst net.IP) (physicalRoute, error) {
	sa, _, err := rawInet(dst)
	if err != nil {
		return physicalRoute{}, err
	}
	var row windows.MibIpForwardRow2
	ret, _ := callGetBestRoute2(newBestRoute2Call(&sa, &row, &bestSourceForLookup))
	if ret != 0 {
		return physicalRoute{}, fmt.Errorf("GetBestRoute2(%s): %w", dst, routeError(windows.NTStatus(ret)))
	}
	nextHop, err := rawInetIP(row.NextHop)
	if err != nil {
		return physicalRoute{}, fmt.Errorf("route for %s has an unusable next hop: %w", dst, err)
	}
	if nextHop == nil {
		return physicalRoute{}, fmt.Errorf(
			"route for %s is on-link with no next hop, so it cannot be pinned", dst)
	}
	return physicalRoute{luid: row.InterfaceLuid, nextHop: nextHop}, nil
}

// addHostRoute installs the bypass route: a /32 (or /128) for one destination,
// pinned through the interface and next hop the table already uses for it.
func (liveWindowsRoutes) addHostRoute(dst net.IP, route physicalRoute) error {
	prefix, bits, err := rawInet(dst)
	if err != nil {
		return err
	}
	return installRoute(
		fmt.Sprintf("bypass route for %s", dst),
		prefix, bits, route.luid, route.nextHop, hostRouteMetric,
	)
}

// addPrefixRoute installs a route for an arbitrary prefix, which is what the
// obfuscated data plane needs for each of the peer's AllowedIPs. A nil nextHop
// means on-link: the destination prefix already names the tunnel adapter, so the
// table records no gateway rather than one that does not exist.
func (liveWindowsRoutes) addPrefixRoute(prefix net.IP, bits uint8, luid uint64, nextHop net.IP, metric uint32) error {
	sa, _, err := rawInet(prefix)
	if err != nil {
		return err
	}
	if nextHop == nil {
		nextHop = onLinkNextHop(sa)
	}
	return installRoute(
		fmt.Sprintf("tunnel route for %s/%d", prefix, bits),
		sa, bits, luid, nextHop, metric,
	)
}

// installRoute creates a forward entry, replacing whatever else holds the prefix.
//
// The interface is named by LUID rather than index because that is what the entry
// point takes, and the index form races an adapter that is being renumbered.
//
// A route already present for the destination is replaced rather than reported as a
// failure: Windows has no atomic "replace" for a forward entry, and a retry
// legitimately re-pins a destination its predecessor already pinned. The
// delete-then-create leaves a brief window with no route, which is the safer
// direction — traffic follows the tunnel for a moment instead of a stale pin
// outliving the tunnel it was cut for.
func installRoute(desc string, prefix windows.RawSockaddrInet, bits uint8, luid uint64, nextHop net.IP, metric uint32) error {
	next, _, err := rawInet(nextHop)
	if err != nil {
		return err
	}
	var existing windows.MibIpForwardRow2
	existing.DestinationPrefix = windows.IpAddressPrefix{Prefix: prefix, PrefixLength: bits}
	if err := windows.GetIpForwardEntry2(&existing); err == nil {
		if existing.InterfaceLuid == luid && sameAddr(existing.NextHop, next) {
			// Already exactly this route; installing it again would fail with
			// an object collision and change nothing.
			return nil
		}
		ret, _, _ := procDeleteRoute2.Call(uintptr(unsafe.Pointer(&existing)))
		if ret != 0 && !isMissingNTStatus(windows.NTStatus(ret)) {
			return fmt.Errorf("replace %s: %w", desc, routeError(windows.NTStatus(ret)))
		}
	} else if !isMissingErrno(err) {
		// An absent entry is the expected case and means there is nothing to
		// replace. Any other lookup failure is not something to install on top
		// of: a route this daemon cannot see is a route it cannot later sweep.
		return fmt.Errorf("look up existing %s: %w", desc, err)
	}
	row := forwardRow(prefix, bits, luid, next, metric)
	ret, _, _ := procCreateRoute2.Call(uintptr(unsafe.Pointer(&row)))
	if ret != 0 {
		return fmt.Errorf("install %s: %w", desc, routeError(windows.NTStatus(ret)))
	}
	return nil
}

// forwardRow builds the MIB_IPFORWARD_ROW2 an install hands to the entry point.
//
// Separated from [installRoute] so the row can be inspected in a test without writing to
// this machine's forward table: the fields below are the difference between a route the
// stack uses and one it lists and ignores.
func forwardRow(prefix windows.RawSockaddrInet, bits uint8, luid uint64, next windows.RawSockaddrInet, metric uint32) windows.MibIpForwardRow2 {
	return windows.MibIpForwardRow2{
		InterfaceLuid: luid,
		DestinationPrefix: windows.IpAddressPrefix{
			Prefix:       prefix,
			PrefixLength: bits,
		},
		NextHop:  next,
		Metric:   metric,
		Protocol: windows.MIB_IPPROTO_NETMGMT,
		// The lifetimes are INFINITE_LIFETIME, and they have to be: zero is not
		// "no expiry", it is an expiry of now. An entry point created that way lands in
		// the table and Get-NetRoute reports it as Alive, while the FIB has already
		// discarded it and the stack keeps routing that destination somewhere else. A
		// tunnel whose route is installed exactly like a working one, and ignored
		// exactly like a broken one, is not a failure any log line describes.
		ValidLifetime:     infiniteLifetime,
		PreferredLifetime: infiniteLifetime,
	}
}

// onLinkNextHop renders the "no gateway" value a forward row carries for an on-link
// route, in the family the destination prefix belongs to. A nil NextHop is how the
// table says the destination is directly reachable through the named interface,
// which is the truth for the tunnel's own routes.
func onLinkNextHop(prefix windows.RawSockaddrInet) net.IP {
	if prefix.Family == windows.AF_INET6 {
		return net.IPv6zero
	}
	return net.IPv4zero
}

// deleteHostRoute removes the bypass route.
func (liveWindowsRoutes) deleteHostRoute(dst net.IP) error {
	prefix, bits, err := rawInet(dst)
	if err != nil {
		return err
	}
	return removeRoute(fmt.Sprintf("bypass route for %s", dst), prefix, bits)
}

// deletePrefixRoute removes a tunnel route. The tunnel's routes live on the Wintun
// adapter and go with it, so this exists for the paths that remove them while the
// adapter is still there.
func (liveWindowsRoutes) deletePrefixRoute(prefix net.IP, bits uint8) error {
	sa, _, err := rawInet(prefix)
	if err != nil {
		return err
	}
	return removeRoute(fmt.Sprintf("tunnel route for %s/%d", prefix, bits), sa, bits)
}

// removeRoute deletes a forward entry, looking it up first because the delete entry
// point identifies a route by its full row, including the interface it was installed
// on — a prefix is not unique on its own. A missing entry is the desired end state.
func removeRoute(desc string, prefix windows.RawSockaddrInet, bits uint8) error {
	var row windows.MibIpForwardRow2
	row.DestinationPrefix = windows.IpAddressPrefix{Prefix: prefix, PrefixLength: bits}
	if err := windows.GetIpForwardEntry2(&row); err != nil {
		// The package's binding surfaces this entry point's NETIO_STATUS as a
		// raw syscall.Errno, so a missing route arrives as an ERROR_* code here
		// rather than a STATUS_* one. Both spellings are accepted for that
		// reason: which one a given Windows build produces is not something to
		// bet a teardown on.
		if isMissingErrno(err) {
			return nil
		}
		return fmt.Errorf("look up %s: %w", desc, err)
	}
	ret, _, _ := procDeleteRoute2.Call(uintptr(unsafe.Pointer(&row)))
	if ret != 0 {
		status := windows.NTStatus(ret)
		if isMissingNTStatus(status) {
			return nil
		}
		return fmt.Errorf("remove %s: %w", desc, routeError(status))
	}
	return nil
}

// routeError renders an NTSTATUS from the IP Helper entry points. These return
// NETIO_STATUS codes, not Win32 error codes, so the value must be translated
// before it is reported — comparing one against an ERROR_* constant is a
// category error that silently never matches.
func routeError(status windows.NTStatus) error {
	if status == 0 {
		return nil
	}
	// The numeric code always rides along. Windows has no message for many of these
	// codes, and FormatMessage then substitutes a placeholder that names neither the
	// code nor a remedy — "the system cannot find message text for message number 0x%1"
	// — so a reader given only that has nothing to act on. Which codes are unnamed is
	// not something to be discovering during an incident.
	return fmt.Errorf("NETIO status %#x: %w", uint32(status), status.Errno())
}

// isMissingNTStatus reports whether a status means "no such route". Windows
// reports an absent forward entry as STATUS_OBJECT_NAME_NOT_FOUND, and some
// paths as STATUS_NOT_FOUND.
func isMissingNTStatus(status windows.NTStatus) bool {
	switch status {
	case windows.STATUS_OBJECT_NAME_NOT_FOUND,
		windows.STATUS_OBJECT_PATH_NOT_FOUND,
		windows.STATUS_NOT_FOUND:
		return true
	default:
		return false
	}
}

// isMissingErrno is [isMissingNTStatus] for an error that has already been
// translated, which is how the package's own bound entry points report. It
// unwraps, so a caller that has added context still matches.
func isMissingErrno(err error) bool {
	var errno windows.Errno
	if !errors.As(err, &errno) {
		return false
	}
	return errno == windows.ERROR_FILE_NOT_FOUND || errno == windows.ERROR_NOT_FOUND
}

// sameAddr compares two SOCKADDR_INET values for the same address, ignoring
// port and padding.
func sameAddr(a, b windows.RawSockaddrInet) bool {
	return a.Family == b.Family && rawInetBytes(a) == rawInetBytes(b)
}

// rawInetBytes renders a SOCKADDR_INET's address as a comparable string.
func rawInetBytes(sa windows.RawSockaddrInet) string {
	ip, err := rawInetIP(sa)
	if err != nil || ip == nil {
		return ""
	}
	return ip.String()
}

// bestSourceForLookup is the out-parameter buffer GetBestRoute2 writes the chosen
// source address through. It is passed a scratch buffer rather than NULL because
// the entry point rejects a null pointer there, and the value itself is of no
// interest: only the route row is read back.
var bestSourceForLookup windows.RawSockaddrInet

// callGetBestRoute2 is the seam over the bound entry point's variadic call, so
// the *argument list* can be asserted in a test without loading iphlpapi.
//
// The seam deliberately sits at the variadic Call rather than wrapping the call
// in a typed helper. A typed helper is where the bug hid: with the arguments
// behind a signature the type checker vouched for, a test could stub the helper
// and assert only that the helper was called with the right pointers -- which
// stayed green while the argument list *inside* it was still wrong. Keeping the
// list here means the test sees the same thing the kernel sees.
var callGetBestRoute2 = func(call bestRoute2Call) (uintptr, error) {
	ret, _, err := procGetBestRoute2.Call(call.args...)
	return ret, err
}

// bestRoute2Args builds GetBestRoute2's seven arguments, in the order the entry
// point declares them:
//
//	NET_LUID*, NET_IFINDEX, SOCKADDR_INET* (source), SOCKADDR_INET* (destination),
//	ULONG sortOptions, MIB_IPFORWARD_ROW2*, SOCKADDR_INET* (best source)
//
// The destination is the FOURTH parameter. It was bound first, which made the
// kernel read the address as a NET_LUID and fail with a status no message table
// could name -- and because the call is variadic, nothing but this list's own
// comments could have caught it.
//
// A null LUID and a zero index together mean "consult the routing table", which
// is what a caller asking "where does this go today" wants: the interface is an
// output here, not an input. Zero for the optional source address asks the same,
// and zero for the unused sort options is what the documentation specifies.
// bestRoute2Call is one GetBestRoute2 invocation: the variadic argument list as
// the kernel sees it, plus the typed buffers those slots point at.
//
// Carrying both is what lets a test assert the argument *order* and still write
// through the out-parameters. Reading a typed pointer back out of the []uintptr
// would mean converting a uintptr to a pointer, which govet rejects (a uintptr
// carries no provenance), so the pointers travel alongside instead of being
// recovered from the list.
type bestRoute2Call struct {
	args       []uintptr
	dst        *windows.RawSockaddrInet
	row        *windows.MibIpForwardRow2
	bestSource *windows.RawSockaddrInet
}

// newBestRoute2Call builds the argument list in the order the entry point
// declares its parameters:
//
//	NET_LUID*, NET_IFINDEX, SOCKADDR_INET* (source), SOCKADDR_INET* (destination),
//	ULONG sortOptions, MIB_IPFORWARD_ROW2*, SOCKADDR_INET* (best source)
//
// The destination is the FOURTH parameter. It was bound first, which made the
// kernel read the address as a NET_LUID and fail with a status no message table
// could name -- and because the call is variadic, nothing but this list's own
// comments could have caught it.
//
// A null LUID and a zero index together mean "consult the routing table", which
// is what a caller asking "where does this go today" wants: the interface is an
// output here, not an input. Zero for the optional source address asks the same,
// and zero for the unused sort options is what the documentation specifies.
func newBestRoute2Call(
	dst *windows.RawSockaddrInet,
	row *windows.MibIpForwardRow2,
	bestSource *windows.RawSockaddrInet,
) bestRoute2Call {
	return bestRoute2Call{
		args: []uintptr{
			0, // InterfaceLuid -- absent, so the table decides
			0, // InterfaceIndex -- absent, so the table decides
			0, // SourceAddress -- optional, absent
			uintptr(unsafe.Pointer(dst)),
			0, // AddressSortOptions -- not currently used
			uintptr(unsafe.Pointer(row)),
			uintptr(unsafe.Pointer(bestSource)),
		},
		dst:        dst,
		row:        row,
		bestSource: bestSource,
	}
}

// rawInet renders ip as the SOCKADDR_INET the route entry points take, plus the
// address's bit length for the prefix length field.
//
// The conversion goes through the concrete RawSockaddrInet4/6 layouts, which is
// the conversion the package documents: RawSockaddrInet is a union, and the
// address bytes sit at a different offset in each arm.
func rawInet(ip net.IP) (windows.RawSockaddrInet, uint8, error) {
	var out windows.RawSockaddrInet
	if v4 := ip.To4(); v4 != nil {
		sa := windows.RawSockaddrInet4{Family: windows.AF_INET}
		copy(sa.Addr[:], v4)
		*(*windows.RawSockaddrInet4)(unsafe.Pointer(&out)) = sa
		return out, 32, nil
	}
	if v6 := ip.To16(); v6 != nil {
		sa := windows.RawSockaddrInet6{Family: windows.AF_INET6}
		copy(sa.Addr[:], v6)
		*(*windows.RawSockaddrInet6)(unsafe.Pointer(&out)) = sa
		return out, 128, nil
	}
	return out, 0, fmt.Errorf("not an IP address: %v", ip)
}

// rawInetIP reads an address back out of a SOCKADDR_INET, so a next hop read
// from the table can be compared and installed. An unspecified address (the
// table's way of saying "on-link, no gateway") yields nil: there is no next hop
// to install, and a caller that needs one must fail closed rather than guess a
// gateway.
func rawInetIP(sa windows.RawSockaddrInet) (net.IP, error) {
	switch sa.Family {
	case windows.AF_INET:
		raw := (*windows.RawSockaddrInet4)(unsafe.Pointer(&sa))
		return net.IP(raw.Addr[:]).To4(), nil
	case windows.AF_INET6:
		raw := (*windows.RawSockaddrInet6)(unsafe.Pointer(&sa))
		ip := net.IP(raw.Addr[:])
		if ip.IsUnspecified() {
			return nil, nil
		}
		return ip, nil
	default:
		return nil, fmt.Errorf("unsupported address family %d", sa.Family)
	}
}

//go:build windows

package tunnel

import (
	"net"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The IP Helper entry points are bound by hand rather than through
// x/sys/windows, so nothing in the type system checks their signatures. Because
// the call is variadic, a wrong argument count or order is invisible to the
// compiler and reaches the kernel as garbage -- which is exactly what happened:
// GetBestRoute2 takes seven parameters, and binding three of them (destination
// first) made the kernel read the address as a NET_LUID, so every real bring-up
// failed with a status no message table could name.
//
// The transport tests could not see this: they drive the windowsRoutes seam, and
// liveWindowsRoutes is what holds the binding. So the assertion has to be about
// the argument list itself, which is why newBestRoute2Call is the unit under test
// and not a typed helper wrapping the call -- a typed helper would let a test
// assert "the right pointers reached the helper" and stay green while the list
// inside it was still wrong.

// Parameter slots, per the entry point's declaration:
//
//	0 NET_LUID* (optional)      4 ULONG sortOptions
//	1 NET_IFINDEX                5 MIB_IPFORWARD_ROW2*  (out)
//	2 SOCKADDR_INET* source      6 SOCKADDR_INET*        (out, best source)
//	3 SOCKADDR_INET* destination
//
// Spelled out as constants so reordering the production list fails a test rather
// than silently following along.
const (
	argSlotDestination = 3
	argSlotBestRoute   = 5
	argSlotBestSource  = 6
	argSlotCount       = 7
)

// TestBestRoute2CallBindsTheDestinationFourth pins GetBestRoute2's parameter
// order. It is the assertion the original three-argument binding failed.
func TestBestRoute2CallBindsTheDestinationFourth(t *testing.T) {
	dst := net.ParseIP("192.168.1.115")
	sa, _, err := rawInet(dst)
	if err != nil {
		t.Fatalf("rawInet(%s): %v", dst, err)
	}
	var row windows.MibIpForwardRow2
	var bestSource windows.RawSockaddrInet

	call := newBestRoute2Call(&sa, &row, &bestSource)

	// The count is the first thing that went wrong, and the cheapest to pin:
	// three arguments left the kernel reading the address as a LUID.
	if len(call.args) != argSlotCount {
		t.Fatalf("GetBestRoute2 bound with %d arguments, want %d: %v",
			len(call.args), argSlotCount, call.args)
	}

	// Parameters 1-3 select the interface and must be absent so the routing table
	// decides. A non-zero LUID pins the lookup to one interface, which is the
	// opposite of what "where does this go today" means.
	for i, name := range []string{"InterfaceLuid", "InterfaceIndex", "SourceAddress"} {
		if call.args[i] != 0 {
			t.Errorf("GetBestRoute2 %s = %#x, want 0 (absent)", name, call.args[i])
		}
	}

	// Parameter 4 is the destination. Compare the raw slot against the address we
	// meant to pass: pointer-to-uintptr keeps provenance, so this is sound, and
	// it is the assertion that fails when the destination moves.
	if got := call.args[argSlotDestination]; got != uintptr(unsafe.Pointer(&sa)) {
		t.Errorf("GetBestRoute2 destination argument = %#x, want the bound SOCKADDR_INET %#x",
			got, uintptr(unsafe.Pointer(&sa)))
	}
	// And the buffer at that slot must name the address that was asked about.
	gotIP, err := rawInetIP(*call.dst)
	if err != nil {
		t.Fatalf("bound SOCKADDR_INET is unreadable: %v", err)
	}
	if !gotIP.Equal(dst) {
		t.Errorf("bound destination = %v, want %v", gotIP, dst)
	}

	// The out-parameters must be the caller's own buffers: the entry point writes
	// through them, and a null pointer for either is rejected outright.
	if call.row != &row {
		t.Error("BestRoute does not point at the caller's row")
	}
	if call.bestSource != &bestSource {
		t.Error("BestSourceAddress does not point at the caller's buffer")
	}
	if call.args[argSlotBestRoute] != uintptr(unsafe.Pointer(&row)) {
		t.Errorf("GetBestRoute2 BestRoute argument = %#x, want the caller's row %#x",
			call.args[argSlotBestRoute], uintptr(unsafe.Pointer(&row)))
	}
	if call.args[argSlotBestSource] != uintptr(unsafe.Pointer(&bestSource)) {
		t.Errorf("GetBestRoute2 BestSourceAddress argument = %#x, want the caller's buffer %#x",
			call.args[argSlotBestSource], uintptr(unsafe.Pointer(&bestSource)))
	}

	// The struct size belongs nowhere in this list. It was passed as the address
	// family, which is how the original call looked plausible.
	for i, a := range call.args {
		if i != argSlotDestination && a == unsafe.Sizeof(sa) {
			t.Errorf("argument %d is the SOCKADDR_INET size (%d); the entry point takes "+
				"an address family here, not a size", i, a)
		}
	}
}

// TestBestRouteReadsTheRowTheEntryPointWrote drives bestRoute end to end over the
// seam, so the argument list and the row read-back are checked together: a correct
// list that failed to plumb the row through would produce a tunnel with no
// interface to bind.
func TestBestRouteReadsTheRowTheEntryPointWrote(t *testing.T) {
	nextHop := net.ParseIP("192.168.1.1")
	original := callGetBestRoute2
	t.Cleanup(func() { callGetBestRoute2 = original })

	var seen bestRoute2Call
	callGetBestRoute2 = func(call bestRoute2Call) (uintptr, error) {
		seen = call
		call.row.InterfaceLuid = 42
		sa, _, err := rawInet(nextHop)
		if err != nil {
			t.Errorf("rawInet(%s): %v", nextHop, err)
		}
		call.row.NextHop = sa
		return 0, nil
	}

	route, err := liveWindowsRoutes{}.bestRoute(net.ParseIP("192.168.1.115"))
	if err != nil {
		t.Fatalf("bestRoute = %v", err)
	}
	if len(seen.args) != argSlotCount {
		t.Fatalf("bestRoute passed %d arguments, want %d", len(seen.args), argSlotCount)
	}
	if route.luid != 42 {
		t.Errorf("bestRoute luid = %d, want 42", route.luid)
	}
	if !route.nextHop.Equal(nextHop) {
		t.Errorf("bestRoute nextHop = %v, want %v", route.nextHop, nextHop)
	}
}

// TestBestRouteRejectsAnOnLinkRouteWithNoNextHop covers the fail-closed case: a
// directly-connected destination has no gateway, so there is nothing to pin a
// bypass route to and the daemon must refuse rather than install a route it cannot
// make work.
func TestBestRouteRejectsAnOnLinkRouteWithNoNextHop(t *testing.T) {
	original := callGetBestRoute2
	t.Cleanup(func() { callGetBestRoute2 = original })
	callGetBestRoute2 = func(call bestRoute2Call) (uintptr, error) {
		call.row.InterfaceLuid = 7
		// An unspecified NextHop is the table's way of saying "on-link".
		return 0, nil
	}

	_, err := liveWindowsRoutes{}.bestRoute(net.ParseIP("192.168.1.115"))
	if err == nil {
		t.Fatal("bestRoute accepted an on-link route with no next hop")
	}
	if !containsStr(err.Error(), "next hop") {
		t.Errorf("bestRoute error = %v, want it to name the missing next hop", err)
	}
}

// TestBestRouteTranslatesAFailureStatus covers the other half of the binding: a
// non-zero return is a NETIO_STATUS that must reach the caller as a wrapped error
// naming the destination, not as a silently ignored value.
func TestBestRouteTranslatesAFailureStatus(t *testing.T) {
	original := callGetBestRoute2
	t.Cleanup(func() { callGetBestRoute2 = original })
	callGetBestRoute2 = func(bestRoute2Call) (uintptr, error) {
		return uintptr(windows.STATUS_NOT_FOUND), nil
	}

	dst := net.ParseIP("203.0.113.10")
	_, err := liveWindowsRoutes{}.bestRoute(dst)
	if err == nil {
		t.Fatal("bestRoute returned nil error for a failing GetBestRoute2")
	}
	if !isMissingErrno(err) {
		t.Errorf("bestRoute error = %v, want a translated no-such-route", err)
	}
	// "Which address could not be routed" is the only actionable part of this
	// failure, so the destination has to be in the message.
	if !containsStr(err.Error(), dst.String()) {
		t.Errorf("bestRoute error = %v, want it to name the destination %s", err, dst)
	}
}

// containsStr is strings.Contains, kept local so this file does not import strings
// for three call sites.
func containsStr(haystack, needle string) bool {
	if len(needle) == 0 {
		return true
	}
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return true
		}
	}
	return false
}

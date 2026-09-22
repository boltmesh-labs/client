// Package tunnel owns the privileged WireGuard interface lifecycle. The
// client never runs privileged tooling or reads the device itself: it sends
// the wg-quick config text to the daemon and receives status (stage,
// handshake, counters, peer) back.
//
// Backends live in per-OS files: Linux drives `wg-quick` + `wgctrl`, Windows
// drives the WireGuard-for-Windows tunnel service + `wireguard.dll`. This
// file holds what both share.
package tunnel

import (
	"time"

	"boltmeshd/internal/protocol"
)

// DefaultInterface is the single interface the daemon manages. It is fixed
// here rather than taken from the client so no request can name an arbitrary
// interface.
const DefaultInterface = "boltmesh0"

// peer is the cross-platform projection of one WireGuard peer. Each backend
// fills it from its own device API.
type peer struct {
	publicKey     string
	endpoint      string
	lastHandshake time.Time
	rxBytes       int64
	txBytes       int64
}

// applyPeers folds peers into st: counters are summed across peers, and the
// peer with the newest handshake supplies PublicKey/Endpoint/LastHandshake.
// A zero handshake stays zero ("unknown"), never a fabricated timestamp.
func applyPeers(st *protocol.Status, peers []peer) {
	var newest time.Time
	for _, p := range peers {
		st.RxBytes += p.rxBytes
		st.TxBytes += p.txBytes
		if p.lastHandshake.After(newest) {
			newest = p.lastHandshake
			st.PublicKey = p.publicKey
			st.Endpoint = p.endpoint
		}
	}
	if !newest.IsZero() {
		st.LastHandshake = newest.Unix()
	}
}

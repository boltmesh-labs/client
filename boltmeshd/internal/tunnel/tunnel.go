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
	"context"
	"errors"
	"sync"
	"time"

	"boltmeshd/internal/protocol"
)

// DefaultInterface is the single interface the daemon manages. It is fixed
// here rather than taken from the client so no request can name an arbitrary
// interface.
const DefaultInterface = "boltmesh0"

// operationGate serializes privileged lifecycle operations in FIFO order.
// Waiters are cancellable: a request that gives up while queued is removed
// without ever entering the manager. The gate is held through bounded failure
// cleanup, so a retry cannot overlap a partially-applied tunnel transition.
type operationGate struct {
	mu      sync.Mutex
	next    uint64
	serving uint64
	owned   bool
	waiters map[uint64]*gateWaiter
}

type gateWaiter struct {
	ready   chan struct{}
	granted bool
}

const maxOperationWaiters = 128

func (g *operationGate) acquire(ctx context.Context) bool {
	if ctx.Err() != nil {
		return false
	}

	g.mu.Lock()
	if !g.owned && len(g.waiters) == 0 {
		g.serving = g.next
		g.next++
		g.owned = true
		g.mu.Unlock()
		if ctx.Err() != nil {
			g.release()
			return false
		}
		return true
	}
	if g.waiters == nil {
		g.waiters = make(map[uint64]*gateWaiter)
	}
	if len(g.waiters) >= maxOperationWaiters {
		g.mu.Unlock()
		return false
	}
	ticket := g.next
	g.next++
	waiter := &gateWaiter{ready: make(chan struct{})}
	g.waiters[ticket] = waiter
	g.mu.Unlock()

	select {
	case <-waiter.ready:
		g.mu.Lock()
		if ctx.Err() != nil {
			delete(g.waiters, ticket)
			g.advanceLocked()
			g.mu.Unlock()
			return false
		}
		delete(g.waiters, ticket)
		g.owned = true
		g.mu.Unlock()
		return true
	case <-ctx.Done():
		g.mu.Lock()
		if waiter.granted {
			// The grant and cancellation raced. Complete the handoff while
			// holding the gate lock so a new caller cannot acquire the slot
			// before this canceled waiter passes it on.
			delete(g.waiters, ticket)
			g.advanceLocked()
		} else {
			delete(g.waiters, ticket)
		}
		g.mu.Unlock()
		return false
	}
}

func (g *operationGate) release() {
	g.mu.Lock()
	g.owned = false
	g.advanceLocked()
	g.mu.Unlock()
}

// advanceLocked grants the next live waiter, skipping tickets whose callers
// canceled. The caller must hold g.mu.
func (g *operationGate) advanceLocked() {
	for g.serving < g.next {
		waiter, ok := g.waiters[g.serving]
		if !ok {
			g.serving++
			continue
		}
		waiter.granted = true
		close(waiter.ready)
		return
	}
}

func operationUnavailable(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return errors.New("another tunnel operation is already in progress")
}

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

package tunnel

import (
	"testing"
	"time"

	"boltmeshd/internal/protocol"
)

func TestApplyPeersSumsAndPicksNewest(t *testing.T) {
	st := &protocol.Status{Interface: DefaultInterface, Up: true, Stage: protocol.StageConnected}
	applyPeers(st, []peer{
		{publicKey: "older", endpoint: "203.0.113.10:51820", lastHandshake: time.Unix(1000, 0), rxBytes: 100, txBytes: 200},
		{publicKey: "newer", endpoint: "198.51.100.7:1234", lastHandshake: time.Unix(2000, 0), rxBytes: 5, txBytes: 6},
	})

	if st.RxBytes != 105 || st.TxBytes != 206 {
		t.Fatalf("counters = rx %d tx %d, want 105/206", st.RxBytes, st.TxBytes)
	}
	if st.LastHandshake != 2000 {
		t.Fatalf("lastHandshake = %d, want 2000", st.LastHandshake)
	}
	if st.PublicKey != "newer" || st.Endpoint != "198.51.100.7:1234" {
		t.Fatalf("peer = %q %q, want the newest", st.PublicKey, st.Endpoint)
	}
}

func TestApplyPeersKeepsZeroHandshakeUnknown(t *testing.T) {
	st := &protocol.Status{Interface: DefaultInterface, Up: true, Stage: protocol.StageConnected}
	applyPeers(st, []peer{{publicKey: "k", endpoint: "e", rxBytes: 1, txBytes: 2}})

	if st.LastHandshake != 0 {
		t.Fatalf("lastHandshake = %d, want 0 (unknown)", st.LastHandshake)
	}
	if st.PublicKey != "" || st.Endpoint != "" {
		t.Fatalf("peer = %q %q, want empty for a never-handshook peer", st.PublicKey, st.Endpoint)
	}
	if st.RxBytes != 1 || st.TxBytes != 2 {
		t.Fatalf("counters = rx %d tx %d, want 1/2", st.RxBytes, st.TxBytes)
	}
}

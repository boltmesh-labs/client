package tunnel

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
	"time"
)

// This file translates between the wg-quick config text the client sends and
// the UAPI wire format spoken by `wireguard-go`.
//
// It exists because macOS has no kernel WireGuard and `wgctrl` has no darwin
// backend, so the macOS backend must run `wireguard-go` in userspace over a
// `utun` device and drive it over its UAPI socket — the same shape the
// upstream WireGuard macOS app uses. The translation is deliberately free of
// any OS-specific code so it is unit-testable everywhere, including the Linux
// and Windows CI runners that cannot build or run the darwin backend.

// uapiDevice is the `GET=1` response: the device's own settings plus its peer
// table. Key material arrives hex-encoded and base64 in the wg-quick config.
type uapiDevice struct {
	ListenPort int        `json:"listen_port"`
	Peers      []uapiPeer `json:"peers"`
}

type uapiPeer struct {
	PublicKey                   string   `json:"public_key"`
	Endpoint                    uapiAddr `json:"endpoint"`
	ProtocolVersion             int      `json:"protocol_version"`
	LastHandshakeTimeSec        int64    `json:"last_handshake_time_sec"`
	LastHandshakeTimeNSec       int64    `json:"last_handshake_time_nsec"`
	RxBytes                     int64    `json:"rx_bytes"`
	TxBytes                     int64    `json:"tx_bytes"`
	PersistentKeepaliveInterval int      `json:"persistent_keepalive_interval"`
}

// uapiAddr is the UAPI endpoint union. Only one family is ever populated.
type uapiAddr struct {
	V4 string `json:"v4,omitempty"`
	V6 string `json:"v6,omitempty"`
}

// String renders the populated family, or "" when neither is set (a peer with
// no endpoint yet, which is normal before the first handshake).
func (a uapiAddr) String() string {
	if a.V4 != "" {
		return a.V4
	}
	return a.V6
}

// uapiKeyValue is the `set=1` request: an ordered key=value stream. The device
// protocol is line-oriented and order-sensitive — a peer's public_key must
// precede its endpoint and allowed_ips.
type uapiKeyValue struct {
	lines []string
}

func (k *uapiKeyValue) add(key, value string) {
	k.lines = append(k.lines, key+"="+value)
}

// bytes renders the request body, including the trailing newline the device
// requires to consider the message complete.
func (k *uapiKeyValue) bytes() []byte {
	return []byte(strings.Join(k.lines, "\n") + "\n")
}

// uapiDirective is one parsed wg-quick directive, with the section it came
// from. Multi-valued keys (Address, AllowedIPs) keep every value.
type uapiDirective struct {
	section string
	key     string
	value   string
}

// parseWgQuick splits validated wg-quick text into ordered directives. The
// caller must have run config.Validate first, so hooks and unknown directives
// are already rejected; this only needs the structure.
func parseWgQuick(text string) []uapiDirective {
	var out []uapiDirective
	section := ""
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(strings.Trim(line, "[]"))
			continue
		}
		rawKey, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		out = append(out, uapiDirective{
			section: section,
			key:     strings.ToLower(strings.TrimSpace(rawKey)),
			value:   strings.TrimSpace(value),
		})
	}
	return out
}

// ConfigToUAPI renders a validated wg-quick config as a UAPI `set=1` body.
//
// Two directives carry meaning on Linux that the device has no concept of,
// and are deliberately dropped rather than approximated:
//
//   - `Address` — the device never assigns interface addresses; the backend
//     does that with `ifconfig`, so passing it would be rejected as unknown.
//   - `DNS` — resolver state belongs to the OS, and configuring it from the
//     device protocol is not possible. The macOS backend sets and reverts the
//     system resolver itself around the tunnel lifecycle.
//
// Passing them as unknown keys would make the device reject the whole request,
// so dropping them here is what lets the same client config drive every
// backend.
func ConfigToUAPI(text string) ([]byte, error) {
	directives := parseWgQuick(text)
	request := &uapiKeyValue{}

	var (
		sawPrivateKey bool
	)

	// Peers are grouped so a public key can be emitted once, followed by its
	// endpoint/keepalive/allowed_ips. The device treats a bare public_key as
	// the start of a new peer block.
	emitPeer := func(pd string, values []uapiDirective) error {
		if len(values) == 0 {
			return errors.New("peer has no public key")
		}
		request.add("public_key", pd)
		for _, d := range values {
			switch d.key {
			case "presharedkey":
				if err := addHexKey(request, "preshared_key", d.value); err != nil {
					return err
				}
			case "endpoint":
				endpoint, err := normalizeEndpoint(d.value)
				if err != nil {
					return err
				}
				request.add("endpoint", endpoint)
			case "persistentkeepalive":
				seconds, err := strconv.Atoi(d.value)
				if err != nil {
					return fmt.Errorf("invalid PersistentKeepalive %q", d.value)
				}
				request.add("persistent_keepalive_interval", strconv.Itoa(seconds))
			case "allowedips":
				for _, cidr := range strings.Split(d.value, ",") {
					cidr = strings.TrimSpace(cidr)
					if cidr == "" {
						continue
					}
					if _, _, err := net.ParseCIDR(cidr); err != nil {
						return fmt.Errorf("invalid AllowedIP %q", cidr)
					}
					request.add("allowed_ip", cidr)
				}
			}
		}
		return nil
	}

	var (
		currentPeer   []uapiDirective
		flushedPeers  bool
		pendingPubKey string
	)
	flushPeer := func() error {
		if len(currentPeer) == 0 {
			return nil
		}
		if err := emitPeer(pendingPubKey, currentPeer); err != nil {
			return err
		}
		currentPeer = nil
		return nil
	}

	for _, d := range directives {
		switch d.section {
		case "interface":
			// A [Interface] after a [Peer] would make the peer block ambiguous.
			if err := flushPeer(); err != nil {
				return nil, err
			}
			switch d.key {
			case "privatekey":
				if err := addHexKey(request, "private_key", d.value); err != nil {
					return nil, err
				}
				sawPrivateKey = true
			case "listenport":
				port, err := strconv.Atoi(d.value)
				if err != nil {
					return nil, fmt.Errorf("invalid ListenPort %q", d.value)
				}
				request.add("listen_port", strconv.Itoa(port))
			}
			// address/dns/fwmark/mtu/table are Linux-shaped and skipped.
		case "peer":
			if d.key == "publickey" {
				if err := flushPeer(); err != nil {
					return nil, err
				}
				key, err := hexKey(d.value)
				if err != nil {
					return nil, fmt.Errorf("invalid PublicKey: %w", err)
				}
				pendingPubKey = key
				flushedPeers = true
				continue
			}
			currentPeer = append(currentPeer, d)
		}
	}
	if err := flushPeer(); err != nil {
		return nil, err
	}

	if !sawPrivateKey {
		return nil, errors.New("config is missing [Interface] PrivateKey")
	}
	if !flushedPeers || pendingPubKey == "" {
		return nil, errors.New("config is missing a [Peer] PublicKey")
	}
	return request.bytes(), nil
}

// addHexKey decodes a base64 WireGuard key from the wg-quick config and emits
// its hex form, which is what the UAPI protocol speaks.
func addHexKey(request *uapiKeyValue, uapiKey, base64Key string) error {
	hexKey, err := hexKey(base64Key)
	if err != nil {
		return fmt.Errorf("invalid %s: %w", uapiKey, err)
	}
	request.add(uapiKey, hexKey)
	return nil
}

// wireguardKeyLen is the length of a WireGuard key: Curve25519 keys are 32
// bytes. Accepting a shorter decodable string would let a malformed peer
// through as if it were valid, and the device would then fail the whole
// request rather than rejecting that one peer.
const wireguardKeyLen = 32

// hexKey normalizes a base64 (or already-hex) key to the lowercase hex the
// UAPI protocol expects. Accepting hex too keeps the function usable against a
// `GET=1` dump, which reports keys in hex. The decoded key must be exactly
// [wireguardKeyLen] bytes.
func hexKey(key string) (string, error) {
	trimmed := strings.TrimSpace(key)
	if trimmed == "" {
		return "", errors.New("key is empty")
	}
	// Hex keys are exactly 64 characters; base64 keys for 32 bytes are 44.
	if len(trimmed) == wireguardKeyLen*2 {
		if raw, err := hex.DecodeString(trimmed); err == nil && len(raw) == wireguardKeyLen {
			return strings.ToLower(trimmed), nil
		}
	}
	raw, err := base64.StdEncoding.DecodeString(trimmed)
	if err != nil {
		// Tolerate unpadded base64, which some producers emit.
		raw, err = base64.RawStdEncoding.DecodeString(trimmed)
		if err != nil {
			return "", err
		}
	}
	if len(raw) != wireguardKeyLen {
		return "", fmt.Errorf("key is %d bytes, want %d", len(raw), wireguardKeyLen)
	}
	return hex.EncodeToString(raw), nil
}

// normalizeEndpoint validates a wg-quick Endpoint and re-renders it in the
// bracketed form the UAPI protocol expects. Splitting strips the brackets from
// an IPv6 literal, so rejoining naively would produce the ambiguous
// "2001:db8::1:51820" that no parser can read back.
func normalizeEndpoint(endpoint string) (string, error) {
	host, port, err := net.SplitHostPort(endpoint)
	if err != nil {
		return "", fmt.Errorf("invalid Endpoint %q", endpoint)
	}
	if host == "" {
		return "", fmt.Errorf("endpoint %q has no host", endpoint)
	}
	if port == "" {
		return "", fmt.Errorf("endpoint %q has no port", endpoint)
	}
	// A host that is itself bracketed, or a literal IPv6 address, needs its
	// brackets back.
	if strings.Contains(host, ":") {
		return net.JoinHostPort(strings.Trim(host, "[]"), port), nil
	}
	return net.JoinHostPort(host, port), nil
}

// ParseUAPIPeers projects a `GET=1` response into the cross-platform peer
// list. A handshake timestamp of zero (never completed) stays zero, so
// [applyPeers] reports "unknown" rather than a fabricated time.
func ParseUAPIPeers(data []byte) ([]peer, error) {
	var device uapiDevice
	if err := json.Unmarshal(data, &device); err != nil {
		return nil, fmt.Errorf("decode UAPI device state: %w", err)
	}
	peers := make([]peer, 0, len(device.Peers))
	for _, p := range device.Peers {
		key, err := hexKey(p.PublicKey)
		if err != nil {
			// A peer whose key does not parse cannot be attributed; skip it
			// rather than failing the whole status read, which would turn a
			// single odd entry into an unknown tunnel.
			continue
		}
		peers = append(peers, peer{
			publicKey:     key,
			endpoint:      p.Endpoint.String(),
			lastHandshake: uapiHandshake(p),
			rxBytes:       p.RxBytes,
			txBytes:       p.TxBytes,
		})
	}
	// Stable order keeps status reads reproducible for the client.
	sort.SliceStable(peers, func(i, j int) bool {
		return peers[i].publicKey < peers[j].publicKey
	})
	return peers, nil
}

// uapiHandshake reconstructs the handshake instant from the split
// sec/nsec fields, or the zero time when no handshake has completed.
func uapiHandshake(p uapiPeer) time.Time {
	if p.LastHandshakeTimeSec == 0 && p.LastHandshakeTimeNSec == 0 {
		return time.Time{}
	}
	return time.Unix(p.LastHandshakeTimeSec, p.LastHandshakeTimeNSec)
}

// FormatPeersAsUAPI renders a peer list back into a `GET=1`-shaped response.
// It exists so the device-response contract can be tested without a real
// wireguard-go device, and so a future backend can be compared against a
// recorded dump.
func FormatPeersAsUAPI(listenPort int, peers []peer) []byte {
	device := uapiDevice{ListenPort: listenPort}
	for _, p := range peers {
		entry := uapiPeer{
			PublicKey:       p.publicKey,
			RxBytes:         p.rxBytes,
			TxBytes:         p.txBytes,
			ProtocolVersion: 1,
		}
		if host, port, err := net.SplitHostPort(p.endpoint); err == nil && p.endpoint != "" {
			if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
				entry.Endpoint.V4 = net.JoinHostPort(host, port)
			} else {
				entry.Endpoint.V6 = net.JoinHostPort(host, port)
			}
		}
		if !p.lastHandshake.IsZero() {
			entry.LastHandshakeTimeSec = p.lastHandshake.Unix()
			entry.LastHandshakeTimeNSec = int64(p.lastHandshake.Nanosecond())
		}
		device.Peers = append(device.Peers, entry)
	}
	data, err := json.Marshal(device)
	if err != nil {
		// Only reachable with unmarshalable contents, which the struct above
		// cannot produce; return an empty dump rather than panicking.
		return []byte(`{"listen_port":0,"peers":[]}`)
	}
	return data
}

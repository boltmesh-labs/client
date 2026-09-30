package tunnel

// Shared test fixtures used by both the Linux and Windows manager tests.

const (
	keyA = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	keyB = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
)

const validConfig = `[Interface]
PrivateKey = ` + keyA + `
Address = 10.8.0.5/32
DNS = 10.8.0.1

[Peer]
PublicKey = ` + keyB + `
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`

// obfuscatedConfig is validConfig plus a complete AmneziaWG obfuscation set
// (all-or-none by validation). The parameter values mirror the canonical
// example the control plane generates.
const obfuscatedConfig = `[Interface]
PrivateKey = ` + keyA + `
Address = 10.8.0.5/32
DNS = 10.8.0.1
Jc = 3
Jmin = 40
Jmax = 70
S1 = 15
S2 = 17
S3 = 10
S4 = 5
H1 = 115-120
H2 = 130
H3 = 150-160
H4 = 171

[Peer]
PublicKey = ` + keyB + `
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`

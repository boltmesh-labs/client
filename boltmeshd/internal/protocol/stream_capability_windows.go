//go:build windows

package protocol

// streamTransportCap is the capability token for the stream transport on this
// build. The Windows backend owns the transport lifecycle and pins its server
// through the physical path with a /32 host route, which wins over the tunnel
// adapter's default route on longest-prefix match, so Windows advertises the
// token.
//
// The caveat that matters is the inner format: this token says the *transport*
// can run, not that an obfuscated region's datagrams can be produced. The
// kernel tunnel service Windows drives has no concept of the AmneziaWG
// directives, so the AWG data plane is still Linux-only. On a stock region the
// two are independent and the stream rung works; on an obfuscated one the
// client refuses the region before it ever selects this rung.
const streamTransportCap = CapStreamTransport

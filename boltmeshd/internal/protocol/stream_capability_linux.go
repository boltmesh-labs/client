//go:build linux

package protocol

// streamTransportCap is the capability token for the stream transport on a
// build whose data plane can run it. The Linux tunnel backend owns the
// transport lifecycle and its bypass route, so Linux advertises the token.
const streamTransportCap = CapStreamTransport

//go:build !linux

package protocol

// streamTransportCap is empty on every build whose data plane cannot run the
// stream transport: the transport lifecycle and its bypass route live in the
// Linux backend, and the Windows and macOS backends reject a transport spec
// outright rather than ignore it (an ignored spec would leave the tunnel on a
// dead loopback endpoint). Advertising the token here would let a client select
// a rung that is guaranteed to be refused.
const streamTransportCap = ""

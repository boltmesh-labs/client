#ifndef RUNNER_TUNNEL_HOST_H_
#define RUNNER_TUNNEL_HOST_H_

namespace flutter {
class FlutterEngine;
}  // namespace flutter

namespace boltmesh {

// Registers the app's own native tunnel channels on |engine|:
//
//   com.boltmesh/handshake -> getLastHandshake  (epoch seconds, or null)
//   com.boltmesh/tunnel    -> getActivePeer, killGhost
//
// Mirrors the Android `TunnelHost` contract (see `client/README.md` and
// `client/lib/features/vpn/data/tunnel_adapter.dart`). Safe to call once per
// engine; repeated calls are no-ops.
void RegisterTunnelHost(flutter::FlutterEngine* engine);

}  // namespace boltmesh

#endif  // RUNNER_TUNNEL_HOST_H_

#ifndef RUNNER_HELPER_PIPE_H_
#define RUNNER_HELPER_PIPE_H_

namespace flutter {
class FlutterEngine;
}  // namespace flutter

namespace boltmesh {

// Registers the app's transport to the privileged boltmeshd helper on
// |engine|:
//
//   com.boltmesh/helper -> exchange(jsonLine) -> jsonLine
//
// `dart:io` has no Windows named-pipe client, so this native channel performs
// one newline-delimited JSON exchange over `\\.\pipe\boltmesh\boltmeshd` and
// returns the single response line. The framing matches the daemon's Unix
// socket on Linux, so both transports share the same server code. Safe to
// call once per engine; repeated calls are no-ops.
void RegisterHelperPipe(flutter::FlutterEngine* engine);

}  // namespace boltmesh

#endif  // RUNNER_HELPER_PIPE_H_

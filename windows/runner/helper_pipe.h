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
// socket on Linux, so both transports share the same server code. The exchange
// runs on a worker thread and completes the Dart future on the platform
// thread, so a wedged helper never blocks the window. Safe to call once per
// engine; repeated calls are no-ops.
void RegisterHelperPipe(flutter::FlutterEngine* engine);

// Stops new helper exchanges from posting back to the engine. Must be called
// on the platform thread before the engine (owned by the FlutterViewController)
// is destroyed, e.g. from FlutterWindow::OnDestroy. In-flight workers either
// post their outcome before this returns or drop it; a post the engine's task
// runner never runs is cancelled with the engine.
void ShutdownHelperPipe();

}  // namespace boltmesh

#endif  // RUNNER_HELPER_PIPE_H_

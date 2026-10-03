#ifndef RUNNER_HELPER_PIPE_H_
#define RUNNER_HELPER_PIPE_H_

#include <windows.h>

namespace flutter {
class FlutterEngine;
}  // namespace flutter

namespace boltmesh {

// Window message a worker uses to hand its outcome back to the platform thread.
//
// This deliberately does not use flutter::FlutterEngine::PostPlatformThreadTask.
// That helper heap-allocates the posted callable and frees it from a
// cancellation handler if the engine is torn down before the task runs; on a
// machine whose GPU device is lost (which is what this app can hit under RDP on
// a virtualised adapter) the platform thread can still run the task afterwards,
// invoking a freed std::function and faulting inside the engine's trampoline.
// A window message is delivered by the same thread that owns the MethodResult
// and carries no engine-owned storage, so there is nothing to free underneath
// it. See helper_pipe.cpp for the full note.
constexpr UINT kHelperOutcomeMessage = WM_APP + 1;

// Registers the app's transport to the privileged boltmeshd helper on
// |engine|, delivering worker outcomes to |window|:
//
//   com.boltmesh/helper -> exchange(jsonLine) -> jsonLine
//
// `dart:io` has no Windows named-pipe client, so this native channel performs
// one newline-delimited JSON exchange over `\\.\pipe\boltmesh\boltmeshd` and
// returns the single response line. The framing matches the daemon's Unix
// socket on Linux, so both transports share the same server code. The exchange
// runs on a worker thread and completes the Dart future on the platform thread,
// so a wedged helper never blocks the window. Safe to call once per engine;
// repeated calls are no-ops.
void RegisterHelperPipe(flutter::FlutterEngine* engine, HWND window);

// Completes one outcome on the platform thread. |outcome| is the pointer a
// worker passed as the lParam of kHelperOutcomeMessage; this function takes
// ownership of it. Called from the runner's window procedure.
void CompleteHelperPipeOutcome(void* outcome);

// Stops new helper exchanges from delivering outcomes, and drains any already
// queued so none is left pending against a destroyed window. Must be called on
// the platform thread before the window is destroyed, e.g. from
// FlutterWindow::OnDestroy.
void ShutdownHelperPipe();

}  // namespace boltmesh

#endif  // RUNNER_HELPER_PIPE_H_

#ifndef RUNNER_HELPER_PIPE_IO_H_
#define RUNNER_HELPER_PIPE_IO_H_

#include <cstddef>
#include <string>

namespace boltmesh {
namespace io {

// The named pipe the privileged boltmeshd daemon listens on.
inline constexpr wchar_t kHelperPipe[] = L"\\\\.\\pipe\\boltmesh\\boltmeshd";

// Upper bound on one complete pipe exchange (connect, write, and read). A
// wedged daemon must surface as a transport failure, never as a blocked
// platform thread.
inline constexpr unsigned long kIoTimeoutMs = 10000;
// Do not let an untrusted Dart caller turn the native exchange into an
// unbounded wait.
inline constexpr unsigned long kMaxIoTimeoutMs = 60000;

// How long to wait for the pipe to appear when the daemon is still starting.
inline constexpr unsigned long kConnectWaitMs = 2000;

// Hard cap on one response line, matching the daemon's request cap.
inline constexpr std::size_t kMaxResponseBytes = 128 * 1024;

// ExchangePipe sends one request line (request + '\n') over the named pipe and
// returns the first response line with its trailing newline stripped. It
// returns false when the pipe is unreachable, the I/O fails, or the complete
// exchange exceeds the timeout.
//
// This is kept free of Flutter so the framing and correlation logic can be
// exercised by a standalone test binary (tests/helper_pipe_io_test.cpp).
bool ExchangePipe(const wchar_t* pipe_name, const std::string& request,
                  std::string* response,
                  unsigned long timeout_ms = kIoTimeoutMs,
                  unsigned long connect_wait_ms = kConnectWaitMs);

}  // namespace io
}  // namespace boltmesh

#endif  // RUNNER_HELPER_PIPE_IO_H_

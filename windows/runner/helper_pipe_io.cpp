// Named-pipe transport to the privileged boltmeshd helper.
//
// The daemon runs as LocalSystem and serves the same newline-delimited JSON
// protocol as the Linux Unix socket, but over a named pipe. `dart:io` has no
// Windows named-pipe client, so the runner performs the exchange here and
// hands the response line back to Dart through the `com.boltmesh/helper`
// channel (see helper_pipe.cpp).
//
// Deliberately Flutter-free: tests/helper_pipe_io_test.cpp links this file
// directly and drives it against a local pipe server.
#include "helper_pipe_io.h"

#define WIN32_LEAN_AND_MEAN

#include <process.h>
#include <windows.h>
#include <winsvc.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace boltmesh {
namespace io {
namespace {

using TickCount = ULONGLONG;
constexpr unsigned long kDrainTimeoutMs = 1000;

// The Windows service the privileged helper registers as (see
// boltmeshd/cmd/boltmeshd/main_windows.go). Binding the pipe's server process
// to this service is how the unprivileged client tells the real boltmeshd from
// a local process that pre-created the pipe name: the SCM reports the actual
// process id of the running service, and registering or repointing a service
// requires administrator rights.
constexpr wchar_t kHelperServiceName[] = L"boltmeshd";

TickCount DeadlineAfter(unsigned long timeout_ms) {
  return GetTickCount64() + timeout_ms;
}

unsigned long RemainingMs(TickCount deadline) {
  const TickCount now = GetTickCount64();
  if (now >= deadline) return 0;
  const TickCount remaining = deadline - now;
  return remaining > MAXDWORD
             ? MAXDWORD
             : static_cast<unsigned long>(remaining);
}

// One overlapped operation and everything the kernel touches while it is in
// flight. It lives on the heap rather than the caller's stack so it can outlive
// the call that started it: CancelIoEx only marks the operation for
// cancellation, and the kernel may keep writing the completion status into
// `overlapped`, signalling `event`, and reading/writing `buffer` after the
// caller's deadline has passed. Freeing any of that early is a use-after-free.
struct OverlappedOp {
  OverlappedOp()
      : overlapped{}, event(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {
    overlapped.hEvent = event;
  }
  ~OverlappedOp() {
    if (event != nullptr) CloseHandle(event);
  }

  OVERLAPPED overlapped;
  HANDLE event;
  // Owns the bytes the kernel accesses. The write payload is copied in so a
  // still-pending IRP cannot reach into a caller buffer that has been freed.
  std::vector<char> buffer;

  bool valid() const { return event != nullptr; }
};

// ReapThread frees an operation once the kernel has signalled its completion
// event. It is what makes the drain timeout safe: a slow or non-cancellable
// provider keeps the operation alive until it is genuinely finished. It uses
// the CRT (_beginthreadex) because destroying the operation touches the C++
// runtime.
unsigned WINAPI ReapThread(void* param) {
  auto* op = static_cast<OverlappedOp*>(param);
  WaitForSingleObject(op->event, INFINITE);
  delete op;
  return 0;
}

// RetireOverlapped gives up the caller's ownership of an operation whose
// cancellation could not be confirmed. The OVERLAPPED/buffer must not be
// destroyed while the kernel may still use them, so the reaper watches the
// completion event instead. If no reaper thread can be started the operation is
// deliberately leaked: a small, bounded leak is strictly safer than a
// use-after-free.
void RetireOverlapped(OverlappedOp* op) {
  const uintptr_t thread =
      _beginthreadex(nullptr, 0, ReapThread, op, 0, nullptr);
  if (thread != 0) {
    CloseHandle(reinterpret_cast<HANDLE>(thread));
  }
}

// WaitOverlapped waits for one overlapped operation. When it does not complete
// within timeout_ms it requests cancellation and waits one bounded drain
// interval. true means the operation completed and `*op` is still caller-owned.
// false means it failed; when the kernel might still be using it, ownership has
// been retired and `*op` is left null so the caller cannot free it.
bool WaitOverlapped(HANDLE pipe, std::unique_ptr<OverlappedOp>* op,
                    unsigned long timeout_ms, DWORD* transferred) {
  OverlappedOp* current = op->get();
  if (WaitForSingleObject(current->event, timeout_ms) == WAIT_OBJECT_0) {
    return GetOverlappedResult(pipe, &current->overlapped, transferred, FALSE) !=
           0;
  }
  // A timeout or a wait failure are both "not confirmed complete"; ask for
  // cancellation either way. CancelIoEx is asynchronous, so its return does not
  // let us free anything.
  CancelIoEx(pipe, &current->overlapped);
  // The completion event is the only proof the kernel has stopped touching our
  // memory. A fixed drain bound on its own is not a completion guarantee, so if
  // it expires without the event we hand the operation to a reaper.
  if (WaitForSingleObject(current->event, kDrainTimeoutMs) == WAIT_OBJECT_0) {
    return false;
  }
  RetireOverlapped(op->release());
  return false;
}

bool WriteAll(HANDLE pipe, const std::string& data, TickCount deadline) {
  size_t offset = 0;
  while (offset < data.size()) {
    const unsigned long remaining = RemainingMs(deadline);
    if (remaining == 0) return false;
    const size_t left = data.size() - offset;
    const DWORD chunk =
        static_cast<DWORD>(left < 64 * 1024 ? left : 64 * 1024);

    // The IRP reads from op->buffer, so the payload must be owned by the
    // operation and outlive it.
    auto op = std::make_unique<OverlappedOp>();
    if (!op->valid()) return false;
    op->buffer.assign(data.data() + offset, data.data() + offset + chunk);

    const BOOL started =
        WriteFile(pipe, op->buffer.data(), chunk, nullptr, &op->overlapped);
    DWORD written = 0;
    bool ok = false;
    if (started) {
      ok = WaitOverlapped(pipe, &op, remaining, &written);
    } else if (GetLastError() == ERROR_IO_PENDING) {
      ok = WaitOverlapped(pipe, &op, remaining, &written);
    }
    // If WaitOverlapped retired the operation, `op` is null and the reaper owns
    // it; a failed start never issued an IRP, so destroying it is safe.
    if (!ok || written == 0) return false;
    offset += written;
  }
  return true;
}

// ReadLine reads until the first '\n' or the response cap, whichever comes
// first. The trailing newline is stripped.
bool ReadLine(HANDLE pipe, std::string* out, TickCount deadline) {
  out->clear();
  while (out->size() <= kMaxResponseBytes) {
    const unsigned long remaining = RemainingMs(deadline);
    if (remaining == 0) return false;

    auto op = std::make_unique<OverlappedOp>();
    if (!op->valid()) return false;
    op->buffer.resize(4096);

    const BOOL started =
        ReadFile(pipe, op->buffer.data(), static_cast<DWORD>(op->buffer.size()),
                 nullptr, &op->overlapped);
    DWORD read = 0;
    bool ok = false;
    if (started) {
      ok = WaitOverlapped(pipe, &op, remaining, &read);
    } else if (GetLastError() == ERROR_IO_PENDING) {
      ok = WaitOverlapped(pipe, &op, remaining, &read);
    }
    if (!ok || read == 0) return false;

    out->append(op->buffer.data(), read);
    const size_t newline = out->find('\n');
    if (newline != std::string::npos) {
      out->resize(newline);
      return true;
    }
  }
  return false;
}

// ServerProcessId returns the process id of the connected pipe's server end, or
// false when the query fails.
bool ServerProcessId(HANDLE pipe, DWORD* pid) {
  ULONG server = 0;
  if (!GetNamedPipeServerProcessId(pipe, &server) || server == 0) return false;
  *pid = static_cast<DWORD>(server);
  return true;
}

// ServiceProcessId returns the process id the service control manager reports
// for a running service. It returns false when the service is missing, stopped,
// or not queryable by this caller.
bool ServiceProcessId(const wchar_t* service_name, DWORD* pid) {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) return false;
  SC_HANDLE service =
      OpenServiceW(manager, service_name, SERVICE_QUERY_STATUS);
  if (service == nullptr) {
    CloseServiceHandle(manager);
    return false;
  }
  SERVICE_STATUS_PROCESS status{};
  DWORD needed = 0;
  const BOOL queried =
      QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
                           reinterpret_cast<LPBYTE>(&status),
                           static_cast<DWORD>(sizeof(status)), &needed);
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  if (!queried || status.dwProcessId == 0) return false;
  *pid = status.dwProcessId;
  return true;
}

// VerifyPipeServer authenticates the connected pipe's server: it must be the
// process the SCM started for the privileged boltmeshd service. A local process
// that squatted the predictable pipe name is rejected here, before the request
// (which may carry the WireGuard private key) is written.
//
// The check is a process-id comparison rather than a token image/path query
// because a standard user cannot open a LocalSystem process to read either; the
// SCM, which only an administrator can repoint, is the trust anchor instead.
bool VerifyPipeServer(HANDLE pipe) {
  DWORD server_pid = 0;
  if (!ServerProcessId(pipe, &server_pid)) return false;
  DWORD service_pid = 0;
  if (!ServiceProcessId(kHelperServiceName, &service_pid)) return false;
  return server_pid == service_pid;
}

HANDLE OpenPipe(const wchar_t* pipe_name, unsigned long connect_wait_ms) {
  const DWORD access = GENERIC_READ | GENERIC_WRITE;
  HANDLE pipe = CreateFileW(pipe_name, access, 0, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED, nullptr);
  if (pipe != INVALID_HANDLE_VALUE) return pipe;
  // The daemon may still be starting; wait briefly for the pipe, then retry.
  if (!WaitNamedPipeW(pipe_name, connect_wait_ms)) return INVALID_HANDLE_VALUE;
  return CreateFileW(pipe_name, access, 0, nullptr, OPEN_EXISTING,
                     FILE_FLAG_OVERLAPPED, nullptr);
}

// ExchangePipeImpl is the shared transport. authenticate_peer is true for the
// public entry point; only the standalone test passes false.
bool ExchangePipeImpl(const wchar_t* pipe_name, const std::string& request,
                      std::string* response, unsigned long timeout_ms,
                      unsigned long connect_wait_ms, bool authenticate_peer) {
  const TickCount deadline = DeadlineAfter(timeout_ms);
  HANDLE pipe = OpenPipe(pipe_name, std::min(RemainingMs(deadline),
                                             connect_wait_ms));
  if (pipe == INVALID_HANDLE_VALUE) return false;

  // Authenticate before writing: the request for `up` carries the WireGuard
  // private key, so a rejected impostor must never receive a byte.
  if (authenticate_peer && !VerifyPipeServer(pipe)) {
    CloseHandle(pipe);
    return false;
  }

  const bool ok = WriteAll(pipe, request + "\n", deadline) &&
                  ReadLine(pipe, response, deadline);
  CloseHandle(pipe);
  return ok;
}

}  // namespace

bool ExchangePipe(const wchar_t* pipe_name, const std::string& request,
                  std::string* response, unsigned long timeout_ms,
                  unsigned long connect_wait_ms) {
  return ExchangePipeImpl(pipe_name, request, response, timeout_ms,
                          connect_wait_ms, true);
}

#ifdef BOLTMESH_HELPER_PIPE_TEST
// Test-only entry point: the framing path without peer authentication. The
// standalone test cannot run a server as the boltmeshd service, so it drives
// this to cover the transport. It is compiled only into the test binary (see
// windows/runner/CMakeLists.txt); the app never links it.
bool ExchangePipeUnverified(const wchar_t* pipe_name,
                            const std::string& request, std::string* response,
                            unsigned long timeout_ms,
                            unsigned long connect_wait_ms) {
  return ExchangePipeImpl(pipe_name, request, response, timeout_ms,
                          connect_wait_ms, false);
}
#endif

}  // namespace io
}  // namespace boltmesh

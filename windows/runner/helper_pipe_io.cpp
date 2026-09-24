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

#include <windows.h>

#include <algorithm>
#include <cstdint>
#include <string>

namespace boltmesh {
namespace io {
namespace {

using TickCount = ULONGLONG;
constexpr unsigned long kDrainTimeoutMs = 1000;

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

// WaitOverlapped waits for one overlapped operation. On timeout it cancels the
// operation and bounds the completion drain so the caller's deadline remains
// authoritative.
bool WaitOverlapped(HANDLE pipe, OVERLAPPED* overlapped,
                    unsigned long timeout_ms, DWORD* transferred) {
  if (WaitForSingleObject(overlapped->hEvent, timeout_ms) != WAIT_OBJECT_0) {
    CancelIoEx(pipe, overlapped);
    // Never let a stuck provider turn the caller's timeout into an
    // uninterruptible platform-thread wait. Closing the pipe below cancels
    // any operation that did not report completion during the drain.
    (void)WaitForSingleObject(overlapped->hEvent, kDrainTimeoutMs);
    return false;
  }
  return GetOverlappedResult(pipe, overlapped, transferred, FALSE) != 0;
}

bool WriteAll(HANDLE pipe, const std::string& data, TickCount deadline) {
  size_t offset = 0;
  while (offset < data.size()) {
    const unsigned long remaining = RemainingMs(deadline);
    if (remaining == 0) return false;
    const DWORD chunk = static_cast<DWORD>(
        (data.size() - offset) < 64 * 1024 ? (data.size() - offset) : 64 * 1024);
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) return false;

    const BOOL started =
        WriteFile(pipe, data.data() + offset, chunk, nullptr, &overlapped);
    DWORD written = 0;
    bool ok = false;
    if (started) {
      ok = WaitOverlapped(pipe, &overlapped, remaining, &written);
    } else if (GetLastError() == ERROR_IO_PENDING) {
      ok = WaitOverlapped(pipe, &overlapped, remaining, &written);
    }
    CloseHandle(overlapped.hEvent);
    if (!ok || written == 0) return false;
    offset += written;
  }
  return true;
}

// ReadLine reads until the first '\n' or the response cap, whichever comes
// first. The trailing newline is stripped.
bool ReadLine(HANDLE pipe, std::string* out, TickCount deadline) {
  out->clear();
  char buffer[4096];
  while (out->size() <= kMaxResponseBytes) {
    const unsigned long remaining = RemainingMs(deadline);
    if (remaining == 0) return false;
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) return false;

    const BOOL started =
        ReadFile(pipe, buffer, static_cast<DWORD>(sizeof(buffer)), nullptr,
                 &overlapped);
    DWORD read = 0;
    bool ok = false;
    if (started) {
      ok = WaitOverlapped(pipe, &overlapped, remaining, &read);
    } else if (GetLastError() == ERROR_IO_PENDING) {
      ok = WaitOverlapped(pipe, &overlapped, remaining, &read);
    }
    CloseHandle(overlapped.hEvent);
    if (!ok || read == 0) return false;

    out->append(buffer, read);
    const size_t newline = out->find('\n');
    if (newline != std::string::npos) {
      out->resize(newline);
      return true;
    }
  }
  return false;
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

}  // namespace

bool ExchangePipe(const wchar_t* pipe_name, const std::string& request,
                  std::string* response, unsigned long timeout_ms,
                  unsigned long connect_wait_ms) {
  const TickCount deadline = DeadlineAfter(timeout_ms);
  HANDLE pipe = OpenPipe(pipe_name, std::min(RemainingMs(deadline),
                                             connect_wait_ms));
  if (pipe == INVALID_HANDLE_VALUE) return false;

  const bool ok = WriteAll(pipe, request + "\n", deadline) &&
                  ReadLine(pipe, response, deadline);
  CloseHandle(pipe);
  return ok;
}

}  // namespace io
}  // namespace boltmesh

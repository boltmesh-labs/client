// Native transport to the privileged boltmeshd helper.
//
// The daemon runs as LocalSystem and serves the same newline-delimited JSON
// protocol as the Linux Unix socket, but over the named pipe
// `\\.\pipe\boltmesh\boltmeshd`. `dart:io` has no Windows named-pipe client,
// so the runner performs the exchange here and hands the response line back
// to Dart through `com.boltmesh/helper`.
//
// All I/O is overlapped with bounded waits: a wedged daemon must surface as a
// Dart-side transport failure, never as a blocked platform thread.
#include "helper_pipe.h"

#define WIN32_LEAN_AND_MEAN

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

namespace boltmesh {
namespace {

constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\boltmesh\\boltmeshd";

// How long to wait for the pipe to appear when the daemon is still starting.
constexpr DWORD kConnectWaitMs = 2000;
// Upper bound on one overlapped read/write.
constexpr DWORD kIoTimeoutMs = 10000;
// Hard cap on one response line, matching the daemon's request cap.
constexpr size_t kMaxResponseBytes = 128 * 1024;

// WaitOverlapped waits for one overlapped operation. On timeout it cancels
// the operation and drains the completion so the handle is safe to close.
bool WaitOverlapped(HANDLE pipe, OVERLAPPED* overlapped, DWORD* transferred) {
  if (WaitForSingleObject(overlapped->hEvent, kIoTimeoutMs) != WAIT_OBJECT_0) {
    CancelIoEx(pipe, overlapped);
    WaitForSingleObject(overlapped->hEvent, INFINITE);
    return false;
  }
  return GetOverlappedResult(pipe, overlapped, transferred, FALSE) != 0;
}

bool WriteAll(HANDLE pipe, const std::string& data) {
  size_t offset = 0;
  while (offset < data.size()) {
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
      ok = WaitOverlapped(pipe, &overlapped, &written);
    } else if (GetLastError() == ERROR_IO_PENDING) {
      ok = WaitOverlapped(pipe, &overlapped, &written);
    }
    CloseHandle(overlapped.hEvent);
    if (!ok || written == 0) return false;
    offset += written;
  }
  return true;
}

// ReadLine reads until the first '\n' or the response cap, whichever comes
// first. The trailing newline is stripped.
bool ReadLine(HANDLE pipe, std::string* out) {
  out->clear();
  char buffer[4096];
  while (out->size() <= kMaxResponseBytes) {
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (overlapped.hEvent == nullptr) return false;

    const BOOL started =
        ReadFile(pipe, buffer, sizeof(buffer), nullptr, &overlapped);
    DWORD read = 0;
    bool ok = false;
    if (started) {
      ok = WaitOverlapped(pipe, &overlapped, &read);
    } else if (GetLastError() == ERROR_IO_PENDING) {
      ok = WaitOverlapped(pipe, &overlapped, &read);
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

HANDLE OpenPipe() {
  const DWORD access = GENERIC_READ | GENERIC_WRITE;
  HANDLE pipe = CreateFileW(kPipeName, access, 0, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED, nullptr);
  if (pipe != INVALID_HANDLE_VALUE) return pipe;
  // The daemon may still be starting; wait briefly for the pipe, then retry.
  if (!WaitNamedPipeW(kPipeName, kConnectWaitMs)) return INVALID_HANDLE_VALUE;
  return CreateFileW(kPipeName, access, 0, nullptr, OPEN_EXISTING,
                     FILE_FLAG_OVERLAPPED, nullptr);
}

// Exchange performs one request/response round trip. Returns false when the
// pipe is unreachable, the I/O fails, or it times out.
bool Exchange(const std::string& request, std::string* response) {
  HANDLE pipe = OpenPipe();
  if (pipe == INVALID_HANDLE_VALUE) return false;

  bool ok = WriteAll(pipe, request + "\n") && ReadLine(pipe, response);
  CloseHandle(pipe);
  return ok;
}

}  // namespace

void RegisterHelperPipe(flutter::FlutterEngine* engine) {
  static bool registered = false;
  if (registered || engine == nullptr) return;
  flutter::BinaryMessenger* messenger = engine->messenger();
  if (messenger == nullptr) return;

  // The engine owns the messenger and this is the app's only engine, so the
  // channel is held for the process lifetime.
  static std::vector<
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
      channels;

  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.boltmesh/helper",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "exchange") {
          result->NotImplemented();
          return;
        }
        const auto* request = std::get_if<std::string>(call.arguments());
        if (request == nullptr) {
          result->Error("bad_request", "exchange requires a JSON string");
          return;
        }
        std::string response;
        if (!Exchange(*request, &response)) {
          result->Error("unavailable", "boltmeshd pipe unavailable");
          return;
        }
        result->Success(flutter::EncodableValue(response));
      });
  channels.push_back(std::move(channel));

  registered = true;
}

}  // namespace boltmesh

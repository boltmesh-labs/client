// Native transport to the privileged boltmeshd helper.
//
// The daemon runs as LocalSystem and serves the same newline-delimited JSON
// protocol as the Linux Unix socket, but over the named pipe
// `\\.\pipe\boltmesh\boltmeshd`. `dart:io` has no Windows named-pipe client,
// so the runner performs the exchange and hands the response line back to
// Dart through `com.boltmesh/helper`.
//
// The framing/overlapped-I/O lives in helper_pipe_io.cpp, which links no
// Flutter code and is exercised by tests/helper_pipe_io_test.cpp; this file
// only wires it to the method channel.
//
// The exchange runs on a detached worker thread, never on the platform
// thread: a stopped, wedged, or impersonating helper must not stall window
// messages, the tray, or close handling for the whole 10-60 second budget.
// The outcome is marshalled back to the platform thread, where MethodResult
// callbacks belong, as a kHelperOutcomeMessage window message.
#include "helper_pipe.h"

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include "helper_pipe_io.h"

namespace boltmesh {
namespace {

using Result = flutter::MethodResult<flutter::EncodableValue>;

// The window is owned by Win32Window and is destroyed before the engine, while
// an exchange may still be in flight on a worker thread. g_state_mutex guards
// g_window so a worker can never post a message to a destroyed window:
// ShutdownHelperPipe clears it while still on the platform thread, before the
// window goes away, and a worker reads it under the same lock.
//
// Why a window message rather than flutter::FlutterEngine::
// PostPlatformThreadTask: that API heap-allocates the posted std::function and
// hands ownership to the engine, which frees it from a cancellation handler if
// the engine dies before the platform thread runs the task. When the GPU
// device is lost — reachable here, since a virtualised adapter under RDP can
// lose it — the two orderings interleave so the platform thread runs a task
// whose std::function was already freed, faulting on an access violation
// inside the engine's trampoline. It reproduces with an empty posted lambda, so
// no payload change avoids it; only not using the engine's task runner does. A
// window message is delivered by the thread that owns the MethodResult and
// stores nothing the engine can free underneath us.
std::mutex g_state_mutex;
HWND g_window = nullptr;  // guarded by g_state_mutex

// One exchange handed to a worker. It owns the request and the result; the
// result is only completed from a platform-thread task.
struct PendingExchange {
  std::string request;
  unsigned long timeout_ms = io::kIoTimeoutMs;
  std::shared_ptr<Result> result;
};

// A worker's outcome, handed to the platform thread as the window message's
// lParam and owned by it from the moment PostOutcome succeeds.
struct HelperOutcome {
  std::shared_ptr<Result> result;
  std::string response;
  bool ok;
};

// PostOutcome delivers a worker's outcome on the platform thread, where
// MethodResult callbacks belong. It reads g_window under the mutex and posts
// while still holding it, so the window cannot be destroyed between the check
// and the post. A post that fails drops the outcome, which the Dart side
// already treats as a transport timeout.
void PostOutcome(std::shared_ptr<Result> result, std::string response,
                 bool ok) {
  std::lock_guard<std::mutex> lock(g_state_mutex);
  if (g_window == nullptr) return;
  auto* outcome = new HelperOutcome{std::move(result), std::move(response), ok};
  if (!::PostMessage(g_window, kHelperOutcomeMessage, 0,
                     reinterpret_cast<LPARAM>(outcome))) {
    delete outcome;
  }
}

// StartExchange performs one pipe exchange off the platform thread. The
// shared_ptr keeps the request alive for the worker and lets a failed
// std::thread construction still answer the caller instead of throwing
// through the method-channel callback.
void StartExchange(std::shared_ptr<PendingExchange> exchange) {
  try {
    std::thread([exchange]() {
      std::string response;
      bool ok = false;
      try {
        ok = io::ExchangePipe(io::kHelperPipe, exchange->request, &response,
                              exchange->timeout_ms);
      } catch (...) {
        // An exception escaping a detached thread terminates the process;
        // report the transport as unavailable instead.
        ok = false;
      }
      PostOutcome(std::move(exchange->result), std::move(response), ok);
    }).detach();
  } catch (const std::system_error&) {
    exchange->result->Error("unavailable", "helper worker unavailable");
  }
}

}  // namespace

void CompleteHelperPipeOutcome(void* outcome) {
  // Platform thread, from the window procedure. Takes ownership of the
  // outcome the worker posted.
  std::unique_ptr<HelperOutcome> completed(
      static_cast<HelperOutcome*>(outcome));
  if (!completed) return;
  if (completed->ok) {
    completed->result->Success(
        flutter::EncodableValue(std::move(completed->response)));
  } else {
    completed->result->Error("unavailable", "boltmeshd pipe unavailable");
  }
}

void RegisterHelperPipe(flutter::FlutterEngine* engine, HWND window) {
  static bool registered = false;
  if (registered || engine == nullptr || window == nullptr) return;
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
        std::string request;
        unsigned long timeout_ms = io::kIoTimeoutMs;
        if (const auto* text = std::get_if<std::string>(call.arguments());
            text != nullptr) {
          // Accept the original string form for compatibility with older
          // clients and the standalone transport tests.
          request = *text;
        } else if (const auto* arguments =
                       std::get_if<flutter::EncodableMap>(call.arguments());
                   arguments != nullptr) {
          const auto request_it =
              arguments->find(flutter::EncodableValue("request"));
          if (request_it == arguments->end()) {
            result->Error("bad_request", "exchange requires a request");
            return;
          }
          const auto* request_text =
              std::get_if<std::string>(&request_it->second);
          if (request_text == nullptr) {
            result->Error("bad_request", "exchange request must be a string");
            return;
          }
          request = *request_text;

          const auto timeout_it =
              arguments->find(flutter::EncodableValue("timeoutMs"));
          if (timeout_it != arguments->end()) {
            const auto* timeout_value =
                std::get_if<int32_t>(&timeout_it->second);
            if (timeout_value == nullptr || *timeout_value <= 0 ||
                static_cast<unsigned long>(*timeout_value) >
                    io::kMaxIoTimeoutMs) {
              result->Error("bad_request", "exchange timeout is invalid");
              return;
            }
            timeout_ms = static_cast<unsigned long>(*timeout_value);
          }
        } else {
          result->Error("bad_request", "exchange requires a JSON request");
          return;
        }

        // Bound the request here as well as in the transport so the oversized
        // string is never copied to a worker or written. The daemon rejects a
        // line over the cap anyway; doing it first keeps the cost on the
        // caller's side of the channel.
        if (request.size() + 1 > io::kMaxRequestBytes) {
          result->Error("bad_request", "exchange request is too large");
          return;
        }

        auto exchange = std::make_shared<PendingExchange>();
        exchange->request = std::move(request);
        exchange->timeout_ms = timeout_ms;
        exchange->result = std::shared_ptr<Result>(std::move(result));
        StartExchange(std::move(exchange));
      });
  channels.push_back(std::move(channel));

  {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    g_window = window;
  }
  registered = true;
}

void ShutdownHelperPipe() {
  // Called on the platform thread before the window is destroyed. Clear the
  // handle first so no worker can post after this point, then drain anything
  // already queued: those outcomes own a MethodResult, and the message loop
  // will never dispatch them once the window is gone.
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    window = g_window;
    g_window = nullptr;
  }
  if (window == nullptr) return;
  MSG msg;
  while (::PeekMessage(&msg, window, kHelperOutcomeMessage,
                       kHelperOutcomeMessage, PM_REMOVE)) {
    CompleteHelperPipeOutcome(reinterpret_cast<void*>(msg.lParam));
  }
}

}  // namespace boltmesh

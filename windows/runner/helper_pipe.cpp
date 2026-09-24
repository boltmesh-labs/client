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
// The outcome is marshalled back to the platform thread through the engine,
// where MethodResult callbacks belong.
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

// The engine is owned by the FlutterViewController and dies with the window,
// while an exchange may still be in flight on a worker thread. g_engine_mutex
// guards g_engine so a worker can never post to a destroyed engine: shutdown
// clears the pointer before the controller is torn down, and a worker holds
// the mutex across its post. A post the engine's task runner never runs
// (because the engine is destroyed) is cancelled, which destroys the captured
// result without touching the engine.
std::mutex g_engine_mutex;
flutter::FlutterEngine* g_engine = nullptr;  // guarded by g_engine_mutex

// One exchange handed to a worker. It owns the request and the result; the
// result is only completed from a platform-thread task.
struct PendingExchange {
  std::string request;
  unsigned long timeout_ms = io::kIoTimeoutMs;
  std::shared_ptr<Result> result;
};

// PostOutcome delivers a worker's outcome on the platform thread, where
// MethodResult callbacks belong. It holds g_engine_mutex across the post so the
// engine cannot be destroyed between the null check and the call, and drops the
// outcome when the engine is already gone.
void PostOutcome(std::shared_ptr<Result> result, std::string response,
                 bool ok) {
  std::lock_guard<std::mutex> lock(g_engine_mutex);
  flutter::FlutterEngine* engine = g_engine;
  if (engine == nullptr) return;
  engine->PostPlatformThreadTask([result = std::move(result),
                                  response = std::move(response),
                                  ok]() mutable {
    if (ok) {
      result->Success(flutter::EncodableValue(std::move(response)));
    } else {
      result->Error("unavailable", "boltmeshd pipe unavailable");
    }
  });
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

        auto exchange = std::make_shared<PendingExchange>();
        exchange->request = std::move(request);
        exchange->timeout_ms = timeout_ms;
        exchange->result = std::shared_ptr<Result>(std::move(result));
        StartExchange(std::move(exchange));
      });
  channels.push_back(std::move(channel));

  {
    std::lock_guard<std::mutex> lock(g_engine_mutex);
    g_engine = engine;
  }
  registered = true;
}

void ShutdownHelperPipe() {
  // Called on the platform thread before the controller (and its engine) is
  // destroyed. In-flight workers either post before this returns or observe a
  // null engine and drop their outcome.
  std::lock_guard<std::mutex> lock(g_engine_mutex);
  g_engine = nullptr;
}

}  // namespace boltmesh

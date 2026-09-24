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
#include "helper_pipe.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include "helper_pipe_io.h"

namespace boltmesh {

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

        std::string response;
        if (!io::ExchangePipe(io::kHelperPipe, request, &response,
                              timeout_ms)) {
          result->Error("unavailable", "boltmeshd pipe unavailable");
          return;
        }
        result->Success(flutter::EncodableValue(response));
      });
  channels.push_back(std::move(channel));

  registered = true;
}

}  // namespace boltmesh

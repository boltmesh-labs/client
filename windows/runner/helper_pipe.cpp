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
        const auto* request = std::get_if<std::string>(call.arguments());
        if (request == nullptr) {
          result->Error("bad_request", "exchange requires a JSON string");
          return;
        }
        std::string response;
        if (!io::ExchangePipe(io::kHelperPipe, *request, &response)) {
          result->Error("unavailable", "boltmeshd pipe unavailable");
          return;
        }
        result->Success(flutter::EncodableValue(response));
      });
  channels.push_back(std::move(channel));

  registered = true;
}

}  // namespace boltmesh

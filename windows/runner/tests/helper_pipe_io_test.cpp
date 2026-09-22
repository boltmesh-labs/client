// Standalone test for the named-pipe transport in helper_pipe_io.cpp.
//
// It links no Flutter libraries: it stands up a local pipe server with the
// Win32 API and drives ExchangePipe against it, so the framing, newline
// handling and timeout behaviour are covered on the Windows CI runner even
// though the full runner needs Flutter (and hence a GUI toolchain) to build.
#include "../helper_pipe_io.h"

#define WIN32_LEAN_AND_MEAN

#include <windows.h>

#include <cstdio>
#include <string>

namespace {

int g_failures = 0;

void Check(bool condition, const char* what) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", what);
    ++g_failures;
  }
}

std::wstring UniquePipeName(const wchar_t* suffix) {
  return std::wstring(L"\\\\.\\pipe\\boltmesh-test-") +
         std::to_wstring(GetCurrentProcessId()) + L"-" + suffix;
}

// ServerArgs carries the pipe name, the reply the server should send (empty
// means "accept the request but never answer"), and the request it read.
struct ServerArgs {
  std::wstring pipe_name;
  std::string reply;
  std::string request;
};

// ServerThread serves exactly one connection: it reads one request line into
// args->request and, when reply is non-empty, writes reply + '\n'.
DWORD WINAPI ServerThread(LPVOID param) {
  auto* args = static_cast<ServerArgs*>(param);
  HANDLE pipe = CreateNamedPipeW(
      args->pipe_name.c_str(), PIPE_ACCESS_DUPLEX,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1,
      4096, 4096, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    return 1;
  }

  const BOOL connected = ConnectNamedPipe(pipe, nullptr) ||
                         GetLastError() == ERROR_PIPE_CONNECTED;
  if (connected) {
    std::string line;
    char buffer[512];
    while (line.find('\n') == std::string::npos) {
      DWORD read = 0;
      if (!ReadFile(pipe, buffer, static_cast<DWORD>(sizeof(buffer)), &read,
                    nullptr) ||
          read == 0) {
        break;
      }
      line.append(buffer, read);
    }
    const size_t newline = line.find('\n');
    args->request = newline == std::string::npos ? line : line.substr(0, newline);

    if (!args->reply.empty()) {
      const std::string out = args->reply + "\n";
      DWORD written = 0;
      WriteFile(pipe, out.data(), static_cast<DWORD>(out.size()), &written,
                nullptr);
      FlushFileBuffers(pipe);
    } else {
      // Hold the connection open past the client's timeout.
      Sleep(1000);
    }
  }

  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  return 0;
}

// StartServer returns a running thread (or nullptr) for one request.
HANDLE StartServer(ServerArgs* args) {
  return CreateThread(nullptr, 0, ServerThread, args, 0, nullptr);
}

// WaitForServer joins a server thread so its buffers outlive ExchangePipe.
void WaitForServer(HANDLE thread, const char* what) {
  if (thread == nullptr) {
    Check(false, what);
    return;
  }
  const DWORD wait = WaitForSingleObject(thread, 5000);
  Check(wait == WAIT_OBJECT_0, what);
  CloseHandle(thread);
}

void TestRoundTrip() {
  ServerArgs args;
  args.pipe_name = UniquePipeName(L"round-trip");
  args.reply = R"({"v":1,"id":"1","ok":true})";
  HANDLE thread = StartServer(&args);
  // Give CreateNamedPipeW a moment to publish the name.
  Sleep(50);

  std::string response;
  const std::string request = R"({"v":1,"id":"1","op":"ping"})";
  const bool ok = boltmesh::io::ExchangePipe(args.pipe_name.c_str(), request,
                                             &response, 3000, 2000);
  Check(ok, "ExchangePipe returns true for a served request");
  Check(response == args.reply, "response line is returned verbatim");
  Check(args.request == request, "server received the request line");
  WaitForServer(thread, "round-trip server thread joined");
}

void TestTimeoutWhenServerNeverReplies() {
  ServerArgs args;
  args.pipe_name = UniquePipeName(L"no-reply");
  HANDLE thread = StartServer(&args);
  Sleep(50);

  std::string response;
  const bool ok = boltmesh::io::ExchangePipe(args.pipe_name.c_str(), "{}",
                                             &response, 200, 2000);
  Check(!ok, "ExchangePipe returns false when the server never answers");
  WaitForServer(thread, "no-reply server thread joined");
}

void TestUnreachablePipe() {
  std::string response;
  const bool ok = boltmesh::io::ExchangePipe(
      UniquePipeName(L"absent").c_str(), "{}", &response, 200, 100);
  Check(!ok, "ExchangePipe returns false for an absent pipe");
}

}  // namespace

int main() {
  TestRoundTrip();
  TestTimeoutWhenServerNeverReplies();
  TestUnreachablePipe();

  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::printf("helper_pipe_io: all checks passed\n");
  return 0;
}

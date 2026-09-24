// Standalone test for the named-pipe transport in helper_pipe_io.cpp.
//
// It links no Flutter libraries: it stands up a local pipe server with the
// Win32 API and drives the transport against it, so the framing, newline
// handling, timeout behaviour, and the rejection of a server that is not the
// privileged boltmeshd service are covered on the Windows CI runner even
// though the full runner needs Flutter (and hence a GUI toolchain) to build.
#include "../helper_pipe_io.h"

#define WIN32_LEAN_AND_MEAN

#include <windows.h>

#include <cstdio>
#include <string>

namespace boltmesh {
namespace io {
// Defined in helper_pipe_io.cpp only when BOLTMESH_HELPER_PIPE_TEST is set (see
// windows/runner/CMakeLists.txt). The framing tests drive the transport without
// peer authentication because a test cannot run a server as the boltmeshd
// service; TestRejectsServerThatIsNotTheService exercises the authenticating
// ExchangePipe against a local, unprivileged server.
bool ExchangePipeUnverified(const wchar_t* pipe_name,
                            const std::string& request, std::string* response,
                            unsigned long timeout_ms,
                            unsigned long connect_wait_ms);
}  // namespace io
}  // namespace boltmesh

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
// means "accept the request but never answer"), the delay before the pipe is
// created, and the request it read.
struct ServerArgs {
  std::wstring pipe_name;
  std::string reply;
  DWORD delay_ms = 0;
  std::string request;
};

// ServerThread serves exactly one connection: it creates the pipe (after
// args->delay_ms, to model a daemon that is still starting), reads one request
// line into args->request and, when reply is non-empty, writes reply + '\n'.
DWORD WINAPI ServerThread(LPVOID param) {
  auto* args = static_cast<ServerArgs*>(param);
  if (args->delay_ms != 0) {
    Sleep(args->delay_ms);
  }
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
  const bool ok = boltmesh::io::ExchangePipeUnverified(
      args.pipe_name.c_str(), request, &response, 3000, 2000);
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
  const ULONGLONG start = GetTickCount64();
  const bool ok = boltmesh::io::ExchangePipeUnverified(
      args.pipe_name.c_str(), "{}", &response, 200, 2000);
  const ULONGLONG elapsed = GetTickCount64() - start;
  Check(!ok, "ExchangePipe returns false when the server never answers");
  // The cancellation drain must stay inside the requested 200 ms budget; the
  // old fixed 1 s drain let the exchange run ~1.2 s. Allow ample scheduling
  // slack but well under that.
  Check(elapsed < 700, "timeout is not extended by the cancellation drain");
  WaitForServer(thread, "no-reply server thread joined");
}

void TestUnreachablePipe() {
  std::string response;
  const bool ok = boltmesh::io::ExchangePipe(
      UniquePipeName(L"absent").c_str(), "{}", &response, 200, 100);
  Check(!ok, "ExchangePipe returns false for an absent pipe");
}

// The daemon may still be starting when the app first connects. WaitNamedPipeW
// returns immediately when no instance exists at all, so the transport must
// poll for the pipe to be created rather than give up on the first miss.
void TestWaitsForPipeToAppear() {
  ServerArgs args;
  args.pipe_name = UniquePipeName(L"delayed");
  args.reply = R"({"v":1,"id":"1","ok":true})";
  args.delay_ms = 200;
  HANDLE thread = StartServer(&args);

  std::string response;
  const bool ok = boltmesh::io::ExchangePipeUnverified(
      args.pipe_name.c_str(), "{}", &response, 3000, 2000);
  Check(ok, "ExchangePipe waits for a pipe the daemon has not created yet");
  Check(response == args.reply, "delayed-pipe response line is returned");
  WaitForServer(thread, "delayed-pipe server thread joined");
}

// A local process that pre-created the pipe name must be rejected before the
// request is written: this server is not the boltmeshd service process.
void TestRejectsServerThatIsNotTheService() {
  ServerArgs args;
  args.pipe_name = UniquePipeName(L"impostor");
  args.reply = R"({"v":1,"id":"1","ok":true})";
  HANDLE thread = StartServer(&args);
  Sleep(50);

  std::string response;
  const std::string request = R"({"v":1,"id":"1","op":"up","config":"secret"})";
  const bool ok =
      boltmesh::io::ExchangePipe(args.pipe_name.c_str(), request, &response,
                                 3000, 2000);
  Check(!ok, "ExchangePipe rejects a server that is not the boltmeshd service");
  Check(args.request.empty(), "no request reaches a rejected server");
  WaitForServer(thread, "impostor server thread joined");
}

// A request line is capped before it is written. A body one byte over what the
// daemon accepts (the cap includes the framing newline) must be rejected
// without connecting, so there is no server here.
void TestRejectsOversizedRequest() {
  std::string response;
  const std::string request(boltmesh::io::kMaxRequestBytes, 'x');
  const bool ok = boltmesh::io::ExchangePipeUnverified(
      UniquePipeName(L"oversized-request").c_str(), request, &response, 200,
      100);
  Check(!ok, "ExchangePipe rejects a request over the cap");
}

// A request whose framed length is exactly the cap is still valid.
void TestAcceptsRequestAtCap() {
  ServerArgs args;
  args.pipe_name = UniquePipeName(L"request-at-cap");
  args.reply = R"({"v":1,"id":"1","ok":true})";
  HANDLE thread = StartServer(&args);
  Sleep(50);

  std::string response;
  const std::string request(boltmesh::io::kMaxRequestBytes - 1, 'x');
  const bool ok = boltmesh::io::ExchangePipeUnverified(
      args.pipe_name.c_str(), request, &response, 10000, 2000);
  Check(ok, "ExchangePipe accepts a request at the cap");
  Check(args.request == request, "at-cap request arrives intact");
  WaitForServer(thread, "request-at-cap server thread joined");
}

// A response line exactly at the cap is accepted.
void TestAcceptsResponseAtCap() {
  ServerArgs args;
  args.pipe_name = UniquePipeName(L"response-at-cap");
  args.reply = std::string(boltmesh::io::kMaxResponseBytes, 'x');
  HANDLE thread = StartServer(&args);
  Sleep(50);

  std::string response;
  const bool ok = boltmesh::io::ExchangePipeUnverified(
      args.pipe_name.c_str(), "{}", &response, 10000, 2000);
  Check(ok, "ExchangePipe accepts a response line at the cap");
  Check(response == args.reply, "at-cap response line is returned intact");
  WaitForServer(thread, "response-at-cap server thread joined");
}

// One byte past the cap must be rejected: the old loop read a whole 4096-byte
// chunk once the response already reached the cap, accepting up to 4095 extra
// bytes.
void TestRejectsOverlongResponse() {
  ServerArgs args;
  args.pipe_name = UniquePipeName(L"overlong-response");
  args.reply = std::string(boltmesh::io::kMaxResponseBytes + 1, 'x');
  HANDLE thread = StartServer(&args);
  Sleep(50);

  std::string response;
  const bool ok = boltmesh::io::ExchangePipeUnverified(
      args.pipe_name.c_str(), "{}", &response, 10000, 2000);
  Check(!ok, "ExchangePipe rejects a response line over the cap");
  WaitForServer(thread, "overlong-response server thread joined");
}

}  // namespace

int main() {
  TestRoundTrip();
  TestTimeoutWhenServerNeverReplies();
  TestUnreachablePipe();
  TestWaitsForPipeToAppear();
  TestRejectsServerThatIsNotTheService();
  TestRejectsOversizedRequest();
  TestAcceptsRequestAtCap();
  TestAcceptsResponseAtCap();
  TestRejectsOverlongResponse();

  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::printf("helper_pipe_io: all checks passed\n");
  return 0;
}

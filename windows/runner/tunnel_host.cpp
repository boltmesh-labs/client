// Windows host for the app's own native tunnel channels.
//
// Mirrors the Android `TunnelHost` contract (see `client/README.md` and
// `client/lib/features/vpn/data/tunnel_adapter.dart`) on top of the WireGuard
// for Windows adapter the VPN plugin already installs:
//
//   com.boltmesh/handshake -> getLastHandshake  (epoch seconds, or null)
//   com.boltmesh/tunnel    -> getActivePeer, killGhost
//
// The plugin only exposes byte counters, so these reads go through the
// bundled `wireguard.dll` (`WireGuardOpenAdapter` + `WireGuardGetConfiguration`)
// and the SCM. Every failure resolves as null/false (unknown, never a stall on
// its own), matching the Dart adapter's read semantics.
#define WIN32_LEAN_AND_MEAN

#include "tunnel_host.h"

#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

#include <flutter/encodable_value.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "wireguard_api.h"

namespace boltmesh {
namespace {

// The plugin names both the adapter and its Windows service after the
// interface name passed to `initialize(interfaceName: 'boltmesh0')`.
constexpr wchar_t kAdapterName[] = L"boltmesh0";
constexpr wchar_t kServiceName[] = L"boltmesh0";

// First-guess configuration buffer; grown on ERROR_MORE_DATA.
constexpr DWORD kInitialConfigBytes = 0x10000;

// 100ns intervals between the FILETIME epoch (1601-01-01) and the Unix epoch.
constexpr DWORD64 kFiletimeUnixEpoch = 116444736000000000ULL;
constexpr double kFiletimePerSecond = 10000000.0;

// Bound for waiting out a service stop. The plugin's own stop already waits
// up to 15s; this only runs for a ghost the plugin could not reach.
constexpr int kStopPollAttempts = 50;
constexpr DWORD kStopPollIntervalMs = 100;

// ---------------------------------------------------------------------------
// wireguard.dll, loaded lazily and cached for the process lifetime.
// ---------------------------------------------------------------------------

struct WireGuardApi {
  HMODULE module = nullptr;
  WireGuardOpenAdapterFn open_adapter = nullptr;
  WireGuardCloseAdapterFn close_adapter = nullptr;
  WireGuardGetConfigurationFn get_configuration = nullptr;
};

const WireGuardApi& Api() {
#pragma warning(push)
#pragma warning(disable : 4191)  // GetProcAddress -> typed function pointer
  static const WireGuardApi api = [] {
    WireGuardApi loaded;
    wchar_t path[MAX_PATH] = {};
    const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) return loaded;
    std::wstring directory(path, length);
    const size_t slash = directory.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return loaded;
    directory.resize(slash + 1);
    // Absolute path: the loader must never search the CWD or PATH for the
    // DLL (the plugin already installs it next to the executable).
    loaded.module = LoadLibraryW((directory + L"wireguard.dll").c_str());
    if (loaded.module == nullptr) return loaded;
    loaded.open_adapter = reinterpret_cast<WireGuardOpenAdapterFn>(
        GetProcAddress(loaded.module, "WireGuardOpenAdapter"));
    loaded.close_adapter = reinterpret_cast<WireGuardCloseAdapterFn>(
        GetProcAddress(loaded.module, "WireGuardCloseAdapter"));
    loaded.get_configuration = reinterpret_cast<WireGuardGetConfigurationFn>(
        GetProcAddress(loaded.module, "WireGuardGetConfiguration"));
    return loaded;
  }();
  return api;
#pragma warning(pop)
}

// Reads the live configuration of `boltmesh0` into |buffer|. False when the
// DLL, the adapter, or the call is unavailable (all "unknown" to Dart). On
// success |iface| points into |buffer| and |peers| is the peer array that
// immediately follows it.
bool ReadConfiguration(std::vector<BYTE>* buffer,
                       const WIREGUARD_INTERFACE** iface,
                       const WIREGUARD_PEER** peers) {
  const WireGuardApi& api = Api();
  if (api.open_adapter == nullptr || api.close_adapter == nullptr ||
      api.get_configuration == nullptr) {
    return false;
  }
  WIREGUARD_ADAPTER_HANDLE adapter = api.open_adapter(kAdapterName);
  if (adapter == nullptr) return false;

  bool ok = false;
  DWORD bytes = kInitialConfigBytes;
  buffer->assign(bytes, 0);
  // The driver answers ERROR_MORE_DATA with the required size; a bounded
  // retry count keeps a misbehaving driver from spinning here forever.
  for (int attempt = 0; attempt < 4; ++attempt) {
    if (api.get_configuration(
            adapter, reinterpret_cast<WIREGUARD_INTERFACE*>(buffer->data()),
            &bytes)) {
      ok = true;
      break;
    }
    if (GetLastError() != ERROR_MORE_DATA) break;
    buffer->assign(bytes, 0);
  }
  api.close_adapter(adapter);
  if (!ok) return false;

  const auto* config =
      reinterpret_cast<const WIREGUARD_INTERFACE*>(buffer->data());
  // The driver reports PeersCount but the buffer must actually hold that many
  // peer structs; refuse to walk past what it allocated.
  const size_t needed =
      sizeof(WIREGUARD_INTERFACE) +
      static_cast<size_t>(config->PeersCount) * sizeof(WIREGUARD_PEER);
  if (buffer->size() < needed) return false;

  *iface = config;
  *peers = reinterpret_cast<const WIREGUARD_PEER*>(config + 1);
  return true;
}

// ---------------------------------------------------------------------------
// Encoding helpers.
// ---------------------------------------------------------------------------

constexpr char kBase64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Standard base64 with padding, matching Dart's `base64Encode` for the 32-byte
// WireGuard public key.
std::string Base64Encode(const BYTE* data, size_t length) {
  std::string out;
  out.reserve(((length + 2) / 3) * 4);
  size_t i = 0;
  for (; i + 3 <= length; i += 3) {
    const uint32_t chunk =
        (static_cast<uint32_t>(data[i]) << 16) |
        (static_cast<uint32_t>(data[i + 1]) << 8) |
        static_cast<uint32_t>(data[i + 2]);
    out.push_back(kBase64Alphabet[(chunk >> 18) & 0x3f]);
    out.push_back(kBase64Alphabet[(chunk >> 12) & 0x3f]);
    out.push_back(kBase64Alphabet[(chunk >> 6) & 0x3f]);
    out.push_back(kBase64Alphabet[chunk & 0x3f]);
  }
  const size_t remaining = length - i;
  if (remaining == 1) {
    const uint32_t chunk = static_cast<uint32_t>(data[i]) << 16;
    out.push_back(kBase64Alphabet[(chunk >> 18) & 0x3f]);
    out.push_back(kBase64Alphabet[(chunk >> 12) & 0x3f]);
    out.push_back('=');
    out.push_back('=');
  } else if (remaining == 2) {
    const uint32_t chunk = (static_cast<uint32_t>(data[i]) << 16) |
                           (static_cast<uint32_t>(data[i + 1]) << 8);
    out.push_back(kBase64Alphabet[(chunk >> 18) & 0x3f]);
    out.push_back(kBase64Alphabet[(chunk >> 12) & 0x3f]);
    out.push_back(kBase64Alphabet[(chunk >> 6) & 0x3f]);
    out.push_back('=');
  }
  return out;
}

std::string FormatEndpoint(const SOCKADDR_INET& endpoint) {
  char host[INET6_ADDRSTRLEN] = {};
  if (endpoint.si_family == AF_INET) {
    if (InetNtopA(AF_INET, &endpoint.Ipv4.sin_addr, host, sizeof(host)) ==
        nullptr) {
      return "";
    }
    return std::string(host) + ":" +
           std::to_string(ntohs(endpoint.Ipv4.sin_port));
  }
  if (endpoint.si_family == AF_INET6) {
    if (InetNtopA(AF_INET6, &endpoint.Ipv6.sin6_addr, host, sizeof(host)) ==
        nullptr) {
      return "";
    }
    // Bracketed to match Dart's `formatEndpoint` for IPv6 hosts.
    return "[" + std::string(host) + "]:" +
           std::to_string(ntohs(endpoint.Ipv6.sin6_port));
  }
  return "";
}

// ---------------------------------------------------------------------------
// Reads.
// ---------------------------------------------------------------------------

// Newest completed handshake across the adapter's peers, in epoch seconds, or
// nullopt when none has handshook (0 means "never", per the driver contract).
std::optional<double> LastHandshakeSeconds() {
  std::vector<BYTE> buffer;
  const WIREGUARD_INTERFACE* iface = nullptr;
  const WIREGUARD_PEER* peers = nullptr;
  if (!ReadConfiguration(&buffer, &iface, &peers)) return std::nullopt;

  DWORD64 newest = 0;
  for (DWORD i = 0; i < iface->PeersCount; ++i) {
    if (peers[i].LastHandshake > newest) newest = peers[i].LastHandshake;
  }
  if (newest <= kFiletimeUnixEpoch) return std::nullopt;
  return static_cast<double>(newest - kFiletimeUnixEpoch) / kFiletimePerSecond;
}

// Identifying fields of the live peer with the newest handshake, or nullopt
// when no adapter/peer exists. No private key material leaves the process.
std::optional<flutter::EncodableMap> ActivePeer() {
  std::vector<BYTE> buffer;
  const WIREGUARD_INTERFACE* iface = nullptr;
  const WIREGUARD_PEER* peers = nullptr;
  if (!ReadConfiguration(&buffer, &iface, &peers) || iface->PeersCount == 0) {
    return std::nullopt;
  }

  const WIREGUARD_PEER* chosen = &peers[0];
  for (DWORD i = 1; i < iface->PeersCount; ++i) {
    if (peers[i].LastHandshake > chosen->LastHandshake) chosen = &peers[i];
  }
  const std::string public_key =
      Base64Encode(chosen->PublicKey, WIREGUARD_KEY_LENGTH);
  if (public_key.empty()) return std::nullopt;

  flutter::EncodableMap peer;
  peer[flutter::EncodableValue("publicKey")] =
      flutter::EncodableValue(public_key);
  peer[flutter::EncodableValue("endpoint")] =
      flutter::EncodableValue(FormatEndpoint(chosen->Endpoint));
  return peer;
}

// ---------------------------------------------------------------------------
// Ghost kill.
// ---------------------------------------------------------------------------

bool ServiceStopped(SC_HANDLE service) {
  SERVICE_STATUS_PROCESS status = {};
  DWORD needed = 0;
  if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
                            reinterpret_cast<LPBYTE>(&status), sizeof(status),
                            &needed)) {
    return false;
  }
  return status.dwCurrentState == SERVICE_STOPPED;
}

// Stops the tunnel's Windows service directly (the plugin's own `stopVpn`
// needs `initialize` first and a live handle, so a ghost after a process
// restart slips past it). True when no tunnel is running afterwards, so it is
// idempotent and safe to call after a normal stop.
bool StopTunnelService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (manager == nullptr) return false;
  SC_HANDLE service =
      OpenServiceW(manager, kServiceName, SERVICE_STOP | SERVICE_QUERY_STATUS);
  if (service == nullptr) {
    // No such service: nothing is running.
    CloseServiceHandle(manager);
    return true;
  }

  bool stopped = ServiceStopped(service);
  if (!stopped) {
    SERVICE_STATUS status = {};
    ControlService(service, SERVICE_CONTROL_STOP, &status);
    for (int i = 0; i < kStopPollAttempts && !stopped; ++i) {
      Sleep(kStopPollIntervalMs);
      stopped = ServiceStopped(service);
    }
  }
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return stopped;
}

}  // namespace

void RegisterTunnelHost(flutter::FlutterEngine* engine) {
  static bool registered = false;
  if (registered || engine == nullptr) return;
  flutter::BinaryMessenger* messenger = engine->messenger();
  if (messenger == nullptr) return;

  // The engine owns the messenger and this is the app's only engine, so the
  // channels are held for the process lifetime (destroying one would leave
  // its handler registered on the messenger).
  static std::vector<
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
      channels;

  auto handshake =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.boltmesh/handshake",
          &flutter::StandardMethodCodec::GetInstance());
  handshake->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "getLastHandshake") {
          result->NotImplemented();
          return;
        }
        const std::optional<double> seconds = LastHandshakeSeconds();
        if (seconds.has_value()) {
          result->Success(flutter::EncodableValue(*seconds));
        } else {
          result->Success();  // null = unknown
        }
      });
  channels.push_back(std::move(handshake));

  auto tunnel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.boltmesh/tunnel",
          &flutter::StandardMethodCodec::GetInstance());
  tunnel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        if (method == "getActivePeer") {
          const std::optional<flutter::EncodableMap> peer = ActivePeer();
          if (peer.has_value()) {
            result->Success(flutter::EncodableValue(*peer));
          } else {
            result->Success();  // null = unknown
          }
          return;
        }
        if (method == "killGhost") {
          result->Success(flutter::EncodableValue(StopTunnelService()));
          return;
        }
        result->NotImplemented();
      });
  channels.push_back(std::move(tunnel));

  registered = true;
}

}  // namespace boltmesh

// Minimal ABI declarations for the WireGuard for Windows embeddable DLL.
//
// The VPN plugin ships `wireguard.dll` next to the executable but exposes no
// read API of its own, so the runner loads it directly to read the live
// adapter's peers. The structs below are copied verbatim from upstream
// `wireguard.h` (WireGuard for Windows, SPDX-License-Identifier: GPL-2.0 OR
// MIT) because the layout is load-bearing: `WireGuardGetConfiguration`
// returns one `WIREGUARD_INTERFACE` immediately followed by `PeersCount`
// `WIREGUARD_PEER` structs (and then their allowed IPs), so any drift in
// field order, type, or the `ALIGNED(8)` attribute would read the wrong
// offsets. Only the read side is declared; writes are never performed here.
#ifndef RUNNER_WIREGUARD_API_H_
#define RUNNER_WIREGUARD_API_H_

#include <winsock2.h>
#include <windows.h>
#include <ipexport.h>
#include <ifdef.h>
#include <ws2ipdef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef ALIGNED
#if defined(_MSC_VER)
#define ALIGNED(n) __declspec(align(n))
#elif defined(__GNUC__)
#define ALIGNED(n) __attribute__((aligned(n)))
#else
#error "Unable to define ALIGNED"
#endif
#endif

#define WIREGUARD_KEY_LENGTH 32

// The `ALIGNED(8)` attributes below can pad the structs; the runner builds
// with /W4 /WX, so silence C4324 the same way upstream `wireguard.h` does.
#pragma warning(push)
#pragma warning(disable : 4324)  // structure was padded due to alignment

// A handle to a WireGuard adapter, returned by WireGuardOpenAdapter.
typedef struct _WIREGUARD_ADAPTER* WIREGUARD_ADAPTER_HANDLE;

typedef struct _WIREGUARD_INTERFACE WIREGUARD_INTERFACE;
struct ALIGNED(8) _WIREGUARD_INTERFACE {
  DWORD Flags; /**< Bitwise combination of WIREGUARD_INTERFACE_FLAG. */
  WORD ListenPort; /**< Port for UDP listen socket, or 0 to choose randomly. */
  BYTE PrivateKey[WIREGUARD_KEY_LENGTH];
  BYTE PublicKey[WIREGUARD_KEY_LENGTH];
  DWORD PeersCount; /**< Number of WIREGUARD_PEER structs following this one. */
};

typedef struct _WIREGUARD_PEER WIREGUARD_PEER;
struct ALIGNED(8) _WIREGUARD_PEER {
  DWORD Flags; /**< Bitwise combination of WIREGUARD_PEER_FLAG. */
  DWORD Reserved; /**< Reserved; must be zero. */
  BYTE PublicKey[WIREGUARD_KEY_LENGTH];
  BYTE PresharedKey[WIREGUARD_KEY_LENGTH];
  WORD PersistentKeepalive; /**< Seconds interval, or 0 to disable. */
  SOCKADDR_INET Endpoint; /**< Endpoint, with IP address and UDP port. */
  DWORD64 TxBytes;
  DWORD64 RxBytes;
  DWORD64 LastHandshake; /**< 100ns intervals since 1601-01-01 UTC, or 0. */
  DWORD AllowedIPsCount; /**< Allowed IP structs following the peers. */
};

#pragma warning(pop)

// Entry points resolved from `wireguard.dll` at runtime (never linked, so the
// runner carries no build-time dependency on the plugin's import library).
typedef WIREGUARD_ADAPTER_HANDLE(WINAPI* WireGuardOpenAdapterFn)(LPCWSTR Name);
typedef VOID(WINAPI* WireGuardCloseAdapterFn)(
    WIREGUARD_ADAPTER_HANDLE Adapter);
typedef BOOL(WINAPI* WireGuardGetConfigurationFn)(
    WIREGUARD_ADAPTER_HANDLE Adapter,
    WIREGUARD_INTERFACE* Config,
    DWORD* Bytes);

#ifdef __cplusplus
}
#endif

#endif  // RUNNER_WIREGUARD_API_H_

# Vendored Wintun (Windows)

`wintun.dll` is the Wintun L3 TUN driver: a minimal NDIS virtual adapter that
gives a userspace program a network interface to read and write packets, the
Windows counterpart to Linux's `/dev/net/tun`. BoltMesh needs it for the
AmneziaWG data plane, because the WireGuard-for-Windows kernel service has no
concept of the obfuscation directives an obfuscated region requires.

## Provenance

| | |
| --- | --- |
| Source | <https://www.wintun.net/> — the only supported distribution channel |
| DLL release | 0.14.1 |
| Go binding | `golang.zx2c4.com/wintun v0.0.0-20230126152724-0fa3db229ce2` |
| Archive | `wintun-0.14.1.zip` (SHA2-256 `07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51`) |
| File | `wintun/bin/amd64/wintun.dll` |
| SHA2-256 | `e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce` |
| Signer | `CN=WireGuard LLC, O=WireGuard LLC, L=Boulder, S=Colorado, C=US` |
| Issuer | `CN=DigiCert EV Code Signing CA (SHA2)` |
| Timestamp | DigiCert Timestamp 2021 (so the 2021 expiry does not invalidate it) |

Only the **amd64** build is vendored. The Windows client is x64-only because
`wireguard_flutter_plus` supplies amd64 tunnel/WireGuard DLLs; `stage_boltmeshd.ps1`
rejects arm64 bundles. The other three architectures ship in the same archive and
are left out rather than carried as dead weight.

The Go binding's pseudo-version looks six years older than the DLL, and that is
not a stale pin: the module is versioned by commit date and carries no release
tags, so `go get ...@latest` resolves to the same revision. `0.14.1` is the
*DLL's* version, reported by `wintun.RunningVersion()` once the adapter is up.

## Why it is vendored at all

`golang.zx2c4.com/wintun` loads the DLL at runtime. Nothing in the Go module
embeds it, so it must be a file on disk — see `wintun_windows.go` for how the
path is pinned, and `stage_boltmeshd.ps1` for how it reaches the bundle.

## Upgrading

1. Download the new release archive and check its published SHA2-256.
2. Replace `wintun.dll`; re-verify the file's own SHA2-256 and its Authenticode
   signature (`Get-AuthenticodeSignature` must report `Valid`).
3. Update the table above.
4. `go get golang.zx2c4.com/wintun@latest` — the Go binding and the DLL ship
   independently, so both usually need the same bump.

## Licence

The prebuilt binary is under `LICENSE.txt` in this directory, not the GPL 2.0
that covers Wintun's source. See that file for the redistribution obligations.

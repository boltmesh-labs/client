# Security Policy

BoltMesh Client is the cross-platform WireGuard client: a Flutter app
(Android, iOS/macOS, Windows, Linux) plus `boltmeshd`, the privileged
Linux/Windows helper. This document describes the security controls in those
components and how to report vulnerabilities.

The control plane and infrastructure live in their own repositories
([`backend`](https://github.com/boltmesh-labs/backend),
[`frontend`](https://github.com/boltmesh-labs/frontend),
[`agent`](https://github.com/boltmesh-labs/agent),
[`infra`](https://github.com/boltmesh-labs/infra)); report issues in the
component that owns them.

## Supported Versions

We release patches for security vulnerabilities for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| 0.x     | :x:                |

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues, pull requests, discussions, or bug-report templates.**

Use **GitHub Private Vulnerability Reporting** instead:

1. Open the [Security tab](https://github.com/boltmesh-labs/client/security) of this repository.
2. Select **Report a vulnerability**.
3. Fill in the advisory draft. Only repository maintainers can see it until disclosure is coordinated with you.

Please include:

- Description of the vulnerability and the affected component (`client` app or `boltmeshd`)
- Platform/OS and version tag or commit SHA where the issue was observed
- Steps to reproduce, or a proof of concept (if applicable)
- Potential impact
- A suggested fix, if you have one

**Safe harbor**: we will not pursue, or support action against, anyone researching this project in good faith, provided they respect user privacy, avoid service degradation, neither exfiltrate nor destroy data, and use the channel above rather than exploiting a vulnerability beyond what is needed to demonstrate it.

Non-vulnerability security questions may be raised as public GitHub issues with the `security` label — without including sensitive detail.

## Automated Security Controls

CI runs on every push and pull request targeting `main`/`develop` through `.github/workflows/ci.yml`. Tagged releases (`.github/workflows/default.yml`) reuse that same validation suite via `workflow_call` before building and signing artifacts:

- **Trivy filesystem scanning** (`security` job): fails the build on CRITICAL findings and ignores advisories without an available fix.
- **Test coverage gate**: `flutter test --coverage` plus `tool/coverage_gate.sh 80` enforces a floor on hand-written Dart lines; `validate-boltmeshd` runs `gofmt`, golangci-lint, `deadcode` and `go test ./...` on the Go helper.
- **Generated-code drift check**: `tool/check_generated.sh` regenerates l10n/build_runner output and fails when the committed tree is stale (those files are excluded from analysis).
- **Release signing gates**: tagged `build-android`/`build-windows` jobs fail when their signing secrets are missing rather than publish a debug-signed or unsigned artifact.
- **Release artifact integrity**: tagged releases publish SHA-256 checksums, CycloneDX/SPDX SBOMs, keyless cosign signatures for the Linux packages, and Sigstore build-provenance/SBOM attestations, so downloads are verifiable with `gh attestation verify` and `cosign verify-blob` (see [DEPLOYMENT.md](DEPLOYMENT.md#verifying-a-release)).
- **Pre-commit hooks** (`.pre-commit-config.yaml`): gofmt/golangci-lint for `boltmeshd`, `dart format` + `flutter analyze`, shellcheck, and whitespace/YAML/large-file/merge-conflict guards.
- **CI secret hygiene**: workflows declare explicit least-privilege `permissions:` blocks, and signing material is supplied only through GitHub Actions secrets — never committed to the repository.
- **Automated dependency updates** (`.github/dependabot.yml`): Dependabot opens weekly, grouped PRs per ecosystem — Flutter (`pub`), Android (Gradle), `boltmeshd` (`gomod`) and GitHub Actions — with a release cooldown, so updates land through normal review gated by the `validate*` and `security` jobs above.

Dependabot's **security** updates are a separate pipeline: an advisory with a fix opens a PR immediately, bypassing the weekly schedule and grouping rather than waiting for the next batch.

## Privilege Model

The app is designed to hold no privilege:

- **Linux**: the Flutter app never runs `sudo`, `wg`, or `wg-quick` and never reads the WireGuard device directly. All privileged work goes through `boltmeshd` over `/run/boltmesh/boltmeshd.sock`, a newline-delimited JSON protocol. The socket is `0660 root:boltmesh`; only members of the `boltmesh` group can connect. The daemon validates the single `up` argument (a wg-quick config) before spending privilege — one `[Interface]`, at least one `[Peer]`, parsed key material, a size cap, and a hard reject of the `PreUp`/`PostUp`/`PreDown`/`PostDown`/`SaveConfig` hooks — fixes the interface name and config path, uses `exec.Command` with explicit args (no shell with client data), and runs with `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome`, `PrivateTmp`, restricted address families, and no new namespaces. See [`boltmeshd/README.md`](boltmeshd/README.md).
- **Windows**: the app runs unprivileged; `boltmeshd` runs as a LocalSystem service and owns the WireGuard tunnel service. The app CMake drops the plugin's `requireAdministrator` link flag and the runner only proxies the named pipe. The daemon validates the same `up` config before spending privilege, fixes the tunnel service name, config path and the `wireguard_svc.exe` binary path (never taken from the client — a client-chosen service binary would be LocalSystem code execution), ACLs the pipe to SYSTEM, Administrators and Interactive Users, and sets a protected DACL of SYSTEM + Administrators on the persisted config directory and file (so ProgramData inheritance cannot expose the private key). Because the pipe name is globally predictable, the app also verifies the connected pipe's server process is the one the SCM reports for the `boltmeshd` service before sending a request, so an unprivileged process that pre-created the pipe name cannot capture the WireGuard config. The Installer itself elevates to write Program Files and register the service.
- **Android**: the app requests the `VpnService` permission and the system shows the standard VPN consent dialog on first connect.
- **iOS/macOS**: the Packet Tunnel Provider runs as a Network Extension; the app only sends it `getHandshake` over the `NETunnelProviderSession`.

## Secrets and Data at Rest

- The WireGuard private key, device id and API tokens are stored in platform secure storage (Keychain/Keystore) via `flutter_secure_storage`; the app never writes them to plain files.
- The access JWT is short-lived (15 minutes) and renews proactively before expiry plus once per 401 (single-flight shared retry); the `refresh_token` is an HttpOnly cookie. Logging out revokes the session server-side.
- Byte counters are display-only and never drive heals; handshake reads are read-only and a null/unknown read never heals the tunnel.

## Transport Security

- **TLS by default**: the API base defaults to production HTTPS and release builds refuse `http://` URLs (debug/profile builds allow `localhost` for local development).
- **Optional pinning**: `--dart-define=TLS_PIN_SPKI_SHA256=pin[,pin...]` pins one or more base64 SHA-256 hashes of the server certificate's SubjectPublicKeyInfo (SPKI), which survives certificate renewal while the key is reused.
- **OAuth**: the system browser handles consent. Desktop platforms open an ephemeral loopback listener (`http://127.0.0.1:{port}/callback`); mobile uses the registered `boltmesh://` custom scheme. The provider redirects back with a single-use code that the app exchanges at `POST /auth/native/exchange`.

## Disclosure Policy

1. We acknowledge receipt of your vulnerability report.
2. We investigate and determine the severity.
3. We develop and test a fix.
4. We release a patched version.
5. We publicly disclose the vulnerability after a reasonable delay (typically 90 days), crediting the reporter where desired.

## Best Practices for Operators

If you deploy the BoltMesh client, please:

1. **Run supported versions** — update promptly when patch releases ship.
2. **Verify downloads** — obtain installers and packages only from official GitHub Releases for this repository, then check them against `SHA256SUMS` and the published Sigstore attestations/signatures (see [DEPLOYMENT.md](DEPLOYMENT.md#verifying-a-release)).
3. **Keep TLS verification on** — do not weaken `API_BASE_URL` to `http://` outside throwaway development, and prefer an SPKI pin for pinned deployments.
4. **Keep privilege minimal** — on Linux, only add desktop users who should control the tunnel to the `boltmesh` group. The package uses a validated installer hint or a unique active graphical session, but operators should use the root-only `/usr/libexec/boltmesh/boltmesh-enroll-user --uid UID` command to make any additional enrollment explicit; `boltmeshd` runs as root on enrolled users' behalf. On Windows, the pipe is limited to SYSTEM, Administrators and Interactive Users, and only the installer needs elevation.
5. **Review CI changes as security-sensitive code** — audit modifications to `.github/workflows/`, the signing hooks under `windows/packaging/` and `boltmeshd/packaging/`, and `tool/` with the same scrutiny as source changes.

## Contact

Security-related questions that are **not** vulnerability reports may be raised as public GitHub issues with the `security` label, or discussed privately via a drafted advisory on the [Security tab](https://github.com/boltmesh-labs/client/security).

Thank you for helping keep BoltMesh and our users safe! 🔒

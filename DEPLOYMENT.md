# BoltMesh Client — Deployment

This document covers releasing the BoltMesh client: the tag-driven CI/CD
pipeline, the Android/Linux/Windows artifacts it publishes, and the release
signing gates. For local development see [SETUP.md](SETUP.md); the run-time
`--dart-define`s, per-platform notes and the detailed build commands live in
[README.md](README.md). For contribution guidelines see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Contents

- [1. Release versioning](#1-release-versioning)
- [2. CI/CD pipeline](#2-cicd-pipeline)
- [3. Artifacts and signing](#3-artifacts-and-signing)
- [4. Troubleshooting](#4-troubleshooting)

## 1. Release versioning

The git tag is the release source of truth. Every build job in
`.github/workflows/default.yml` runs `dart run tool/set_release_version.dart`
first to derive `pubspec.yaml`'s `version:` from the `vX.Y.Z` tag (build number
from `GITHUB_RUN_NUMBER`), because both the Android `versionName` and the
fastforge package names/versions are read from pubspec. The checked-in
`version: 0.1.0+1` is a dev placeholder and is not meaningful for tagged
artifacts.

Cut a release by pushing a `v*` tag:

```bash
git tag v1.2.3
git push origin v1.2.3
```

## 2. CI/CD pipeline

CI is split by lifecycle. `.github/workflows/ci.yml` runs the validation jobs on
pushes and pull requests to `main`/`develop`; `.github/workflows/default.yml`
runs on `v*` tags, calls `ci.yml` as a reusable workflow (`workflow_call`) so a
release is built on the same validated commit, then builds and publishes:

| Job | Workflow | Trigger | Checks |
| - | - | - | - |
| `validate` | `ci.yml` | every push/PR, and the release gate | `tool/check_generated.sh`, `flutter analyze --fatal-infos`, `dart format --set-exit-if-changed lib test`, `flutter test --coverage`, `tool/coverage_gate.sh 80` |
| `validate-android` | `ci.yml` | every push/PR, and the release gate | `flutter build apk --debug` |
| `validate-windows` | `ci.yml` | every push/PR, and the release gate | `flutter build windows --debug`, Windows-tagged `boltmeshd` tests |
| `validate-boltmeshd` | `ci.yml` | every push/PR, and the release gate | `gofmt`, golangci-lint (Linux + `GOOS=windows`), `deadcode`, `GOOS=windows` build/vet, `go test ./...` under `boltmeshd/` |
| `security` | `ci.yml` | every push/PR, and the release gate | Trivy filesystem scan (fails on CRITICAL, ignores unfixed advisories) |
| `build-android` | `default.yml` | `v*` tags | `flutter build appbundle --release` + `flutter build apk --release`, signed with the upload key |
| `build-linux` | `default.yml` | `v*` tags | `fastforge release --name=production` → deb + rpm (stages `boltmeshd`) |
| `build-windows` | `default.yml` | `v*` tags | `fastforge release --name=production` → Authenticode-signed Inno Setup `.exe` |
| `release` | `default.yml` | `v*` tags | SBOMs (`Syft`) + `SHA256SUMS`, keyless cosign signatures for the Linux packages, provenance/SBOM attestations, then drafts the GitHub Release with every asset |

Each build job depends on `default.yml`'s single `validate` job — the whole
`ci.yml` suite above — so a failing test or scan blocks the release. The signing
jobs stay in `default.yml` because the keyless cosign identity is bound to the
workflow file path at the tag (see [Verifying a release](#verifying-a-release)).
Each host runs only its own fastforge jobs, which is why the same
`--name=production` release works from both the Linux and Windows runners.

Dependency updates are automated separately by `.github/dependabot.yml`:
weekly grouped PRs (Flutter `pub`, Android Gradle, `boltmeshd` `gomod`, GitHub
Actions) run these same `validate*`/`security` jobs before merge, and
security-advisory updates open immediately rather than waiting for the batch.

## 3. Artifacts and signing

| Platform | Artifact | Integrity |
| - | - | - |
| Android | `.aab` (Play) + `.apk` | upload keystore (`ANDROID_KEYSTORE*` secrets) |
| Linux | `.deb` + `.rpm` | keyless cosign; detached `.sigstore.json` per package |
| Windows | Inno Setup `.exe` | Authenticode (`.pfx` via `WINDOWS_CERTIFICATE*` secrets) |
| All | `SHA256SUMS` | SHA-256 of every binary, itself keyless cosign-signed |
| All | `*.cdx.json` / `*.spdx.json` | CycloneDX + SPDX SBOMs (Syft) |
| All | `boltmesh-<tag>-*.sigstore.json` | raw Sigstore attestation bundles |

The `release` job is the single signing/attestation point. It generates the
checksum manifest and SBOMs, keyless-signs the Linux packages and `SHA256SUMS`
with cosign (the signature is bound to the workflow's OIDC identity at the tag
and recorded in the public Rekor transparency log, so no long-lived signing key
is stored), then attests build provenance and the source SBOM for every
distributable. The attestations also live in GitHub's attestation API
(`gh attestation verify`); the raw bundles are published for offline
verification.

Tagged `build-android` fails when `ANDROID_KEYSTORE` is unset, and tagged
`build-windows` fails when `WINDOWS_CERTIFICATE` is unset — neither will publish
a debug-signed or unsigned release. Local builds keep the debug fallback unless
`REQUIRE_RELEASE_SIGNING=true` is set. Full instructions, including how to
generate the keystore and where the signing hooks live, are in
[README.md](README.md#android-release-build) and
[README.md](README.md#windows-release-build).

### Verifying a release

Download the assets you need, then:

```bash
# 1. Checksums (the manifest also ships a cosign signature).
sha256sum -c SHA256SUMS

# 2. Build provenance / SBOM attestations (GitHub CLI).
gh attestation verify <package>.deb --repo boltmesh-labs/client

# 3. Keyless package signature: the identity is this workflow at the tag.
cosign verify-blob \
  --bundle <package>.deb.sigstore.json \
  --certificate-identity-regexp \
    'https://github.com/boltmesh-labs/client/.github/workflows/default.yml@refs/tags/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  <package>.deb
```

`SHA256SUMS.sigstore.json` and the `boltmesh-<tag>-*.sigstore.json` bundles
verify the same way (the latter hold the provenance and SBOM predicates).

## 4. Troubleshooting

- **`validate` fails on `tool/check_generated.sh`**: generated code
  (`lib/l10n/gen/**`, `*.freezed.dart`, `*.g.dart`) is stale. Run
  `bash tool/check_generated.sh` locally and commit the regenerated files.
- **`validate` fails the coverage floor**: `tool/coverage_gate.sh` enforces 80%
  on hand-written lines only; add tests for the new code.
- **`build-android` fails with "ANDROID_KEYSTORE is not set"**: the repository
  secret is missing. Add the base64 keystore and password under Settings →
  Secrets and variables → Actions (see README).
- **`build-windows` fails with "WINDOWS_CERTIFICATE is not set"**: same, for the
  base64 `.pfx` and its password.
- **`release` fails in the cosign/attestation steps**: these need the job's
  `id-token: write` and `attestations: write` permissions and a public
  repository (the public-good Sigstore instance). Fix and re-run — the job fails
  rather than publish assets nothing can verify.
- **A tagged build is skipped**: `.github/workflows/default.yml` is gated on
  `refs/tags/v*`; confirm the pushed tag starts with `v`.

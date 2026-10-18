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
`.github/workflows/release.yml` runs `dart run tool/set_release_version.dart`
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

CI is security-only. `.github/workflows/ci.yml` runs two jobs: `dependency-review`
on pull requests, and `security` (gitleaks then Trivy) on pull requests, pushes to
`main` and the tag gate. `.github/workflows/release.yml` runs on `v*` tags, calls
`ci.yml` as a reusable workflow (`workflow_call`) so a release is built on a
commit that passed that scan, then builds and publishes:

| Job | Workflow | Trigger | Checks |
| - | - | - | - |
| `security` | `ci.yml` | PR, push to `main`, release gate | `gitleaks` over the full commit history, then Trivy filesystem scan (fails on CRITICAL, ignores unfixed advisories) |
| `dependency-review` | `ci.yml` | PR only | flags a newly introduced moderate-or-worse vulnerability in what the PR pulls in |
| `prepare-release` | `release.yml` | `v*` tags | creates the empty draft GitHub Release that the build jobs upload into (reusing it on a re-run) so the hand-off does not need Actions artifacts |
| `build-android` | `release.yml` | `v*` tags | `flutter build appbundle --release` + `flutter build apk --release`, signed with the upload key. This is the only place the minified variant is assembled, so it is where R8 and `proguard-rules.pro` are exercised |
| `build-linux` | `release.yml` | `v*` tags | `fastforge release --name=production` → deb + rpm (stages `boltmeshd`) |
| `build-windows` | `release.yml` | `v*` tags | `fastforge release --name=production` → Authenticode-signed Inno Setup `.exe` |
| `release` | `release.yml` | `v*` tags | SBOMs (`Syft`) + `SHA256SUMS`, keyless cosign signatures for the Linux packages, provenance/SBOM attestations, then drafts the GitHub Release with every asset |

The per-commit validation — generated code, `flutter analyze`/format, the Dart
tests and coverage floor, the Go lint/test matrix, the native contract checks
and the Windows/Android validation — is a manual gate run before pushing, listed
in [CONTRIBUTING.md](CONTRIBUTING.md#full-validation-gate). It left CI because
the toolchains it needs (Flutter SDK, Go build cache, Gradle, the Android NDK)
populated gigabytes of Actions caches, and the account's shared storage
allowance — the same one whose exhaustion forced the artifact hand-off below —
could not sustain them. The trade is explicit: nothing on GitHub tests a tag
before it is signed.

Each build job depends on `release.yml`'s single `validate` job — the security
scan — so a leaked secret blocks the release. The signing
jobs stay in `release.yml` because the keyless cosign identity is bound to the
workflow file path at the tag (see [Verifying a release](#verifying-a-release)).
Each host runs only its own fastforge jobs, which is why the same
`--name=production` release works from both the Linux and Windows runners.

The build outputs reach `release` as **assets on the draft release**, not as
Actions artifacts: `prepare-release` creates the draft, each build job uploads
into it with `gh release upload --clobber`, and `release` pulls them back with
`gh release download` so it can SBOM, sign and checksum them before adding its
own files. The artifact hand-off had to go because Actions artifacts share the
account's storage allowance with caches and Packages — once that allowance
filled, the upload step failed the whole tag build with "Artifact storage quota
has been hit". Release assets are kept in a separate store, so the draft doubles
as a hand-off that cannot be starved by the account-wide allowance. A side
effect worth knowing: the draft exists from the first uploaded asset onward, so
a tag build that dies halfway leaves a visibly incomplete draft rather than
nothing.

Dependency updates are automated separately by `.github/dependabot.yml`:
weekly grouped PRs (Flutter `pub`, Android Gradle, `boltmeshd` `gomod`, GitHub
Actions) run the `security` and `dependency-review` jobs before merge, and
security-advisory updates open immediately rather than waiting for the batch.
The manual validation gate is the contributor's responsibility on those PRs.

## 3. Artifacts and signing

| Platform | Artifact | Integrity |
| - | - | - |
| Android | `.aab` (Play) + `.apk` | upload keystore (`ANDROID_KEYSTORE*` secrets) |
| Linux | `.deb` + `.rpm` | keyless cosign; detached `.sigstore.json` per package |
| Windows | Inno Setup `.exe` | Authenticode (`.pfx` via `WINDOWS_CERTIFICATE*` secrets) |
| All | `SHA256SUMS` | SHA-256 of every binary, itself keyless cosign-signed |
| All | `*.cdx.json` / `*.spdx.json` | CycloneDX + SPDX SBOMs (Syft) |
| All | `boltmesh-<tag>-*.sigstore.json` | raw Sigstore attestation bundles |

**There is no Apple artifact.** No iOS or macOS build, signing, notarization or
store submission exists in this pipeline, and none can be added without a
`macos`-runner job, an Apple Developer account and a Network Extension
provisioning profile. Shipping an Apple target is blocked on the Xcode
extension target, not on this workflow. See
[README.md → Platform status](README.md#platform-status).

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
    'https://github.com/boltmesh-labs/client/.github/workflows/release.yml@refs/tags/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  <package>.deb
```

`SHA256SUMS.sigstore.json` and the `boltmesh-<tag>-*.sigstore.json` bundles
verify the same way (the latter hold the provenance and SBOM predicates).

## 4. Troubleshooting

- **The manual gate fails on `tool/check_generated.sh`**: generated code
  (`lib/l10n/gen/**`, `*.freezed.dart`, `*.g.dart`) is stale. Run
  `bash tool/check_generated.sh` locally and commit the regenerated files.
- **The manual gate fails the coverage floor**: `tool/coverage_gate.sh` enforces
  80% on hand-written lines only; add tests for the new code. Nothing on GitHub
  re-runs either check, so this is caught before pushing or not at all.
- **`build-android` fails with "ANDROID_KEYSTORE is not set"**: the repository
  secret is missing. Add the base64 keystore and password under Settings →
  Secrets and variables → Actions (see README).
- **`build-windows` fails with "WINDOWS_CERTIFICATE is not set"**: same, for the
  base64 `.pfx` and its password.
- **`release` fails in the cosign/attestation steps**: these need the job's
  `id-token: write` and `attestations: write` permissions and a public
  repository (the public-good Sigstore instance). Fix and re-run — the job fails
  rather than publish assets nothing can verify.
- **A tagged build is skipped**: `.github/workflows/release.yml` is gated on
  `refs/tags/v*`; confirm the pushed tag starts with `v`.

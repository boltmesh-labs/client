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

`.github/workflows/default.yml` runs on pushes and pull requests to
`main`/`develop`, and on `v*` tags:

| Job | Trigger | Checks |
| - | - | - |
| `validate` | every push/PR | `tool/check_generated.sh`, `flutter analyze --fatal-infos`, `dart format --set-exit-if-changed lib test`, `flutter test --coverage`, `tool/coverage_gate.sh 80` |
| `validate-android` | every push/PR | `flutter build apk --debug` |
| `validate-windows` | every push/PR | `flutter build windows --debug` |
| `validate-boltmeshd` | every push/PR | `gofmt`, golangci-lint, `deadcode`, `go test ./...` under `linux/boltmeshd/` |
| `security` | every push/PR | Trivy filesystem scan (fails on CRITICAL, ignores unfixed advisories) |
| `build-android` | `v*` tags | `flutter build appbundle --release` + `flutter build apk --release`, signed with the upload key |
| `build-linux` | `v*` tags | `fastforge release --name=production` → deb + rpm (stages `boltmeshd`) |
| `build-windows` | `v*` tags | `fastforge release --name=production` → Authenticode-signed Inno Setup `.exe` |
| `release` | `v*` tags | drafts a GitHub Release with the AAB/APK, Linux packages and Windows installer |

The build jobs run only on tags and depend on the matching validate job plus
`security`, so a failing test or scan blocks the release. Each host runs only
its own fastforge jobs, which is why the same `--name=production` release works
from both the Linux and Windows runners.

## 3. Artifacts and signing

| Platform | Artifact | Signing |
| - | - | - |
| Android | `.aab` (Play) + `.apk` | upload keystore (`ANDROID_KEYSTORE*` secrets) |
| Linux | `.deb` + `.rpm` | unsigned; package metadata from `distribute_options.yaml` |
| Windows | Inno Setup `.exe` | Authenticode (`.pfx` via `WINDOWS_CERTIFICATE*` secrets) |

Tagged `build-android` fails when `ANDROID_KEYSTORE` is unset, and tagged
`build-windows` fails when `WINDOWS_CERTIFICATE` is unset — neither will publish
a debug-signed or unsigned release. Local builds keep the debug fallback unless
`REQUIRE_RELEASE_SIGNING=true` is set. Full instructions, including how to
generate the keystore and where the signing hooks live, are in
[README.md](README.md#android-release-build) and
[README.md](README.md#windows-release-build).

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
- **A tagged build is skipped**: the jobs are gated on `refs/tags/v*`; confirm
  the pushed tag starts with `v`.

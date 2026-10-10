#!/usr/bin/env python3
"""Cross-build the Android AmneziaWG JNI library for the app's supported ABIs.

Android devices can sleep for longer than WireGuard's keepalive interval. The
upstream Android build changes the Go runtime clock from CLOCK_MONOTONIC to
CLOCK_BOOTTIME so timers account for suspend. Use Go's overlay facility rather
than modifying the installed Go SDK, and fail loudly if a future Go release
changes the assembly sites we rely on.

``--check`` instead gates the module the way the other Go modules are gated:
gofmt, ``go mod tidy``, ``go vet`` and golangci-lint, once per ABI. The APK build
does compile this package, but a compile is not a gate: it says nothing about
vet, lint or formatting. The same NDK toolchain wiring serves both modes, so the
check cannot drift from the build it guards.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path


ABIS = (
    ("armeabi-v7a", "arm", "armv7a-linux-androideabi"),
    ("arm64-v8a", "arm64", "aarch64-linux-android"),
    ("x86", "386", "i686-linux-android"),
    ("x86_64", "amd64", "x86_64-linux-android"),
)

#: Must match ``android/app/build.gradle.kts`` and the CI install step.
NDK_VERSION = "28.2.13676358"


def replace_once(text: str, old: str, new: str, source: Path) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"expected one Go runtime clock site in {source}, found {count}: {old!r}"
        )
    return text.replace(old, new, 1)


def prepare_runtime_overlay(goroot: Path, overlay_dir: Path) -> Path:
    runtime = goroot / "src" / "runtime"
    overlay_dir.mkdir(parents=True, exist_ok=True)
    replace: dict[str, str] = {}

    sites = {
        "sys_linux_386.s": (
            ("$1, 0(SP)\t// CLOCK_MONOTONIC", "$7, 0(SP)\t// CLOCK_BOOTTIME"),
            ("$1, BX\t\t// CLOCK_MONOTONIC", "$7, BX\t\t// CLOCK_BOOTTIME"),
        ),
        "sys_linux_amd64.s": (
            ("$1, DI // CLOCK_MONOTONIC", "$7, DI // CLOCK_BOOTTIME"),
        ),
    }
    for name, changes in sites.items():
        source = runtime / name
        text = source.read_text(encoding="utf-8")
        for old, new in changes:
            text = replace_once(text, old, new, source)
        target = overlay_dir / name
        target.write_text(text, encoding="utf-8")
        replace[str(source.resolve())] = str(target.resolve())

    for name, define in (
        ("sys_linux_arm.s", "#define CLOCK_MONOTONIC\t1"),
        ("sys_linux_arm64.s", "#define CLOCK_MONOTONIC 1"),
    ):
        source = runtime / name
        text = source.read_text(encoding="utf-8")
        text = replace_once(text, define, define.replace("CLOCK_MONOTONIC", "CLOCK_BOOTTIME").replace("1", "7"), source)
        if "CLOCK_MONOTONIC" not in text:
            raise RuntimeError(f"expected CLOCK_MONOTONIC uses in {source}")
        text = text.replace("CLOCK_MONOTONIC", "CLOCK_BOOTTIME")
        target = overlay_dir / name
        target.write_text(text, encoding="utf-8")
        replace[str(source.resolve())] = str(target.resolve())

    overlay = overlay_dir / "overlay.json"
    overlay.write_text(json.dumps({"Replace": replace}, indent=2) + "\n", encoding="utf-8")
    return overlay


def ndk_host_tag() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if system == "linux" and machine in {"x86_64", "amd64"}:
        return "linux-x86_64"
    if system == "darwin":
        return "darwin-arm64" if machine in {"arm64", "aarch64"} else "darwin-x86_64"
    if system == "windows" and machine in {"x86_64", "amd64"}:
        return "windows-x86_64"
    raise RuntimeError(f"unsupported Android NDK host: {system}-{machine}")


def resolve_ndk(explicit: str | None) -> Path:
    """Locates the NDK: explicit argument, then env, then the pinned SDK copy.

    The build gets the path from Gradle; ``--check`` is expected to work from
    the environment alone, so CI and a Makefile can call it without repeating
    the pinned version.
    """
    if explicit:
        return Path(explicit).resolve()
    for name in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        value = os.environ.get(name)
        if value:
            return Path(value).resolve()
    for name in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        sdk = os.environ.get(name)
        if sdk:
            candidate = Path(sdk) / "ndk" / NDK_VERSION
            if candidate.is_dir():
                return candidate
    # Last resort for local runs: the conventional SDK location. CI sets
    # ANDROID_HOME explicitly, so this only ever fires on a dev machine
    # whose shell never exported it.
    home = os.environ.get("HOME")
    if home:
        candidate = Path(home) / "Android" / "Sdk" / "ndk" / NDK_VERSION
        if candidate.is_dir():
            return candidate
    raise RuntimeError(
        "Android NDK not found: pass the NDK directory, set ANDROID_NDK_HOME, "
        f"or install ndk;{NDK_VERSION} under $ANDROID_HOME"
    )


def toolchain_for(ndk: Path) -> tuple[Path, Path]:
    """Returns the (clang, sysroot) pair for this host's NDK toolchain."""
    host = ndk_host_tag()
    toolchain = ndk / "toolchains" / "llvm" / "prebuilt" / host
    compiler = toolchain / "bin" / ("clang.exe" if host.startswith("windows") else "clang")
    sysroot = toolchain / "sysroot"
    if not compiler.is_file():
        raise RuntimeError(f"Android NDK clang is missing: {compiler}")
    return compiler, sysroot


def abi_env(
    compiler: Path,
    sysroot: Path,
    goarch: str,
    target: str,
    overlay: Path | None = None,
) -> dict[str, str]:
    """The cgo/Android environment for one ABI, shared by build and check.

    Every value here is load-bearing: without the NDK toolchain this package
    cannot even be parsed, because it includes <jni.h> and <android/log.h>.
    """
    env = os.environ.copy()
    env.update(
        {
            "CGO_ENABLED": "1",
            "CGO_CFLAGS": f"--target={target}30 --sysroot={sysroot} -fPIC",
            "CGO_LDFLAGS": (
                f"--target={target}30 --sysroot={sysroot} "
                "-Wl,-z,max-page-size=16384 -Wl,-soname,libawg-go.so"
            ),
            "CC": str(compiler),
            "GOARCH": goarch,
            "GOOS": "android",
            "GOTOOLCHAIN": "local",
        }
    )
    if overlay is not None:
        env["GOFLAGS"] = f"-overlay={overlay}"
    return env


def run_checks(module: Path, go: str, compiler: Path, sysroot: Path) -> None:
    """gofmt, ``go mod tidy``, ``go vet`` and golangci-lint over every ABI."""

    def run(label: str, cmd: list[str], env: dict[str, str] | None = None) -> str:
        result = subprocess.run(cmd, cwd=module, env=env, capture_output=True, text=True)
        if result.returncode != 0:
            sys.stdout.write(result.stdout)
            sys.stderr.write(result.stderr)
            raise RuntimeError(f"Android AWG module check failed: {label}")
        return result.stdout.strip()

    unformatted = run("gofmt", ["gofmt", "-l", "."])
    if unformatted:
        raise RuntimeError(f"gofmt needed on:\n{unformatted}")
    # `-diff` prints the required change instead of writing it, so this is
    # check-only and cannot leave the tree dirty.
    run("go mod tidy", [go, "mod", "tidy", "-diff"])

    lint = shutil.which("golangci-lint")
    if lint is None:
        raise RuntimeError(
            "golangci-lint v2 is required to check android/awg-native: "
            "go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.14.0"
        )
    for abi, goarch, target in ABIS:
        env = abi_env(compiler, sysroot, goarch, target)
        run(f"go vet ({abi})", [go, "vet", "-tags=linux", "./..."], env)
        run(f"golangci-lint ({abi})", [lint, "run", "--build-tags", "linux", "./..."], env)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "ndk",
        nargs="?",
        help="Android NDK directory (default: $ANDROID_NDK_HOME, then the pinned copy under $ANDROID_HOME)",
    )
    parser.add_argument("jni_root", nargs="?", help="jniLibs output directory (build mode)")
    parser.add_argument(
        "--check",
        action="store_true",
        help="gofmt, go mod tidy, go vet and golangci-lint every ABI instead of building",
    )
    args = parser.parse_args()

    go = shutil.which("go")
    if go is None:
        raise RuntimeError("Go 1.27 is required to build the Android AWG library")
    go_version = subprocess.check_output([go, "version"], text=True).split()[2]
    if not go_version.startswith("go1.27"):
        raise RuntimeError(f"Android AWG requires Go 1.27, found {go_version}")

    ndk = resolve_ndk(args.ndk)
    compiler, sysroot = toolchain_for(ndk)
    module = Path(__file__).resolve().parents[1] / "android" / "awg-native"

    if args.check:
        run_checks(module, go, compiler, sysroot)
        return

    if not args.jni_root:
        raise SystemExit(
            "usage: build_awg_android.py <ndk-dir> <jniLibs-output-dir> | --check"
        )
    jni_root = Path(args.jni_root).resolve()
    goroot = Path(subprocess.check_output([go, "env", "GOROOT"], text=True).strip())
    build_root = jni_root.parent / "awg-native-build"
    overlay = prepare_runtime_overlay(goroot, build_root / "runtime-overlay")

    for abi, goarch, target in ABIS:
        work = build_root / abi
        work.mkdir(parents=True, exist_ok=True)
        generated = work / "libawg-go.so"
        env = abi_env(compiler, sysroot, goarch, target, overlay)
        subprocess.run(
            [
                go,
                "build",
                "-tags=linux",
                "-trimpath",
                "-buildvcs=false",
                "-buildmode=c-shared",
                "-ldflags=-s -w -buildid=",
                "-o",
                str(generated),
                ".",
            ],
            cwd=module,
            env=env,
            check=True,
        )
        destination = jni_root / abi / "libawg-go.so"
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(generated, destination)


if __name__ == "__main__":
    main()

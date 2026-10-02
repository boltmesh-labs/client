#!/usr/bin/env python3
"""Cross-build the Android AmneziaWG JNI library for the app's supported ABIs.

Android devices can sleep for longer than WireGuard's keepalive interval. The
upstream Android build changes the Go runtime clock from CLOCK_MONOTONIC to
CLOCK_BOOTTIME so timers account for suspend. Use Go's overlay facility rather
than modifying the installed Go SDK, and fail loudly if a future Go release
changes the assembly sites we rely on.
"""

from __future__ import annotations

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


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: build_awg_android.py <ndk-dir> <jniLibs-output-dir>")

    ndk = Path(sys.argv[1]).resolve()
    jni_root = Path(sys.argv[2]).resolve()
    go = shutil.which("go")
    if go is None:
        raise RuntimeError("Go 1.26 is required to build the Android AWG library")
    go_version = subprocess.check_output([go, "version"], text=True).split()[2]
    if not go_version.startswith("go1.26"):
        raise RuntimeError(f"Android AWG requires Go 1.26, found {go_version}")

    goroot = Path(subprocess.check_output([go, "env", "GOROOT"], text=True).strip())
    build_root = jni_root.parent / "awg-native-build"
    overlay = prepare_runtime_overlay(goroot, build_root / "runtime-overlay")

    host = ndk_host_tag()
    toolchain = ndk / "toolchains" / "llvm" / "prebuilt" / host
    compiler = toolchain / "bin" / ("clang.exe" if host.startswith("windows") else "clang")
    sysroot = toolchain / "sysroot"
    if not compiler.is_file():
        raise RuntimeError(f"Android NDK clang is missing: {compiler}")

    module = Path(__file__).resolve().parents[1] / "android" / "awg-native"
    for abi, goarch, target in ABIS:
        work = build_root / abi
        work.mkdir(parents=True, exist_ok=True)
        generated = work / "libawg-go.so"
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
                "GOFLAGS": f"-overlay={overlay}",
                "GOOS": "android",
                "GOTOOLCHAIN": "local",
            }
        )
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

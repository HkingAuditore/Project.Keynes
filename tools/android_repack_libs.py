#!/usr/bin/env python3
"""对导出的 Android APK 做「原生库压缩」后处理。

**只在非 Gradle 导出（`use_gradle_build=false`）时需要。** 走 Gradle 构建时
`gradle_build/compress_native_libraries=true` 已经由 AGP 压缩原生库，本脚本无事可做
（且会白白重签一次）。

背景
----
Godot 非 Gradle 导出时，`EditorExportPlugin.add_shared_object()` 加进去的 .so
（以及 FMOD / GDExtension 的库）在 APK 里是 **STORED（不压缩）**，只有引擎自己的
libgodot_android.so 走 deflate。实测这些库 deflate 后能省 ~11.6 MiB。

官方开关 `gradle_build/compress_native_libraries` 只在启用 Gradle 构建时生效，
纯 APK 导出路径用不上，所以用本脚本在导出后重新打包。

前提：manifest 的 `android:extractNativeLibs="true"`（纯 APK 导出默认就是 true）。
该值下 Android 会把 .so 解压安装到 /data/app，压缩不影响加载；若改成 false
（需要在 APK 内直接 mmap，.so 必须 4K 对齐且不压缩），本脚本会拒绝执行。

用法
----
    python tools/android_repack_libs.py Build/ProjectKeynes.apk
    python tools/android_repack_libs.py <apk> --keystore ~/.android/debug.keystore \
        --alias androiddebugkey --ks-pass android

依赖：Android SDK 的 zipalign / apksigner（默认从 %LOCALAPPDATA%\\Android\\Sdk 找，
可用 --sdk 覆盖）。
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

SOC = ("zipalign", "apksigner")


def find_sdk(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    env = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if env:
        return Path(env)
    cand = Path(os.environ.get("LOCALAPPDATA", "")) / "Android" / "Sdk"
    if cand.is_dir():
        return cand
    sys.exit("找不到 Android SDK，请用 --sdk 指定")


def build_tool(sdk: Path, name: str) -> Path:
    bt = sdk / "build-tools"
    if not bt.is_dir():
        sys.exit(f"缺少 {bt}")
    versions = sorted((p for p in bt.iterdir() if p.is_dir()), key=lambda p: p.name)
    for v in reversed(versions):
        for suffix in (".exe", ".bat", ""):
            p = v / (name + suffix)
            if p.is_file():
                return p
    sys.exit(f"在 {bt} 下找不到 {name}")


def extract_native_libs_flag(apk: Path, aapt2: Path) -> bool | None:
    try:
        out = subprocess.run(
            [str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, OSError):
        return None
    for line in out.splitlines():
        if "extractNativeLibs" in line:
            return line.strip().endswith("true")
    return None


def repack(src: Path, dst: Path) -> tuple[int, int, int]:
    before = after = 0
    changed = 0
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for info in zin.infolist():
            data = zin.read(info.filename)
            is_native = info.filename.startswith("lib/") and info.filename.endswith(".so")
            if is_native:
                before += len(data)
                if info.compress_type == zipfile.ZIP_STORED:
                    changed += 1
                    compress = zipfile.ZIP_DEFLATED
                    after += len(data)  # 占位，真实大小由 zip 写入后统计
                else:
                    compress = zipfile.ZIP_DEFLATED
                    after += len(data)
            else:
                compress = info.compress_type
            new = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            new.compress_type = compress
            new.external_attr = info.external_attr
            new.create_system = info.create_system
            zout.writestr(new, data)
    return before, dst.stat().st_size, changed


def main() -> int:
    ap = argparse.ArgumentParser(description="压缩 APK 内未压缩的原生库并重新签名")
    ap.add_argument("apk")
    ap.add_argument("--sdk")
    ap.add_argument("--keystore", default=str(Path.home() / ".android" / "debug.keystore"))
    ap.add_argument("--alias", default="androiddebugkey")
    ap.add_argument("--ks-pass", default="android")
    ap.add_argument("--keep-original", action="store_true", help="保留原 APK 为 .orig")
    args = ap.parse_args()

    apk = Path(args.apk).resolve()
    if not apk.is_file():
        sys.exit(f"找不到 {apk}")
    sdk = find_sdk(args.sdk)
    zipalign = build_tool(sdk, "zipalign")
    apksigner = build_tool(sdk, "apksigner")
    aapt2 = build_tool(sdk, "aapt2")

    flag = extract_native_libs_flag(apk, aapt2)
    print(f"extractNativeLibs = {flag}")
    if flag is False:
        sys.exit("extractNativeLibs=false：.so 必须不压缩且 4K 对齐，不能做本处理后重新压缩。")

    size_before = apk.stat().st_size
    with tempfile.TemporaryDirectory(dir=str(apk.parent)) as td:
        tmp = Path(td) / "repacked.apk"
        aligned = Path(td) / "aligned.apk"
        _, _, changed = repack(apk, tmp)
        print(f"重新打包：{changed} 个库改为 deflate")

        subprocess.run([str(zipalign), "-f", "-p", "4", str(tmp), str(aligned)], check=True)
        shutil.copy2(aligned, tmp)
        subprocess.run([
            str(apksigner), "sign", "--ks", args.keystore,
            "--ks-pass", f"pass:{args.ks_pass}", "--ks-key-alias", args.alias, str(tmp),
        ], check=True)
        subprocess.run([str(apksigner), "verify", str(tmp)], check=True)

        if args.keep_original:
            apk.replace(apk.with_suffix(apk.suffix + ".orig"))
        shutil.move(str(tmp), str(apk))

    size_after = apk.stat().st_size
    print(f"{size_before/1048576:.1f} MiB -> {size_after/1048576:.1f} MiB "
          f"(-{(size_before-size_after)/1048576:.1f} MiB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

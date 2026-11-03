#!/usr/bin/env python3
"""把 `org.fmod.FMOD` 的 Java stub 编成 classes2.dex 并注入 Godot 导出的 APK。

背景：FMOD 的 Android 运行库在 `JNI_OnLoad` 里 `FindClass("org/fmod/FMOD")` 并
`RegisterNatives`；缺类时 CheckJNI 会把进程 abort 掉。官方类在 FMOD Android SDK 的
`fmod.jar` 里（需要登录 fmod.com 下载），这里先用一份最小 stub 顶上，让
`addons/fmod_android_bootstrap` 的 native 初始化能继续往下走。

它做三件事：
  1. javac 编译 `tools/fmod_java_stub/**.java`
  2. d8 生成 classes.dex
  3. 解包 APK -> 写入 classes2.dex -> 重新打包 -> zipalign -> apksigner 重签

用法：
    python tools/inject_fmod_java_stub.py Build/ProjectKeynes-fmod-emulator.apk
    python tools/inject_fmod_java_stub.py in.apk -o out.apk --min-api 24
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[1]
JAVA_SRC = REPO / "tools" / "fmod_java_stub"
DEFAULT_SDK = pathlib.Path(os.environ.get("ANDROID_HOME") or
                           pathlib.Path(os.environ.get("LOCALAPPDATA", "")) / "Android" / "Sdk")


def find_tool(sdk: pathlib.Path, name: str) -> pathlib.Path:
    build_tools = sdk / "build-tools"
    if not build_tools.is_dir():
        raise SystemExit(f"missing {build_tools}")
    # newest build-tools first
    for version in sorted(build_tools.iterdir(), reverse=True):
        for candidate in (version / name, version / f"{name}.bat", version / f"{name}.exe"):
            if candidate.exists():
                return candidate
    raise SystemExit(f"{name} not found under {build_tools}")


def run(cmd: list[str]) -> None:
    print("[stub] " + " ".join(str(part) for part in cmd))
    result = subprocess.run([str(part) for part in cmd], capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr, file=sys.stderr)
        raise SystemExit(f"command failed: {cmd[0]} (exit {result.returncode})")
    if result.stdout.strip():
        print(result.stdout.strip())


def build_dex(work: pathlib.Path, min_api: int, sdk: pathlib.Path) -> pathlib.Path:
    javac = shutil.which("javac")
    if javac is None:
        raise SystemExit("javac not found on PATH (need a JDK)")
    classes = work / "classes"
    classes.mkdir(parents=True, exist_ok=True)
    sources = sorted(str(p) for p in JAVA_SRC.rglob("*.java"))
    if not sources:
        raise SystemExit(f"no java sources under {JAVA_SRC}")

    # stub 里可能引用 android.content.Context 之类的平台类，编译时要有 android.jar。
    classpath = []
    jar = find_android_jar(sdk, min_api)
    if jar is not None:
        classpath = ["-classpath", str(jar)]
    run([javac, "-nowarn", "-source", "11", "-target", "11", *classpath,
         "-d", str(classes), *sources])

    dex_out = work / "dex"
    dex_out.mkdir(parents=True, exist_ok=True)
    class_files = sorted(str(p) for p in classes.rglob("*.class"))
    d8 = find_tool(sdk, "d8")
    d8_cmd = [str(d8), "--min-api", str(min_api), "--output", str(dex_out)]
    if jar is not None:
        d8_cmd += ["--lib", str(jar)]
    run(d8_cmd + class_files)
    produced = dex_out / "classes.dex"
    if not produced.exists():
        raise SystemExit("d8 did not produce classes.dex")
    return produced


def find_android_jar(sdk: pathlib.Path, min_api: int) -> pathlib.Path | None:
    platforms = sdk / "platforms"
    if not platforms.is_dir():
        return None
    candidates = sorted(platforms.iterdir(), reverse=True)
    for platform in candidates:
        jar = platform / "android.jar"
        if jar.exists():
            return jar
    return None


def inject(apk: pathlib.Path, dex: pathlib.Path, out: pathlib.Path) -> None:
    with zipfile.ZipFile(apk) as src, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as dst:
        # Godot 的 Android 导出本来就可能切出 classes2..N，这里取下一个空位，
        # 不要覆盖别人的 dex（ART 会按名字顺序全部加载）。
        used = {name for name in src.namelist() if name.startswith("classes") and name.endswith(".dex")}
        index = 2
        while f"classes{index}.dex" in used:
            index += 1
        target = f"classes{index}.dex"
        for item in src.infolist():
            data = src.read(item.filename)
            dst.writestr(item, data, compress_type=item.compress_type)
        dst.write(dex, target)
    print(f"[stub] {target} injected -> {out}")


def align_and_sign(apk: pathlib.Path, sdk: pathlib.Path, keystore: pathlib.Path) -> None:
    aligned = apk.with_name(apk.stem + "-aligned.apk")
    zipalign = find_tool(sdk, "zipalign")
    run([str(zipalign), "-f", "-p", "4", str(apk), str(aligned)])
    shutil.move(str(aligned), str(apk))

    apksigner = find_tool(sdk, "apksigner")
    run([str(apksigner), "sign", "--ks", str(keystore), "--ks-pass", "pass:android",
         "--key-pass", "pass:android", "--ks-key-alias", "androiddebugkey", str(apk)])
    run([str(apksigner), "verify", str(apk)])


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("apk")
    ap.add_argument("-o", "--out", default=None)
    ap.add_argument("--min-api", type=int, default=24)
    ap.add_argument("--sdk", default=str(DEFAULT_SDK))
    ap.add_argument("--keystore", default=str(pathlib.Path.home() / ".android" / "debug.keystore"))
    args = ap.parse_args(argv[1:])

    apk = pathlib.Path(args.apk).resolve()
    if not apk.exists():
        raise SystemExit(f"missing apk: {apk}")
    keystore = pathlib.Path(args.keystore)
    if not keystore.exists():
        raise SystemExit(f"missing debug keystore: {keystore}")
    out = pathlib.Path(args.out).resolve() if args.out else apk.with_name(apk.stem + "-jni.apk")
    sdk = pathlib.Path(args.sdk)

    with tempfile.TemporaryDirectory(prefix="fmod_stub_") as tmp:
        work = pathlib.Path(tmp)
        dex = build_dex(work, args.min_api, sdk)
        unsigned = work / apk.name
        inject(apk, dex, unsigned)
        shutil.copy(unsigned, out)
    align_and_sign(out, sdk, keystore)
    print(f"[stub] signed apk: {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

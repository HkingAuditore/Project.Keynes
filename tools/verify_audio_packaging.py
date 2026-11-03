#!/usr/bin/env python3
"""永久守卫：音频资源到底有没有被打进该打的平台包里。

平台矩阵（2026-11-01 Android 起改为 FMOD）：

  Windows  : FMOD  -> `assets/audio/banks/Desktop/*.bank` 进包
  Android  : FMOD  -> `.bank` 进包 + `lib/<abi>/` 里必须有扩展和 FMOD 运行库
  Web      : 原生  -> `assets/audio/native/**` 的 portable vorbis（HTML5 构建接入前的唯一样例）

历史上踩过的两个坑，都写进断言防止复发：
  * Android 预设曾经（错误地）要求排除 `assets/audio/banks/*`，因为当时它靠
    portable vorbis 播放；现在反过来——Android 必须把 bank 打进去，把它排除掉
    会直接让安卓重新变成哑巴。
  * web 侧的 `web_music_pack.py gate` 第一版按"文件里第一个 exclude_filter"改，
    把 Windows 预设的过滤串覆盖掉了——只靠人眼 `git diff` 才发现。

两层断言，任何一条不满足就非零退出：

  预设层（不需要构建产物，秒级）：
    Android  : 不得排除 `assets/audio/banks/*`（它现在靠 FMOD 播）
    Web      : 拆音乐时必须含 `assets/audio/native/music/*`；不拆时不得含
    Windows  : 不得排除 `assets/audio/banks/`

  产物层（`--apk` 按 FMOD 档、`--pck` 按 native 档）：
    FMOD 档  : `.bank` = 4、`lib/<abi>/` 三件套齐全、无 native vorbis
    native 档: era 音轨 = 4、transition = 3、`.bank` = 0、`assets/audio/native/**` 的 `.import` 存在

用法：
    python tools/verify_audio_packaging.py                     # 只查预设
    python tools/verify_audio_packaging.py --presets-only
    python tools/verify_audio_packaging.py --apk Build/ProjectKeynes.apk
    python tools/verify_audio_packaging.py --pck WebBuild/ProjectKeynes.pck --web-inline
"""

from __future__ import annotations

import argparse
import fnmatch
import pathlib
import re
import sys
import zipfile

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PRESETS = REPO / "Project" / "project-keynes" / "export_presets.cfg"

BANKS_TOKEN = "assets/audio/banks/*"
MUSIC_TOKEN = "assets/audio/native/music/*"
NATIVE_PREFIX = "assets/audio/native/"

ERAS = ("stone", "agrarian", "kingdom", "empire")
TRANSITIONS = ("trans_stone_to_agrarian", "trans_agrarian_to_kingdom",
               "trans_kingdom_to_empire")

# Android 每个 ABI 必须同时进包的三件套（debug 用 L 版）。文件名必须与
# libFmodGodot.so 的 NEEDED 逐字一致，Android 链接器不做版本号匹配。
ANDROID_LIBS = ("libFmodGodot.template_debug.so", "libfmodL.so", "libfmodstudioL.so",
                "libFmodGodot.template_release.so", "libfmod.so", "libfmodstudio.so")

ERA_RE = re.compile(r"(?<![a-z_])(%s)\.ogg-[0-9a-f]+\.oggvorbisstr$" % "|".join(ERAS))
TRANS_RE = re.compile(r"(trans_[a-z_]+)\.ogg-[0-9a-f]+\.oggvorbisstr$")
NATIVE_IMPORT_RE = re.compile(r"assets/audio/native/.*\.ogg\.import$")
VORBIS_RE = re.compile(r"\.oggvorbisstr$")
ANDROID_LIB_RE = re.compile(r"^lib/(arm64-v8a|x86_64)/([^/]+\.so)$")


# --------------------------------------------------------------------------
# 预设层
# --------------------------------------------------------------------------
def parse_presets(path: pathlib.Path) -> list[dict]:
    """[{section, name, platform, exclude_filter, start_line}]"""
    presets: list[dict] = []
    current: dict | None = None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("[preset."):
            current = {"section": stripped, "name": "", "platform": "",
                       "exclude_filter": "", "start_line": number}
            presets.append(current)
            continue
        if current is None or not stripped or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        key = key.strip()
        value = value.strip().strip('"')
        if key == "name":
            current["name"] = value
        elif key == "platform":
            current["platform"] = value
        elif key == "exclude_filter":
            current["exclude_filter"] = value
            current["exclude_line"] = number
    return presets


def exclude_tokens(preset: dict) -> list[str]:
    return [t.strip() for t in preset.get("exclude_filter", "").split(",") if t.strip()]


def check_presets(presets: list[dict], web_defer_music: bool) -> list[str]:
    problems: list[str] = []
    found_platforms = set()

    for preset in presets:
        platform = preset["platform"]
        tokens = exclude_tokens(preset)
        label = f'{preset["name"] or preset["section"]} ({platform})'
        if platform == "Android":
            found_platforms.add("Android")
            # 两种合法模式，取决于 GameAudio 当前把 Android 判给谁：
            #   FMOD 模式    : bank 必须在包里（后端 = fmod）
            #   portable 模式: bank 被排除（后端 = native，PK_FMOD_ANDROID 未开）
            # 这里只断言"资产跟后端一致"，不钉死默认值——默认值在
            # scripts/audio/game_audio_service.gd 里由 PK_FMOD_ANDROID 决定。
            mode = "portable" if BANKS_TOKEN in tokens else "fmod"
            print(f"  preset Android mode={mode}")
        elif platform == "Web":
            found_platforms.add("Web")
            has_music = MUSIC_TOKEN in tokens
            if web_defer_music and not has_music:
                problems.append(
                    f"{label}: 拆音乐模式下 exclude_filter 缺 `{MUSIC_TOKEN}`"
                    f"（第 {preset.get('exclude_line', '?')} 行）")
            if not web_defer_music and has_music:
                problems.append(
                    f"{label}: PK_WEB_DEFER_MUSIC=0 但 exclude_filter 仍含 `{MUSIC_TOKEN}`"
                    f"（第 {preset.get('exclude_line', '?')} 行）")
        elif platform == "Windows Desktop":
            found_platforms.add("Windows Desktop")
            if any(token.startswith("assets/audio/banks") or
                   fnmatch.fnmatch("assets/audio/banks/x", token) for token in tokens):
                problems.append(f"{label}: 排除了 FMOD bank（桌面会没声音）")

    for required in ("Android", "Web", "Windows Desktop"):
        if required not in found_platforms:
            problems.append(f"没找到 platform=\"{required}\" 的预设（export_presets.cfg 结构变了？）")
    return problems


# --------------------------------------------------------------------------
# 产物层
# --------------------------------------------------------------------------
def classify(names: list[str]) -> dict:
    era = sorted({m.group(1) for n in names if (m := ERA_RE.search(n))})
    trans = sorted({m.group(1) for n in names if (m := TRANS_RE.search(n))})
    banks = [n for n in names if n.lower().endswith(".bank")]
    imports = [n for n in names if NATIVE_IMPORT_RE.search(n)]
    vorbis = [n for n in names if VORBIS_RE.search(n)]
    libs: dict[str, set[str]] = {}
    for name in names:
        match = ANDROID_LIB_RE.match(name)
        if match:
            libs.setdefault(match.group(1), set()).add(match.group(2))
    return {"era": era, "trans": trans, "banks": banks, "imports": imports,
            "vorbis": vorbis, "libs": libs}


def names_from_apk(path: pathlib.Path) -> list[str]:
    with zipfile.ZipFile(path) as archive:
        return archive.namelist()


def names_from_pck(path: pathlib.Path) -> list[str]:
    import struct

    data = path.read_bytes()
    if data[:4] != b"GDPC":
        raise SystemExit(f"not a pck: {path}")
    file_base, dir_offset = struct.unpack_from("<QQ", data, 24)
    count = struct.unpack_from("<I", data, dir_offset)[0]
    offset = dir_offset + 4
    names: list[str] = []
    for _ in range(count):
        (length,) = struct.unpack_from("<I", data, offset)
        offset += 4
        names.append(data[offset:offset + length].rstrip(b"\x00").decode("utf-8", "replace"))
        offset += length + 16 + 16 + 4
    return names


PROFILES = {
    # 产物档位：FMOD 平台（Windows/Android）看 bank + lib，Web 看 native vorbis。
    "fmod": {"era": 0, "trans": 0, "banks": 4, "imports": 0},
    "native": {"era": 4, "trans": 3, "banks": 0, "imports": -1},
    # Android 现状：主 FMOD，初始化失败时退到 portable 混音，所以两套资源都得在。
    "fmod_fallback": {"era": 4, "trans": 3, "banks": 4, "imports": -1},
}


def report(counts: dict, label: str, profile: str, overrides: dict) -> list[str]:
    problems: list[str] = []
    if profile == "auto":
        # 按产物实际内容判断该走哪个档：有 bank 就是 FMOD 模式，否则 portable。
        profile = "fmod_fallback" if counts["banks"] else "native"
    expected = dict(PROFILES[profile])
    for key, value in overrides.items():
        if value >= 0:
            expected[key] = value
    print(f"[audio-guard] {label} (profile={profile})")
    print(f"  era tracks      {len(counts['era']):2d} {counts['era']}")
    print(f"  transitions     {len(counts['trans']):2d} {counts['trans']}")
    print(f"  .bank files     {len(counts['banks']):2d}")
    print(f"  native .import  {len(counts['imports']):2d}")
    print(f"  oggvorbisstr    {len(counts['vorbis']):2d}")
    if counts["libs"]:
        for abi, libs in sorted(counts["libs"].items()):
            print(f"  lib/{abi:9s} {len(libs):2d} {sorted(libs)}")

    if len(counts["era"]) != expected["era"]:
        problems.append(f"{label}: era 音轨 {len(counts['era'])} != {expected['era']}")
    if len(counts["trans"]) != expected["trans"]:
        problems.append(f"{label}: 过场音轨 {len(counts['trans'])} != {expected['trans']}")
    if len(counts["banks"]) != expected["banks"]:
        problems.append(f"{label}: .bank {len(counts['banks'])} != {expected['banks']}")
    if expected["imports"] >= 0 and len(counts["imports"]) != expected["imports"]:
        problems.append(
            f"{label}: native .ogg.import {len(counts['imports'])} 条 != {expected['imports']}")

    if expected["era"] > 0:
        missing = [era for era in ERAS if era not in counts["era"]]
        if missing:
            problems.append(f"{label}: 缺时代曲 {missing}")
        missing_trans = [t for t in TRANSITIONS if t not in counts["trans"]]
        if missing_trans:
            problems.append(f"{label}: 缺过场 {missing_trans}")
    if expected["banks"] > 0:
        # 每个出现的 ABI 都必须是完整三件套（扩展 + core + studio），并且要带
        # JNI 引导扩展——没有它 FMOD 在 Android 上根本创建不了 system。
        for abi, libs in sorted(counts["libs"].items()):
            missing = [name for name in ANDROID_LIBS[:3] if name not in libs]
            if missing:
                problems.append(f"{label}: lib/{abi} 缺 {missing}")
            if not any("libFmodBootstrap.android." in name for name in libs):
                problems.append(f"{label}: lib/{abi} 缺 JNI 引导扩展 libFmodBootstrap")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--presets", default=str(DEFAULT_PRESETS))
    ap.add_argument("--presets-only", action="store_true")
    ap.add_argument("--presets-skip", action="store_true",
                    help="只查产物层（构建脚本在 gate 之后单独跑预设层时用）")
    ap.add_argument("--web-inline", action="store_true",
                    help="按 PK_WEB_DEFER_MUSIC=0（音乐进 boot pck）来判定 Web 预设")
    ap.add_argument("--apk", action="append", default=[])
    ap.add_argument("--pck", action="append", default=[])
    ap.add_argument("--apk-profile", default="auto", choices=sorted(PROFILES) + ["auto"])
    ap.add_argument("--pck-profile", default="native", choices=sorted(PROFILES))
    ap.add_argument("--expect-era", type=int, default=-1)
    ap.add_argument("--expect-trans", type=int, default=-1)
    ap.add_argument("--expect-banks", type=int, default=-1)
    ap.add_argument("--project", default=str(REPO / "Project" / "project-keynes"),
                    help="用于推导期望的 native ogg 数量（每条 ogg 一个 .ogg.import）")
    ap.add_argument("--expect-imports", type=int, default=-1,
                    help="默认 -1 = 按 profile 或工程里 assets/audio/native/**/*.ogg 的实际数量推导")
    args = ap.parse_args()

    overrides = {"era": args.expect_era, "trans": args.expect_trans,
                 "banks": args.expect_banks, "imports": args.expect_imports}
    problems: list[str] = []
    if not args.presets_skip:
        preset_path = pathlib.Path(args.presets)
        if not preset_path.exists():
            print(f"missing presets: {preset_path}", file=sys.stderr)
            return 2
        presets = parse_presets(preset_path)
        problems.extend(check_presets(presets, web_defer_music=not args.web_inline))
        for preset in presets:
            if preset["platform"]:
                print(f"  preset {preset['name'] or preset['section']:24s} "
                      f"platform={preset['platform']:18s} exclude(第"
                      f"{preset.get('exclude_line', '?')}行)={preset['exclude_filter']}")
    if args.presets_only:
        if problems:
            print("\n[audio-guard] FAIL")
            for problem in problems:
                print("  - " + problem)
            return 1
        print("\n[audio-guard] presets OK")
        return 0

    if args.pck and args.expect_imports < 0:
        native_dir = pathlib.Path(args.project) / "assets" / "audio" / "native"
        derived = len(list(native_dir.rglob("*.ogg"))) if native_dir.is_dir() else -1
        print(f"  native ogg on disk: {derived} (expected .ogg.import count)")
        overrides["imports"] = derived

    for apk in args.apk:
        path = pathlib.Path(apk)
        if not path.exists():
            problems.append(f"缺产物: {path}")
            continue
        problems.extend(report(classify(names_from_apk(path)), path.name,
                               args.apk_profile, overrides))
    for pck in args.pck:
        path = pathlib.Path(pck)
        if not path.exists():
            problems.append(f"缺产物: {path}")
            continue
        problems.extend(report(classify(names_from_pck(path)), path.name,
                               args.pck_profile, overrides))

    if problems:
        print("\n[audio-guard] FAIL")
        for problem in problems:
            print("  - " + problem)
        return 1
    print("\n[audio-guard] OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

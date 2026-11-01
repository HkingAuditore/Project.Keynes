#!/usr/bin/env python3
"""Split the Web music payload into per-era `music_<era>.pck` files.

Why: `assets/audio/native/music/*.ogg` is ~18 MB of the boot pck, but a session only
ever needs the current era's suite plus (occasionally) one transition. The Web shell
can only auto-download one pack, so these are produced separately and mounted at
runtime with `ProjectSettings.load_resource_pack()` after
`engine.rtenv.copyToFS('/tmp/x.pck', bytes)`.

A packed music file needs two entries, exactly like the exporter emits them:

  assets/audio/native/music/stone.ogg.import   <- the [remap] that points at the
                                                  imported `.oggvorbisstr`
  .godot/imported/stone.ogg-<md5>.oggvorbisstr <- the decoded stream itself

The `.ogg` source is NOT needed at runtime (the import cache replaced it).

Usage:
    python tools/web_music_pack.py build  --project Project/project-keynes --out tmp/music_packs
    python tools/web_music_pack.py verify --pck tmp/music_packs/music_stone.pck
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import struct
import sys

ERA_PACKS = {
    "stone": ["stone.ogg"],
    "agrarian": ["agrarian.ogg"],
    "kingdom": ["kingdom.ogg"],
    "empire": ["empire.ogg"],
    "trans": ["trans_stone_to_agrarian.ogg", "trans_agrarian_to_kingdom.ogg",
              "trans_kingdom_to_empire.ogg"],
}
MUSIC_REL = "assets/audio/native/music"
GODOT_VERSION = (4, 6, 2)
HEADER_SIZE = 112
PACK_FLAGS_REL_FILEBASE = 2


def read_import(import_path: pathlib.Path) -> list[str]:
    """`dest_files` out of a `.import` sidecar (paths are res:// absolute)."""
    text = import_path.read_text(encoding="utf-8", errors="replace")
    match = re.search(r"^dest_files=\[(.*?)\]", text, re.MULTILINE | re.DOTALL)
    if not match:
        return []
    return re.findall(r'"(res://[^"]+)"', match.group(1))


def entry_paths(project: pathlib.Path, ogg_name: str) -> list[tuple[str, pathlib.Path]]:
    """[(path inside the pack, source file)] for one music file."""
    src = project / MUSIC_REL / ogg_name
    sidecar = src.with_name(ogg_name + ".import")
    if not sidecar.exists():
        raise SystemExit(f"missing import sidecar: {sidecar}")
    out: list[tuple[str, pathlib.Path]] = [(f"{MUSIC_REL}/{ogg_name}.import", sidecar)]
    dests = read_import(sidecar)
    if not dests:
        raise SystemExit(f"no dest_files in {sidecar}")
    for dest in dests:
        rel = dest.replace("res://", "")
        path = project / rel.replace("/", "\\")
        if not path.exists():
            raise SystemExit(f"imported artifact missing (run godot --import first): {path}")
        out.append((rel, path))
    return out


def write_pck(dest: pathlib.Path, files: list[tuple[str, pathlib.Path]]) -> int:
    """Godot 4 pck (pack_version 3, relative file base, directory at the end)."""
    blobs: list[tuple[str, bytes]] = []
    for pack_path, src in files:
        blobs.append((pack_path, src.read_bytes()))
    # The engine wants the path inside the pack prefixed with res://.
    body = bytearray()
    entries: list[tuple[str, int, int, bytes]] = []
    offset = 0
    for pack_path, data in blobs:
        name = pack_path if pack_path.startswith("res://") else "res://" + pack_path
        entries.append((name, offset, len(data), hashlib.md5(data).digest()))
        body += data
        offset += len(data)
    dir_start = HEADER_SIZE + len(body)
    directory = bytearray()
    directory += struct.pack("<I", len(entries))
    for name, off, size, digest in entries:
        raw = name.encode("utf-8")
        padded = raw + b"\x00" * ((-len(raw)) % 4)
        directory += struct.pack("<I", len(padded))
        directory += padded
        directory += struct.pack("<QQ", off, size)
        directory += digest
        directory += struct.pack("<I", 0)

    header = bytearray()
    header += b"GDPC"
    header += struct.pack("<I", 3)
    header += struct.pack("<III", *GODOT_VERSION)
    header += struct.pack("<I", PACK_FLAGS_REL_FILEBASE)
    header += struct.pack("<Q", HEADER_SIZE)      # file_base
    header += struct.pack("<Q", dir_start)        # directory offset
    header += b"\x00" * (HEADER_SIZE - len(header))

    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(bytes(header) + bytes(body) + bytes(directory))
    return dest.stat().st_size


def cmd_build(args: argparse.Namespace) -> int:
    project = pathlib.Path(args.project).resolve()
    out_dir = pathlib.Path(args.out).resolve()
    total = 0
    for pack_name, oggs in ERA_PACKS.items():
        files: list[tuple[str, pathlib.Path]] = []
        for ogg in oggs:
            files.extend(entry_paths(project, ogg))
        dest = out_dir / f"music_{pack_name}.pck"
        size = write_pck(dest, files)
        total += size
        print(f"{dest.name:22s} {size / 1048576:7.3f} MB  "
              f"({len(files)} entries: {', '.join(oggs)})")
    print(f"\n{'TOTAL':22s} {total / 1048576:7.3f} MB")
    boot = sum((project / MUSIC_REL / ogg).stat().st_size
               for oggs in ERA_PACKS.values() for ogg in oggs)
    print(f"source .ogg total (imported size may differ): {boot / 1048576:.2f} MB")
    return 0


EXCLUDE_TOKEN = f"{MUSIC_REL}/*"


def cmd_gate(args: argparse.Namespace) -> int:
    """Toggle the music exclusion inside the **Web** export preset only.

    `--enable`  = music stays out of the boot pck (default: deferred packs).
    `--disable` = music is packed into the boot pck again (old behaviour).
    The preset file holds every platform's preset, so this walks the sections and
    only edits the block that carries `platform="Web"` — a blind first-match edit
    hits the Windows/Android preset instead (that mistake is why this docstring
    is explicit; see worklog §11).
    """
    preset = pathlib.Path(args.preset).resolve()
    lines = preset.read_text(encoding="utf-8").splitlines(keepends=True)
    section_start = None
    is_web = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[preset.") or stripped.startswith("["):
            section_start = index
            is_web = False
            continue
        if stripped == 'platform="Web"':
            is_web = True
            continue
        if not is_web or not stripped.startswith("exclude_filter="):
            continue
        value = stripped.split("=", 1)[1].strip().strip('"')
        parts = [p.strip() for p in value.split(",") if p.strip()]
        has = EXCLUDE_TOKEN in parts
        if args.enable and has:
            print("[gate] already enabled")
            return 0
        if not args.enable and not has:
            print("[gate] already disabled")
            return 0
        if args.enable:
            parts.append(EXCLUDE_TOKEN)
        else:
            parts = [p for p in parts if p != EXCLUDE_TOKEN]
        lines[index] = 'exclude_filter="' + ", ".join(parts) + '"\n'
        preset.write_text("".join(lines), encoding="utf-8")
        print(f"[gate] music exclusion {'enabled' if args.enable else 'disabled'} "
              f"in the Web preset (line {index + 1})")
        return 0
    print("[gate] no Web preset exclude_filter line found", file=sys.stderr)
    return 1


def cmd_verify(args: argparse.Namespace) -> int:
    pck = pathlib.Path(args.pck).resolve()
    data = pck.read_bytes()
    magic, version = struct.unpack_from("<II", data, 0)
    if magic != 0x43504447:
        print(f"not a pck: {pck}", file=sys.stderr)
        return 1
    file_base, dir_offset = struct.unpack_from("<QQ", data, 24)
    count = struct.unpack_from("<I", data, dir_offset)[0]
    off = dir_offset + 4
    print(f"{pck.name}: version={version} file_base={file_base} dir@{dir_offset} entries={count}")
    for _ in range(count):
        (plen,) = struct.unpack_from("<I", data, off)
        off += 4
        name = data[off:off + plen].rstrip(b"\x00").decode("utf-8", "replace")
        off += plen
        ofs, size = struct.unpack_from("<QQ", data, off)
        off += 32 + 4
        print(f"  {size:9d}  {name}")
    return 0


def main() -> int:
    repo = pathlib.Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build")
    build.add_argument("--project", default=str(repo / "Project" / "project-keynes"))
    build.add_argument("--out", default=str(repo / "tmp" / "music_packs"))
    verify = sub.add_parser("verify")
    verify.add_argument("--pck", required=True)
    gate = sub.add_parser("gate")
    gate.add_argument("--enable", dest="enable", action="store_true")
    gate.add_argument("--disable", dest="enable", action="store_false")
    gate.set_defaults(enable=True)
    gate.add_argument("--preset", default=str(repo / "Project" / "project-keynes"
                                             / "export_presets.cfg"))
    args = ap.parse_args()
    if args.command == "build":
        return cmd_build(args)
    if args.command == "gate":
        return cmd_gate(args)
    return cmd_verify(args)


if __name__ == "__main__":
    raise SystemExit(main())

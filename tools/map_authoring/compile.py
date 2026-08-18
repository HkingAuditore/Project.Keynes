"""Compile author.py → PKAUTH → (optional) headless Godot PKMAP."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    __package__ = "map_authoring"

from .errors import AuthoringError
from .godot_cli import find_godot_exe, godot_project_dir
from .hints import compile_hints
from .pkauth import write_pkauth
from .sandbox import run_author_script

REPO_ROOT = Path(__file__).resolve().parents[2]


def compile_script_to_pkauth(
    source: str,
    out_path: str | Path,
    width: int,
    height: int,
    seed: int,
    sea_level: float,
    timeout_sec: float = 5.0,
) -> dict:
    author = run_author_script(source, width, height, seed, sea_level, timeout_sec)
    compiled = compile_hints(author, width, height, seed, sea_level)
    write_pkauth(out_path, compiled)
    compiled["pkauth_path"] = str(Path(out_path).resolve())
    return compiled


def compile_pkauth_to_pkmap(
    auth_path: str | Path,
    out_path: str | Path,
    godot_exe: str = "",
    project_dir: str = "",
) -> int:
    exe = find_godot_exe(godot_exe)
    project = Path(project_dir) if project_dir else godot_project_dir(REPO_ROOT)
    if not project.is_dir():
        raise AuthoringError("godot_project_missing", "Godot project not found: %s" % project)
    cmd = [
        str(exe),
        "--headless",
        "--path",
        str(project),
        "--script",
        "res://tests/compile_authored_map.gd",
        "--",
        "auth=%s" % Path(auth_path).resolve(),
        "out=%s" % Path(out_path).resolve(),
    ]
    print("[map-authoring] %s" % " ".join(cmd))
    completed = subprocess.run(cmd, check=False)
    if completed.returncode != 0:
        raise AuthoringError(
            "headless_compile_failed",
            "Godot compile_authored_map exited %d" % completed.returncode,
        )
    return completed.returncode


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Author map → PKAUTH / PKMAP")
    parser.add_argument("script", help="author.py with generate(ctx)")
    parser.add_argument("--width", type=int, default=60)
    parser.add_argument("--height", type=int, default=40)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--sea-level", type=float, default=0.50)
    parser.add_argument("--auth", default="", help="PKAUTH output path")
    parser.add_argument("--out", default="", help="PKMAP output path")
    parser.add_argument("--auth-only", action="store_true")
    parser.add_argument("--godot", default="", help="Godot console executable")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)

    script_path = Path(args.script)
    source = script_path.read_text(encoding="utf-8")
    auth_path = Path(args.auth) if args.auth else script_path.with_suffix(".pkauth")
    try:
        compile_script_to_pkauth(
            source,
            auth_path,
            args.width,
            args.height,
            args.seed,
            args.sea_level,
            args.timeout,
        )
        print("[map-authoring] wrote %s" % auth_path)
        if args.auth_only:
            return 0
        out_path = Path(args.out) if args.out else script_path.with_suffix(".pkmap")
        compile_pkauth_to_pkmap(auth_path, out_path, args.godot)
        print("[map-authoring] wrote %s" % out_path)
        return 0
    except AuthoringError as exc:
        print("[map-authoring] FAIL %s: %s" % (exc.code, exc.message), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

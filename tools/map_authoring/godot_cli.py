"""Locate the Godot 4.6 console executable used by headless-perf."""

from __future__ import annotations

import os
from pathlib import Path

from .errors import AuthoringError

_CANDIDATES = (
    r"D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe",
    r"D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe",
)

# GODOT_BIN is the repo-wide convention; GODOT_EXE stays supported for callers
# that predate it.
_ENV_VARS = ("GODOT_BIN", "GODOT_EXE")


def find_godot_exe(explicit: str = "") -> Path:
    if explicit:
        path = Path(explicit)
        if path.is_file():
            return path
        raise AuthoringError("godot_missing", "GODOT exe not found: %s" % explicit)
    for name in _ENV_VARS:
        env = os.environ.get(name, "").strip()
        if not env:
            continue
        path = Path(env)
        if path.is_file():
            return path
        raise AuthoringError("godot_missing", "%s is set but missing: %s" % (name, env))
    for raw in _CANDIDATES:
        path = Path(raw)
        if path.is_file():
            return path
    raise AuthoringError(
        "godot_missing",
        "Set GODOT_BIN to Godot_v4.6.2-stable_win64_console.exe",
    )


def godot_project_dir(repo_root: Path) -> Path:
    return repo_root / "Project" / "project-keynes"

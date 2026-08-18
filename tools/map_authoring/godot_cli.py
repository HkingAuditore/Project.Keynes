"""Locate the Godot 4.6 console executable used by headless-perf."""

from __future__ import annotations

import os
from pathlib import Path

from .errors import AuthoringError

_CANDIDATES = (
    r"F:\Developent\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe",
    r"D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe",
    r"D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64.exe",
)


def find_godot_exe(explicit: str = "") -> Path:
    if explicit:
        path = Path(explicit)
        if path.is_file():
            return path
        raise AuthoringError("godot_missing", "GODOT exe not found: %s" % explicit)
    env = os.environ.get("GODOT_EXE", "").strip()
    if env:
        path = Path(env)
        if path.is_file():
            return path
        raise AuthoringError("godot_missing", "GODOT_EXE is set but missing: %s" % env)
    for raw in _CANDIDATES:
        path = Path(raw)
        if path.is_file():
            return path
    raise AuthoringError(
        "godot_missing",
        "Set GODOT_EXE to Godot_v4.6.2-stable_win64_console.exe",
    )


def godot_project_dir(repo_root: Path) -> Path:
    return repo_root / "Project" / "project-keynes"

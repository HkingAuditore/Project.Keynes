"""Locate the Godot 4.6 console executable used by headless-perf."""

from __future__ import annotations

import os
from pathlib import Path

from .errors import AuthoringError

_REPO_ROOT = Path(__file__).resolve().parents[2]
_ABOVE_REPO = _REPO_ROOT.parent
_GRAND_REPO = _ABOVE_REPO.parent
_NAMES = ("Godot_v4.6.2-stable_win64_console.exe", "Godot_v4.6.2-stable_win64.exe")
_ZIP_DIR = "Godot_v4.6.2-stable_win64.exe"

# Known local installs, derived from where this repo actually is: the official zip
# is often extracted next to the repo, and a directory named *.exe means the binary
# sits one level deeper. Console builds are listed before the GUI ones.
_CANDIDATES = tuple(
    str(base / part)
    for name in _NAMES
    for base in (_REPO_ROOT, _ABOVE_REPO, _GRAND_REPO)
    for part in ((name,), (_ZIP_DIR, name))
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

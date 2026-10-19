"""Make the Windows build work when ``reg.exe`` is unavailable.

SCons discovers MSVC through vswhere and the registry, and the vcvars scripts
find the Windows SDK with ``reg query`` (see ``vsdevcmd/core/winsdk.bat``). When
a sandbox or security policy blocks ``reg.exe``, both paths fail silently in
different ways:

* SCons keeps the highest install it can enumerate, which on this machine is a
  toolset-only "VS 18" BuildTools that ships no Windows SDK at all;
* vcvars then leaves ``WindowsSdkDir`` empty, so ``INCLUDE`` never gains
  ``...\\10\\Include\\<ver>\\ucrt`` and every file dies on ``crtdbg.h``.

This module repairs both halves without needing the registry:

1. pick the newest complete MSVC toolset (``cl.exe`` + ``yvals.h`` present);
2. pick the newest Windows SDK that has ``ucrt/crtdbg.h`` and ``ucrt.lib``;
3. prepend those dirs onto ``INCLUDE``/``LIB``/``PATH`` in ``os.environ`` so
   compiler child processes inherit them no matter which setup path SCons takes;
4. as a belt-and-braces measure, seed ``MSVC_USE_SCRIPT`` so the same toolset is
   selected even if ``reg.exe`` becomes available again.

``Environment.__init__`` applies keyword arguments before it initialises tools,
which is why seeding ``MSVC_USE_SCRIPT`` here is enough to influence detection.
"""

from __future__ import annotations

import os
from pathlib import Path

import SCons.Environment

_VCVARS_RELATIVE = Path("VC") / "Auxiliary" / "Build" / "vcvars64.bat"
_PROGRAM_FILES = Path(os.environ.get("ProgramFiles", r"C:\Program Files"))
_PROGRAM_FILES_X86 = Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"))

# Visual Studio 2022 first: it is what godot-cpp 4.x targets, so it wins over a
# newer preview install whose SDK pairing may not be present.
_INSTALL_ROOTS = (
    _PROGRAM_FILES / "Microsoft Visual Studio" / "2022",
    _PROGRAM_FILES_X86 / "Microsoft Visual Studio" / "2022",
    _PROGRAM_FILES_X86 / "Microsoft Visual Studio",
    _PROGRAM_FILES / "Microsoft Visual Studio",
)


def _version_key(name: str) -> tuple[int, ...]:
    parts = []
    for chunk in name.split("."):
        parts.append(int(chunk) if chunk.isdigit() else 0)
    return tuple(parts)


def _install_dirs() -> list[Path]:
    found: list[Path] = []
    for root in _INSTALL_ROOTS:
        if not root.is_dir():
            continue
        for edition in sorted(root.iterdir()):
            if (edition / _VCVARS_RELATIVE).is_file():
                found.append(edition)
    return found


def _pick_toolset(install: Path) -> Path | None:
    tools = install / "VC" / "Tools" / "MSVC"
    if not tools.is_dir():
        return None
    usable = [
        candidate for candidate in tools.iterdir()
        if (candidate / "bin" / "Hostx64" / "x64" / "cl.exe").is_file()
        and (candidate / "include" / "yvals.h").is_file()
    ]
    if not usable:
        return None
    return max(usable, key=lambda candidate: _version_key(candidate.name))


def _pick_sdk_version(kits: Path) -> str:
    best = ""
    for include in kits.iterdir():
        if not (include / "ucrt" / "crtdbg.h").is_file():
            continue
        if not (kits.parent / "Lib" / include.name / "ucrt" / "x64" / "ucrt.lib").is_file():
            continue
        if not best or _version_key(include.name) > _version_key(best):
            best = include.name
    return best


def _existing(*paths: Path) -> list[str]:
    return [str(path) for path in paths if path.is_dir()]


def _prepend_env(name: str, entries: list[str]) -> None:
    if not entries:
        return
    current = os.environ.get(name, "")
    kept = [part for part in current.split(os.pathsep) if part]
    lowered = {part.lower() for part in entries}
    merged = entries + [part for part in kept if part.lower() not in lowered]
    os.environ[name] = os.pathsep.join(merged)


def _repair_environment() -> tuple[str, dict[str, list[str]]]:
    """Returns (vcvars path to pin, path additions per env var name)."""

    toolset = None
    vcvars = ""
    for install in _install_dirs():
        candidate = _pick_toolset(install)
        if candidate is not None:
            toolset = candidate
            vcvars = str(install / _VCVARS_RELATIVE)
            break
    if toolset is None:
        return "", {}

    kits = _PROGRAM_FILES_X86 / "Windows Kits" / "10"
    sdk_version = _pick_sdk_version(kits / "Include") if (kits / "Include").is_dir() else ""
    if not sdk_version:
        return "", {}

    host_bin = toolset / "bin" / "Hostx64" / "x64"
    include = toolset / "include"
    lib = toolset / "lib" / "x64"
    sdk_include = kits / "Include" / sdk_version
    sdk_lib = kits / "Lib" / sdk_version

    additions = {
        "PATH": _existing(
            host_bin,
            kits / "bin" / sdk_version / "x64",
        ),
        "INCLUDE": _existing(
            include,
            toolset / "atlmfc" / "include",
            sdk_include / "ucrt",
            sdk_include / "um",
            sdk_include / "shared",
            sdk_include / "winrt",
        ),
    }
    libs = _existing(
        lib,
        toolset / "atlmfc" / "lib" / "x64",
        sdk_lib / "ucrt" / "x64",
        sdk_lib / "um" / "x64",
    )
    additions["LIB"] = libs
    additions["LIBPATH"] = libs
    return vcvars, additions


def _apply_to_environ(additions: dict[str, list[str]]) -> None:
    for name, entries in additions.items():
        _prepend_env(name, entries)


_PINNED_VCVARS = ""
_PATH_ADDITIONS: dict[str, list[str]] = {}

if os.environ.get("MSVC_USE_SCRIPT") != "0":
    _PINNED_VCVARS, _PATH_ADDITIONS = _repair_environment()

if not _PINNED_VCVARS.endswith(".bat"):
    _PINNED_VCVARS = ""

# Both channels are needed. Touching os.environ only helps if SCons has not
# snapshotted it yet, which depends on when the construction environment is
# built; re-applying to each Environment after __init__ covers the other case.
_apply_to_environ(_PATH_ADDITIONS)

if _PATH_ADDITIONS:
    print("site_init: MSVC/SDK include+lib paths injected"
          f" ({len(_PATH_ADDITIONS['INCLUDE'])} include dirs)")

if _PINNED_VCVARS:
    print(f"site_init: MSVC toolchain pinned to {_PINNED_VCVARS}")

if _PINNED_VCVARS or _PATH_ADDITIONS:
    _original_init = SCons.Environment.Base.__init__

    def _init_with_pinned_msvc(self, *args, **kwargs):
        if _PINNED_VCVARS:
            kwargs.setdefault("MSVC_USE_SCRIPT", _PINNED_VCVARS)
        _original_init(self, *args, **kwargs)
        for name, entries in _PATH_ADDITIONS.items():
            self.PrependENVPath(name, entries, delete_existing=False)

    SCons.Environment.Base.__init__ = _init_with_pinned_msvc

    SCons.Environment.Base.__init__ = _init_with_pinned_msvc

"""The agent's working tree: one full checkout reused across runs, so the Godot import cache
(`.godot/`, ignored) and SCons objects survive. Tracked files are reset before every run."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Iterator

from common import must, sh
from ticket import touching

SCRATCH = ".factory-"
GODOT_CPP = "gdext/godot-cpp"


def git(workdir: str, *args: str) -> str:
    return must(["git", "-C", workdir, *args]).rstrip("\n")


def common_dir(path: str) -> str:
    d = git(path, "rev-parse", "--git-common-dir")
    return str((Path(path) / d).resolve()) if not os.path.isabs(d) else d


def ensure(runner_dir: str, workdir: str, ref: str) -> None:
    if (Path(workdir) / ".git").exists():
        return
    must(["git", "-C", runner_dir, "worktree", "add", "--detach", workdir, ref], timeout=3600)
    main = str(Path(common_dir(runner_dir)).parent)
    reference = Path(main) / GODOT_CPP
    args = ["git", "-C", workdir, "submodule", "update", "--init", GODOT_CPP]
    if (reference / ".git").exists():
        args[5:5] = ["--reference", str(reference)]  # after "update": git submodule update --reference X
    must(args, timeout=3600)


def prepare(workdir: str, remote: str, base: str, branch: str) -> str:
    """Reset the tree and put `branch` at `remote/base`. Returns the base commit."""
    git(workdir, "fetch", "--prune", remote)
    git(workdir, "reset", "--hard", "-q")
    git(workdir, "clean", "-fdq")
    git(workdir, "checkout", "-q", "-B", branch, f"{remote}/{base}")
    must(["git", "-C", workdir, "submodule", "update", "--init", "--checkout", "--force", GODOT_CPP],
         timeout=3600)
    git(str(Path(workdir) / GODOT_CPP), "clean", "-fdq")
    return git(workdir, "rev-parse", "HEAD")


def head(workdir: str) -> str:
    return git(workdir, "rev-parse", "HEAD")


def changed(workdir: str, base: str) -> list[str]:
    tracked = git(workdir, "diff", "--name-only", "--no-renames", "--ignore-submodules=none", "-z", base)
    untracked = git(workdir, "ls-files", "--others", "--exclude-standard", "-z")
    return sorted({f for f in (tracked + untracked).split("\0") if f and not f.startswith(SCRATCH)})


def scope(cfg: dict, files: list[str]) -> tuple[list[str], list[str], list[str]]:
    return (touching(files, cfg["paths"]["forbidden"]),
            touching(files, cfg["paths"]["needsHuman"]),
            touching(files, cfg["checks"]["nativePaths"]))


def dirty(workdir: str) -> bool:
    return bool(changed(workdir, "HEAD"))


def restore(workdir: str, path: str) -> None:
    """Undo build outputs in a tracked folder (the native build rewrites tracked libraries)."""
    sh(["git", "-C", workdir, "checkout", "--", path])
    sh(["git", "-C", workdir, "clean", "-fdq", "--", path])


def _write_patch(workdir: str, base: str, path: Path, *files: str, ignore_submodules: str) -> None:
    git(workdir, "add", "-A", "-N", "--", *files)
    git(workdir, "diff", "--binary", "--no-ext-diff", "--no-textconv", "--submodule=short",
        f"--ignore-submodules={ignore_submodules}", f"--output={path.absolute()}", base, "--", *files)


def _submodule_checkouts(root: Path) -> Iterator[Path]:
    # Use tracked gitlinks so changes to .gitmodules cannot hide a checked-out submodule.
    entries = git(str(root), "ls-files", "--stage", "-z").split("\0")
    paths = {entry.partition("\t")[2] for entry in entries if entry.startswith("160000 ")}
    for name in sorted(paths):
        directory = root / name
        if (directory / ".git").exists():
            yield directory
            yield from _submodule_checkouts(directory)


def save_patch(workdir: str, base: str, path: Path) -> list[Path]:
    _write_patch(workdir, base, path, ".", f":(top,exclude,glob){SCRATCH}*", ignore_submodules="none")
    saved = [path]
    root = Path(workdir)
    for directory in _submodule_checkouts(root):
        relative = directory.relative_to(root).as_posix()
        # Escape underscores so e.g. a/b and a__b produce distinct filenames.
        name = relative.replace("%", "%25").replace("_", "%5F").replace("/", "__")
        subpatch = path.with_name(f"{path.stem}.{name}{path.suffix}")
        _write_patch(str(directory), "HEAD", subpatch, ".", ignore_submodules="dirty")
        if subpatch.stat().st_size:
            saved.append(subpatch)
        else:
            subpatch.unlink()
    return saved


def patch_notice(paths: list[Path]) -> str:
    return "Saved patches: " + ", ".join(f"`{path}`" for path in paths)


def commit(workdir: str, message: str) -> str:
    git(workdir, "add", "-A", "--", ".", f":(top,exclude,glob){SCRATCH}*")
    must(["git", "-C", workdir, "commit", "-q", "-F", "-"], stdin=message)
    return head(workdir)


def push(workdir: str, remote: str, branch: str) -> None:
    git(workdir, "push", "-q", "--force-with-lease", remote, f"HEAD:refs/heads/{branch}")


def scratch(workdir: str, name: str) -> str | None:
    p = Path(workdir) / f"{SCRATCH}{name}"
    if p.exists():
        text = p.read_text(encoding="utf-8")
        p.unlink()
        return text
    return None

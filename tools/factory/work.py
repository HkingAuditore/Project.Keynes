"""The agent's working tree: one full checkout reused across runs, so the Godot import cache
(`.godot/`, ignored) and SCons objects survive. Tracked files are reset before every run."""

from __future__ import annotations

import os
from pathlib import Path

from common import must, sh

SCRATCH = ".factory-"


def git(workdir: str, *args: str) -> str:
    return must(["git", "-C", workdir, *args]).strip()


def common_dir(path: str) -> str:
    d = git(path, "rev-parse", "--git-common-dir")
    return str((Path(path) / d).resolve()) if not os.path.isabs(d) else d


def ensure(runner_dir: str, workdir: str, ref: str) -> None:
    if not (Path(workdir) / ".git").exists():
        must(["git", "-C", runner_dir, "worktree", "add", "--detach", workdir, ref], timeout=3600)
    main = str(Path(common_dir(runner_dir)).parent)
    reference = Path(main) / "gdext" / "godot-cpp"
    args = ["git", "-C", workdir, "submodule", "update", "--init", "gdext/godot-cpp"]
    if (reference / ".git").exists():
        args[4:4] = ["--reference", str(reference)]
    must(args, timeout=3600)


def prepare(workdir: str, remote: str, base: str, branch: str) -> str:
    """Reset the tree and put `branch` at `remote/base`. Returns the base commit."""
    git(workdir, "fetch", "--prune", remote)
    git(workdir, "reset", "--hard", "-q")
    git(workdir, "clean", "-fdq")
    git(workdir, "checkout", "-q", "-B", branch, f"{remote}/{base}")
    must(["git", "-C", workdir, "submodule", "update", "--init", "gdext/godot-cpp"], timeout=3600)
    return git(workdir, "rev-parse", "HEAD")


def head(workdir: str) -> str:
    return git(workdir, "rev-parse", "HEAD")


def changed(workdir: str, base: str) -> list[str]:
    tracked = git(workdir, "diff", "--name-only", base).splitlines()
    untracked = git(workdir, "ls-files", "--others", "--exclude-standard").splitlines()
    return sorted({f for f in tracked + untracked if f and not Path(f).name.startswith(SCRATCH)})


def dirty(workdir: str) -> bool:
    return bool(changed(workdir, "HEAD"))


def restore(workdir: str, path: str) -> None:
    """Undo build outputs in a tracked folder (the native build rewrites tracked libraries)."""
    sh(["git", "-C", workdir, "checkout", "--", path])
    sh(["git", "-C", workdir, "clean", "-fdq", "--", path])


def commit(workdir: str, message: str) -> str:
    git(workdir, "add", "-A", "--", ".", f":(exclude){SCRATCH}*")
    must(["git", "-C", workdir, "commit", "-q", "-F", "-"], stdin=message)
    return head(workdir)


def push(workdir: str, remote: str, branch: str) -> None:
    git(workdir, "push", "-q", "--force-with-lease", remote, f"HEAD:refs/heads/{branch}")


def scratch(workdir: str, name: str) -> str | None:
    p = Path(workdir) / f"{SCRATCH}{name}"
    if p.exists():
        text = p.read_text(encoding="utf-8").strip()
        p.unlink()
        return text
    return None

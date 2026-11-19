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


def _is_sparse(workdir: str) -> bool:
    # The effective config includes worktree overrides when worktreeConfig is enabled.
    args = ["git", "-C", workdir]
    config = sh([*args, "config", "--type=bool", "--get", "core.sparseCheckout"])
    if config.ok and config.out.strip() == "true":
        return True
    if not config.ok and (config.code != 1 or config.err):
        raise RuntimeError(f"could not read sparse checkout config in {workdir}: {config.err.strip()}")
    patterns = sh([*args, "sparse-checkout", "list"], env={"LC_ALL": "C"})
    if patterns.ok and patterns.out.strip():
        return True
    if not patterns.ok and (patterns.code != 128 or patterns.err.strip() != "fatal: this worktree is not sparse"):
        raise RuntimeError(f"could not list sparse checkout patterns in {workdir}: {patterns.err.strip()}")
    # Turning off the config alone can leave skip-worktree entries invisible to ls-files --deleted.
    entries = git(workdir, "ls-files", "--sparse", "-t", "-z")
    return any(entry.startswith("S ") for entry in entries.split("\0"))


def _require_complete(workdir: str, *paths: str) -> None:
    if _is_sparse(workdir):
        raise RuntimeError(f"incomplete work tree at {workdir}: sparse checkout is still active")
    deleted = git(workdir, "ls-files", "--deleted", "-z", "--", *paths)
    if deleted:
        missing = ", ".join(repr(path) for path in deleted.split("\0") if path)
        raise RuntimeError(f"incomplete work tree at {workdir}: missing tracked files {missing}")


def ensure(runner_dir: str, workdir: str, ref: str) -> None:
    if (Path(workdir) / ".git").exists():
        return
    must(["git", "-C", runner_dir, "worktree", "add", "--no-checkout", "--detach", workdir, ref], timeout=3600)
    git(workdir, "sparse-checkout", "disable")
    # With --no-checkout the index can be empty, so disabling sparsity alone may write no files.
    git(workdir, "reset", "--hard", "-q", "HEAD")
    main = str(Path(common_dir(runner_dir)).parent)
    reference = Path(main) / GODOT_CPP
    args = ["git", "-C", workdir, "submodule", "update", "--init", GODOT_CPP]
    if (reference / ".git").exists():
        args[5:5] = ["--reference", str(reference)]  # after "update": git submodule update --reference X
    must(args, timeout=3600)
    _require_complete(str(Path(workdir) / GODOT_CPP))


def prepare(workdir: str, remote: str, base: str, branch: str) -> str:
    """Reset the tree and put `branch` at `remote/base`. Returns the base commit."""
    git(workdir, "fetch", "--prune", remote)
    return checkout(workdir, f"{remote}/{base}", branch=branch)


def checkout(workdir: str, ref: str, *, branch: str | None = None) -> str:
    """Materialize a full checkout without fetching or moving the requested ref."""
    if _is_sparse(workdir):
        git(workdir, "sparse-checkout", "disable")
    git(workdir, "reset", "--hard", "-q")
    git(workdir, "clean", "-fdq")
    target = ["-B", branch] if branch else ["--detach"]
    git(workdir, "checkout", "-q", *target, ref)
    update_godot_cpp(workdir)
    _require_complete(workdir, ".", f":(top,exclude,literal){GODOT_CPP}")
    return head(workdir)


def update_godot_cpp(workdir: str) -> None:
    submodule = Path(workdir) / GODOT_CPP
    if (submodule / ".git").exists() and _is_sparse(str(submodule)):
        git(str(submodule), "sparse-checkout", "disable")
    must(["git", "-C", workdir, "submodule", "update", "--init", "--checkout", "--force", GODOT_CPP],
         timeout=3600)
    git(str(submodule), "clean", "-fdq")
    _require_complete(str(submodule))


def head(workdir: str) -> str:
    return git(workdir, "rev-parse", "HEAD")


def changed(workdir: str, base: str, merge_parent: str | None = None) -> list[str]:
    def differs(parent: str) -> set[str]:
        return set(git(workdir, "diff", "--name-only", "--no-renames", "--ignore-submodules=none",
                       "-z", parent).split("\0"))

    tracked = differs(base)
    if merge_parent is not None:
        tracked &= differs(merge_parent)
    untracked = git(workdir, "ls-files", "--others", "--exclude-standard", "-z")
    return sorted(f for f in tracked.union(untracked.split("\0")) if f and not f.startswith(SCRATCH))


def merge_head(workdir: str) -> str | None:
    result = sh(["git", "-C", workdir, "rev-parse", "--verify", "-q", "MERGE_HEAD"])
    if result.ok:
        return result.out.strip()
    if result.code == 1 and not result.err:
        return None
    raise RuntimeError(f"could not read MERGE_HEAD: {result.err.strip()}")


def unmerged(workdir: str) -> dict[str, dict[str, str]]:
    conflicts: dict[str, dict[str, str]] = {}
    for entry in git(workdir, "ls-files", "--unmerged", "-z").split("\0"):
        if entry:
            info, _, path = entry.partition("\t")
            mode, _, stage = info.split()
            conflicts.setdefault(path, {})[stage] = mode
    return conflicts


def stage_zero_entries(workdir: str) -> dict[str, tuple[str, str]]:
    entries = {}
    for entry in filter(None, git(workdir, "ls-files", "--stage", "-z").split("\0")):
        info, _, path = entry.partition("\t")
        mode, blob, stage = info.split()
        if stage == "0":
            entries[path] = (mode, blob)
    return entries


def changes_outside_conflicts(workdir: str, clean_entries: dict[str, tuple[str, str]],
                              conflicts: list[str]) -> list[str]:
    current = stage_zero_entries(workdir)
    changed_entries = {p for p in clean_entries.keys() | current.keys() if clean_entries.get(p) != current.get(p)}
    unstaged = git(workdir, "diff", "--name-only", "--no-renames", "--ignore-submodules=none", "-z")
    untracked = git(workdir, "ls-files", "--others", "--exclude-standard", "-z")
    return sorted(changed_entries.union(unstaged.split("\0"), untracked.split("\0")) - set(conflicts) - {""})


def merge_from(workdir: str, ref: str) -> str | None:
    result = sh(["git", "-C", workdir, "-c", "rerere.enabled=false",
                 "merge", "--no-ff", "--no-commit", ref])
    parent = merge_head(workdir)
    if not result.ok and not (parent and unmerged(workdir)):
        raise RuntimeError(f"could not merge {ref}: {(result.err or result.out).strip()}")
    return parent


def binary_conflicts(workdir: str, head: str, parent: str, paths: list[str]) -> list[str]:
    if not paths:
        return []
    stats = git(workdir, "diff", "--numstat", "--no-renames", "--no-textconv", "--no-ext-diff",
                "-z", head, parent, "--", *[f":(top,literal){p}" for p in paths])
    return sorted(entry.split("\t", 2)[2] for entry in stats.split("\0") if entry.startswith("-\t-\t"))


def conflict_markers(workdir: str, paths: list[str]) -> list[str]:
    if not paths:
        return []
    markers = r"^(<{7,}|>{7,}|\|{7,})([[:space:]]|$)|^={7,}[[:space:]]*$"
    result = sh(["git", "-C", workdir, "grep", "-I", "-l", "-z", "-E", "--untracked", "-e", markers,
                 "--", *[f":(top,literal){p}" for p in paths]])
    if result.code not in (0, 1) or result.err:
        raise RuntimeError(f"could not check for conflict markers: {result.err.strip()}")
    return sorted(filter(None, result.out.split("\0")))


def remote_head(workdir: str, remote: str, branch: str) -> str | None:
    ref = f"refs/heads/{branch}"
    return git(workdir, "ls-remote", "--refs", remote, ref).partition("\t")[0] or None


def scope(cfg: dict, files: list[str]) -> tuple[list[str], list[str], list[str]]:
    return (touching(files, cfg["paths"]["forbidden"]),
            touching(files, cfg["paths"]["needsHuman"]),
            touching(files, cfg["checks"]["nativePaths"]))


def binary_changes(cfg: dict, files: list[str]) -> list[str]:
    return touching(files, [cfg["paths"]["trackedBinaries"]])


def dirty(workdir: str) -> bool:
    return bool(changed(workdir, "HEAD"))


def restore(workdir: str, path: str) -> None:
    """Discard staged and unstaged build outputs in a tracked folder."""
    git(workdir, "restore", "--source=HEAD", "--staged", "--worktree", "--", path)
    git(workdir, "clean", "-fdq", "--", path)


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


def stage(workdir: str) -> None:
    git(workdir, "add", "-A", "--", ".", f":(top,exclude,glob){SCRATCH}*")


def commit(workdir: str, message: str, *, staged: bool = False) -> str:
    if not staged:
        stage(workdir)
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

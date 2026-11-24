"""Shared helpers: config, shell calls, event log."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

FACTORY = Path(__file__).resolve().parent


def load_config() -> dict:
    cfg = json.loads((FACTORY / "config.json").read_text(encoding="utf-8"))
    cfg["home"] = str(Path(os.path.expanduser(os.environ.get("KEYNES_FACTORY_HOME", cfg["home"]))))
    cfg["tools"] = {k: os.path.expanduser(v) for k, v in cfg["tools"].items()}
    return cfg


@contextmanager
def lane_lock(home: Path, lane: str):
    """Hold one lane until exit, including manual invocations and automatic merges."""
    home.mkdir(parents=True, exist_ok=True)
    with (home / f"{lane}.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True


def legacy_lane_gate(home: Path, lane: str) -> bool:
    """Refuse a lane if the old single-lock worker may share its work or PR ownership."""
    try:
        pid = int((home / "lock").read_text().strip())
    except (FileNotFoundError, ValueError):
        return False
    owner = sh(["ps", "-o", "command=", "-p", str(pid)])
    commands = owner.out.split()
    if any(part.endswith("tools/factory/watch_prs.py") for part in commands):
        return True
    return lane == "issue" and any(part.endswith("tools/factory/run.py") for part in commands)


def godot_environment(cfg: dict, workdir: str) -> dict[str, str]:
    wrapper_dir = FACTORY / "bin"
    return {
        "PATH": os.pathsep.join([str(wrapper_dir), os.environ.get("PATH", os.defpath)]),
        "GODOT_BIN": str(wrapper_dir / "godot"),
        "KEYNES_FACTORY_REAL_GODOT": cfg["tools"]["godot"],
        "KEYNES_FACTORY_GODOT_HOME": str(Path(workdir) / "Project/project-keynes/.godot/factory-home"),
    }


@dataclass
class Result:
    code: int
    out: str
    err: str

    @property
    def ok(self) -> bool:
        return self.code == 0


def sh(args: list[str], cwd: str | None = None, timeout: float | None = None,
       stdin: str | None = None, env: dict | None = None, log: str | None = None) -> Result:
    """Run a command without a shell. With `log`, stdout+stderr go to that file instead of memory."""
    full_env = {**os.environ, **(env or {})}
    try:
        if log:
            Path(log).parent.mkdir(parents=True, exist_ok=True)
            with open(log, "w", encoding="utf-8") as fh:
                p = subprocess.run(args, cwd=cwd, timeout=timeout, input=stdin, text=True,
                                   stdout=fh, stderr=subprocess.STDOUT, env=full_env)
            return Result(p.returncode, "", "")
        p = subprocess.run(args, cwd=cwd, timeout=timeout, input=stdin, text=True,
                           capture_output=True, env=full_env)
        return Result(p.returncode, p.stdout, p.stderr)
    except subprocess.TimeoutExpired:
        return Result(124, "", f"timed out after {timeout}s: {' '.join(args[:3])}")
    except FileNotFoundError as e:
        return Result(127, "", str(e))


def must(args: list[str], **kw) -> str:
    r = sh(args, **kw)
    if not r.ok:
        raise RuntimeError(f"{' '.join(args[:4])} failed ({r.code}): {(r.err or r.out).strip()[-800:]}")
    return r.out


def tail(path: str, lines: int = 60) -> str:
    try:
        return "\n".join(Path(path).read_text(encoding="utf-8", errors="replace").splitlines()[-lines:])
    except OSError:
        return ""


class Events:
    """Timestamped events, kept in the run record."""

    def __init__(self) -> None:
        self.items: list[dict] = []

    def add(self, step: str, **data) -> None:
        item = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "step": step, **data}
        self.items.append(item)
        print(json.dumps(item, ensure_ascii=False), flush=True)

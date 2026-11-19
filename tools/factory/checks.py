"""Local checks. The static guard list is read from the PR workflow so it cannot drift from CI."""

from __future__ import annotations

import json
import re
import shlex
import time
from pathlib import Path

from common import sh, tail

GUARD_LIST = re.compile(r"for guard in (.*?); do", re.S)


def static_guards(workdir: str, workflow: str) -> list[str]:
    text = (Path(workdir) / workflow).read_text(encoding="utf-8")
    m = GUARD_LIST.search(text)
    if not m:
        raise RuntimeError(f"no 'for guard in ...; do' list in {workflow}")
    return [w for w in m.group(1).replace("\\", " ").split() if w.endswith(".py")]


def extra_checks(plan_checks: list[str], pattern: str) -> tuple[list[str], list[str]]:
    """Split plan-requested commands into allowed ones and rejected ones."""
    rx = re.compile(pattern)
    ok, bad = [], []
    for c in plan_checks:
        (ok if rx.match(c.strip()) else bad).append(c.strip())
    return ok, bad


class Runner:
    def __init__(self, cfg: dict, workdir: str, logdir: str) -> None:
        self.cfg, self.workdir, self.logdir = cfg, workdir, Path(logdir)
        self.py = cfg["tools"]["python"]
        self.timeout = cfg["limits"]["checkTimeoutMinutes"] * 60

    def _run(self, name: str, args: list[str], cwd: str | None = None) -> dict:
        log = str(self.logdir / f"{re.sub(r'[^A-Za-z0-9_.-]+', '_', name)}.log")
        started = time.time()
        r = sh(args, cwd=cwd or self.workdir, timeout=self.timeout, log=log)
        return {"name": name, "ok": r.ok, "code": r.code, "log": log,
                "seconds": round(time.time() - started)}

    def run(self, native: bool, extra: list[str], cached: list[dict] | None = None) -> list[dict]:
        passed = {r["name"]: r for r in cached or [] if r["ok"]}

        def run_check(name: str, args: list[str], cwd: str | None = None) -> dict:
            return passed.get(name) or self._run(name, args, cwd)

        c = self.cfg["checks"]
        results = []
        ci = str(Path(self.workdir) / "tools" / "ci")
        for g in static_guards(self.workdir, c["staticWorkflow"]):
            results.append(run_check(f"static:{g}", [self.py, g], cwd=ci))
        for args in c["unit"]:
            results.append(run_check("unit:" + " ".join(args[-1:]), [self.py, *args]))
        if native:
            build = run_check("native-build", [self.cfg["tools"]["scons"], *c["nativeBuild"]])
            results.append(build)
            if not build["ok"]:
                return results
        godot = self.cfg["tools"]["godot"]
        reg_logs = str(self.logdir / f"regression-{int(time.time())}")
        reg = [self.py, *c["regression"], "--godot", godot, "--log-dir", reg_logs, "--import"]
        results.append(run_check("regression", reg))
        for cmd in extra:
            parts = shlex.split(cmd)
            args = [self.py, *parts]
            if "--godot" not in parts and any(p.endswith(("replay.py", "matrix.py", "determinism.py")) for p in parts):
                args += ["--godot", godot, "--log-dir", str(self.logdir / f"extra-{int(time.time())}")]
            results.append(run_check(f"extra:{cmd}", args))
        return results


def failed(results: list[dict]) -> list[str]:
    return [r["name"] for r in results if not r["ok"]]


def feedback(results: list[dict], names: list[str]) -> str:
    parts = []
    for r in results:
        if r["name"] in names:
            parts.append(f"### {r['name']} (exit {r['code']})\n```\n{tail(r['log'], 80)}\n```")
    return "\n\n".join(parts)


def base_results(cfg: dict, workdir: str, sha: str, cache_dir: str, logdir: str) -> list[dict]:
    """Reuse passing checks on the same base commit. Retry failed or missing checks."""
    cache = Path(cache_dir) / f"{sha}.json"
    cached = json.loads(cache.read_text(encoding="utf-8")) if cache.exists() else []
    results = Runner(cfg, workdir, logdir).run(native=False, extra=[], cached=cached)
    passed = [r for r in results if r["ok"]]
    if passed != cached:
        cache.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache.with_suffix(".tmp")
        tmp.write_text(json.dumps(passed, indent=2), encoding="utf-8")
        tmp.replace(cache)
    return results

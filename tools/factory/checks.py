"""Local checks. The static guard list is read from the PR workflow so it cannot drift from CI."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import time
from pathlib import Path

import work
from common import godot_environment, sh, tail
from verdict import NativeFacts

GUARD_LIST = re.compile(r"for guard in (.*?); do", re.S)
NATIVE_REBUILD = "native-rebuild"
NATIVE_IMPORT = "native-import"


def runtime_name(library: str) -> str:
    return f"native-runtime:{Path(library).name}"


def file_digest(path: Path) -> str | None:
    if path.is_symlink() or not path.is_file():
        return None
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def static_guards(workdir: str, workflow: str) -> list[str]:
    text = (Path(workdir) / workflow).read_text(encoding="utf-8")
    m = GUARD_LIST.search(text)
    if not m:
        raise RuntimeError(f"no 'for guard in ...; do' list in {workflow}")
    return [w for w in m.group(1).replace("\\", " ").split() if w.endswith(".py")]


def already_run(cfg: dict) -> tuple[set[str], set[str]]:
    """Commands and scripts the factory runs on its own: the default regression, and the native
    runtime check, which runs on both libraries whenever native sources change."""
    c = cfg["checks"]
    return {" ".join(c["regression"])}, {c["nativeRuntimeCheck"]}


def native_line(command: str, script: str) -> bool:
    """The native runtime check alone, with flags, plain values or `<placeholder>` values and no
    shell syntax, so nothing else can ride along on the line."""
    value = r"( [A-Za-z0-9_./-]+| <[A-Za-z0-9 _./-]+>)?"
    return re.fullmatch(re.escape(script) + rf"( --?[a-z0-9-]+{value})*", command) is not None


def requests_native(lines: list[str], cfg: dict) -> bool:
    return any(native_line(re.sub(r"^python3? +", "", c.strip()), cfg["checks"]["nativeRuntimeCheck"]) for c in lines)


def extra_checks(plan_checks: list[str], pattern: str,
                 covered: tuple[set[str], set[str]] = (set(), set())) -> tuple[list[str], list[str], list[str]]:
    """Split plan-requested commands into allowed, rejected and already-run ones."""
    rx = re.compile(pattern)
    commands, scripts = covered
    ok, bad, dup = [], [], []
    for c in plan_checks:
        c = c.strip()
        bare = re.sub(r"^python3? +", "", c)
        if bare in commands or any(native_line(bare, s) for s in scripts):
            dup.append(c)
        elif rx.match(bare):
            ok.append(bare)
        else:
            bad.append(c)
    return ok, bad, dup


class Runner:
    def __init__(self, cfg: dict, workdir: str, logdir: str) -> None:
        self.cfg, self.workdir, self.logdir = cfg, workdir, Path(logdir)
        self.py = cfg["tools"]["python"]
        self.env = godot_environment(cfg, workdir)
        self.godot = self.env["GODOT_BIN"]
        self.timeout = cfg["limits"]["checkTimeoutMinutes"] * 60

    def _require_path(self, name: str, *, cwd: str | None = None, directory: bool = False) -> None:
        path = Path(cwd or self.workdir) / name
        if directory:
            if not path.is_dir():
                raise RuntimeError(f"missing check directory: {path}")
        elif not path.is_file():
            raise RuntimeError(f"missing check script: {path}")

    def _require_unit_target(self, args: list[str]) -> None:
        if args[:3] == ["-m", "unittest", "discover"]:
            options = args[3:]
            directory = options[0] if options and not options[0].startswith("-") else "."
            for i, arg in enumerate(options):
                if arg in ("-s", "--start-directory"):
                    directory = options[i + 1]
                    break
                if arg.startswith("--start-directory="):
                    directory = arg.partition("=")[2]
                    break
            self._require_path(directory, directory=True)
        elif args[:2] == ["-m", "unittest"]:
            for script in args[2:]:
                if script.endswith(".py"):
                    self._require_path(script)
        elif args[0] != "-m":
            self._require_path(args[0])

    def _run(self, name: str, args: list[str], cwd: str | None = None, *, env: dict | None = None) -> dict:
        log = str(self.logdir / f"{re.sub(r'[^A-Za-z0-9_.-]+', '_', name)}.log")
        started = time.time()
        r = sh(args, cwd=cwd or self.workdir, timeout=self.timeout, log=log, env={**self.env, **(env or {})})
        return {"name": name, "ok": r.ok, "code": r.code, "log": log,
                "seconds": round(time.time() - started)}

    def run_native(self, results: list[dict]) -> bool:
        c, tools = self.cfg["checks"], self.cfg["tools"]
        rebuild = Path(c["nativeRebuild"])
        self._require_path(str(rebuild.parent), directory=True)
        self._require_path(c["nativeRebuild"])
        args = c["nativeImport"]
        self._require_path(args[args.index("--path") + 1], directory=True)
        self._require_path(c["nativeRuntimeCheck"])
        libraries = self.cfg["checks"]["nativeBuildOutputs"]
        # Force both targets to be produced here, even if SCons retained its object cache.
        for lib in libraries:
            (Path(self.workdir) / lib).unlink(missing_ok=True)
        scons_dir = str(Path(tools["scons"]).expanduser().parent)
        build = self._run(NATIVE_REBUILD, ["bash", rebuild.name], cwd=str(Path(self.workdir) / rebuild.parent),
                          env={"PATH": os.pathsep.join([scons_dir, self.env["PATH"]])})
        results.append(build)
        if not build["ok"]:
            return False
        build["libraries"] = {lib: file_digest(Path(self.workdir) / lib) for lib in libraries}

        imported = self._run(NATIVE_IMPORT, [self.godot, *args])
        results.append(imported)
        if not imported["ok"]:
            return False
        for lib in libraries:
            name = runtime_name(lib)
            logs = self.logdir / f"probe-{Path(lib).stem}"
            results.append(self._run(name, [self.py, c["nativeRuntimeCheck"], "--godot", self.godot,
                                            "--library", lib, "--log-dir", str(logs)]))
        return True

    def run(self, native: bool, extra: list[str], cached: list[dict] | None = None) -> list[dict]:
        passed = {r["name"]: r for r in cached or [] if r["ok"]}

        def run_check(name: str, args: list[str], cwd: str | None = None) -> dict:
            return passed.get(name) or self._run(name, args, cwd)

        c = self.cfg["checks"]
        results = []
        ci = str(Path(self.workdir) / "tools" / "ci")
        for g in static_guards(self.workdir, c["staticWorkflow"]):
            self._require_path(g, cwd=ci)
            results.append(run_check(f"static:{g}", [self.py, g], cwd=ci))
        for args in c["unit"]:
            self._require_unit_target(args)
            results.append(run_check("unit:" + " ".join(args[-1:]), [self.py, *args]))
        if native and not self.run_native(results):
            return results
        reg_logs = str(self.logdir / f"regression-{int(time.time())}")
        self._require_path(c["regression"][0])
        reg = [self.py, *c["regression"], "--godot", self.godot, "--log-dir", reg_logs, "--import"]
        results.append(run_check("regression", reg))
        results += self.run_extras(extra, run_check)
        return results

    def run_extras(self, extra: list[str], run_check=None) -> list[dict]:
        """The commands the plan asked for on top of the default checks."""
        run_check = run_check or (lambda name, args, cwd=None: self._run(name, args, cwd))
        results = []
        for cmd in extra:
            parts = shlex.split(cmd)
            self._require_path(parts[0])
            args = [self.py, *parts]
            if "--godot" not in parts and any(p.endswith(("replay.py", "matrix.py", "determinism.py", "regression_checks.py")) for p in parts):
                args += ["--godot", self.godot, "--log-dir", str(self.logdir / f"extra-{int(time.time())}")]
            results.append(run_check(f"extra:{cmd}", args))
        return results


def failed(results: list[dict]) -> list[str]:
    return [r["name"] for r in results if not r["ok"]]


def new_failures(results: list[dict], before: list[str]) -> list[str]:
    return [name for name in failed(results) if name.startswith("native-") or name not in before]


class Candidate:
    """Check one pending commit against its parent and retain its build evidence."""

    def __init__(self, cfg: dict, workdir: str, facts: NativeFacts, *,
                 merge_parent: str | None = None) -> None:
        self.cfg, self.workdir, self.facts = cfg, workdir, facts
        self.merge_parent = merge_parent
        self.rebuild_for_merge = False
        self.inputs: dict[str, str | None] = {}
        self.built: dict[str, str | None] = {}

    def changed(self, base: str) -> list[str]:
        if self.merge_parent is None:
            return work.changed(self.workdir, base)
        return work.changed(self.workdir, base, self.merge_parent)

    def scope(self, files: list[str]) -> tuple[list[str], list[str], list[str]]:
        bad, human, native = work.scope(self.cfg, files)
        if self.merge_parent is not None:
            # The merged checkout can differ from either parent's native build inputs.
            from_parents = sorted(set(work.changed(self.workdir, "HEAD")) |
                                  set(work.changed(self.workdir, self.merge_parent)))
            native = work.scope(self.cfg, from_parents)[2]
            if work.GODOT_CPP in from_parents:
                native.append(work.GODOT_CPP)
        if native:
            self.facts.native_changed = True
        return bad, human, native

    def _digests(self, files: list[str]) -> dict[str, str | None]:
        return {path: file_digest(Path(self.workdir) / path) for path in files}

    def run(self, base: str, files: list[str], logdir: str, extra: list[str]) -> tuple[list[dict], list[str]]:
        _, _, native = self.scope(files)
        if self.merge_parent is not None:
            # Merging the removal of tracked outputs can delete the local copies.
            # Keep the requirement through retries and the final commit check.
            self.rebuild_for_merge = self.rebuild_for_merge or any(
                not (Path(self.workdir) / lib).is_file() for lib in self.cfg["checks"]["nativeBuildOutputs"]
            )
        rebuild = bool(native) or self.rebuild_for_merge
        if rebuild or self.inputs:
            self.facts.native_changed = bool(native)
            self.facts.native_rebuilt = self.facts.native_runtime_ok = False
        self.inputs, self.built = self._digests(native), {}
        results = Runner(self.cfg, self.workdir, logdir).run(rebuild, extra)
        if rebuild:
            by_name = {row["name"]: row for row in results}
            build = by_name.get(NATIVE_REBUILD, {})
            self.facts.native_rebuilt = build.get("ok", False)
            self.facts.native_runtime_ok = (
                by_name.get(NATIVE_IMPORT, {}).get("ok", False)
                and all(by_name.get(runtime_name(lib), {}).get("ok", False)
                        for lib in self.cfg["checks"]["nativeBuildOutputs"])
            )
            self.built = build.get("libraries", {})
        return results, self.changed(base)

    def commit_problem(self, native: list[str]) -> str | None:
        if not native and not self.rebuild_for_merge:
            return "C++ files changed after the native checks" if self.inputs else None
        if (self.inputs != self._digests(native) or
                not (self.facts.native_rebuilt and self.facts.native_runtime_ok)):
            return "both macOS libraries must be rebuilt and pass runtime checks for this checkout"
        if any(not digest or self.built.get(lib) != digest
               for lib, digest in self._digests(self.cfg["checks"]["nativeBuildOutputs"]).items()):
            return "the macOS libraries differ from this run's rebuild outputs"
        return None

    def committed(self) -> None:
        self.inputs, self.built = {}, {}


def error_lines(path: str, limit: int = 30) -> str:
    """Compiler and test errors can scroll out of the log tail; quote them first."""
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    hits = [line for line in lines if re.search(r"\berror\b|\bFAIL(ED)?\b|Traceback|AssertionError", line, re.I)]
    if not hits:
        return ""
    return "Error lines:\n```\n" + "\n".join(hits[:limit]) + "\n```\nLog tail:\n"


def feedback(results: list[dict], names: list[str]) -> str:
    parts = []
    for r in results:
        if r["name"] in names:
            parts.append(f"### {r['name']} (exit {r['code']})\n{error_lines(r['log'])}```\n{tail(r['log'], 80)}\n```")
    return "\n\n".join(parts)


def base_results(cfg: dict, workdir: str, sha: str, cache_dir: str, logdir: str) -> list[dict]:
    """Reuse passing checks on the same base commit. Retry failed or missing checks."""
    cache = Path(cache_dir) / f"{sha}.json"
    cached = json.loads(cache.read_text(encoding="utf-8")) if cache.exists() else []
    libraries = cfg["checks"]["nativeBuildOutputs"]
    tracked = work.git(workdir, "ls-files", "-z", "--", *libraries).split("\0")
    # Older parents carry their own libraries. New parents need local builds even
    # when their ordinary check results are cached.
    native = not set(libraries).issubset(tracked)
    results = Runner(cfg, workdir, logdir).run(native=native, extra=[], cached=cached)
    passed = [r for r in results if r["ok"] and not r["name"].startswith("native-")]
    if passed != cached:
        cache.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache.with_suffix(".tmp")
        tmp.write_text(json.dumps(passed, indent=2), encoding="utf-8")
        tmp.replace(cache)
    return results

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
from common import sh, tail
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
        r = sh(args, cwd=cwd or self.workdir, timeout=self.timeout, log=log, env=env)
        return {"name": name, "ok": r.ok, "code": r.code, "log": log,
                "seconds": round(time.time() - started)}

    def _run_native(self, results: list[dict]) -> bool:
        c, tools = self.cfg["checks"], self.cfg["tools"]
        rebuild = Path(c["nativeRebuild"])
        self._require_path(str(rebuild.parent), directory=True)
        self._require_path(c["nativeRebuild"])
        args = c["nativeImport"]
        self._require_path(args[args.index("--path") + 1], directory=True)
        self._require_path(c["nativeRuntimeCheck"])
        libraries = self.cfg["paths"]["nativeLibraries"]
        # Force both targets to be produced here, even if SCons retained its object cache.
        for lib in libraries:
            (Path(self.workdir) / lib).unlink(missing_ok=True)
        scons_dir = str(Path(tools["scons"]).expanduser().parent)
        build = self._run(NATIVE_REBUILD, ["bash", rebuild.name], cwd=str(Path(self.workdir) / rebuild.parent),
                          env={"PATH": os.pathsep.join([scons_dir, os.environ.get("PATH", os.defpath)])})
        results.append(build)
        if not build["ok"]:
            return False
        build["libraries"] = {lib: file_digest(Path(self.workdir) / lib) for lib in libraries}

        imported = self._run(NATIVE_IMPORT, [tools["godot"], *args])
        results.append(imported)
        if not imported["ok"]:
            return False
        for lib in libraries:
            name = runtime_name(lib)
            logs = self.logdir / f"probe-{Path(lib).stem}"
            results.append(self._run(name, [self.py, c["nativeRuntimeCheck"], "--godot", tools["godot"],
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
        if native and not self._run_native(results):
            return results
        godot = self.cfg["tools"]["godot"]
        reg_logs = str(self.logdir / f"regression-{int(time.time())}")
        self._require_path(c["regression"][0])
        reg = [self.py, *c["regression"], "--godot", godot, "--log-dir", reg_logs, "--import"]
        results.append(run_check("regression", reg))
        results += self.run_extras(extra, run_check)
        return results

    def run_extras(self, extra: list[str], run_check=None) -> list[dict]:
        """The commands the plan asked for on top of the default checks."""
        run_check = run_check or (lambda name, args, cwd=None: self._run(name, args, cwd))
        godot = self.cfg["tools"]["godot"]
        results = []
        for cmd in extra:
            parts = shlex.split(cmd)
            self._require_path(parts[0])
            args = [self.py, *parts]
            if "--godot" not in parts and any(p.endswith(("replay.py", "matrix.py", "determinism.py", "regression_checks.py")) for p in parts):
                args += ["--godot", godot, "--log-dir", str(self.logdir / f"extra-{int(time.time())}")]
            results.append(run_check(f"extra:{cmd}", args))
        return results


def failed(results: list[dict]) -> list[str]:
    return [r["name"] for r in results if not r["ok"]]


def new_failures(results: list[dict], before: list[str]) -> list[str]:
    return [name for name in failed(results) if name.startswith("native-") or name not in before]


class Candidate:
    """Check one pending commit against its parent and retain its build evidence."""

    def __init__(self, cfg: dict, workdir: str, facts: NativeFacts, *,
                 merge_parent: str | None = None, force_native: bool = False) -> None:
        self.cfg, self.workdir, self.facts = cfg, workdir, facts
        self.merge_parent, self.force_native = merge_parent, force_native
        self.inputs: dict[str, str | None] = {}
        self.built: dict[str, str | None] = {}

    def changed(self, base: str) -> list[str]:
        if self.merge_parent is None:
            return work.changed(self.workdir, base)
        return work.changed(self.workdir, base, self.merge_parent)

    def scope(self, files: list[str]) -> tuple[list[str], list[str], list[str]]:
        bad, human, native = work.scope(self.cfg, files)
        if self.merge_parent is not None:
            # Master can bring native input changes that are outside the PR's resolution scope.
            from_head = work.changed(self.workdir, "HEAD")
            native = work.scope(self.cfg, from_head)[2]
            if work.GODOT_CPP in from_head:
                native.append(work.GODOT_CPP)
        if native or self.force_native:
            if self.facts.native_libraries_committed:
                self.facts.native_rebuilt = self.facts.native_runtime_ok = self.facts.native_libraries_committed = False
            self.facts.native_changed = True
        if native or self.force_native or self.merge_parent is not None:
            human = sorted(set(human) | (set(work.binary_changes(self.cfg, files)) - set(self.expected_libraries)))
        return bad, human, native

    @property
    def expected_libraries(self) -> list[str]:
        return self.cfg["paths"]["nativeLibraries"]

    def discard_binaries(self, files: list[str]) -> list[str]:
        binaries = set(work.binary_changes(self.cfg, files))
        if binaries:
            work.restore(self.workdir, self.cfg["paths"]["trackedBinaries"])
        return [path for path in files if path not in binaries]

    def _digests(self, files: list[str]) -> dict[str, str | None]:
        return {path: file_digest(Path(self.workdir) / path) for path in files}

    def run(self, base: str, files: list[str], logdir: str, extra: list[str]) -> tuple[list[dict], list[str]]:
        _, _, native = self.scope(files)
        rebuild = bool(native) or self.force_native
        self.inputs, self.built = self._digests(native), {}
        if rebuild or not self.facts.native_libraries_committed:
            self.facts.native_changed = rebuild
            self.facts.native_rebuilt = self.facts.native_runtime_ok = False
        if not rebuild and self.merge_parent is None:
            self.discard_binaries(files)
        results = Runner(self.cfg, self.workdir, logdir).run(rebuild, extra)
        if rebuild:
            by_name = {row["name"]: row for row in results}
            build = by_name.get(NATIVE_REBUILD, {})
            self.facts.native_rebuilt = build.get("ok", False)
            self.facts.native_runtime_ok = all(by_name.get(runtime_name(lib), {}).get("ok", False)
                                               for lib in self.expected_libraries)
            self.built = build.get("libraries", {})
        after = self.changed(base)
        if self.merge_parent is not None:
            return results, after
        if not rebuild and not work.scope(self.cfg, after)[2]:
            after = self.discard_binaries(after)
        elif rebuild and not self.facts.native_runtime_ok:
            # A failed rebuild can leave one or both targets missing. Restore the parents'
            # libraries for the next repair attempt, while preserving any out-of-scope changes.
            if set(work.binary_changes(self.cfg, after)).issubset(self.expected_libraries):
                after = self.discard_binaries(after)
        return results, after

    def commit_problem(self, files: list[str], native: list[str]) -> str | None:
        changed = set(work.binary_changes(self.cfg, files))
        if not (native or self.force_native):
            if self.inputs:
                return "C++ files changed after the native checks"
            if self.merge_parent is not None and changed:
                return "native libraries changed without a rebuild"
            return None
        if (self.inputs != self._digests(native) or
                not (self.facts.native_rebuilt and self.facts.native_runtime_ok)):
            return "both macOS libraries must be rebuilt and pass runtime checks for the current C++ changes"
        expected = set(self.expected_libraries)
        # A verified rebuild in a merge can reproduce either parent's library byte for byte.
        if self.merge_parent is None and changed != expected:
            missing = ", ".join(sorted(expected - changed))
            unexpected = ", ".join(sorted(changed - expected))
            return f"expected exactly the two rebuilt macOS libraries to change (missing: {missing or 'none'}; unexpected: {unexpected or 'none'})"
        if any(not digest or self.built.get(lib) != digest
               for lib, digest in self._digests(self.expected_libraries).items()):
            return "the macOS libraries differ from this run's rebuild outputs"
        if self.merge_parent is not None:
            tracked = work.git(self.workdir, "ls-files", "-z", "--", *self.expected_libraries)
            if not expected.issubset(tracked.split("\0")):
                return "the merge must include both rebuilt macOS libraries"
        return None

    def committed(self) -> None:
        if self.inputs or self.force_native:
            self.facts.native_libraries_committed = True
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
    results = Runner(cfg, workdir, logdir).run(native=False, extra=[], cached=cached)
    passed = [r for r in results if r["ok"]]
    if passed != cached:
        cache.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache.with_suffix(".tmp")
        tmp.write_text(json.dumps(passed, indent=2), encoding="utf-8")
        tmp.replace(cache)
    return results

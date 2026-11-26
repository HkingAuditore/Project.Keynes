"""Build and run isolated Keynes performance measurements."""


from __future__ import annotations

import contextlib
import csv
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

from perf_change_metrics import (
    AUTH_PREFIX, HARNESS_PREFIX, HEADLINE, RESULT_PREFIX, csv_metrics, numeric_items,
    parse_kv_line, record_reusable, to_number, validate_perf_run, waterfall_metrics,
)


COMPETING = {"godot", "Godot", "scons", "clang++", "clang", "cc1plus", "ld", "ld64"}
COMPETING_CPU = 20.0


PERF_SCRIPT = "res://tests/game/headless_perf_record.gd"


PROJECT = "Project/project-keynes"
GODOT_CPP = "gdext/godot-cpp"
LIBRARY_DIR = "addons/dots_ext/bin"
MAX_WORKTREES = 3


class Deferred(Exception):
    """The machine stayed busy or the run budget expired."""


class StepFailed(Exception):
    """A build, import or check could not produce valid evidence."""


def load_gate(idle: float | None, competing: list[str], min_idle: float,
              busiest: list[str] = ()) -> list[str]:
    """Reasons the machine is too busy to measure (empty list = go). idle is the CPU idle fraction
    over the last second: unlike the 1-minute load average it does not lag after a job ends.

    `busiest` only explains a low idle figure that no known competitor accounts for; it never
    decides on its own whether the machine is busy."""
    reasons = []
    if idle is None or not 0.0 <= idle <= 1.0:
        reasons.append("cpu idle unknown")
    elif idle < min_idle:
        reasons.append(f"cpu {idle:.0%} idle, below {min_idle:.0%}")
        if not competing and busiest:
            reasons.append("busiest processes: " + ", ".join(busiest))
    reasons += [f"competing process: {name}" for name in competing]
    return reasons


TOP_IDLE = re.compile(r"CPU usage:.*?([0-9.]+)% idle")


def parse_top_idle(text: str) -> float | None:
    """Idle fraction from `top -l 2`: the first sample counts since boot, so only the last counts."""
    found = TOP_IDLE.findall(text)
    if len(found) < 2:
        return None
    return to_number(found[-1]) / 100 if to_number(found[-1]) is not None else None


def parse_proc_stat_idle(before: str, after: str) -> float | None:
    """Idle fraction between two /proc/stat readings (idle + iowait over all jiffies)."""
    def totals(text):
        for line in text.splitlines():
            parts = line.split()
            if parts and parts[0] == "cpu" and len(parts) >= 6 and all(x.isdigit() for x in parts[1:]):
                values = [int(x) for x in parts[1:]]
                return sum(values), values[3] + values[4]
        return None
    a, b = totals(before), totals(after)
    if a is None or b is None or b[0] <= a[0]:
        return None
    return (b[1] - a[1]) / (b[0] - a[0])


def cpu_idle() -> float | None:
    if platform.system() == "Darwin":
        done = subprocess.run(["top", "-l", "2", "-n", "0", "-s", "1"], text=True, capture_output=True)
        return parse_top_idle(done.stdout)
    try:
        before = Path("/proc/stat").read_text()
        time.sleep(1)
        return parse_proc_stat_idle(before, Path("/proc/stat").read_text())
    except OSError:
        return None


def run(args: list[str], cwd: Path | None = None, env: dict | None = None,
        log: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
    full_env = {**os.environ, **(env or {})}
    if log is None:
        done = subprocess.run(args, cwd=cwd, env=full_env, text=True, capture_output=True, check=False)
    else:
        with log.open("w") as handle:
            done = subprocess.run(args, cwd=cwd, env=full_env, text=True, stdout=handle,
                                  stderr=subprocess.STDOUT, check=False)
    if check and done.returncode != 0:
        detail = log.read_text(errors="replace")[-2000:] if log else (done.stderr or done.stdout)[-2000:]
        raise StepFailed(f"{' '.join(map(str, args))} exited {done.returncode}\n{detail}")
    return done


def first_line(args: list[str]) -> str:
    try:
        done = subprocess.run(args, text=True, capture_output=True, check=False)
    except OSError:
        return "unavailable"
    return ((done.stdout or done.stderr).strip().splitlines() or ["unavailable"])[0]


def machine_identity() -> dict:
    if platform.system() == "Darwin":
        values = [first_line(["sysctl", "-n", key]) for key in
                  ("hw.model", "machdep.cpu.brand_string", "hw.ncpu", "hw.memsize")]
        label = f"{values[0]} {values[1]} {values[2]} cpus {int(values[3]) // 2**30} GiB"
    else:
        cpu = next((line.split(":", 1)[1].strip() for line in
                    Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")),
                   platform.processor()) if Path("/proc/cpuinfo").exists() else platform.processor()
        label = f"{platform.system()} {cpu} {os.cpu_count()} cpus"
    return {"machine": hashlib.sha256(label.encode()).hexdigest()[:16], "machine_label": label}


def toolchain_identity(godot: str) -> dict:
    compiler = first_line(["c++", "--version"])
    godot_version = first_line([godot, "--version"])
    label = f"godot {godot_version}; {compiler}; {platform.system()} {platform.release()}"
    return {"toolchain": hashlib.sha256(label.encode()).hexdigest()[:16], "toolchain_label": label}


def competing_processes(ps_output: str, mine: int, min_cpu: float = COMPETING_CPU) -> list[str]:
    """Busy Godot, build or link processes that are not ours (an idle editor does not count)."""
    found = []
    for pid, cpu, executable in busy_processes(ps_output, mine, min_cpu):
        name = executable.rsplit("/", 1)[-1]
        if name in COMPETING:
            found.append(f"{pid} {name} {cpu:.0f}% cpu")
    return found


# Lower than COMPETING_CPU on purpose: a low idle figure can come from several processes that
# each use only a little CPU, and they are what the hint has to name.
BUSIEST_MIN_CPU = 1.0
APP_BUNDLE = re.compile(r"/([^/]+)\.app/Contents/MacOS/[^/]+$")


def process_name(executable: str) -> str:
    """A readable name for an executable path, as `ps -o comm=` prints it (no arguments, spaces
    kept). A macOS app's own executable is named by its bundle; anything else by its basename."""
    bundle = APP_BUNDLE.search(executable)
    return bundle.group(1) if bundle else executable.rsplit("/", 1)[-1]


def busiest_processes(ps_output: str, mine: int, limit: int = 3,
                      min_cpu: float = BUSIEST_MIN_CPU) -> list[str]:
    """The busiest processes that are not ours, of any kind, busiest first. They name what is
    using the CPU when the idle figure is low but no known competitor is running."""
    found = sorted(busy_processes(ps_output, mine, min_cpu), key=lambda p: (-p[1], p[0]))
    return [f"{pid} {process_name(executable)} {cpu:.0f}% cpu"
            for pid, cpu, executable in found[:limit]]


def busy_processes(ps_output: str, mine: int, min_cpu: float) -> list[tuple[int, float, str]]:
    """(pid, %cpu, executable) for process_table rows at or above min_cpu, leaving out this
    process and its children. The final `comm` field can contain spaces."""
    rows = []
    for line in ps_output.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        pid, ppid, cpu, executable = int(parts[0]), int(parts[1]), to_number(parts[2]), parts[3]
        if pid == mine or ppid == mine or cpu is None or cpu < min_cpu:
            continue
        rows.append((pid, cpu, executable))
    return rows


def process_table() -> str:
    """Read CPU usage and untruncated executable names from the same process listing."""
    return run(["ps", "-Aww", "-o", "pid=", "-o", "ppid=", "-o", "%cpu=", "-o", "comm="]).stdout


# Rough cost of each step on a quiet machine, used only to decide how long waiting may last.
ESTIMATE_S = {"build": 240, "golden": 60, "load_consistency": 120, "round": 15}


def work_estimate(missing_ready: list[bool], tier: str, rounds: int) -> float:
    """Seconds of work for the commits still to measure; True means its worktree is already built."""
    per_commit = ESTIMATE_S["golden"] + rounds * ESTIMATE_S["round"]
    if tier == "full":
        per_commit += ESTIMATE_S["load_consistency"]
    return sum(per_commit + (0 if ready else ESTIMATE_S["build"]) for ready in missing_ready)


def wait_allowance(budget_s: float, elapsed_s: float, estimate_s: float) -> float:
    """Seconds the whole run may still spend waiting for a quiet machine: never negative."""
    return max(0.0, budget_s - elapsed_s - estimate_s)


def check_budget(args) -> None:
    if args.budget > 0 and time.monotonic() - args.started >= args.budget * 60:
        raise Deferred(f"the {args.budget:g}-minute run budget expired")


def wait_for_quiet_machine(args, log: list) -> dict:
    """Block until the machine is quiet. Waiting shares one allowance for the whole run
    (the time budget minus the estimated work); when it runs out the run is deferred."""
    deadline = time.monotonic() + args.wait_left
    if args.budget > 0:
        deadline = min(deadline, args.started + args.budget * 60)
    while True:
        check_budget(args)
        load1 = os.getloadavg()[0]
        idle = cpu_idle()
        cpus = os.cpu_count() or 0
        table, mine = process_table(), os.getpid()
        competing = competing_processes(table, mine)
        busiest = [] if competing else busiest_processes(table, mine)
        reasons = load_gate(idle, competing, args.min_idle, busiest)
        sample = {"at": now(), "cpu_idle": None if idle is None else round(idle, 3),
                  "load1": round(load1, 2), "cpus": cpus, "busy": reasons}
        check_budget(args)
        if not reasons:
            args.wait_left = max(0.0, deadline - time.monotonic())
            return sample
        log.append(sample)
        if time.monotonic() + args.poll_seconds > deadline:
            raise Deferred(f"machine still busy and the {args.budget:g}-minute budget leaves no time "
                           f"to wait: " + "; ".join(reasons))
        print(f"machine busy, waiting: {'; '.join(reasons)}", flush=True)
        time.sleep(args.poll_seconds)


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- archive

class Archive:
    def __init__(self, home: Path):
        self.home = home
        self.records = home / "records"
        self.worktrees = home / "worktrees"
        self.comparisons = home / "comparisons"
        self.build = home / "build"
        for path in (self.records, self.worktrees, self.comparisons):
            path.mkdir(parents=True, exist_ok=True)

    @contextlib.contextmanager
    def measurement_lock(self):
        """Keep builds, cached worktrees and active measurements exclusive to this invocation."""
        import fcntl

        with (self.home / "build.lock").open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def scenario_id(self, scenario: dict) -> str:
        return "_".join(f"{key}{scenario[key]}" for key in sorted(scenario))

    def find(self, identity: dict, tier: str, rounds: int) -> tuple[dict | None, str]:
        folder = self.records / identity["commit"][:12] / self.scenario_id(identity["scenario"])
        why = "no record"
        if not folder.exists():
            return None, why
        for path in sorted(folder.glob("*/record.json"), reverse=True):
            record = json.loads(path.read_text())
            ok, why = record_reusable(record, identity, tier, rounds)
            if ok:
                record["path"] = str(path.parent)
                return record, why
        return None, why

    def new_record_dir(self, identity: dict) -> Path:
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        path = (self.records / identity["commit"][:12] / self.scenario_id(identity["scenario"])
                / f"{stamp}-{identity['machine']}")
        path.mkdir(parents=True)
        return path

    def index(self, record: dict) -> None:
        line = {key: record.get(key) for key in ("created", "tier", "status", "path")}
        line.update(commit=record["identity"]["commit"], subject=record.get("subject"),
                    scenario=record["identity"]["scenario"],
                    machine=record["identity"]["machine_label"],
                    headline=record.get("headline", {}))
        with (self.home / "index.jsonl").open("a") as handle:
            handle.write(json.dumps(line, ensure_ascii=False) + "\n")


def save(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


# ---------------------------------------------------------------- worktrees and builds

def git(repo: Path, *args: str) -> str:
    return run(["git", "-C", str(repo), *args]).stdout.strip()


def require_managed_worktree(repo: Path, path: Path) -> None:
    if path.is_symlink() or not (path / ".perf-worktree").is_file():
        raise StepFailed(f"archive path is not a managed worktree: {path}")
    if (Path(git(path, "rev-parse", "--show-toplevel")).resolve() != path.resolve()
            or git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
            != git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
            or git(path, "branch", "--show-current")):
        raise StepFailed(f"archive path is not a detached worktree of this repository: {path}")


def add_worktree(repo: Path, path: Path, commit: str) -> None:
    git(repo, "worktree", "add", "--detach", str(path), commit)
    (path / ".perf-worktree").touch()


PLATFORMS = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}
ARCHES = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x86_64", "AMD64": "x86_64"}


def host_target(system: str, machine: str) -> tuple[str, str]:
    if system not in PLATFORMS or machine not in ARCHES:
        raise StepFailed(f"no build recipe for {system}/{machine}")
    return PLATFORMS[system], ARCHES[machine]


def scons_command(system: str, machine: str, jobs: int) -> list[str]:
    """The headless editor loads the debug mapping of dots_ext.gdextension, so only that target is built."""
    target_platform, arch = host_target(system, machine)
    return ["scons", f"platform={target_platform}", "target=template_debug",
            f"arch={arch}", "dev_build=no", f"-j{max(1, jobs)}"]


def debug_libraries(tree: Path, system: str, machine: str) -> list[Path]:
    """This host's debug libraries only: other platforms' libraries are checked in and prove nothing."""
    target_platform, arch = host_target(system, machine)
    folder = tree / PROJECT / LIBRARY_DIR / target_platform
    return sorted(folder.glob(f"*.{target_platform}.template_debug.{arch}*"))


def compile_commit(repo: Path, archive: Archive, commit: str, args, record_dir: Path) -> list[Path]:
    """Build one commit in the archive's long-lived build tree and return its debug libraries.

    The build tree is reused across commits, so SCons only recompiles what differs from the last
    build; only the first build on a machine compiles godot-cpp and every source from scratch.
    """
    tree = archive.build
    if tree.exists() or tree.is_symlink():
        require_managed_worktree(repo, tree)
    else:
        add_worktree(repo, tree, commit)
    run(["git", "-C", str(tree), "checkout", "--detach", "--force", commit],
        log=record_dir / f"checkout-{commit[:12]}.log")
    submodule = ["git", "-C", str(tree), "submodule", "update", "--init", "--force", GODOT_CPP]
    reference = repo / GODOT_CPP
    if (reference / ".git").exists():
        submodule[5:5] = ["--reference", str(reference)]
    run(submodule, log=record_dir / f"submodule-{commit[:12]}.log")
    host = (platform.system(), platform.machine())
    for stale in debug_libraries(tree, *host):
        shutil.rmtree(stale) if stale.is_dir() else stale.unlink()
    command = scons_command(*host, os.cpu_count() or 8)
    if args.scons:
        command[0] = args.scons
    check_budget(args)
    run(command, cwd=tree / "gdext", log=record_dir / f"build-{commit[:12]}.log")
    built = debug_libraries(tree, *host)
    if not built:
        raise StepFailed(f"build of {commit[:12]} produced no template_debug library")
    return built


def prepare_worktree(repo: Path, archive: Archive, commit: str, args, record_dir: Path,
                     busy_log: list) -> Path:
    path = archive.worktrees / commit[:12]
    ready = path / ".perf-built"
    if path.exists() or path.is_symlink():
        require_managed_worktree(repo, path)
        if ready.is_file() and ready.read_text().strip() == commit and git(path, "rev-parse", "HEAD") == commit:
            path.touch()
            return path
        git(repo, "worktree", "remove", "--force", str(path))
    prune_worktrees(repo, archive)
    started = time.monotonic()
    wait_for_quiet_machine(args, busy_log)
    built = compile_commit(repo, archive, commit, args, record_dir)
    check_budget(args)
    compiled = time.monotonic() - started
    add_worktree(repo, path, commit)
    for library in built:
        target = path / library.relative_to(archive.build)
        target.parent.mkdir(parents=True, exist_ok=True)
        if library.is_dir():
            shutil.copytree(library, target, dirs_exist_ok=True)
        else:
            shutil.copy2(library, target)
    seeded = seed_import_cache(archive, path)
    wait_for_quiet_machine(args, busy_log)
    import_started = time.monotonic()
    run([args.godot, "--headless", "--path", str(path / PROJECT), "--import"],
        log=record_dir / f"import-{commit[:12]}.log")
    print(f"imported {commit[:12]} in {time.monotonic() - import_started:.0f}s"
          + (f" (cache from {seeded.name})" if seeded else " (no cache)"), flush=True)
    ready.write_text(commit + "\n")
    print(f"built {commit[:12]}: compile {compiled:.0f}s, total {time.monotonic() - started:.0f}s",
          flush=True)
    return path


def seed_import_cache(archive: Archive, target: Path) -> Path | None:
    """Clone the newest imported asset cache into a fresh worktree so --import only redoes changed
    assets. Godot checks each source against its recorded hash, so a stale cache costs time, not
    correctness. Only .godot/imported is copied; the script class and uid caches are rebuilt."""
    sources = sorted((p for p in archive.worktrees.iterdir()
                      if p != target and (p / ".perf-built").exists()
                      and (p / PROJECT / ".godot/imported").is_dir()),
                     key=lambda p: p.stat().st_mtime, reverse=True)
    if (archive.build / PROJECT / ".godot/imported").is_dir():
        sources.append(archive.build)
    if not sources:
        return None
    source, destination = sources[0] / PROJECT / ".godot/imported", target / PROJECT / ".godot/imported"
    destination.parent.mkdir(parents=True, exist_ok=True)
    clone = ["cp", "-cR", str(source), str(destination)] if platform.system() == "Darwin" else None
    if clone is None or subprocess.run(clone, capture_output=True).returncode != 0:
        shutil.rmtree(destination, ignore_errors=True)
        shutil.copytree(source, destination)
    return sources[0]


def prune_worktrees(repo: Path, archive: Archive) -> None:
    existing = sorted((p for p in archive.worktrees.iterdir() if (p / ".perf-worktree").is_file()),
                      key=lambda p: p.stat().st_mtime)
    for path in existing[:max(0, len(existing) - (MAX_WORKTREES - 1))]:
        require_managed_worktree(repo, path)
        git(repo, "worktree", "remove", "--force", str(path))


def build_hash(worktree: Path) -> str:
    binaries = sorted(path for library in debug_libraries(worktree, platform.system(), platform.machine())
                      for path in ([library] if library.is_file() else library.rglob("*")))
    digest = hashlib.sha256()
    for path in binaries:
        if path.is_file():
            digest.update(path.read_bytes())
    return digest.hexdigest()[:16]


# ---------------------------------------------------------------- measurements

def perf_round(worktree: Path, out: Path, scenario: dict, tier: str, godot: str, label: str) -> dict:
    out.mkdir(parents=True)
    command = [godot, "--headless", "--path", str(worktree / PROJECT), "--script", PERF_SCRIPT, "--",
               *(f"{key}={value}" for key, value in scenario.items()),
               f"label={label}", f"output_dir={out}"]
    env = dict(os.environ)
    if tier == "full":
        env["PK_RUNTIME_WATERFALL_CSV"] = str(out / "waterfall.csv")
    log = out / "godot.log"
    started = time.monotonic()
    with log.open("w") as handle:
        process = subprocess.Popen(command, cwd=worktree, env=env, stdout=handle,
                                   stderr=subprocess.STDOUT)
        _, status, usage = os.wait4(process.pid, 0)
    wall = time.monotonic() - started
    exit_code = os.waitstatus_to_exitcode(status)
    process.returncode = exit_code
    lines = log.read_text(errors="replace").splitlines()
    metrics, result = {}, None
    errors = []
    try:
        result = parse_kv_line(lines, RESULT_PREFIX)
        metrics.update(numeric_items("result", result))
    except ValueError as error:
        errors.append(str(error))
    for prefix, name in ((AUTH_PREFIX, "auth"), (HARNESS_PREFIX, "harness")):
        try:
            metrics.update(numeric_items(name, parse_kv_line(lines, prefix)))
        except ValueError as error:
            errors.append(str(error))
    csv_path = Path(result.get("path", "")) if result else None
    rows = None
    if csv_path and csv_path.is_file():
        try:
            with csv_path.open(newline="", encoding="utf-8-sig") as handle:
                reader = csv.DictReader(handle, strict=True)
                columns = reader.fieldnames
                if not columns or "" in columns or len(set(columns)) != len(columns):
                    raise ValueError("missing or duplicate column names")
                rows = list(reader)
            if any(None in row or None in row.values() for row in rows):
                raise ValueError("row does not match header width")
            metrics.update(csv_metrics(rows))
        except (csv.Error, OSError, ValueError) as error:
            errors.append(f"perf csv: {error}")
    waterfall = out / "waterfall.csv"
    if waterfall.is_file():
        with waterfall.open(newline="", encoding="utf-8", errors="replace") as handle:
            metrics.update(waterfall_metrics(list(csv.DictReader(handle))))
    scale = 1 if platform.system() == "Darwin" else 1024
    metrics.update({"rusage.wall_s": wall, "rusage.cpu_s": usage.ru_utime + usage.ru_stime,
                    "rusage.user_s": usage.ru_utime, "rusage.sys_s": usage.ru_stime,
                    "rusage.maxrss_mb": usage.ru_maxrss * scale / 2**20})
    errors += validate_perf_run(exit_code, result, rows, scenario)
    method = (result or {}).get("recorder_method")
    if result is not None and method is None:
        # Old scripts had no version marker. Only identical unversioned
        # scripts can be assumed to give the old metric names the same meaning.
        script = worktree / PROJECT / PERF_SCRIPT.removeprefix("res://")
        try:
            method = "unversioned:" + hashlib.sha256(script.read_bytes()).hexdigest()[:12]
        except OSError as error:
            errors.append(f"could not identify unversioned recorder: {error}")
    return {"label": label, "command": command, "exit": exit_code, "errors": errors,
            "recorder_method": method, "metrics": metrics, "dir": str(out)}


def golden_check(worktree: Path, out: Path, godot: str, runs: int) -> dict:
    candidate = out / "golden-candidate.json"
    logs = out / "golden-logs"
    done = run([sys.executable, "tools/ci/check_golden_determinism.py", "--godot", godot,
                "--runs", str(runs), "--log-dir", str(logs), "--write-candidate", str(candidate)],
               cwd=worktree, log=out / "golden.log", check=False)
    summary = logs / "summary.json"
    passed = done.returncode == 0 and summary.is_file() and json.loads(summary.read_text()).get("passed") is True
    return {"passed": passed and candidate.is_file(), "exit": done.returncode, "runs": runs,
            "candidate": str(candidate) if candidate.is_file() else None, "log": str(out / "golden.log")}


def load_consistency_check(worktree: Path, out: Path, godot: str) -> dict:
    logs = out / "load-logs"
    done = run([sys.executable, "tools/ci/check_runtime_load_consistency.py", "--godot", godot,
                "--workers", "7", "--log-dir", str(logs)], cwd=worktree, log=out / "load.log", check=False)
    return {"passed": done.returncode == 0, "exit": done.returncode, "log": str(out / "load.log")}


def headline(rounds: list[dict]) -> dict:
    out = {}
    for name in HEADLINE:
        values = [r["metrics"][name] for r in rounds if name in r["metrics"]]
        if values:
            out[name] = statistics.median(values)
    return out

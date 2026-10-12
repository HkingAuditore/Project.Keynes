#!/usr/bin/env python3
"""Offline Country AI catalog tuning with separable CMA-ES.

Each candidate is a point in the normalized box of ``param_space.json``. It is
written to a ``.tres`` through ``apply_params.gd`` and scored by batches of
formal headless games (``tests/headless_perf_record.gd``) with the AI ACTIVE.
The candidate catalog is injected through ``PK_COUNTRY_AI_CATALOG`` so the
default ``data/country/default_country_ai.tres`` is only touched by
``--write-back``.

The objective reads the ``country_ai_record`` CSV of every run and is a weighted
sum of survival, development, development balance across countries and
behavioral diversity across personalities, minus the command rejection rate.
The runtime never consumes this script's output except through the catalog, so
tuned values stay deterministic and hash-checked.

Example (small, fast budget)::

    python tools/country_ai_tune/cmaes_tune.py --generations 6 --days 1825 \
        --seeds 20260718 20260719 --jobs 2

Resume a run and write the best catalog back::

    python tools/country_ai_tune/cmaes_tune.py --resume --generations 12 --write-back

Only the standard library is used (sep-CMA-ES keeps a diagonal covariance, so
no eigendecomposition is needed).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import glob
import json
import math
import os
import random
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROJECT_DIR = REPO_ROOT / "Project" / "project-keynes"
DEFAULT_CATALOG = "res://data/country/default_country_ai.tres"
APPLY_SCRIPT = "res://tools/country_ai_tune/apply_params.gd"
PERF_SCRIPT = "res://tests/headless_perf_record.gd"
DEFAULT_GODOT = os.environ.get(
    "GODOT_BIN",
    r"D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe",
)


# ---------------------------------------------------------------------------
# Parameter space


@dataclass
class Param:
    path: str
    lo: float
    hi: float

    def decode(self, u: float) -> float:
        return self.lo + min(1.0, max(0.0, u)) * (self.hi - self.lo)

    def encode(self, value: float) -> float:
        span = self.hi - self.lo
        return 0.5 if span == 0 else min(1.0, max(0.0, (float(value) - self.lo) / span))


def load_space(path: Path) -> tuple[list[Param], dict]:
    spec = json.loads(path.read_text(encoding="utf-8"))
    params = [Param(p["path"], float(p["min"]), float(p["max"])) for p in spec["params"]]
    if not params:
        raise SystemExit("param_space.json has no params")
    return params, spec.get("objective", {})


# ---------------------------------------------------------------------------
# Godot helpers


def run_godot(godot: str, args: list[str], env: dict | None = None,
              timeout: float | None = None, log_path: Path | None = None) -> tuple[int, str]:
    cmd = [godot, "--headless", "--path", str(PROJECT_DIR)] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", env=env, timeout=timeout)
    output = (proc.stdout or "") + (proc.stderr or "")
    if log_path is not None:
        log_path.write_text(output, encoding="utf-8")
    return proc.returncode, output


def read_current_values(godot: str, space_path: Path, work: Path) -> dict:
    out = work / "baseline_values.json"
    code, output = run_godot(godot, ["--script", APPLY_SCRIPT, "--",
                                     f"base={DEFAULT_CATALOG}", f"read={space_path}",
                                     f"out={out}"])
    if code != 0 or not out.exists():
        raise SystemExit(f"reading baseline values failed ({code}):\n{output[-2000:]}")
    return json.loads(out.read_text(encoding="utf-8"))


def write_catalog(godot: str, values: dict, params_json: Path, out_tres: Path) -> None:
    params_json.write_text(json.dumps(values, indent=2), encoding="utf-8")
    code, output = run_godot(godot, ["--script", APPLY_SCRIPT, "--",
                                     f"base={DEFAULT_CATALOG}", f"params={params_json}",
                                     f"out={out_tres}"])
    if code != 0 or not out_tres.exists():
        raise RuntimeError(f"apply_params failed ({code}): {output[-2000:]}")


# ---------------------------------------------------------------------------
# Objective


@dataclass
class RunResult:
    ok: bool
    reason: str = ""
    metrics: dict = field(default_factory=dict)


def score_csv(csv_path: Path, objective: dict) -> dict:
    by_handle: dict[str, list[dict]] = {}
    with csv_path.open(newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            if None in row.values() or "" in (row.get("population"), row.get("cash")):
                continue  # truncated trailing line
            by_handle.setdefault(row["handle"], []).append(row)
    if not by_handle:
        return {"countries": 0}
    target_m = float(objective.get("target_milestones", 2))
    target_t = float(objective.get("target_territory_growth", 4))
    survival, dev, emitted, rejected = [], [], 0, 0
    agenda_hist: dict[str, dict[str, int]] = {}
    for rows in by_handle.values():
        first, last = rows[0], rows[-1]
        alive = 1.0 if int(last["population"]) > 0 else 0.0
        negative = sum(1 for r in rows if int(r["cash"]) < 0) / len(rows)
        survival.append(alive * (1.0 - negative))
        milestones = int(last["completed_milestones"])
        growth = int(last["territory"]) - int(first["territory"])
        dev.append(0.6 * min(1.0, milestones / max(1e-9, target_m))
                   + 0.4 * min(1.0, max(0, growth) / max(1e-9, target_t)))
        emitted += int(last["commands_emitted"])
        rejected += int(last["commands_rejected"])
        hist = agenda_hist.setdefault(last["personality"], {})
        for r in rows:
            hist[r["agenda"]] = hist.get(r["agenda"], 0) + 1
    mean_dev = statistics.fmean(dev)
    balance = 1.0
    if len(dev) > 1 and mean_dev > 0:
        balance = max(0.0, 1.0 - statistics.pstdev(dev) / mean_dev)
    elif mean_dev == 0:
        balance = 0.0
    # Mean pairwise total-variation distance between personality agenda mixes.
    mixes = []
    for hist in agenda_hist.values():
        total = sum(hist.values())
        mixes.append({k: v / total for k, v in hist.items()})
    pairs, distance = 0, 0.0
    for i in range(len(mixes)):
        for j in range(i + 1, len(mixes)):
            keys = set(mixes[i]) | set(mixes[j])
            distance += 0.5 * sum(abs(mixes[i].get(k, 0.0) - mixes[j].get(k, 0.0)) for k in keys)
            pairs += 1
    diversity = distance / pairs if pairs else 0.0
    return {
        "countries": len(by_handle),
        "survival": statistics.fmean(survival),
        "development": mean_dev,
        "balance": balance,
        "diversity": diversity,
        "rejection": rejected / max(1, emitted + rejected),
        "commands_emitted": emitted,
        "commands_rejected": rejected,
    }


def combine(metrics: list[dict], objective: dict) -> float:
    weights = objective.get("weights", {})
    failed = float(objective.get("failed_run_score", -1.0))
    scores = []
    for m in metrics:
        if not m or m.get("countries", 0) == 0:
            scores.append(failed)
            continue
        scores.append(
            weights.get("survival", 0.35) * m["survival"]
            + weights.get("development", 0.30) * m["development"]
            + weights.get("balance", 0.15) * m["balance"]
            + weights.get("diversity", 0.15) * m["diversity"]
            - weights.get("rejection", 0.05) * m["rejection"])
    return statistics.fmean(scores) if scores else failed


def run_game(godot: str, catalog: Path, run_dir: Path, seed: int, args: argparse.Namespace) -> RunResult:
    run_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["PK_COUNTRY_AI_CATALOG"] = str(catalog)
    env["PK_COUNTRY_AI_MODE"] = "ACTIVE"
    game_args = ["--script", PERF_SCRIPT, "--",
                 f"days={args.days}", f"speed={args.speed}", f"seed={seed}",
                 f"width={args.width}", f"height={args.height}",
                 f"foreign_count={args.foreign_count}", "population_scale=0",
                 "label=cmaes", f"output_dir={run_dir}", "country_ai=ACTIVE"]
    try:
        code, output = run_godot(godot, game_args, env=env, timeout=args.run_timeout,
                                 log_path=run_dir / "godot.log")
    except subprocess.TimeoutExpired:
        return RunResult(False, "timeout")
    result_lines = [line for line in output.splitlines() if line.startswith("[headless-perf/result]")]
    if not result_lines:
        return RunResult(False, f"no_result_line(exit={code})")
    result = result_lines[-1]
    if "fatal=false" not in result or "ledger_failures=0" not in result:
        return RunResult(False, f"economy_failure(exit={code})")
    csvs = sorted(glob.glob(str(run_dir / "country_ai_record_*.csv")))
    if not csvs:
        return RunResult(False, "no_country_ai_csv")
    return RunResult(True, metrics=score_csv(Path(csvs[-1]), args.objective))


def evaluate(godot: str, values: dict, cand_dir: Path, args: argparse.Namespace) -> tuple[float, list[dict]]:
    cand_dir.mkdir(parents=True, exist_ok=True)
    catalog = cand_dir / "candidate.tres"
    write_catalog(godot, values, cand_dir / "params.json", catalog)
    metrics = []
    for seed in args.seeds:
        result = run_game(godot, catalog, cand_dir / f"seed_{seed}", seed, args)
        metrics.append(result.metrics if result.ok else {"countries": 0, "reason": result.reason})
        if not args.keep_runs:
            for perf_csv in (cand_dir / f"seed_{seed}").glob("*.csv"):
                if not perf_csv.name.startswith("country_ai_record_"):
                    perf_csv.unlink(missing_ok=True)
    return combine(metrics, args.objective), metrics


# ---------------------------------------------------------------------------
# sep-CMA-ES (Ros & Hansen 2008), maximizing the objective.


class SepCmaEs:
    def __init__(self, mean: list[float], sigma: float, seed: int, popsize: int = 0):
        n = len(mean)
        self.n = n
        self.lam = popsize or 4 + int(3 * math.log(n))
        self.mu = self.lam // 2
        raw = [math.log(self.mu + 0.5) - math.log(i + 1) for i in range(self.mu)]
        total = sum(raw)
        self.w = [r / total for r in raw]
        self.mueff = 1.0 / sum(x * x for x in self.w)
        self.cc = 4.0 / (n + 4.0)
        self.cs = (self.mueff + 2.0) / (n + self.mueff + 3.0)
        c1 = 2.0 / ((n + 1.3) ** 2 + self.mueff)
        cmu = min(1.0 - c1, 2.0 * (self.mueff - 2.0 + 1.0 / self.mueff) / ((n + 2.0) ** 2 + self.mueff))
        scale = (n + 2.0) / 3.0
        self.c1 = min(1.0, c1 * scale)
        self.cmu = min(1.0 - self.c1, cmu * scale)
        self.damps = 1.0 + 2.0 * max(0.0, math.sqrt((self.mueff - 1.0) / (n + 1.0)) - 1.0) + self.cs
        self.chin = math.sqrt(n) * (1.0 - 1.0 / (4.0 * n) + 1.0 / (21.0 * n * n))
        self.mean = list(mean)
        self.sigma = sigma
        self.diag = [1.0] * n
        self.ps = [0.0] * n
        self.pc = [0.0] * n
        self.gen = 0
        self.rng = random.Random(seed)

    def ask(self) -> list[list[float]]:
        out = []
        for _ in range(self.lam):
            x = [self.mean[j] + self.sigma * math.sqrt(self.diag[j]) * self.rng.gauss(0.0, 1.0)
                 for j in range(self.n)]
            out.append(x)
        return out

    def tell(self, xs: list[list[float]], scores: list[float]) -> None:
        order = sorted(range(len(xs)), key=lambda i: scores[i], reverse=True)[: self.mu]
        ys = [[(xs[i][j] - self.mean[j]) / self.sigma for j in range(self.n)] for i in order]
        yw = [sum(self.w[k] * ys[k][j] for k in range(self.mu)) for j in range(self.n)]
        self.mean = [self.mean[j] + self.sigma * yw[j] for j in range(self.n)]
        zw = [yw[j] / math.sqrt(self.diag[j]) for j in range(self.n)]
        coef_s = math.sqrt(self.cs * (2.0 - self.cs) * self.mueff)
        self.ps = [(1.0 - self.cs) * self.ps[j] + coef_s * zw[j] for j in range(self.n)]
        ps_norm = math.sqrt(sum(v * v for v in self.ps))
        denom = math.sqrt(1.0 - (1.0 - self.cs) ** (2 * (self.gen + 1)))
        hsig = 1.0 if ps_norm / denom / self.chin < 1.4 + 2.0 / (self.n + 1.0) else 0.0
        coef_c = math.sqrt(self.cc * (2.0 - self.cc) * self.mueff)
        self.pc = [(1.0 - self.cc) * self.pc[j] + hsig * coef_c * yw[j] for j in range(self.n)]
        for j in range(self.n):
            rank_mu = sum(self.w[k] * ys[k][j] ** 2 for k in range(self.mu))
            self.diag[j] = ((1.0 - self.c1 - self.cmu) * self.diag[j]
                            + self.c1 * (self.pc[j] ** 2
                                         + (1.0 - hsig) * self.cc * (2.0 - self.cc) * self.diag[j])
                            + self.cmu * rank_mu)
            self.diag[j] = max(1e-12, self.diag[j])
        self.sigma *= math.exp((self.cs / self.damps) * (ps_norm / self.chin - 1.0))
        self.sigma = min(self.sigma, 1.0)
        self.gen += 1

    def state(self) -> dict:
        return {"mean": self.mean, "sigma": self.sigma, "diag": self.diag, "ps": self.ps,
                "pc": self.pc, "gen": self.gen, "lam": self.lam, "rng": list(self.rng.getstate())}

    def load(self, state: dict) -> None:
        self.mean, self.sigma, self.diag = state["mean"], state["sigma"], state["diag"]
        self.ps, self.pc, self.gen = state["ps"], state["pc"], state["gen"]
        version, internal, gauss_next = state["rng"]
        self.rng.setstate((version, tuple(internal), gauss_next))


# ---------------------------------------------------------------------------


def decode_values(params: list[Param], u: list[float]) -> dict:
    return {p.path: p.decode(x) for p, x in zip(params, u)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", default=DEFAULT_GODOT)
    parser.add_argument("--space", type=Path, default=Path(__file__).with_name("param_space.json"))
    parser.add_argument("--work", type=Path, default=REPO_ROOT / "tmp" / "country_ai_tune")
    parser.add_argument("--generations", type=int, default=8)
    parser.add_argument("--popsize", type=int, default=0, help="0 = 4 + 3 ln(n)")
    parser.add_argument("--sigma", type=float, default=0.2, help="initial step in the normalized box")
    parser.add_argument("--rng-seed", type=int, default=1)
    parser.add_argument("--seeds", type=int, nargs="+", default=[20260718, 20260719])
    parser.add_argument("--days", type=int, default=1825)
    parser.add_argument("--speed", type=float, default=200.0)
    parser.add_argument("--width", type=int, default=60)
    parser.add_argument("--height", type=int, default=40)
    parser.add_argument("--foreign-count", type=int, default=5)
    parser.add_argument("--jobs", type=int, default=1, help="parallel candidates")
    parser.add_argument("--run-timeout", type=float, default=3600.0)
    parser.add_argument("--keep-runs", action="store_true")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--baseline-only", action="store_true", help="score the current catalog and exit")
    parser.add_argument("--write-back", action="store_true",
                        help="write the best candidate into data/country/default_country_ai.tres")
    args = parser.parse_args()

    if not Path(args.godot).exists():
        print(f"Godot executable not found: {args.godot}", file=sys.stderr)
        return 2
    params, objective = load_space(args.space)
    args.objective = objective
    args.work.mkdir(parents=True, exist_ok=True)
    state_path = args.work / "state.json"
    history_path = args.work / "history.jsonl"

    baseline = read_current_values(args.godot, args.space.resolve(), args.work)
    x0 = [p.encode(baseline[p.path]) for p in params]
    es = SepCmaEs(x0, args.sigma, args.rng_seed, args.popsize)
    best = {"score": -math.inf, "values": decode_values(params, x0), "metrics": []}

    if args.resume and state_path.exists():
        saved = json.loads(state_path.read_text(encoding="utf-8"))
        es.load(saved["es"])
        best = saved["best"]
        print(f"[cmaes] resumed at generation {es.gen}, best={best['score']:.4f}")
    else:
        score, metrics = evaluate(args.godot, best["values"], args.work / "baseline", args)
        best = {"score": score, "values": best["values"], "metrics": metrics}
        print(f"[cmaes] baseline score={score:.4f} metrics={json.dumps(metrics)}")
        with history_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"gen": -1, "score": score, "values": best["values"], "metrics": metrics}) + "\n")
    if args.baseline_only:
        return 0

    while es.gen < args.generations:
        started = time.time()
        population = es.ask()
        clipped = [[min(1.0, max(0.0, v)) for v in x] for x in population]
        gen_dir = args.work / f"gen_{es.gen:03d}"

        def job(index: int):
            values = decode_values(params, clipped[index])
            return evaluate(args.godot, values, gen_dir / f"cand_{index:02d}", args)

        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            results = list(pool.map(job, range(len(population))))
        scores = []
        for index, (score, metrics) in enumerate(results):
            # Out-of-box samples are clipped for evaluation and penalized by
            # their squared distance so the mean drifts back into bounds.
            penalty = sum((a - b) ** 2 for a, b in zip(population[index], clipped[index]))
            scores.append(score - penalty)
            values = decode_values(params, clipped[index])
            with history_path.open("a", encoding="utf-8") as fh:
                fh.write(json.dumps({"gen": es.gen, "cand": index, "score": score,
                                     "values": values, "metrics": metrics}) + "\n")
            if score > best["score"]:
                best = {"score": score, "values": values, "metrics": metrics}
        es.tell(population, scores)
        state_path.write_text(json.dumps({"es": es.state(), "best": best}, indent=2), encoding="utf-8")
        print(f"[cmaes] gen={es.gen} best_gen={max(scores):.4f} best={best['score']:.4f} "
              f"sigma={es.sigma:.4f} elapsed={time.time() - started:.0f}s")

    (args.work / "best_params.json").write_text(json.dumps(best, indent=2), encoding="utf-8")
    write_catalog(args.godot, best["values"], args.work / "best_values.json", args.work / "best_candidate.tres")
    print(f"[cmaes] best score={best['score']:.4f} -> {args.work / 'best_candidate.tres'}")
    if args.write_back:
        target = PROJECT_DIR / "data" / "country" / "default_country_ai.tres"
        write_catalog(args.godot, best["values"], args.work / "best_values.json", target)
        print(f"[cmaes] wrote best values back to {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

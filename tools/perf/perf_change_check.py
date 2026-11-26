#!/usr/bin/env python3
"""Measure Project.Keynes simulation performance per commit and compare two commits.

Every measurement is stored in a long-lived archive (default ~/.keynes-perf/keynes, or
$KEYNES_PERF_HOME) keyed by commit, scenario, machine, toolchain and measurement
method. A comparison reads two archive records; a record that already exists for
the same identity is reused, so re-checking a PR after review only measures the
new head.

Subcommands:
  measure REV            make sure the archive holds a record for REV
  compare BASE HEAD      measure both if needed, check results are unchanged,
                         compare every metric, write report.json and report.md
  history                list archived records

Exit codes: 0 pass, 1 fail (results changed, a run was invalid, a build failed),
2 needs a person (a claimed metric did not improve, a headline metric regressed),
75 deferred (the machine stayed busy or the run budget expired), 64 usage error.

Only headless measurements are taken. Windowed frame time needs an unlocked
screen and is reported as not measured.

Timing summaries follow the conventions of compare_perf.py from the
project-keynes-runtime-hotloop-optimization skill (+/-15% wall-clock noise,
cumulative scan counters as the deterministic evidence).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import re
import shutil
import sys
import time
from pathlib import Path

from perf_change_metrics import HEADLINE, NOISE, TIERS, compare_rounds, first_difference, judge, to_number
from perf_change_runner import (
    ESTIMATE_S, Archive, Deferred, StepFailed, build_hash, check_budget, git, golden_check, headline,
    load_consistency_check, machine_identity, now, perf_round, prepare_worktree, save, toolchain_identity,
    wait_allowance, wait_for_quiet_machine, work_estimate,
)


METHOD_VERSION = 3
DEFAULT_SCENARIO = {"days": 50, "speed": 50, "seed": 20260718, "width": 60, "height": 40,
                    "foreign_count": 3}


DEFAULT_ROUNDS = 3
GOLDEN_RUNS = 2
EXIT_PASS, EXIT_FAIL, EXIT_HUMAN, EXIT_DEFERRED, EXIT_USAGE = 0, 1, 2, 75, 64


def resolve(repo: Path, rev: str) -> tuple[str, str]:
    commit = git(repo, "rev-parse", "--verify", "--end-of-options", f"{rev}^{{commit}}")
    return commit, git(repo, "log", "-1", "--format=%s", commit)


def identity_for(commit: str, scenario: dict, machine: dict, toolchain: dict) -> dict:
    return {"commit": commit, "scenario": scenario, "method_version": METHOD_VERSION,
            **machine, **toolchain}


def ensure_records(repo: Path, archive: Archive, revs: list[str], args, busy_log: list) -> list[dict]:
    """Return one complete record per rev, measuring alternately only the missing ones."""
    check_budget(args)
    machine, toolchain = machine_identity(), toolchain_identity(args.godot)
    commits = {}
    plans = []
    for rev in revs:
        commit, subject = resolve(repo, rev)
        if commit not in commits:
            identity = identity_for(commit, args.scenario, machine, toolchain)
            record, why = archive.find(identity, args.tier, args.rounds)
            if record is not None:
                print(f"reusing archived record for {commit[:12]}: {record['path']}", flush=True)
                record["reused"] = True
            commits[commit] = {"commit": commit, "subject": subject, "identity": identity,
                               "record": record, "why": why}
        plans.append(commits[commit])
    missing = [plan for plan in commits.values() if plan["record"] is None]
    ready = [(archive.worktrees / p["commit"][:12] / ".perf-built").exists() for p in missing]
    estimate = work_estimate(ready, args.tier, args.rounds)
    args.wait_left = (float("inf") if args.budget <= 0 else
                      wait_allowance(args.budget * 60, time.monotonic() - args.started, estimate))
    if missing:
        print(f"estimated work {estimate:.0f}s; may wait up to "
              f"{'unlimited' if args.budget <= 0 else f'{args.wait_left:.0f}s'} for a quiet machine", flush=True)
    for position, plan in enumerate(missing):
        check_budget(args)
        print(f"measuring {plan['commit'][:12]} ({plan['why']})", flush=True)
        record_dir = archive.new_record_dir(plan["identity"])
        plan["dir"] = record_dir
        plan["worktree"] = prepare_worktree(repo, archive, plan["commit"], args, record_dir, busy_log)
        check_budget(args)
        if args.budget > 0:
            # The build is done: give waiting what is left after the remaining work.
            remaining = (work_estimate([True] + ready[position + 1:], args.tier, args.rounds)
                         + position * args.rounds * ESTIMATE_S["round"])  # earlier commits' rounds
            args.wait_left = wait_allowance(args.budget * 60, time.monotonic() - args.started, remaining)
        record = {"identity": plan["identity"], "subject": plan["subject"], "tier": args.tier,
                  "created": now(), "status": "measuring", "build": build_hash(plan["worktree"]),
                  "rounds": [], "load_samples": [], "path": str(record_dir)}
        plan["record"] = record
        save(record_dir / "record.json", record)
        wait_for_quiet_machine(args, busy_log)
        record["golden"] = golden_check(plan["worktree"], record_dir, args.godot, GOLDEN_RUNS)
        if args.tier == "full":
            wait_for_quiet_machine(args, busy_log)
            record["load_consistency"] = load_consistency_check(plan["worktree"], record_dir, args.godot)
    for index in range(1, args.rounds + 1):
        for plan in missing:
            sample = wait_for_quiet_machine(args, busy_log)
            plan["record"]["load_samples"].append(sample)
            out = plan["dir"] / f"round-{index}"
            label = f"{plan['commit'][:12]}-r{index}"
            print(f"round {index}/{args.rounds} {plan['commit'][:12]}", flush=True)
            plan["record"]["rounds"].append(
                perf_round(plan["worktree"], out, args.scenario, args.tier, args.godot, label))
    check_budget(args)
    for plan in missing:
        record = plan["record"]
        record["headline"] = headline(record["rounds"])
        valid = (record["golden"]["passed"] and all(not r["errors"] for r in record["rounds"])
                 and record.get("load_consistency", {"passed": True})["passed"])
        record["status"] = "complete" if valid else "invalid"
        record["finished"] = now()
        save(plan["dir"] / "record.json", record)
        archive.index(record)
    return [plan["record"] for plan in plans]


def correctness_facts(base: dict, head: dict) -> list[str]:
    facts = []
    for name, record in (("base", base), ("head", head)):
        golden = record.get("golden", {})
        if not golden.get("passed"):
            facts.append(f"{name} {record['identity']['commit'][:12]}: same-input repeat check failed "
                         f"({golden.get('log')})")
        load = record.get("load_consistency")
        if load is not None and not load.get("passed"):
            facts.append(f"{name}: results changed under CPU load ({load.get('log')})")
    if not facts:
        expected = json.loads(Path(base["golden"]["candidate"]).read_text())
        actual = json.loads(Path(head["golden"]["candidate"]).read_text())
        diff = first_difference(expected, actual)
        if diff:
            facts.append(f"daily results differ between base and head at {diff['path']}: {json.dumps(diff)[:400]}")
    return facts


def render_markdown(report: dict) -> str:
    base, head = report["base"], report["head"]
    lines = [f"# Performance change check: {base['commit'][:12]} → {head['commit'][:12]}", "",
             f"- Status: **{report['status']}**" + (f" — {'; '.join(report['reasons'])}" if report["reasons"] else ""),
             f"- Base: `{base['commit'][:12]}` {base['subject']} ({'archived ' + base['created'] if base['reused'] else 'measured now'})",
             f"- Head: `{head['commit'][:12]}` {head['subject']} ({'archived ' + head['created'] if head['reused'] else 'measured now'})",
             f"- Scenario: {json.dumps(report['scenario'])}; tier {report['tier']}; "
             f"base {base['rounds']} rounds, head {head['rounds']} rounds",
             f"- Machine: {report['machine']}; toolchain: {report['toolchain']}",
             f"- Noise threshold for timings: ±{report['noise']:.0%} and no overlap between the two sides' ranges",
             "", "## Results unchanged", ""]
    lines += [f"- {fact}" for fact in report["correctness"]] or [
        "- Same-input repeat check passed on both sides, and the daily per-domain hashes of base and head are identical."]
    if report["tier"] == "full":
        lines.append("- CPU-load consistency check: " + ", ".join(
            f"{side} {'passed' if report[side].get('load_consistency', {}).get('passed') else 'FAILED'}"
            for side in ("base", "head")))
    rows = report["metrics"]
    def fmt(value):
        return "—" if value is None else f"{value:,.4g}"
    def table(selected, title):
        if not selected:
            return
        lines.extend(["", f"## {title}", "", "| metric | base median | head median | change | base range | head range | status |",
                      "|---|---:|---:|---:|---|---|---|"])
        for row in selected:
            change = "—" if row.get("change") is None else f"{row['change']:+.1%}"
            ranges = [f"{fmt(min(v))}–{fmt(max(v))}" if v else "—" for v in (row["base"], row["head"])]
            lines.append(f"| `{row['metric']}` | {fmt(row.get('base_median'))} | {fmt(row.get('head_median'))} | "
                         f"{change} | {ranges[0]} | {ranges[1]} | {row['status']} |")
    by_name = {row["metric"]: row for row in rows}
    table([by_name[name] for name in HEADLINE if name in by_name], "Headline")
    claimed = [row for row in rows if any(re.search(p, row["metric"]) for p in report["claims"])]
    table(claimed, "Claimed metrics")
    moved = sorted((row for row in rows if row["status"] in ("improved", "regressed")),
                   key=lambda row: -abs(row.get("change") or 0))
    table(moved[:40], f"Beyond noise ({len(moved)})")
    work = sorted((row for row in rows if row["status"] in ("less_work", "more_work", "changed")),
                  key=lambda row: -abs(row.get("change") or 0))
    table(work[:40], f"Deterministic counters and gauges that changed ({len(work)})")
    counts = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    lines += ["", "## Coverage", "",
              f"- {len(rows)} metrics compared: " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())),
              *(f"- Excluded from the statistics: {item}" for item in report.get("excluded_rounds", [])),
              *([f"- Claim not measured headlessly: {report['unmeasured']}"] if report.get("unmeasured") else []),
              "- Not measured: windowed frame time and GPU work (needs an unlocked screen).",
              f"- Raw data: base `{base['path']}`, head `{head['path']}`"]
    if report["busy_samples"]:
        lines.append(f"- Waited for a busy machine {len(report['busy_samples'])} time(s) before measuring.")
    if "elapsed_s" in report:
        budget = report.get("budget_min") or 0
        lines.append(f"- Run time: {report['elapsed_s']}s" + (f" of a {budget:g}-minute budget" if budget else ""))
    return "\n".join(lines) + "\n"


def assess(base: dict, head: dict, claims: list[str], noise: float,
           unmeasured: str | None = None) -> dict:
    """Correctness is always checked; invalid rounds fail the check and never enter the statistics."""
    invalid = [f"{side} round {i}: {'; '.join(r['errors'])}"
               for side, record in (("base", base), ("head", head))
               for i, r in enumerate(record["rounds"], 1) if r["errors"]]
    # A full record may satisfy a quick request. Waterfall timings belong to the full tier.
    same_tier = base.get("tier", "quick") == head.get("tier", "quick")

    def valid_metrics(record):
        samples = [r["metrics"] for r in record["rounds"] if not r["errors"]]
        if same_tier:
            return samples
        return [{key: value for key, value in sample.items() if not key.startswith("waterfall.")}
                for sample in samples]

    correctness = correctness_facts(base, head)
    methods = [{run.get("recorder_method") for run in record["rounds"] if not run["errors"]}
               for record in (base, head)]
    method_errors = [f"{side} has missing or inconsistent recorder methods"
                     for side, method in zip(("base", "head"), methods)
                     if len(method) > 1 or None in method]
    invalid.extend(method_errors)
    if method_errors:
        rows = []
        status, reasons = judge(correctness, invalid, rows, claims, unmeasured)
    elif all(methods) and methods[0] != methods[1]:
        base_method, head_method = (next(iter(method)) for method in methods)
        reasons = correctness + invalid
        status = "fail" if reasons else "needs_human"
        reasons.append(f"incompatible recorder methods: {base_method} vs {head_method}")
        rows = []
    else:
        rows = compare_rounds(valid_metrics(base), valid_metrics(head), noise)
        status, reasons = judge(correctness, invalid, rows, claims, unmeasured)
    return {"status": status, "reasons": reasons, "correctness": correctness, "rows": rows,
            "excluded_rounds": invalid}


def command_compare(args, repo: Path, archive: Archive) -> int:
    busy = []
    base, head = ensure_records(repo, archive, [args.base, args.head], args, busy)
    verdict = assess(base, head, args.claim, args.noise, args.unmeasured)
    status, reasons, correctness, rows = (verdict[key] for key in ("status", "reasons", "correctness", "rows"))
    def side(record):
        return {"commit": record["identity"]["commit"], "subject": record.get("subject"),
                "created": record.get("created"), "reused": bool(record.get("reused")),
                "rounds": len(record["rounds"]),
                "path": record.get("path"), "load_consistency": record.get("load_consistency")}
    report = {"status": status, "reasons": reasons, "base": side(base), "head": side(head),
              "scenario": args.scenario, "tier": args.tier, "requested_rounds": args.rounds, "noise": args.noise,
              "claims": args.claim, "unmeasured": args.unmeasured, "machine": head["identity"]["machine_label"],
              "toolchain": head["identity"]["toolchain_label"], "correctness": correctness,
              "busy_samples": busy, "metrics": rows, "excluded_rounds": verdict["excluded_rounds"],
              "elapsed_s": round(time.monotonic() - args.started), "budget_min": args.budget,
              "created": now(), "method_version": METHOD_VERSION}
    out = Path(args.out) if args.out else archive.comparisons / (
        f"{base['identity']['commit'][:12]}..{head['identity']['commit'][:12]}-"
        f"{dt.datetime.now().strftime('%Y%m%d-%H%M%S-%f')}")
    markdown = render_markdown(report)
    check_budget(args)
    out.mkdir(parents=True, exist_ok=True)
    save(out / "report.json", report)
    (out / "report.md").write_text(markdown, encoding="utf-8")
    print(f"PERF_CHECK_RESULT={json.dumps({'status': status, 'reasons': reasons, 'report': str(out / 'report.md')}, ensure_ascii=False)}")
    return {"pass": EXIT_PASS, "needs_human": EXIT_HUMAN}.get(status, EXIT_FAIL)


def command_measure(args, repo: Path, archive: Archive) -> int:
    record, = ensure_records(repo, archive, [args.rev], args, [])
    check_budget(args)
    print(f"PERF_RECORD={json.dumps({'status': record['status'], 'path': record['path']})}")
    return EXIT_PASS if record["status"] == "complete" else EXIT_FAIL


def command_history(args, archive: Archive) -> int:
    index = archive.home / "index.jsonl"
    if not index.exists():
        print("archive is empty")
        return EXIT_PASS
    for line in index.read_text().splitlines():
        entry = json.loads(line)
        if args.commit and not entry["commit"].startswith(args.commit):
            continue
        head = entry.get("headline", {})
        print(f"{entry['created']} {entry['commit'][:12]} {entry['status']:<8} {entry['tier']:<5} "
              f"run_ms={head.get('result.run_ms', float('nan')):.0f} "
              f"days/s={head.get('auth.authoritative_days_per_second', float('nan')):.2f} "
              f"rss_mb={head.get('rusage.maxrss_mb', float('nan')):.0f}  {entry.get('subject') or ''}")
    return EXIT_PASS


def parse_args(argv: list[str]):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=".", help="Project.Keynes checkout (default: current directory)")
    parser.add_argument("--home", default=os.environ.get("KEYNES_PERF_HOME", "~/.keynes-perf/keynes"))
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--scons", default=shutil.which("scons"))
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("measure", "compare"):
        p = sub.add_parser(name)
        if name == "measure":
            p.add_argument("rev")
        else:
            p.add_argument("base")
            p.add_argument("head")
            p.add_argument("--claim", action="append", default=[],
                           help="regex of a metric the change claims to improve (repeatable)")
            p.add_argument("--unmeasured", metavar="REASON",
                           help="part of the claimed gain has no headless metric (say why); the daily "
                                "results, headline metrics and any --claim are still judged, and the "
                                "run never passes")
            p.add_argument("--noise", type=float, default=NOISE)
            p.add_argument("--out", help="report directory (default: inside the archive)")
        p.add_argument("--tier", choices=TIERS, default="quick")
        p.add_argument("--rounds", type=int, default=DEFAULT_ROUNDS)
        for key, value in DEFAULT_SCENARIO.items():
            p.add_argument(f"--{key.replace('_', '-')}", type=int, default=value)
        p.add_argument("--min-idle", type=float, default=0.5,
                       help="lowest CPU idle fraction over one second allowed before each step")
        p.add_argument("--budget", type=float, default=10,
                       help="minutes for the whole run; waiting for a quiet machine gets what the "
                            "estimated work leaves, then the run is deferred (0 = no limit)")
        p.add_argument("--poll-seconds", type=float, default=15)
    h = sub.add_parser("history")
    h.add_argument("--commit")
    args = parser.parse_args(argv)
    if args.command == "compare":
        if to_number(args.noise) is None or args.noise < 0:
            parser.error("--noise must be finite and nonnegative")
        if args.unmeasured is not None and not args.unmeasured.strip():
            parser.error("--unmeasured needs a reason")
        if not args.claim and args.unmeasured is None:
            parser.error("compare needs --claim, --unmeasured or both")
        for pattern in args.claim:
            if not pattern.strip():
                parser.error("--claim must be a nonempty regex")
            try:
                re.compile(pattern)
            except re.error as error:
                parser.error(f"invalid --claim regex {pattern!r}: {error}")
    if args.command in ("measure", "compare"):
        if not 0.0 < args.min_idle <= 1.0:
            parser.error("--min-idle must be in (0, 1]")
        if to_number(args.budget) is None or args.budget < 0:
            parser.error("--budget must be 0 (no limit) or positive")
        if to_number(args.poll_seconds) is None or args.poll_seconds <= 0:
            parser.error("--poll-seconds must be finite and positive")
        if args.rounds < 2:
            parser.error("--rounds must be at least 2 so timings have a range")
        args.scenario = {key: getattr(args, key) for key in DEFAULT_SCENARIO}
        if any(value <= 0 for key, value in args.scenario.items() if key != "foreign_count"):
            parser.error("scenario values must be positive")
        if args.foreign_count < 0:
            parser.error("--foreign-count must be nonnegative")
    return args


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
    except SystemExit as exit_:
        return EXIT_USAGE if exit_.code else EXIT_PASS
    args.started = time.monotonic()
    try:
        archive = Archive(Path(args.home).expanduser().resolve())
        if args.command == "history":
            return command_history(args, archive)
        if platform.system() not in ("Darwin", "Linux"):
            raise StepFailed("measure and compare require macOS or Linux for process timing and load sampling")
        repo = Path(git(Path(args.repo), "rev-parse", "--show-toplevel"))
        if args.scons and ("/" in args.scons or args.scons.startswith("~")):
            args.scons = str(Path(args.scons).expanduser().resolve())
        if "/" in args.godot or args.godot.startswith("~"):
            args.godot = str(Path(args.godot).expanduser().resolve())
        with archive.measurement_lock():
            if args.command == "measure":
                return command_measure(args, repo, archive)
            return command_compare(args, repo, archive)
    except Deferred as error:
        print(f"PERF_CHECK_RESULT={json.dumps({'status': 'deferred', 'reasons': [str(error)]})}")
        return EXIT_DEFERRED
    except (StepFailed, OSError) as error:
        print(f"PERF_CHECK_RESULT={json.dumps({'status': 'fail', 'reasons': [str(error)[:1500]]})}")
        return EXIT_FAIL


if __name__ == "__main__":
    raise SystemExit(main())

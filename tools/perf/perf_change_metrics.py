"""Validate measurement data and compare per-run performance metrics."""


from __future__ import annotations

import re
import statistics


TIERS = ("quick", "full")
NOISE = 0.15


HEADLINE = {
    "result.run_ms": "lower",
    "auth.authoritative_days_per_second": "higher",
    "harness.adjusted_days_per_second": "higher",
    "result.generation_ms": "lower",
    "rusage.maxrss_mb": "lower",
    "rusage.cpu_s": "lower",
}


RESULT_PREFIX = "[headless-perf/result]"
AUTH_PREFIX = "[headless-perf/auth]"
HARNESS_PREFIX = "[headless-perf/harness]"


REQUIRED_CSV_COLUMNS = ("tick_idx", "speed_multiplier", "t_sus_ms")
DAY_RECORDER_METHODS = {False: "day_records_worker_v1", True: "day_records_main_v1"}
DAY_CSV_COLUMNS = {*REQUIRED_CSV_COLUMNS, "row_idx", "runtime_graph_simulation_committed_day",
                   "runtime_graph_simulation_generation", "commit_produced_at_us", "commit_interval_ms"}


def parse_kv_line(lines: list[str], prefix: str) -> dict[str, str]:
    """Return the key=value pairs of the single line starting with prefix."""
    found = [line for line in lines if line.startswith(prefix)]
    if len(found) != 1:
        raise ValueError(f"expected one {prefix} line, found {len(found)}")
    payload = found[0][len(prefix):]
    if prefix == RESULT_PREFIX:
        # The recorder prints the CSV path last and does not quote it.
        payload, separator, csv_path = payload.partition(" path=")
    else:
        separator = ""
    pairs = re.findall(r"([A-Za-z_][A-Za-z0-9_]*)=(\S*)", payload)
    if separator:
        pairs.append(("path", csv_path))
    if not pairs:
        raise ValueError(f"{prefix} line has no key=value pairs")
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError(f"{prefix} line repeats a key")
    return dict(pairs)


def to_number(value) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if number == number and abs(number) != float("inf") else None


def validate_day_csv(rows: list[dict], result: dict[str, str]) -> list[str]:
    """The daily format requires a real commit stamp for every measured day."""
    warmup = to_number(result.get("warmup_days"))
    if warmup is None or warmup < 0 or not warmup.is_integer():
        return ["invalid warmup_days for day recorder"]
    if result.get("recorder_method") != DAY_RECORDER_METHODS[warmup == 0]:
        return ["recorder method does not match the warmup clock"]
    previous = None
    for index, row in enumerate(rows):
        day = int(warmup) + index + 1
        if set(row) != DAY_CSV_COLUMNS:
            return ["daily perf csv columns do not match the recorder method"]
        if row["tick_idx"] != str(day) or row["runtime_graph_simulation_committed_day"] != str(day):
            return [f"daily perf csv expected ordered day {day}"]
        if row["t_sus_ms"] != "":
            return [f"day {day}: t_sus_ms must be empty in the daily CSV"]
        stamp = to_number(row["commit_produced_at_us"])
        if stamp is None or stamp <= 0 or not stamp.is_integer() or (previous is not None and stamp < previous):
            return [f"day {day}: invalid commit_produced_at_us"]
        interval = to_number(row["commit_interval_ms"])
        if day == 1:
            if row["commit_interval_ms"] != "":
                return ["day 1: commit_interval_ms has no preceding commit"]
        elif interval is None or interval < 0 or (
                previous is not None and interval != (stamp - previous) / 1000.0):
            return [f"day {day}: invalid commit_interval_ms"]
        previous = stamp
        for column in ("row_idx", "speed_multiplier", "runtime_graph_simulation_generation"):
            if to_number(row[column]) is None:
                return [f"day {day}: {column} is missing or nonnumeric"]
    return []


def validate_perf_run(exit_code: int, result: dict[str, str] | None, csv_rows: list[dict] | None,
                      scenario: dict) -> list[str]:
    """Errors that make a headless perf run unusable as evidence (empty list = valid)."""
    errors = []
    if exit_code != 0:
        errors.append(f"godot exit={exit_code}")
    if result is None:
        return errors + ["missing result line"]
    def number(key):
        value = to_number(result.get(key))
        if value is None:
            errors.append(f"result.{key} missing or not a number")
        return value
    days = scenario["days"]
    rows, expected = number("rows"), number("expected_rows")
    if rows is not None and rows != days:
        errors.append(f"result rows={rows:g} expected {days}")
    if expected is not None and expected != days:
        errors.append(f"result expected_rows={expected:g} expected {days}")
    csv_count = len(csv_rows) if csv_rows is not None else None
    if csv_count != days:
        errors.append(f"perf csv has {csv_count} data rows, expected {days}")
    method = result.get("recorder_method")
    if method is not None and method not in DAY_RECORDER_METHODS.values():
        errors.append(f"unknown recorder method {method!r}")
    elif csv_rows and method is not None:
        errors.extend(validate_day_csv(csv_rows, result))
    elif csv_rows:
        for column in REQUIRED_CSV_COLUMNS:
            if column not in csv_rows[0]:
                errors.append(f"perf csv missing required column {column}")
            elif any(to_number(row.get(column)) is None for row in csv_rows):
                errors.append(f"perf csv required column {column} has a missing or nonnumeric value")
    if result.get("fatal") != "false":
        errors.append(f"fatal={result.get('fatal')}")
    if result.get("economy_configured") != "true":
        errors.append(f"economy_configured={result.get('economy_configured')}")
    if result.get("formal_start") != "true":
        errors.append(f"formal_start={result.get('formal_start')}")
    ledger = number("ledger_failures")
    if ledger is not None and ledger != 0:
        errors.append(f"ledger_failures={ledger:g}")
    population = number("population")
    if population is not None and population <= 0:
        errors.append(f"population={population:g}")
    countries = number("country_count")
    if countries is not None and countries < scenario["foreign_count"] + 1:
        errors.append(f"country_count={countries:g} expected >= {scenario['foreign_count'] + 1}")
    return errors


COST_MARKS = ("bytes", "memory", "_mb", "_kb")


def metric_kind(name: str) -> str:
    """counter: cumulative work; cost: memory or capacity the run holds; timing: varies run to run;
    gauge: anything else, with no better direction."""
    if name.startswith("csv."):
        column = name.split(".")[1]
        if (column.startswith(("bd_economy_scan_", "scan_steps")) or column.endswith("_epoch")
                or column in ("research_full_scan_fallbacks", "bd_country_research_full_scan_fallbacks")):
            return "counter"
    if any(mark in name for mark in ("_ms", "_us", "per_second", "wait")):
        return "timing"
    if any(mark in name.lower() for mark in COST_MARKS):
        return "cost"
    return "timing" if name.startswith("rusage.") else "gauge"


def direction(name: str) -> str:
    return "higher" if "per_second" in name else "lower"


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def csv_metrics(rows: list[dict[str, str]]) -> dict[str, float]:
    """Summarize numeric perf_record samples. The run validator checks required cells."""
    if not rows:
        return {}
    out = {}
    for column in rows[0]:
        if column == "commit_produced_at_us":
            continue  # Absolute timestamps identify samples. Only their intervals are measurements.
        samples = []
        populated = 0
        for day, row in enumerate(rows):
            cell = row.get(column)
            if cell == "":
                continue
            populated += 1
            value = to_number(cell)
            if value is not None:
                samples.append((day, value))
        if not samples:
            # Text labels and optional columns with no samples are part of the recorder's schema.
            continue
        if len(samples) != populated:
            raise ValueError(f"column {column} has {len(samples)}/{populated} numeric populated values")
        name = f"csv.{column}"
        if metric_kind(name + ".per_day") == "counter":
            # A sparse counter needs two readings. Keep the existing one-day summary.
            if len(samples) > 1 or len(rows) == 1:
                first_day, first_value = samples[0]
                last_day, last_value = samples[-1]
                out[f"{name}.per_day"] = (last_value - first_value) / max(last_day - first_day, 1)
            continue
        values = [value for _, value in samples]
        out[f"{name}.mean"] = statistics.fmean(values)
        if column.endswith(("_ms", "_us")):
            out[f"{name}.p95"] = percentile(values, 0.95)
            out[f"{name}.max"] = max(values)
    return out


def waterfall_metrics(rows: list[dict[str, str]]) -> dict[str, float]:
    """Per-day worker segment costs from PK_RUNTIME_WATERFALL_CSV."""
    if not rows:
        return {}
    fixed = {"day", "attempt", "committed", "mask"}
    days = {row.get("day") for row in rows}
    committed = [row for row in rows if row.get("committed") in ("1", "true")]
    out = {"waterfall.attempts_per_day": len(rows) / max(1, len(days)),
           "waterfall.failed_attempts": float(len(rows) - len(committed))}
    for column in rows[0]:
        if column in fixed:
            continue
        values = [to_number(row.get(column)) for row in committed]
        values = [v for v in values if v is not None]
        if values:
            out[f"waterfall.{column}_ms.mean"] = statistics.fmean(values)
            if column == "total":
                out["waterfall.total_ms.p95"] = percentile(values, 0.95)
    return out


def numeric_items(prefix: str, values: dict[str, str]) -> dict[str, float]:
    out = {}
    for key, value in values.items():
        number = to_number(value)
        if number is not None:
            out[f"{prefix}.{key}"] = number
    return out


def compare_metric(name: str, base: list[float], head: list[float], noise: float = NOISE) -> dict:
    """Classify one metric. Deterministic sides compare exactly; timings need a clear gap."""
    row = {"metric": name, "kind": metric_kind(name), "better": direction(name),
           "base": base, "head": head}
    if not base or not head:
        row["status"] = "only_in_head" if head else "only_in_base"
        return row
    med_b, med_h = statistics.median(base), statistics.median(head)
    row.update(base_median=med_b, head_median=med_h,
               change=None if med_b == 0 else (med_h - med_b) / abs(med_b))
    exact = len(set(base)) == 1 and len(set(head)) == 1
    if exact and row["kind"] != "timing":
        if med_b == med_h:
            row["status"] = "unchanged"
        elif row["kind"] in ("counter", "cost"):
            row["status"] = "less_work" if med_h < med_b else "more_work"
        else:
            row["status"] = "changed"
        return row
    if len(base) < 2 or len(head) < 2:
        row["status"] = "insufficient_rounds"
        return row
    change = row["change"]
    separated = max(head) < min(base) or min(head) > max(base)
    if change is None or abs(change) <= noise or not separated:
        row["status"] = "within_noise"
        return row
    faster = (med_h < med_b) if row["better"] == "lower" else (med_h > med_b)
    row["status"] = "improved" if faster else "regressed"
    return row


def compare_rounds(base_rounds: list[dict], head_rounds: list[dict], noise: float = NOISE) -> list[dict]:
    names = sorted({k for r in base_rounds + head_rounds for k in r})
    rows = []
    for name in names:
        base = [r[name] for r in base_rounds if name in r]
        head = [r[name] for r in head_rounds if name in r]
        row = compare_metric(name, base, head, noise)
        if base and head and (len(base) != len(base_rounds) or len(head) != len(head_rounds)):
            row["status"] = "missing_rounds"
        rows.append(row)
    return rows


def first_difference(expected, actual, path="golden"):
    if type(expected) is not type(actual):
        return {"path": path, "base": expected, "head": actual}
    if isinstance(expected, dict):
        if expected.keys() != actual.keys():
            return {"path": path, "base_keys": sorted(expected), "head_keys": sorted(actual)}
        for key in sorted(expected):
            found = first_difference(expected[key], actual[key], f"{path}.{key}")
            if found:
                return found
        return None
    if isinstance(expected, list):
        if len(expected) != len(actual):
            return {"path": path, "base_length": len(expected), "head_length": len(actual)}
        for index, (left, right) in enumerate(zip(expected, actual)):
            found = first_difference(left, right, f"{path}[{index}]")
            if found:
                return found
        return None
    return None if expected == actual else {"path": path, "base": expected, "head": actual}


def record_reusable(record: dict | None, identity: dict, tier: str, rounds: int) -> tuple[bool, str]:
    """A stored record needs an identical identity, a sufficient tier and enough rounds."""
    if record is None:
        return False, "no record"
    if record.get("status") != "complete":
        return False, f"record status {record.get('status')}"
    stored = record.get("identity", {})
    for key in sorted(set(identity) | set(stored)):
        if stored.get(key) != identity.get(key):
            return False, f"identity differs: {key}"
    if TIERS.index(record.get("tier", "quick")) < TIERS.index(tier):
        return False, f"record tier {record.get('tier')} is below {tier}"
    samples = record.get("rounds")
    if not isinstance(samples, list):
        return False, "record has no rounds list"
    if len(samples) < rounds:
        return False, f"record has {len(samples)} rounds, need {rounds}"
    return True, "record matches"


def judge(correctness: list[str], invalid_runs: list[str], rows: list[dict],
          claims: list[str], unmeasured: str | None = None) -> tuple[str, list[str]]:
    """Overall status from facts: fail, needs_human or pass.

    `unmeasured` says why the claimed gain cannot be measured headlessly. The results check and
    the headline metrics are still judged, but such a run never passes: the claim needs a person.
    """
    reasons = list(correctness) + list(invalid_runs)
    if reasons:
        return "fail", reasons
    incomplete = ("only_in_base", "only_in_head", "missing_rounds", "insufficient_rounds")
    missing = [f"incomplete measurement for {row['metric']} ({row['status']})" for row in rows
               if row["status"] in incomplete]
    if missing:
        return "fail", missing
    if unmeasured is not None:
        human = [f"claim not measured headlessly: {unmeasured}"]
    else:
        human = [] if claims else ["no improvement claim supplied"]
    regressions = ("regressed", "more_work")
    for pattern in claims:
        matched = [row for row in rows if re.search(pattern, row["metric"])]
        if not matched:
            human.append(f"claim {pattern!r} matches no metric")
            continue
        if not any(row["status"] in ("improved", "less_work") for row in matched):
            states = sorted({row["status"] for row in matched})
            human.append(f"claim {pattern!r} not shown to improve ({', '.join(states)})")
        for row in matched:
            if row["status"] in regressions:
                human.append(f"claim {pattern!r} includes {row['metric']} ({row['status']})")
    for row in rows:
        if row["metric"] in HEADLINE and row["status"] in regressions:
            change = row.get("change")
            extent = f" {change:+.1%}" if change is not None else ""
            human.append(f"headline {row['metric']} {row['status']}{extent}")
    return ("needs_human", human) if human else ("pass", [])

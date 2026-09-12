#!/usr/bin/env python3
"""Streaming/disk-backed comparison for Stage C2 full-SoA recordings."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import random
import sqlite3
from pathlib import Path

COMPAT_KEYS = (
    "build", "seed", "map_width", "map_height", "num_continents", "continent_size",
    "foreign_count", "speed", "graphics_profile", "window_width", "window_height",
    "vsync", "max_fps", "day_night", "overlay", "warmup_seconds", "record_seconds",
    "warmup_until_tick", "record_ticks",
    "tick_stride", "cell_stride", "max_rows", "compact_fields",
)
RESERVOIR_SIZE = 50_000


def session_value(sidecar: dict, key: str):
    if key in sidecar:
        return sidecar[key]
    session = sidecar.get("session", {})
    if key in session:
        return session[key]
    for section in ("tick_coverage", "cell_coverage", "sampling"):
        if key in sidecar.get(section, {}):
            return sidecar[section][key]
    return None


def stable_seed(name: str) -> int:
    return int.from_bytes(hashlib.sha256(name.encode("utf-8")).digest()[:8], "little")


class DiffStats:
    def __init__(self, field: str):
        self.count = 0
        self.sum = 0.0
        self.max = 0.0
        self.diff_count = 0
        self.first = None
        self.sample: list[float] = []
        self.rng = random.Random(stable_seed(field))

    def add(self, tick: int, cell: int, left: float, right: float):
        value = abs(left - right)
        self.count += 1
        self.sum += value
        self.max = max(self.max, value)
        if value > 0.0:
            self.diff_count += 1
            if self.first is None:
                self.first = {"tick_idx": tick, "cell_index": cell, "left": left, "right": right, "abs_diff": value}
        if len(self.sample) < RESERVOIR_SIZE:
            self.sample.append(value)
        else:
            slot = self.rng.randrange(self.count)
            if slot < RESERVOIR_SIZE:
                self.sample[slot] = value

    def p95(self) -> float:
        if not self.sample:
            return 0.0
        ordered = sorted(self.sample)
        return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def parse_number(raw: str):
    if raw is None or raw.strip() == "":
        return None, "empty"
    try:
        value = float(raw)
    except ValueError:
        return None, "invalid"
    if not math.isfinite(value):
        return None, "nonfinite"
    return value, None


def quoted(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def load_csv(connection, table: str, path: Path, fields: list[str]):
    columns = ",".join(f"{quoted(field)} REAL" for field in fields)
    connection.execute(f"CREATE TABLE {table}(tick_idx INTEGER NOT NULL, cell_index INTEGER NOT NULL,{columns},PRIMARY KEY(tick_idx,cell_index)) WITHOUT ROWID")
    placeholders = ",".join("?" for _ in range(2 + len(fields)))
    insert = f"INSERT INTO {table} VALUES({placeholders})"
    issues = {field: {"empty": 0, "invalid": 0, "nonfinite": 0} for field in fields}
    batch = []
    rows = 0
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        required = {"tick_idx", "cell_index", *fields}
        missing = sorted(required - set(reader.fieldnames or []))
        if missing:
            raise ValueError(f"{path}: missing CSV columns: {missing}")
        for row in reader:
            values = [int(row["tick_idx"]), int(row["cell_index"])]
            for field in fields:
                value, issue = parse_number(row[field])
                if issue:
                    issues[field][issue] += 1
                values.append(value)
            batch.append(values)
            rows += 1
            if len(batch) >= 5000:
                connection.executemany(insert, batch)
                batch.clear()
        if batch:
            connection.executemany(insert, batch)
    connection.commit()
    return rows, issues


def issue_total(issues: dict) -> int:
    return sum(sum(counts.values()) for counts in issues.values())


def missing_summary(connection, source: str, other: str):
    where = f"FROM {source} s LEFT JOIN {other} o USING(tick_idx,cell_index) WHERE o.tick_idx IS NULL"
    count = connection.execute("SELECT COUNT(*) " + where).fetchone()[0]
    examples = [{"tick_idx": row[0], "cell_index": row[1]} for row in connection.execute("SELECT s.tick_idx,s.cell_index " + where + " ORDER BY s.tick_idx,s.cell_index LIMIT 20")]
    return {"count": count, "examples": examples}


def country_evidence_index(sidecar: dict):
    evidence = sidecar.get("country_evidence", {})
    if evidence.get("schema") != "CountryClientEvidence" or evidence.get("schema_version") != 1:
        return None, {"reason": "country_evidence_schema_missing_or_invalid"}
    indexed = {}
    for sample in evidence.get("samples", []):
        tick = int(sample.get("tick_idx", -1))
        for country in sample.get("countries", []):
            country_id = str(country.get("country_id", ""))
            if tick < 0 or not country_id:
                continue
            indexed[(tick, country_id)] = {
                "territory_count": int(country.get("territory_count", -1)),
                "cash": int(country.get("cash", 0)),
                "goods": list(zip(country.get("good_ids", []), country.get("good_quantities", []))),
                "technology_ids": list(country.get("technology_ids", [])),
                "research_states": list(country.get("research_states", [])),
                "research_queue": list(country.get("research_queue", [])),
            }
    receipts = [{
        key: row.get(key) for key in (
            "request_id", "producer_id", "sequence", "effective_day",
            "generation", "code", "status", "reason")
    } for row in evidence.get("terminal_receipts", [])]
    return {"countries": indexed, "receipts": receipts}, None


def compare_country_evidence(left_meta: dict, right_meta: dict):
    left, left_error = country_evidence_index(left_meta)
    right, right_error = country_evidence_index(right_meta)
    if left_error or right_error:
        return {
            "status": "release_blocker",
            "left_error": left_error,
            "right_error": right_error,
            "missing_left": [],
            "missing_right": [],
            "differences": [],
            "receipt_match": False,
        }
    left_keys = set(left["countries"])
    right_keys = set(right["countries"])
    differences = []
    for key in sorted(left_keys & right_keys):
        if left["countries"][key] != right["countries"][key]:
            differences.append({
                "tick_idx": key[0],
                "country_id": key[1],
                "left": left["countries"][key],
                "right": right["countries"][key],
            })
            if len(differences) >= 100:
                break
    missing_left = [{"tick_idx": key[0], "country_id": key[1]}
                    for key in sorted(right_keys - left_keys)[:100]]
    missing_right = [{"tick_idx": key[0], "country_id": key[1]}
                     for key in sorted(left_keys - right_keys)[:100]]
    receipt_match = left["receipts"] == right["receipts"]
    status = "pass" if not differences and not missing_left and not missing_right and receipt_match else "release_blocker"
    return {
        "status": status,
        "left_country_rows": len(left_keys),
        "right_country_rows": len(right_keys),
        "missing_left": missing_left,
        "missing_right": missing_right,
        "differences": differences,
        "receipt_match": receipt_match,
        "left_receipts": left["receipts"],
        "right_receipts": right["receipts"],
    }


def modifier_evidence_samples(sidecar: dict):
    evidence = sidecar.get("modifier_evidence", {})
    if evidence.get("schema") != "ModifierClientEvidence" or evidence.get("schema_version") != 1:
        return None, {"field": "modifier_evidence", "detail": "schema_missing_or_invalid"}
    indexed = {}
    for sample in evidence.get("samples", []):
        tick = int(sample.get("tick_idx", -1))
        if tick < 0:
            continue
        indexed[tick] = {
            "state_hash": int(sample.get("state_hash", 0)),
            "snapshot_generation": int(sample.get("snapshot_generation", 0)),
            "ack_count": int(sample.get("ack_count", 0)),
        }
    return indexed, None


def compare_modifier_evidence(left_meta: dict, right_meta: dict, policy: dict) -> list[dict]:
    """E8 ModifierClientEvidence: undeclared divergences are blockers.

    Declared fields under policy['modifier_evidence'] use absolute_tolerance.
    Compares per-tick samples when present; also compares sidecar summary keys.
    """
    mismatches: list[dict] = []
    left, left_error = modifier_evidence_samples(left_meta)
    right, right_error = modifier_evidence_samples(right_meta)
    if left_error:
        mismatches.append(left_error)
    if right_error:
        mismatches.append(right_error)
    if left is None or right is None:
        return mismatches

    field_policy = policy.get("modifier_evidence", {})
    left_ticks = set(left)
    right_ticks = set(right)
    for tick in sorted(right_ticks - left_ticks)[:50]:
        mismatches.append({"field": "modifier_evidence", "tick_idx": tick, "detail": "missing_left_sample"})
    for tick in sorted(left_ticks - right_ticks)[:50]:
        mismatches.append({"field": "modifier_evidence", "tick_idx": tick, "detail": "missing_right_sample"})

    compared_fields = ("state_hash", "snapshot_generation", "ack_count")
    for tick in sorted(left_ticks & right_ticks):
        for field in compared_fields:
            left_value = left[tick][field]
            right_value = right[tick][field]
            abs_diff = abs(left_value - right_value)
            if abs_diff == 0:
                continue
            limits = field_policy.get(field)
            if not isinstance(limits, dict) or "absolute_tolerance" not in limits:
                mismatches.append({
                    "field": field,
                    "tick_idx": tick,
                    "detail": "undeclared_difference",
                    "left": left_value,
                    "right": right_value,
                    "abs_diff": abs_diff,
                })
                continue
            tolerance = float(limits.get("absolute_tolerance", 0.0))
            if abs_diff > tolerance:
                mismatches.append({
                    "field": field,
                    "tick_idx": tick,
                    "detail": "declared_tolerance_exceeded",
                    "left": left_value,
                    "right": right_value,
                    "abs_diff": abs_diff,
                    "absolute_tolerance": tolerance,
                })
        if len(mismatches) >= 200:
            break

    # Summary keys (last sample) — catch recordings that only store aggregates.
    for field in compared_fields:
        left_summary = left_meta.get("modifier_evidence", {}).get(field)
        right_summary = right_meta.get("modifier_evidence", {}).get(field)
        if left_summary is None or right_summary is None:
            continue
        abs_diff = abs(int(left_summary) - int(right_summary))
        if abs_diff == 0:
            continue
        limits = field_policy.get(field)
        if not isinstance(limits, dict) or "absolute_tolerance" not in limits:
            mismatches.append({
                "field": field,
                "detail": "undeclared_summary_difference",
                "left": int(left_summary),
                "right": int(right_summary),
                "abs_diff": abs_diff,
            })
        elif abs_diff > float(limits.get("absolute_tolerance", 0.0)):
            mismatches.append({
                "field": field,
                "detail": "declared_summary_tolerance_exceeded",
                "left": int(left_summary),
                "right": int(right_summary),
                "abs_diff": abs_diff,
                "absolute_tolerance": float(limits.get("absolute_tolerance", 0.0)),
            })
    return mismatches


def effect_evidence_samples(sidecar: dict):
    evidence = sidecar.get("effect_evidence", {})
    if evidence.get("schema") != "EffectClientEvidence" or evidence.get("schema_version") != 1:
        return None, {"field": "effect_evidence", "detail": "schema_missing_or_invalid"}
    indexed = {}
    for sample in evidence.get("samples", []):
        tick = int(sample.get("tick_idx", -1))
        if tick < 0:
            continue
        indexed[tick] = {
            "state_hash": int(sample.get("state_hash", 0)),
            "snapshot_generation": int(sample.get("snapshot_generation", 0)),
            "ack_count": int(sample.get("ack_count", 0)),
        }
    return indexed, None


def compare_effect_evidence(left_meta: dict, right_meta: dict, policy: dict) -> list[dict]:
    """F8 EffectClientEvidence: undeclared divergences are blockers.

    Declared fields under policy['effect_evidence'] use absolute_tolerance.
    Compares per-tick samples when present; also compares sidecar summary keys.
    """
    mismatches: list[dict] = []
    left, left_error = effect_evidence_samples(left_meta)
    right, right_error = effect_evidence_samples(right_meta)
    if left_error:
        mismatches.append(left_error)
    if right_error:
        mismatches.append(right_error)
    if left is None or right is None:
        return mismatches

    field_policy = policy.get("effect_evidence", {})
    left_ticks = set(left)
    right_ticks = set(right)
    for tick in sorted(right_ticks - left_ticks)[:50]:
        mismatches.append({"field": "effect_evidence", "tick_idx": tick, "detail": "missing_left_sample"})
    for tick in sorted(left_ticks - right_ticks)[:50]:
        mismatches.append({"field": "effect_evidence", "tick_idx": tick, "detail": "missing_right_sample"})

    compared_fields = ("state_hash", "snapshot_generation", "ack_count")
    for tick in sorted(left_ticks & right_ticks):
        for field in compared_fields:
            left_value = left[tick][field]
            right_value = right[tick][field]
            abs_diff = abs(left_value - right_value)
            if abs_diff == 0:
                continue
            limits = field_policy.get(field)
            if not isinstance(limits, dict) or "absolute_tolerance" not in limits:
                mismatches.append({
                    "field": field,
                    "tick_idx": tick,
                    "detail": "undeclared_difference",
                    "left": left_value,
                    "right": right_value,
                    "abs_diff": abs_diff,
                })
                continue
            tolerance = float(limits.get("absolute_tolerance", 0.0))
            if abs_diff > tolerance:
                mismatches.append({
                    "field": field,
                    "tick_idx": tick,
                    "detail": "declared_tolerance_exceeded",
                    "left": left_value,
                    "right": right_value,
                    "abs_diff": abs_diff,
                    "absolute_tolerance": tolerance,
                })
        if len(mismatches) >= 200:
            break

    for field in compared_fields:
        left_summary = left_meta.get("effect_evidence", {}).get(field)
        right_summary = right_meta.get("effect_evidence", {}).get(field)
        if left_summary is None or right_summary is None:
            continue
        abs_diff = abs(int(left_summary) - int(right_summary))
        if abs_diff == 0:
            continue
        limits = field_policy.get(field)
        if not isinstance(limits, dict) or "absolute_tolerance" not in limits:
            mismatches.append({
                "field": field,
                "detail": "undeclared_summary_difference",
                "left": int(left_summary),
                "right": int(right_summary),
                "abs_diff": abs_diff,
            })
        elif abs_diff > float(limits.get("absolute_tolerance", 0.0)):
            mismatches.append({
                "field": field,
                "detail": "declared_summary_tolerance_exceeded",
                "left": int(left_summary),
                "right": int(right_summary),
                "abs_diff": abs_diff,
                "absolute_tolerance": float(limits.get("absolute_tolerance", 0.0)),
            })
    return mismatches


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--left-csv", required=True, type=Path)
    parser.add_argument("--right-csv", required=True, type=Path)
    parser.add_argument("--left-sidecar", required=True, type=Path)
    parser.add_argument("--right-sidecar", required=True, type=Path)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--keep-database", action="store_true")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    left_meta = json.loads(args.left_sidecar.read_text(encoding="utf-8-sig"))
    right_meta = json.loads(args.right_sidecar.read_text(encoding="utf-8-sig"))
    policy = json.loads(args.policy.read_text(encoding="utf-8-sig"))
    fields = [str(value) for value in left_meta.get("soa_fields", [])]
    right_fields = [str(value) for value in right_meta.get("soa_fields", [])]
    mismatches = []
    if left_meta.get("schema") != "TileDataRecorderSidecar" or right_meta.get("schema") != "TileDataRecorderSidecar":
        mismatches.append({"key": "sidecar_schema", "left": left_meta.get("schema"), "right": right_meta.get("schema")})
    if left_meta.get("schema_version") != 1 or right_meta.get("schema_version") != 1:
        mismatches.append({"key": "sidecar_schema_version", "left": left_meta.get("schema_version"), "right": right_meta.get("schema_version")})
    if policy.get("schema") != "AuthorityStageCFieldPolicy" or policy.get("schema_version") != 1 or not isinstance(policy.get("fields"), dict):
        mismatches.append({"key": "field_policy_schema", "schema": policy.get("schema"), "schema_version": policy.get("schema_version")})
    if not fields or not right_fields:
        mismatches.append({"key": "soa_fields", "left": fields, "right": right_fields, "reason": "empty_schema"})
    for key in COMPAT_KEYS:
        left, right = session_value(left_meta, key), session_value(right_meta, key)
        if left != right:
            mismatches.append({"key": key, "left": left, "right": right})
    if fields != right_fields:
        mismatches.append({"key": "soa_fields", "left": fields, "right": right_fields})
    authority_modes = {str(left_meta.get("authority_mode", "")).upper(), str(right_meta.get("authority_mode", "")).upper()}
    if authority_modes != {"ACTIVE", "OFF"}:
        mismatches.append({"key": "authority_mode_pair", "left": left_meta.get("authority_mode"), "right": right_meta.get("authority_mode")})
    if mismatches:
        report = {"schema": "AuthorityStageCTileComparison", "schema_version": 1, "status": "rejected", "compatibility_mismatches": mismatches}
        (args.output_dir / "comparison.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"[stage-c/C2] rejected: {len(mismatches)} metadata/schema mismatches")
        return 2

    db_path = args.output_dir / "comparison.sqlite3"
    connection = sqlite3.connect(db_path)
    connection.execute("PRAGMA journal_mode=OFF")
    connection.execute("PRAGMA synchronous=OFF")
    left_rows, left_issues = load_csv(connection, "left_rows", args.left_csv, fields)
    right_rows, right_issues = load_csv(connection, "right_rows", args.right_csv, fields)
    only_left = missing_summary(connection, "left_rows", "right_rows")
    only_right = missing_summary(connection, "right_rows", "left_rows")
    field_policy = policy.get("fields", {})
    stats = {}
    for field in fields:
        stats[field] = DiffStats(field)

    select_values = ",".join(f"l.{quoted(field)},r.{quoted(field)}" for field in fields)
    query = f"SELECT l.tick_idx,l.cell_index,{select_values} FROM left_rows l JOIN right_rows r USING(tick_idx,cell_index) ORDER BY l.tick_idx,l.cell_index"
    aligned_rows = 0
    for row in connection.execute(query):
        aligned_rows += 1
        tick, cell = row[0], row[1]
        for index, field in enumerate(fields):
            left, right = row[2 + index * 2], row[3 + index * 2]
            if left is not None and right is not None:
                stats[field].add(tick, cell, left, right)

    lag_totals = {field: {lag: [0.0, 0] for lag in range(-2, 3)} for field in fields}
    for lag in range(-2, 3):
        lag_query = f"SELECT {select_values} FROM left_rows l JOIN right_rows r ON r.cell_index=l.cell_index AND r.tick_idx=l.tick_idx+?"
        for row in connection.execute(lag_query, (lag,)):
            for index, field in enumerate(fields):
                left, right = row[index * 2], row[index * 2 + 1]
                if left is not None and right is not None:
                    lag_totals[field][lag][0] += abs(left - right)
                    lag_totals[field][lag][1] += 1

    results = []
    blockers = []
    known_expected = []
    for field in fields:
        item = stats[field]
        mean = item.sum / item.count if item.count else 0.0
        p95 = item.p95()
        lags = [{"lag": lag, "samples": values[1], "mean_abs_diff": values[0] / values[1] if values[1] else None} for lag, values in lag_totals[field].items()]
        viable = [entry for entry in lags if entry["mean_abs_diff"] is not None]
        best = min(viable, key=lambda entry: entry["mean_abs_diff"]) if viable else None
        declared = field in field_policy
        limits = field_policy.get(field, {})
        policy_valid = declared and bool(str(limits.get("reason", "")).strip()) and "absolute_tolerance" in limits
        exceeds = item.diff_count > 0
        if policy_valid:
            exceeds = (item.max > float(limits.get("absolute_tolerance", 0.0)) or
                       mean > float(limits.get("mean_tolerance", limits.get("absolute_tolerance", 0.0))) or
                       p95 > float(limits.get("p95_tolerance", limits.get("absolute_tolerance", 0.0))))
        row = {"field": field, "samples": item.count, "different_samples": item.diff_count, "max_abs_diff": item.max,
               "mean_abs_diff": mean, "p95_abs_diff": p95, "p95_method": f"deterministic_reservoir_{RESERVOIR_SIZE}",
               "first_difference": item.first, "policy_declared": declared, "policy_valid": policy_valid,
               "policy": limits, "policy_exceeded": exceeds,
               "best_lag": best, "lags": lags}
        results.append(row)
        if item.diff_count and not declared:
            blockers.append({"field": field, "reason": "undeclared_difference"})
        elif item.diff_count and not policy_valid:
            blockers.append({"field": field, "reason": "invalid_field_policy"})
        elif policy_valid:
            known_expected.append(row)
            if exceeds:
                blockers.append({"field": field, "reason": "declared_tolerance_exceeded"})

    if only_left["count"] or only_right["count"]:
        blockers.append({"reason": "missing_tick_or_cell"})
    if issue_total(left_issues) or issue_total(right_issues):
        blockers.append({"reason": "empty_invalid_or_nonfinite_value"})
    country_evidence = None
    if "country_slot_arr" in fields:
        country_evidence = compare_country_evidence(left_meta, right_meta)
        if country_evidence["status"] != "pass":
            blockers.append({"reason": "country_client_evidence_mismatch"})
    modifier_mismatches = compare_modifier_evidence(left_meta, right_meta, policy)
    for item in modifier_mismatches:
        blockers.append({"reason": "modifier_client_evidence_mismatch", **item})
    effect_mismatches = compare_effect_evidence(left_meta, right_meta, policy)
    for item in effect_mismatches:
        blockers.append({"reason": "effect_client_evidence_mismatch", **item})
    status = "pass" if not blockers else "release_blocker"
    report = {"schema": "AuthorityStageCTileComparison", "schema_version": 1, "status": status,
              "left": str(args.left_csv), "right": str(args.right_csv), "policy": str(args.policy),
              "authority_modes": [left_meta.get("authority_mode"), right_meta.get("authority_mode")],
              "rows": {"left": left_rows, "right": right_rows, "aligned": aligned_rows},
              "missing": {"only_left": only_left, "only_right": only_right},
              "numeric_issues": {"left": left_issues, "right": right_issues},
              "field_results": results, "country_evidence": country_evidence,
              "modifier_evidence_mismatches": modifier_mismatches,
              "effect_evidence_mismatches": effect_mismatches,
              "known_expected_fields": [row["field"] for row in known_expected], "blockers": blockers}
    (args.output_dir / "comparison.json").write_text(json.dumps(report, indent=2, allow_nan=False), encoding="utf-8")
    with (args.output_dir / "comparison.csv").open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=("field", "samples", "different_samples", "max_abs_diff", "mean_abs_diff", "p95_abs_diff", "p95_method", "policy_declared", "policy_exceeded", "best_lag", "best_lag_mean_abs_diff", "first_tick", "first_cell"))
        writer.writeheader()
        for row in results:
            first, best = row["first_difference"] or {}, row["best_lag"] or {}
            writer.writerow({**{key: row[key] for key in writer.fieldnames if key in row}, "best_lag": best.get("lag"), "best_lag_mean_abs_diff": best.get("mean_abs_diff"), "first_tick": first.get("tick_idx"), "first_cell": first.get("cell_index")})
    lines = ["# Authority Stage C2 tile comparison", "", f"Status: **{status}**", "", f"Aligned rows: {aligned_rows}; only left: {only_left['count']}; only right: {only_right['count']}.", "", f"Numeric empty/invalid/nonfinite values: left={issue_total(left_issues)}, right={issue_total(right_issues)}.", "", f"Blockers: {len(blockers)}. Declared policy fields are listed separately in `comparison.json`.", "", "p95 uses a deterministic bounded reservoir; mean and max are exact."]
    (args.output_dir / "comparison.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    connection.close()
    if not args.keep_database:
        db_path.unlink(missing_ok=True)
    print(f"[stage-c/C2] status={status} output={args.output_dir}")
    return 0 if status == "pass" else 3


if __name__ == "__main__":
    raise SystemExit(main())

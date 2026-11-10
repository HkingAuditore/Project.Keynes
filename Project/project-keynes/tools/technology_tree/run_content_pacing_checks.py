#!/usr/bin/env python3
"""Run catalog-focused Godot checks with bounded failure handling and logs."""
import argparse
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CHECKS = [
    ("authoring", "res://tools/build_technology_network_authoring.gd", ["--check"]),
    ("design", "res://tests/technology/technology_network_design_test.gd", []),
    ("binding", "res://tests/technology/technology_content_binding_audit_test.gd", []),
    ("closure", "res://tests/technology/technology_unlock_closure_audit_test.gd", ["--effective"]),
    ("construction", "res://tests/technology/technology_unlock_closure_audit_test.gd", ["--effective", "--construction"]),
    ("industry", "res://tests/technology/technology_industry_chain_balance_test.gd", []),
    ("catalog", "res://tests/technology/technology_catalog_test.gd", []),
    ("research", "res://tests/technology/technology_research_runtime_test.gd", []),
    ("activation", "res://tests/technology/technology_modifier_activation_test.gd", []),
    ("applications", "res://tests/technology/technology_application_intersection_schema_test.gd", []),
    ("report", "res://tools/export_technology_tree.gd", ["--check"]),
]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--godot", required=True)
    p.add_argument("--log-dir", type=Path, required=True)
    p.add_argument("--only", nargs="*")
    p.add_argument("--timeout", type=int, default=90)
    args = p.parse_args()
    args.log_dir.mkdir(parents=True, exist_ok=True)
    failures = 0
    for name, script, user_args in DEFAULT_CHECKS:
        if args.only and name not in args.only:
            continue
        log = args.log_dir / f"{name}.log"
        command = [args.godot, "--headless", "--path", str(ROOT), "--script", script]
        if user_args:
            command += ["--", *user_args]
        start = time.monotonic()
        with log.open("wb") as out:
            proc = subprocess.Popen(command, stdout=out, stderr=subprocess.STDOUT,
                                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            while proc.poll() is None:
                time.sleep(.2)
                output = log.read_text(encoding="utf-8", errors="replace")
                if "SCRIPT ERROR:" in output or time.monotonic() - start > args.timeout:
                    proc.kill()
                    proc.wait()
                    break
        output = log.read_text(encoding="utf-8", errors="replace")
        passed = proc.returncode == 0 and "SCRIPT ERROR:" not in output and "PASS" in output
        print(f"{'PASS' if passed else 'FAIL'} {name} ({time.monotonic() - start:.1f}s) {log}", flush=True)
        if not passed:
            failures += 1
            print("\n".join(output.splitlines()[:12]), flush=True)
    return int(bool(failures))


if __name__ == "__main__":
    raise SystemExit(main())

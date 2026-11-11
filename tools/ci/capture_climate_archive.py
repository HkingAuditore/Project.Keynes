#!/usr/bin/env python3
"""Generate a reviewable climate checkpoint candidate; never change the CI fixture.

The candidate must pass the unchanged exact-byte/eight-domain replay checker
before the command succeeds. Installing it in the repository is a separate edit.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
from check_climate_archive import (climate_section, publication_section,
                                   compatibility_section, host_transport, military_index, FIXTURE, replay_environment)
from check_committed_replay import continuation_scan, coverage_errors
from check_golden_determinism import records
from run_regression_checks import ROOT, SHUTDOWN_LEAK


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    args.candidate.mkdir(parents=True, exist_ok=False)
    args.log_dir.mkdir(parents=True, exist_ok=False)
    saves = args.log_dir.resolve() / "saves"
    payloads = []
    for mode in ("checkpoint", "resume"):
        environment = replay_environment(args.log_dir, mode, saves)
        log = args.log_dir / (mode + ".log")
        command = [args.godot, "--headless", "--path", str(ROOT / "Project/project-keynes"),
                   "--script", "res://tests/runtime/committed_view_replay_test.gd"]
        with log.open("w") as stream:
            code = subprocess.run(command, env=environment, stdout=stream,
                                  stderr=subprocess.STDOUT).returncode
        lines = log.read_text(errors="replace").splitlines()
        errors = [line for line in lines if "SCRIPT ERROR:" in line or "[FAIL]" in line
                  or line.startswith("ERROR:") or SHUTDOWN_LEAK.search(line)]
        result = records(lines, "COMMITTED_REPLAY_RESULT=")
        if code or errors or len(result) != 1:
            raise RuntimeError(f"candidate {mode} failed: {code}, {errors}; log={log}")
        expected_days = range(1, 11) if mode == "checkpoint" else range(3, 11)
        if coverage_errors(result[0], expected_days):
            raise RuntimeError(f"candidate coverage failed: {log}")
        payloads.append(result[0])
    scan = continuation_scan(*payloads)
    (args.log_dir / "candidate-scan.json").write_text(json.dumps(scan, indent=2) + "\n")
    if len(scan["rows"]) != 8 or not all(
            all(value["equal"] for value in row["domains"].values()) and
            all(value["equal"] for value in row["other"].values()) for row in scan["rows"]):
        raise RuntimeError("candidate continuation diverged; retain logs and repair before capture")
    sections = saves / "manual_3-sections"
    pksr = (sections / "simulation_runtime.bin").read_bytes()
    ecp2 = (sections / "ecp2.bin").read_bytes()
    pkmi = (sections / "pkmi.bin").read_bytes()
    climate = climate_section(pksr)
    archive = saves / "manual_3.pksv"
    metadata = {
        "seed": 20260727, "clock_rng_seed": 150015, "committed_day": 2,
        "climate_version": 9, "archive_sha256": digest(archive.read_bytes()),
        "climate_sha256": digest(climate), "climate_bytes": len(climate),
        "climate_days_3_to_10": [row["domains"]["CLIMATE"]["actual"] for row in scan["rows"]],
        "note": "Current content; ECP2 60 / OSOA4 requires sampled rain edges and frozen rain thresholds. Candidate passed full eight-domain continuation before installation.",
        "validated_library_sha256": digest((ROOT / "Project/project-keynes/addons/dots_ext/bin/macos/libdots_ext.macos.template_debug.arm64.dylib").read_bytes()),
        "ecp2_schema": 60, "osoa_version": 4, "cpd2_payload_revision": 1,
        "pksr_version": 5, "environment_adapter_version": 3, "pkmi_version": 3,
        "military_forwarder_version": 1,
    }
    chunks = {"publication": publication_section(ecp2), "resources": publication_section(ecp2, 9),
              "compatibility": compatibility_section(pksr), "mobility": publication_section(ecp2, 10),
              "cadence": publication_section(ecp2, 11), "population": publication_section(ecp2, 12),
              "rain": publication_section(ecp2, 13), "transport": host_transport(pksr),
              "military_index": military_index(pkmi), "military_forwarder": pkmi[-28:]}
    for name, data in chunks.items():
        metadata[name + "_bytes"] = len(data)
        metadata[name + "_sha256"] = digest(data)
    legacy = (FIXTURE / "legacy_catalog.pkcm").read_bytes()
    metadata["legacy_catalog_bytes"] = len(legacy)
    metadata["legacy_catalog_sha256"] = digest(legacy)
    metadata["supersedes_archive_sha256"] = json.loads((FIXTURE / "manifest.json").read_text())["archive_sha256"]
    shutil.copyfile(FIXTURE / "legacy_catalog.pkcm", args.candidate / "legacy_catalog.pkcm")
    shutil.copyfile(archive, args.candidate / "day2.pksv")
    (args.candidate / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return subprocess.run([sys.executable, str(ROOT / "tools/ci/check_climate_archive.py"),
                           "--godot", args.godot, "--fixture", str(args.candidate.resolve()),
                           "--log-dir", str(args.log_dir / "validation")]).returncode


if __name__ == "__main__":
    raise SystemExit(main())

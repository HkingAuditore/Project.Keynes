#!/usr/bin/env python3
"""Run focused Godot regressions, retaining logs and checking script failures.

Godot can return zero despite SCRIPT ERROR, so process status alone is not a gate.
Use --import on a fresh checkout after building the native extension.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TESTS = (
    "tests/game/save_repository_test.gd",
    "tests/game/save_container_validation_test.gd",
    "tests/game/game_save_session_test.gd",
    "tests/game/runtime_module_registry_test.gd",
    "tests/game/world_session_test.gd",
    "tests/game/runtime_clock_binding_test.gd",
    "tests/game/state_module_boundary_test.gd",
    "tests/building/bootstrap_owner_allocation_test.gd",
    "tests/game/gameplay_start_runtime_test.gd",
    "tests/game/player_country_ui_smoke_test.gd",
    "tests/game/narrative_ai_credentials_test.gd",
    "tests/runtime/runtime_worker_stop_lifetime_test.gd",
    "tests/runtime/runtime_resource_lifetime_test.gd",
    "tests/runtime/runtime_loading_exit_test.gd",
    "tests/runtime/runtime_economy_worker_restart_test.gd",
    "tests/ideology/ideology_execution_contract_manifest_test.gd",
    "tests/runtime/ideology_day_continuation_test.gd",
    "tests/building/building_runtime_test.gd",
    "tests/economy/economy_test_bootstrap_test.gd",
    "tests/economy/goods_storage_schema_test.gd",
    "tests/economy/economy_cadence_runtime_test.gd",
    "tests/economy/economy_worker_restart_day_test.gd",
    "tests/runtime/runtime_economy_stage_ops_soak_parity_test.gd",
    "tests/runtime/runtime_economy_parity_test.gd",
    "tests/runtime/runtime_economy_pod_test.gd",
    "tests/runtime/runtime_economy_d7_gate_test.gd",
    "tests/runtime/runtime_economy_opcode_ack_test.gd",
    "tests/runtime/runtime_economy_stage_order_contract_test.gd",
    "tests/runtime/runtime_large_ecp2_save_test.gd",
    "tests/runtime/runtime_economy_authority_soak_test.gd",
    "tests/runtime/runtime_authority_m5_m6_gate_test.gd",
)
# Leaks may only produce a WARNING and a zero exit code. They still fail the
# gate, including ObjectDB-only leaks without a Resource or RID error.
SHUTDOWN_LEAK = re.compile(
    r"ObjectDB instances leaked at exit|resources still in use at exit|"
    r"RID allocations of type .+ were leaked at exit|Leaked instance:"
)


def run_check(godot: str, name: str, arguments: list[str], logs: Path,
              extra_env: dict[str, str] | None = None) -> bool:
    environment = os.environ.copy()
    environment.pop("PK_GAME_SAVE_ROUNDTRIP_TEST", None)
    environment.update(extra_env or {})
    path = logs / f"{name}.log"
    command = [godot, "--headless", "--path", str(ROOT / "Project/project-keynes"), *arguments]
    print(f"Running {name}", flush=True)
    with path.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=ROOT, env=environment, stdout=output,
                                stderr=subprocess.STDOUT, check=False)
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    errors = [line for line in lines if (
        "SCRIPT ERROR:" in line or "[FAIL]" in line or
        line.startswith("ERROR:") or SHUTDOWN_LEAK.search(line)
    )]
    passed = result.returncode == 0 and not errors
    for line in lines:
        if "checks," in line or "save listing (" in line or "[save-roundtrip] PASS" in line:
            print(line)
    leaks = sum(bool(SHUTDOWN_LEAK.search(line)) for line in lines)
    print(f"{'PASS' if passed else 'FAIL'} {name}; exit={result.returncode}; "
          f"shutdown leak messages={leaks}; log={path}", flush=True)
    if not passed:
        print("\n".join(errors or lines[-40:]))
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--import", dest="import_project", action="store_true")
    parser.add_argument("--roundtrip", action="store_true")
    parser.add_argument("--log-dir", type=Path)
    parser.add_argument("tests", nargs="*")
    args = parser.parse_args()
    logs = args.log_dir or Path(tempfile.mkdtemp(prefix="keynes-regression-logs-"))
    logs.mkdir(parents=True, exist_ok=True)
    if args.import_project and not run_check(args.godot, "import", ["--editor", "--import"], logs):
        return 1
    passed = True
    for script in args.tests or TESTS:
        passed = run_check(args.godot, Path(script).stem, ["--script", f"res://{script}"], logs) and passed
    if args.roundtrip:
        with tempfile.TemporaryDirectory(prefix="keynes-regression-saves-") as saves:
            passed = run_check(args.godot, "game_save_roundtrip", [], logs,
                               {"PK_GAME_SAVE_ROUNDTRIP_TEST": "1", "PK_SAVE_DIR": saves}) and passed
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

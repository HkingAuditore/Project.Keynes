#!/usr/bin/env python3
"""Run focused Godot regressions, retaining logs and checking script failures.

Godot can return zero despite SCRIPT ERROR, so process status alone is not a gate.
Use --import on a fresh checkout after building the native extension.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from runtime_test_hygiene import trace_environment, untracked, unexpected_artifacts

ROOT = Path(__file__).resolve().parents[2]
TESTS = (
    "tests/ui/era_advancement_panel_test.gd",
    "tests/technology/era_advancement_service_test.gd",
    "tests/ideology/ideology_draw_flow_test.gd",
    "tests/game/player_controller_contract_test.gd",
    "tests/ui/inspector_live_patch_test.gd",
    "tests/building/building_visual_catalog_test.gd",
    "tests/world/vegetation_family_layer_test.gd",
    "tests/rendering/veg_variant_parity_probe.gd",
    "tests/ui/visual_tile_native_bake_test.gd",
    "tests/world/web_water_pass_node_test.gd",
    "tests/family/family_workspace_ui_test.gd",
    "tests/ui/ui_scene_structure_test.gd",
    "tests/game/save_repository_test.gd",
    "tests/game/save_container_validation_test.gd",
    "tests/game/game_save_session_test.gd",
    "tests/game/runtime_module_registry_test.gd",
    "tests/game/world_session_test.gd",
    "tests/game/world_runtime_host_values_test.gd",
    "tests/game/world_runtime_presentation_test.gd",
    "tests/game/world_runtime_preparation_test.gd",
    "tests/game/world_runtime_restore_preparation_test.gd",
    "tests/game/world_runtime_lifecycle_test.gd",
    "tests/game/web_daily_fallback_test.gd",
    "tests/game/world_runtime_commands_test.gd",
    "tests/game/world_runtime_modifier_writeback_test.gd",
    "tests/game/runtime_clock_binding_test.gd",
    "tests/game/state_module_boundary_test.gd",
    "tests/game/module_projection_boundaries_test.gd",
    "tests/game/world_state_contracts_test.gd",
    "tests/building/bootstrap_owner_allocation_test.gd",
    "tests/game/gameplay_start_runtime_test.gd",
    "tests/game/player_country_ui_smoke_test.gd",
    "tests/game/narrative_ai_credentials_test.gd",
    "tests/runtime/runtime_worker_stop_lifetime_test.gd",
    "tests/runtime/runtime_resource_lifetime_test.gd",
    "tests/runtime/runtime_loading_exit_test.gd",
    "tests/runtime/runtime_inline_save_restore_test.gd",
    "tests/runtime/runtime_executor_boundary_test.gd",
    "tests/runtime/native_world_handshake_test.gd",
    "tests/runtime/runtime_world_lifecycle_test.gd",
    "tests/runtime/runtime_world_rules_rebuild_test.gd",
    "tests/runtime/runtime_inline_coordinator_save_test.gd",
    "tests/runtime/startup_save_boundary_test.gd",
    "tests/runtime/economy_settlement_save_boundary_test.gd",
    "tests/game/player_clock_event_test.gd",
    "tests/runtime/runtime_economy_worker_restart_test.gd",
    "tests/ideology/ideology_execution_contract_manifest_test.gd",
    "tests/ideology/ideology_save_worker_authority_test.gd",
    "tests/ideology/ideology_save_transaction_states_test.gd",
    "tests/ideology/ideology_save_basis_and_midmaterialize_test.gd",
    "tests/runtime/ideology_day_continuation_test.gd",
    "tests/runtime/runtime_opinion_input_lifecycle_test.gd",
    "tests/ideology/ideology_social_media_worker_test.gd",
    "tests/building/building_runtime_test.gd",
    "tests/economy/economy_test_bootstrap_test.gd",
    "tests/economy/bootstrap_catalog_contract_test.gd",
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
    "tests/runtime/resource_exclusion_bounds_test.gd",
    "tests/runtime/golden_day_hash_test.gd",
    "tests/runtime/military_index_continuation_test.gd",
    "tests/runtime/runtime_events_pod_test.gd",
    "tests/runtime/fiscal_return_intent_test.gd",
    "tests/runtime/procurement_intent_test.gd",
    "tests/runtime/fiscal_cash_intent_test.gd",
    "tests/runtime/golden_external_advancers_test.gd",
    "tests/runtime/asset_transfer_intent_test.gd",
    "tests/runtime/research_intent_test.gd",
    "tests/runtime/treasury_spend_intent_test.gd",
    "tests/runtime/colonization_intent_test.gd",
    "tests/runtime/inflight_save_boundary_test.gd",
    "tests/runtime/environment_save_continuation_test.gd",
    "tests/runtime/runtime_event_restore_cursor_test.gd",
    "tests/country/country_runtime_test.gd",
    "tests/runtime/runtime_country_peer_bridge_test.gd",
    "tests/effect/modifier_runtime_test.gd",
)
# These write fixed user:// paths, so they share one serial lane.
SERIAL_TESTS = {
    "tests/game/save_repository_test.gd",
    "tests/game/save_container_validation_test.gd",
    "tests/game/narrative_ai_credentials_test.gd",
    "tests/ideology/ideology_execution_contract_manifest_test.gd",
    "tests/economy/economy_test_bootstrap_test.gd",
}
# Leaks may only produce a WARNING and a zero exit code. They still fail the
# gate, including ObjectDB-only leaks without a Resource or RID error.
# Per-test wall clock cap; override with PK_REGRESSION_TEST_TIMEOUT (seconds).
TEST_TIMEOUT_SECONDS = int(os.environ.get("PK_REGRESSION_TEST_TIMEOUT", "1200"))
# Wall-clock seconds per check, written to <log-dir>/timings.json at the end.
TIMINGS: dict[str, float] = {}
SHUTDOWN_LEAK = re.compile(
    r"ObjectDB instances leaked at exit|resources still in use at exit|"
    r"RID allocations of type .+ were leaked at exit|Leaked instance:"
)

# FMOD ships no macOS/Linux libraries; since upstream e395588e removed the addon
# .gdignore files, Godot logs these load errors on desktop runs. Audio falls
# back to the built-in backend, so they are not test failures.
FMOD_PLATFORM_MISSING = re.compile(
    r"^ERROR: (No GDExtension library found for current OS and architecture .*|"
    r"GDExtension dynamic library not found: |Error loading extension: )"
    r"'?res://addons/(0_fmod_bootstrap|FmodGodot)/"
)


def is_engine_error(line: str) -> bool:
    return line.startswith("ERROR:") and not FMOD_PLATFORM_MISSING.search(line)


# This negative fixture deliberately calls the public rejecting builder. The
# exact diagnostic must occur once; every other error and every leak still fails.
EXPECTED_ERRORS = {
    "ideology_effect_override_test": (
        "ERROR: [effect-catalog] effect_catalog_ideology_effect_parameter_max_stacks_invalid",
    ),
}


def fixture_errors(name: str, lines: list[str]) -> list[str]:
    expected = EXPECTED_ERRORS.get(name, ())
    errors = [line for line in lines if (
        "SCRIPT ERROR:" in line or "[FAIL]" in line or
        is_engine_error(line) or SHUTDOWN_LEAK.search(line)
    ) and line not in expected]
    for diagnostic in expected:
        count = lines.count(diagnostic)
        if count != 1:
            errors.append(f"expected exactly one diagnostic ({count} found): {diagnostic}")
    return errors


def run_check(godot: str, name: str, arguments: list[str], logs: Path,
              extra_env: dict[str, str] | None = None, check_artifacts: bool = True) -> bool:
    environment = os.environ.copy()
    environment.pop("PK_GAME_SAVE_ROUNDTRIP_TEST", None)
    environment.update(extra_env or {})
    environment = trace_environment(environment, logs, name)
    before_files = untracked(ROOT) if check_artifacts else set()
    path = logs / f"{name}.log"
    command = [godot, "--headless", "--path", str(ROOT / "Project/project-keynes"), *arguments]
    print(f"Running {name}", flush=True)
    timed_out = False
    started = time.monotonic()
    with path.open("w", encoding="utf-8") as output:
        try:
            result = subprocess.run(command, cwd=ROOT, env=environment, stdout=output,
                                    stderr=subprocess.STDOUT, check=False,
                                    timeout=TEST_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            # A script error inside _init never reaches quit(); fail instead of hanging the gate.
            timed_out = True
            result = subprocess.CompletedProcess(command, -9)
    elapsed = time.monotonic() - started
    TIMINGS[name] = round(elapsed, 1)
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    errors = fixture_errors(name, lines)
    if timed_out:
        errors.append(f"timed out after {TEST_TIMEOUT_SECONDS}s: {name}")
    artifacts = unexpected_artifacts(before_files, untracked(ROOT)) if check_artifacts else []
    errors.extend("unexpected test artifact: " + name for name in artifacts)
    passed = result.returncode == 0 and not errors
    for line in lines:
        if "checks," in line or "save listing (" in line or "[save-roundtrip] PASS" in line:
            print(line)
    leaks = sum(bool(SHUTDOWN_LEAK.search(line)) for line in lines)
    print(f"{'PASS' if passed else 'FAIL'} {name}; exit={result.returncode}; "
          f"shutdown leak messages={leaks}; {elapsed:.1f}s; log={path}", flush=True)
    if not passed:
        print("\n".join(errors or lines[-40:]))
    return passed


def timed_run(name: str, command: list[str]) -> subprocess.CompletedProcess:
    started = time.monotonic()
    result = subprocess.run(command, check=False)
    TIMINGS[name] = round(time.monotonic() - started, 1)
    print(f"{'PASS' if result.returncode == 0 else 'FAIL'} {name}; {TIMINGS[name]:.1f}s", flush=True)
    return result


def report_timings(logs: Path, started: float) -> None:
    total = time.monotonic() - started
    (logs / "timings.json").write_text(json.dumps(
        {"total_seconds": round(total, 1), "checks": TIMINGS}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    print(f"regression wall time {total / 60:.1f} min; slowest:")
    for name, seconds in sorted(TIMINGS.items(), key=lambda item: -item[1])[:10]:
        print(f"  {seconds:7.1f}s  {name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument("--import", dest="import_project", action="store_true")
    parser.add_argument("--roundtrip", action="store_true")
    parser.add_argument("--military-fiscal-probe", type=Path,
                        help="Run native military conservation test with a separately built test extension")
    parser.add_argument("--log-dir", type=Path)
    parser.add_argument("--full", action="store_true",
                        help="Also run the real 365-day year and the standard checkpoint replay")
    parser.add_argument("--jobs", type=int, default=4, help="Parallel Godot processes")
    parser.add_argument("tests", nargs="*")
    args = parser.parse_args()
    logs = args.log_dir or Path(tempfile.mkdtemp(prefix="keynes-regression-logs-"))
    logs = logs.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    for guard in ("check_size_ratchet.py", "check_cpp_deps.py", "check_cross_domain_inventory.py", "check_runtime_advancers.py", "check_runtime_switches.py", "check_committed_views.py", "check_save_contracts.py", "check_module_contracts.py", "check_resolve_apply.py", "check_module_api.py", "check_skill_mirrors.py", "check_module_map.py", "world_ext_bindings.py", "check_world_ext_bindings.py", "check_script_native_access.py", "test_architecture_guards.py", "test_regression_evidence.py"):
        result = subprocess.run([sys.executable, str(ROOT / "tools/ci" / guard)], check=False)
        if result.returncode:
            return result.returncode
    if args.import_project and not run_check(args.godot, "import", ["--editor", "--import"], logs):
        return 1
    started = time.monotonic()
    before_files = untracked(ROOT)

    def test(script: str) -> bool:
        return run_check(args.godot, Path(script).stem, ["--script", f"res://{script}"], logs,
                         check_artifacts=False)

    def tool(name: str, script: str, *arguments: str) -> bool:
        return timed_run(name, [sys.executable, str(ROOT / "tools/ci" / script), "--godot", args.godot,
                                *arguments, "--log-dir", str(logs / name)]).returncode == 0

    selected = list(args.tests or TESTS)
    serial = [script for script in selected if script in SERIAL_TESTS]
    # Longest first, so the pool does not end on one long straggler.
    tasks = [lambda: all([test(script) for script in serial])] if serial else []
    if not args.tests:
        tasks.append(lambda: tool("replay_matrix", "check_replay_matrix.py"))
        tasks.append(lambda: tool("annual_autosave", "check_committed_replay.py", "--checkpoint", "--trace",
                                  "--autosave", "--year-days", "16", "--save-day", "16", "--days", "24"))
        if args.full:
            tasks.append(lambda: tool("annual_365", "check_replay_matrix.py", "--annual"))
            tasks.append(lambda: tool("committed_checkpoint", "check_committed_replay.py",
                                      "--checkpoint", "--trace", "--days", "10"))
    tasks += [lambda script=script: test(script) for script in selected if script not in SERIAL_TESTS]
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        passed = all(list(pool.map(lambda task: task(), tasks)))
    artifacts = unexpected_artifacts(before_files, untracked(ROOT))
    if artifacts:
        print("\n".join("unexpected test artifact: " + name for name in artifacts))
        passed = False
    if args.military_fiscal_probe:
        passed = run_check(args.godot, "military_fiscal_semantics_test",
                           ["--script", "res://tests/runtime/military_fiscal_semantics_test.gd",
                            "--", f"--native-probe={args.military_fiscal_probe.resolve()}"], logs) and passed
    if args.roundtrip:
        with tempfile.TemporaryDirectory(prefix="keynes-regression-saves-") as saves:
            passed = run_check(args.godot, "game_save_roundtrip", [], logs,
                               {"PK_GAME_SAVE_ROUNDTRIP_TEST": "1", "PK_SAVE_DIR": saves}) and passed
    report_timings(logs, started)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

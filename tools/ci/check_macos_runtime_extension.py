#!/usr/bin/env python3
"""Load a specific macOS arm64 library in isolation and exercise save/restore.

The editor normally loads the debug library, so its regression results cannot
establish that a checked-in release library implements the same save protocol.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from run_regression_checks import SHUTDOWN_LEAK
from runtime_test_hygiene import trace_environment

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = (
    ("startup_boundary", "tests/runtime/startup_save_boundary_test.gd", "startup save boundary:"),
    ("settlement_boundary", "tests/runtime/economy_settlement_save_boundary_test.gd", "economy settlement save boundary:"),
    ("save_restore", "tests/runtime/runtime_inline_save_restore_test.gd", "inline save/restore:"),
    ("executor_boundaries", "tests/runtime/runtime_executor_boundary_test.gd", "executor boundaries:"),
    ("world_lifecycle", "tests/runtime/runtime_world_lifecycle_test.gd", "runtime world lifecycle:"),
    ("formal_inline_restart", "tests/runtime/runtime_inline_coordinator_save_test.gd", "inline coordinator save:"),
    ("world_rules", "tests/runtime/runtime_world_rules_rebuild_test.gd", "runtime world rules rebuild:"),
    ("opinion_inputs", "tests/runtime/runtime_opinion_input_lifecycle_test.gd", "runtime opinion input lifecycle:"),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() != "arm64":
        parser.error("this probe loads macOS arm64 libraries only")
    library = args.library.resolve(strict=True)
    logs = args.log_dir.resolve()
    logs.mkdir(parents=True, exist_ok=False)
    report = {"library": str(library), "sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
              "stages": [], "passed": False}
    with tempfile.TemporaryDirectory(prefix="keynes-extension-probe-") as directory:
        project = Path(directory)
        source = ROOT / "Project/project-keynes"
        # Reuse production resources without changing its extension mapping.
        # Tests are private copies, including the parent fixtures they extend.
        for entry in source.iterdir():
            if entry.name in {".godot", "project.godot", "tests"}:
                continue
            (project / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
        shutil.copytree(source / "tests", project / "tests")
        configuration = (source / "project.godot").read_text().replace(
            'config/name="ProjectKeynes"', 'config/name="Runtime extension probe"')
        (project / "project.godot").write_text(configuration)
        (project / "runtime.gdextension").write_text(
            '[configuration]\nentry_symbol="dots_ext_init"\ncompatibility_minimum="4.4"\n'
            '[libraries]\nmacos.debug.arm64=' + json.dumps(str(library)) + '\n')
        # Load through the runtime startup list. An editor import also asks
        # release libraries for editor documentation, which is not their job.
        (project / ".godot").mkdir()
        for name in ("global_script_class_cache.cfg", "uid_cache.bin"):
            if (source / ".godot" / name).is_file():
                shutil.copyfile(source / ".godot" / name, project / ".godot" / name)
        (project / ".godot/imported").symlink_to(source / ".godot/imported", target_is_directory=True)
        (project / ".godot/extension_list.cfg").write_text("res://runtime.gdextension\n")
        stages = []
        for name, fixture, result_prefix in FIXTURES:
            stages.append((name, ["--script", "res://" + fixture], result_prefix))
        for name, arguments, result_prefix in stages:
            command = [args.godot, "--headless", "--path", str(project), *arguments]
            path = logs / (name + ".log")
            environment = trace_environment(os.environ.copy(), logs, name)
            with path.open("w") as output:
                result = subprocess.run(command, cwd=ROOT, env=environment,
                                        stdout=output, stderr=subprocess.STDOUT, check=False)
            lines = path.read_text(errors="replace").splitlines()
            errors = [line for line in lines if line.startswith("ERROR:") or
                      "SCRIPT ERROR:" in line or "[FAIL]" in line or SHUTDOWN_LEAK.search(line)]
            if not any(
                    line.startswith(result_prefix) and line.endswith(", 0 failures")
                    for line in lines):
                errors.append(name + " fixture did not report success")
            passed = result.returncode == 0 and not errors
            report["stages"].append({"name": name, "exit": result.returncode,
                                      "passed": passed, "errors": errors, "log": str(path)})
            print(f"{'PASS' if passed else 'FAIL'} {name}; library={library}; log={path}", flush=True)
            for line in lines:
                if line.startswith(result_prefix):
                    print(line, flush=True)
            if not passed:
                print("\n".join(errors or lines[-30:]), flush=True)
                break
        report["passed"] = len(report["stages"]) == len(stages) and all(
            row["passed"] for row in report["stages"])
    (logs / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

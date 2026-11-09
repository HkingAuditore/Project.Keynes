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
FIXTURE = ROOT / "Project/project-keynes/tests/runtime/runtime_inline_save_restore_test.gd"


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
        (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Runtime extension probe"\n')
        (project / "runtime.gdextension").write_text(
            '[configuration]\nentry_symbol="dots_ext_init"\ncompatibility_minimum="4.4"\n'
            '[libraries]\nmacos.debug.arm64=' + json.dumps(str(library)) + '\n')
        # Load through the runtime startup list. An editor import also asks
        # release libraries for editor documentation, which is not their job.
        (project / ".godot").mkdir()
        (project / ".godot/extension_list.cfg").write_text("res://runtime.gdextension\n")
        shutil.copyfile(FIXTURE, project / FIXTURE.name)
        stages = [("save_restore", ["--script", "res://" + FIXTURE.name])]
        for name, arguments in stages:
            command = [args.godot, "--headless", "--path", str(project), *arguments]
            path = logs / (name + ".log")
            environment = trace_environment(os.environ.copy(), logs, name)
            with path.open("w") as output:
                result = subprocess.run(command, cwd=ROOT, env=environment,
                                        stdout=output, stderr=subprocess.STDOUT, check=False)
            lines = path.read_text(errors="replace").splitlines()
            errors = [line for line in lines if line.startswith("ERROR:") or
                      "SCRIPT ERROR:" in line or "[FAIL]" in line or SHUTDOWN_LEAK.search(line)]
            if name == "save_restore" and not any(
                    line.startswith("inline save/restore:") and line.endswith(", 0 failures")
                    for line in lines):
                errors.append("save/restore fixture did not report success")
            passed = result.returncode == 0 and not errors
            report["stages"].append({"name": name, "exit": result.returncode,
                                      "passed": passed, "errors": errors, "log": str(path)})
            print(f"{'PASS' if passed else 'FAIL'} {name}; library={library}; log={path}", flush=True)
            for line in lines:
                if line.startswith("inline save/restore:"):
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

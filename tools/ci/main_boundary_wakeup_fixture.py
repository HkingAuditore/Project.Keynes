#!/usr/bin/env python3
"""Compile the actual host completion body with a controlled wait interleaving."""
from __future__ import annotations

from pathlib import Path
import subprocess

def declaration(source: str, marker: str, semicolon: bool = False) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    if semicolon:
        assert source[end] == ";"
        end += 1
    return source[start:end]


def subject(source: str, implementation: str, negative: bool) -> str:
    methods = [
        declaration(source, "enum class MainBoundaryClient", True),
        declaration(source, "static constexpr uint32_t main_boundary_client_bit("),
        declaration(source, "void request_main_boundary_service("),
        declaration(implementation, "void NativeSimulationHost::complete_main_boundary_service(").replace(
            "NativeSimulationHost::", "", 1),
    ]
    if negative:
        guard = "std::lock_guard<std::mutex> control_lock(_control_mutex);"
        if methods[-1].count(guard) != 1:
            raise AssertionError("negative fixture requires exactly one completion guard")
        methods[-1] = methods[-1].replace(guard, "", 1)
    # Observe the lock acquisition, while preserving all production control
    # flow and atomic operations. The test wrapper owns only these three fields.
    body = "\n".join(methods).replace("std::mutex", "ProbeMutex")
    return ("struct MainBoundarySubject {\n" + body +
            "\nstd::atomic<uint32_t> _main_boundary_service_requested{0};\n"
            "ProbeMutex _control_mutex;\nProbeConditionVariable _control_cv;\n};\n")


def verify(compiler: str, root: Path, temporary: Path) -> None:
    """Reuse the architecture guard's compiler, directory and failure handling."""
    source = (root / "gdext/src/native_simulation_host.h").read_text()
    implementation = (root / "gdext/src/native_simulation_host.cpp").read_text()
    fixture = root / "gdext/tests/runtime_main_boundary_wakeup_test.cpp"
    for negative in (False, True):
        label = "unlocked-negative" if negative else "actual-production-body"
        (temporary / "runtime_main_boundary_test_subject.h").write_text(
            subject(source, implementation, negative))
        executable = temporary / label
        subprocess.run([compiler, "-std=c++17", "-pthread", "-I" + str(temporary),
                        str(fixture), "-o", str(executable)], check=True)
        # The existing suite watchdog catches deadlocks; no timing threshold
        # determines the protocol verdict, and the wait scenario has no timeout.
        result = subprocess.run([str(executable)], text=True, capture_output=True,
                                timeout=10, check=False)
        expected = 1 if negative else 0
        expected_output = ("FAIL: completion crossed the locked check-to-wait window"
                           if negative else "main boundary wakeup: PASS")
        output = result.stdout + result.stderr
        if result.returncode != expected or expected_output not in output:
            raise AssertionError(f"{label}: exit={result.returncode}\n{output}")
        print(f"PASS {label}: {output.strip()}")

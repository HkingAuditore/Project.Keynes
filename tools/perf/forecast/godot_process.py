"""Run Godot and reject engine errors even when it exits with status zero."""
import subprocess


def run_command(argv):
    result = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode or "SCRIPT ERROR:" in result.stdout or "ERROR:" in result.stdout:
        raise ValueError(result.stdout.strip() or f"{argv[0]} exited {result.returncode}")
    return result.stdout

"""Scenario-based workload analysis. JSON by default; use --dot for a graph."""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from hashlib import sha256
from pathlib import Path

from forecast import predict, read_json

ROOT = Path(__file__).resolve().parent


def default_lean():
    return os.getenv("PERF_FORECAST_LEAN") or "lean"


def keys(obj, required, optional=()):
    if not isinstance(obj, dict) or not set(required) <= obj.keys() or set(obj) - set(required) - set(optional):
        raise ValueError(f"expected fields {list(required)}, optional {list(optional)}")


def run(argv, *, cwd=None, payload=None, include_stderr=False):
    proc = subprocess.run(argv, cwd=cwd, text=True, input=payload, capture_output=True)
    if proc.returncode:
        raise ValueError(f"{argv[0]} exited {proc.returncode}: {proc.stderr.strip()} {proc.stdout.strip()}")
    return proc.stdout + (proc.stderr if include_stderr else "")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False, separators=(",", ":"))


def read_profile(path):
    profile = read_json(path)
    keys(profile, ("adapter", "metrics"), ("source", "options", "proof", "command", "assumptions"))
    notes = profile.get("assumptions", [])
    if not isinstance(notes, list) or not all(isinstance(s, str) for s in notes):
        raise ValueError("assumptions must be a list of descriptions")
    if not isinstance(profile["metrics"], dict) or not profile["metrics"] or not all(
            isinstance(v, str) and v.strip() for v in profile["metrics"].values()):
        raise ValueError("metrics must map stable names to definitions")
    if profile["adapter"] not in ("python", "gdscript", "command") or not isinstance(profile.get("options", {}), dict):
        raise ValueError("invalid adapter or options")
    if profile["adapter"] == "command":
        cmd = profile.get("command")
        if not isinstance(cmd, list) or not cmd or not all(isinstance(s, str) and s for s in cmd):
            raise ValueError("command adapter requires an argument array")
    elif "command" in profile:
        raise ValueError("command is only used by the command adapter")
    return profile


def validate_trace(raw, steps, metrics):
    keys(raw, ("steps", "locations"))
    if not isinstance(raw["locations"], dict) or set(raw["locations"]) != set(metrics):
        raise ValueError("adapter must locate every declared metric")
    for name, line in raw["locations"].items():
        if type(line) is not int or line < 1:
            raise ValueError(f"invalid source line for {name}")
    if not isinstance(raw["steps"], list) or len(raw["steps"]) != len(steps):
        raise ValueError("adapter step count differs from scenario")
    totals = dict.fromkeys(metrics, 0)
    for row in raw["steps"]:
        keys(row, ("counts", "path"), ("output",))
        if not isinstance(row["path"], list) or not isinstance(row["counts"], dict) or set(row["counts"]) != set(metrics):
            raise ValueError("adapter returned an incomplete path or metric set")
        for name, count in row["counts"].items():
            if type(count) is not int or count < 0:
                raise ValueError(f"invalid count for {name}")
            totals[name] += count
    return totals


def project_inputs(fields, steps):
    if not isinstance(fields, list):
        raise ValueError("proof inputs must be an ordered array")
    symbols = [{} for _ in fields]
    rows = [[] for _ in steps]
    for i, field in enumerate(fields):
        keys(field, ("key", "as"))
        if not isinstance(field["key"], str) or field["as"] not in ("int", "length", "optional_symbol"):
            raise ValueError(f"invalid proof input field: {field}")
        for row, step in zip(rows, steps):
            if not isinstance(step, dict):
                raise ValueError("proof inputs must refer to object fields")
            key = field["key"]
            if field["as"] == "optional_symbol":
                if key not in step:
                    row.append(0)
                    continue
                value = step[key]
                # Numeric equality is shared by JSON integer and floating representations.
                symbol = ("number", value) if type(value) in (int, float) else ("json", canonical(value))
                row.append(symbols[i].setdefault(symbol, len(symbols[i]) + 1))
            elif field["as"] == "length" and isinstance(step[key], (list, dict, str)):
                row.append(len(step[key]))
            elif field["as"] == "int" and type(step[key]) is int:
                row.append(step[key])
            else:
                raise ValueError(f"invalid projection {field}")
    return rows


def evaluate_proof(executable, profile, folder, steps, raw=None):
    proof = profile.get("proof")
    if proof is None:
        raise ValueError("this profile has no Lean model")
    keys(proof, ("files", "inputs", "metrics"))
    names = proof["metrics"]
    if not isinstance(names, list) or not names or len(names) != len(set(names)) or set(names) - set(profile["metrics"]):
        raise ValueError("proof metrics must be distinct declared metrics")
    if not isinstance(proof["files"], list) or not proof["files"]:
        raise ValueError("missing Lean sources")
    inputs = project_inputs(proof["inputs"], steps)
    model = "\n".join((folder / p).read_text(encoding="utf-8") for p in proof["files"])
    statement = f'#eval IO.println ("WORK_MODEL " ++ toString (expectedWork {inputs}))'
    if raw is not None:
        counts = [[row["counts"][k] for k in names] for row in raw["steps"]]
        statement += f"\ntheorem workTraceAgreement : expectedWork {inputs} = {counts} := by decide\n#print axioms workTraceAgreement"

    with tempfile.TemporaryDirectory(prefix="work-proof-") as tmp:
        path = Path(tmp) / "WorkCheck.lean"
        path.write_text(model + "\n" + statement + "\n#print axioms expectedWork\n", encoding="utf-8")
        out = run([executable, str(path)], cwd=folder, include_stderr=True)
        if re.search(r"\bsorryAx\b|declaration uses 'sorry'", out):
            raise ValueError("Lean reported an incomplete proof")
    matches = [json.loads(line.removeprefix("WORK_MODEL ")) for line in out.splitlines()
               if line.startswith("WORK_MODEL ")]
    if len(matches) != 1 or not isinstance(matches[0], list) or len(matches[0]) != len(steps):
        raise ValueError("Lean model must produce one count vector per input step")
    predictions = []
    for row in matches[0]:
        if not isinstance(row, list) or len(row) != len(names) or any(type(n) is not int or n < 0 for n in row):
            raise ValueError("Lean model returned an invalid count vector")
        predictions.append(dict(zip(names, row)))
    return {"metrics": names, "assumptions": profile.get("assumptions", []), "model_sha256": sha256(model.encode()).hexdigest(),
            "input_columns": proof["inputs"], "matched_trace": raw is not None,
            "predicted_steps": predictions, "totals": {k: sum(r[k] for r in predictions) for k in names}}


def trace(profile_path, request, source_override, lean, source_only=False):
    profile = read_profile(profile_path)
    folder = profile_path.resolve().parent
    if source_override is None and "source" not in profile:
        raise ValueError("pass --source or specify source in the profile")
    source = source_override.resolve() if source_override else (folder / profile["source"]).resolve()
    data = source.read_bytes()
    runners = {"python": "work_python.py", "gdscript": "work_godot.py"}
    cmd = [sys.executable, str(ROOT / runners[profile["adapter"]])] if profile["adapter"] in runners else [
        sys.executable if token == "{python}" else token for token in profile["command"]]
    payload = {"source": str(source), "steps": request["steps"], "options": profile.get("options", {})}
    if source_only:
        if profile["adapter"] != "python":
            raise ValueError("source-only counting currently supports Python profiles; other adapters can use estimate with a model")
        from work_static import analyze
        raw = analyze(payload)
    else:
        raw = json.loads(run(cmd, cwd=folder, payload=canonical(payload)))
    totals = validate_trace(raw, request["steps"], profile["metrics"])
    if data != source.read_bytes():
        raise ValueError("source changed during the run")
    proof = evaluate_proof(lean, profile, folder, request["steps"], raw) if lean else None
    return {"basis": "source evaluation" if source_only else "execution",
            "source": str(source), "source_sha256": sha256(data).hexdigest(),
            "scenario_sha256": sha256(canonical(request).encode()).hexdigest(),
            "metrics": profile["metrics"], "assumptions": profile.get("assumptions", []),
            "totals": totals, "proof": proof, **raw}


def compare(before, after):
    if before["scenario_sha256"] != after["scenario_sha256"] or before["metrics"] != after["metrics"]:
        raise ValueError("comparison requires identical scenarios and metric definitions")
    different, missing = [], []
    for index, (a, b) in enumerate(zip(before["steps"], after["steps"])):
        if "output" not in a or "output" not in b:
            missing.append(index)
        elif canonical(a["output"]) != canonical(b["output"]):
            different.append(index)
    delta = {k: after["totals"][k] - value for k, value in before["totals"].items()}
    signs = {int(d > 0) - int(d < 0) for d in delta.values()} - {0}
    verdict = ("mixed" if len(signs) == 2 else "decreased" if -1 in signs else
               "increased" if 1 in signs else "unchanged")
    return {"basis": before.get("basis"), "observed_work": verdict, "delta_after_minus_before": delta,
            "outputs": "differ" if different else "unavailable" if missing or not before["steps"] else "match",
            "mismatched_steps": different, "missing_outputs": missing, "before": before, "after": after}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    describe = commands.add_parser("describe", help="inspect the adapter, work definitions, scenario fields and assumptions")
    describe.add_argument("profile", type=Path)
    scan = commands.add_parser("scan", help="source structure and normal-flow graph")
    scan.add_argument("source", type=Path)
    scan.add_argument("--function", help="select a single function")
    scan.add_argument("--clang-arg", action="append", default=[], help="e.g. --clang-arg=-std=c++17")
    scan.add_argument("--dot", action="store_true", help="write a Graphviz graph")
    prediction = commands.add_parser("predict", help="evaluate a workload model without running the target")
    prediction.add_argument("request")
    estimate = commands.add_parser("estimate", help="run the profile's count model without executing the target")
    estimate.add_argument("profile", type=Path)
    estimate.add_argument("request")
    estimate.add_argument("--lean", default=default_lean(), metavar="EXECUTABLE")
    for name in ("trace", "compare"):
        sub = commands.add_parser(name, help="record a scenario path" if name == "trace" else "compare two versions on identical steps")
        sub.add_argument("profile", type=Path)
        if name == "compare":
            sub.add_argument("after_profile", type=Path)
            sub.add_argument("--after-source", type=Path)
        sub.add_argument("request", help="JSON file or - for stdin")
        sub.add_argument("--source", type=Path)
        sub.add_argument("--source-only", action="store_true", help="evaluate supported Python source without importing or running the target")
        sub.add_argument("--lean", nargs="?", const=default_lean(), metavar="EXECUTABLE")
        if name == "trace":
            sub.add_argument("--dot", action="store_true", help="graph of observed transitions")
            sub.add_argument("--step", type=int, help="zero-based step to show in the observed graph")
    args = parser.parse_args()
    try:
        if args.action == "describe":
            result = read_profile(args.profile)
        elif args.action == "scan":
            from work_scan import dot, scan_source
            result = scan_source(args.source, args.function, args.clang_arg)
            if args.dot:
                print(dot(result))
                return
        elif args.action == "predict":
            result = predict(read_json(args.request))
        else:
            request = read_json(args.request)
            keys(request, ("steps",))
            if not isinstance(request["steps"], list):
                raise ValueError("steps must be an array")
            if args.action == "estimate":
                result = evaluate_proof(args.lean, read_profile(args.profile), args.profile.resolve().parent,
                                        request["steps"])
            else:
                result = trace(args.profile, request, args.source, args.lean, args.source_only)
            if args.action == "compare":
                result = compare(result, trace(args.after_profile, request, args.after_source, args.lean, args.source_only))
        if args.action == "trace":
            if args.step is not None and not args.dot:
                raise ValueError("--step selects a graph step and requires --dot")
            if args.dot:
                from work_scan import observed_dot
                print(observed_dot(result, args.step))
                return
        print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
    except (ValueError, KeyError, TypeError, OSError, SyntaxError, ArithmeticError, RecursionError, IndexError) as exc:
        parser.exit(2, f"work: {exc}\n")


if __name__ == "__main__":
    main()

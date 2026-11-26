"""Run a concrete terrain scenario through the supplied Keynes cache source."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import tempfile

from forecast import read_json
from godot_process import run_command

ROOT = Path(__file__).resolve().parent
# These observations identify executed work, independently of the Lean model.
HOOKS = {
    "_key = key": "key_changed",
    "_copy_inputs = true": "invalidate_inputs",
    "writer.set_shader_parameter(entry.name, value)": "copy_one_uniform",
    "_views[i].render_target_update_mode = SubViewport.UPDATE_ONCE": "request_texture_update",
    "builds += 1": "build_completed",
}


def instrument(source):
    result = []
    locations = {}
    for line_no, line in enumerate(source.splitlines(), start=1):
        result.append(line)
        if line.strip() == "extends Node":
            result.append("var trace_events := []")
        if line.strip() == "if not _dirty:":
            if "clean_return_path" in locations:
                raise ValueError("ambiguous clean-cache observation")
            locations["clean_return_path"] = line_no
            indent = line[:len(line) - len(line.lstrip())]
            result.append(indent + '\ttrace_events.append("clean_return_path")')
        event = HOOKS.get(line.strip())
        if event:
            if event in locations:
                raise ValueError(f"ambiguous observation point: {event}")
            locations[event] = line_no
            indent = line[:len(line) - len(line.lstrip())]
            result.append(f'{indent}trace_events.append("{event}")')
    expected = {*HOOKS.values(), "clean_return_path"}
    if set(locations) != expected:
        raise ValueError(f"source observation points missing: {expected - set(locations)}")
    return "\n".join(result) + "\n", locations


def validate(request):
    if not isinstance(request, dict) or set(request) != {"frames"} or not isinstance(request["frames"], list):
        raise ValueError("expected an object containing a frames array")
    for frame in request["frames"]:
        if not isinstance(frame, dict) or set(frame) - {"revision", "tint"}:
            raise ValueError("allowed frame fields are revision and tint")
        rev = frame.get("revision")
        if type(rev) is not int or not 0 <= rev < 2**53:
            raise ValueError("revision must be a nonnegative exact JSON/Godot integer below 2^53")
        if "tint" in frame and (type(frame["tint"]) not in (int, float)
                                or not math.isfinite(frame["tint"]) or not 0 <= frame["tint"] <= 1):
            raise ValueError("tint must be a finite number between 0 and 1")


def run_scenario(args):
    request = read_json(args.request)
    validate(request)
    source = args.source.read_bytes()
    traced, locations = instrument(source.decode())
    with tempfile.TemporaryDirectory(prefix="cache-path-") as tmp:
        project = Path(tmp)
        (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Cache path"\n')
        (project / "cache.gd").write_text(traced)
        (project / "input.json").write_text(json.dumps(request, allow_nan=False))
        shutil.copyfile(ROOT / "scenario/driver.gd", project / "driver.gd")
        output = run_command([args.godot, "--headless", "--quit", "--path", tmp, "--script", "res://driver.gd"])
        traces = [json.loads(line.removeprefix("SCENARIO_RESULT ")) for line in output.splitlines()
                  if line.startswith("SCENARIO_RESULT ")]
        if len(traces) != 1 or len(traces[0]) != len(request["frames"]):
            raise ValueError("incomplete Godot trace")
        rows = []
        events = []
        previous_revision = None
        previous_tint = None
        for frame, observed in zip(request["frames"], traces[0]):
            tint = frame.get("tint", previous_tint)
            if frame["revision"] != previous_revision:
                event = "keyChange"
            elif tint != previous_tint:
                event = "invalidate"
            else:
                event = "hold"
            previous_revision, previous_tint = frame["revision"], tint
            events.append("." + event)
            rows.append({"input": frame, "model_event": event, **observed,
                         "texture_updates": observed["events"].count("request_texture_update")})
        if args.lean:
            observed_builds = [r["builds"] for r in rows]
            updates = [r["texture_updates"] for r in rows]
            sequence = "[" + ", ".join(events) + "]"
            certificate = (ROOT / "scenario/CacheProof.lean").read_text() + f"""
open CacheForecast
example : builds true {sequence} = {observed_builds} := by decide
example : (builds true {sequence}).map (fun n => 2*n) = {updates} := by decide
"""
            proof = project / "Check.lean"
            proof.write_text(certificate)
            run_command([args.lean, str(proof)])
        return {"source": str(args.source.resolve()), "sha256": hashlib.sha256(source).hexdigest(),
                "observation_lines": locations, "lean_checked": bool(args.lean), "frames": rows}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("request", help="JSON file or - for standard input")
    parser.add_argument("--source", required=True, type=Path, help="Keynes land_base_cache.gd")
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--lean", metavar="EXECUTABLE", help="also check the theorem and this trace")
    options = parser.parse_args()
    try:
        print(json.dumps(run_scenario(options), ensure_ascii=False, indent=2))
    except (OSError, ValueError, OverflowError) as exc:
        parser.exit(2, f"scenario_trace: {exc}\n")

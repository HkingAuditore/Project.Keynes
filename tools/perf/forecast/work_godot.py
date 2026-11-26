"""Trace named statements in standalone synchronous GDScript methods."""
import json
from pathlib import Path
import sys
import tempfile

from godot_process import run_command


DRIVER = '''extends SceneTree
const Subject = preload("res://subject.gd")
const Log = preload("res://log.gd")

func _initialize():
	var spec = JSON.parse_string(FileAccess.get_file_as_string("res://input.json"))
	var instance = Subject.new()
	var steps = []
	for args in spec.args:
		Log.hits = []
		var value = instance.callv(spec.method, args)
		if not json_value(value):
			push_error("entry output must consist of JSON values")
			quit(2)
			return
		steps.append({"output": value.duplicate(true) if value is Array or value is Dictionary else value, "path": Log.hits.duplicate()})
	if instance is Node:
		instance.free()
	print("WORK_GD ", JSON.stringify(steps, "", false, true))
	quit()

func json_value(v) -> bool:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(v)
		TYPE_ARRAY:
			return v.all(json_value)
		TYPE_DICTIONARY:
			for k in v:
				if typeof(k) != TYPE_STRING or not json_value(v[k]):
					return false
			return true
		_:
			return false
'''


def trace(payload):
    try:
        from gdtoolkit.parser import parser
    except ImportError as exc:
        raise ValueError("run uv run --with gdtoolkit==4.5.0 python work.py trace ...") from exc
    opts = payload["options"]
    if set(opts) - {"entry", "arguments", "observe", "godot"} or not {"entry", "arguments", "observe"} <= set(opts):
        raise ValueError("gdscript options require entry, arguments and observe")
    args = opts["arguments"]
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args) or len(set(args)) != len(args):
        raise ValueError("arguments must be an ordered list of distinct field names")
    source = Path(payload["source"]).read_text(encoding="utf-8")
    lines = source.splitlines()
    tree = parser.parse(source, gather_metadata=True)
    locations = {}
    for name, probe in opts["observe"].items():
        if set(probe) != {"function", "statement"}:
            raise ValueError("a GDScript probe needs a function and an exact statement")
        funcs = [n for n in tree.find_data("func_def") if str(n.children[0].children[0]) == probe["function"]]
        if len(funcs) != 1:
            raise ValueError(f"missing or ambiguous function for {name}")
        positions = {n.meta.line for n in funcs[0].iter_subtrees_topdown()
                     if n.data.endswith("_stmt") and lines[n.meta.line-1].strip() == probe["statement"]
                     and len(lines[n.meta.line-1]) - len(lines[n.meta.line-1].lstrip()) == n.meta.column - 1}
        if len(positions) != 1:
            raise ValueError(f"missing or ambiguous statement for {name}")
        locations[name], = positions
    marked = set(locations.values())
    output = []
    for no, line in enumerate(lines, 1):
        if no in marked:
            indent = line[:len(line)-len(line.lstrip())]
            output.append(f'{indent}preload("res://log.gd").hits.append({no})')
        output.append(line)
    def ensure_exact_json(v):
        if type(v) is int and abs(v) > 2**53:
            raise ValueError("Godot JSON input cannot represent this integer exactly")
        if isinstance(v, (list, dict)):
            for part in (v.values() if isinstance(v, dict) else v):
                ensure_exact_json(part)
    ensure_exact_json(payload["steps"])
    calls = []
    for step in payload["steps"]:
        if not isinstance(step, dict) or set(step) != set(args):
            raise ValueError("step must contain the configured arguments")
        calls.append([step[k] for k in args])
    with tempfile.TemporaryDirectory(prefix="work-gd-") as tmp:
        folder = Path(tmp)
        (folder/"project.godot").write_text("config_version=5\n")
        (folder/"subject.gd").write_text("\n".join(output)+"\n")
        (folder/"log.gd").write_text("extends RefCounted\nstatic var hits := []\n")
        (folder/"driver.gd").write_text(DRIVER)
        (folder/"input.json").write_text(json.dumps({"method": opts["entry"], "args": calls}, allow_nan=False))
        log = run_command([opts.get("godot", "godot"), "--headless", "--quit", "--path", tmp,
                           "--script", "res://driver.gd"])
    results = [json.loads(s.removeprefix("WORK_GD ")) for s in log.splitlines() if s.startswith("WORK_GD ")]
    if len(results) != 1:
        raise ValueError("Godot returned no unique trace")
    for row in results[0]:
        row["counts"] = {name: row["path"].count(no) for name, no in locations.items()}
    return {"steps": results[0], "locations": locations}


if __name__ == "__main__":
    try:
        print(json.dumps(trace(json.load(sys.stdin)), allow_nan=False))
    except Exception as exc:
        sys.exit(f"gdscript adapter: {exc}")

"""Python source inventory and single-threaded scenario recorder."""
import contextlib
import json
import runpy
import sys
from pathlib import Path


def trace(request):
    path = Path(request["source"]).resolve()
    opts = request["options"]
    if set(opts) != {"entry", "observe"} or not isinstance(opts["observe"], dict):
        raise ValueError("python options require entry and observe")
    source = path.read_text(encoding="utf-8")
    lines = source.splitlines()
    compiled = compile(source, str(path), "exec")
    codes = []
    def collect(code):
        for const in code.co_consts:
            if isinstance(const, type(code)):
                codes.append(const)
                collect(const)
    collect(compiled)
    hits = {}
    locations = {}
    for name, spec in opts["observe"].items():
        if not isinstance(spec, dict) or set(spec) not in ({"function"}, {"function", "statement"}):
            raise ValueError(f"invalid python observation {name}")
        matches = [c for c in codes if c.co_qualname == spec["function"]]
        if len(matches) != 1:
            raise ValueError(f"missing or ambiguous function {spec['function']}")
        code = matches[0]
        line = code.co_firstlineno
        event = "call"
        if "statement" in spec:
            candidates = {n for _, _, n in code.co_lines() if n and lines[n-1].strip() == spec["statement"]}
            if len(candidates) != 1:
                raise ValueError(f"missing or ambiguous line for {name}")
            line, = candidates
            event = "line"
        hits.setdefault((code.co_qualname, event, line if event == "line" else None), []).append(name)
        locations[name] = line
    def check_json(value):
        if isinstance(value, list):
            for part in value:
                check_json(part)
        elif isinstance(value, dict):
            if not all(isinstance(k, str) for k in value):
                raise ValueError("output JSON object keys must be strings")
            for part in value.values():
                check_json(part)
        elif value is not None and type(value) not in (str, bool, int, float):
            raise ValueError(f"unsupported output type: {type(value).__name__}")
    records = []
    filename = str(path)

    def observe(frame, event, arg):
        if frame.f_code.co_filename != filename:
            return None
        if event in ("call", "line", "return", "exception"):
            name = frame.f_code.co_qualname
            line = frame.f_lineno
            chain.append([name, line, event])
            for key in hits.get((name, event, line if event == "line" else None), []):
                counts[key] += 1
        return observe

    sys.path.insert(0, str(path.parent))
    # Keep application prints separate from the JSON protocol.
    with contextlib.redirect_stdout(sys.stderr):
        scope = runpy.run_path(filename)
        entry = scope[opts["entry"]]
        for step in request["steps"]:
            if not isinstance(step, dict):
                raise ValueError("python steps must be keyword argument objects")
            counts = dict.fromkeys(locations, 0)
            chain = []
            sys.settrace(observe)
            try:
                output = entry(**step)
            finally:
                sys.settrace(None)
            # Freeze mutable results before running another step.
            check_json(output)
            output = json.loads(json.dumps(output, allow_nan=False))
            records.append({"counts": counts, "path": chain, "output": output})
    return {"locations": locations, "steps": records}


if __name__ == "__main__":
    try:
        print(json.dumps(trace(json.load(sys.stdin)), allow_nan=False))
    except Exception as exc:
        sys.exit(f"python adapter: {exc}")

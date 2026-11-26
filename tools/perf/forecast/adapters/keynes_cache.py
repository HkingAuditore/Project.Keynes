"""Expose the existing Keynes Godot driver using the shared trace protocol."""
import argparse
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scenario_trace import run_scenario


def trace(payload):
    with tempfile.TemporaryDirectory() as temp:
        request = Path(temp) / "request.json"
        request.write_text(json.dumps({"frames": payload["steps"]}))
        result = run_scenario(argparse.Namespace(request=request, source=Path(payload["source"]),
                              godot=payload["options"].get("godot", "godot"), lean=None))
    locations = result["observation_lines"]
    rows = [{"path": f["events"], "counts": {k: f["events"].count(k) for k in locations}}
            for f in result["frames"]]
    return {"steps": rows, "locations": locations}


if __name__ == "__main__":
    try:
        print(json.dumps(trace(json.load(sys.stdin))))
    except (ValueError, OSError) as exc:
        sys.exit(str(exc))

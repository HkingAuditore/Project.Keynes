"""Summarize a coast-pan-v1 capture and compare it with a saved device baseline."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct

HERE = Path(__file__).resolve().parent
PROTOCOL = "coast-pan-v1"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def stats(values):
    ordered = sorted(values)
    require(ordered and all(math.isfinite(x) and x > 0 for x in ordered), "invalid timing samples")
    return {"samples": len(ordered), "p95_ms": ordered[math.ceil(.95 * len(ordered)) - 1],
            "above_25_ms": sum(v > 25 for v in ordered)}


def load_capture(folder):
    raw = [(folder / f"coast-{i}.json").read_bytes() for i in range(4)]
    records = [json.loads(data) for data in raw]
    outcome = (folder / "outcome.txt").read_text().strip()
    if outcome == "29 checks, 2 failures":
        # Historical run checked VSync against two desktop expectations. Only those exact
        # four original files may be replayed with the separately verified phone metadata.
        reference = json.loads((HERE / "iphone-16e.json").read_text())
        require([hashlib.sha256(data).hexdigest() for data in raw] == reference["arm_sha256"],
                "this failed run is not the archived iPhone capture")
        for r in records:
            r.update(protocol=PROTOCOL, platform="iOS", model="iPhone 16e", build="release",
                     screen_px=[2532, 1170], godot=reference["godot"])
    else:
        require(re.fullmatch(r"\d+ checks, 0 failures", outcome), "incomplete or failed benchmark")
    fields = ("platform", "model", "adapter", "driver", "build", "screen_px", "window_px",
              "refresh_hz", "vsync", "engine_max_fps", "explored_land_water_fractions")
    for i, r in enumerate(records):
        require(r["protocol"] == PROTOCOL and r["arm"] == i and r["ok"] is True
                and r["scene"] == "explored-coast" and r["omitted_layer"] == ("water" if i % 2 else "")
                and r["scale_percent"] == 100 and r["camera_zoom"] == 1.75 and r["day"] == 3
                and r["vsync"] == 1 and r["engine_max_fps"] == 0, f"invalid arm {i}")
        require(all(r[k] == records[0][k] for k in (*fields, "process_id", "godot")),
                f"mixed runs or changed settings in arm {i}")
        require(r["start_unix_s"] < r["end_unix_s"] and
                (i == 0 or records[i-1]["end_unix_s"] < r["start_unix_s"]), "invalid timing window")
        require(len(r["raw_frame_interval_ms"]) == len(r["camera_centers"]) == r["draw_calls"]["samples"] == 240,
                "expected 240 measured positions per arm")
        for j, (x, y) in enumerate(r["camera_centers"], 1):
            require(abs(x - (1059.36376953125 + 320*j/240)) < .01 and abs(y-924) < .01,
                    f"route mismatch at arm {i}, step {j}")
        require(r["camera_centers"] == records[0]["camera_centers"], "camera differed between arms")
        with (folder / f"coast-{i}.png").open("rb") as f:
            header = f.read(24)
        require(header[:8] == b"\x89PNG\r\n\x1a\n" and list(struct.unpack(">II", header[16:24])) == r["window_px"],
                "screenshot dimensions differ")
    return records, {k: records[0][k] for k in fields}


def compare(current, previous):
    require(previous["protocol"] == current["protocol"], "different scenario version")
    keys = set(current["conditions"]) | set(previous["conditions"])
    different = [k for k in sorted(keys) if current["conditions"].get(k) != previous["conditions"].get(k)]
    if different:
        return {"comparable": False, "different_conditions": different, "reference": previous["measurements"]}
    changes = {}
    for group, metrics in current["measurements"].items():
        for name, new in metrics.items():
            old = previous["measurements"][group].get(name)
            if old and old["samples"] == new["samples"]:
                changes[f"{group}/{name}"] = {
                    "baseline_ms": old["p95_ms"], "current_ms": new["p95_ms"],
                    "delta_p95_ms": round(new["p95_ms"] - old["p95_ms"], 6),
                    "delta_above_25_ms": new["above_25_ms"] - old["above_25_ms"]}
    return {"comparable": True, "changes": changes}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("folder", type=Path)
    p.add_argument("--device", required=True, help="stable device label, e.g. iphone-16e")
    p.add_argument("--baseline", type=Path, default=HERE/"iphone-16e.json")
    p.add_argument("--trace", type=Path, help="optional Apple Game Performance .trace")
    p.add_argument("--save", type=Path, help="write this run as a reusable baseline")
    args = p.parse_args()
    records, conditions = load_capture(args.folder)
    model = conditions.pop("model")
    conditions["device"] = args.device
    result = {"protocol": PROTOCOL, "conditions": conditions, "model": model, "godot": records[0]["godot"], "measurements": {}}
    for i, name in enumerate(("full", "without_water")):
        result["measurements"][name] = {"draw_callback_ms": stats([
            value for r in records[i::2] for value in r["raw_frame_interval_ms"]])}
    if args.trace:
        from apple_trace import matched_timings
        for name, samples in matched_timings(args.trace, records).items():
            result["measurements"][name].update({k: stats(v) for k, v in samples.items()})
    comparison = compare(result, json.loads(args.baseline.read_text()))
    if args.save:
        with args.save.open("x") as f:
            json.dump(result, f, indent=2)
            f.write("\n")
    print(json.dumps({**result, "comparison": comparison}, indent=2))


if __name__ == "__main__":
    main()

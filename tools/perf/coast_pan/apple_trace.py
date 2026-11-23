"""Apple Game Performance export for the reference route suffix (arms 2/3, steps 130–239)."""
from collections import defaultdict
from datetime import datetime
from itertools import pairwise
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
from xml.etree import ElementTree as ET


def rows(trace, table, folder):
    out = folder / (table + ".xml")
    subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                    f"/trace-toc/run[@number='1']/data/table[@schema='{table}']",
                    "--output", out], stdout=subprocess.DEVNULL, check=True)
    root = ET.parse(out)
    ids = {elem.get("id"): elem for elem in root.iter() if elem.get("id")}
    for row in root.findall(".//row"):
        yield [ids[e.get("ref")] if e.get("ref") else e for e in row]


def active_ms(intervals):
    total = 0
    end = 0
    for start, stop in sorted(intervals):
        total += max(0, stop - max(start, end))
        end = max(end, stop)
    return total / 1e6


def matched_timings(trace, records):
    toc = ET.fromstring(subprocess.check_output(["xcrun", "xctrace", "export", "--input", trace, "--toc"]))
    run = toc.find("./run")
    zero = datetime.fromisoformat(run.findtext("./info/summary/start-date")).timestamp()
    pid = records[0]["process_id"]

    def target(element):
        return element.get("fmt", "").endswith(f" ({pid})")

    with TemporaryDirectory() as tmp:
        folder = Path(tmp)
        requests = [(int(r[0].text), int(r[1].text), int(r[2].text))
                    for r in rows(trace, "ca-client-present-request", folder)
                    if target(r[6]) and r[1].text and r[2].text]
        surfaces = {s for _, _, s in requests}
        swaps = sorted({int(r[0].text) for r in rows(trace, "display-surface-swap", folder)
                        if r[2].text == "Built-In Display" and any(
                            len(r) > i and r[i].text and int(r[i].text) in surfaces for i in (3, 12, 13))})
        assignments = {int(r[1].text): int(r[4].text)
                       for r in rows(trace, "metal-command-buffer-frame-assignment", folder)
                       if target(r[14]) and r[1].text and r[4].text}
        activity = defaultdict(list)
        for r in rows(trace, "metal-gpu-intervals", folder):
            if target(r[10]) and r[7].text == "Active" and r[3].text:
                t = int(r[0].text)
                activity[int(r[3].text)].append((t, t + int(r[1].text)))

    result = {}
    for record, group in zip(records[2:], ("full", "without_water"), strict=True):
        start = (record["start_unix_s"] - zero)*1e9 + sum(record["raw_frame_interval_ms"][:130])*1e6
        stop = (record["end_unix_s"] - zero)*1e9
        ids = [assignments.get(b) for t, b, _ in requests if start <= t < stop]
        displayed = [t for t in swaps if start <= t < stop]
        if len(ids) != 110 or len(set(ids)) != 110 or not all(f in activity for f in ids):
            raise ValueError(f"{group}: incomplete GPU coverage for steps 130–239")
        if len(displayed) != 110:
            raise ValueError(f"{group}: {len(displayed)} display swaps; cannot reproduce the 109-interval baseline")
        result[group] = {"gpu_work_ms": [active_ms(activity[f]) for f in ids],
                         "display_intervals_ms": [(b-a)/1e6 for a, b in pairwise(displayed)]}
    return result

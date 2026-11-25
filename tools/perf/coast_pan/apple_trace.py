"""Attribute Apple Game Performance system samples to a passing coast capture."""
from bisect import bisect_left
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


def pair_swaps(requests, captured_buffers, swaps_by_surface, gpu_ends):
    """Attribute each selected request to its surface swap before that surface is reused."""
    next_request = {}
    deadlines = {}
    for time, buffer, surface in reversed(requests):
        deadlines[buffer] = next_request.get(surface)
        next_request[surface] = time

    displayed = []
    for time, buffer, surface in requests:
        if buffer not in captured_buffers:
            continue
        swaps = swaps_by_surface.get(surface, ())
        first = bisect_left(swaps, max(time, gpu_ends[buffer]))
        deadline = deadlines[buffer]
        last = len(swaps) if deadline is None else bisect_left(swaps, deadline)
        if last <= first:
            # A submitted frame may never reach the screen. Retain that gap in
            # coverage and measure intervals between the swaps we can attribute.
            continue
        if last - first != 1:
            raise ValueError(f"buffer {buffer}: ambiguous display swaps ({last-first} candidates)")
        swap = swaps[first]
        if displayed and swap <= displayed[-1]:
            raise ValueError(f"buffer {buffer}: duplicate or out-of-order display swap")
        displayed.append(swap)
    return displayed


def matched_timings(trace, records):
    toc = ET.fromstring(subprocess.check_output(["xcrun", "xctrace", "export", "--input", trace, "--toc"]))
    run = toc.find("./run")
    zero = datetime.fromisoformat(run.findtext("./info/summary/start-date")).timestamp()
    pid = records[0]["process_id"]

    def target(element):
        return element.get("fmt", "").endswith(f" ({pid})")

    with TemporaryDirectory() as tmp:
        folder = Path(tmp)
        requests = sorted((int(r[0].text), int(r[1].text), int(r[2].text))
                          for r in rows(trace, "ca-client-present-request", folder)
                          if target(r[6]) and r[1].text and r[2].text)
        surfaces = {surface for _, _, surface in requests}
        swaps_by_surface = defaultdict(set)
        for r in rows(trace, "display-surface-swap", folder):
            if r[2].text == "Built-In Display":
                frame_surfaces = {int(r[i].text) for i in (3, 12, 13) if len(r) > i and r[i].text}
                for surface in surfaces & frame_surfaces:
                    swaps_by_surface[surface].add(int(r[0].text))
        swaps_by_surface = {surface: sorted(times) for surface, times in swaps_by_surface.items()}
        assignments = {int(r[1].text): int(r[4].text)
                       for r in rows(trace, "metal-command-buffer-frame-assignment", folder)
                       if target(r[14]) and r[1].text and r[4].text}
        activity = defaultdict(list)
        for r in rows(trace, "metal-gpu-intervals", folder):
            if target(r[10]) and r[7].text == "Active" and r[3].text:
                t = int(r[0].text)
                activity[int(r[3].text)].append((t, t + int(r[1].text)))

    result = {group: {"gpu_work_ms": [], "display_intervals_ms": []}
              for group in ("full", "without_water")}
    coverage = []
    for record in records:
        arm = record["arm"]
        group = "without_water" if arm % 2 else "full"
        start = (record["start_unix_s"] - zero)*1e9
        stop = (record["end_unix_s"] - zero)*1e9
        buffers = [b for t, b, _ in requests if start <= t < stop]
        ids = [assignments.get(b) for b in buffers]
        expected = len(record["raw_frame_interval_ms"])
        # Requests and the draw callback mark different points in the frame.
        # An edge request can belong to the adjacent frame, but the trace must
        # otherwise cover the full measured interval.
        if abs(len(ids) - expected) > 1 or len(set(ids)) != len(ids) or not all(f in activity for f in ids):
            raise ValueError(f"arm {arm}: incomplete GPU coverage ({len(ids)} requests for {expected} draws)")
        gpu_ends = {b: max(end for _, end in activity[f]) for b, f in zip(buffers, ids, strict=True)}
        try:
            displayed = pair_swaps(requests, set(buffers), swaps_by_surface, gpu_ends)
        except ValueError as error:
            raise ValueError(f"arm {arm}: {error}") from error
        if len(displayed) < 2:
            raise ValueError(f"arm {arm}: fewer than two attributable display swaps")
        coverage.append({"arm": arm, "draws": expected, "requests": len(buffers), "matched_swaps": len(displayed),
                         "unpaired_requests": len(buffers) - len(displayed)})
        result[group]["gpu_work_ms"].extend(active_ms(activity[f]) for f in ids)
        result[group]["display_intervals_ms"].extend((b-a)/1e6 for a, b in pairwise(displayed))
    return result, coverage

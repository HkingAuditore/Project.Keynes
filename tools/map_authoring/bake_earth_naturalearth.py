"""Bake Natural Earth + ETOPO20 into a sandboxed generate(ctx) author script.

Preprocessor only (full Python). Output has no imports.
Sources (public domain / NOAA-derived):
  - Natural Earth 50m land, 110m rivers/lakes/geography
  - matplotlib basemap ETOPO20 (20-minute global relief)
"""

from __future__ import annotations

import gzip
import json
from collections import deque
from pathlib import Path

import numpy as np

HEX_DQ = (1, 1, 0, -1, -1, 0)
HEX_DR = (0, -1, -1, 0, 1, 1)

W = 100
H = 64
SEA = 0.50
ROOT = Path(__file__).resolve().parents[2]
GEO = ROOT / "tmp" / "map_geo"
OUT = ROOT / "tools" / "map_authoring" / "examples" / "earth_like.py"


def lonlat_of(col: int, row: int) -> tuple[float, float]:
    lon = (col + 0.5) / float(W) * 360.0 - 180.0
    lat = 90.0 - row / float(H - 1) * 180.0
    return lon, lat


def hex_neighbor_indices(index: int) -> list[int]:
    col = index % W
    row = index // W
    q = col - ((row - (row & 1)) // 2)
    out: list[int] = []
    for d in range(6):
        rr = row + HEX_DR[d]
        if rr < 0 or rr >= H:
            continue
        cc = (q + HEX_DQ[d] + ((rr - (rr & 1)) // 2)) % W
        out.append(rr * W + cc)
    return out


def world_ocean_mask(is_land: list[int]) -> list[int]:
    world = [0] * (W * H)
    queue: deque[int] = deque()
    for col in range(W):
        for row in (0, H - 1):
            i = row * W + col
            if is_land[i]:
                continue
            world[i] = 1
            queue.append(i)
    while queue:
        cur = queue.popleft()
        for ni in hex_neighbor_indices(cur):
            if world[ni] or is_land[ni]:
                continue
            world[ni] = 1
            queue.append(ni)
    return world


def enclosed_water_blobs(is_land: list[int], world: list[int]) -> list[list[int]]:
    seen = [0] * (W * H)
    blobs: list[list[int]] = []
    for i in range(W * H):
        if is_land[i] or world[i] or seen[i]:
            continue
        blob = [i]
        seen[i] = 1
        q: deque[int] = deque([i])
        while q:
            cur = q.popleft()
            for ni in hex_neighbor_indices(cur):
                if seen[ni] or is_land[ni] or world[ni]:
                    continue
                seen[ni] = 1
                blob.append(ni)
                q.append(ni)
        blobs.append(blob)
    return blobs


def blob_centroid(blob: list[int]) -> tuple[float, float]:
    lon_sum = 0.0
    lat_sum = 0.0
    for i in blob:
        lon, lat = lonlat_of(i % W, i // W)
        lon_sum += lon
        lat_sum += lat
    n = float(max(len(blob), 1))
    return lon_sum / n, lat_sum / n


def in_ocean_sea(lon: float, lat: float) -> bool:
    seas = (
        (-7.0, 36.5, 31.0, 41.2),
        (27.0, 42.0, 40.3, 47.4),
        (10.0, 30.5, 53.0, 66.2),
        (-96.0, -78.0, 51.5, 64.0),
        (32.2, 44.5, 12.0, 30.2),
        (47.5, 57.4, 23.4, 30.8),
        (-98.0, -80.2, 18.0, 30.8),
        (-71.0, -56.0, 45.0, 51.5),
        (31.5, 46.0, 63.2, 68.8),
        (98.5, 105.5, -2.5, 6.5),
        (128.2, 133.0, 32.6, 36.4),
        (129.5, 138.5, 36.0, 44.0),
    )
    for lon0, lon1, lat0, lat1 in seas:
        if lon0 <= lon <= lon1 and lat0 <= lat <= lat1:
            return True
    return False


def pip_ring(lon: float, lat: float, ring: list) -> bool:
    inside = False
    n = len(ring)
    if n < 3:
        return False
    j = n - 1
    for i in range(n):
        xi, yi = float(ring[i][0]), float(ring[i][1])
        xj, yj = float(ring[j][0]), float(ring[j][1])
        if (yi > lat) != (yj > lat):
            denom = yj - yi
            if abs(denom) < 1e-18:
                denom = 1e-18
            xint = (xj - xi) * (lat - yi) / denom + xi
            if lon < xint:
                inside = not inside
        j = i
    return inside


def geom_hits(lon: float, lat: float, geom: dict) -> bool:
    gtype = geom.get("type")
    coords = geom.get("coordinates") or []
    polys = []
    if gtype == "Polygon":
        polys = [coords]
    elif gtype == "MultiPolygon":
        polys = coords
    else:
        return False
    for poly in polys:
        if not poly:
            continue
        if pip_ring(lon, lat, poly[0]):
            hole = False
            for ring in poly[1:]:
                if pip_ring(lon, lat, ring):
                    hole = True
                    break
            if not hole:
                return True
        # antimeridian retry
        if lon < -140.0 and pip_ring(lon + 360.0, lat, poly[0]):
            return True
        if lon > 140.0 and pip_ring(lon - 360.0, lat, poly[0]):
            return True
    return False


def bbox_of_geom(geom: dict) -> tuple[float, float, float, float]:
    xs: list[float] = []
    ys: list[float] = []

    def walk(node) -> None:
        if not node:
            return
        if isinstance(node[0], (int, float)):
            xs.append(float(node[0]))
            ys.append(float(node[1]))
            return
        for child in node:
            walk(child)

    walk(geom.get("coordinates"))
    if not xs:
        return (0.0, 0.0, 0.0, 0.0)
    return (min(xs), min(ys), max(xs), max(ys))


def load_features(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    feats = []
    for feat in data.get("features") or []:
        geom = feat.get("geometry") or {}
        if not geom:
            continue
        feats.append(
            {
                "props": feat.get("properties") or {},
                "geom": geom,
                "bbox": bbox_of_geom(geom),
            }
        )
    return feats


def bbox_may_hit(lon: float, lat: float, bbox: tuple[float, float, float, float], pad: float = 1.5) -> bool:
    minx, miny, maxx, maxy = bbox
    if lat < miny - pad or lat > maxy + pad:
        return False
    if maxx - minx > 180.0:
        return True
    if minx - pad <= lon <= maxx + pad:
        return True
    if lon + 360.0 >= minx - pad and lon + 360.0 <= maxx + pad:
        return True
    if lon - 360.0 >= minx - pad and lon - 360.0 <= maxx + pad:
        return True
    return False


def raster_ne_land_mask(land_feats: list[dict], scale: int = 2) -> list[int]:
    fw = W * scale
    fh = (H - 1) * scale + 1
    cover = [0] * (fw * fh)
    for fr in range(fh):
        for fc in range(fw):
            lon = (fc + 0.5) / float(fw) * 360.0 - 180.0
            lat = 90.0 - fr / float(max(fh - 1, 1)) * 180.0
            for feat in land_feats:
                if not bbox_may_hit(lon, lat, feat["bbox"], pad=1.2):
                    continue
                if geom_hits(lon, lat, feat["geom"]):
                    cover[fr * fw + fc] = 1
                    break
    votes = [0] * (W * H)
    for fr in range(fh):
        for fc in range(fw):
            if not cover[fr * fw + fc]:
                continue
            col = min(W - 1, int(fc * W / fw))
            row = min(H - 1, int(round(fr * (H - 1) / float(max(fh - 1, 1)))))
            votes[row * W + col] += 1
    need = (scale * scale + 1) // 2 + 1
    return [1 if v >= need else 0 for v in votes]


def col_row_of_lonlat(lon: float, lat: float) -> tuple[int, int]:
    col = int(round((lon + 180.0) / 360.0 * W)) % W
    row = int(round((90.0 - lat) / 180.0 * (H - 1)))
    row = max(0, min(H - 1, row))
    return col, row


def load_etopo() -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    z = np.loadtxt(gzip.open(GEO / "etopo20data.gz"))
    lats = np.loadtxt(gzip.open(GEO / "etopo20lats.gz"))
    lons = np.loadtxt(gzip.open(GEO / "etopo20lons.gz"))
    return z, lats, lons


def etopo_window(z: np.ndarray, lats: np.ndarray, lons: np.ndarray, lon: float, lat: float, half_w: float, half_h: float) -> np.ndarray:
    elon = lon if lon >= 20.0 else lon + 360.0
    lat_lo, lat_hi = lat - half_h, lat + half_h
    lon_lo, lon_hi = elon - half_w, elon + half_w
    r0 = int(np.searchsorted(lats, lat_lo))
    r1 = int(np.searchsorted(lats, lat_hi))
    r0 = max(0, r0 - 1)
    r1 = min(z.shape[0] - 1, max(r0 + 1, r1 + 1))
    samples = []
    for r in range(r0, r1 + 1):
        c0 = int(np.searchsorted(lons, lon_lo))
        c1 = int(np.searchsorted(lons, lon_hi))
        c0 = max(0, c0 - 1)
        c1 = min(z.shape[1] - 1, max(c0 + 1, c1 + 1))
        samples.append(z[r, c0 : c1 + 1].ravel())
        # wrap past 380 / below 20
        if lon_lo < 20.0:
            samples.append(z[r, np.searchsorted(lons, lon_lo + 360.0) :].ravel())
        if lon_hi > 380.0:
            samples.append(z[r, : np.searchsorted(lons, lon_hi - 360.0) + 1].ravel())
    if not samples:
        return np.array([0.0])
    return np.concatenate(samples)


def q100(v: float) -> int:
    if v < 0.0:
        v = 0.0
    if v > 1.0:
        v = 1.0
    return int(round(v * 100.0))


def line_to_cells(coords: list) -> list[list[int]]:
    cells: list[list[int]] = []
    for pt in coords:
        lon, lat = float(pt[0]), float(pt[1])
        col = int(round((lon + 180.0) / 360.0 * W)) % W
        row = int(round((90.0 - lat) / 180.0 * (H - 1)))
        row = max(0, min(H - 1, row))
        if not cells or cells[-1][0] != col or cells[-1][1] != row:
            cells.append([col, row])
    return cells


def cells_along(points: list[tuple[float, float]]) -> list[list[int]]:
    cells: list[list[int]] = []
    for pi in range(len(points) - 1):
        c0, r0 = col_row_of_lonlat(points[pi][0], points[pi][1])
        c1, r1 = col_row_of_lonlat(points[pi + 1][0], points[pi + 1][1])
        dc = c1 - c0
        if dc > W // 2:
            dc -= W
        if dc < -W // 2:
            dc += W
        steps = max(abs(dc), abs(r1 - r0), 1)
        for s in range(steps + 1):
            col = (c0 + int(round(dc * s / float(steps)))) % W
            row = r0 + int(round((r1 - r0) * s / float(steps)))
            row = max(0, min(H - 1, row))
            if not cells or cells[-1][0] != col or cells[-1][1] != row:
                cells.append([col, row])
    return cells


def lake_cells_from_geom(geom: dict) -> list[list[int]]:
    cells = []
    for row in range(H):
        for col in range(W):
            lon, lat = lonlat_of(col, row)
            if geom_hits(lon, lat, geom):
                cells.append([col, row])
    return cells


def fmt_rows(vals: list[int]) -> str:
    lines = []
    for row in range(H):
        chunk = vals[row * W : (row + 1) * W]
        lines.append("        [" + ",".join(str(v) for v in chunk) + "],")
    return "\n".join(lines)


def main() -> None:
    print("loading ETOPO20 + Natural Earth...")
    z, lats, lons = load_etopo()
    land_feats = load_features(GEO / "ne_50m_land.geojson")
    geo_path = GEO / "ne_50m_geography.geojson"
    if not geo_path.is_file():
        geo_path = GEO / "ne_110m_geography.geojson"
    geo_feats = load_features(geo_path)

    dcol = 360.0 / W
    drow = 180.0 / (H - 1)
    elev = [0.0] * (W * H)
    highland = [0] * (W * H)
    moisture = [0] * (W * H)
    etopo_frac = [0.0] * (W * H)
    is_land = [0] * (W * H)

    mtn = [f for f in geo_feats if f["props"].get("FEATURECLA") == "Range/mtn"]
    plateau = [f for f in geo_feats if f["props"].get("FEATURECLA") == "Plateau"]
    desert = [f for f in geo_feats if f["props"].get("FEATURECLA") == "Desert"]
    basin = [f for f in geo_feats if f["props"].get("FEATURECLA") == "Basin"]
    isthmus = [f for f in geo_feats if f["props"].get("FEATURECLA") == "Isthmus"]
    plains = [f for f in geo_feats if f["props"].get("FEATURECLA") == "Plain"]
    tundra = [f for f in geo_feats if f["props"].get("FEATURECLA") == "Tundra"]
    wetlands = [f for f in geo_feats if f["props"].get("FEATURECLA") in ("Wetlands", "Delta")]
    print("geo deserts", len(desert), "mountains", len(mtn), "plains", len(plains))

    print("raster NE land at 2x...")
    ne_cover = raster_ne_land_mask(land_feats, 2)

    print("sampling %d cells..." % (W * H))
    for row in range(H):
        for col in range(W):
            i = row * W + col
            lon, lat = lonlat_of(col, row)
            samples = etopo_window(z, lats, lons, lon, lat, dcol * 0.55, drow * 0.55)
            frac = float(np.mean(samples >= 0.0))
            p75 = float(np.percentile(samples, 70))
            z_land = float(np.mean(samples[samples >= 0.0])) if np.any(samples >= 0.0) else 0.0
            z_ocean = float(np.mean(samples[samples < 0.0])) if np.any(samples < 0.0) else -3000.0
            ne_hit = bool(ne_cover[i])
            force = False
            for feat in isthmus:
                if bbox_may_hit(lon, lat, feat["bbox"], pad=2.0) and geom_hits(lon, lat, feat["geom"]):
                    force = True
                    break
            if -86.0 <= lon <= -79.0 and 8.0 <= lat <= 12.5:
                force = True
            if 32.2 <= lon <= 33.4 and 30.0 <= lat <= 31.2:
                force = True
            etopo_frac[i] = frac
            land = ne_hit or force
            if (not land) and frac >= 0.38 and not in_ocean_sea(lon, lat):
                land = True
            if (not land) and not in_ocean_sea(lon, lat):
                if -81.0 <= lon <= -35.0 and -33.0 <= lat <= 10.0 and frac >= 0.18:
                    land = True
                elif 97.0 <= lon <= 109.5 and 8.0 <= lat <= 18.5 and frac >= 0.16:
                    land = True
                elif -125.0 <= lon <= -70.0 and 30.0 <= lat <= 60.0 and frac >= 0.28:
                    land = True
            if land:
                h = max(0.0, min(1.0, z_land / 4000.0))
                e = SEA + 0.14 + h * 0.34
                is_land[i] = 1
            else:
                d = max(0.0, min(1.0, (-z_ocean) / 5500.0))
                e = SEA - 0.10 - d * 0.26
                if e < 0.06:
                    e = 0.06
                if e > SEA - 0.08:
                    e = SEA - 0.08
            elev[i] = e
            hi = 0.0
            for feat in mtn + plateau:
                if bbox_may_hit(lon, lat, feat["bbox"]) and geom_hits(lon, lat, feat["geom"]):
                    name = str(feat["props"].get("NAME") or "")
                    if "TIBET" in name.upper() or feat["props"].get("FEATURECLA") == "Plateau":
                        hi = max(hi, 0.72)
                    else:
                        hi = max(hi, 0.90)
            if land:
                hi = max(hi, min(1.0, z_land / 3800.0 * 0.85), 0.32)
                if -125.0 <= lon <= -105.0 and 32.0 <= lat <= 55.0:
                    hi = max(hi, 0.80)
                    e = max(e, SEA + 0.28)
                if -80.0 <= lon <= -66.0 and -48.0 <= lat <= 10.0:
                    hi = max(hi, 0.84)
                    e = max(e, SEA + 0.30)
                if 72.0 <= lon <= 96.0 and 26.0 <= lat <= 36.0:
                    hi = max(hi, 0.90)
                    e = max(e, SEA + 0.32)
                elev[i] = e
            highland[i] = q100(hi)
            moist = 0.40
            if abs(lat) < 10.0:
                moist = 0.58
            elif abs(lat) < 23.0:
                moist = 0.34
            elif abs(lat) < 40.0:
                moist = 0.36
            elif abs(lat) < 55.0:
                moist = 0.48
            else:
                moist = 0.30
            for feat in desert:
                if bbox_may_hit(lon, lat, feat["bbox"]) and geom_hits(lon, lat, feat["geom"]):
                    moist = 0.08
                    break
            for feat in plains:
                if bbox_may_hit(lon, lat, feat["bbox"]) and geom_hits(lon, lat, feat["geom"]):
                    name = str(feat["props"].get("NAME") or "").upper()
                    if any(k in name for k in ("STEPPE", "SAHEL", "PAMPAS", "PLAINS", "TURAN", "CHACO", "NULLARBOR", "LLANOS")):
                        moist = min(moist, 0.19)
                    break
            for feat in tundra:
                if bbox_may_hit(lon, lat, feat["bbox"]) and geom_hits(lon, lat, feat["geom"]):
                    moist = min(moist, 0.22)
                    break
            for feat in plateau:
                if bbox_may_hit(lon, lat, feat["bbox"]) and geom_hits(lon, lat, feat["geom"]):
                    name = str(feat["props"].get("NAME") or "").upper()
                    if "TIBET" in name or "MONGOL" in name or "COLORADO" in name or "USTYURT" in name:
                        moist = min(moist, 0.16)
                    break
            for feat in basin:
                if bbox_may_hit(lon, lat, feat["bbox"]) and geom_hits(lon, lat, feat["geom"]):
                    name = str(feat["props"].get("NAME") or "").upper()
                    if "AMAZON" in name or "CONGO" in name:
                        moist = max(moist, 0.88)
                    elif "TARIM" in name or "GREAT BASIN" in name or "JUNGGAR" in name:
                        moist = min(moist, 0.10)
                    break
            for feat in wetlands:
                if bbox_may_hit(lon, lat, feat["bbox"]) and geom_hits(lon, lat, feat["geom"]):
                    moist = max(moist, 0.82)
                    break
            if land:
                if -17.0 <= lon <= 33.0 and 16.8 <= lat <= 32.5:
                    moist = min(moist, 0.07)
                if 35.0 <= lon <= 60.0 and 12.0 <= lat <= 32.0:
                    moist = min(moist, 0.07)
                if 44.0 <= lon <= 62.0 and 26.0 <= lat <= 37.0:
                    moist = min(moist, 0.09)
                if 68.0 <= lon <= 76.0 and 24.0 <= lat <= 30.5:
                    moist = min(moist, 0.08)
                if 73.0 <= lon <= 119.0 and 36.0 <= lat <= 48.5:
                    moist = min(moist, 0.08)
                if 114.0 <= lon <= 148.0 and -33.0 <= lat <= -18.0:
                    moist = min(moist, 0.08)
                if 12.0 <= lon <= 28.0 and -32.0 <= lat <= -18.0:
                    moist = min(moist, 0.08)
                if -75.5 <= lon <= -67.0 and -27.0 <= lat <= -18.0:
                    moist = min(moist, 0.07)
                if -72.0 <= lon <= -63.0 and -52.0 <= lat <= -40.0:
                    moist = min(moist, 0.18)
                if -118.0 <= lon <= -102.0 and 30.0 <= lat <= 38.0:
                    moist = min(moist, 0.10)
                if -112.0 <= lon <= -102.0 and 32.0 <= lat <= 42.0:
                    moist = min(moist, 0.18)
                if -125.0 <= lon <= -117.0 and 40.0 <= lat <= 50.0:
                    moist = max(moist, 0.74)
                if -124.0 <= lon <= -120.0 and 32.0 <= lat <= 42.0:
                    moist = max(moist, 0.52)
                if 40.0 <= lon <= 51.0 and 4.0 <= lat <= 12.0:
                    moist = min(moist, 0.09)
                if -16.0 <= lon <= 38.0 and 12.0 <= lat <= 16.5:
                    moist = min(moist, 0.19)
                if -110.0 <= lon <= -97.0 and 32.0 <= lat <= 42.0:
                    moist = min(moist, 0.22)
                if 50.0 <= lon <= 85.0 and 44.0 <= lat <= 55.0:
                    moist = min(moist, 0.19)
                if -80.0 <= lon <= -50.0 and -10.0 <= lat <= 5.0:
                    moist = max(moist, 0.86)
                if 10.0 <= lon <= 30.0 and -4.0 <= lat <= 5.0:
                    moist = max(moist, 0.86)
            if lon > 95.0 and lon < 155.0 and lat > -8.0 and lat < 18.0 and land:
                moist = max(moist, 0.80)
            if not land:
                moist = 0.90
            moisture[i] = q100(moist)

    grow = []
    for _round in range(1):
        grow = []
        for row in range(1, H - 1):
            for col in range(W):
                i = row * W + col
                if is_land[i]:
                    continue
                lon, lat = lonlat_of(col, row)
                if in_ocean_sea(lon, lat) or etopo_frac[i] < 0.12:
                    continue
                nland = 0
                for ni in hex_neighbor_indices(i):
                    if is_land[ni]:
                        nland += 1
                if nland >= 3:
                    grow.append(i)
        for i in grow:
            is_land[i] = 1
            if elev[i] < SEA + 0.14:
                elev[i] = SEA + 0.14
            if highland[i] < 32:
                highland[i] = 32
            if moisture[i] >= 88:
                moisture[i] = 42

    def make_ocean(i: int) -> None:
        is_land[i] = 0
        if elev[i] >= SEA:
            elev[i] = SEA - 0.10
        highland[i] = 0
        moisture[i] = 90

    def make_land(i: int) -> None:
        row = i // W
        if row <= 0 or row >= H - 1:
            return
        is_land[i] = 1
        if elev[i] < SEA + 0.14:
            elev[i] = SEA + 0.14
        if highland[i] < 32:
            highland[i] = 32
        if moisture[i] >= 88:
            moisture[i] = 42

    def stamp_cell(col: int, row: int) -> None:
        if 0 <= row < H:
            make_land(row * W + (col % W))

    def ocean_cell(col: int, row: int) -> None:
        if 0 <= row < H:
            make_ocean(row * W + (col % W))

    def carve_line(points: list[tuple[float, float]], fat: bool = False) -> None:
        for pi in range(len(points) - 1):
            c0, r0 = col_row_of_lonlat(points[pi][0], points[pi][1])
            c1, r1 = col_row_of_lonlat(points[pi + 1][0], points[pi + 1][1])
            dc = c1 - c0
            if dc > W // 2:
                dc -= W
            if dc < -W // 2:
                dc += W
            steps = max(abs(dc), abs(r1 - r0), 1)
            for s in range(steps + 1):
                col = (c0 + int(round(dc * s / float(steps)))) % W
                row = r0 + int(round((r1 - r0) * s / float(steps)))
                ocean_cell(col, row)
                if fat:
                    ocean_cell(col + 1, row)

    restored = 0
    for i in range(W * H):
        if not is_land[i]:
            continue
        lon, lat = lonlat_of(i % W, i // W)
        if in_ocean_sea(lon, lat) and not ne_cover[i]:
            make_ocean(i)
            restored += 1
    print("restored_known_seas", restored)

    # 100x64: one cell is ~3.6°. Straits must be explicit 1-cell cuts, not lon/lat boxes.
    for col in range(44, 60):
        ocean_cell(col, 18)
    for col in range(47, 51):
        ocean_cell(col, 19)
    for row in range(22, 28):
        ocean_cell(60, row)
        ocean_cell(61, row)
    ocean_cell(62, 27)
    for col, row in ((63, 21), (64, 21), (63, 22), (64, 22), (65, 22), (65, 23), (66, 23), (65, 24), (66, 24)):
        ocean_cell(col, row)
    for col in range(29, 34):
        ocean_cell(col, 9)
        ocean_cell(col, 10)
    ocean_cell(78, 30)
    ocean_cell(78, 31)
    ocean_cell(79, 31)
    for row in range(15, 22):
        ocean_cell(86, row)
    for row in range(15, 20):
        ocean_cell(87, row)

    carve_line([(-8.0, 36.0), (-5.6, 36.0), (-1.0, 36.4), (2.5, 36.8)])
    carve_line(
        [
            (34.2, 27.8),
            (36.0, 24.0),
            (38.2, 20.0),
            (40.5, 16.4),
            (42.4, 13.6),
            (44.0, 12.4),
        ]
    )
    carve_line([(99.8, 5.4), (101.2, 3.2), (102.6, 1.2), (104.0, 0.2)])
    carve_line([(128.6, 35.8), (129.8, 34.6), (131.0, 33.4)])
    carve_line([(52.5, 27.5), (54.5, 26.2), (56.8, 26.0), (59.0, 25.0)])
    for col, row in ((57, 16), (58, 16), (59, 16), (58, 17)):
        ocean_cell(col, row)

    japan_cells = (
        (89, 16),
        (89, 17),
        (89, 18),
        (88, 18),
        (88, 19),
        (87, 20),
        (88, 20),
    )
    nz_cells = (
        (98, 44),
        (98, 45),
        (97, 46),
        (96, 47),
        (96, 48),
    )
    stamp_protect: set[int] = set()
    for col, row in japan_cells + nz_cells:
        stamp_cell(col, row)
        stamp_protect.add(row * W + (col % W))
    for row in range(15, 22):
        ocean_cell(86, row)

    def punch_corridor(blob: list[int]) -> bool:
        world = world_ocean_mask(is_land)
        parent = [-1] * (W * H)
        seen = [0] * (W * H)
        queue: deque[int] = deque()
        for i in range(W * H):
            if not world[i]:
                continue
            seen[i] = 1
            queue.append(i)
        blob_set = set(blob)
        hit = -1
        steps_at = [0] * (W * H)
        while queue:
            cur = queue.popleft()
            if cur in blob_set:
                hit = cur
                break
            if steps_at[cur] >= 18:
                continue
            for ni in hex_neighbor_indices(cur):
                if seen[ni] or ni in stamp_protect:
                    continue
                seen[ni] = 1
                parent[ni] = cur
                steps_at[ni] = steps_at[cur] + 1
                queue.append(ni)
        if hit < 0:
            return False
        cur = hit
        opened = 0
        while cur >= 0 and not world[cur]:
            make_ocean(cur)
            opened += 1
            cur = parent[cur]
        return opened > 0

    opened_seas = 0
    filled_holes = 0
    for _pass in range(3):
        world = world_ocean_mask(is_land)
        blobs = enclosed_water_blobs(is_land, world)
        progressed = False
        for blob in blobs:
            lon, lat = blob_centroid(blob)
            keep_sea = in_ocean_sea(lon, lat) or any(
                in_ocean_sea(*lonlat_of(i % W, i // W)) for i in blob
            )
            if keep_sea:
                continue
            if len(blob) > 40:
                if punch_corridor(blob):
                    opened_seas += 1
                    progressed = True
            else:
                for i in blob:
                    make_land(i)
                    filled_holes += 1
                progressed = True
        if not progressed:
            break

    world = world_ocean_mask(is_land)
    for blob in enclosed_water_blobs(is_land, world):
        lon, lat = blob_centroid(blob)
        if in_ocean_sea(lon, lat) or any(
            in_ocean_sea(*lonlat_of(i % W, i // W)) for i in blob
        ):
            continue
        for i in blob:
            make_land(i)
            filled_holes += 1

    for col, row in japan_cells + nz_cells:
        stamp_cell(col, row)
    for row in range(15, 22):
        ocean_cell(86, row)
    for row in range(15, 20):
        ocean_cell(87, row)
    stamp_cell(87, 20)
    for col, row in ((52, 17), (53, 17), (54, 16), (54, 17), (55, 16)):
        stamp_cell(col, row)
    for lon, lat in (
        (102.0, 15.2),
        (104.5, 13.0),
        (107.5, 11.8),
        (100.2, 14.0),
        (121.0, 16.0),
        (121.6, 13.4),
        (122.0, 10.8),
        (125.0, 8.6),
        (113.8, 1.6),
        (116.2, 0.2),
        (110.2, -7.4),
        (112.6, -7.8),
        (100.5, -2.2),
    ):
        stamp_lon = lon
        stamp_lat = lat
        col, row = col_row_of_lonlat(stamp_lon, stamp_lat)
        if col == 78 and 29 <= row <= 32:
            continue
        stamp_cell(col, row)
        stamp_protect.add(row * W + (col % W))
    for row in range(26, 31):
        for col in range(27, 35):
            lon, lat = lonlat_of(col, row)
            i = row * W + col
            if -79.0 <= lon <= -60.0 and 0.0 <= lat <= 12.0 and etopo_frac[i] >= 0.10:
                if not in_ocean_sea(lon, lat):
                    make_land(i)
    for row in range(30, 40):
        for col in range(29, 40):
            lon, lat = lonlat_of(col, row)
            i = row * W + col
            if -62.0 <= lon <= -35.0 and -25.0 <= lat <= 3.0 and etopo_frac[i] >= 0.08:
                if not in_ocean_sea(lon, lat):
                    make_land(i)
    for row in range(29, 37):
        for col in range(28, 37):
            lon, lat = lonlat_of(col, row)
            if -74.0 <= lon <= -52.0 and -10.0 <= lat <= 5.0:
                if lon >= -51.5 and abs(lat) < 1.8:
                    continue
                make_land(row * W + col)
    ocean_cell(78, 30)
    ocean_cell(78, 31)
    ocean_cell(79, 31)
    for col, row in ((63, 21), (64, 21), (63, 22), (64, 22), (65, 22), (65, 23), (66, 23), (65, 24), (66, 24)):
        ocean_cell(col, row)
    for col in range(29, 34):
        ocean_cell(col, 9)
        ocean_cell(col, 10)
    for col in range(44, 60):
        ocean_cell(col, 18)

    for _iter in range(40):
        changed = 0
        for i in range(W * H):
            if not is_land[i]:
                continue
            mn = 10.0
            for ni in hex_neighbor_indices(i):
                if elev[ni] < mn:
                    mn = elev[ni]
            if elev[i] + 0.0005 < mn:
                elev[i] = mn
                changed += 1
        if changed == 0:
            break

    for i in range(W * H):
        if is_land[i] and elev[i] < SEA + 0.14:
            elev[i] = SEA + 0.14
        if (not is_land[i]) and elev[i] >= SEA:
            elev[i] = SEA - 0.10

    seam = 0
    for row in range(H):
        i0 = row * W
        i1 = i0 + W - 1
        if abs(elev[i0] - elev[i1]) <= 0.12:
            continue
        _lon, lat = lonlat_of(0, row)
        if 52.0 <= lat <= 70.0:
            make_ocean(i0)
            make_ocean(i1)
        elif is_land[i0] or is_land[i1]:
            e = max(elev[i0], elev[i1], SEA + 0.14)
            make_land(i0)
            make_land(i1)
            elev[i0] = elev[i1] = e
            highland[i0] = highland[i1] = max(highland[i0], highland[i1], 32)
        else:
            make_ocean(i0)
            make_ocean(i1)
        seam += 1
    print("opened_seas", opened_seas, "filled_interior_water", filled_holes, "seam_fix_rows", seam)

    def dump_region(title: str, c0: int, c1: int, r0: int, r1: int) -> None:
        print(title)
        for row in range(r0, r1 + 1):
            chars = []
            for col in range(c0, c1 + 1):
                chars.append("#" if is_land[row * W + (col % W)] else ".")
            print("%02d %s" % (row, "".join(chars)))

    dump_region("japan cols85-91 rows15-21", 85, 91, 15, 21)
    dump_region("nz cols96-99 rows43-49", 96, 99, 43, 49)
    dump_region("med cols47-60 rows16-21", 47, 60, 16, 21)
    dump_region("redsea cols58-63 rows20-28", 58, 63, 20, 28)
    dump_region("malacca cols76-81 rows28-33", 76, 81, 28, 33)

    dump_region("hudson cols20-34 rows7-16", 20, 34, 7, 16)
    dump_region("sa cols24-42 rows26-42", 24, 42, 26, 42)
    dump_region("gulf cols61-67 rows20-24", 61, 67, 20, 24)
    dump_region("seasia cols74-90 rows24-36", 74, 90, 24, 36)

    rivers = []
    major_rivers = (
        (
            "mississippi",
            [(-95.0, 47.0), (-93.2, 41.5), (-90.8, 38.6), (-90.2, 35.0), (-90.8, 32.2), (-89.6, 29.4)],
        ),
        (
            "amazon",
            [(-75.2, -3.2), (-70.0, -4.0), (-62.0, -3.4), (-55.0, -2.0), (-50.2, -0.2)],
        ),
        (
            "parana",
            [(-54.8, -20.0), (-57.5, -27.2), (-58.2, -34.2)],
        ),
        (
            "nile",
            [(32.6, 15.6), (32.5, 19.0), (32.0, 24.5), (31.4, 28.5), (31.0, 32.8)],
        ),
        (
            "congo",
            [(25.2, 1.8), (18.0, -2.2), (12.8, -6.0)],
        ),
        (
            "yangtze",
            [(103.2, 30.6), (111.5, 30.6), (120.2, 31.6)],
        ),
        (
            "yellow",
            [(109.8, 35.6), (114.5, 35.2), (118.8, 37.6)],
        ),
        (
            "mekong",
            [(101.8, 18.2), (104.8, 12.0), (106.6, 10.2)],
        ),
        (
            "ganges",
            [(78.2, 28.2), (84.8, 25.2), (89.8, 22.4)],
        ),
        (
            "danube",
            [(16.4, 48.2), (20.2, 45.2), (28.8, 45.2)],
        ),
        (
            "murray",
            [(147.2, -36.2), (143.0, -34.8), (139.6, -35.4)],
        ),
        (
            "volga",
            [(50.0, 56.0), (48.5, 50.5), (47.8, 46.2)],
        ),
    )
    for name, pts in major_rivers:
        cells = cells_along(pts)
        if len(cells) >= 2:
            rivers.append({"name": name, "cells": cells})

    lakes: list[dict] = []

    elev_q = [q100(v) for v in elev]
    land_n = sum(1 for v in elev if v >= SEA)
    desert_n = sum(1 for i, v in enumerate(elev) if v >= SEA and moisture[i] <= 12)
    steppe_n = sum(1 for i, v in enumerate(elev) if v >= SEA and 13 <= moisture[i] <= 22)
    wet_n = sum(1 for i, v in enumerate(elev) if v >= SEA and moisture[i] >= 70)
    print(
        "land_ratio",
        round(land_n / float(W * H), 3),
        "rivers",
        len(rivers),
        "lakes",
        len(lakes),
        "desert",
        desert_n,
        "steppe",
        steppe_n,
        "wet",
        wet_n,
    )

    ascii_map = []
    moist_map = []
    for row in range(H):
        line = []
        mline = []
        for col in range(W):
            i = row * W + col
            land = elev[i] >= SEA
            line.append("#" if land else ".")
            m = moisture[i]
            if not land:
                mline.append(".")
            elif m <= 12:
                mline.append("D")
            elif m <= 22:
                mline.append("s")
            elif m >= 70:
                mline.append("F")
            else:
                mline.append("#")
        ascii_map.append("%02d%s" % (row, "".join(line)))
        moist_map.append("%02d%s" % (row, "".join(mline)))
    preview = GEO / "earth_like_preview.txt"
    preview.write_text(
        "  " + "0123456789" * 10 + "\n" + "\n".join(ascii_map)
        + "\n\nmoisture D=desert s=steppe F=wet #=mid\n"
        + "  " + "0123456789" * 10 + "\n" + "\n".join(moist_map),
        encoding="utf-8",
    )
    print("wrote", preview)

    river_py = []
    for r in rivers:
        river_py.append(
            "            {\"cells\": %s, \"depth\": 0.04, \"width\": 1}," % r["cells"]
        )
    lake_py = []
    for lake in lakes:
        lake_py.append("            {\"cells\": %s, \"depth\": 0.08}," % lake["cells"])

    text = r'''"""Earth 100x64 baked from Natural Earth 50m land + ETOPO20 + 110m rivers/lakes.

Do not edit the numeric grids by hand. Re-run:
  python tools/map_authoring/bake_earth_naturalearth.py
"""


def generate(ctx):
    sea = ctx.sea_level
    elev_q = [
__ELEV__
    ]
    high_q = [
__HIGH__
    ]
    moist_q = [
__MOIST__
    ]
    n = ctx.width * ctx.height
    elevation = [0.0] * n
    highland = [0.0] * n
    moisture_paint = [0.0] * n
    for row, col, i in ctx.cells():
        e = elev_q[row][col] / 100.0
        if e >= sea:
            e = ctx.clamp(e + ctx.fbm(col, row, 3, 3.2, 3) * 0.012)
            if e < sea + 0.14:
                e = sea + 0.14
        else:
            e = ctx.clamp(e + ctx.fbm(col, row, 9, 2.4, 2) * 0.01)
            if e >= sea:
                e = sea - 0.02
        elevation[i] = e
        highland[i] = high_q[row][col] / 100.0
        moisture_paint[i] = moist_q[row][col] / 100.0
    for row in range(ctx.height):
        i0 = ctx.index(0, row)
        i1 = ctx.index(ctx.width - 1, row)
        if abs(elevation[i0] - elevation[i1]) <= 0.12:
            continue
        if elevation[i0] >= sea and elevation[i1] >= sea:
            e = max(elevation[i0], elevation[i1])
            elevation[i0] = e
            elevation[i1] = e
        else:
            e = min(elevation[i0], elevation[i1], sea - 0.08)
            elevation[i0] = e
            elevation[i1] = e

    def hex_ocean_adj(col, row):
        q = col - ((row - (row & 1)) // 2)
        d = 0
        while d < 6:
            dq = (1, 1, 0, -1, -1, 0)[d]
            dr = (0, -1, -1, 0, 1, 1)[d]
            rr = row + dr
            if 0 <= rr < ctx.height:
                cc = (q + dq + ((rr - (rr & 1)) // 2)) % ctx.width
                if elevation[ctx.index(cc, rr)] < sea:
                    return True
            d += 1
        return False

    def trim_river(cells):
        out = []
        for pair in cells:
            col = int(pair[0]) % ctx.width
            row = int(pair[1])
            if row < 0 or row >= ctx.height:
                continue
            if elevation[ctx.index(col, row)] < sea:
                if out and hex_ocean_adj(out[-1][0], out[-1][1]):
                    break
                continue
            if len(out) == 0 or out[-1][0] != col or out[-1][1] != row:
                out.append([col, row])
        while len(out) > 1 and not hex_ocean_adj(out[-1][0], out[-1][1]):
            out = out[:-1]
        if len(out) >= 2 and hex_ocean_adj(out[-1][0], out[-1][1]):
            return out
        return []

    raw_rivers = [
__RIVERS__
    ]
    rivers = []
    for item in raw_rivers:
        path = trim_river(item["cells"])
        if path:
            rivers.append({"cells": path, "depth": item["depth"], "width": 1})

    raw_lakes = [
__LAKES__
    ]
    lakes = []
    for item in raw_lakes:
        cells = []
        for pair in item["cells"]:
            col = int(pair[0]) % ctx.width
            row = int(pair[1])
            if 0 <= row < ctx.height:
                cells.append([col, row])
        if len(cells) >= 8:
            lakes.append({"cells": cells, "depth": item["depth"]})

    return {
        "elevation": elevation,
        "sea_level": sea,
        "hints": {
            "carve_rivers": rivers,
            "lake_basins": lakes,
            "moisture_paint": {"values": moisture_paint, "mix": 0.92},
            "highland_paint": {"values": highland, "mix": 0.32},
        },
    }
'''
    text = (
        text.replace("__ELEV__", fmt_rows(elev_q))
        .replace("__HIGH__", fmt_rows(highland))
        .replace("__MOIST__", fmt_rows(moisture))
        .replace("__RIVERS__", "\n".join(river_py))
        .replace("__LAKES__", "\n".join(lake_py))
    )
    OUT.write_text(text, encoding="utf-8")
    print("wrote", OUT)


if __name__ == "__main__":
    main()

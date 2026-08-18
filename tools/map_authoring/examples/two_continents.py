"""Two wrapping continents, a draining river, and an inland lake basin."""


def generate(ctx):
    n = ctx.width * ctx.height
    elevation = [0.0] * n
    highland = [0.0] * n
    moisture_paint = [0.0] * n
    for row, col, i in ctx.cells():
        nx = ctx.nx(col)
        ny = ctx.ny(row)
        d1 = ctx.cyl_dist(nx, ny, 0.24, 0.50)
        d2 = ctx.cyl_dist(nx, ny, 0.68, 0.52)
        blob = max(
            ctx.smoothstep(0.30, 0.07, d1),
            ctx.smoothstep(0.28, 0.07, d2),
        )
        noise = ctx.fbm(col, row, 3, 2.5, 4) * 0.06
        ridge = ctx.ridged(col, row, 9, 3.0, 3) * 0.10
        e = 0.36 + blob * 0.40 + noise
        if ny < 0.05 or ny > 0.95:
            e = min(e, 0.40)
        elevation[i] = ctx.clamp(e)
        highland[i] = ctx.clamp(blob * ridge * 2.0)
        moisture_paint[i] = ctx.clamp(0.35 + blob * 0.25 + (1.0 - abs(ny * 2.0 - 1.0)) * 0.15)

    mid_row = ctx.height // 2
    river = []
    start_col = int(0.28 * ctx.width)
    for col in range(start_col, -1, -1):
        river.append([col, mid_row])

    lake = []
    lake_c = int(0.30 * ctx.width)
    lake_r = mid_row - 2
    for dr in range(-1, 2):
        for dc in range(-2, 3):
            lake.append([lake_c + dc, lake_r + dr])

    return {
        "elevation": elevation,
        "sea_level": ctx.sea_level,
        "hints": {
            "carve_rivers": [{"cells": river, "depth": 0.05, "width": 1}],
            "lake_basins": [{"cells": lake, "depth": 0.08}],
            "moisture_paint": {"values": moisture_paint, "mix": 0.45},
            "highland_paint": {"values": highland, "mix": 0.35},
        },
    }

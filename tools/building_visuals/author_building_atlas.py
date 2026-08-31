#!/usr/bin/env python3
"""Deterministic authoring/bake tool for the Project.Keynes building visual atlas.

The strategic map is a flat, top-down, low-saturation geometric presentation
(see ShrubLayer's procedural archetype meshes). Building tiles therefore use
flat colour fields, a horizontal roof ridge, a dark foundation band at the
bottom edge, and no baked shadow: false shadows are drawn by the separate
analytic ``building_shadow`` pass.

Outputs (all deterministic for identical inputs):
  * one SVG per tile under ``assets/buildings/source`` so artists can replace
    any authored silhouette without touching the runtime;
  * ``assets/buildings/generated/building_albedo.png`` - RGBA colour + silhouette;
  * ``assets/buildings/generated/building_surface.png`` - RGBA response mask
    (R = up-facing snow acceptance, G = wetness response, B = window emission,
    A = ambient-occlusion / occupancy aid);
  * ``assets/buildings/building_visual_manifest.json`` - atlas geometry, channel
    semantics, era-band mapping and content hashes.

Tile index contract (must match building_compound.gdshader):
    index = art_era * 18 + archetype * 3 + variant
    column = index % 9, row = index // 9
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

REPO_ROOT = Path(__file__).resolve().parents[2]
ASSET_ROOT = REPO_ROOT / "Project" / "project-keynes" / "assets" / "buildings"
SOURCE_DIR = ASSET_ROOT / "source"
GENERATED_DIR = ASSET_ROOT / "generated"
MANIFEST_PATH = ASSET_ROOT / "building_visual_manifest.json"

ATLAS_COLUMNS = 12
ATLAS_ROWS = 6
TILE_SIZE = 160
SUPERSAMPLE = 4
LAYOUT_VERSION = 2

ARCHETYPES = [
    "agriculture",
    "extractive",
    "manufacturing",
    "energy",
    "knowledge",
    "service",
]
ERA_BANDS = ["early", "masonry", "industrial", "modern"]
# Runtime eras come from completed TechnologyCatalog milestones. This table only
# maps an authoritative era index onto an art band; it never derives era itself.
# The breakpoints match the procedural fallback palette in building_visual_layer
# so switching between authored and fallback art cannot change an era's read.
RUNTIME_ERA_TO_BAND = [0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3]
VARIANT_COUNT = 3

BAND_EARLY = 0
BAND_MASONRY = 1
BAND_INDUSTRIAL = 2
BAND_MODERN = 3

PALETTES = [
    {
        "roof_back": (0.42, 0.30, 0.20),
        "roof_front": (0.55, 0.40, 0.26),
        "ridge": (0.63, 0.48, 0.32),
        "wall": (0.72, 0.64, 0.50),
        "wall_side": (0.55, 0.48, 0.37),
        "foundation": (0.24, 0.20, 0.16),
        "facility": (0.41, 0.34, 0.25),
        "window": (0.30, 0.35, 0.33),
        "door": (0.22, 0.16, 0.12),
        "yard": (0.49, 0.47, 0.29),
        "metal": (0.46, 0.45, 0.43),
        "glass": (0.45, 0.56, 0.57),
        "pit": (0.33, 0.28, 0.23),
    },
    {
        "roof_back": (0.44, 0.26, 0.20),
        "roof_front": (0.58, 0.34, 0.25),
        "ridge": (0.66, 0.41, 0.30),
        "wall": (0.76, 0.72, 0.63),
        "wall_side": (0.58, 0.55, 0.48),
        "foundation": (0.28, 0.26, 0.23),
        "facility": (0.48, 0.44, 0.38),
        "window": (0.32, 0.34, 0.36),
        "door": (0.26, 0.19, 0.14),
        "yard": (0.52, 0.50, 0.34),
        "metal": (0.50, 0.49, 0.46),
        "glass": (0.46, 0.55, 0.58),
        "pit": (0.36, 0.32, 0.28),
    },
    {
        "roof_back": (0.31, 0.29, 0.30),
        "roof_front": (0.44, 0.41, 0.42),
        "ridge": (0.53, 0.50, 0.50),
        "wall": (0.56, 0.35, 0.28),
        "wall_side": (0.42, 0.26, 0.21),
        "foundation": (0.20, 0.19, 0.19),
        "facility": (0.38, 0.36, 0.35),
        "window": (0.63, 0.66, 0.62),
        "door": (0.18, 0.16, 0.15),
        "yard": (0.40, 0.38, 0.33),
        "metal": (0.41, 0.41, 0.43),
        "glass": (0.55, 0.64, 0.64),
        "pit": (0.27, 0.25, 0.24),
    },
    {
        "roof_back": (0.38, 0.42, 0.44),
        "roof_front": (0.51, 0.55, 0.57),
        "ridge": (0.61, 0.65, 0.67),
        "wall": (0.72, 0.74, 0.74),
        "wall_side": (0.56, 0.58, 0.59),
        "foundation": (0.26, 0.28, 0.29),
        "facility": (0.47, 0.52, 0.55),
        "window": (0.41, 0.62, 0.70),
        "door": (0.24, 0.28, 0.30),
        "yard": (0.44, 0.47, 0.45),
        "metal": (0.62, 0.64, 0.66),
        "glass": (0.37, 0.58, 0.68),
        "pit": (0.34, 0.36, 0.38),
    },
]

# R = up-facing snow acceptance, G = wetness response, B = window emission,
# A = ambient occlusion / occupancy aid.
SURFACE = {
    "roof_back": (1.00, 0.55, 0.00, 1.00),
    "roof_front": (0.92, 0.60, 0.00, 1.00),
    "ridge": (1.00, 0.45, 0.00, 1.00),
    "wall": (0.10, 0.95, 0.00, 1.00),
    "wall_side": (0.06, 0.95, 0.00, 1.00),
    "foundation": (0.02, 0.85, 0.00, 1.00),
    "facility": (0.60, 0.70, 0.00, 1.00),
    "window": (0.00, 0.50, 1.00, 1.00),
    "door": (0.00, 0.50, 0.22, 1.00),
    "yard": (0.35, 1.00, 0.00, 0.55),
    "metal": (0.70, 0.80, 0.00, 1.00),
    "glass": (0.55, 0.90, 0.45, 1.00),
    "pit": (0.05, 0.90, 0.00, 0.85),
}


def rect(role: str, x0: float, y0: float, x1: float, y1: float):
    return (role, [(x0, y0), (x1, y0), (x1, y1), (x0, y1)])


def circle(role: str, cx: float, cy: float, r: float, segments: int = 24):
    pts = []
    for i in range(segments):
        angle = 2.0 * math.pi * i / segments
        pts.append((cx + math.cos(angle) * r, cy + math.sin(angle) * r))
    return (role, pts)


def trapezoid(role: str, cx: float, top_w: float, bottom_w: float, y0: float, y1: float):
    return (
        role,
        [
            (cx - top_w / 2.0, y0),
            (cx + top_w / 2.0, y0),
            (cx + bottom_w / 2.0, y1),
            (cx - bottom_w / 2.0, y1),
        ],
    )


def pitched_body(
    cx: float,
    width: float,
    y_top: float,
    y_eave: float,
    y_wall: float,
    ridge_t: float = 0.5,
    base_widen: float = 1.10,
    base_h: float = 0.042,
):
    """A top-down pitched building: back slope, ridge, front slope, wall, base."""
    x0 = cx - width / 2.0
    x1 = cx + width / 2.0
    y_ridge = y_top + (y_eave - y_top) * ridge_t
    parts = [
        rect("roof_back", x0, y_top, x1, y_ridge),
        rect("roof_front", x0, y_ridge, x1, y_eave),
        rect("ridge", x0, y_ridge - 0.011, x1, y_ridge + 0.011),
        rect("wall", x0 + 0.014, y_eave, x1 - 0.014, y_wall),
    ]
    base_w = width * base_widen
    parts.append(rect("foundation", cx - base_w / 2.0, y_wall, cx + base_w / 2.0, y_wall + base_h))
    return parts


def flat_body(
    cx: float,
    width: float,
    y_top: float,
    y_eave: float,
    y_wall: float,
    base_widen: float = 1.06,
    base_h: float = 0.040,
):
    x0 = cx - width / 2.0
    x1 = cx + width / 2.0
    parts = [
        rect("roof_back", x0, y_top, x1, y_eave - 0.020),
        rect("ridge", x0, y_eave - 0.031, x1, y_eave - 0.020),
        rect("wall", x0 + 0.012, y_eave - 0.020, x1 - 0.012, y_wall),
    ]
    base_w = width * base_widen
    parts.append(rect("foundation", cx - base_w / 2.0, y_wall, cx + base_w / 2.0, y_wall + base_h))
    return parts


def barrel_body(cx: float, width: float, y_top: float, y_eave: float, y_wall: float):
    x0 = cx - width / 2.0
    x1 = cx + width / 2.0
    span = y_eave - y_top
    parts = [
        rect("roof_back", x0, y_top + span * 0.00, x1, y_top + span * 0.34),
        rect("ridge", x0, y_top + span * 0.34, x1, y_top + span * 0.46),
        rect("roof_front", x0, y_top + span * 0.46, x1, y_eave),
        rect("wall", x0 + 0.016, y_eave, x1 - 0.016, y_wall),
        rect("foundation", x0 - 0.020, y_wall, x1 + 0.020, y_wall + 0.040),
    ]
    return parts


def sawtooth_roof(cx: float, width: float, y_top: float, y_eave: float, teeth: int):
    x0 = cx - width / 2.0
    step = width / teeth
    parts = []
    for i in range(teeth):
        tx0 = x0 + step * i
        tx1 = tx0 + step
        parts.append(rect("roof_back", tx0, y_top, tx1, y_top + (y_eave - y_top) * 0.62))
        parts.append(rect("glass", tx0 + step * 0.10, y_top + (y_eave - y_top) * 0.62,
                          tx1 - step * 0.10, y_eave))
    return parts


def windows(cx: float, width: float, y0: float, y1: float, count: int):
    parts = []
    span = width / (count + 1)
    for i in range(count):
        wx = cx - width / 2.0 + span * (i + 1)
        parts.append(rect("window", wx - span * 0.24, y0, wx + span * 0.24, y1))
    return parts


def door(cx: float, w: float, y0: float, y1: float):
    return [rect("door", cx - w / 2.0, y0, cx + w / 2.0, y1)]


def chimney(cx: float, w: float, y0: float, y1: float):
    return [
        rect("facility", cx - w / 2.0, y0 + 0.030, cx + w / 2.0, y1),
        rect("metal", cx - w * 0.78, y0, cx + w * 0.78, y0 + 0.030),
    ]


def tower(cx: float, w: float, y0: float, y1: float, cap: bool = True):
    parts = [trapezoid("facility", cx, w * 0.72, w, y0, y1)]
    if cap:
        parts.append(rect("metal", cx - w * 0.62, y0 - 0.026, cx + w * 0.62, y0))
    return parts


def field_rows(x0: float, x1: float, y0: float, y1: float, rows: int):
    parts = [rect("yard", x0, y0, x1, y1)]
    step = (y1 - y0) / (rows * 2 - 1)
    for i in range(rows):
        ry = y0 + step * (i * 2)
        parts.append(rect("facility", x0 + 0.010, ry, x1 - 0.010, ry + step * 0.62))
    return parts


def panel_grid(x0: float, y0: float, x1: float, y1: float, nx: int, ny: int):
    parts = [rect("foundation", x0, y0, x1, y1)]
    dx = (x1 - x0) / nx
    dy = (y1 - y0) / ny
    for ix in range(nx):
        for iy in range(ny):
            parts.append(rect("glass", x0 + dx * ix + dx * 0.12, y0 + dy * iy + dy * 0.14,
                              x0 + dx * (ix + 1) - dx * 0.12, y0 + dy * (iy + 1) - dy * 0.14))
    return parts


def pit_rings(cx: float, cy: float, r: float, rings: int):
    parts = []
    for i in range(rings):
        rr = r * (1.0 - i / float(rings))
        role = "pit" if i % 2 == 0 else "foundation"
        parts.append(circle(role, cx, cy, rr))
    return parts


def headframe(cx: float, y0: float, y1: float, w: float):
    return [
        rect("metal", cx - w * 0.10, y0, cx + w * 0.10, y1),
        rect("metal", cx - w * 0.52, y0 + (y1 - y0) * 0.16, cx + w * 0.52,
             y0 + (y1 - y0) * 0.26),
        (
            "metal",
            [(cx - w * 0.52, y1), (cx - w * 0.16, y0 + (y1 - y0) * 0.20),
             (cx - w * 0.02, y0 + (y1 - y0) * 0.20), (cx - w * 0.30, y1)],
        ),
        (
            "metal",
            [(cx + w * 0.52, y1), (cx + w * 0.16, y0 + (y1 - y0) * 0.20),
             (cx + w * 0.02, y0 + (y1 - y0) * 0.20), (cx + w * 0.30, y1)],
        ),
    ]


def dome(cx: float, cy: float, r: float):
    return [circle("facility", cx, cy, r), circle("glass", cx, cy, r * 0.62),
            rect("metal", cx - r * 0.06, cy - r - 0.030, cx + r * 0.06, cy - r + 0.010)]


def dish(cx: float, cy: float, r: float):
    return [circle("metal", cx, cy, r), circle("glass", cx, cy, r * 0.58)]


def antenna(cx: float, y0: float, y1: float):
    return [
        rect("metal", cx - 0.008, y0, cx + 0.008, y1),
        rect("metal", cx - 0.052, y0 + 0.020, cx + 0.052, y0 + 0.030),
        rect("metal", cx - 0.034, y0 + 0.052, cx + 0.034, y0 + 0.062),
    ]


def silo(cx: float, w: float, y0: float, y1: float):
    return [
        rect("metal", cx - w / 2.0, y0 + 0.024, cx + w / 2.0, y1),
        circle("facility", cx, y0 + 0.028, w * 0.50, 16),
    ]


def canopy_rows(cx: float, width: float, y0: float, y1: float, bays: int):
    x0 = cx - width / 2.0
    step = width / bays
    parts = [rect("roof_back", x0, y0, cx + width / 2.0, y0 + (y1 - y0) * 0.42),
             rect("ridge", x0, y0 + (y1 - y0) * 0.42, cx + width / 2.0,
                  y0 + (y1 - y0) * 0.52)]
    for i in range(bays):
        bx = x0 + step * i
        parts.append(rect("facility", bx + step * 0.16, y0 + (y1 - y0) * 0.52,
                          bx + step * 0.84, y1))
    parts.append(rect("foundation", x0 - 0.018, y1, cx + width / 2.0 + 0.018, y1 + 0.040))
    return parts


def agriculture(era: int, variant: int):
    if variant == 0:
        parts = field_rows(0.10, 0.90, 0.72, 0.86, 3)
        if era == BAND_EARLY:
            # Thatch: a squat body with a deep front slope and no glazing.
            parts += pitched_body(0.42, 0.46, 0.20, 0.52, 0.68,
                                  ridge_t=0.34, base_widen=1.20)
            parts += door(0.42, 0.09, 0.55, 0.68)
            parts += pitched_body(0.80, 0.22, 0.42, 0.58, 0.68,
                                  ridge_t=0.36, base_widen=1.22)
        elif era == BAND_MASONRY:
            parts += pitched_body(0.44, 0.54, 0.16, 0.50, 0.68, ridge_t=0.48)
            parts += windows(0.44, 0.42, 0.55, 0.62, 2)
            parts += door(0.28, 0.09, 0.53, 0.68)
            parts += chimney(0.72, 0.06, 0.10, 0.34)
            parts += pitched_body(0.82, 0.20, 0.38, 0.58, 0.68, ridge_t=0.52)
        elif era == BAND_INDUSTRIAL:
            parts += pitched_body(0.44, 0.52, 0.16, 0.50, 0.68, ridge_t=0.58)
            parts += windows(0.44, 0.40, 0.55, 0.62, 3)
            parts += silo(0.80, 0.16, 0.30, 0.68)
        else:
            parts += flat_body(0.42, 0.50, 0.20, 0.50, 0.68)
            parts += windows(0.42, 0.40, 0.54, 0.62, 4)
            parts += panel_grid(0.70, 0.34, 0.92, 0.62, 2, 3)
        return parts
    if variant == 1:
        parts = []
        if era == BAND_EARLY:
            parts += pitched_body(0.30, 0.30, 0.30, 0.54, 0.70,
                                  ridge_t=0.34, base_widen=1.22)
            parts += pitched_body(0.62, 0.26, 0.38, 0.58, 0.70,
                                  ridge_t=0.36, base_widen=1.22)
            parts.append(circle("yard", 0.86, 0.60, 0.10))
        elif era == BAND_MASONRY:
            parts += pitched_body(0.30, 0.34, 0.24, 0.52, 0.70, ridge_t=0.50)
            parts += pitched_body(0.70, 0.32, 0.30, 0.56, 0.70, ridge_t=0.50)
            parts += chimney(0.50, 0.06, 0.22, 0.46)
        elif era == BAND_INDUSTRIAL:
            parts += silo(0.28, 0.18, 0.20, 0.70)
            parts += silo(0.50, 0.18, 0.26, 0.70)
            parts += flat_body(0.76, 0.30, 0.42, 0.58, 0.70)
        else:
            parts += flat_body(0.36, 0.40, 0.22, 0.50, 0.70)
            parts += panel_grid(0.60, 0.26, 0.92, 0.66, 3, 4)
        parts += field_rows(0.12, 0.88, 0.76, 0.86, 2)
        return parts
    parts = field_rows(0.08, 0.50, 0.30, 0.80, 3)
    if era == BAND_EARLY:
        parts += pitched_body(0.72, 0.36, 0.28, 0.56, 0.72,
                              ridge_t=0.34, base_widen=1.20)
    elif era == BAND_MASONRY:
        parts += pitched_body(0.72, 0.40, 0.22, 0.52, 0.72, ridge_t=0.50)
        parts += chimney(0.88, 0.05, 0.14, 0.36)
    elif era == BAND_INDUSTRIAL:
        parts += pitched_body(0.72, 0.42, 0.20, 0.50, 0.72, ridge_t=0.62)
        parts += silo(0.60, 0.14, 0.28, 0.50)
    else:
        parts += sawtooth_roof(0.72, 0.42, 0.22, 0.50, 3)
        parts += flat_body(0.72, 0.42, 0.50, 0.60, 0.72)
    parts += door(0.72, 0.10, 0.58, 0.72)
    return parts


def extractive(era: int, variant: int):
    if variant == 0:
        if era == BAND_EARLY:
            parts = pitched_body(0.34, 0.32, 0.34, 0.58, 0.74,
                                 ridge_t=0.34, base_widen=1.22)
        else:
            parts = pitched_body(0.34, 0.36, 0.30, 0.56, 0.74, ridge_t=0.50)
        parts += door(0.34, 0.10, 0.60, 0.74)
        parts += headframe(0.72, 0.16, 0.74, 0.34)
        parts.append(rect("foundation", 0.54, 0.74, 0.92, 0.79))
        if era == BAND_MASONRY:
            parts += chimney(0.50, 0.05, 0.36, 0.56)
        elif era == BAND_INDUSTRIAL:
            parts += chimney(0.50, 0.07, 0.28, 0.56)
            parts += silo(0.14, 0.12, 0.42, 0.74)
        elif era == BAND_MODERN:
            parts += panel_grid(0.06, 0.20, 0.28, 0.42, 2, 2)
        return parts
    if variant == 1:
        # A terraced quarry cut. Nested rings read as a bullseye at strategic
        # zoom, so the benches are wide horizontal steps instead, with a ramp
        # breaking the symmetry and a spoil heap for scale.
        benches = 3 if era <= BAND_MASONRY else 4
        parts = [rect("pit", 0.10, 0.26, 0.90, 0.68)]
        for i in range(benches):
            inset = 0.085 * i
            top = 0.26 + i * (0.38 / benches)
            parts.append(rect("foundation", 0.10 + inset, top,
                              0.90 - inset, top + 0.048))
        parts.append(("facility", [(0.34, 0.68), (0.46, 0.68),
                                   (0.62, 0.28), (0.54, 0.28)]))
        parts.append(circle("foundation", 0.80, 0.74, 0.085))
        if era == BAND_EARLY:
            parts += pitched_body(0.22, 0.22, 0.70, 0.80, 0.87,
                                  ridge_t=0.34, base_h=0.026)
        elif era == BAND_MASONRY:
            parts += pitched_body(0.22, 0.24, 0.70, 0.80, 0.87,
                                  ridge_t=0.50, base_h=0.028)
            parts += headframe(0.80, 0.10, 0.26, 0.18)
        elif era == BAND_INDUSTRIAL:
            parts += flat_body(0.22, 0.24, 0.72, 0.81, 0.87, base_h=0.028)
            parts += headframe(0.80, 0.06, 0.26, 0.22)
        else:
            parts += flat_body(0.22, 0.26, 0.72, 0.81, 0.87, base_h=0.028)
            parts += tower(0.80, 0.10, 0.06, 0.26)
        return parts
    parts = []
    for i, cx in enumerate((0.24, 0.42, 0.60)):
        parts.append(circle("pit", cx, 0.76 - i * 0.02, 0.11))
    if era == BAND_EARLY:
        parts += pitched_body(0.66, 0.30, 0.32, 0.56, 0.68,
                              ridge_t=0.34, base_widen=1.22)
    elif era == BAND_MASONRY:
        parts += pitched_body(0.66, 0.34, 0.26, 0.52, 0.68, ridge_t=0.50)
        parts += windows(0.66, 0.26, 0.55, 0.63, 2)
    elif era == BAND_INDUSTRIAL:
        parts += flat_body(0.66, 0.36, 0.24, 0.50, 0.68)
        parts += windows(0.66, 0.26, 0.55, 0.63, 2)
        parts += chimney(0.88, 0.06, 0.18, 0.44)
    else:
        parts += flat_body(0.62, 0.44, 0.20, 0.48, 0.68)
        parts += windows(0.62, 0.32, 0.53, 0.62, 3)
        parts += tower(0.90, 0.09, 0.28, 0.68)
    return parts


def manufacturing(era: int, variant: int):
    if variant == 0:
        if era == BAND_EARLY:
            parts = pitched_body(0.46, 0.50, 0.28, 0.56, 0.74,
                                 ridge_t=0.34, base_widen=1.20)
            parts += door(0.34, 0.11, 0.60, 0.74)
            parts.append(circle("facility", 0.80, 0.60, 0.11))
            return parts
        parts = pitched_body(0.46, 0.58, 0.24, 0.54, 0.74,
                             ridge_t=0.48 if era == BAND_MASONRY else 0.58)
        parts += windows(0.46, 0.46, 0.59, 0.68,
                         2 if era == BAND_MASONRY else 3)
        parts += door(0.30, 0.10, 0.60, 0.74)
        parts += chimney(0.80, 0.06 if era == BAND_MASONRY else 0.08,
                         0.16 if era == BAND_MASONRY else 0.12, 0.50)
        if era == BAND_MODERN:
            parts += panel_grid(0.16, 0.14, 0.40, 0.22, 3, 1)
        return parts
    if variant == 1:
        if era == BAND_EARLY:
            # Open-air workshop row: three small kilns under one long eave.
            parts = pitched_body(0.48, 0.66, 0.26, 0.44, 0.50,
                                 ridge_t=0.34, base_h=0.022)
            for cx in (0.26, 0.48, 0.70):
                parts.append(circle("facility", cx, 0.64, 0.085))
            parts.append(rect("foundation", 0.12, 0.74, 0.86, 0.79))
            return parts
        teeth = 3 if era == BAND_MASONRY else 4
        parts = sawtooth_roof(0.48, 0.66, 0.24, 0.50, teeth)
        parts += flat_body(0.48, 0.66, 0.50, 0.60, 0.76)
        parts += door(0.48, 0.12, 0.64, 0.76)
        parts += chimney(0.84, 0.07, 0.16, 0.52)
        return parts
    if era == BAND_EARLY:
        parts = pitched_body(0.48, 0.56, 0.28, 0.56, 0.76,
                             ridge_t=0.34, base_widen=1.20)
        parts += door(0.48, 0.12, 0.62, 0.76)
        parts += chimney(0.18, 0.05, 0.24, 0.48)
        return parts
    parts = pitched_body(0.48, 0.62, 0.26, 0.54, 0.76, ridge_t=0.52) \
        if era == BAND_MASONRY else barrel_body(0.48, 0.62, 0.26, 0.54, 0.76)
    parts += windows(0.48, 0.50, 0.58, 0.68, 4)
    if era == BAND_MASONRY:
        parts += chimney(0.16, 0.06, 0.16, 0.48)
    elif era == BAND_INDUSTRIAL:
        parts += chimney(0.16, 0.07, 0.12, 0.48)
        parts += chimney(0.82, 0.07, 0.18, 0.50)
    else:
        parts += tower(0.86, 0.11, 0.24, 0.60)
    return parts


def energy(era: int, variant: int):
    if variant == 0:
        if era == BAND_EARLY:
            parts = pitched_body(0.38, 0.40, 0.32, 0.58, 0.74,
                                 ridge_t=0.34, base_widen=1.22)
            parts += door(0.38, 0.10, 0.62, 0.74)
            parts.append(circle("metal", 0.76, 0.56, 0.15))
            parts.append(circle("facility", 0.76, 0.56, 0.06))
            parts.append(rect("facility", 0.58, 0.70, 0.94, 0.75))
            return parts
        parts = pitched_body(0.40, 0.44, 0.28, 0.56, 0.74, ridge_t=0.50) \
            if era == BAND_MASONRY else flat_body(0.40, 0.46, 0.28, 0.56, 0.74)
        parts += door(0.40, 0.10, 0.60, 0.74)
        if era == BAND_MASONRY:
            parts.append(circle("metal", 0.78, 0.54, 0.14))
            parts.append(circle("facility", 0.78, 0.54, 0.05))
            parts += chimney(0.14, 0.05, 0.22, 0.50)
        elif era == BAND_INDUSTRIAL:
            parts += chimney(0.76, 0.09, 0.14, 0.56)
            parts.append(circle("metal", 0.88, 0.66, 0.09))
        else:
            parts += panel_grid(0.62, 0.30, 0.94, 0.70, 3, 3)
        return parts
    if variant == 1:
        parts = []
        if era == BAND_EARLY:
            # Stacked fuel/charcoal mounds rather than pressure vessels.
            for i, cx in enumerate((0.28, 0.52, 0.76)):
                parts.append(trapezoid("facility", cx, 0.06, 0.20,
                                       0.36 + i * 0.04, 0.66 + i * 0.02))
            parts += pitched_body(0.42, 0.34, 0.66, 0.76, 0.84,
                                  ridge_t=0.34, base_h=0.030)
            return parts
        for i, cx in enumerate((0.30, 0.56, 0.80)):
            parts.append(circle("metal", cx, 0.44 + i * 0.03, 0.13))
            parts.append(circle("facility", cx, 0.44 + i * 0.03, 0.055))
        parts += flat_body(0.42, 0.40, 0.66, 0.74, 0.84)
        if era == BAND_MASONRY:
            parts += chimney(0.12, 0.05, 0.30, 0.66)
        elif era == BAND_MODERN:
            parts += antenna(0.88, 0.18, 0.36)
        return parts
    if era == BAND_EARLY:
        parts = pitched_body(0.42, 0.44, 0.32, 0.58, 0.78,
                             ridge_t=0.34, base_widen=1.20)
        parts.append(circle("metal", 0.80, 0.60, 0.13))
        return parts
    parts = flat_body(0.42, 0.48, 0.34, 0.58, 0.78)
    parts += windows(0.42, 0.38, 0.62, 0.70, 3)
    if era == BAND_MASONRY:
        parts.append(circle("metal", 0.80, 0.58, 0.14))
        parts += chimney(0.80, 0.06, 0.26, 0.44)
    elif era == BAND_INDUSTRIAL:
        parts.append(trapezoid("metal", 0.80, 0.20, 0.28, 0.26, 0.72))
    else:
        parts.append(trapezoid("metal", 0.80, 0.16, 0.24, 0.24, 0.66))
        parts.append(circle("glass", 0.80, 0.30, 0.06))
    return parts


def knowledge(era: int, variant: int):
    if variant == 0:
        if era == BAND_EARLY:
            parts = pitched_body(0.48, 0.50, 0.32, 0.60, 0.76,
                                 ridge_t=0.34, base_widen=1.20)
            parts += door(0.48, 0.11, 0.64, 0.76)
            parts.append(rect("facility", 0.24, 0.26, 0.72, 0.32))
            return parts
        parts = pitched_body(0.48, 0.56, 0.30, 0.58, 0.76, ridge_t=0.50)
        parts += dome(0.48, 0.28, 0.13)
        parts += windows(0.48, 0.44, 0.62, 0.70, 3)
        parts += door(0.48, 0.11, 0.64, 0.76)
        if era == BAND_INDUSTRIAL:
            parts += chimney(0.86, 0.06, 0.34, 0.58)
        elif era == BAND_MODERN:
            parts += antenna(0.86, 0.22, 0.42)
        return parts
    if variant == 1:
        parts = [rect("yard", 0.32, 0.44, 0.68, 0.70)]
        parts += flat_body(0.22, 0.20, 0.34, 0.62, 0.76)
        parts += flat_body(0.78, 0.20, 0.34, 0.62, 0.76)
        parts += pitched_body(0.50, 0.62, 0.24, 0.40, 0.46,
                              ridge_t=0.34 if era == BAND_EARLY else 0.50,
                              base_h=0.024)
        if era == BAND_EARLY:
            parts.append(rect("facility", 0.42, 0.14, 0.58, 0.24))
        elif era == BAND_MASONRY:
            parts += dome(0.50, 0.20, 0.10)
        else:
            parts += tower(0.50, 0.13, 0.14, 0.40)
        parts.append(rect("foundation", 0.16, 0.76, 0.84, 0.81))
        return parts
    parts = flat_body(0.36, 0.36, 0.30, 0.58, 0.76)
    parts += flat_body(0.72, 0.28, 0.40, 0.62, 0.76)
    parts += windows(0.36, 0.28, 0.62, 0.70, 2)
    if era == BAND_EARLY:
        parts.append(trapezoid("facility", 0.72, 0.10, 0.22, 0.28, 0.44))
    elif era == BAND_MASONRY:
        parts += dome(0.72, 0.34, 0.10)
    elif era == BAND_INDUSTRIAL:
        parts += tower(0.72, 0.12, 0.24, 0.40)
    else:
        parts += dish(0.74, 0.30, 0.11)
        parts += antenna(0.20, 0.18, 0.34)
    return parts


def service(era: int, variant: int):
    if variant == 0:
        bays = 3 if era <= BAND_MASONRY else 4
        parts = canopy_rows(0.50, 0.72, 0.30, 0.74, bays)
        if era == BAND_EARLY:
            parts.append(rect("yard", 0.18, 0.76, 0.82, 0.82))
        elif era == BAND_MASONRY:
            parts += chimney(0.86, 0.05, 0.24, 0.48)
        elif era == BAND_MODERN:
            parts.append(rect("glass", 0.24, 0.34, 0.76, 0.42))
        return parts
    if variant == 1:
        if era == BAND_EARLY:
            parts = pitched_body(0.48, 0.58, 0.28, 0.58, 0.78,
                                 ridge_t=0.34, base_widen=1.20)
        elif era == BAND_MASONRY:
            parts = pitched_body(0.48, 0.62, 0.26, 0.56, 0.78, ridge_t=0.46)
        else:
            parts = barrel_body(0.48, 0.66, 0.28, 0.58, 0.78)
        parts += door(0.36, 0.13, 0.62, 0.78)
        if era != BAND_EARLY:
            parts += windows(0.62, 0.26, 0.62, 0.70, 2)
        if era == BAND_MODERN:
            parts += panel_grid(0.20, 0.16, 0.76, 0.26, 4, 1)
        return parts
    parts = [rect("yard", 0.16, 0.66, 0.84, 0.80)]
    if era == BAND_EARLY:
        parts += pitched_body(0.44, 0.44, 0.28, 0.54, 0.66,
                              ridge_t=0.34, base_widen=1.20)
    elif era == BAND_MASONRY:
        parts += pitched_body(0.44, 0.48, 0.26, 0.52, 0.66, ridge_t=0.52)
    else:
        parts += flat_body(0.44, 0.50, 0.26, 0.52, 0.66)
    parts += windows(0.44, 0.40, 0.55, 0.63, 2 if era == BAND_EARLY else 3)
    parts += door(0.44, 0.11, 0.56, 0.66)
    if era == BAND_EARLY:
        parts += pitched_body(0.80, 0.20, 0.46, 0.58, 0.66,
                              ridge_t=0.34, base_h=0.026)
    elif era == BAND_MASONRY:
        parts += pitched_body(0.80, 0.22, 0.42, 0.58, 0.66,
                              ridge_t=0.52, base_h=0.026)
    elif era == BAND_INDUSTRIAL:
        parts += flat_body(0.80, 0.24, 0.40, 0.56, 0.66, base_h=0.026)
    else:
        parts += flat_body(0.80, 0.26, 0.36, 0.54, 0.66, base_h=0.026)
        parts += antenna(0.86, 0.20, 0.34)
    parts.append(rect("foundation", 0.14, 0.80, 0.86, 0.85))
    return parts


BUILDERS = [agriculture, extractive, manufacturing, energy, knowledge, service]


def tile_parts(era: int, archetype: int, variant: int):
    return BUILDERS[archetype](era, variant)


def tile_index(era: int, archetype: int, variant: int) -> int:
    return era * (len(ARCHETYPES) * VARIANT_COUNT) + archetype * VARIANT_COUNT + variant


def tile_name(era: int, archetype: int, variant: int) -> str:
    return f"{ERA_BANDS[era]}_{ARCHETYPES[archetype]}_v{variant}"


def to_byte(value: float) -> int:
    return max(0, min(255, int(round(value * 255.0))))


def write_svg(path: Path, parts, palette) -> None:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{TILE_SIZE}" '
        f'height="{TILE_SIZE}" viewBox="0 0 {TILE_SIZE} {TILE_SIZE}">',
        "  <!-- Flat top-down authored tile. No baked shadow: the analytic",
        "       building_shadow pass owns false shadows. -->",
    ]
    for role, pts in parts:
        colour = palette[role]
        hex_colour = "#%02x%02x%02x" % (to_byte(colour[0]), to_byte(colour[1]), to_byte(colour[2]))
        coords = " ".join(
            f"{x * TILE_SIZE:.2f},{y * TILE_SIZE:.2f}" for x, y in pts
        )
        lines.append(f'  <polygon data-role="{role}" fill="{hex_colour}" points="{coords}"/>')
    lines.append("</svg>")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def draw_tile(parts, palette, size: int):
    albedo = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    surface = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    albedo_draw = ImageDraw.Draw(albedo)
    surface_draw = ImageDraw.Draw(surface)
    for role, pts in parts:
        colour = palette[role]
        mask = SURFACE[role]
        scaled = [(x * size, y * size) for x, y in pts]
        albedo_draw.polygon(
            scaled,
            fill=(to_byte(colour[0]), to_byte(colour[1]), to_byte(colour[2]), 255),
        )
        surface_draw.polygon(
            scaled,
            fill=(to_byte(mask[0]), to_byte(mask[1]), to_byte(mask[2]), to_byte(mask[3])),
        )
    return albedo, surface


def downsample(image: Image.Image, target: int) -> Image.Image:
    """Premultiplied resize so transparent margins never darken tile edges."""
    data = np.asarray(image, dtype=np.float64) / 255.0
    alpha = data[:, :, 3:4]
    premultiplied = np.concatenate([data[:, :, :3] * alpha, alpha], axis=2)
    small = Image.fromarray(
        np.clip(premultiplied * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGBA"
    ).resize((target, target), Image.LANCZOS)
    out = np.asarray(small, dtype=np.float64) / 255.0
    out_alpha = np.clip(out[:, :, 3:4], 0.0, 1.0)
    rgb = np.where(out_alpha > 1.0e-6, out[:, :, :3] / np.maximum(out_alpha, 1.0e-6), 0.0)
    combined = np.concatenate([np.clip(rgb, 0.0, 1.0), out_alpha], axis=2)
    return Image.fromarray(np.clip(combined * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGBA")


def rasterize_svg_with_inkscape(svg_path: Path, size: int) -> Image.Image:
    executable = shutil.which("inkscape")
    if executable is None:
        raise SystemExit(
            "--from-svg requires the Inkscape CLI for artist-supplied vectors; "
            "install Inkscape or omit --from-svg to use the authored generator."
        )
    out_path = svg_path.with_suffix(".raster.png")
    subprocess.run(
        [
            executable,
            f"--export-filename={out_path}",
            f"--export-width={size}",
            f"--export-height={size}",
            str(svg_path),
        ],
        check=True,
        capture_output=True,
    )
    with Image.open(out_path) as raster:
        image = raster.convert("RGBA").copy()
    out_path.unlink()
    return image


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--from-svg",
        action="store_true",
        help="Rasterize the SVG sources with Inkscape instead of the built-in "
        "authored generator. Fails closed when Inkscape is unavailable.",
    )
    parser.add_argument("--tile-size", type=int, default=TILE_SIZE)
    args = parser.parse_args()

    tile = args.tile_size
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    GENERATED_DIR.mkdir(parents=True, exist_ok=True)

    atlas_w = ATLAS_COLUMNS * tile
    atlas_h = ATLAS_ROWS * tile
    albedo_atlas = Image.new("RGBA", (atlas_w, atlas_h), (0, 0, 0, 0))
    surface_atlas = Image.new("RGBA", (atlas_w, atlas_h), (0, 0, 0, 0))

    tiles_meta = []
    source_hashes = {}
    for era in range(len(ERA_BANDS)):
        for archetype in range(len(ARCHETYPES)):
            for variant in range(VARIANT_COUNT):
                index = tile_index(era, archetype, variant)
                name = tile_name(era, archetype, variant)
                parts = tile_parts(era, archetype, variant)
                palette = PALETTES[era]
                svg_path = SOURCE_DIR / f"{name}.svg"
                write_svg(svg_path, parts, palette)
                source_hashes[svg_path.name] = file_hash(svg_path)

                if args.from_svg:
                    albedo_tile = rasterize_svg_with_inkscape(svg_path, tile)
                    _, surface_full = draw_tile(parts, palette, tile * SUPERSAMPLE)
                    surface_tile = downsample(surface_full, tile)
                else:
                    albedo_full, surface_full = draw_tile(parts, palette, tile * SUPERSAMPLE)
                    albedo_tile = downsample(albedo_full, tile)
                    surface_tile = downsample(surface_full, tile)

                column = index % ATLAS_COLUMNS
                row = index // ATLAS_COLUMNS
                origin = (column * tile, row * tile)
                albedo_atlas.paste(albedo_tile, origin)
                surface_atlas.paste(surface_tile, origin)
                tiles_meta.append(
                    {
                        "index": index,
                        "name": name,
                        "era_band": ERA_BANDS[era],
                        "archetype": ARCHETYPES[archetype],
                        "variant": variant,
                        "column": column,
                        "row": row,
                        "polygon_count": len(parts),
                    }
                )

    albedo_path = GENERATED_DIR / "building_albedo.png"
    surface_path = GENERATED_DIR / "building_surface.png"
    albedo_atlas.save(albedo_path)
    surface_atlas.save(surface_path)

    expected = len(ERA_BANDS) * len(ARCHETYPES) * VARIANT_COUNT
    if len(tiles_meta) != expected or expected != ATLAS_COLUMNS * ATLAS_ROWS:
        raise SystemExit(f"tile count mismatch: {len(tiles_meta)} vs {expected}")
    alpha = np.asarray(albedo_atlas, dtype=np.uint8)[:, :, 3]
    if int(alpha.max()) != 255 or float(alpha.mean()) <= 1.0:
        raise SystemExit("authored albedo atlas has no usable silhouette coverage")

    manifest = {
        "layout_version": LAYOUT_VERSION,
        "atlas_columns": ATLAS_COLUMNS,
        "atlas_rows": ATLAS_ROWS,
        "tile_size": tile,
        "atlas_size": [atlas_w, atlas_h],
        "era_bands": ERA_BANDS,
        "runtime_era_to_band": RUNTIME_ERA_TO_BAND,
        "archetypes": ARCHETYPES,
        "variant_count": VARIANT_COUNT,
        "tile_index_formula": "era_band * %d + archetype * %d + variant"
        % (len(ARCHETYPES) * VARIANT_COUNT, VARIANT_COUNT),
        "albedo": "generated/building_albedo.png",
        "surface": "generated/building_surface.png",
        "channels": {
            "albedo": "RGB flat authored colour, A silhouette",
            "surface_r": "up-facing snow acceptance",
            "surface_g": "wetness response",
            "surface_b": "window emission",
            "surface_a": "ambient occlusion / occupancy aid",
        },
        "baked_shadow": False,
        "orientation": "fixed top-down, foundation at bottom",
        "tiles": tiles_meta,
        "source_hashes": source_hashes,
        "output_hashes": {
            "building_albedo.png": file_hash(albedo_path),
            "building_surface.png": file_hash(surface_path),
        },
    }
    MANIFEST_PATH.write_text(
        json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(
        f"authored {len(tiles_meta)} tiles -> {atlas_w}x{atlas_h} "
        f"albedo={albedo_path.stat().st_size} bytes surface={surface_path.stat().st_size} bytes"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

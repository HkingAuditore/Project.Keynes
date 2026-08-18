import math
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from map_authoring.ctx import AuthoringContext
from map_authoring.errors import AuthoringError
from map_authoring.hints import compile_hints
from map_authoring.pkauth import read_pkauth, write_pkauth


def _flat(width, height, value):
    return [value] * (width * height)


class HintTests(unittest.TestCase):
    def test_size_mismatch(self):
        with self.assertRaises(AuthoringError) as ctx:
            compile_hints({"elevation": [0.4, 0.4]}, 4, 4, 1, 0.5)
        self.assertEqual(ctx.exception.code, "size_mismatch")

    def test_nan_elevation(self):
        elev = _flat(12, 8, 0.4)
        elev[3] = float("nan")
        with self.assertRaises(AuthoringError) as ctx:
            compile_hints({"elevation": elev}, 12, 8, 1, 0.5)
        self.assertEqual(ctx.exception.code, "nan_elevation")

    def test_wrap_seam_cliff(self):
        width, height = 16, 10
        elev = []
        for row in range(height):
            for col in range(width):
                elev.append(0.85 if col == 0 else 0.20)
        with self.assertRaises(AuthoringError) as ctx:
            compile_hints({"elevation": elev, "sea_level": 0.5}, width, height, 1, 0.5)
        self.assertEqual(ctx.exception.code, "wrap_seam_cliff")

    def test_river_no_outlet(self):
        width, height = 20, 12
        elev = []
        for row in range(height):
            for col in range(width):
                ny = row / float(height - 1)
                nx = col / float(width)
                d = math.hypot(nx - 0.5, ny - 0.5)
                elev.append(0.72 if d < 0.28 else 0.22)
        river = [[10, 6], [11, 6], [12, 6]]
        with self.assertRaises(AuthoringError) as ctx:
            compile_hints(
                {
                    "elevation": elev,
                    "sea_level": 0.5,
                    "hints": {"carve_rivers": [{"cells": river, "depth": 0.04}]},
                },
                width,
                height,
                1,
                0.5,
            )
        self.assertEqual(ctx.exception.code, "river_no_outlet")

    def test_land_ratio_out_of_range(self):
        with self.assertRaises(AuthoringError) as ctx:
            compile_hints({"elevation": _flat(12, 8, 0.12), "sea_level": 0.5}, 12, 8, 1, 0.5)
        self.assertEqual(ctx.exception.code, "land_ratio_out_of_range")

    def test_cylinder_seam_matches(self):
        ctx = AuthoringContext(48, 24, 7, 0.5)
        a = ctx.fbm(0, 10, 1, 2.0, 4)
        b = ctx.fbm(48, 10, 1, 2.0, 4)
        self.assertAlmostEqual(a, b, places=6)

    def test_pkauth_roundtrip(self, tmp_name="pkauth_roundtrip.pkauth"):
        width, height = 12, 8
        elev = []
        for row in range(height):
            for col in range(width):
                nx = col / float(width)
                ny = row / float(height - 1)
                d = min(abs(nx - 0.5), 1.0 - abs(nx - 0.5))
                blob = 1.0 if (d < 0.22 and 0.25 < ny < 0.75) else 0.0
                elev.append(0.32 + blob * 0.36)
        compiled = compile_hints({"elevation": elev, "sea_level": 0.5, "hints": {}}, width, height, 9, 0.5)
        path = Path(__file__).resolve().parent / tmp_name
        write_pkauth(path, compiled)
        loaded = read_pkauth(path)
        path.unlink(missing_ok=True)
        self.assertEqual(loaded["n_cells"], width * height)
        self.assertEqual(len(loaded["elevation"]), width * height)
        self.assertAlmostEqual(loaded["elevation"][0], compiled["elevation"][0], places=5)


if __name__ == "__main__":
    unittest.main()

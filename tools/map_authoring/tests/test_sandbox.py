import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from map_authoring.errors import AuthoringError
from map_authoring.sandbox import run_author_script


class SandboxTests(unittest.TestCase):
    def test_rejects_import(self):
        src = "import os\ndef generate(ctx):\n    return {'elevation': [0.5] * (ctx.width * ctx.height)}\n"
        with self.assertRaises(AuthoringError) as ctx:
            run_author_script(src, 12, 8, 1, 0.5)
        self.assertEqual(ctx.exception.code, "sandbox_forbidden")

    def test_rejects_open(self):
        src = "def generate(ctx):\n    open('x')\n    return {'elevation': [0.5] * (ctx.width * ctx.height)}\n"
        with self.assertRaises(AuthoringError) as ctx:
            run_author_script(src, 12, 8, 1, 0.5)
        self.assertEqual(ctx.exception.code, "sandbox_forbidden")

    def test_generate_runs(self):
        src = (
            "def generate(ctx):\n"
            "    n = ctx.width * ctx.height\n"
            "    return {'elevation': [0.4] * n, 'sea_level': ctx.sea_level, 'hints': {}}\n"
        )
        result = run_author_script(src, 12, 8, 1, 0.5)
        self.assertEqual(len(result["elevation"]), 96)


if __name__ == "__main__":
    unittest.main()

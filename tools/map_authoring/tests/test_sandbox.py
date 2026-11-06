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

    def test_rejects_object_introspection(self):
        src = (
            "def generate(ctx):\n"
            "    builtins = ctx.__class__.__init__.__globals__[\"__builtins__\"]\n"
            "    builtins[\"open\"]('outside-sandbox')\n"
            "    return {'elevation': [0.5] * (ctx.width * ctx.height)}\n"
        )
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

    def test_rejects_frame_and_format_access(self):
        for expression in [
            "ctx.cells().gi_frame.f_globals",
            "'{0.__class__}'.format(ctx)",
            "getattr(ctx, '_' + '_class__')",
        ]:
            with self.subTest(expression=expression), self.assertRaises(AuthoringError) as caught:
                run_author_script("def generate(ctx):\n    return {'escape': " + expression + "}\n", 2, 2, 1, 0.5)
            self.assertEqual(caught.exception.code, "sandbox_forbidden")

    def test_rejects_unlisted_syntax_and_context_mutation(self):
        for source in [
            "class Escape:\n    pass\ndef generate(ctx):\n    return {}\n",
            "def generate(ctx):\n    ctx.width = 0\n    return {}\n",
            "@print\ndef generate(ctx):\n    return {}\n",
        ]:
            with self.subTest(source=source), self.assertRaises(AuthoringError) as caught:
                run_author_script(source, 2, 2, 1, 0.5)
            self.assertEqual(caught.exception.code, "sandbox_forbidden")

    def test_result_must_be_data(self):
        with self.assertRaises(AuthoringError) as caught:
            run_author_script("def generate(ctx):\n    return {'object': ctx}\n", 2, 2, 1, 0.5)
        self.assertEqual(caught.exception.code, "result_not_json")

    def test_comments_do_not_trigger_forbidden_tokens(self):
        result = run_author_script("# import open( is not code\ndef generate(ctx):\n    return {'note': 'open('}\n", 2, 2, 1, 0.5)
        self.assertEqual(result["note"], "open(")

    def test_shipped_examples_keep_their_numeric_results(self):
        # The checked-in fixtures are trusted. Execute them unrestricted only
        # here to compare the restricted path's arrays and nested hint data.
        from map_authoring.ctx import AuthoringContext
        examples = Path(__file__).resolve().parents[1] / "examples"
        for name, width, height in [("two_continents.py", 60, 40), ("earth_like.py", 100, 64)]:
            with self.subTest(name=name):
                source = (examples / name).read_text()
                namespace = {}
                exec(compile(source, str(examples / name), "exec"), namespace)
                expected = namespace["generate"](AuthoringContext(width, height, 1, 0.5))
                self.assertEqual(run_author_script(source, width, height, 1, 0.5), expected)


if __name__ == "__main__":
    unittest.main()

"""Restricted execution of author generate(ctx) scripts.

This is deliberately a small language implemented as a validated Python AST.
The worker process is still useful for time limits, but it is not treated as a
security boundary: the AST validator and the tiny builtins table are the
boundary.  Results cross the process boundary as JSON, never as pickle.
"""

from __future__ import annotations

import ast
import json
import multiprocessing as mp
import os
import tempfile
from pathlib import Path
from typing import Any

from .ctx import AuthoringContext
from .errors import AuthoringError

_SAFE_BUILTINS = {
    "abs": abs,
    "min": min,
    "max": max,
    "range": range,
    "len": len,
    "float": float,
    "int": int,
    "list": list,
    "dict": dict,
    "tuple": tuple,
    "enumerate": enumerate,
    "zip": zip,
    "True": True,
    "False": False,
    "None": None,
    "round": round,
    "sum": sum,
    "print": print,
}

_FORBIDDEN_NAMES = {
    "__builtins__", "__import__", "eval", "exec", "compile", "open",
    "input", "globals", "locals", "vars", "getattr", "setattr",
    "delattr", "breakpoint", "help",
}

# Positive lists are intentional: new Python syntax and introspection surfaces
# (gi_frame, f_globals, cr_frame, format, ...) must not become available merely
# because they do not start with an underscore.
_ALLOWED_NODES = (
    ast.Module, ast.FunctionDef, ast.arguments, ast.arg, ast.Return,
    ast.Assign, ast.AugAssign, ast.Expr, ast.If, ast.For, ast.While,
    ast.Break, ast.Continue, ast.Pass, ast.Name, ast.Constant,
    ast.List, ast.Tuple, ast.Dict, ast.Set, ast.Subscript, ast.Slice,
    ast.Attribute, ast.Call, ast.keyword, ast.Starred,
    ast.BinOp, ast.UnaryOp, ast.BoolOp, ast.Compare, ast.IfExp,
    ast.ListComp, ast.SetComp, ast.DictComp, ast.GeneratorExp, ast.comprehension,
    ast.Load, ast.Store, ast.operator, ast.unaryop, ast.boolop, ast.cmpop,
)
_ALLOWED_ATTRIBUTES = {
    "width", "height", "seed", "sea_level", "index", "nx", "ny", "cells",
    "clamp", "lerp", "smoothstep", "cyl_dist", "fbm", "ridged",
    "append", "extend", "insert", "pop", "remove", "clear", "copy",
    "count", "reverse", "sort", "get", "keys", "values", "items",
    "update", "setdefault",
}


class _AuthorAstGuard(ast.NodeVisitor):
    """Reject Python escape hatches while retaining the authoring examples."""

    def __init__(self) -> None:
        self.errors: list[str] = []

    def generic_visit(self, node: ast.AST) -> None:
        if not isinstance(node, _ALLOWED_NODES):
            self.errors.append(type(node).__name__)
            return
        super().generic_visit(node)

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:  # noqa: N802
        if node.decorator_list or node.name.startswith("__"):
            self.errors.append("decorated/private function")
        self.generic_visit(node)

    def visit_Import(self, node: ast.Import) -> None:  # noqa: N802
        self.errors.append("import")

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:  # noqa: N802
        self.errors.append("import")

    def visit_Attribute(self, node: ast.Attribute) -> None:  # noqa: N802
        if node.attr not in _ALLOWED_ATTRIBUTES or not isinstance(node.ctx, ast.Load):
            self.errors.append("attribute %s" % node.attr)
        self.generic_visit(node)

    def visit_Name(self, node: ast.Name) -> None:  # noqa: N802
        if node.id in _FORBIDDEN_NAMES or node.id.startswith("__"):
            self.errors.append(node.id)
        self.generic_visit(node)


def _compile_author_source(source: str):
    try:
        tree = ast.parse(source, filename="<author.py>", mode="exec")
    except SyntaxError as exc:
        raise AuthoringError("sandbox_syntax", str(exc)) from exc
    guard = _AuthorAstGuard()
    guard.visit(tree)
    if guard.errors:
        raise AuthoringError("sandbox_forbidden", "script uses %s" % guard.errors[0])
    return compile(tree, "<author.py>", "exec")


def _worker(out_path: str, source: str, params: dict) -> None:
    payload: dict[str, Any]
    try:
        code = _compile_author_source(source)
        ns: dict = {"__builtins__": _SAFE_BUILTINS}
        exec(code, ns, ns)
        gen = ns.get("generate")
        if not callable(gen):
            payload = {"ok": False, "code": "missing_generate", "message": "script must define generate(ctx)"}
            Path(out_path).write_text(json.dumps(payload), encoding="utf-8")
            return
        ctx = AuthoringContext(
            int(params["width"]),
            int(params["height"]),
            int(params["seed"]),
            float(params["sea_level"]),
        )
        result = gen(ctx)
        if not isinstance(result, dict):
            payload = {"ok": False, "code": "generate_not_dict", "message": "generate(ctx) must return a dict"}
            Path(out_path).write_text(json.dumps(payload), encoding="utf-8")
            return
        payload = {"ok": True, "result": result}
    except AuthoringError as exc:
        payload = {"ok": False, "code": exc.code, "message": exc.message}
    except Exception as exc:
        payload = {"ok": False, "code": "script_exception", "message": "%s: %s" % (type(exc).__name__, exc)}
    try:
        Path(out_path).write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    except (TypeError, ValueError) as exc:
        Path(out_path).write_text(json.dumps({
            "ok": False,
            "code": "result_not_json",
            "message": str(exc),
        }), encoding="utf-8")


def run_author_script(
    source: str,
    width: int,
    height: int,
    seed: int,
    sea_level: float,
    timeout_sec: float = 5.0,
) -> dict:
    fd, out_path = tempfile.mkstemp(prefix="pkauth_sandbox_", suffix=".json")
    os.close(fd)
    try:
        ctx = mp.get_context("spawn")
        proc = ctx.Process(
            target=_worker,
            args=(out_path, source, {
                "width": width,
                "height": height,
                "seed": seed,
                "sea_level": sea_level,
            }),
        )
        proc.start()
        proc.join(timeout_sec)
        if proc.is_alive():
            proc.terminate()
            proc.join(1.0)
            raise AuthoringError("sandbox_timeout", "author script exceeded %.1fs" % timeout_sec)
        data = Path(out_path).read_text(encoding="utf-8")
        if not data:
            raise AuthoringError("sandbox_no_result", "author script produced no result")
        try:
            payload = json.loads(data)
        except json.JSONDecodeError as exc:
            raise AuthoringError("sandbox_result_invalid", "author script produced invalid JSON") from exc
        if not isinstance(payload, dict):
            raise AuthoringError("sandbox_result_invalid", "author script result must be an object")
        if not bool(payload.get("ok", False)):
            raise AuthoringError(str(payload.get("code", "sandbox_failed")), str(payload.get("message", "")))
        if not isinstance(payload.get("result"), dict):
            raise AuthoringError("sandbox_result_invalid", "generate(ctx) result must be an object")
        return payload["result"]
    finally:
        try:
            os.remove(out_path)
        except OSError:
            pass

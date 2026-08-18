"""Restricted exec of author generate(ctx). No import/open; 5s timeout."""

from __future__ import annotations

import multiprocessing as mp
import os
import pickle
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


def _worker(out_path: str, source: str, params: dict) -> None:
    payload: dict[str, Any]
    try:
        forbidden = ("import ", "__import__", "open(", "exec(", "eval(", "compile(")
        for token in forbidden:
            if token in source:
                payload = {"ok": False, "code": "sandbox_forbidden", "message": "script uses %s" % token.strip()}
                Path(out_path).write_bytes(pickle.dumps(payload, protocol=4))
                return
        ns: dict = {"__builtins__": _SAFE_BUILTINS}
        exec(compile(source, "<author.py>", "exec"), ns, ns)
        gen = ns.get("generate")
        if not callable(gen):
            payload = {"ok": False, "code": "missing_generate", "message": "script must define generate(ctx)"}
            Path(out_path).write_bytes(pickle.dumps(payload, protocol=4))
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
            Path(out_path).write_bytes(pickle.dumps(payload, protocol=4))
            return
        payload = {"ok": True, "result": result}
    except Exception as exc:
        payload = {"ok": False, "code": "script_exception", "message": "%s: %s" % (type(exc).__name__, exc)}
    Path(out_path).write_bytes(pickle.dumps(payload, protocol=4))


def run_author_script(
    source: str,
    width: int,
    height: int,
    seed: int,
    sea_level: float,
    timeout_sec: float = 5.0,
) -> dict:
    fd, out_path = tempfile.mkstemp(prefix="pkauth_sandbox_", suffix=".pkl")
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
        data = Path(out_path).read_bytes()
        if not data:
            raise AuthoringError("sandbox_no_result", "author script produced no result")
        payload = pickle.loads(data)
        if not bool(payload.get("ok", False)):
            raise AuthoringError(str(payload.get("code", "sandbox_failed")), str(payload.get("message", "")))
        return payload["result"]
    finally:
        try:
            os.remove(out_path)
        except OSError:
            pass

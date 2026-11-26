#!/usr/bin/env python3
"""Drop FmodGodot from the exported web shell's `gdextensionLibs`.

Why: `audio_backend_policy.gd` decides Web uses Godot's built-in mixer and never
FMOD. But the Web preset still ships the FmodGodot extension, the export writes it
into `GODOT_CONFIG.gdextensionLibs`, and the engine loads it at boot anyway. Its
AudioWorklet then runs and, on the first real user gesture
(`Resetting audio driver based on user input`), calls
`FMOD_JS_MixerFastpathFunction` — which the side module built from source does not
export — and aborts the audio thread. 2026-11-26: 1026 errors within 13 s of one
click, while the same page is clean until something is clicked.

So the shell must not list it. `libdots_ext` stays.

Idempotent: if the entry is already gone it prints that and exits 0. If the
`gdextensionLibs` array cannot be found at all it exits non-zero — that means the
export template changed and this patch silently stopped applying.

Usage:
    python tools/patch_web_no_fmod.py --html WebBuild/ProjectKeynes.html
"""
from __future__ import annotations

import argparse
import json
import re
import sys

ARRAY_RE = re.compile(r'"gdextensionLibs"\s*:\s*\[(?P<body>[^\]]*)\]')
KEEP = "libdots_ext"
DROP = "libFmodGodot"


def strip_fmod(html: str) -> tuple[str, str]:
    """Return (new_html, status) where status is kept/dropped/missing."""
    match = ARRAY_RE.search(html)
    if match is None:
        raise SystemExit("gdextensionLibs array not found in the exported html; "
                         "the export template changed — update this patch")
    body = match.group("body")
    entries = [e.strip() for e in body.split(",") if e.strip()]
    kept = [e for e in entries if DROP not in e]
    if len(kept) == len(entries):
        return html, "already-clean"
    if not any(KEEP in e for e in kept):
        raise SystemExit(f"refusing to patch: {KEEP} would disappear from gdextensionLibs")
    new_array = '"gdextensionLibs":[' + ",".join(kept) + "]"
    new_html = html[:match.start()] + new_array + html[match.end():]
    return new_html, "dropped"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--html", required=True, help="exported ProjectKeynes.html")
    args = ap.parse_args(argv)

    path = __import__("pathlib").Path(args.html)
    original = path.read_text(encoding="utf-8")
    patched, status = strip_fmod(original)

    if status == "dropped":
        path.write_text(patched, encoding="utf-8")
    final = path.read_text(encoding="utf-8")

    # Independent verification, not just "we wrote something".
    check = ARRAY_RE.search(final)
    libs = []
    if check is not None:
        libs = [e.strip().strip('"') for e in check.group("body").split(",") if e.strip()]
    ok = (DROP not in final) and any(KEEP in lib for lib in libs)
    print(f"[html-no-fmod] status={status} libs={libs} bytes={len(final.encode('utf-8'))} ok={ok}")
    if not ok:
        print("[html-no-fmod] FAILED verification", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

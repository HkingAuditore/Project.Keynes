#!/usr/bin/env python3
"""Expose FMOD side-module exports on the emscripten Module object (Web only).

Why this is needed
------------------
FMOD's HTML5 AudioWorklet output is JS that FMOD embeds as `emscripten_asm_const`
strings (inside `fmod_output_audioworklet.o`). That JS does:

    Module.FMOD_JS_MixerFastpathFunction = Module["cwrap"]('FMOD_JS_MixerFastpathFunction', 'void', ['number']);

and `cwrap` resolves through `getCFunc = ident => Module["_" + ident]`.
`FMOD_JS_MixFunction` / `FMOD_JS_MixerFastpathFunction` / `FMOD_JS_MixerSlowpathFunction`
are *wasm exports of the FMOD side module*. Emscripten's dylink merges side-module
exports into `wasmImports` and the GOT (`mergeLibSymbols`), but never into the
`Module` object, so `cwrap` throws:

    Aborted(Assertion failed: Cannot call unknown func__MixerFastpathFunction, make sure it is exported)

This post-export patch hooks `mergeLibSymbols` inside the generated engine JS and
copies `FMOD_JS_*` exports onto `Module["_"+name]` at side-module load time.

Usage
-----
    python tools/sb_patch_web_fmod_bridge.py WebBuild            # dir with ProjectKeynes.js
    python tools/sb_patch_web_fmod_bridge.py WebBuild ProjectKeynes.js

Idempotent. Exits 1 if the anchor changes (new engine version) so a silent
mismatch never ships.
"""
from __future__ import annotations

import sys
import pathlib

ANCHOR = 'mergeLibSymbols=(exports,libName)=>{for(var[sym,exp]of Object.entries(exports)){'
INJECT = 'if(sym.indexOf("FMOD_JS_")===0){Module["_"+sym]=exp}'
MARK = 'if(sym.indexOf("FMOD_JS_")===0)'


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    target = pathlib.Path(args[0])
    if target.is_dir():
        name = args[1] if len(args) > 1 else "ProjectKeynes.js"
        target = target / name
    if not target.exists():
        print(f"missing: {target}")
        return 1
    text = target.read_text(encoding="utf-8", errors="replace")
    if MARK in text:
        print(f"already patched: {target}")
        return 0
    hits = text.count(ANCHOR)
    if hits != 1:
        print(f"anchor count {hits} != 1 -- engine JS layout changed, update ANCHOR: {target}")
        return 1
    patched = text.replace(ANCHOR, ANCHOR + INJECT)
    target.write_text(patched, encoding="utf-8", newline="")
    print(f"patched {target} ({len(text)} -> {len(patched)} chars)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

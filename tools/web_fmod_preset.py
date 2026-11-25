#!/usr/bin/env python3
"""Temporarily shape export_presets.cfg for the FMOD web export, then restore it.

Why this exists
---------------
Two preset edits are needed for a web package that actually has FMOD audio:

1. `variant/thread_support=true`
   FMOD's HTML5 libraries are pthreads-only, so the engine must be the
   multi-threaded web variant.

2. `exclude_filter`: `addons/FmodGodot/*` -> only `bin/android/*`,
   `bin/windows/*`, `icons/*`
   A blanket `addons/FmodGodot/*` exclusion makes the web exporter skip the
   extension's library registration, so the side module never lands in
   `GODOT_CONFIG.gdextensionLibs`. Without that preload entry `dlopen` tries a
   synchronous fetch, which emscripten 4.0.20 refuses
   ("synchronous loading of external files is not available").

Both must *not* be permanent: a `PK_WEB_SKIP_FMOD=1` single-threaded package must
keep the blanket exclusion and `thread_support=false`, otherwise FmodGodot enters
the pck and the nothreads engine tries to load a pthreads side module.

So: `begin` before the FMOD export, `end` after. Byte-exact restore. If someone
else edits the preset while `begin` is active, `end` refuses to overwrite and
keeps the backup instead.

Usage
-----
    python tools/web_fmod_preset.py begin [--preset PATH] [--state PATH]
    python tools/web_fmod_preset.py end
    python tools/web_fmod_preset.py status
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_PRESET = ROOT / "Project" / "project-keynes" / "export_presets.cfg"
DEFAULT_STATE = ROOT / "tmp" / "web_fmod_preset_state.json"
WIDE = "addons/FmodGodot/*"
NARROW = "addons/FmodGodot/bin/android/*, addons/FmodGodot/bin/windows/*, addons/FmodGodot/icons/*"
THREAD_OFF = "variant/thread_support=false"
THREAD_ON = "variant/thread_support=true"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_state(state: pathlib.Path) -> dict | None:
    if not state.exists():
        return None
    try:
        return json.loads(state.read_text(encoding="utf-8"))
    except Exception:
        return None


def begin(preset: pathlib.Path, state: pathlib.Path) -> int:
    raw = preset.read_bytes()
    original_sha = sha(raw)
    # Idempotent: Build-Web may run -EnableOnly more than once before -RestoreOnly.
    # A second begin must not overwrite the backup with the already-flipped file
    # (that would make `end` "restore" the flipped preset and leave the repo wrong).
    prev = read_state(state)
    if prev:
        if original_sha == prev.get("written_sha"):
            print("[preset] begin: already active; keeping the original backup")
            return 0
        print("[preset] WARNING: a previous begin is still active but export_presets.cfg changed "
              f"since (expected {str(prev.get('written_sha'))[:8]}, now {original_sha[:8]}).")
        print(f"  refusing to re-baseline; run `end` first (backup: {prev.get('backup')})")
        return 1
    text = raw.decode("utf-8")
    changed = []
    if THREAD_OFF in text:
        text = text.replace(THREAD_OFF, THREAD_ON)
        changed.append("thread_support=true")
    if WIDE in text:
        text = text.replace(WIDE, NARROW)
        changed.append("FmodGodot exclude narrowed")
        # The web preset already lists addons/FmodGodot/bin/android/* separately, so the
        # replacement above can duplicate it. Dedupe every exclude_filter value that
        # mentions FmodGodot (other presets keep their own lists untouched).
        def _dedupe(m):
            if "FmodGodot" not in m.group(2):
                return m.group(0)
            seen, out = set(), []
            for tok in m.group(2).split(", "):
                tok = tok.strip()
                if tok and tok not in seen:
                    seen.add(tok)
                    out.append(tok)
            return m.group(1) + ", ".join(out) + '"'

        text = re.sub(r'(exclude_filter=")([^"]*)"', _dedupe, text)
    if not changed:
        print("[preset] already in FMOD-web shape (nothing to do)")
    new_raw = text.encode("utf-8")
    backup = state.with_suffix(".bak")
    backup.parent.mkdir(parents=True, exist_ok=True)
    backup.write_bytes(raw)
    preset.write_bytes(new_raw)
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps({
        "preset": str(preset),
        "backup": str(backup),
        "original_sha": original_sha,
        "written_sha": sha(new_raw),
        "changes": changed,
    }, indent=2), encoding="utf-8")
    print(f"[preset] begin: {', '.join(changed) if changed else 'no change'}; "
          f"sha {original_sha[:8]} -> {sha(new_raw)[:8]}")
    return 0


def end(preset: pathlib.Path, state: pathlib.Path) -> int:
    st = read_state(state)
    if not st:
        print("[preset] end: no state file (nothing to restore)")
        return 0
    if not preset.exists():
        print(f"[preset] end: preset missing at {preset}")
        return 1
    cur = sha(preset.read_bytes())
    if cur != st["written_sha"]:
        print("[preset] WARNING: export_presets.cfg changed while the FMOD export was active; "
              "refusing to overwrite. Re-apply the FMOD shape manually if needed.")
        print(f"  original sha {st['original_sha'][:8]}, expected {st['written_sha'][:8]}, now {cur[:8]}")
        # keep state so a human can inspect
        return 1
    # Restore the exact bytes captured by `begin` (not by reversing the text edits:
    # the exclude dedupe makes the narrowed string non-contiguous, so reverse
    # replacement cannot be exact).
    backup = pathlib.Path(st.get("backup", ""))
    if not backup.exists():
        print(f"[preset] end: backup missing at {backup}")
        return 1
    preset.write_bytes(backup.read_bytes())
    restored = sha(preset.read_bytes())
    if restored != st["original_sha"]:
        print(f"[preset] WARNING: restored sha {restored[:8]} != original {st['original_sha'][:8]}")
        return 1
    state.unlink()
    print(f"[preset] end: restored, sha8={restored[:8]}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["begin", "end", "status"])
    ap.add_argument("--preset", default=str(DEFAULT_PRESET))
    ap.add_argument("--state", default=str(DEFAULT_STATE))
    a = ap.parse_args()
    preset, state = pathlib.Path(a.preset), pathlib.Path(a.state)
    if a.action == "begin":
        return begin(preset, state)
    if a.action == "end":
        return end(preset, state)
    st = read_state(state)
    if not st:
        print("[preset] status: idle")
        return 0
    print(f"[preset] status: active; original {st['original_sha'][:8]}, written {st['written_sha'][:8]}, "
          f"changes={st.get('changes')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

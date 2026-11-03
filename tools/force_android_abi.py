"""Force the Android preset to exactly one ABI and verify by re-reading the file.

This exists because `export_presets.cfg` gets rewritten by other processes while we
are working; a write that is not verified immediately is worthless. Run it, then
export **in the same command**, then check the produced APK's lib/<abi>/ directory.

Usage:
    python tools/force_android_abi.py x86_64
    python tools/force_android_abi.py arm64
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
PRESETS = REPO / "Project" / "project-keynes" / "export_presets.cfg"

WANT = {
    "arm64": {"arm64-v8a": "true", "x86_64": "false"},
    "x86_64": {"arm64-v8a": "false", "x86_64": "true"},
}


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in WANT:
        print(__doc__)
        return 2
    wanted = WANT[argv[1]]
    text = PRESETS.read_text(encoding="utf-8")

    start = text.index("[preset.1]")
    end = text.index("[preset.2]") if "[preset.2]" in text else len(text)
    block = text[start:end]
    for key, value in wanted.items():
        block = re.sub(r"architectures/%s=(?:true|false)" % re.escape(key),
                       "architectures/%s=%s" % (key, value), block)
    updated = text[:start] + block + text[end:]
    PRESETS.write_text(updated, encoding="utf-8")

    # Verify by re-reading from disk (the whole point of this script).
    verify = PRESETS.read_text(encoding="utf-8")[start:end]
    found = dict(re.findall(r"architectures/(arm64-v8a|x86_64)=(true|false)", verify))
    print("[abi] requested=%s" % argv[1])
    for key in ("arm64-v8a", "x86_64"):
        print("  %s=%s" % (key, found.get(key, "MISSING")))
    ok = all(found.get(key) == value for key, value in wanted.items())
    print("[abi] verified=%s" % ok)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

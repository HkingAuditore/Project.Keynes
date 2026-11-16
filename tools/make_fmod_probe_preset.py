"""Slice the game's Android export preset into the standalone FMOD probe project.

The probe only needs the Android platform block; it flips the ABI to x86_64 (the
emulator ABI) and clears command_line/extra_args so nothing forces --headless.
"""

from __future__ import annotations

import pathlib
import re

REPO = pathlib.Path(__file__).resolve().parents[1]
SRC = REPO / "Project" / "project-keynes" / "export_presets.cfg"
DST = REPO / "tmp" / "fmod_android_probe" / "export_presets.cfg"


def main() -> int:
    text = SRC.read_text(encoding="utf-8")
    start = text.index("[preset.1]")
    end = text.index("[preset.2]")
    block = text[start:end]

    block = block.replace("[preset.1.options]", "[preset.0.options]")
    block = block.replace("[preset.1]", "[preset.0]")
    block = block.replace('export_path="../../Build/ProjectKeynes.apk"', 'export_path="probe.apk"')
    block = block.replace('package/unique_name="com.projectkeynes.game"',
                          'package/unique_name="com.projectkeynes.fmodprobe"')
    block = block.replace('package/name="ProjectKeynes"', 'package/name="FmodProbe"')
    block = block.replace("architectures/arm64-v8a=true", "architectures/arm64-v8a=false")
    block = block.replace("architectures/x86_64=false", "architectures/x86_64=true")
    block = re.sub(r'command_line/extra_args="[^"]*"', 'command_line/extra_args=""', block)

    DST.write_text(block, encoding="utf-8")
    for line in block.splitlines():
        if any(key in line for key in ("architectures/", "extra_args", "export_path", "name=")):
            print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

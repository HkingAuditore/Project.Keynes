#!/usr/bin/env python3
"""Encode the map acceptance frame sequences as review GIFs.

The input frames are screenshots produced by
`military_formation_map_visual_harness.gd`. This tool only quantizes and packs
those frames; it does not render or alter any military artwork.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CAPTURE_DIR = (
    ROOT / "Project/project-keynes/tmp/military_formation_map_visual"
)
SEQUENCES = (
    ("idle", "12_game_map_idle_sequence"),
    ("move", "13_game_map_move_sequence"),
    ("attack", "14_game_map_attack_sequence"),
    ("hit", "15_game_map_hit_sequence"),
)
FRAME_DURATION_MS = 125


def _load_frames(capture_dir: Path, sequence_dir: str) -> list[Image.Image]:
    directory = capture_dir / "sequences" / sequence_dir
    paths = [directory / f"frame_{index:02d}.png" for index in range(8)]
    missing = [path for path in paths if not path.is_file()]
    if missing:
        formatted = "\n".join(str(path) for path in missing)
        raise FileNotFoundError(f"missing map sequence frames:\n{formatted}")

    frames: list[Image.Image] = []
    for path in paths:
        with Image.open(path) as image:
            frames.append(image.convert("RGBA"))
    sizes = {frame.size for frame in frames}
    if len(sizes) != 1:
        raise ValueError(f"inconsistent frame sizes in {directory}: {sizes}")
    return frames


def _save_gif(frames: list[Image.Image], output: Path) -> None:
    rgb = [frame.convert("RGB") for frame in frames]
    rgb[0].save(
        output,
        format="GIF",
        save_all=True,
        append_images=rgb[1:],
        duration=FRAME_DURATION_MS,
        loop=0,
        disposal=2,
        optimize=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture-dir", type=Path, default=DEFAULT_CAPTURE_DIR)
    args = parser.parse_args()

    capture_dir = args.capture_dir.resolve()
    all_frames: list[Image.Image] = []
    for action, sequence_dir in SEQUENCES:
        frames = _load_frames(capture_dir, sequence_dir)
        output = capture_dir / f"military_formation_v4_{action}_map.gif"
        _save_gif(frames, output)
        all_frames.extend(frames)
        print(f"wrote {output} frames={len(frames)} size={frames[0].size}")

    overview = capture_dir / "military_formation_v4_all_actions_map.gif"
    _save_gif(all_frames, overview)
    print(
        f"wrote {overview} frames={len(all_frames)} "
        f"size={all_frames[0].size}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Build portable Vorbis assets from the lossless FMOD sources (no API calls).

Requires ffmpeg on PATH or `python -m pip install imageio-ffmpeg`.
Music stems are summed at unity gain, without normalization or resampling.
"""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Audio/ProjectKeynes/Assets"
OUTPUT = ROOT / "Project/project-keynes/assets/audio/native"


def encode(ffmpeg, inputs, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    for source in inputs:
        if not source.is_file():
            raise FileNotFoundError(source)
        args += ["-i", str(source)]
    if len(inputs) > 1:
        args += ["-filter_complex", f"amix=inputs={len(inputs)}:normalize=0"]
    args += ["-c:a", "libvorbis", "-q:a", "7", str(target)]
    subprocess.run(args, check=True)
    print(f"{target.relative_to(ROOT)}: {target.stat().st_size:,} bytes", flush=True)


def main():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        import imageio_ffmpeg
        ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    for era, prefix, roles in [
        ("stone", "stem_", ["base_core", "pop_rhythm", "pop_chorus"]),
        ("agrarian", "stem_agr_", ["base_core", "pop_rhythm", "pop_chorus"]),
        ("kingdom", "stem_kng_", ["base_core", "pulse", "theme", "color", "impact"]),
        ("empire", "stem_emp_", ["base_core", "pulse", "theme", "color", "impact"]),
    ]:
        encode(ffmpeg, [SOURCE / f"{prefix}{role}.wav" for role in roles],
               OUTPUT / "music" / f"{era}.ogg")
    for transition in ["stone_to_agrarian", "agrarian_to_kingdom", "kingdom_to_empire"]:
        encode(ffmpeg, [SOURCE / f"trans_{transition}.wav"],
               OUTPUT / "music" / f"trans_{transition}.ogg")
    for cue in ["click", "page", "open", "close", "confirm", "toggle_on", "toggle_off", "tick"]:
        encode(ffmpeg, [SOURCE / "UI" / f"{cue}.wav"], OUTPUT / "ui" / f"{cue}.ogg")
    progression = {"tech_start", "tech_research", "tech_cancel", "ideology_draw", "ideology_use",
                   "ideology_reroll", "ideology_reveal", "ideology_choose", "ideology_unequip",
                   "ideology_promote"}
    for cue in sorted(progression | {"territory_expand", "building_complete", "population_grow", "trade"}):
        folder = "progression" if cue in progression else "events"
        encode(ffmpeg, [SOURCE / "UI" / folder / f"{cue}.wav"], OUTPUT / "events" / f"{cue}.ogg")


if __name__ == "__main__":
    main()

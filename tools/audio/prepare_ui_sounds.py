"""Rebuild the small CC0 paper UI palette; requires FFmpeg on PATH.

Original files live in Audio/Sources/UI. No network or Studio metadata writes.
"""
import array
from pathlib import Path
import subprocess
import wave

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Audio/Sources/UI"
OUTPUT = ROOT / "Audio/ProjectKeynes/Assets/UI"
RATE = 48000
# cue: source, high pass, low pass, speed, peak dBFS, maximum seconds, reverse
RECIPES = {
    "click": ("kenney/click_001.ogg", 130, 4200, 1.0, -18, .07, False),
    "page": ("starninjas/book_flip.6.ogg", 170, 6500, 1.35, -16, .36, False),
    "open": ("starninjas/book_flip.4.ogg", 110, 5600, 1.2, -15, .48, False),
    "close": ("starninjas/book_flip.8.ogg", 150, 4600, 1.3, -17, .32, True),
    "confirm": ("kenney/drop_003.ogg", 65, 2200, .9, -14, .15, False),
    "toggle_on": ("kenney/toggle_001.ogg", 130, 3800, 1.1, -19, .14, False),
    "toggle_off": ("kenney/toggle_002.ogg", 100, 3000, .95, -20, .16, False),
    "tick": ("kenney/scratch_001.ogg", 300, 4500, 1.5, -24, .055, False),
}


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for cue, (source, high, low, speed, db, limit, reverse) in RECIPES.items():
        filters = f"highpass=f={high},lowpass=f={low},atempo={speed}"
        raw = subprocess.check_output([
            "ffmpeg", "-v", "error", "-i", str(SOURCE / source),
            "-af", filters, "-ar", str(RATE), "-ac", "1", "-f", "f32le", "-",
        ])
        samples = array.array("f", raw)
        peak = max(map(abs, samples))
        active = [i for i, value in enumerate(samples) if abs(value) > peak * .025]
        start = max(0, active[0] - int(.003 * RATE))
        end = min(len(samples), active[-1] + int(.018 * RATE))
        samples = samples[start:end][:int(limit * RATE)]
        if reverse:
            samples.reverse()
        gain = 10 ** (db / 20) / max(map(abs, samples))
        pcm = array.array("h")
        for i, value in enumerate(samples):
            # Short edge fades keep the dry material transients free of edit clicks.
            fade = min(1, i / (RATE * .001), (len(samples) - 1 - i) / (RATE * .012))
            pcm.append(round(max(-1, min(1, value * gain * fade)) * 32767))
        with wave.open(str(OUTPUT / (cue + ".wav")), "wb") as out:
            out.setparams((1, 2, RATE, len(pcm), "NONE", "not compressed"))
            out.writeframes(pcm.tobytes())
        print(f"{cue}: {len(pcm) / RATE:.3f}s, peak ceiling {db} dBFS")


if __name__ == "__main__":
    main()

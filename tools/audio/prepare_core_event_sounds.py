"""Add a restrained body and room tail to the seven core event cues.

The source cues remain the transient anchor.  The added layers are deterministic DSP, kept well below the
transient, so event sounds gain material weight without turning into a loud notification wall.
"""

from __future__ import annotations

import json
import math
import wave
from pathlib import Path

import numpy as np
from scipy import signal
from scipy.io import wavfile


SR = 48_000
ROOT = Path(__file__).resolve().parents[2]
EVENT_DIR = ROOT / "Audio" / "ProjectKeynes" / "Assets" / "UI" / "events"
EVENTS = {
    "tech_research.wav": (750.0, 0.22, 0.14),
    "territory_expand.wav": (420.0, 0.26, 0.18),
    "ideology_draw.wav": (620.0, 0.24, 0.16),
    "ideology_use.wav": (520.0, 0.28, 0.18),
    "building_complete.wav": (360.0, 0.30, 0.20),
    "population_grow.wav": (680.0, 0.20, 0.14),
    "trade.wav": (480.0, 0.26, 0.17),
}


def read(path: Path) -> np.ndarray:
    sr, data = wavfile.read(path)
    if sr != SR or data.dtype != np.int16:
        raise RuntimeError(f"{path}: expected 48 kHz int16 WAV, got {sr} {data.dtype}")
    data = data.astype(np.float64) / 32768.0
    if data.ndim == 1:
        data = np.repeat(data[:, None], 2, axis=1)
    return data


def write(path: Path, audio: np.ndarray, rng: np.random.Generator) -> None:
    tpdf = rng.random(audio.shape) - rng.random(audio.shape)
    pcm = np.clip(np.round(audio * 32767.0 + tpdf), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())


def process(source: np.ndarray, body_cutoff: float, body_gain: float, tail_gain: float) -> np.ndarray:
    body_sos = signal.butter(3, body_cutoff, btype="lowpass", fs=SR, output="sos")
    body = signal.sosfilt(body_sos, source, axis=0)
    body *= body_gain

    tail_len = int(round(0.24 * SR))
    tail = np.zeros((source.shape[0] + tail_len, 2), dtype=np.float64)
    tail[: source.shape[0]] += source * 0.12
    for delay_ms, gain in ((17, 0.60), (43, 0.38), (91, 0.22)):
        delay = int(round(delay_ms * SR / 1000.0))
        tail[delay: delay + source.shape[0]] += source * (tail_gain * gain)
    env = np.exp(-np.arange(tail.shape[0], dtype=np.float64) / (0.105 * SR))[:, None]
    tail *= env

    out = np.zeros_like(tail)
    out[: source.shape[0]] += source + body
    out += tail
    peak = float(np.max(np.abs(out)))
    if peak > 10.0 ** (-1.2 / 20.0):
        out *= 10.0 ** (-1.2 / 20.0) / peak
    return out


def main() -> None:
    rng = np.random.default_rng(20261023)
    manifest = {"sample_rate": SR, "ceiling_dbfs": -1.2, "events": {}}
    for name, (cutoff, body_gain, tail_gain) in EVENTS.items():
        path = EVENT_DIR / name
        source = read(path)
        processed = process(source, cutoff, body_gain, tail_gain)
        write(path, processed, rng)
        manifest["events"][name] = {"duration_seconds": round(processed.shape[0] / SR, 4), "body_cutoff_hz": cutoff}
    (EVENT_DIR / "core_event_sound_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print("CORE_EVENT_SOUNDS_OK=true")


if __name__ == "__main__":
    main()

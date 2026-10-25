"""Offline validation for the Kingdom/Empire five-role FMOD assets."""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from scipy.io import wavfile


SR = 48_000
ROLES = ("base_core", "pulse", "theme", "color", "impact")


def read(path: Path) -> np.ndarray:
    sr, data = wavfile.read(path)
    if sr != SR:
        raise AssertionError(f"{path}: expected {SR} Hz, got {sr}")
    if data.dtype != np.int16:
        raise AssertionError(f"{path}: expected int16 WAV, got {data.dtype}")
    data = data.astype(np.float64) / 32768.0
    if data.ndim == 1:
        data = np.repeat(data[:, None], 2, axis=1)
    if data.shape[1] != 2:
        raise AssertionError(f"{path}: expected stereo, got {data.shape[1]} channels")
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("Audio/ProjectKeynes/Assets"))
    args = parser.parse_args()
    root = args.root
    specs = (("kingdom", "stem_kng_", 166.0), ("empire", "stem_emp_", 165.0))
    for era, prefix, duration in specs:
        layers = [read(root / f"{prefix}{role}.wav") for role in ROLES]
        lengths = {layer.shape[0] for layer in layers}
        expected = int(round(duration * SR))
        if lengths != {expected}:
            raise AssertionError(f"{era}: role lengths {sorted(lengths)} != {expected}")
        full = sum(layers)
        reference = read(root / f"{prefix}reference_full_mix.wav") if (root / f"{prefix}reference_full_mix.wav").exists() else None
        if reference is not None and reference.shape != full.shape:
            raise AssertionError(f"{era}: reference shape {reference.shape} != {full.shape}")
        peak = float(np.max(np.abs(full)))
        if 20.0 * math.log10(peak + 1e-12) > -0.5:
            raise AssertionError(f"{era}: role sum peak too hot ({peak:.4f})")
        rms_share = np.asarray([np.mean(layer * layer) for layer in layers])
        rms_share /= np.sum(rms_share)
        print(f"{era}: sr={SR} length={duration:.1f}s energy_share="
              + ",".join(f"{role}={share * 100:.1f}%" for role, share in zip(ROLES, rms_share)))
    print("FIVE_STEM_ASSETS_OK=true")


if __name__ == "__main__":
    main()

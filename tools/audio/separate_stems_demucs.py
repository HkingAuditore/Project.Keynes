"""Local high-quality music source separation with Demucs (htdemucs_ft) on CUDA.

Run with the audio venv (D:/Godot/ProjectKeynes/tmp/audio_venv). Usage:
    python separate_stems_demucs.py <input_44k1.wav> <output_dir> [model_name]

Writes float32 WAV stems (drums/bass/other/vocals) at the input sample rate, sample-aligned with the input.
"""

from __future__ import annotations

import sys
import types
from pathlib import Path

import numpy as np
from scipy.io import wavfile


def _ensure_torchaudio_importable() -> None:
    # The system torchaudio native DLL is blocked on this machine; Demucs only needs it for file I/O,
    # which we do with scipy instead, so a stub module is enough for model inference.
    try:
        import torchaudio  # noqa: F401
    except Exception:
        for name in list(sys.modules):
            if name == "torchaudio" or name.startswith("torchaudio."):
                del sys.modules[name]
        stub = types.ModuleType("torchaudio")
        stub.__path__ = []  # type: ignore[attr-defined]
        sys.modules["torchaudio"] = stub
        for sub in ("transforms", "functional"):
            mod = types.ModuleType(f"torchaudio.{sub}")
            sys.modules[f"torchaudio.{sub}"] = mod
            setattr(stub, sub, mod)


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    in_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    model_name = sys.argv[3] if len(sys.argv) > 3 else "htdemucs_ft"
    out_dir.mkdir(parents=True, exist_ok=True)

    _ensure_torchaudio_importable()
    import torch
    from demucs.apply import apply_model
    from demucs.pretrained import get_model

    sr, data = wavfile.read(str(in_path))
    if data.dtype != np.float32:
        data = data.astype(np.float32) / (32768.0 if data.dtype == np.int16 else 1.0)
    if data.ndim == 1:
        data = np.stack([data, data], axis=1)

    model = get_model(model_name)
    if sr != model.samplerate:
        raise SystemExit(f"Input must be {model.samplerate} Hz, got {sr} Hz")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model.to(device)
    model.eval()

    wav = torch.from_numpy(data.T.copy())
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    wav_n = (wav - mean) / std
    with torch.no_grad():
        sources = apply_model(model, wav_n[None], device=device, shifts=2, split=True, overlap=0.25, progress=False)[0]
    sources = sources * std + mean

    for name, src in zip(model.sources, sources):
        arr = src.cpu().numpy().T.astype(np.float32)
        wavfile.write(str(out_dir / f"{name}.wav"), sr, arr)
        rms = 20.0 * np.log10(float(np.sqrt(np.mean(arr.astype(np.float64) ** 2))) + 1e-12)
        print(f"  [demucs] {name:7s} RMS={rms:6.1f} dBFS")


if __name__ == "__main__":
    main()

"""Generate cached, lossless technology/ideology one-shots for the existing UI bank."""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np
from scipy.io import wavfile

from generate_grand_strategy_music_elevenlabs import load_api_key, api_post_json

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Audio/ProjectKeynes/Assets/UI/progression"
CACHE = ROOT / ".codex-tmp/progression-sfx-elevenlabs"
STYLE = ("One isolated tactile historical strategy game interface sound, immediate onset, "
         "warm detailed natural materials, clean studio recording, short natural decay. "
         "No speech, no voices, no music bed, no electronic beeps, no background noise. ")
# duration, loudness: frequent gestures stay beneath completion and promotion cues.
CUES = {
    "tech_start": (0.9, -22, "A quill makes a decisive short inscription on parchment, followed by a tiny wooden stamp and a delicate bronze tick. Beginning a research project."),
    "tech_research": (2.2, -19, "A bright small bronze bell blooms above a warm struck glass resonance and a soft parchment flourish. A satisfying discovery, elegant and restrained, a single rising shimmer resolving warmly."),
    "tech_cancel": (0.6, -24, "A short dry parchment slip withdrawn from a wooden ledger, softly damped wooden tap at the end."),
    "ideology_draw": (1.4, -22, "A thick parchment scroll swiftly unrolls, three stiff paper cards slide across felt, a gentle airy anticipation flourish ending in a small wood knock."),
    "ideology_reroll": (1.0, -23, "A crisp parchment sheet tears once, followed immediately by a quick shuffle of three thick paper cards, intimate and restrained."),
    "ideology_reveal": (0.5, -25, "One stiff handmade paper card flips over with a crisp papery flutter and one very light delicate glass tick, extremely short and light."),
    "ideology_choose": (1.0, -21, "A warm heavy wax seal stamp lands decisively on thick parchment, a soft leather thump and a tiny bronze ring with a short satisfying decay."),
    "ideology_use": (0.8, -22, "A carved wooden tablet slides into a fitted niche and locks with a soft wooden click, a tiny warm metal resonance, confident and tactile."),
    "ideology_unequip": (0.6, -24, "A carved wooden tablet gently lifts out of a felt lined niche, short soft scrape followed by a muted wooden click."),
    "ideology_promote": (2.4, -19, "A deep ceremonial seal strike followed by a luminous bronze bowl resonance with a rising golden shimmer and warm dignified resolution. A rare intellectual achievement, compact and graceful, no orchestra."),
}


def process(raw: Path, dest: Path, lufs: int) -> dict:
    # Remove leading silence only; preserve the generated material and natural tail.
    decoded = subprocess.run(["ffmpeg", "-v", "error", "-i", str(raw), "-f", "f32le",
                              "-ac", "2", "-ar", "48000", "pipe:1"], check=True, capture_output=True)
    audio = np.frombuffer(decoded.stdout, dtype="<f4").reshape(-1, 2).copy()
    active = np.flatnonzero(np.max(np.abs(audio), axis=1) > 0.002)
    if not len(active):
        raise RuntimeError(f"Silent generation: {raw.name}")
    audio = audio[max(0, int(active[0]) - 240):min(len(audio), int(active[-1]) + 4800)]
    fade = min(480, len(audio) // 4)
    audio[:96] *= np.linspace(0, 1, 96)[:, None]
    audio[-fade:] *= np.linspace(1, 0, fade)[:, None]
    temp = CACHE / (dest.stem + "_trim.wav")
    wavfile.write(temp, 48000, audio)
    # Two-pass loudnorm avoids dynamic processing; final PCM uses TPDF dither.
    scan = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(temp), "-af",
                           f"loudnorm=I={lufs}:TP=-1:LRA=11:print_format=json", "-f", "null", "-"],
                          check=True, capture_output=True, text=True).stderr
    measured = json.loads(scan[scan.rfind("{"):scan.rfind("}") + 1])
    filt = (f"loudnorm=I={lufs}:TP=-1:LRA=11:measured_I={measured['input_i']}:"
            f"measured_TP={measured['input_tp']}:measured_LRA={measured['input_lra']}:"
            f"measured_thresh={measured['input_thresh']}:offset={measured['target_offset']}:linear=true,"
            "aresample=48000:dither_method=triangular")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(temp), "-af", filt,
                    "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", str(dest)], check=True)
    sr, pcm = wavfile.read(dest)
    return {"duration_seconds": round(len(pcm) / sr, 4), "target_lufs": lufs,
            "sample_rate": sr, "sha256": hashlib.sha256(dest.read_bytes()).hexdigest(),
            "peak_dbfs": round(float(20 * np.log10(max(1, np.max(np.abs(pcm.astype(float)))) / 32768)), 2)}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-api", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    key = None if args.no_api else load_api_key()
    manifest = {"provider": "ElevenLabs", "model_id": "eleven_text_to_sound_v2",
                "output_format": "wav_48000", "events": {}}
    for name, (duration, lufs, description) in CUES.items():
        payload = {"text": STYLE + description, "duration_seconds": duration,
                   "prompt_influence": 0.5, "loop": False, "model_id": manifest["model_id"]}
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()[:12]
        raw = CACHE / f"{name}_{digest}.wav"
        if not raw.exists():
            if key is None:
                raise RuntimeError(f"Missing cache for {name}")
            print(f"Generating {name} ({duration}s)", flush=True)
            raw.write_bytes(api_post_json("https://api.elevenlabs.io/v1/sound-generation?output_format=wav_48000",
                                          key, payload, timeout=180))
        entry = process(raw, OUT / f"{name}.wav", lufs)
        entry["prompt"] = payload["text"]
        entry["event"] = f"event:/UI/Event/{name}"
        manifest["events"][name] = entry
        print(f"Ready {name}: {entry['duration_seconds']}s", flush=True)
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("PROGRESSION_SFX_GENERATED=true", flush=True)


if __name__ == "__main__":
    main()

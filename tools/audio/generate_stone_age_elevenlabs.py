"""Generate the Stone Age interactive music suite (5 synchronized stereo stems) using ElevenLabs API.

Pipeline:
  1. Call POST /v1/music (model_id="music_v2_5") with a 4-section CompositionPlan:
       - [0.0s .. 12.8s]  (12800ms) Intro: 荒原初醒 (Prehistoric bone horn, clay xun, canyon stone chimes)
       - [12.8s .. 28.8s] (16000ms) Loop A: 旷野寻踪 (Jiahu bone flute pentatonic lead, stone lithophone, frame drum)
       - [28.8s .. 44.8s] (16000ms) Loop B: 溪谷石语 (Mellow clay ocarina xun, wood clappers, bow harp, throat drone)
       - [44.8s .. 63.2s] (18400ms) Loop C + 2.4s wrap tail: 星火守夜 (Bone flute & xun duet, ancestral clan choir)
  2. Call POST /v1/music/stem-separation (six_stems_v1) on the master track to extract strictly phase-aligned stems:
       - stem_base_core.wav  <- other + piano + guitar (melodic instruments: bone flute, clay xun, lithophone, bow harp)
       - stem_pop_rhythm.wav <- drums + bass (tribal shamanic frame drum, wood clappers, shaker, low pulse)
       - stem_pop_chorus.wav <- vocals (ancestral clan choir / throat-singing overtone pad)
  3. Call POST /v1/sound-generation (loop=True, duration_seconds=16.0) for the two camera zoom layers:
       - stem_zoom_close.wav <- Prehistoric hearth campfire crackling, flint knapping & intimate clay pot foley
       - stem_zoom_far.wav   <- High-altitude steppe wind & vast prehistoric canyon overtone drone
  4. Apply equal-power loop boundary crossfading at 12.8s / 28.8s / 44.8s / 60.8s and RMS normalization.
"""

from __future__ import annotations

import io
import json
import math
import os
import subprocess
import urllib.error
import urllib.request
import uuid
import wave
import zipfile
from pathlib import Path
import numpy as np

SR = 32000
BPM = 75.0
BEAT = 60.0 / BPM          # 0.8s
BAR = BEAT * 4.0           # 3.2s
INTRO_BARS = 4             # 12.8s
LOOP_SECTION_BARS = 5      # 16.0s each
TOTAL_BARS = INTRO_BARS + 3 * LOOP_SECTION_BARS  # 19 bars = 60.8s
TOTAL_DUR = TOTAL_BARS * BAR                     # 60.8s
TAIL_SEC = 2.4
N_SAMPLES = int(round(TOTAL_DUR * SR))
N_EXT = N_SAMPLES + int(round(TAIL_SEC * SR))

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT.parent / "tmp" / "fmod_stone_age" / "audio"
CACHE_DIR = ROOT.parent / "tmp" / "fmod_stone_age" / "elevenlabs_cache"
REPO_ASSET_DIR = ROOT / "Audio" / "ProjectKeynes" / "Assets" / "StoneAge"
REPO_FLAT_ASSET_DIR = ROOT / "Audio" / "ProjectKeynes" / "Assets"


def load_api_key() -> str:
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                if k.strip() == "ELEVENLABS_API_KEY":
                    os.environ["ELEVENLABS_API_KEY"] = v.strip().strip('"').strip("'")
    key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    if not key:
        raise RuntimeError("Missing ELEVENLABS_API_KEY in .env or environment.")
    return key


def api_post_json(url: str, api_key: str, payload: dict, timeout: int = 300) -> bytes:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json",
            "User-Agent": "ProjectKeynes-AudioPipeline/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"ElevenLabs HTTP {e.code} on {url}: {body}") from e


def api_post_multipart(url: str, api_key: str, fields: dict[str, str], file_field: str, file_name: str, file_bytes: bytes, content_type: str = "audio/mpeg", timeout: int = 600) -> bytes:
    boundary = f"----PKBoundary{uuid.uuid4().hex}"
    body = io.BytesIO()
    for k, v in fields.items():
        body.write(f"--{boundary}\r\n".encode("utf-8"))
        body.write(f'Content-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode("utf-8"))
    body.write(f"--{boundary}\r\n".encode("utf-8"))
    body.write(
        f'Content-Disposition: form-data; name="{file_field}"; filename="{file_name}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n".encode("utf-8")
    )
    body.write(file_bytes)
    body.write(f"\r\n--{boundary}--\r\n".encode("utf-8"))

    req = urllib.request.Request(
        url,
        data=body.getvalue(),
        headers={
            "xi-api-key": api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "User-Agent": "ProjectKeynes-AudioPipeline/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"ElevenLabs HTTP {e.code} on {url}: {err_body}") from e


def decode_audio_bytes_to_numpy(audio_bytes: bytes, target_sr: int = SR) -> np.ndarray:
    """Use ffmpeg to decode any audio bytes (mp3/wav/flac) into float64 stereo [-1, 1] at target_sr."""
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        "pipe:0",
        "-f",
        "s16le",
        "-acodec",
        "pcm_s16le",
        "-ac",
        "2",
        "-ar",
        str(target_sr),
        "pipe:1",
    ]
    proc = subprocess.run(cmd, input=audio_bytes, capture_output=True, check=True)
    pcm = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float64) / 32768.0
    return pcm.reshape(-1, 2)


def fit_length(audio: np.ndarray, target_samples: int) -> np.ndarray:
    """Pad or trim stereo audio to exact target_samples."""
    n = audio.shape[0]
    if n >= target_samples:
        return audio[:target_samples].copy()
    out = np.zeros((target_samples, 2), dtype=np.float64)
    out[:n] = audio
    return out


def wrap_loop_boundaries(buf_ext: np.ndarray) -> np.ndarray:
    """Ensure seamless equal-power crossfade across Loop A/B/C boundaries (12.8s, 28.8s, 44.8s, 60.8s)."""
    out = buf_ext[:N_SAMPLES].copy()
    xfade_sec = 0.45
    xfade_n = int(round(xfade_sec * SR))
    t = np.linspace(0.0, 1.0, xfade_n, dtype=np.float64)[:, None]
    fade_in = np.sin(0.5 * math.pi * t)
    fade_out = np.cos(0.5 * math.pi * t)

    # Fold the tail beyond 60.8s into the start of Loop A (12.8s)
    loop_a_idx = int(round(12.8 * SR))
    tail = buf_ext[N_SAMPLES:N_SAMPLES + xfade_n]
    if tail.shape[0] == xfade_n:
        out[loop_a_idx:loop_a_idx + xfade_n] = (
            out[loop_a_idx:loop_a_idx + xfade_n] * fade_in + tail * fade_out
        )

    # Also smooth micro-seams at the end of Loop A (28.8s), Loop B (44.8s), and Loop C (60.8s)
    micro_n = int(round(0.08 * SR))
    mt = np.linspace(0.0, 1.0, micro_n, dtype=np.float64)[:, None]
    m_in = np.sin(0.5 * math.pi * mt)
    m_out = np.cos(0.5 * math.pi * mt)
    for sec_start, sec_end in [(12.8, 28.8), (28.8, 44.8), (44.8, 60.8)]:
        i_start = int(round(sec_start * SR))
        i_end = int(round(sec_end * SR))
        head = out[i_start:i_start + micro_n].copy()
        out[i_end - micro_n:i_end] = out[i_end - micro_n:i_end] * m_out + head * m_in

    return out


def tile_loop_to_timeline(loop_audio: np.ndarray) -> np.ndarray:
    """Tile a shorter seamless ambient loop across N_EXT with 1.2s equal-power crossfades."""
    out = np.zeros((N_EXT, 2), dtype=np.float64)
    xfade_n = min(int(round(1.2 * SR)), loop_audio.shape[0] // 4)
    step = loop_audio.shape[0] - xfade_n
    t = np.linspace(0.0, 1.0, xfade_n, dtype=np.float64)[:, None]
    fade_in = np.sin(0.5 * math.pi * t)
    fade_out = np.cos(0.5 * math.pi * t)

    pos = 0
    first = True
    while pos < N_EXT:
        chunk = loop_audio.copy()
        if not first and xfade_n > 0:
            chunk[:xfade_n] *= fade_in
            out[pos:min(N_EXT, pos + xfade_n)] *= fade_out[:max(0, min(N_EXT - pos, xfade_n))]
        n_copy = min(chunk.shape[0], N_EXT - pos)
        out[pos:pos + n_copy] += chunk[:n_copy]
        pos += step
        first = False
    return wrap_loop_boundaries(out)


def normalize_stem(audio: np.ndarray, target_rms_db: float = -20.0, peak_limit_db: float = -1.5) -> tuple[np.ndarray, float, float]:
    rms = float(np.sqrt(np.mean(np.square(audio)) + 1e-12))
    if rms < 1e-5:
        return audio, -80.0, -80.0
    curr_rms_db = 20.0 * math.log10(rms)
    gain = 10.0 ** ((target_rms_db - curr_rms_db) / 20.0)
    out = audio * gain
    peak = float(np.max(np.abs(out)) + 1e-12)
    peak_limit = 10.0 ** (peak_limit_db / 20.0)
    if peak > peak_limit:
        out = np.tanh(out / peak_limit) * peak_limit
    final_rms = 20.0 * math.log10(float(np.sqrt(np.mean(np.square(out)) + 1e-12)))
    final_peak = 20.0 * math.log10(float(np.max(np.abs(out)) + 1e-12))
    return out, final_rms, final_peak


def write_wav(path: Path, audio: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = np.clip(np.round(audio * 32767.0), -32768, 32767).astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())


def generate_stone_age_suite(api_key: str, force_regen: bool = False) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    master_mp3_path = CACHE_DIR / "stone_age_master.mp3"
    stems_zip_path = CACHE_DIR / "stone_age_stems.zip"
    zoom_close_mp3_path = CACHE_DIR / "stone_age_zoom_close.mp3"
    zoom_far_mp3_path = CACHE_DIR / "stone_age_zoom_far.mp3"
    choir_pad_mp3_path = CACHE_DIR / "stone_age_choir_pad.mp3"

    base_styles = [
        "prehistoric stone age soundtrack",
        "ancient neolithic world music",
        "75 BPM",
        "D Dorian modal pentatonic",
        "Jiahu bone flute",
        "ancient clay ocarina xun",
        "stone lithophone chimes",
        "plucked acoustic hunting bow harp",
        "tribal shamanic frame drum",
        "natural canyon acoustic reverb",
        "great production quality",
    ]
    neg_styles = [
        "modern synthesizer",
        "electric guitar",
        "pop vocals",
        "lyrics",
        "trap hi-hats",
        "edm",
        "brass fanfare",
        "distortion",
    ]

    # 1. Generate Master Track via /v1/music (CompositionPlan)
    if force_regen or not master_mp3_path.exists():
        print("[1/4] Generating Stone Age 4-section master track via ElevenLabs /v1/music (music_v2_5)...")
        composition_plan = {
            "chunks": [
                {
                    "text": "[Instrumental Intro]\n{deep prehistoric bone horn call echoing across a misty canyon, sparse clay ocarina xun and stone chimes}",
                    "duration_ms": 12800,
                    "positive_styles": base_styles + ["atmospheric intro", "deep bone horn", "sparse mystical opening"],
                    "negative_styles": neg_styles,
                    "context_adherence": "high",
                },
                {
                    "text": "[Instrumental Theme A]\n{breathful Jiahu bone flute playing a memorable pentatonic melody, rhythmic stone lithophone chimes, steady tribal shamanic frame drum and wood clappers}",
                    "duration_ms": 16000,
                    "positive_styles": base_styles + ["expressive bone flute lead", "tribal frame drum groove", "flowing pentatonic melody"],
                    "negative_styles": neg_styles,
                    "context_adherence": "high",
                },
                {
                    "text": "[Instrumental Theme B]\n{warm deep clay xun ocarina solo melody, plucked acoustic bow harp arpeggios, echoing stone percussion, low ancestral throat-singing overtone drone}",
                    "duration_ms": 16000,
                    "positive_styles": base_styles + ["mellow clay ocarina lead", "plucked bow harp", "deep throat-singing drone", "meditative tribal pulse"],
                    "negative_styles": neg_styles,
                    "context_adherence": "high",
                },
                {
                    "text": "[Instrumental Theme C]\n{soaring high bone flute and clay xun duet, wordless prehistoric clan choir humming in fifths, tribal frame drum and seed shaker groove}",
                    "duration_ms": 18400,
                    "positive_styles": base_styles + ["wordless ancestral clan choir humming", "soaring bone flute harmony", "warm tribal ensemble"],
                    "negative_styles": neg_styles,
                    "context_adherence": "high",
                },
            ]
        }
        payload = {
            "model_id": "music_v2_5",
            "composition_plan": composition_plan,
        }
        master_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/music?output_format=mp3_48000_192",
            api_key,
            payload,
        )
        master_mp3_path.write_bytes(master_bytes)
        print(f"  -> Saved master track ({len(master_bytes) / 1024:.1f} KB) to {master_mp3_path}")
    else:
        print(f"[1/4] Reusing cached master track: {master_mp3_path}")
        master_bytes = master_mp3_path.read_bytes()

    # 2. Separate Master into 6 synchronized stems via /v1/music/stem-separation
    if force_regen or not stems_zip_path.exists():
        print("[2/4] Separating master track into 6 synchronized stems via ElevenLabs /v1/music/stem-separation...")
        zip_bytes = api_post_multipart(
            "https://api.elevenlabs.io/v1/music/stem-separation",
            api_key,
            fields={"stem_variation_id": "six_stems_v1"},
            file_field="file",
            file_name="stone_age_master.mp3",
            file_bytes=master_bytes,
            content_type="audio/mpeg",
        )
        stems_zip_path.write_bytes(zip_bytes)
        print(f"  -> Saved separated stems ZIP ({len(zip_bytes) / 1024:.1f} KB) to {stems_zip_path}")
    else:
        print(f"[2/4] Reusing cached stems ZIP: {stems_zip_path}")

    # Decode separated stems from ZIP
    stem_buffers: dict[str, np.ndarray] = {}
    with zipfile.ZipFile(stems_zip_path, "r") as zf:
        for member in zf.namelist():
            if member.endswith("/"):
                continue
            raw_b = zf.read(member)
            low_name = Path(member).stem.lower()
            arr = fit_length(decode_audio_bytes_to_numpy(raw_b, SR), N_EXT)
            stem_buffers[low_name] = arr
            print(f"  -> Decoded stem '{low_name}' from {member} (RMS={20.0*math.log10(float(np.sqrt(np.mean(arr**2)+1e-12))):.1f} dBFS)")

    # Map separated stems to Base_Core, Pop_Rhythm, Pop_Chorus
    full_master = fit_length(decode_audio_bytes_to_numpy(master_bytes, SR), N_EXT)

    def pick_stems(keywords: list[str]) -> np.ndarray:
        acc = np.zeros((N_EXT, 2), dtype=np.float64)
        matched = False
        for k, v in stem_buffers.items():
            if any(kw in k for kw in keywords):
                acc += v
                matched = True
        return acc if matched else np.zeros((N_EXT, 2), dtype=np.float64)

    melodic_stem = pick_stems(["other", "piano", "guitar", "synth", "wind", "strings", "melod", "instrument"])
    rhythm_stem = pick_stems(["drum", "bass", "perc"])
    chorus_stem = pick_stems(["vocal", "choir", "voice"])

    # Fallback guarantees so no track is ever near-silent if a stem had minimal energy
    if float(np.sqrt(np.mean(melodic_stem ** 2))) < 1e-3:
        melodic_stem = full_master * 0.85
    if float(np.sqrt(np.mean(rhythm_stem ** 2))) < 1e-3:
        rhythm_stem = full_master * 0.55

    # Generate an ancestral clan choir / throat-singing harmonic pad in D so Pop_Chorus has unmistakable vocal/choral richness
    if force_regen or not choir_pad_mp3_path.exists():
        print("[2.5/4] Generating ancestral clan choir pad in D via ElevenLabs /v1/sound-generation...")
        choir_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_192",
            api_key,
            {
                "text": "Prehistoric ancestral clan choir wordless humming and warm throat-singing overtone drone in D minor pentatonic, solemn mystical vocal harmony pad, no drums",
                "duration_seconds": 16.0,
                "loop": True,
                "prompt_influence": 0.55,
            },
        )
        choir_pad_mp3_path.write_bytes(choir_bytes)
    else:
        print(f"[2.5/4] Reusing cached ancestral choir pad: {choir_pad_mp3_path}")
        choir_bytes = choir_pad_mp3_path.read_bytes()

    choir_tiled = tile_loop_to_timeline(decode_audio_bytes_to_numpy(choir_bytes, SR))
    # Fade in the choir subtly during the intro and fuller during the loops, blended with the separated vocals & high harmonic shimmer
    choir_norm, _, _ = normalize_stem(choir_tiled, target_rms_db=-21.5, peak_limit_db=-2.0)
    melodic_norm, _, _ = normalize_stem(wrap_loop_boundaries(melodic_stem), target_rms_db=-24.0, peak_limit_db=-2.0)

    stem_base_core = wrap_loop_boundaries(melodic_stem)
    stem_pop_rhythm = wrap_loop_boundaries(rhythm_stem)
    stem_pop_chorus = wrap_loop_boundaries(
        fit_length(choir_norm * 0.80 + wrap_loop_boundaries(chorus_stem) * 2.5 + melodic_norm * 0.35, N_EXT)
    )

    # 3. Generate CameraZoom Close & Far ambient soundscapes via /v1/sound-generation
    if force_regen or not zoom_close_mp3_path.exists():
        print("[3/4] Generating Zoom_Close soundscape via ElevenLabs /v1/sound-generation...")
        zc_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_192",
            api_key,
            {
                "text": "Prehistoric tribal village hearth campfire crackling warmly, subtle rhythmic flint stone knapping and soft hand clay pot tapping, intimate dry acoustic foley",
                "duration_seconds": 16.0,
                "loop": True,
                "prompt_influence": 0.45,
            },
        )
        zoom_close_mp3_path.write_bytes(zc_bytes)
    else:
        print(f"[3/4] Reusing cached Zoom_Close soundscape: {zoom_close_mp3_path}")
        zc_bytes = zoom_close_mp3_path.read_bytes()

    if force_regen or not zoom_far_mp3_path.exists():
        print("[4/4] Generating Zoom_Far soundscape via ElevenLabs /v1/sound-generation...")
        zf_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_192",
            api_key,
            {
                "text": "High-altitude sweeping steppe wind over a vast prehistoric continent, deep resonant canyon air and mystical low harmonic overtone drone in D",
                "duration_seconds": 16.0,
                "loop": True,
                "prompt_influence": 0.45,
            },
        )
        zoom_far_mp3_path.write_bytes(zf_bytes)
    else:
        print(f"[4/4] Reusing cached Zoom_Far soundscape: {zoom_far_mp3_path}")
        zf_bytes = zoom_far_mp3_path.read_bytes()

    stem_zoom_close = tile_loop_to_timeline(decode_audio_bytes_to_numpy(zc_bytes, SR))
    stem_zoom_far = tile_loop_to_timeline(decode_audio_bytes_to_numpy(zf_bytes, SR))

    # 4. Normalize and export all 5 stems to tmp/fmod_stone_age/audio/ and Audio/ProjectKeynes/Assets/
    stems = [
        ("stem_base_core.wav", stem_base_core, -18.5),
        ("stem_pop_rhythm.wav", stem_pop_rhythm, -19.5),
        ("stem_pop_chorus.wav", stem_pop_chorus, -20.0),
        ("stem_zoom_close.wav", stem_zoom_close, -21.5),
        ("stem_zoom_far.wav", stem_zoom_far, -20.5),
    ]

    for filename, raw_audio, target_rms in stems:
        norm_audio, rms_db, peak_db = normalize_stem(raw_audio, target_rms_db=target_rms, peak_limit_db=-1.2)
        for target_dir in [OUT_DIR, REPO_ASSET_DIR, REPO_FLAT_ASSET_DIR]:
            write_wav(target_dir / filename, norm_audio)
        print(f"  [OK] {filename:20s} dur={norm_audio.shape[0]/SR:5.2f}s RMS={rms_db:6.2f} dBFS Peak={peak_db:6.2f} dBFS")


if __name__ == "__main__":
    key = load_api_key()
    generate_stone_age_suite(key)

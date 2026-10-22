"""Project.Keynes grand-strategy era music pipeline, v3 (ElevenLabs music_v2_5 -> Demucs -> FMOD stems).

What changed vs v2 (and why the old suites sounded dull, muddy and samey):
  * Lossless chain: ElevenLabs `pcm_48000` (was mp3_192) -> 48 kHz / 16-bit dithered WAV (was 32 kHz, which
    cut everything above 16 kHz) -> FMOD Vorbis at a higher quality setting.
  * Stems: local Demucs `htdemucs_ft` on CUDA instead of the ElevenLabs 6-stem MP3s, which were ~128 kbps and
    25 ms late versus the master; mixing them with master-derived filters caused comb filtering and flamming.
  * Exact-sum layers: Base_Core + Pop_Rhythm + Pop_Chorus == master (one common gain, no per-stem RMS
    normalisation, no tanh saturation, no duplicated filtered copies). Full population plays the real mix.
  * Composition: 10 contrasting sections per era (theme statement -> counterpoint -> dance -> conflict ->
    lament -> nocturne -> choral climax -> recall) with key, meter, tempo-feel and dynamic changes. Shared
    styles are kept small so per-section styles actually steer the arrangement.
  * Ambience beds no longer contain tonal drones that clash with chord changes.

Timeline contract (unchanged, consumed by FMOD builders and game_audio_service.gd):
  Stone 18 + 3x54 = 180s | Agrarian 16 + 3x52 = 172s | Kingdom 16 + 3x50 = 166s | Empire 15 + 3x50 = 165s

Usage (system python with numpy/scipy; Demucs runs in tmp/audio_venv):
  python tools/audio/generate_grand_strategy_music_elevenlabs.py --eras stone_age
  python tools/audio/generate_grand_strategy_music_elevenlabs.py --eras all --no-api   # re-mix from cache only
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import urllib.error
import urllib.request
import wave
from pathlib import Path

import numpy as np
from scipy import ndimage, signal
from scipy.io import wavfile

SR = 48000
DEMUCS_SR = 44100
TRANS_DUR_SEC = 15.0

ROOT = Path(__file__).resolve().parents[2]
WORK_ROOT = ROOT.parent / "tmp"
REPO_FLAT_ASSET_DIR = ROOT / "Audio" / "ProjectKeynes" / "Assets"
AUDIO_VENV_PY = WORK_ROOT / "audio_venv" / "Scripts" / "python.exe"
DEMUCS_SCRIPT = Path(__file__).with_name("separate_stems_demucs.py")
CACHE_DIR_NAME = "elevenlabs_cache_v3"

MUSIC_TARGET_LUFS = -18.0
TRANSITION_TARGET_LUFS = -17.0
AMBIENCE_TARGET_LUFS = -28.0
TRUE_PEAK_CEILING_DB = -1.0

# Share of every separated stem sent to (Base_Core, Pop_Rhythm, Pop_Chorus). Rows sum to 1.0, so the three
# layers always reconstruct the master exactly. Base keeps some bass/percussion/voice so Tier 0 never sounds
# hollow (Demucs often files solo flutes/erhu under "vocals"); the tiers add drive and choral bloom.
LAYER_SPLIT = {
    "other": (1.0, 0.0, 0.0),
    "bass": (0.6, 0.4, 0.0),
    "drums": (0.3, 0.7, 0.0),
    "vocals": (0.35, 0.0, 0.65),
}
# Orchestral music has almost nothing in Demucs' drums/vocals stems, so the "other" stem (strings, brass,
# winds, plucks) is split further with complementary soft masks (still exact-sum):
#   * percussive/articulated part (pizzicato, plucks, staccato, timpani hits) -> Pop_Rhythm
#   * stereo-side part of the sustained ensemble (section width, hall bloom, divisi) -> Pop_Chorus
OTHER_PERCUSSIVE_TO_RHYTHM = 0.6
OTHER_SIDE_TO_CHORUS = 0.6

GLOBAL_NEGATIVE_STYLES = [
    "electronic synthesizer",
    "electric guitar",
    "modern drum kit",
    "pop song",
    "lyrics",
    "spoken words",
    "rap",
    "edm",
    "lo-fi",
    "distortion",
    "heavily compressed loudness",
    "muddy mix",
    "static drone without melody",
    "repetitive loop",
]


# ---------------------------------------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------------------------------------

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


def api_post_json(url: str, api_key: str, payload: dict, timeout: int = 900) -> bytes:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json",
            "User-Agent": "ProjectKeynes-AudioPipeline/3.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"ElevenLabs HTTP {e.code} on {url}: {body}") from e


# ---------------------------------------------------------------------------------------------------------
# Audio I/O and DSP
# ---------------------------------------------------------------------------------------------------------

def pcm16_bytes_to_float(raw: bytes, channels: int = 2) -> np.ndarray:
    pcm = np.frombuffer(raw[: len(raw) - len(raw) % (2 * channels)], dtype="<i2").astype(np.float64) / 32768.0
    pcm = pcm.reshape(-1, channels)
    return np.repeat(pcm, 2, axis=1) if channels == 1 else pcm


def decode_with_ffmpeg(audio_bytes: bytes) -> np.ndarray:
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-f", "f32le", "-ac", "2",
           "-ar", str(SR), "-af", "aresample=resampler=soxr:precision=28", "pipe:1"]
    proc = subprocess.run(cmd, input=audio_bytes, capture_output=True, check=True)
    return np.frombuffer(proc.stdout, dtype=np.float32).astype(np.float64).reshape(-1, 2)


def read_wav_float(path: Path) -> tuple[int, np.ndarray]:
    sr, data = wavfile.read(str(path))
    if data.dtype == np.int16:
        data = data.astype(np.float64) / 32768.0
    elif data.dtype == np.int32:
        data = data.astype(np.float64) / 2147483648.0
    else:
        data = data.astype(np.float64)
    if data.ndim == 1:
        data = np.stack([data, data], axis=1)
    return sr, data


def fit_length(audio: np.ndarray, target_samples: int) -> np.ndarray:
    if audio.shape[0] >= target_samples:
        return audio[:target_samples].copy()
    out = np.zeros((target_samples, 2), dtype=np.float64)
    out[: audio.shape[0]] = audio
    return out


def write_wav16(path: Path, audio: np.ndarray, rng: np.random.Generator) -> None:
    """16-bit PCM with TPDF dither (FMOD re-encodes to Vorbis; 16-bit keeps repo assets reasonably sized)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tpdf = rng.random(audio.shape) - rng.random(audio.shape)
    pcm = np.clip(np.round(audio * 32767.0 + tpdf), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())


def k_weighted(audio: np.ndarray) -> np.ndarray:
    # ITU-R BS.1770 K-weighting coefficients for 48 kHz.
    b1 = [1.53512485958697, -2.69169618940638, 1.19839281085285]
    a1 = [1.0, -1.69065929318241, 0.73248077421585]
    b2 = [1.0, -2.0, 1.0]
    a2 = [1.0, -1.99004745483398, 0.99007225036621]
    return signal.lfilter(b2, a2, signal.lfilter(b1, a1, audio, axis=0), axis=0)


def integrated_lufs(audio: np.ndarray) -> float:
    y = k_weighted(audio)
    block, hop = int(0.4 * SR), int(0.1 * SR)
    if y.shape[0] < block:
        return -70.0
    cs = np.vstack([np.zeros((1, 2)), np.cumsum(y ** 2, axis=0)])
    starts = np.arange(0, y.shape[0] - block + 1, hop)
    z = ((cs[starts + block] - cs[starts]) / block).sum(axis=1)
    lk = -0.691 + 10.0 * np.log10(z + 1e-20)
    z_abs = z[lk > -70.0]
    if z_abs.size == 0:
        return -70.0
    rel = -0.691 + 10.0 * math.log10(float(np.mean(z_abs))) - 10.0
    z_rel = z[(lk > -70.0) & (lk > rel)]
    return -0.691 + 10.0 * math.log10(float(np.mean(z_rel)) + 1e-20)


def short_loudness(audio: np.ndarray) -> float:
    y = k_weighted(audio)
    return -0.691 + 10.0 * math.log10(float(np.mean(y ** 2, axis=0).sum()) + 1e-20)


def true_peak_db(audio: np.ndarray) -> float:
    """4x oversampled peak, processed in windows to bound memory."""
    peak = 0.0
    win, pad = 20 * SR, 256
    for ch in range(audio.shape[1]):
        x = audio[:, ch]
        for s in range(0, x.shape[0], win):
            lo, hi = max(0, s - pad), min(x.shape[0], s + win + pad)
            up = signal.resample_poly(x[lo:hi], 4, 1)
            peak = max(peak, float(np.max(np.abs(up))))
    return 20.0 * math.log10(peak + 1e-12)


def common_gain(reference: np.ndarray, others: list[np.ndarray], target_lufs: float) -> tuple[float, float, float]:
    """One gain for the reference and all of its sub-layers: hit target loudness, never exceed the TP ceiling."""
    loud = integrated_lufs(reference)
    gain_db = target_lufs - loud
    tp = max([true_peak_db(reference)] + [true_peak_db(o) for o in others])
    if tp + gain_db > TRUE_PEAK_CEILING_DB:
        gain_db = TRUE_PEAK_CEILING_DB - tp
    return 10.0 ** (gain_db / 20.0), loud + gain_db, tp + gain_db


def equal_power(n: int) -> tuple[np.ndarray, np.ndarray]:
    t = np.linspace(0.0, 1.0, n, dtype=np.float64)[:, None]
    return np.sin(0.5 * math.pi * t), np.cos(0.5 * math.pi * t)


def make_loop_seamless(audio: np.ndarray, intro_sec: float, loop_sec: float) -> np.ndarray:
    """Linear (layer-sum preserving) loop preparation for the FMOD marker regions.

    The default Loop_All_ABC region jumps from the end of C back to the start of A, so the last 1.5 s of C is
    cross-faded into the material that originally led into A (the end of the intro). The jump then lands on
    a waveform and phrase that naturally continue. A/B/C-only audition loops get a short click-free blend.
    """
    out = audio.copy()
    a = int(round(intro_sec * SR))
    b = int(round((intro_sec + loop_sec) * SR))
    c = int(round((intro_sec + 2.0 * loop_sec) * SR))
    end = int(round((intro_sec + 3.0 * loop_sec) * SR))

    n = min(int(round(1.5 * SR)), a)
    fin, fout = equal_power(n)
    out[end - n:end] = audio[end - n:end] * fout + audio[a - n:a] * fin

    m = int(round(0.06 * SR))
    mi, mo = equal_power(m)
    for s, e in ((a, b), (b, c)):
        out[e - m:e] = out[e - m:e] * mo + audio[s - m:s] * mi

    k = int(round(0.005 * SR))
    out[:k] *= np.linspace(0.0, 1.0, k)[:, None]
    return out


def tile_loop(loop_audio: np.ndarray, total_samples: int) -> np.ndarray:
    out = np.zeros((total_samples, 2), dtype=np.float64)
    xfade = min(int(round(2.0 * SR)), loop_audio.shape[0] // 4)
    fin, fout = equal_power(xfade)
    step = loop_audio.shape[0] - xfade
    pos = 0
    first = True
    while pos < total_samples:
        chunk = loop_audio.copy()
        if not first:
            chunk[:xfade] *= fin
            span = min(xfade, total_samples - pos)
            out[pos:pos + span] *= fout[:span]
        n = min(chunk.shape[0], total_samples - pos)
        out[pos:pos + n] += chunk[:n]
        pos += step
        first = False
    return out


def shape_transition_envelope(audio: np.ndarray) -> np.ndarray:
    out = fit_length(audio, int(round(TRANS_DUR_SEC * SR)))
    atk = int(round(0.01 * SR))
    rel = int(round(1.2 * SR))
    out[:atk] *= np.linspace(0.0, 1.0, atk)[:, None]
    out[-rel:] *= np.cos(0.5 * math.pi * np.linspace(0.0, 1.0, rel))[:, None]
    return out


# ---------------------------------------------------------------------------------------------------------
# Stem separation and layer construction
# ---------------------------------------------------------------------------------------------------------

def separate_stems(master: np.ndarray, work_dir: Path, force: bool) -> dict[str, np.ndarray]:
    out_dir = work_dir / "demucs_htdemucs_ft"
    names = ["drums", "bass", "other", "vocals"]
    if force or not all((out_dir / f"{n}.wav").exists() for n in names):
        if not AUDIO_VENV_PY.exists():
            raise RuntimeError(f"Demucs venv missing: {AUDIO_VENV_PY} (see SKILL.md setup)")
        in_path = work_dir / "master_44k1.wav"
        wavfile.write(str(in_path), DEMUCS_SR, signal.resample_poly(master, 147, 160, axis=0).astype(np.float32))
        print("  [demucs] separating with htdemucs_ft on GPU ...")
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        subprocess.run([str(AUDIO_VENV_PY), str(DEMUCS_SCRIPT), str(in_path), str(out_dir), "htdemucs_ft"],
                       check=True, env=env)
    stems: dict[str, np.ndarray] = {}
    for n in names:
        sr, data = read_wav_float(out_dir / f"{n}.wav")
        if sr != DEMUCS_SR:
            raise RuntimeError(f"Unexpected Demucs sample rate {sr} for {n}")
        stems[n] = fit_length(signal.resample_poly(data, 160, 147, axis=0), master.shape[0])
    return stems


def build_layers(master: np.ndarray, stems: dict[str, np.ndarray]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    layers = [np.zeros_like(master) for _ in range(3)]
    for name, split in LAYER_SPLIT.items():
        if name == "other":
            continue
        for i in range(3):
            if split[i]:
                layers[i] += stems[name] * split[i]
    harmonic, percussive = hpss_split(stems["other"])
    side = 0.5 * (harmonic[:, 0] - harmonic[:, 1])
    side_part = OTHER_SIDE_TO_CHORUS * np.stack([side, -side], axis=1)
    rhythm_part = OTHER_PERCUSSIVE_TO_RHYTHM * percussive
    layers[1] += rhythm_part
    layers[2] += side_part
    layers[0] += stems["other"] - rhythm_part - side_part
    # Whatever the separator could not attribute (and the >20 kHz band lost at 44.1 kHz) stays in Base_Core,
    # so Base + Rhythm + Chorus is bit-for-bit the master before quantisation.
    residual = master - (layers[0] + layers[1] + layers[2])
    layers[0] += residual
    m_db = 20.0 * math.log10(float(np.sqrt(np.mean(master ** 2))) + 1e-12)
    r_db = 20.0 * math.log10(float(np.sqrt(np.mean(residual ** 2))) + 1e-12)
    print(f"  [layers] separation residual {r_db - m_db:6.1f} dB relative to master (folded into Base_Core)")
    return layers[0], layers[1], layers[2]


def hpss_split(audio: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Median-filter harmonic/percussive separation with complementary Wiener masks (H + P == input)."""
    nper, hop = 4096, 1024
    _, _, spec = signal.stft(audio.T, fs=SR, nperseg=nper, noverlap=nper - hop, boundary="even", padded=True)
    mag = np.abs(spec).mean(axis=0)  # one mask for both channels keeps the stereo image intact
    harm = ndimage.median_filter(mag, size=(1, 17), mode="reflect")
    perc = ndimage.median_filter(mag, size=(17, 1), mode="reflect")
    mask_p = perc ** 2 / (perc ** 2 + harm ** 2 + 1e-12)
    _, p = signal.istft(spec * mask_p[None], fs=SR, nperseg=nper, noverlap=nper - hop, boundary=True)
    p = fit_length(p.T, audio.shape[0])
    return audio - p, p


def report_sections(spec: dict, master: np.ndarray, layers: tuple[np.ndarray, ...]) -> None:
    print("  section                              start   loud(LUFS)  base%  rhythm%  chorus%")
    pos = 0
    for ch in spec["chunks"]:
        n = int(round(ch["duration_ms"] / 1000.0 * SR))
        seg = slice(pos, min(pos + n, master.shape[0]))
        energies = [float(np.mean(layer[seg] ** 2)) for layer in layers]
        total = sum(energies) + 1e-20
        shares = [100.0 * e / total for e in energies]
        print(f"  {ch['label'][:36]:36s} {pos / SR:6.1f}s   {short_loudness(master[seg]):7.1f}    "
              f"{shares[0]:5.1f}  {shares[1]:6.1f}  {shares[2]:6.1f}")
        pos += n


# ---------------------------------------------------------------------------------------------------------
# Composition plans
# ---------------------------------------------------------------------------------------------------------

def section(label: str, duration_ms: int, cues: list[str], styles: list[str], negatives: list[str] | None = None,
            adherence: str = "medium") -> dict:
    return {"label": label, "duration_ms": duration_ms, "cues": cues, "styles": styles,
            "negatives": negatives or [], "adherence": adherence}


def build_composition_plan(identity: list[str], chunks: list[dict], extra_negatives: list[str] | None = None) -> dict:
    plan_chunks = []
    for ch in chunks:
        text = "\n".join([f"[{ch['label']}]"] + ["{" + c + "}" for c in ch["cues"]])
        lines = text.splitlines()
        assert len(lines) <= 30 and all(len(line) <= 200 for line in lines), f"cue too long in {ch['label']}"
        assert 3000 <= ch["duration_ms"] <= 120000
        positive = identity + ch["styles"]
        negative = GLOBAL_NEGATIVE_STYLES + (extra_negatives or []) + ch["negatives"]
        assert len(positive) <= 50 and len(negative) <= 50
        plan_chunks.append({
            "text": text,
            "duration_ms": ch["duration_ms"],
            "positive_styles": positive,
            "negative_styles": negative,
            "context_adherence": ch["adherence"],
        })
    return {"chunks": plan_chunks}


HIFI = ["wide dynamic range, uncompressed", "pristine high fidelity studio master", "real acoustic performance"]

ERA_SPECS: list[dict] = [
    {
        "key": "stone_age",
        "prefix": "stem_",
        "intro_sec": 18.0,
        "loop_sec": 54.0,
        "identity": [
            "ancient prehistoric world music score for a grand historical strategy game",
            "organic acoustic instruments only",
            "wooden flutes, clay ocarina, frame drums, log drums, rain stick, cello, plucked harp, wordless voices",
            "D Dorian",
            "75 BPM",
            "natural valley and stone cave acoustics",
            "strong memorable melodic theme developed through variations",
        ] + HIFI,
        "chunks": [
            section("Intro - dawn over the wilds", 18000, [
                "free rubato, no steady pulse, pianissimo",
                "a lone wooden flute calls a fragment of the main theme, answered by a distant echo across the valley",
                "rain stick, a soft heartbeat frame drum and low hummed voices slowly fade in",
            ], ["pianissimo atmospheric prologue", "free rubato", "flute call and echo", "sparse and spacious"],
                ["full orchestra", "loud drums", "fast tempo"]),
            section("Theme A - statement", 18000, [
                "the main theme: a singing D Dorian melody on wooden flute, rising a fourth then falling stepwise",
                "plucked harp ostinato and a soft heartbeat frame drum, piano dynamic",
            ], ["intimate solo melody exposition", "piano dynamic", "plucked harp ostinato", "heartbeat frame drum"],
                ["full orchestra", "choir", "cymbals"], "high"),
            section("Theme A - counterpoint", 18000, [
                "the theme repeats an octave lower on cello while a clay ocarina sings a new countermelody above",
                "low male voices hum a sustained harmony, shakers enter, mezzo-piano",
            ], ["cello and ocarina counterpoint", "hummed male voices", "mezzo-piano", "growing warmth"],
                adherence="high"),
            section("Theme A - gathering dance", 18000, [
                "hand drums build an interlocking 6/8 groove while two flutes trade short phrases of the theme",
                "crescendo to mezzo-forte, ending on an open suspended chord",
            ], ["interlocking hand drum polyrhythm", "6/8 tribal dance", "crescendo", "call and response flutes"]),
            section("Theme B - the hunt", 18000, [
                "sudden change of mood: A Phrygian, urgent double-time feel, deep log drums and stomping",
                "driving cello ostinato under sharp staccato flute motifs, forte",
            ], ["tense hunting chase", "A Phrygian", "double-time driving rhythm", "deep log drums", "forte"],
                ["gentle lullaby", "slow tempo"], "low"),
            section("Theme B - the hunt climax", 18000, [
                "animal horn blasts, the full tribal percussion ensemble, cellos and basses pounding",
                "the main theme returns fragmented and fierce in the low strings, fortissimo",
            ], ["fortissimo tribal percussion climax", "animal horn calls", "fierce variation of the theme",
                "powerful low strings"], adherence="high"),
            section("Bridge - aftermath lament", 18000, [
                "abrupt drop to near silence: rain stick and a solo cello playing a slow descending lament",
                "a distant soft drum, pianissimo, mournful and reflective",
            ], ["pianissimo lament", "solo cello", "sparse and empty", "reflective aftermath"],
                ["loud drums", "fast tempo", "choir"], "low"),
            section("Theme C - campfire lullaby", 18000, [
                "warm F major lullaby in 3/4 around a campfire, clay ocarina melody over plucked harp",
                "a soft female voice hums without words, piano dynamic, tender",
            ], ["tender campfire lullaby", "F major", "lilting 3/4", "clay ocarina", "soft female humming"],
                ["loud drums"], "low"),
            section("Theme C - song of the ancestors", 18000, [
                "the ancestral choir rises, men and women singing wordless ah, full strings swell",
                "the main theme in broad slow augmentation over big frame drums, fortissimo, awe-inspiring",
            ], ["majestic wordless choir climax", "theme in augmentation", "fortissimo", "ancestral hymn"]),
            section("Coda - return to the wilds", 18000, [
                "the choir fades away, back to D Dorian, a lone wooden flute recalls the opening theme",
                "soft heartbeat frame drum and plucked harp settle, piano, leading back to the beginning",
            ], ["gentle decrescendo coda", "D Dorian", "solo flute recalls the theme", "seamless loop back"]),
        ],
        "zoom_close_prompt": "Prehistoric village campfire crackling warmly, occasional flint stone knapping, soft footsteps "
                             "on dry earth, intimate dry acoustic foley, no music",
        "zoom_far_prompt": "High-altitude wind sweeping over a vast prehistoric steppe, rustling grass, a distant eagle "
                           "cry, airy and wide, no music, no tonal hum",
        "transition_file": None,
    },
    {
        "key": "agrarian_age",
        "prefix": "stem_agr_",
        "intro_sec": 16.0,
        "loop_sec": 52.0,
        "identity": [
            "pastoral world music score for a grand historical strategy game",
            "East Asian folk instruments blended with a Western chamber orchestra",
            "bamboo dizi, guzheng, erhu, pipa, xiao flute, chamber strings, harp, frame drums, wordless choir",
            "G major pentatonic",
            "80 BPM",
            "warm sunlit chamber hall acoustics",
            "strong memorable melodic theme developed through variations",
        ] + HIFI,
        "chunks": [
            section("Intro - morning bell", 16000, [
                "a single deep bronze bell, then a cascading guzheng glissando",
                "a free rubato dizi call over soft string harmonics, pianissimo",
            ], ["pianissimo sunrise prologue", "free rubato", "bronze bell and guzheng glissando"],
                ["loud drums", "full orchestra"]),
            section("Theme A - spring sowing", 17000, [
                "the main theme on bamboo dizi: a bright G pentatonic folk melody with a skipping rhythm",
                "guzheng arpeggios and light pizzicato strings, piano dynamic",
            ], ["intimate solo melody exposition", "bright skipping folk melody", "guzheng arpeggios",
                "piano dynamic"], ["choir", "cymbals", "full orchestra"], "high"),
            section("Theme A - erhu answer", 17000, [
                "erhu answers with a lyrical countermelody while chamber strings add warm sustained harmony",
                "a soft frame drum enters, mezzo-piano",
            ], ["erhu and dizi counterpoint", "warm chamber strings", "mezzo-piano"], adherence="high"),
            section("Theme A - harvest dance", 18000, [
                "the theme in full ensemble with a gentle harvest dance groove, crescendo to mezzo-forte",
                "modulating up to D major at the end",
            ], ["harvest dance groove", "full folk ensemble", "crescendo", "modulation to D major"]),
            section("Theme B - village festival", 17000, [
                "lively festival dance in 6/8 in D major, pipa tremolo and rapid hand drums",
                "dizi and erhu trade quick ornamented phrases, forte, joyful",
            ], ["joyful village festival dance", "6/8", "pipa tremolo", "rapid hand drums", "forte"],
                ["slow tempo"], "low"),
            section("Theme B - festival peak", 17000, [
                "big festival drums, cymbal swells, strings and plucked instruments in unison, fortissimo",
                "the main theme returns triumphant",
            ], ["fortissimo festival climax", "big drums and cymbal swells", "triumphant theme"],
                adherence="high"),
            section("Bridge - flood and drought", 18000, [
                "sudden darkening to E minor, low string tremolo and distant taiko rolls",
                "a strained erhu melody, tension rising, then falling away to pianissimo",
            ], ["ominous tension", "E minor", "low string tremolo", "distant taiko rolls", "strained erhu"],
                ["joyful", "major key"], "low"),
            section("Theme C - moonlit fields", 17000, [
                "slow and still, xiao flute and guqin harmonics, free rubato, pianissimo",
                "C major, a deeply calm night",
            ], ["tranquil nocturne", "xiao flute and guqin harmonics", "C major", "pianissimo"],
                ["drums"], "low"),
            section("Theme C - harvest prayer", 17000, [
                "a warm wordless choir and string chorale swell in C major, a prayer for a good harvest",
                "the main theme in augmentation, forte",
            ], ["warm wordless choir chorale", "string chorale", "theme in augmentation", "forte"]),
            section("Coda - homecoming", 18000, [
                "back to G major, the dizi gently restates the main theme with guzheng",
                "decrescendo to piano, leading back to the beginning",
            ], ["gentle decrescendo coda", "G major", "dizi recalls the theme", "seamless loop back"]),
        ],
        "zoom_close_prompt": "Peaceful farming village: irrigation brook babbling, wooden waterwheel turning, stone "
                             "millstone grinding softly, morning songbirds, no music",
        "zoom_far_prompt": "Warm breeze sweeping across vast golden wheat fields and terraced valleys, swaying crops, "
                           "distant cicadas, airy and wide, no music, no tonal hum",
        "transition_file": "trans_stone_to_agrarian.wav",
        "transition": {
            "bpm": "80 BPM",
            "bridge": ["a wooden flute and warm cello in D minor build anticipation",
                       "rising harp glissando and timpani roll"],
            "fanfare": ["radiant G major arrival: bronze bells, soaring bamboo dizi, lush strings",
                        "cascading guzheng and a warm wordless choir"],
            "fanfare_styles": ["triumphant pastoral era arrival fanfare", "radiant G major resolution",
                               "soaring dizi and lush strings", "bronze bells and guzheng"],
        },
    },
    {
        "key": "kingdom_age",
        "prefix": "stem_kng_",
        "intro_sec": 16.0,
        "loop_sec": 50.0,
        "identity": [
            "royal court orchestral score for a grand historical strategy game",
            "renaissance court ensemble with symphony orchestra and East Asian court instruments",
            "lute, harp, recorder, oboe, strings, French horns, trumpets, timpani, bronze bells, pipe organ, guqin",
            "C major",
            "86 BPM",
            "rich palace hall and cathedral acoustics",
            "strong noble melodic theme developed through variations",
        ] + HIFI,
        "chunks": [
            section("Intro - the procession approaches", 16000, [
                "a solemn bronze bell toll, a low brass chorale and a soft timpani roll",
                "a royal procession approaching from afar, pianissimo growing to mezzo-piano",
            ], ["solemn royal prologue", "low brass chorale", "bell toll", "pianissimo to mezzo-piano"],
                ["fast tempo"]),
            section("Theme A - court pavane", 16000, [
                "the royal theme as a stately pavane: solo oboe over lute and harp, piano dynamic",
                "noble and dignified, a clear melody in C major",
            ], ["stately renaissance pavane", "solo oboe over lute and harp", "piano dynamic"],
                ["choir", "cymbals", "loud brass"], "high"),
            section("Theme A - royal counterpoint", 17000, [
                "strings and French horns take the theme in imitative counterpoint, recorder ornaments",
                "mezzo-forte, rich polyphony",
            ], ["imitative counterpoint", "strings and French horns", "mezzo-forte"], adherence="high"),
            section("Theme A - procession march", 17000, [
                "full royal procession march: trumpets, snare drum and timpani, the theme on horns, forte",
            ], ["royal procession march", "trumpets and timpani", "forte"]),
            section("Theme B - palace intrigue", 16000, [
                "A minor, sly staccato pizzicato strings and harpsichord with a sneaky bassoon line",
                "mezzo-piano, mysterious and clever",
            ], ["mysterious palace intrigue", "A minor", "pizzicato strings and harpsichord", "sneaky bassoon"],
                ["triumphant", "choir"], "low"),
            section("Theme B - war council", 17000, [
                "D minor, war drums and a low brass ostinato with heroic horn calls, fortissimo",
                "driving martial energy",
            ], ["martial war council", "D minor", "war drums", "low brass ostinato", "fortissimo"],
                adherence="medium"),
            section("Bridge - the cost of war", 17000, [
                "sudden quiet: a solo viola lament over sparse harp, pianissimo",
            ], ["pianissimo lament", "solo viola", "sparse harp"], ["drums", "brass"], "low"),
            section("Theme C - cathedral hymn", 16000, [
                "F major, a reverent wordless choir hymn with soft pipe organ, piano dynamic",
            ], ["reverent choral hymn", "soft pipe organ", "F major", "piano dynamic"], ["drums"], "low"),
            section("Theme C - coronation", 17000, [
                "full orchestra, choir and pealing bells, the royal theme in grand augmentation, fortissimo",
                "a triumphant coronation",
            ], ["triumphant coronation climax", "choir and pealing bells", "theme in augmentation",
                "fortissimo"]),
            section("Coda - a peaceful realm", 17000, [
                "lute and recorder softly recall the court theme in C major",
                "decrescendo, leading back to the beginning",
            ], ["gentle decrescendo coda", "C major", "lute and recorder recall the theme", "seamless loop back"]),
        ],
        "zoom_close_prompt": "Busy medieval market square: crowd murmur, cart wheels on cobblestones, horses, a distant "
                             "blacksmith hammer, no music",
        "zoom_far_prompt": "High mountain fortress wind with heavy silk banners flapping, distant crows, airy and wide, "
                           "no music, no tonal hum",
        "transition_file": "trans_agrarian_to_kingdom.wav",
        "transition": {
            "bpm": "86 BPM",
            "bridge": ["a pastoral dizi and strings in G major build noble tension",
                       "a rising timpani roll and French horn swell"],
            "fanfare": ["monumental C major coronation fanfare with bronze bells, noble horns and trumpets",
                        "sweeping strings, harp and a solemn wordless choir"],
            "fanfare_styles": ["majestic royal coronation fanfare", "grand C major resolution",
                               "noble horns and trumpets", "pealing bronze bells"],
        },
    },
    {
        "key": "empire_age",
        "prefix": "stem_emp_",
        "intro_sec": 15.0,
        "loop_sec": 50.0,
        "identity": [
            "late-romantic nineteenth-century symphonic score for a grand historical strategy game",
            "full symphony orchestra with concert grand piano",
            "piano, solo cello, solo violin, lush strings, French horns, brass, woodwinds, harp, timpani",
            "F major",
            "92 BPM",
            "world-class concert hall recording",
            "sweeping memorable melodic theme developed through variations",
        ] + HIFI,
        "chunks": [
            section("Intro - dawn of an age", 15000, [
                "solo concert grand piano rolling arpeggios, then a distant noble French horn call",
                "rubato, piano dynamic, hopeful",
            ], ["hopeful piano prologue", "rolling piano arpeggios", "distant horn call", "rubato"],
                ["drums", "full orchestra"]),
            section("Theme A - imperial theme", 16000, [
                "the main theme sung by solo cello over expressive piano accompaniment in F major, rubato",
                "intimate and hopeful, piano dynamic",
            ], ["intimate cello and piano exposition", "expressive rubato", "piano dynamic"],
                ["choir", "cymbals", "brass"], "high"),
            section("Theme A - waltz", 17000, [
                "lush strings take the theme as a graceful waltz in 3/4, harp and flutes sparkle",
                "mezzo-forte, elegant",
            ], ["graceful romantic waltz", "3/4", "lush strings", "sparkling harp and flutes"], adherence="high"),
            section("Theme A - grand ballroom", 17000, [
                "a grand ballroom waltz with full woodwinds and horns, crescendo to forte",
            ], ["grand ballroom waltz", "full woodwinds and horns", "crescendo to forte"]),
            section("Theme B - industry", 16000, [
                "D minor, a relentless 2/4 string ostinato like turning machinery, snare drum and low brass",
                "mezzo-forte, driving and purposeful",
            ], ["relentless industrial ostinato", "D minor", "2/4 march pulse", "snare and low brass"],
                ["waltz", "synthesizer"], "low"),
            section("Theme B - expansion", 17000, [
                "a heroic brass fanfare in B flat major, full percussion and cymbal crashes, fortissimo",
                "a bold imperial march",
            ], ["heroic imperial march", "B flat major", "brass fanfare", "cymbal crashes", "fortissimo"],
                adherence="medium"),
            section("Bridge - the cost of empire", 17000, [
                "G minor, a solo violin lament over muted strings, pianissimo, bittersweet",
            ], ["bittersweet lament", "G minor", "solo violin", "muted strings", "pianissimo"],
                ["drums", "brass"], "low"),
            section("Theme C - salon nocturne", 16000, [
                "D flat major, an intimate piano nocturne with a soft clarinet, rubato, pianissimo",
            ], ["intimate piano nocturne", "D flat major", "soft clarinet", "rubato"], ["drums"], "low"),
            section("Theme C - triumph", 17000, [
                "full symphony orchestra and wordless choir, the main theme in F major, broad and glorious",
                "fortissimo, soaring strings and cymbals, triumphant",
            ], ["glorious symphonic triumph", "wordless choir", "soaring strings", "fortissimo"]),
            section("Coda - twilight", 17000, [
                "solo horn and piano quietly restate the theme in F major",
                "decrescendo, leading back to the beginning",
            ], ["gentle decrescendo coda", "F major", "solo horn and piano recall the theme",
                "seamless loop back"]),
        ],
        "zoom_close_prompt": "Bustling nineteenth-century harbor city street: crowd murmur, horse carriages on "
                             "cobblestones, distant workshop machinery, no music",
        "zoom_far_prompt": "Vast ocean wind over a continental empire seen from high above, soft distant waves, "
                           "distant seagulls, airy and wide, no music, no tonal hum",
        "transition_file": "trans_kingdom_to_empire.wav",
        "transition": {
            "bpm": "92 BPM",
            "bridge": ["royal bells and strings in C major build into a thrilling full-orchestra crescendo",
                       "timpani roll and harp glissando"],
            "fanfare": ["glorious F major symphonic fanfare with triumphant French horns and soaring strings",
                        "concert grand piano, cymbals and a wordless choir"],
            "fanfare_styles": ["triumphant imperial ascension fanfare", "glorious F major resolution",
                               "late-romantic symphony orchestra", "soaring strings and horns"],
        },
    },
]


def transition_plan(spec: dict) -> dict:
    t = spec["transition"]
    base = ["orchestral era transition for a grand historical strategy game", t["bpm"]] + HIFI
    chunks = [
        section("Bridge", 6000, t["bridge"], ["rising anticipation", "crescendo"], adherence="medium"),
        section("Fanfare", 9000, t["fanfare"], t["fanfare_styles"] + ["fortissimo then a ringing final chord"],
                adherence="high"),
    ]
    return build_composition_plan(base, chunks)


# ---------------------------------------------------------------------------------------------------------
# Era processing
# ---------------------------------------------------------------------------------------------------------

def generate_music_pcm(api_key: str, plan: dict) -> bytes:
    return api_post_json("https://api.elevenlabs.io/v1/music?output_format=pcm_48000", api_key,
                         {"model_id": "music_v2_5", "composition_plan": plan})


def generate_ambience(api_key: str, prompt: str) -> bytes:
    payload = {"text": prompt, "duration_seconds": 22.0, "loop": True, "prompt_influence": 0.5}
    try:
        return api_post_json("https://api.elevenlabs.io/v1/sound-generation?output_format=wav_48000", api_key,
                             payload)
    except RuntimeError as e:
        print(f"  [ambience] wav_48000 rejected ({e}); falling back to mp3_44100_192")
        return api_post_json("https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_192",
                             api_key, payload)


def process_era(spec: dict, api_key: str | None, args: argparse.Namespace, rng: np.random.Generator) -> None:
    key = spec["key"]
    prefix = spec["prefix"]
    intro_sec = float(spec["intro_sec"])
    loop_sec = float(spec["loop_sec"])
    total_sec = intro_sec + 3.0 * loop_sec
    total_n = int(round(total_sec * SR))
    plan_sec = sum(c["duration_ms"] for c in spec["chunks"]) / 1000.0
    assert abs(plan_sec - total_sec) < 1e-6, f"{key}: plan {plan_sec}s != timeline {total_sec}s"

    work = WORK_ROOT / f"fmod_{key}"
    cache = work / CACHE_DIR_NAME
    out_dir = work / "audio"
    cache.mkdir(parents=True, exist_ok=True)

    print("\n" + "=" * 92)
    print(f"{key}: v3 suite {total_sec:.0f}s ({len(spec['chunks'])} sections)")
    print("=" * 92)

    # 1. Master (lossless PCM)
    master_path = cache / "master_48k.pcm"
    plan = build_composition_plan(spec["identity"], spec["chunks"])
    if args.force_music or not master_path.exists():
        if api_key is None:
            raise RuntimeError(f"{key}: no cached master and --no-api given")
        print("[1/5] Composing master via /v1/music (pcm_48000) ...")
        (cache / "composition_plan.json").write_text(json.dumps(plan, indent=2), encoding="utf-8")
        master_path.write_bytes(generate_music_pcm(api_key, plan))
    else:
        print(f"[1/5] Reusing cached master {master_path}")
    raw_master = pcm16_bytes_to_float(master_path.read_bytes())
    got_sec = raw_master.shape[0] / SR
    print(f"  master length {got_sec:.2f}s (timeline {total_sec:.2f}s)")
    if got_sec < total_sec - 0.25:
        print("  WARNING: master shorter than timeline; the tail will be padded with silence")
    master = fit_length(raw_master, total_n)

    # 2. Local separation
    print("[2/5] Separating stems ...")
    stems = separate_stems(master, cache, force=args.force_music or args.force_separation)

    # 3. Exact-sum layers, loop prep, common gain
    print("[3/5] Building exact-sum layers ...")
    base, rhythm, chorus = build_layers(master, stems)
    report_sections(spec, master, (base, rhythm, chorus))
    base, rhythm, chorus = (make_loop_seamless(x, intro_sec, loop_sec) for x in (base, rhythm, chorus))
    full = base + rhythm + chorus
    gain, lufs, tp = common_gain(full, [base, rhythm, chorus], MUSIC_TARGET_LUFS)
    print(f"  common gain {20 * math.log10(gain):+.2f} dB -> full mix {lufs:.1f} LUFS, true peak {tp:.1f} dBTP")

    # 4. Ambience beds
    ambience: dict[str, np.ndarray] = {}
    for tag, prompt_key in (("zoom_close", "zoom_close_prompt"), ("zoom_far", "zoom_far_prompt")):
        amb_path = cache / f"{tag}.bin"
        if args.force_ambience or not amb_path.exists():
            if api_key is None:
                raise RuntimeError(f"{key}: no cached {tag} and --no-api given")
            print(f"[4/5] Generating {tag} ambience ...")
            amb_path.write_bytes(generate_ambience(api_key, spec[prompt_key]))
        else:
            print(f"[4/5] Reusing cached {tag} ambience")
        loop_audio = decode_with_ffmpeg(amb_path.read_bytes())
        bed = make_loop_seamless(tile_loop(loop_audio, total_n), intro_sec, loop_sec)
        g, l, p = common_gain(bed, [], AMBIENCE_TARGET_LUFS)
        ambience[tag] = bed * g
        print(f"  {tag}: {l:.1f} LUFS, true peak {p:.1f} dBTP")

    outputs = [
        (f"{prefix}base_core.wav", base * gain),
        (f"{prefix}pop_rhythm.wav", rhythm * gain),
        (f"{prefix}pop_chorus.wav", chorus * gain),
        (f"{prefix}zoom_close.wav", ambience["zoom_close"]),
        (f"{prefix}zoom_far.wav", ambience["zoom_far"]),
    ]
    for name, audio in outputs:
        for target in (out_dir, REPO_FLAT_ASSET_DIR):
            write_wav16(target / name, audio, rng)
        peak = 20 * math.log10(float(np.max(np.abs(audio))) + 1e-12)
        print(f"  [OK] {name:26s} {audio.shape[0] / SR:6.2f}s  {integrated_lufs(audio):6.1f} LUFS  "
              f"sample peak {peak:5.1f} dBFS")
    # Full-mix reference for listening and A/B against the old suite.
    write_wav16(out_dir / f"{prefix}reference_full_mix.wav", full * gain, rng)

    # 5. Era transition fanfare
    trans_file = spec.get("transition_file")
    if trans_file and not args.skip_transitions:
        trans_path = cache / "transition_48k.pcm"
        if args.force_transitions or args.force_music or not trans_path.exists():
            if api_key is None:
                raise RuntimeError(f"{key}: no cached transition and --no-api given")
            print(f"[5/5] Composing transition {trans_file} ...")
            trans_path.write_bytes(generate_music_pcm(api_key, transition_plan(spec)))
        else:
            print(f"[5/5] Reusing cached transition {trans_file}")
        trans = shape_transition_envelope(pcm16_bytes_to_float(trans_path.read_bytes()))
        g, l, p = common_gain(trans, [], TRANSITION_TARGET_LUFS)
        for target in (out_dir, REPO_FLAT_ASSET_DIR):
            write_wav16(target / trans_file, trans * g, rng)
        print(f"  [OK] {trans_file:26s} {trans.shape[0] / SR:6.2f}s  {l:6.1f} LUFS  true peak {p:5.1f} dBTP")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--eras", default="all", help="comma list of era keys (stone_age,...) or 'all'")
    parser.add_argument("--force-music", action="store_true", help="re-compose masters (costs credits)")
    parser.add_argument("--force-separation", action="store_true", help="re-run Demucs on cached masters")
    parser.add_argument("--force-ambience", action="store_true", help="re-generate ambience beds")
    parser.add_argument("--force-transitions", action="store_true", help="re-compose transition fanfares")
    parser.add_argument("--skip-transitions", action="store_true")
    parser.add_argument("--no-api", action="store_true", help="never call ElevenLabs; fail if cache is missing")
    args = parser.parse_args()

    wanted = None if args.eras == "all" else {e.strip() for e in args.eras.split(",") if e.strip()}
    specs = [s for s in ERA_SPECS if wanted is None or s["key"] in wanted]
    if not specs:
        raise SystemExit(f"No era matches {args.eras!r}")
    api_key = None if args.no_api else load_api_key()
    rng = np.random.default_rng(20261022)
    for spec in specs:
        process_era(spec, api_key, args, rng)
    print("\n=== v3 era suites generated ===")


if __name__ == "__main__":
    main()

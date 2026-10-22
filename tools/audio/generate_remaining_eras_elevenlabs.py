"""Generate Agrarian Age, Kingdom Age, and Empire Age interactive music suites + Era Transitions via ElevenLabs API.

Follows the project-keynes-fmod-elevenlabs-audio skill pipeline:
  1. POST /v1/music (music_v2_5 CompositionPlan) for each era's 4-section master track + 2.4s loop wrap tail.
  2. POST /v1/music/stem-separation (six_stems_v1) for phase-locked Base_Core, Pop_Rhythm, and Pop_Chorus stems.
  3. POST /v1/sound-generation (mp3_44100_192, loop=True) for tonal choir pads and CameraZoom Close/Far soundscapes.
  4. POST /v1/music (music_v2_5 CompositionPlan, 9600ms) for the 3 era upgrade transition fanfares.
  5. Equal-power loop wrapping at exact section markers and RMS normalization.
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
TAIL_SEC = 2.4
TRANS_DUR_SEC = 9.6
TRANS_SAMPLES = int(round(TRANS_DUR_SEC * SR))

ROOT = Path(__file__).resolve().parents[2]
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


def api_post_json(url: str, api_key: str, payload: dict, timeout: int = 360) -> bytes:
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


def api_post_multipart(
    url: str,
    api_key: str,
    fields: dict[str, str],
    file_field: str,
    file_name: str,
    file_bytes: bytes,
    content_type: str = "audio/mpeg",
    timeout: int = 600,
) -> bytes:
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
    n = audio.shape[0]
    if n >= target_samples:
        return audio[:target_samples].copy()
    out = np.zeros((target_samples, 2), dtype=np.float64)
    out[:n] = audio
    return out


def wrap_loop_boundaries(buf_ext: np.ndarray, intro_sec: float, loop_sec: float) -> np.ndarray:
    total_dur = intro_sec + 3.0 * loop_sec
    n_samples = int(round(total_dur * SR))
    out = buf_ext[:n_samples].copy()

    xfade_sec = 0.45
    xfade_n = int(round(xfade_sec * SR))
    t = np.linspace(0.0, 1.0, xfade_n, dtype=np.float64)[:, None]
    fade_in = np.sin(0.5 * math.pi * t)
    fade_out = np.cos(0.5 * math.pi * t)

    loop_a_idx = int(round(intro_sec * SR))
    tail = buf_ext[n_samples:n_samples + xfade_n]
    if tail.shape[0] == xfade_n:
        out[loop_a_idx:loop_a_idx + xfade_n] = (
            out[loop_a_idx:loop_a_idx + xfade_n] * fade_in + tail * fade_out
        )

    micro_n = int(round(0.08 * SR))
    mt = np.linspace(0.0, 1.0, micro_n, dtype=np.float64)[:, None]
    m_in = np.sin(0.5 * math.pi * mt)
    m_out = np.cos(0.5 * math.pi * mt)
    b_start = intro_sec + loop_sec
    c_start = intro_sec + 2.0 * loop_sec
    for sec_start, sec_end in [(intro_sec, b_start), (b_start, c_start), (c_start, total_dur)]:
        i_start = int(round(sec_start * SR))
        i_end = int(round(sec_end * SR))
        head = out[i_start:i_start + micro_n].copy()
        out[i_end - micro_n:i_end] = out[i_end - micro_n:i_end] * m_out + head * m_in

    return out


def tile_loop_to_timeline(loop_audio: np.ndarray, intro_sec: float, loop_sec: float) -> np.ndarray:
    total_dur = intro_sec + 3.0 * loop_sec
    n_ext = int(round((total_dur + TAIL_SEC) * SR))
    out = np.zeros((n_ext, 2), dtype=np.float64)
    xfade_n = min(int(round(1.2 * SR)), loop_audio.shape[0] // 4)
    step = loop_audio.shape[0] - xfade_n
    t = np.linspace(0.0, 1.0, xfade_n, dtype=np.float64)[:, None]
    fade_in = np.sin(0.5 * math.pi * t)
    fade_out = np.cos(0.5 * math.pi * t)

    pos = 0
    first = True
    while pos < n_ext:
        chunk = loop_audio.copy()
        if not first and xfade_n > 0:
            chunk[:xfade_n] *= fade_in
            out[pos:min(n_ext, pos + xfade_n)] *= fade_out[:max(0, min(n_ext - pos, xfade_n))]
        n_copy = min(chunk.shape[0], n_ext - pos)
        out[pos:pos + n_copy] += chunk[:n_copy]
        pos += step
        first = False
    return wrap_loop_boundaries(out, intro_sec, loop_sec)


def shape_transition_envelope(audio: np.ndarray) -> np.ndarray:
    """Ensure a clean 9.6s fanfare with a gentle 60ms attack and 650ms natural resonant fade-out."""
    out = fit_length(audio, TRANS_SAMPLES)
    atk_n = int(round(0.06 * SR))
    rel_n = int(round(0.65 * SR))
    out[:atk_n] *= np.linspace(0.0, 1.0, atk_n, dtype=np.float64)[:, None]
    rel_curve = np.cos(0.5 * math.pi * np.linspace(0.0, 1.0, rel_n, dtype=np.float64))[:, None]
    out[-rel_n:] *= rel_curve
    return out


def normalize_stem(audio: np.ndarray, target_rms_db: float = -20.0, peak_limit_db: float = -1.2) -> tuple[np.ndarray, float, float]:
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


ERA_SPECS = [
    {
        "key": "agrarian_age",
        "folder": "AgrarianAge",
        "prefix": "stem_agr_",
        "intro_sec": 12.0,
        "loop_sec": 15.0,
        "base_styles": [
            "ancient Chinese pastoral agrarian soundtrack",
            "silk and bamboo acoustic chamber ensemble",
            "80 BPM",
            "G major pentatonic pastoral mode",
            "bamboo flute dizi",
            "ancient plucked silk-string guse zither",
            "bamboo panpipes paixiao and lusheng reed pipe",
            "mellow clay xun ocarina",
            "warm earthenware harvest drum and grain shakers",
            "sunlit acoustic village atmosphere",
            "great production quality",
        ],
        "neg_styles": [
            "modern synthesizer",
            "electric guitar",
            "pop vocals",
            "lyrics",
            "trap hi-hats",
            "edm",
            "heavy distortion",
            "western rock drums",
        ],
        "chunks": [
            (
                "[Instrumental Intro]\n{clear ancient bronze bell chime at dawn, shimmering bamboo panpipe chord, flowing silk-string guse zither arpeggio, gentle bamboo flute dizi opening}",
                12000,
                ["pastoral dawn intro", "ancient bronze bell chime", "flowing guse zither", "gentle bamboo flute"],
            ),
            (
                "[Instrumental Theme A]\n{warm lyrical bamboo flute dizi playing a sunlit G pentatonic pastoral melody, plucked guse zither accompaniment, steady springtime earthenware harvest drum groove}",
                15000,
                ["lyrical bamboo dizi lead", "plucked silk zither", "steady harvest drum pulse", "pastoral melody"],
            ),
            (
                "[Instrumental Theme B]\n{airy bamboo panpipes paixiao and lusheng reed pipe duet, crystalline guse zither harmonics, subtle bronze hand bells and bamboo percussion}",
                15000,
                ["bamboo panpipe and reed pipe duet", "zither harmonics", "gentle bronze bells", "breezy terraced fields"],
            ),
            (
                "[Instrumental Theme C]\n{mellow clay xun ocarina and high bamboo flute harmony, rolling zither arpeggios, warm wordless harvest clan choir humming}",
                17400,
                ["clay ocarina and flute duet", "rolling zither arpeggios", "warm wordless harvest choir humming"],
            ),
        ],
        "choir_prompt": "Ancient pastoral harvest ceremony wordless mixed choir humming and gentle bronze chime bell harmonics in G major pentatonic, warm sunlit vocal pad, no drums",
        "zoom_close_prompt": "Peaceful ancient farming village irrigation water brook babbling, wooden waterwheel turning, stone grain millstone grinding softly, morning meadow songbirds chirping",
        "zoom_far_prompt": "Warm monsoon breeze sweeping across vast golden wheat fields and terraced valleys, subtle celestial bronze bell harmonic overtone drone in G",
        "transition_file": "trans_stone_to_agrarian.wav",
        "transition_plan": {
            "chunks": [
                {
                    "text": "[Instrumental Fanfare]\n{prehistoric bone horn and stone chimes resolving upward into a radiant G major bronze bell chime, jubilant bamboo flute dizi, panpipes, and sweeping silk zither celebration}",
                    "duration_ms": 9600,
                    "positive_styles": [
                        "uplifting era advancement fanfare",
                        "80 BPM",
                        "D to G major pentatonic triumphant resolution",
                        "ancient bronze bells",
                        "bamboo flute dizi and panpipes",
                        "sweeping guse silk zither",
                        "ceremonial harvest drums",
                        "great production quality",
                    ],
                    "negative_styles": ["lyrics", "pop vocals", "electric guitar", "modern synth", "edm"],
                    "context_adherence": "high",
                }
            ]
        },
    },
    {
        "key": "kingdom_age",
        "folder": "KingdomAge",
        "prefix": "stem_kng_",
        "intro_sec": 11.2,
        "loop_sec": 14.0,
        "base_styles": [
            "ancient Chinese royal court Yayue ritual music",
            "Bronze Age and Warring States ceremonial ensemble",
            "85 BPM",
            "C Lydian Yayue court mode",
            "Zeng Hou Yi bronze chime bells bianzhong",
            "jade stone chimes bianqing",
            "seven-string guqin zither and ruan lute",
            "regal sheng mouth organ",
            "deep ceremonial jiangu court drum",
            "majestic palace hall acoustics",
            "great production quality",
        ],
        "neg_styles": [
            "modern synthesizer",
            "electric guitar",
            "pop vocals",
            "lyrics",
            "trap hi-hats",
            "edm",
            "distortion",
        ],
        "chunks": [
            (
                "[Instrumental Intro]\n{deep resonant bronze bo-bell strike, majestic Zeng Hou Yi bronze chime bells bianzhong and jade chimes bianqing, regal sheng mouth organ chord, noble guqin glissando}",
                11200,
                ["majestic royal court intro", "deep bronze bo-bell", "bianzhong chime bells", "regal sheng mouth organ"],
            ),
            (
                "[Instrumental Theme A]\n{noble bronze chime bells bianzhong and jade chimes playing a stately C Yayue court melody, warm sheng mouth organ harmony, dignified jiangu court drum march}",
                14000,
                ["stately bianzhong bell melody", "jade chimes", "dignified court drum rhythm", "regal palace music"],
            ),
            (
                "[Instrumental Theme B]\n{rhythmic plucked zhongruan lute and pipa arpeggios, expressive bamboo xiao and dizi flute melody, crisp jade chimes and wooden clappers}",
                14000,
                ["plucked ruan and pipa groove", "expressive court flute melody", "crisp jade chimes", "prosperous royal capital"],
            ),
            (
                "[Instrumental Theme C]\n{contemplative seven-string guqin harmonics in dialogue with deep洞箫 xiao flute, shimmering bronze bells, solemn royal ancestral temple choir humming}",
                16400,
                ["guqin harmonics and deep xiao flute", "shimmering bronze chime bells", "solemn royal temple wordless choir"],
            ),
        ],
        "choir_prompt": "Solemn ancient royal court ceremonial choir wordless harmony and resonant bronze chime bell overtones in C major, majestic palace temple vocal pad, no drums",
        "zoom_close_prompt": "Ancient royal capital artisan quarter foley, rhythmic blacksmith hammer ringing on iron anvil, stonecutter chiseling city wall blocks, bronze coins clinking softly",
        "zoom_far_prompt": "High mountain fortress pass wind flapping heavy silk royal banners, deep resonant bronze bell and earth horizon harmonic drone in C",
        "transition_file": "trans_agrarian_to_kingdom.wav",
        "transition_plan": {
            "chunks": [
                {
                    "text": "[Instrumental Fanfare]\n{pastoral bamboo flute resolving into a monumental royal bronze bo-bell strike, grand Zeng Hou Yi bianzhong chime bells, jade chimes, regal sheng and ceremonial court drums proclaiming a kingdom}",
                    "duration_ms": 9600,
                    "positive_styles": [
                        "majestic royal coronation fanfare",
                        "85 BPM",
                        "G to C major regal Yayue resolution",
                        "monumental Zeng Hou Yi bronze chime bells",
                        "jade chimes bianqing",
                        "regal sheng mouth organ and bronze horns",
                        "ceremonial court drums",
                        "great production quality",
                    ],
                    "negative_styles": ["lyrics", "pop vocals", "electric guitar", "modern synth", "edm"],
                    "context_adherence": "high",
                }
            ]
        },
    },
    {
        "key": "empire_age",
        "folder": "EmpireAge",
        "prefix": "stem_emp_",
        "intro_sec": 10.4,
        "loop_sec": 13.0,
        "base_styles": [
            "grand imperial Chinese Tang dynasty Yanyue orchestral soundtrack",
            "epic East-meets-West historical strategy game symphony",
            "92 BPM",
            "F major grand orchestral mode",
            "soaring orchestral strings and erhu ensemble",
            "virtuosic pipa and guzheng zither",
            "shimmering ten-gong yunluo chimes",
            "majestic imperial brass horns",
            "thunderous tanggu hall drums",
            "grand concert hall production quality",
            "great production quality",
        ],
        "neg_styles": [
            "modern electronic synthesizer",
            "electric guitar",
            "pop vocals",
            "lyrics",
            "trap hi-hats",
            "edm",
            "dubstep",
        ],
        "chunks": [
            (
                "[Instrumental Intro]\n{majestic imperial brass fanfare and shimmering ten-gong yunluo chimes, sweeping guzheng glissando, lush orchestral strings and erhu ensemble opening the golden age}",
                10400,
                ["grand imperial orchestral intro", "majestic brass and yunluo chimes", "sweeping guzheng", "soaring strings"],
            ),
            (
                "[Instrumental Theme A]\n{soaring orchestral strings and expressive erhu playing a glorious F major imperial melody, cascading guzheng arpeggios, powerful tanggu hall drums}",
                13000,
                ["glorious string and erhu melody", "cascading guzheng", "powerful imperial drum pulse", "golden age grandeur"],
            ),
            (
                "[Instrumental Theme B]\n{virtuosic pipa tremolos and plucked lute rhythm, sparkling yunluo gong chimes and metallophones, rich low cello and bass string groove along the Silk Road}",
                13000,
                ["virtuosic pipa lead", "sparkling yunluo chimes", "rich cello rhythmic groove", "cosmopolitan Silk Road metropolis"],
            ),
            (
                "[Instrumental Theme C]\n{noble cello and deep bamboo xiao counterpoint, crystalline guqin and guzheng harmonics, triumphant full orchestra brass and wordless imperial choir}",
                15400,
                ["noble cello and flute counterpoint", "triumphant orchestral brass", "soaring wordless imperial choir"],
            ),
        ],
        "choir_prompt": "Grand imperial symphony wordless mixed choir soaring in F major with warm orchestral string and brass harmonic pad, majestic golden age choral texture, no drums",
        "zoom_close_prompt": "Grand imperial workshop foley, giant wooden waterwheel turning with splashing water, roaring furnace bellows, rhythmic mechanical clockwork gears and woodblock printing press",
        "zoom_far_prompt": "Vast oceanic monsoon wind sweeping across a continental empire, distant silk sails and majestic F major celestial orchestral overtone drone",
        "transition_file": "trans_kingdom_to_empire.wav",
        "transition_plan": {
            "chunks": [
                {
                    "text": "[Instrumental Fanfare]\n{bronze bells expanding into a grand imperial orchestra fanfare in F major, soaring strings, brass horns, cascading guzheng and thunderous tanggu drums}",
                    "duration_ms": 9600,
                    "positive_styles": [
                        "triumphant imperial ascension orchestral fanfare",
                        "92 BPM",
                        "C to F major glorious symphonic resolution",
                        "full orchestral strings and imperial brass",
                        "cascading guzheng and pipa",
                        "shimmering yunluo chimes and tanggu drums",
                        "wordless epic choir",
                        "great production quality",
                    ],
                    "negative_styles": ["lyrics", "pop vocals", "electric guitar", "modern synth", "edm"],
                    "context_adherence": "high",
                }
            ]
        },
    },
]


def process_era(spec: dict, api_key: str, force_regen: bool = False) -> None:
    key_name = spec["key"]
    folder = spec["folder"]
    prefix = spec["prefix"]
    intro_sec = float(spec["intro_sec"])
    loop_sec = float(spec["loop_sec"])
    total_dur = intro_sec + 3.0 * loop_sec
    n_ext = int(round((total_dur + TAIL_SEC) * SR))

    out_dir = ROOT.parent / "tmp" / f"fmod_{key_name}" / "audio"
    cache_dir = ROOT.parent / "tmp" / f"fmod_{key_name}" / "elevenlabs_cache"
    repo_era_dir = ROOT / "Audio" / "ProjectKeynes" / "Assets" / folder
    cache_dir.mkdir(parents=True, exist_ok=True)

    master_mp3_path = cache_dir / f"{key_name}_master.mp3"
    stems_zip_path = cache_dir / f"{key_name}_stems.zip"
    choir_mp3_path = cache_dir / f"{key_name}_choir_pad.mp3"
    zc_mp3_path = cache_dir / f"{key_name}_zoom_close.mp3"
    zf_mp3_path = cache_dir / f"{key_name}_zoom_far.mp3"
    trans_mp3_path = cache_dir / f"{spec['transition_file']}.mp3"

    print(f"\n============================================================")
    print(f"Processing {folder} ({total_dur:.1f}s + Transition {TRANS_DUR_SEC:.1f}s)")
    print(f"============================================================")

    # 1. Master Track
    if force_regen or not master_mp3_path.exists():
        print(f"[1/6] Generating {folder} master track via ElevenLabs /v1/music...")
        chunks_payload = []
        for text, dur_ms, local_styles in spec["chunks"]:
            chunks_payload.append(
                {
                    "text": text,
                    "duration_ms": dur_ms,
                    "positive_styles": spec["base_styles"] + local_styles,
                    "negative_styles": spec["neg_styles"],
                    "context_adherence": "high",
                }
            )
        master_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/music?output_format=mp3_48000_192",
            api_key,
            {"model_id": "music_v2_5", "composition_plan": {"chunks": chunks_payload}},
        )
        master_mp3_path.write_bytes(master_bytes)
        print(f"  -> Saved {master_mp3_path.name} ({len(master_bytes)/1024:.1f} KB)")
    else:
        print(f"[1/6] Reusing cached master track: {master_mp3_path}")
        master_bytes = master_mp3_path.read_bytes()

    # 2. Stem Separation
    if force_regen or not stems_zip_path.exists():
        print(f"[2/6] Separating {folder} master into 6 stems via /v1/music/stem-separation...")
        zip_bytes = api_post_multipart(
            "https://api.elevenlabs.io/v1/music/stem-separation",
            api_key,
            fields={"stem_variation_id": "six_stems_v1"},
            file_field="file",
            file_name=f"{key_name}_master.mp3",
            file_bytes=master_bytes,
            content_type="audio/mpeg",
        )
        stems_zip_path.write_bytes(zip_bytes)
        print(f"  -> Saved {stems_zip_path.name} ({len(zip_bytes)/1024:.1f} KB)")
    else:
        print(f"[2/6] Reusing cached stems ZIP: {stems_zip_path}")

    stem_buffers: dict[str, np.ndarray] = {}
    with zipfile.ZipFile(stems_zip_path, "r") as zf:
        for member in zf.namelist():
            if member.endswith("/"):
                continue
            raw_b = zf.read(member)
            low_name = Path(member).stem.lower()
            arr = fit_length(decode_audio_bytes_to_numpy(raw_b, SR), n_ext)
            stem_buffers[low_name] = arr
            rms_val = 20.0 * math.log10(float(np.sqrt(np.mean(arr ** 2) + 1e-12)))
            print(f"  -> Decoded stem '{low_name}' (RMS={rms_val:.1f} dBFS)")

    full_master = fit_length(decode_audio_bytes_to_numpy(master_bytes, SR), n_ext)

    def pick_stems(keywords: list[str]) -> np.ndarray:
        acc = np.zeros((n_ext, 2), dtype=np.float64)
        matched = False
        for k, v in stem_buffers.items():
            if any(kw in k for kw in keywords):
                acc += v
                matched = True
        return acc if matched else np.zeros((n_ext, 2), dtype=np.float64)

    melodic_stem = pick_stems(["other", "piano", "guitar", "synth", "wind", "strings", "melod", "instrument"])
    rhythm_stem = pick_stems(["drum", "bass", "perc"])
    chorus_stem = pick_stems(["vocal", "choir", "voice"])

    if float(np.sqrt(np.mean(melodic_stem ** 2))) < 1e-3:
        melodic_stem = full_master * 0.85
    if float(np.sqrt(np.mean(rhythm_stem ** 2))) < 1e-3:
        rhythm_stem = full_master * 0.55

    # 3. Tonal Choir Pad for Pop_Chorus
    if force_regen or not choir_mp3_path.exists():
        print(f"[3/6] Generating {folder} choir pad via /v1/sound-generation...")
        choir_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_192",
            api_key,
            {
                "text": spec["choir_prompt"],
                "duration_seconds": 16.0,
                "loop": True,
                "prompt_influence": 0.55,
            },
        )
        choir_mp3_path.write_bytes(choir_bytes)
    else:
        print(f"[3/6] Reusing cached choir pad: {choir_mp3_path}")
        choir_bytes = choir_mp3_path.read_bytes()

    choir_tiled = tile_loop_to_timeline(decode_audio_bytes_to_numpy(choir_bytes, SR), intro_sec, loop_sec)
    choir_norm, _, _ = normalize_stem(choir_tiled, target_rms_db=-21.5, peak_limit_db=-2.0)
    melodic_wrapped = wrap_loop_boundaries(melodic_stem, intro_sec, loop_sec)
    melodic_norm, _, _ = normalize_stem(melodic_wrapped, target_rms_db=-24.0, peak_limit_db=-2.0)
    chorus_wrapped = wrap_loop_boundaries(chorus_stem, intro_sec, loop_sec)

    stem_base_core = melodic_wrapped
    stem_pop_rhythm = wrap_loop_boundaries(rhythm_stem, intro_sec, loop_sec)
    stem_pop_chorus = choir_norm * 0.80 + chorus_wrapped * 2.5 + melodic_norm * 0.35

    # 4. Zoom_Close & Zoom_Far
    if force_regen or not zc_mp3_path.exists():
        print(f"[4/6] Generating {folder} Zoom_Close soundscape via /v1/sound-generation...")
        zc_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_192",
            api_key,
            {
                "text": spec["zoom_close_prompt"],
                "duration_seconds": 16.0,
                "loop": True,
                "prompt_influence": 0.45,
            },
        )
        zc_mp3_path.write_bytes(zc_bytes)
    else:
        print(f"[4/6] Reusing cached Zoom_Close: {zc_mp3_path}")
        zc_bytes = zc_mp3_path.read_bytes()

    if force_regen or not zf_mp3_path.exists():
        print(f"[5/6] Generating {folder} Zoom_Far soundscape via /v1/sound-generation...")
        zf_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/sound-generation?output_format=mp3_44100_192",
            api_key,
            {
                "text": spec["zoom_far_prompt"],
                "duration_seconds": 16.0,
                "loop": True,
                "prompt_influence": 0.45,
            },
        )
        zf_mp3_path.write_bytes(zf_bytes)
    else:
        print(f"[5/6] Reusing cached Zoom_Far: {zf_mp3_path}")
        zf_bytes = zf_mp3_path.read_bytes()

    stem_zoom_close = tile_loop_to_timeline(decode_audio_bytes_to_numpy(zc_bytes, SR), intro_sec, loop_sec)
    stem_zoom_far = tile_loop_to_timeline(decode_audio_bytes_to_numpy(zf_bytes, SR), intro_sec, loop_sec)

    stems = [
        (f"{prefix}base_core.wav", stem_base_core, -18.5),
        (f"{prefix}pop_rhythm.wav", stem_pop_rhythm, -19.5),
        (f"{prefix}pop_chorus.wav", stem_pop_chorus, -20.0),
        (f"{prefix}zoom_close.wav", stem_zoom_close, -21.5),
        (f"{prefix}zoom_far.wav", stem_zoom_far, -20.5),
    ]

    for filename, raw_audio, target_rms in stems:
        norm_audio, rms_db, peak_db = normalize_stem(raw_audio, target_rms_db=target_rms, peak_limit_db=-1.2)
        for target_dir in [out_dir, repo_era_dir, REPO_FLAT_ASSET_DIR]:
            write_wav(target_dir / filename, norm_audio)
        print(f"  [OK] {filename:24s} dur={norm_audio.shape[0]/SR:5.2f}s RMS={rms_db:6.2f} dBFS Peak={peak_db:6.2f} dBFS")

    # 6. Era Transition Fanfare (9.60s)
    trans_file = spec["transition_file"]
    if force_regen or not trans_mp3_path.exists():
        print(f"[6/6] Generating transition fanfare {trans_file} (9.6s) via /v1/music...")
        trans_bytes = api_post_json(
            "https://api.elevenlabs.io/v1/music?output_format=mp3_48000_192",
            api_key,
            {"model_id": "music_v2_5", "composition_plan": spec["transition_plan"]},
        )
        trans_mp3_path.write_bytes(trans_bytes)
    else:
        print(f"[6/6] Reusing cached transition fanfare: {trans_mp3_path}")
        trans_bytes = trans_mp3_path.read_bytes()

    trans_raw = shape_transition_envelope(decode_audio_bytes_to_numpy(trans_bytes, SR))
    trans_norm, t_rms, t_peak = normalize_stem(trans_raw, target_rms_db=-17.5, peak_limit_db=-1.0)
    for target_dir in [out_dir, repo_era_dir, REPO_FLAT_ASSET_DIR]:
        write_wav(target_dir / trans_file, trans_norm)
    print(f"  [OK] {trans_file:24s} dur={trans_norm.shape[0]/SR:5.2f}s RMS={t_rms:6.2f} dBFS Peak={t_peak:6.2f} dBFS")


def main() -> None:
    api_key = load_api_key()
    for spec in ERA_SPECS:
        process_era(spec, api_key, force_regen=False)
    print("\n=== All 3 Remaining Eras + 3 Era Transitions Generated Successfully ===")


if __name__ == "__main__":
    main()

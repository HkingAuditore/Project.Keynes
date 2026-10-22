"""Generate the Agrarian Age (农耕时代) interactive music suite (5 synchronized stereo stems) for FMOD.

Architecture (57.0s total @ 80 BPM, 4/4, 1 beat = 0.75s, 1 bar = 3.0s, G Major Pentatonic / Pastoral Mixolydian):
  - [0.0s .. 12.0s]  (4 bars)  1. 刚进入游戏 (Intro: 晨曦开犁 · 岁首迎春 Dawn of the Agrarian Age)
  - [12.0s .. 27.0s] (5 bars)  2A. 常态循环 I:  《阡陌晨耕》(Morning Ploughing - Bamboo Dizi & 5-String Silk Zither)
  - [27.0s .. 42.0s] (5 bars)  2B. 常态循环 II: 《水渠稻香》(Terraced Paddies - Bamboo Panpipes, Reed Sheng & Zither Harmonics)
  - [42.0s .. 57.0s] (5 bars)  2C. 常态循环 III:《观星授时》(Celestial Calendar - Earthen Xun, Dizi Duet & Bronze Ling)

5 Synchronized Stems:
  1. stem_agr_base_core.wav   - Core Agrarian instruments (Early Bronze Ling Bell intro, Bamboo Dizi, 5-String Silk Zither/Se, Panpipes/Sheng, Clay Xun)
  2. stem_agr_pop_rhythm.wav  - Population Tier 1+ (>=600 pop: Earthenware Harvest Drum 土鼓, Bamboo Pestle 春杵, Grain Shaker, Plucked Bass Lute)
  3. stem_agr_pop_chorus.wav  - Population Tier 2+ (>=1600 pop: Sunlit Harvest Formant Choir 社祭丰收合唱, Ceremonial Bronze Chimes, High Dizi Counter-Melody)
  4. stem_agr_zoom_close.wav  - Camera Zoom-In (Babbling Irrigation Canal 水渠潺潺, Millstone & Threshing 石磨春谷, Meadow Songbirds 田间晨鸟)
  5. stem_agr_zoom_far.wav    - Camera Zoom-Out (Golden Plain Monsoon 沃野季风, Celestial Calendar Harmonics 历法星穹泛音, Deep Loess Drone 大地低音)
"""

from __future__ import annotations

import math
from pathlib import Path
import wave
import numpy as np
from scipy import signal

SR = 32000
BPM = 80.0
BEAT = 60.0 / BPM          # 0.75s
BAR = BEAT * 4.0           # 3.0s
INTRO_BARS = 4             # 12.0s
LOOP_SECTION_BARS = 5      # 15.0s each
TOTAL_BARS = INTRO_BARS + 3 * LOOP_SECTION_BARS  # 19 bars = 57.0s
TOTAL_DUR = TOTAL_BARS * BAR
N_SAMPLES = int(round(TOTAL_DUR * SR))

# Render extra tail for seamless circular loop wrapping at bar boundaries
TAIL_SEC = 2.4
N_EXT = N_SAMPLES + int(round(TAIL_SEC * SR))

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT.parent / "tmp" / "fmod_agrarian_age" / "audio"
REPO_ASSET_DIR = ROOT / "Audio" / "ProjectKeynes" / "Assets" / "AgrarianAge"

# Pitch table (Hz) - G Major Pentatonic / Pastoral Mixolydian (G - A - B - C - D - E - F/F#)
NOTES = {
    "G1": 49.00, "A1": 55.00, "D2": 73.42, "E2": 82.41,
    "G2": 98.00, "A2": 110.00, "B2": 123.47, "C3": 130.81, "D3": 146.83, "E3": 164.81, "F3": 174.61, "F#3": 185.00,
    "G3": 196.00, "A3": 220.00, "B3": 246.94, "C4": 261.63, "D4": 293.66, "E4": 329.63, "F4": 349.23, "F#4": 369.99,
    "G4": 392.00, "A4": 440.00, "B4": 493.88, "C5": 523.25, "D5": 587.33, "E5": 659.25, "F#5": 739.99,
    "G5": 783.99, "A5": 880.00, "B5": 987.77, "D6": 1174.66,
}


def n2f(note: str) -> float:
    return NOTES[note]


def pan_stereo(mono: np.ndarray, pan: float = 0.0, haas_ms: float = 0.0) -> np.ndarray:
    """Constant-power stereo panner (-1.0 left .. +1.0 right) with optional Haas micro-delay."""
    angle = (pan + 1.0) * 0.25 * math.pi
    gl = math.cos(angle)
    gr = math.sin(angle)
    left = mono * gl
    right = mono * gr
    if abs(haas_ms) > 0.05:
        d = int(round(abs(haas_ms) * 0.001 * SR))
        if d > 0 and d < len(mono):
            if haas_ms > 0:
                right = np.pad(right[:-d], (d, 0))
            else:
                left = np.pad(left[:-d], (d, 0))
    return np.stack([left, right], axis=1)


def add_clip(buf: np.ndarray, start_s: float, clip_stereo: np.ndarray, gain: float = 1.0) -> None:
    i0 = int(round(start_s * SR))
    if i0 >= buf.shape[0]:
        return
    n = min(clip_stereo.shape[0], buf.shape[0] - i0)
    if n <= 0:
        return
    buf[i0:i0 + n] += clip_stereo[:n] * gain


def make_pastoral_valley_ir(rt60: float = 1.85, wet_highcut: float = 4600.0, seed: int = 108) -> np.ndarray:
    """Create a warm open-air river-valley & timber-courtyard stereo impulse response."""
    rng = np.random.default_rng(seed)
    n = int(round(rt60 * SR))
    t = np.arange(n, dtype=np.float64) / SR
    decay = np.exp(-6.9078 * t / rt60)
    noise_l = rng.standard_normal(n) * decay
    noise_r = rng.standard_normal(n) * decay
    env = 1.0 - np.exp(-t / 0.028)
    noise_l *= env
    noise_r *= env
    er_times = [0.016, 0.029, 0.044, 0.068, 0.097, 0.142, 0.195]
    er_gains = [0.42, 0.34, 0.26, 0.20, 0.14, 0.10, 0.07]
    for idx, (et, eg) in enumerate(zip(er_times, er_gains)):
        pos = int(round(et * SR))
        if pos < n:
            if idx % 2 == 0:
                noise_l[pos] += eg
                noise_r[min(n - 1, pos + 17)] += eg * 0.72
            else:
                noise_r[pos] += eg
                noise_l[min(n - 1, pos + 21)] += eg * 0.72
    sos = signal.butter(2, [120.0 / (0.5 * SR), wet_highcut / (0.5 * SR)], btype="bandpass", output="sos")
    ir_l = signal.sosfilt(sos, noise_l)
    ir_r = signal.sosfilt(sos, noise_r)
    norm = max(np.max(np.abs(ir_l)), np.max(np.abs(ir_r)), 1e-6)
    return np.stack([ir_l / norm, ir_r / norm], axis=1)


def apply_reverb(stereo: np.ndarray, ir: np.ndarray, wet: float = 0.25) -> np.ndarray:
    if wet <= 0.001:
        return stereo
    n = stereo.shape[0]
    rev_l = signal.fftconvolve(stereo[:, 0], ir[:, 0])[:n]
    rev_r = signal.fftconvolve(stereo[:, 1], ir[:, 1])[:n]
    rev = np.stack([rev_l, rev_r], axis=1)
    return stereo * (1.0 - 0.32 * wet) + rev * (wet * 0.17)


# ==============================================================================
# Physical Modeling Instruments for the Agrarian Age (农耕时代)
# ==============================================================================

def synth_bamboo_dizi(
    freq: float,
    dur: float,
    vel: float = 0.82,
    grace_from: float | None = None,
    vibrato_depth: float = 0.0075,
    seed: int = 11,
) -> np.ndarray:
    """Pastoral Bamboo Flute (竹笛/横笛): warm bamboo tube + bright reed-membrane (笛膜) harmonic shimmer."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.18) * SR))
    t = np.arange(n, dtype=np.float64) / SR

    att = 0.048
    rel = 0.15
    env = np.ones(n, dtype=np.float64)
    att_n = max(1, int(round(att * SR)))
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.3
    arch = 0.86 + 0.14 * np.sin(math.pi * np.clip(t / max(dur, 0.1), 0.0, 1.0))
    env *= arch
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        dt = (i - rel_start) / SR
        env[i] *= math.exp(-dt / (rel * 0.48))

    f_curve = np.full(n, freq, dtype=np.float64)
    if grace_from is not None:
        f_curve = freq + (grace_from - freq) * np.exp(-t / 0.036)
    else:
        f_curve = freq * (1.0 - 0.010 * np.exp(-t / 0.022))

    vib_onset = np.clip((t - 0.18) / 0.22, 0.0, 1.0)
    vib = vibrato_depth * vib_onset * np.sin(2.0 * math.pi * 5.4 * t + rng.uniform(0, 2 * math.pi))
    f_inst = f_curve * (1.0 + vib)
    phase = 2.0 * math.pi * np.cumsum(f_inst) / SR

    # Bamboo pipe harmonics + subtle dimo (membrane) odd/even brightness
    h1 = np.sin(phase)
    h2 = 0.62 * np.sin(2.0 * phase + 0.2) * (0.75 + 0.25 * env)
    h3 = 0.42 * np.sin(3.0 * phase + 0.8) * (0.60 + 0.40 * env)
    h4 = 0.22 * np.sin(4.0 * phase + 1.4) * (env ** 1.3)
    h5 = 0.12 * np.sin(5.0 * phase + 0.5) * (env ** 1.6)
    h6 = 0.06 * np.sin(6.0 * phase + 1.9) * (env ** 2.0)
    raw_tone = h1 + h2 + h3 + h4 + h5 + h6

    # Gentle nonlinear membrane buzz (dimo effect) around 2.2 kHz - 4.2 kHz
    dimo_drive = np.tanh(raw_tone * (1.35 * env)) - raw_tone * 0.85
    sos_dimo = signal.butter(2, [1600.0 / (0.5 * SR), 4800.0 / (0.5 * SR)], btype="bandpass", output="sos")
    dimo = signal.sosfilt(sos_dimo, dimo_drive) * 0.28

    # Gentle bamboo breath chiff
    white = rng.standard_normal(n)
    chiff_env = 0.38 * np.exp(-t / 0.024) + 0.08 * env
    bw_lo = max(400.0, min(freq * 1.8, SR * 0.40))
    bw_hi = max(bw_lo + 500.0, min(freq * 4.5, SR * 0.46))
    sos_air = signal.butter(2, [bw_lo / (0.5 * SR), bw_hi / (0.5 * SR)], btype="bandpass", output="sos")
    air = signal.sosfilt(sos_air, white) * chiff_env

    out = (raw_tone * 0.76 + dimo + air * 0.18) * env * vel * 0.30
    b_peak, a_peak = signal.iirpeak(1450.0 / (0.5 * SR), Q=3.8)
    out = 0.78 * out + 0.22 * signal.lfilter(b_peak, a_peak, out)
    return out


def synth_silk_zither(
    freq: float,
    dur: float = 2.2,
    vel: float = 0.78,
    harmonic_bell: bool = False,
    bend_cents: float = 0.0,
    seed: int = 12,
) -> np.ndarray:
    """Five-String Silk Zither / Gu-Se (五弦古瑟/古琴): warm plucked silk string + paulownia wood body."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR

    f_base = freq * (2.0 if harmonic_bell else 1.0)
    # Optional expressive left-hand pitch bend (吟猱) after pluck
    if abs(bend_cents) > 0.1:
        bend_ratio = (2.0 ** (bend_cents / 1200.0)) - 1.0
        bend_env = np.sin(math.pi * np.clip((t - 0.12) / max(dur * 0.55, 0.2), 0.0, 1.0)) ** 2
        f_curve = f_base * (1.0 + bend_ratio * bend_env)
    else:
        f_curve = np.full(n, f_base, dtype=np.float64)

    phase = 2.0 * math.pi * np.cumsum(f_curve) / SR

    sig = np.zeros(n, dtype=np.float64)
    n_harm = 5 if harmonic_bell else 14
    for k in range(1, n_harm + 1):
        if f_base * k >= SR * 0.45:
            break
        # Silk strings have warm fundamental/low harmonics and gentle high-partial damping
        amp = (1.0 / (k ** (1.45 if harmonic_bell else 1.18))) * (0.85 if k % 2 == 0 else 1.0)
        tau = (dur * 0.75) / (1.0 + 0.28 * (k - 1))
        # Slight inharmonicity of thick silk strings
        detune = math.sqrt(1.0 + 0.00018 * (k ** 2))
        sig += amp * np.exp(-t / max(tau, 0.04)) * np.sin(k * detune * phase + rng.uniform(0, 0.3))

    # Finger / bamboo plectrum pluck transient
    pluck_env = np.exp(-t / 0.0045)
    pluck_noise = signal.sosfilt(
        signal.butter(2, [350.0 / (0.5 * SR), 3200.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * pluck_env * (0.14 if harmonic_bell else 0.26)

    att_env = 1.0 - np.exp(-t / 0.003)
    out = (sig * att_env + pluck_noise) * vel * 0.26

    # Paulownia hollow wooden soundboard resonances (240 Hz & 580 Hz)
    b1, a1 = signal.iirpeak(240.0 / (0.5 * SR), Q=3.2)
    b2, a2 = signal.iirpeak(580.0 / (0.5 * SR), Q=4.0)
    body = 0.18 * signal.lfilter(b1, a1, out) + 0.14 * signal.lfilter(b2, a2, out)
    return out * 0.82 + body


def synth_panpipes_sheng(
    freq: float,
    dur: float,
    vel: float = 0.72,
    fifth_harmony: bool = True,
    seed: int = 13,
) -> np.ndarray:
    """Bamboo Panpipes & Reed Sheng (排箫/芦笙): airy coupled pipes with fifth/octave pastoral harmony."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.22) * SR))
    t = np.arange(n, dtype=np.float64) / SR

    att_n = max(1, int(round(0.085 * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.5
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.14 * SR))

    vib = 0.0045 * np.sin(2.0 * math.pi * 4.8 * t + rng.uniform(0, 2 * math.pi))
    p1 = 2.0 * math.pi * np.cumsum(freq * (1.0 + vib)) / SR
    voice1 = np.sin(p1) + 0.32 * np.sin(2.0 * p1 + 0.4) + 0.18 * np.sin(3.0 * p1 + 1.1)

    if fifth_harmony:
        f2 = freq * 1.4983  # pure fifth
        p2 = 2.0 * math.pi * np.cumsum(f2 * (1.0 - 0.6 * vib)) / SR
        voice2 = 0.52 * (np.sin(p2) + 0.28 * np.sin(2.0 * p2 + 0.7) + 0.14 * np.sin(3.0 * p2))
    else:
        voice2 = np.zeros(n, dtype=np.float64)

    # Gentle bamboo pipe breath
    breath = signal.sosfilt(
        signal.butter(2, [500.0 / (0.5 * SR), 2800.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * (0.20 * np.exp(-t / 0.04) + 0.07 * env)

    return (voice1 * 0.72 + voice2 * 0.48 + breath * 0.22) * env * vel * 0.26


def synth_clay_xun_warm(freq: float, dur: float, vel: float = 0.72, glide_from: float | None = None, seed: int = 14) -> np.ndarray:
    """Earthen Xun (古陶埙): warm low-mid vessel flute bridging Stone Age roots into Agrarian dusk."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.25) * SR))
    t = np.arange(n, dtype=np.float64) / SR
    att_n = max(1, int(round(0.10 * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.5
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.15 * SR))

    f_curve = np.full(n, freq, dtype=np.float64)
    if glide_from is not None:
        f_curve = freq + (glide_from - freq) * np.exp(-t / 0.06)
    vib = 0.0055 * np.clip((t - 0.25) / 0.25, 0.0, 1.0) * np.sin(2.0 * math.pi * 4.5 * t)
    phase = 2.0 * math.pi * np.cumsum(f_curve * (1.0 + vib)) / SR
    tone = np.sin(phase) + 0.20 * np.sin(2.0 * phase) + 0.22 * np.sin(3.0 * phase + 0.4) * env
    b_cav, a_cav = signal.iirpeak(max(200.0, min(freq * 2.0, 1100.0)) / (0.5 * SR), Q=4.8)
    breath = signal.lfilter(b_cav, a_cav, rng.standard_normal(n)) * (0.18 * np.exp(-t / 0.05) + 0.06 * env)
    return (tone * 0.88 + breath * 0.22) * env * vel * 0.30


def synth_bronze_bell(freq: float, dur: float = 2.8, vel: float = 0.76, seed: int = 15) -> np.ndarray:
    """Early Cast Bronze Ling / Nao Bell (先秦青铜古铃/铜饶/编钟雏形): almond-section two-tone bronze modal synthesis."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR

    # Characteristic two-tone bronze bell modal ratios (fundamental + minor-third/octave + bright partials)
    modes = [1.000, 1.202, 1.996, 2.785, 3.920, 5.310]
    amps = [1.00, 0.48, 0.62, 0.30, 0.16, 0.09]
    decays = [dur * 0.72, dur * 0.55, dur * 0.45, dur * 0.28, dur * 0.16, dur * 0.09]

    sig = np.zeros(n, dtype=np.float64)
    for idx, (ratio, amp, tau) in enumerate(zip(modes, amps, decays)):
        f_m = freq * ratio
        if f_m < SR * 0.45:
            # Subtle bronze acoustic beating on upper modes
            beat = 1.0 + 0.08 * np.sin(2.0 * math.pi * (1.8 + 0.7 * idx) * t)
            sig += amp * np.exp(-t / max(tau, 0.05)) * beat * np.sin(2.0 * math.pi * f_m * t + rng.uniform(0, 0.4))

    # Wooden mallet strike on cast bronze
    strike = signal.sosfilt(
        signal.butter(2, [800.0 / (0.5 * SR), 5200.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.0032) * 0.28

    att_env = 1.0 - np.exp(-t / 0.0015)
    return (sig * att_env + strike) * vel * 0.22


def synth_harvest_clay_drum(freq: float = 68.0, dur: float = 0.52, vel: float = 0.85, rim: bool = False, seed: int = 16) -> np.ndarray:
    """Earthenware Harvest Drum (春耕社祭土鼓/陶鼓): deep warm clay-pot bass resonance + hide membrane."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR

    if rim:
        # Crisp wooden rim / clay body tap
        f0 = freq * 2.35
        env = np.exp(-t / 0.075)
        body = np.sin(2.0 * math.pi * f0 * t) + 0.45 * np.sin(2.0 * math.pi * f0 * 1.62 * t) * np.exp(-t / 0.04)
        click = signal.sosfilt(
            signal.butter(2, [600.0 / (0.5 * SR), 3400.0 / (0.5 * SR)], btype="bandpass", output="sos"),
            rng.standard_normal(n),
        ) * np.exp(-t / 0.006) * 0.45
        return (body * env + click) * vel * 0.26

    # Deep clay vessel pitch drop on strike
    f_inst = freq * (1.0 + 0.48 * np.exp(-t / 0.026))
    phase = 2.0 * math.pi * np.cumsum(f_inst) / SR
    sub = np.sin(phase) * np.exp(-t / 0.21)
    mode2 = 0.36 * np.sin(1.58 * phase + 0.4) * np.exp(-t / 0.11)
    thump = signal.sosfilt(
        signal.butter(2, [90.0 / (0.5 * SR), 650.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.014) * 0.32
    return (sub + mode2 + thump) * vel * 0.38


def synth_bamboo_clapper(vel: float = 0.65, seed: int = 17) -> np.ndarray:
    """Bamboo Pestle & Clapper (春杵/竹梆): hollow bamboo tube percussion."""
    rng = np.random.default_rng(seed)
    n = int(round(0.14 * SR))
    t = np.arange(n, dtype=np.float64) / SR
    tone = (
        np.sin(2.0 * math.pi * 690.0 * t) * np.exp(-t / 0.022)
        + 0.55 * np.sin(2.0 * math.pi * 1180.0 * t) * np.exp(-t / 0.014)
    )
    click = signal.sosfilt(
        signal.butter(2, [1100.0 / (0.5 * SR), 4600.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.005) * 0.4
    return (tone * 0.7 + click) * vel * 0.20


def synth_grain_shaker(dur: float = 0.22, vel: float = 0.55, seed: int = 18) -> np.ndarray:
    """Millet / Rice Grain Shaker (谷物沙锤): soft organic grain swish."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    env = np.sin(math.pi * np.clip(t / dur, 0.0, 1.0)) ** 1.7 * np.exp(-t / (dur * 0.65))
    noise = signal.sosfilt(
        signal.butter(2, [2200.0 / (0.5 * SR), 7500.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    )
    return noise * env * vel * 0.16


def synth_harvest_choir(freq: float, dur: float, vel: float = 0.76, seed: int = 19) -> np.ndarray:
    """Agrarian Harvest Choir (丰收社祭人声合唱): warm sunlit 'Ah/Oh' vocal formants + octave ensemble."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.45) * SR))
    t = np.arange(n, dtype=np.float64) / SR

    att_n = max(1, int(round(0.32 * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.6
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.28 * SR))

    # Ensemble of 4 detuned voices (tenor/alto/soprano blend)
    glottal = np.zeros(n, dtype=np.float64)
    voice_ratios = [1.0, 1.003, 1.997, 2.004]
    voice_weights = [0.65, 0.55, 0.45, 0.40]
    for vr, vw in zip(voice_ratios, voice_weights):
        vib = 0.0045 * np.sin(2.0 * math.pi * rng.uniform(4.6, 5.4) * t + rng.uniform(0, 6.28))
        p = 2.0 * math.pi * np.cumsum(freq * vr * (1.0 + vib)) / SR
        for k in range(1, 12):
            if freq * vr * k < SR * 0.44:
                glottal += (vw / (k ** 1.15)) * np.sin(k * p + rng.uniform(0, 6.28))

    # Warm pastoral 'Ah' -> 'Oh' formant filter bank (F1 ~ 680 Hz, F2 ~ 1180 Hz, F3 ~ 2650 Hz)
    out = np.zeros(n, dtype=np.float64)
    for f_form, q_val, g_val in [(680.0, 4.5, 1.0), (1180.0, 5.5, 0.65), (2650.0, 6.5, 0.28)]:
        b, a = signal.iirpeak(f_form / (0.5 * SR), Q=q_val)
        out += g_val * signal.lfilter(b, a, glottal)

    return out * env * vel * 0.14


# ==============================================================================
# Zoom-In (微观水田农庄) & Zoom-Out (宏观九州沃野) Soundscape Generators
# ==============================================================================

def render_zoom_close_stem(ir: np.ndarray) -> np.ndarray:
    """Track 4 Zoom_Close: Babbling Irrigation Canal, Millstone/Threshing Craft, Meadow Songbirds & Hand Percussion."""
    buf = np.zeros((N_EXT, 2), dtype=np.float64)
    rng = np.random.default_rng(404)

    # 1. Continuous babbling irrigation canal water (水渠潺潺流水 + 水滴气泡共鸣)
    n_tot = N_EXT
    t_full = np.arange(n_tot, dtype=np.float64) / SR
    stream_l = signal.sosfilt(
        signal.butter(2, [280.0 / (0.5 * SR), 1900.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n_tot),
    ) * (0.018 + 0.007 * np.sin(2.0 * math.pi * 0.32 * t_full))
    stream_r = signal.sosfilt(
        signal.butter(2, [310.0 / (0.5 * SR), 2050.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n_tot),
    ) * (0.018 + 0.007 * np.cos(2.0 * math.pi * 0.29 * t_full + 0.8))
    buf[:, 0] += stream_l
    buf[:, 1] += stream_r

    # Water droplet / paddy bubble chimes (upward-chirping sinusoid droplets)
    t_cursor = 0.18
    while t_cursor < TOTAL_DUR + 1.2:
        f_drop = rng.uniform(520.0, 1680.0)
        dur_d = rng.uniform(0.035, 0.075)
        nd = int(round(dur_d * SR))
        td = np.arange(nd, dtype=np.float64) / SR
        # Characteristic upward pitch chirp of a water bubble
        f_chirp = f_drop * (1.0 + 0.28 * (td / dur_d) ** 1.5)
        drop_mono = np.sin(2.0 * math.pi * np.cumsum(f_chirp) / SR) * np.sin(math.pi * td / dur_d) * np.exp(-td / 0.028) * 0.045
        add_clip(buf, t_cursor, pan_stereo(drop_mono, pan=rng.uniform(-0.65, 0.65)), 1.0)
        t_cursor += rng.uniform(0.09, 0.26)

    # 2. Rhythmic Millstone Grinding & Wooden Flail Threshing (石磨碾谷与连枷脱粒) + Close Finger-Pot Tap
    for bar_idx in range(TOTAL_BARS + 1):
        bar_t0 = bar_idx * BAR
        # Soft stone millstone swish on beats 1 and 3
        for beat_off in [0.0, 2.0]:
            t0 = bar_t0 + beat_off * BEAT
            nm = int(round(0.55 * SR))
            tm = np.arange(nm, dtype=np.float64) / SR
            env_m = np.sin(math.pi * tm / 0.55) ** 1.4
            mill = signal.sosfilt(
                signal.butter(2, [220.0 / (0.5 * SR), 1100.0 / (0.5 * SR)], btype="bandpass", output="sos"),
                rng.standard_normal(nm),
            ) * env_m * 0.055
            add_clip(buf, t0, pan_stereo(mill, pan=-0.32), 1.0)

        # Close-mic earthen pot & bamboo tap on beats 1.5, 2.5, 3.5
        for sub_idx, beat_off in enumerate([0.5, 1.5, 2.5, 3.5]):
            t0 = bar_t0 + beat_off * BEAT
            if sub_idx % 2 == 0:
                tap = synth_harvest_clay_drum(freq=96.0, dur=0.25, vel=0.46, rim=True, seed=bar_idx * 31 + sub_idx)
                add_clip(buf, t0, pan_stereo(tap, pan=0.28), 0.72)
            else:
                shk = synth_grain_shaker(dur=0.18, vel=0.45, seed=bar_idx * 41 + sub_idx)
                add_clip(buf, t0, pan_stereo(shk, pan=-0.24), 0.70)

        # 3. Pastoral Meadow Songbird twitters (every 2 bars)
        if bar_idx % 2 == 1:
            bird_t0 = bar_t0 + 1.25 * BEAT
            for note_i, (bf0, bf1, bdur) in enumerate([
                (2450.0, 3150.0, 0.085),
                (3100.0, 2680.0, 0.095),
                (2850.0, 3420.0, 0.120),
            ]):
                nb = int(round(bdur * SR))
                tb = np.arange(nb, dtype=np.float64) / SR
                f_b = bf0 + (bf1 - bf0) * (tb / bdur) + 85.0 * np.sin(2.0 * math.pi * 28.0 * tb)
                env_b = np.sin(math.pi * tb / bdur) ** 1.6
                bird_mono = np.sin(2.0 * math.pi * np.cumsum(f_b) / SR) * env_b * 0.042
                add_clip(buf, bird_t0 + note_i * 0.11, pan_stereo(bird_mono, pan=0.45 if bar_idx % 4 == 1 else -0.45), 1.0)

    return apply_reverb(buf, ir, wet=0.16)


def render_zoom_far_stem(ir: np.ndarray) -> np.ndarray:
    """Track 5 Zoom_Far: Golden-Plain Monsoon Breeze, Celestial Calendar Harmonics & Deep Loess Earth Drone."""
    buf = np.zeros((N_EXT, 2), dtype=np.float64)
    rng = np.random.default_rng(505)

    n_tot = N_EXT
    t = np.arange(n_tot, dtype=np.float64) / SR

    # 1. Deep Loess Earth Drone (G1 = 49.0 Hz + D2 = 73.42 Hz + G2 = 98.0 Hz)
    g1 = n2f("G1")
    d2 = n2f("D2")
    g2 = n2f("G2")
    slow_mod = 0.85 + 0.15 * np.sin(2.0 * math.pi * (1.0 / 15.0) * t)
    drone_l = (
        0.52 * np.sin(2.0 * math.pi * g1 * t)
        + 0.34 * np.sin(2.0 * math.pi * d2 * t + 0.5)
        + 0.22 * np.sin(2.0 * math.pi * g2 * t + 1.1)
    ) * slow_mod * 0.14
    drone_r = (
        0.52 * np.sin(2.0 * math.pi * g1 * t + 0.2)
        + 0.34 * np.sin(2.0 * math.pi * d2 * t + 1.9)
        + 0.22 * np.sin(2.0 * math.pi * g2 * t + 0.3)
    ) * slow_mod * 0.14
    buf[:, 0] += drone_l
    buf[:, 1] += drone_r

    # 2. Warm Golden-Plain Monsoon Breeze (sweeping resonant bandpass noise)
    raw_l = rng.standard_normal(n_tot)
    raw_r = rng.standard_normal(n_tot)
    breeze_l = signal.sosfilt(
        signal.butter(2, [160.0 / (0.5 * SR), 920.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        raw_l,
    ) * (0.045 + 0.025 * np.sin(2.0 * math.pi * (1.0 / 10.0) * t))
    breeze_r = signal.sosfilt(
        signal.butter(2, [180.0 / (0.5 * SR), 980.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        raw_r,
    ) * (0.045 + 0.025 * np.cos(2.0 * math.pi * (1.0 / 10.0) * t + 0.7))
    buf[:, 0] += breeze_l
    buf[:, 1] += breeze_r

    # 3. Celestial Calendar Shimmer Pad (Astronomical observation & solar terms: G4 - B4 - D5 - E5 - A5)
    shimmer_chords = [
        (0.0, 12.0, ["G4", "D5", "A5"]),
        (12.0, 27.0, ["G4", "B4", "D5", "E5"]),
        (27.0, 42.0, ["E4", "A4", "B4", "D5"]),
        (42.0, 57.0, ["D4", "G4", "A4", "D5"]),
    ]
    for idx, (t0, t1, notes) in enumerate(shimmer_chords):
        dur = (t1 - t0) + 1.8
        ns = int(round(dur * SR))
        ts = np.arange(ns, dtype=np.float64) / SR
        env_s = np.sin(math.pi * np.clip(ts / dur, 0.0, 1.0)) ** 1.5
        pad_l = np.zeros(ns, dtype=np.float64)
        pad_r = np.zeros(ns, dtype=np.float64)
        for ni, nn in enumerate(notes):
            fn = n2f(nn)
            shimmer_mod = 0.75 + 0.25 * np.sin(2.0 * math.pi * (0.22 + 0.07 * ni) * ts + ni)
            sig_n = (np.sin(2.0 * math.pi * fn * ts) + 0.35 * np.sin(2.0 * math.pi * fn * 2.0 * ts + 0.8)) * shimmer_mod * env_s * 0.048
            pan_p = -0.55 + 1.1 * (ni / max(1, len(notes) - 1))
            st = pan_stereo(sig_n, pan=pan_p, haas_ms=6.0)
            pad_l += st[:, 0]
            pad_r += st[:, 1]
        add_clip(buf, t0, np.stack([pad_l, pad_r], axis=1), 1.0)

    return apply_reverb(buf, ir, wet=0.42)


# ==============================================================================
# Musical Composition: Base Core, Population Tier 1 Rhythm, Population Tier 2 Chorus
# ==============================================================================

def render_base_core_stem(ir: np.ndarray) -> np.ndarray:
    """Track 1 Base_Core: Intro + 3 Pastoral Loop Sections (A: 阡陌晨耕, B: 水渠稻香, C: 观星授时)."""
    buf = np.zeros((N_EXT, 2), dtype=np.float64)

    # --------------------------------------------------------------------------
    # 1. INTRO [0.0s .. 12.0s] (4 bars): 《晨曦开犁 · 岁首迎春》
    #    Cast Bronze Ling Bell awakening + Panpipe dawn chords + Silk Zither cascade + Dizi call
    # --------------------------------------------------------------------------
    intro_bells = [
        (0.05, "G4", 3.6, 0.85, -0.25),
        (1.50, "D5", 3.2, 0.78, 0.30),
        (3.00, "E5", 2.8, 0.72, -0.15),
        (4.50, "D5", 3.0, 0.74, 0.25),
        (6.00, "B4", 3.4, 0.80, -0.20),
        (9.00, "G4", 3.6, 0.82, 0.00),
    ]
    for t0, note, dur, vel, pan in intro_bells:
        bell = synth_bronze_bell(n2f(note), dur=dur, vel=vel, seed=int(t0 * 100) + 1)
        add_clip(buf, t0, pan_stereo(bell, pan=pan, haas_ms=4.0), 0.90)

    # Warm Panpipe & Sheng sunrise swells in Intro
    intro_pads = [
        (0.4, "G3", 5.2, 0.72, -0.30),
        (3.2, "A3", 4.8, 0.68, 0.30),
        (6.0, "G3", 5.5, 0.76, -0.20),
    ]
    for t0, note, dur, vel, pan in intro_pads:
        pp = synth_panpipes_sheng(n2f(note), dur=dur, vel=vel, fifth_harmony=True, seed=int(t0 * 50) + 7)
        add_clip(buf, t0, pan_stereo(pp, pan=pan, haas_ms=5.0), 0.85)

    # Silk Zither morning cascade in Intro (bars 2..4)
    intro_zither = [
        (3.00, "G3", 2.4, 0.75), (3.375, "D4", 2.2, 0.72), (3.75, "G4", 2.2, 0.76), (4.125, "A4", 2.2, 0.74),
        (4.50, "B4", 2.6, 0.80), (5.25, "A4", 2.2, 0.72),
        (6.00, "E3", 2.5, 0.76), (6.375, "B3", 2.2, 0.72), (6.75, "E4", 2.2, 0.74), (7.125, "G4", 2.2, 0.76),
        (7.50, "A4", 2.5, 0.78), (8.25, "G4", 2.4, 0.74),
        (9.00, "D3", 2.8, 0.78), (9.375, "A3", 2.5, 0.74), (9.75, "D4", 2.5, 0.76), (10.50, "A4", 2.4, 0.80),
    ]
    for idx, (t0, note, dur, vel) in enumerate(intro_zither):
        z = synth_silk_zither(n2f(note), dur=dur, vel=vel, seed=200 + idx)
        add_clip(buf, t0, pan_stereo(z, pan=0.22 if idx % 2 == 0 else -0.22, haas_ms=3.0), 0.88)

    # Intro Bamboo Dizi herald phrase (6.0s .. 11.8s) leading into Loop A at 12.0s
    intro_dizi = [
        (6.00, "D4", 1.35, 0.78, "B3"),
        (7.50, "G4", 1.35, 0.84, "E4"),
        (9.00, "A4", 1.05, 0.86, "G4"),
        (10.125, "B4", 0.70, 0.82, None),
        (10.875, "A4", 1.00, 0.80, "B4"),
    ]
    for idx, (t0, note, dur, vel, gr) in enumerate(intro_dizi):
        fl = synth_bamboo_dizi(n2f(note), dur=dur, vel=vel, grace_from=n2f(gr) if gr else None, seed=300 + idx)
        add_clip(buf, t0, pan_stereo(fl, pan=-0.08, haas_ms=2.5), 0.92)

    # --------------------------------------------------------------------------
    # 2A. LOOP A [12.0s .. 27.0s] (5 bars): 《阡陌晨耕》(Morning Ploughing)
    #     Lead: Bamboo Dizi lyrical G-pentatonic melody + 5-String Silk Zither rolling arpeggios
    # --------------------------------------------------------------------------
    loop_a_t0 = 12.0
    # 5-bar chord progression in G Pastoral: Bar 0: G, Bar 1: Em7, Bar 2: Cmaj9/G, Bar 3: D6, Bar 4: G -> D7sus4
    a_chords = [
        ["G2", "D3", "G3", "B3", "D4", "G4", "A4", "D4"],
        ["E2", "B2", "E3", "G3", "B3", "E4", "G4", "B3"],
        ["C3", "G3", "C4", "E4", "G4", "A4", "G4", "E4"],
        ["D3", "A3", "D4", "F#4", "A4", "B4", "A4", "F#4"],
        ["G2", "D3", "G3", "A3", "B3", "D4", "A3", "D3"],
    ]
    for b_i, notes in enumerate(a_chords):
        bt = loop_a_t0 + b_i * BAR
        for step_i, nn in enumerate(notes):
            nt = bt + step_i * (BEAT * 0.5)
            vel = 0.78 if step_i in (0, 4) else 0.62
            z = synth_silk_zither(n2f(nn), dur=2.1, vel=vel, seed=400 + b_i * 10 + step_i)
            add_clip(buf, nt, pan_stereo(z, pan=0.28 if step_i % 2 == 0 else -0.25, haas_ms=3.5), 0.86)

    # Lyrical Bamboo Dizi melody in Loop A
    loop_a_melody = [
        # Bar 0 (G)
        (12.00, "G4", 1.05, 0.85, "E4"),
        (13.125, "A4", 0.35, 0.78, None),
        (13.50, "B4", 1.05, 0.88, "A4"),
        (14.625, "D5", 0.35, 0.82, None),
        # Bar 1 (Em)
        (15.00, "E5", 1.40, 0.90, "D5"),
        (16.50, "D5", 0.70, 0.82, None),
        (17.25, "B4", 0.70, 0.78, "D5"),
        # Bar 2 (C/G)
        (18.00, "A4", 1.05, 0.84, "G4"),
        (19.125, "B4", 0.35, 0.78, None),
        (19.50, "G4", 1.05, 0.82, "A4"),
        (20.625, "E4", 0.35, 0.75, None),
        # Bar 3 (D)
        (21.00, "D4", 0.70, 0.80, "E4"),
        (21.75, "E4", 0.70, 0.82, None),
        (22.50, "G4", 0.70, 0.85, "E4"),
        (23.25, "A4", 0.70, 0.88, "G4"),
        # Bar 4 (G turnaround)
        (24.00, "G4", 1.80, 0.86, "A4"),
        (25.875, "E4", 0.50, 0.76, None),
        (26.40, "D4", 0.55, 0.74, None),
    ]
    for idx, (t0, note, dur, vel, gr) in enumerate(loop_a_melody):
        fl = synth_bamboo_dizi(n2f(note), dur=dur, vel=vel, grace_from=n2f(gr) if gr else None, seed=500 + idx)
        add_clip(buf, t0, pan_stereo(fl, pan=-0.12, haas_ms=2.5), 0.92)

    # Warm Clay Xun bass anchors in Loop A
    for b_i, root_n in enumerate(["G2", "E2", "C3", "D3", "G2"]):
        xun = synth_clay_xun_warm(n2f(root_n), dur=2.6, vel=0.66, seed=580 + b_i)
        add_clip(buf, loop_a_t0 + b_i * BAR, pan_stereo(xun, pan=-0.20), 0.78)

    # --------------------------------------------------------------------------
    # 2B. LOOP B [27.0s .. 42.0s] (5 bars): 《水渠稻香》(Irrigation & Terraced Paddies)
    #     Lead: Bamboo Panpipes & Reed Sheng dialogue + Silk Zither harmonic bells + Bronze Ling
    # --------------------------------------------------------------------------
    loop_b_t0 = 27.0
    b_panpipe_melody = [
        # Bar 0 (Em -> G)
        (27.00, "B3", 1.40, 0.82, True),
        (28.50, "D4", 1.40, 0.84, True),
        # Bar 1 (A7sus -> C)
        (30.00, "E4", 1.05, 0.86, True),
        (31.125, "D4", 0.35, 0.78, False),
        (31.50, "B3", 1.40, 0.80, True),
        # Bar 2 (G -> Em)
        (33.00, "G3", 1.40, 0.82, True),
        (34.50, "A3", 0.70, 0.80, False),
        (35.25, "B3", 0.70, 0.84, True),
        # Bar 3 (C -> D)
        (36.00, "C4", 1.40, 0.85, True),
        (37.50, "D4", 1.40, 0.88, True),
        # Bar 4 (G resolution)
        (39.00, "B3", 1.80, 0.84, True),
        (40.875, "A3", 1.00, 0.78, True),
    ]
    for idx, (t0, note, dur, vel, fifth) in enumerate(b_panpipe_melody):
        pp = synth_panpipes_sheng(n2f(note), dur=dur, vel=vel, fifth_harmony=fifth, seed=600 + idx)
        add_clip(buf, t0, pan_stereo(pp, pan=-0.22 if idx % 2 == 0 else 0.22, haas_ms=4.5), 0.92)

    # Crystalline Silk Zither harmonics (泛音) & expressive bends in Loop B (like sunlight on paddy water)
    b_zither_notes = [
        (27.00, "E3", False, 0.0), (27.75, "B3", True, 0.0), (28.50, "E4", True, 0.0), (29.25, "G4", False, 35.0),
        (30.00, "A2", False, 0.0), (30.75, "E4", True, 0.0), (31.50, "A4", True, 0.0), (32.25, "G4", False, -30.0),
        (33.00, "G2", False, 0.0), (33.75, "D4", True, 0.0), (34.50, "G4", True, 0.0), (35.25, "B4", True, 0.0),
        (36.00, "C3", False, 0.0), (36.75, "G4", True, 0.0), (37.50, "D3", False, 0.0), (38.25, "A4", True, 0.0),
        (39.00, "G2", False, 0.0), (39.75, "D4", True, 0.0), (40.50, "G4", True, 0.0), (41.25, "D4", False, 25.0),
    ]
    for idx, (t0, note, is_harm, bend) in enumerate(b_zither_notes):
        z = synth_silk_zither(n2f(note), dur=2.3, vel=0.76, harmonic_bell=is_harm, bend_cents=bend, seed=700 + idx)
        add_clip(buf, t0, pan_stereo(z, pan=0.30 if is_harm else -0.18, haas_ms=3.0), 0.88)

    # Gentle Bronze Ling bell accents on Loop B bar downbeats
    for b_i, bell_n in enumerate(["E5", "A4", "D5", "G5", "D5"]):
        bell = synth_bronze_bell(n2f(bell_n), dur=2.4, vel=0.64, seed=760 + b_i)
        add_clip(buf, loop_b_t0 + b_i * BAR, pan_stereo(bell, pan=0.35 if b_i % 2 == 0 else -0.35), 0.72)

    # --------------------------------------------------------------------------
    # 2C. LOOP C [42.0s .. 57.0s] (5 bars): 《观星授时》(Celestial Calendar & Harvest Dusk)
    #     Lead: Earthen Xun + High Bamboo Dizi contrapuntal duet + rolling Silk Zither + Bronze Bells
    # --------------------------------------------------------------------------
    loop_c_t0 = 42.0
    # Warm Clay Xun low-mid counter-melody (connecting back to Stone Age ancestry)
    c_xun_melody = [
        (42.00, "G3", 1.40, 0.80, "E3"),
        (43.50, "A3", 1.40, 0.78, "G3"),
        (45.00, "B3", 1.40, 0.82, "A3"),
        (46.50, "G3", 1.40, 0.76, None),
        (48.00, "E3", 1.40, 0.80, "G3"),
        (49.50, "D3", 1.40, 0.78, None),
        (51.00, "G3", 1.40, 0.82, "D3"),
        (52.50, "A3", 1.40, 0.84, "G3"),
        (54.00, "G3", 1.80, 0.82, "A3"),
        (55.875, "D3", 1.05, 0.76, None),
    ]
    for idx, (t0, note, dur, vel, gl) in enumerate(c_xun_melody):
        xun = synth_clay_xun_warm(n2f(note), dur=dur, vel=vel, glide_from=n2f(gl) if gl else None, seed=800 + idx)
        add_clip(buf, t0, pan_stereo(xun, pan=-0.28, haas_ms=4.0), 0.90)

    # High Bamboo Dizi soaring evening descant in Loop C
    c_dizi_descant = [
        (42.75, "D5", 1.40, 0.80, "B4"),
        (44.25, "E5", 0.70, 0.78, None),
        (45.00, "G5", 1.40, 0.85, "E5"),
        (46.50, "E5", 0.70, 0.78, None),
        (47.25, "D5", 0.70, 0.76, None),
        (48.00, "B4", 1.40, 0.82, "D5"),
        (49.50, "A4", 1.40, 0.80, "B4"),
        (51.00, "B4", 1.05, 0.82, "A4"),
        (52.125, "D5", 0.75, 0.84, None),
        (53.00, "E5", 0.95, 0.85, "D5"),
        (54.00, "D5", 1.40, 0.84, "E5"),
        (55.50, "B4", 0.70, 0.78, None),
        (56.25, "A4", 0.70, 0.76, "B4"),
    ]
    for idx, (t0, note, dur, vel, gr) in enumerate(c_dizi_descant):
        fl = synth_bamboo_dizi(n2f(note), dur=dur, vel=vel, grace_from=n2f(gr) if gr else None, seed=850 + idx)
        add_clip(buf, t0, pan_stereo(fl, pan=0.24, haas_ms=3.0), 0.88)

    # Flowing 8th-note Silk Zither accompaniment in Loop C
    c_chords = [
        ["G2", "D3", "G3", "B3", "D4", "G4", "B3", "G3"],
        ["E2", "B2", "E3", "G3", "B3", "E4", "B3", "G3"],
        ["C3", "G3", "C4", "E4", "G4", "E4", "C4", "G3"],
        ["D3", "A3", "D4", "G4", "F#4", "D4", "A3", "D3"],
        ["G2", "D3", "G3", "B3", "D4", "G4", "D4", "A3"],
    ]
    for b_i, notes in enumerate(c_chords):
        bt = loop_c_t0 + b_i * BAR
        for step_i, nn in enumerate(notes):
            nt = bt + step_i * (BEAT * 0.5)
            z = synth_silk_zither(n2f(nn), dur=1.9, vel=0.70, harmonic_bell=(step_i in (4, 5)), seed=900 + b_i * 10 + step_i)
            add_clip(buf, nt, pan_stereo(z, pan=0.18 if step_i % 2 == 0 else -0.18), 0.82)

    # Celestial Calendar Bronze Bell chimes in Loop C
    for b_i, (off_b, bell_n) in enumerate([(0.0, "G4"), (6.0, "E5"), (9.0, "D5"), (12.0, "G5")]):
        bell = synth_bronze_bell(n2f(bell_n), dur=3.0, vel=0.72, seed=960 + b_i)
        add_clip(buf, loop_c_t0 + off_b, pan_stereo(bell, pan=0.0), 0.80)

    return apply_reverb(buf, ir, wet=0.26)


def render_pop_rhythm_stem(ir: np.ndarray) -> np.ndarray:
    """Track 2 Pop_Rhythm (Tier 1 >=600 pop): Earthenware Harvest Drum, Bamboo Pestle, Grain Shaker & Bass Lute."""
    buf = np.zeros((N_EXT, 2), dtype=np.float64)

    for bar_idx in range(TOTAL_BARS + 1):
        bt = bar_idx * BAR
        in_intro = bar_idx < INTRO_BARS
        bar_gain = 0.45 if in_intro else 0.95
        if in_intro and bar_idx < 2:
            continue  # Let first 2 bars of Intro breathe before soft pulse enters

        # 1. Earthenware Harvest Drum (土鼓) pattern: warm heartbeat of ploughing & irrigation labor
        # Beat 0.0 (deep bass), Beat 1.5 (rim), Beat 2.0 (bass), Beat 3.0 (rim), Beat 3.5 (soft bass pickup)
        drum_hits = [
            (0.0, 65.0, 0.88, False, -0.08),
            (1.5, 92.0, 0.58, True, 0.18),
            (2.0, 68.0, 0.78, False, -0.05),
            (3.0, 95.0, 0.62, True, -0.18),
            (3.5, 72.0, 0.55, False, 0.10),
        ]
        for h_i, (b_off, dfreq, dvel, is_rim, dpan) in enumerate(drum_hits):
            d = synth_harvest_clay_drum(freq=dfreq, dur=0.45, vel=dvel * bar_gain, rim=is_rim, seed=1100 + bar_idx * 10 + h_i)
            add_clip(buf, bt + b_off * BEAT, pan_stereo(d, pan=dpan), 0.90)

        # 2. Bamboo Pestle & Clapper (春杵/竹梆) on Beat 1.0 and Beat 2.75
        for c_i, b_off in enumerate([1.0, 2.75]):
            clap = synth_bamboo_clapper(vel=0.62 * bar_gain, seed=1300 + bar_idx * 10 + c_i)
            add_clip(buf, bt + b_off * BEAT, pan_stereo(clap, pan=0.32 if c_i == 0 else -0.32, haas_ms=3.0), 0.82)

        # 3. Grain Shaker (谷物沙锤) 8th-note groove
        for s_i in range(8):
            s_vel = (0.62 if s_i % 2 == 1 else 0.38) * bar_gain
            shk = synth_grain_shaker(dur=0.20, vel=s_vel, seed=1500 + bar_idx * 10 + s_i)
            add_clip(buf, bt + s_i * 0.5 * BEAT, pan_stereo(shk, pan=-0.35 if s_i % 2 == 0 else 0.35), 0.80)

        # 4. Warm Plucked Bass Lute / Low Silk Zither ostinato (locking percussion to harmony)
        if not in_intro:
            sec_bar = (bar_idx - INTRO_BARS) % 5
            bass_roots = ["G2", "E2", "C3", "D3", "G2"]
            bass_fifths = ["D3", "B2", "G3", "A3", "D3"]
            r_note = bass_roots[sec_bar]
            f_note = bass_fifths[sec_bar]
            for p_i, (b_off, nn, pvel) in enumerate([
                (0.0, r_note, 0.78),
                (1.0, f_note, 0.64),
                (1.5, r_note, 0.68),
                (2.5, f_note, 0.66),
                (3.0, r_note, 0.72),
            ]):
                plk = synth_silk_zither(n2f(nn), dur=1.1, vel=pvel, seed=1800 + bar_idx * 10 + p_i)
                add_clip(buf, bt + b_off * BEAT, pan_stereo(plk, pan=0.12), 0.82)

    return apply_reverb(buf, ir, wet=0.20)


def render_pop_chorus_stem(ir: np.ndarray) -> np.ndarray:
    """Track 3 Pop_Chorus (Tier 2 >=1600 pop): Sunlit Harvest Choir, Ceremonial Bronze Chimes & High Dizi Harmony."""
    buf = np.zeros((N_EXT, 2), dtype=np.float64)

    # Intro grand ceremonial entry (bars 2..4)
    for t0, nn, dur, pan in [(6.0, "G3", 5.5, -0.35), (6.0, "D4", 5.5, 0.35)]:
        ch = synth_harvest_choir(n2f(nn), dur=dur, vel=0.72, seed=2100 + int(t0 * 10))
        add_clip(buf, t0, pan_stereo(ch, pan=pan, haas_ms=6.0), 0.88)

    # Loop A, B, C Harvest Choir harmonic pads + Ceremonial Bronze Chime Bells + High Dizi descant
    for sec_idx in range(3):
        sec_t0 = 12.0 + sec_idx * 15.0
        choir_prog = [
            ("G3", "D4", "B4"),
            ("E3", "B3", "G4"),
            ("C3", "G3", "E4"),
            ("D3", "A3", "F#4"),
            ("G3", "D4", "A4"),
        ]
        for b_i, (n_low, n_mid, n_hi) in enumerate(choir_prog):
            bt = sec_t0 + b_i * BAR
            ch_l = synth_harvest_choir(n2f(n_low), dur=2.85, vel=0.76, seed=2200 + sec_idx * 50 + b_i * 3)
            ch_m = synth_harvest_choir(n2f(n_mid), dur=2.85, vel=0.72, seed=2201 + sec_idx * 50 + b_i * 3)
            add_clip(buf, bt, pan_stereo(ch_l, pan=-0.40, haas_ms=6.0), 0.86)
            add_clip(buf, bt, pan_stereo(ch_m, pan=0.40, haas_ms=6.0), 0.84)

            # High soaring bamboo dizi + reed sheng harmony on the upper triad note
            pp_hi = synth_panpipes_sheng(n2f(n_hi), dur=2.6, vel=0.68, fifth_harmony=False, seed=2400 + sec_idx * 50 + b_i)
            add_clip(buf, bt + 0.375, pan_stereo(pp_hi, pan=0.25 if b_i % 2 == 0 else -0.25, haas_ms=4.5), 0.78)

            # Ceremonial Bronze Bell Chimes on bars 0, 2, 4
            if b_i in (0, 2, 4):
                bell1 = synth_bronze_bell(n2f(n_hi), dur=2.8, vel=0.72, seed=2600 + sec_idx * 50 + b_i)
                add_clip(buf, bt, pan_stereo(bell1, pan=-0.30 if b_i == 2 else 0.30, haas_ms=4.0), 0.82)
                bell2 = synth_bronze_bell(n2f("D5" if b_i != 3 else "A5"), dur=2.4, vel=0.64, seed=2700 + sec_idx * 50 + b_i)
                add_clip(buf, bt + 2.0 * BEAT, pan_stereo(bell2, pan=0.18), 0.75)

    return apply_reverb(buf, ir, wet=0.35)


# ==============================================================================
# Era Advancement Transition: Stone Age (D Dorian) ──► Agrarian Age (G Pastoral)
# ==============================================================================

def synth_prehistoric_bone_horn(freq: float, dur: float, vel: float = 0.85, seed: int = 91) -> np.ndarray:
    """Prehistoric Bone Horn (远古骨角号) for Phase I of the Stone -> Agrarian Era Transition."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.5) * SR))
    t = np.arange(n, dtype=np.float64) / SR
    env = np.zeros(n, dtype=np.float64)
    peak_t = dur * 0.48
    for i in range(n):
        ti = t[i]
        if ti < peak_t:
            env[i] = math.sin(0.5 * math.pi * (ti / peak_t)) ** 1.7
        elif ti < dur:
            env[i] = 1.0 - 0.15 * ((ti - peak_t) / max(dur - peak_t, 0.01))
        else:
            env[i] = 0.85 * math.exp(-(ti - dur) / 0.24)
    f_inst = freq * (1.0 - 0.022 * np.exp(-t / 0.16) + 0.004 * np.sin(2.0 * math.pi * 3.9 * t))
    phase = 2.0 * math.pi * np.cumsum(f_inst) / SR
    sig = np.zeros(n, dtype=np.float64)
    for k, w in enumerate([1.0, 0.82, 0.60, 0.38, 0.22, 0.12], start=1):
        sig += w * (env ** (1.0 + 0.30 * (k - 1))) * np.sin(k * phase + 0.2 * k)
    sig = signal.sosfilt(signal.butter(2, 2200.0 / (0.5 * SR), btype="lowpass", output="sos"), sig)
    return sig * env * vel * 0.32


def synth_stone_lithophone(freq: float, dur: float = 1.4, vel: float = 0.72, seed: int = 92) -> np.ndarray:
    """River-Stone Lithophone (石磬) for Phase I of the Era Transition."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    sig = np.zeros(n, dtype=np.float64)
    for ratio, amp, tau in zip([1.0, 2.318, 3.864, 5.412], [1.0, 0.42, 0.20, 0.09], [0.65, 0.32, 0.18, 0.09]):
        if freq * ratio < SR * 0.45:
            sig += amp * np.exp(-t / tau) * np.sin(2.0 * math.pi * freq * ratio * t + rng.uniform(0, 0.4))
    click = signal.sosfilt(
        signal.butter(2, [900.0 / (0.5 * SR), 5200.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.0025) * 0.30
    return (sig * (1.0 - np.exp(-t / 0.0018)) + click) * vel * 0.22


def render_era_transition_stone_to_agrarian(ir: np.ndarray) -> np.ndarray:
    """《破晓定居 · 迈入农耕》(9.60s): Ceremonial transition from Stone Age (D Dorian) to Agrarian Age (G Pastoral).

    - Phase I   [0.0s .. 2.4s] 告别荒原 (Farewell to Stone Age): Bone Horn on D2/A2 + Stone Lithophone cascade + Clay Xun
    - Phase II  [2.4s .. 4.5s] 破晓铸铜 (The Bronze & Silk Pivot): D Dorian -> D Major dominant herald (F4 -> F#4),
                               sweeping 5-String Silk Zither glissando + first Cast Bronze Bell strike + Drum crescendo
    - Phase III [4.5s .. 9.6s] 千里春耕 (Triumphant Arrival of Agrarian Age in G): Grand V -> I resolution onto G Pastoral
                               with Bronze Chime Bells, Harvest Choir, Bamboo Dizi & Reed Sheng fanfare, decaying smoothly
    """
    trans_dur = 9.60
    n_trans = int(round(trans_dur * SR))
    buf = np.zeros((n_trans, 2), dtype=np.float64)

    # --- Phase I [0.0s .. 2.4s]: Stone Age Echo in D ---
    horn_d2 = synth_prehistoric_bone_horn(n2f("D2"), dur=2.3, vel=0.88, seed=3001)
    horn_a2 = synth_prehistoric_bone_horn(n2f("A2"), dur=2.2, vel=0.76, seed=3002)
    add_clip(buf, 0.02, pan_stereo(horn_d2, pan=-0.20, haas_ms=4.0), 0.92)
    add_clip(buf, 0.15, pan_stereo(horn_a2, pan=0.22, haas_ms=4.0), 0.85)

    # Accelerating Stone Lithophone & Clay Xun farewell motif (D4 - F4 - G4 - A4)
    stone_notes = [
        (0.20, "D4", 0.68, -0.35),
        (0.65, "F3", 0.70, 0.30),
        (1.05, "G4", 0.74, -0.25),
        (1.40, "A4", 0.78, 0.25),
        (1.70, "C5", 0.80, -0.20),
        (1.98, "D5", 0.84, 0.18),
    ]
    for idx, (t0, nn, vel, pan) in enumerate(stone_notes):
        lith = synth_stone_lithophone(n2f(nn), dur=1.3, vel=vel, seed=3100 + idx)
        add_clip(buf, t0, pan_stereo(lith, pan=pan), 0.88)

    xun_farewell = synth_clay_xun_warm(n2f("D3"), dur=2.1, vel=0.82, glide_from=n2f("A2"), seed=3150)
    add_clip(buf, 0.10, pan_stereo(xun_farewell, pan=0.0), 0.90)

    # --- Phase II [2.4s .. 4.5s]: The Breakthrough Pivot (D7sus4 -> D Major Dominant Herald + Zither Glissando) ---
    # Sweeping 5-String Silk Zither glissando transforming D minor into radiant D Major / G Pentatonic
    gliss_notes = ["D3", "E3", "F#3", "A3", "B3", "D4", "E4", "F#4", "A4", "B4", "D5", "F#5"]
    for idx, nn in enumerate(gliss_notes):
        t0 = 2.35 + idx * 0.13
        pan = -0.55 + 1.10 * (idx / max(1, len(gliss_notes) - 1))
        z = synth_silk_zither(n2f(nn), dur=2.2, vel=0.74 + 0.015 * idx, harmonic_bell=(idx >= 9), seed=3200 + idx)
        add_clip(buf, t0, pan_stereo(z, pan=pan, haas_ms=3.0), 0.88)

    # First radiant strike of the Cast Bronze Bell on D5 & F#4 (heralding Bronze & Calendar knowledge)
    bell_pivot_1 = synth_bronze_bell(n2f("D5"), dur=3.0, vel=0.88, seed=3301)
    bell_pivot_2 = synth_bronze_bell(n2f("A4"), dur=2.8, vel=0.82, seed=3302)
    add_clip(buf, 2.45, pan_stereo(bell_pivot_1, pan=-0.25, haas_ms=4.0), 0.92)
    add_clip(buf, 3.35, pan_stereo(bell_pivot_2, pan=0.28, haas_ms=4.0), 0.88)

    # Building Earthenware Harvest Drum crescendo roll (2.4s .. 4.4s)
    roll_times = [2.40, 2.75, 3.05, 3.30, 3.52, 3.72, 3.90, 4.06, 4.20, 4.34]
    for r_i, rt in enumerate(roll_times):
        r_vel = 0.42 + 0.055 * r_i
        d = synth_harvest_clay_drum(freq=66.0 + r_i * 1.2, dur=0.42, vel=r_vel, rim=(r_i % 3 == 1), seed=3400 + r_i)
        add_clip(buf, rt, pan_stereo(d, pan=-0.15 if r_i % 2 == 0 else 0.15), 0.92)

    # --- Phase III [4.5s .. 9.6s]: Grand V -> I Resolution onto G Major Pentatonic (千里春耕) ---
    # Glorious full-ensemble downbeat at 4.50s
    for d_t0, d_freq, d_vel in [(4.50, 62.0, 0.98), (5.25, 92.0, 0.68), (6.00, 64.0, 0.92), (6.75, 68.0, 0.84)]:
        d = synth_harvest_clay_drum(freq=d_freq, dur=0.60, vel=d_vel, rim=(d_freq > 80.0), seed=3500 + int(d_t0 * 100))
        add_clip(buf, d_t0, pan_stereo(d, pan=0.0), 0.96)

    # Ceremonial Bronze Bell Chime Chord at 4.50s, 5.25s, 6.00s, 6.75s
    fanfare_bells = [
        (4.50, "G4", 3.8, 0.92, -0.32),
        (4.52, "D5", 3.6, 0.86, 0.32),
        (5.25, "E5", 3.2, 0.80, -0.20),
        (6.00, "G5", 3.8, 0.90, 0.22),
        (6.75, "D5", 3.6, 0.84, 0.00),
    ]
    for idx, (t0, nn, dur, vel, pan) in enumerate(fanfare_bells):
        b = synth_bronze_bell(n2f(nn), dur=dur, vel=vel, seed=3600 + idx)
        add_clip(buf, t0, pan_stereo(b, pan=pan, haas_ms=4.5), 0.92)

    # Sunlit Agrarian Harvest Choir ("Ah/Oh") chord (G2 + D3 + G3 + B3 + D4 + G4)
    choir_voices = [
        ("G2", -0.10, 0.82),
        ("D3", -0.42, 0.84),
        ("G3", 0.42, 0.86),
        ("B3", -0.25, 0.82),
        ("D4", 0.25, 0.84),
    ]
    for idx, (nn, pan, vel) in enumerate(choir_voices):
        ch = synth_harvest_choir(n2f(nn), dur=3.6, vel=vel, seed=3700 + idx)
        add_clip(buf, 4.50, pan_stereo(ch, pan=pan, haas_ms=6.0), 0.92)

    # Bamboo Panpipes & Reed Sheng golden chord swell
    for idx, (nn, pan) in enumerate([("G3", -0.30), ("B3", 0.30), ("D4", 0.0)]):
        pp = synth_panpipes_sheng(n2f(nn), dur=3.5, vel=0.84, fifth_harmony=True, seed=3800 + idx)
        add_clip(buf, 4.50, pan_stereo(pp, pan=pan, haas_ms=5.0), 0.88)

    # Soaring Bamboo Dizi triumphant Agrarian proclamation melody (4.50s .. 8.20s)
    fanfare_dizi = [
        (4.50, "G4", 0.72, 0.90, "D4"),
        (5.25, "A4", 0.35, 0.84, None),
        (5.625, "B4", 0.35, 0.86, None),
        (6.00, "D5", 0.72, 0.94, "B4"),
        (6.75, "E5", 0.50, 0.90, "D5"),
        (7.25, "D5", 1.35, 0.88, "E5"),
    ]
    for idx, (t0, nn, dur, vel, gr) in enumerate(fanfare_dizi):
        fl = synth_bamboo_dizi(n2f(nn), dur=dur, vel=vel, grace_from=n2f(gr) if gr else None, seed=3900 + idx)
        add_clip(buf, t0, pan_stereo(fl, pan=-0.05, haas_ms=2.5), 0.95)

    # Resonant Silk Zither final arpeggiated chord (6.75s .. 9.2s)
    for idx, nn in enumerate(["G2", "D3", "G3", "B3", "D4", "G4", "B4", "D5"]):
        z = synth_silk_zither(n2f(nn), dur=2.6, vel=0.80, harmonic_bell=(idx >= 6), seed=3950 + idx)
        add_clip(buf, 6.75 + idx * 0.07, pan_stereo(z, pan=-0.35 + 0.10 * idx, haas_ms=3.5), 0.86)

    out = apply_reverb(buf, ir, wet=0.34)
    # Smooth fade-in (20ms) and natural fade-out over the last 1.2s
    fi = int(round(0.020 * SR))
    fo = int(round(1.20 * SR))
    out[:fi] *= np.linspace(0.0, 1.0, fi)[:, None]
    out[-fo:] *= (np.linspace(1.0, 0.0, fo) ** 1.5)[:, None]

    rms = math.sqrt(float(np.mean(out ** 2)) + 1e-12)
    target_rms = 10.0 ** (-18.5 / 20.0)
    out *= (target_rms / rms)
    if float(np.max(np.abs(out))) > 0.88:
        out = np.tanh(out * 0.95) * 0.88
    return out



# ==============================================================================
# Seamless Loop Boundary Folding & WAV Export
# ==============================================================================

def finalize_stem_with_loop_wrap(ext_buf: np.ndarray, target_rms_db: float = -20.0) -> np.ndarray:
    """Fold reverb/release tails across the 57.0s -> 12.0s loop boundary so loops are click-free."""
    out = ext_buf[:N_SAMPLES].copy()
    tail = ext_buf[N_SAMPLES:]
    loop_start_idx = int(round(12.0 * SR))
    n_tail = min(len(tail), N_SAMPLES - loop_start_idx)
    if n_tail > 0:
        fade = np.linspace(1.0, 0.0, n_tail)[:, None]
        out[loop_start_idx:loop_start_idx + n_tail] += tail[:n_tail] * fade

    # Gentle 25ms fade-in at 0.0s and micro-smoothing at loop section boundaries (12.0s, 27.0s, 42.0s, 57.0s)
    fi = int(round(0.025 * SR))
    out[:fi] *= np.linspace(0.0, 1.0, fi)[:, None]
    out[-fi:] *= np.linspace(1.0, 0.15, fi)[:, None]

    # Normalize to target RMS with soft ceiling limiter at -1.5 dBFS
    rms = math.sqrt(float(np.mean(out ** 2)) + 1e-12)
    target_rms = 10.0 ** (target_rms_db / 20.0)
    out *= (target_rms / rms)
    peak = float(np.max(np.abs(out)))
    if peak > 0.84:
        out = np.tanh(out * 0.95) * 0.84
    return out


def save_wav(path: Path, stereo: np.ndarray) -> tuple[float, float]:
    path.parent.mkdir(parents=True, exist_ok=True)
    clipped = np.clip(stereo, -0.999, 0.999)
    pcm = (clipped * 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())
    rms_db = 20.0 * math.log10(math.sqrt(float(np.mean(clipped ** 2)) + 1e-12))
    peak_db = 20.0 * math.log10(float(np.max(np.abs(clipped))) + 1e-12)
    return rms_db, peak_db


def main() -> None:
    print(f"Generating Agrarian Age 5-stem interactive suite ({TOTAL_DUR:.2f}s @ {BPM} BPM, SR={SR} Hz)...")
    ir = make_pastoral_valley_ir()

    stems = [
        ("stem_agr_base_core.wav", render_base_core_stem(ir), -19.5),
        ("stem_agr_pop_rhythm.wav", render_pop_rhythm_stem(ir), -20.5),
        ("stem_agr_pop_chorus.wav", render_pop_chorus_stem(ir), -21.0),
        ("stem_agr_zoom_close.wav", render_zoom_close_stem(ir), -21.8),
        ("stem_agr_zoom_far.wav", render_zoom_far_stem(ir), -20.5),
    ]

    for fname, raw_ext, target_rms in stems:
        final_audio = finalize_stem_with_loop_wrap(raw_ext, target_rms_db=target_rms)
        out_path = OUT_DIR / fname
        repo_path = REPO_ASSET_DIR / fname
        rms_db, peak_db = save_wav(out_path, final_audio)
        save_wav(repo_path, final_audio)
        print(f"  [OK] {fname:26s} | dur={len(final_audio)/SR:.2f}s | RMS={rms_db:6.2f} dBFS | Peak={peak_db:6.2f} dBFS")

    trans_audio = render_era_transition_stone_to_agrarian(ir)
    trans_fname = "trans_stone_to_agrarian.wav"
    t_rms, t_peak = save_wav(OUT_DIR / trans_fname, trans_audio)
    save_wav(REPO_ASSET_DIR / trans_fname, trans_audio)
    print(f"  [OK] {trans_fname:26s} | dur={len(trans_audio)/SR:.2f}s | RMS={t_rms:6.2f} dBFS | Peak={t_peak:6.2f} dBFS")

    print("All 5 Agrarian Age stems + Era Advancement transition synthesized successfully!")


if __name__ == "__main__":
    main()

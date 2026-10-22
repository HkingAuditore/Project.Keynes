"""Generate the Stone Age interactive music suite (5 synchronized stereo stems) for FMOD.

Architecture (60.8s total @ 75 BPM, 4/4, 1 beat = 0.8s, 1 bar = 3.2s, D Dorian / Pentatonic):
  - [0.0s .. 12.8s]  (4 bars)  1. 刚进入游戏 (Intro: 荒原初醒 · Dawn of the Paleolithic)
  - [12.8s .. 28.8s] (5 bars)  2A. 常态循环 I:  《旷野寻踪》(Wandering Gatherers - Bone Flute lead)
  - [28.8s .. 44.8s] (5 bars)  2B. 常态循环 II: 《溪谷石语》(Echoes of the Gorge - Clay Xun & Lithophone)
  - [44.8s .. 60.8s] (5 bars)  2C. 常态循环 III:《星火守夜》(Starlight Vigil - High Flute & Bow Harp)

5 Synchronized Stems:
  1. stem_base_core.wav   - Core Stone Age instruments (Bone Horn intro, Jiahu Bone Flute, Clay Xun, Lithophone, Bow Harp)
  2. stem_pop_rhythm.wav  - Population Tier 1+ (Shamanic Frame Drum, Wood Clappers, Seed Shaker, Hunting-Bow Ostinato)
  3. stem_pop_chorus.wav  - Population Tier 2+ (Ancestral Clan Formant Choir / Throat-Singing Drone & High Flute Harmony)
  4. stem_zoom_close.wav  - Camera Zoom-In (Crackling Hearth Campfire, Flint-Knapping Tool Craft, Clay Udu Hand Percussion)
  5. stem_zoom_far.wav    - Camera Zoom-Out (High-Altitude Steppe Wind, Celestial Overtone Pad, Deep Horizon Drone)
"""

from __future__ import annotations

import math
from pathlib import Path
import wave
import numpy as np
from scipy import signal

SR = 32000
BPM = 75.0
BEAT = 60.0 / BPM          # 0.8s
BAR = BEAT * 4.0           # 3.2s
INTRO_BARS = 4             # 12.8s
LOOP_SECTION_BARS = 5      # 16.0s each
TOTAL_BARS = INTRO_BARS + 3 * LOOP_SECTION_BARS  # 19 bars = 60.8s
TOTAL_DUR = TOTAL_BARS * BAR
N_SAMPLES = int(round(TOTAL_DUR * SR))

# Render extra tail for seamless circular loop wrapping at bar boundaries
TAIL_SEC = 2.4
N_EXT = N_SAMPLES + int(round(TAIL_SEC * SR))

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT.parent / "tmp" / "fmod_stone_age" / "audio"
REPO_ASSET_DIR = ROOT / "Audio" / "ProjectKeynes" / "Assets" / "StoneAge"

# Pitch table (Hz) - D Dorian / D Minor Pentatonic (Just-inflected warm tuning)
NOTES = {
    "D1": 36.71, "A1": 55.00,
    "D2": 73.42, "F2": 87.31, "G2": 98.00, "A2": 110.00, "C3": 130.81,
    "D3": 146.83, "E3": 164.81, "F3": 174.61, "G3": 196.00, "A3": 220.00, "B3": 246.94, "C4": 261.63,
    "D4": 293.66, "E4": 329.63, "F4": 349.23, "G4": 392.00, "A4": 440.00, "B4": 493.88, "C5": 523.25,
    "D5": 587.33, "E5": 659.25, "F5": 698.46, "G5": 783.99, "A5": 880.00,
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


def make_canyon_ir(rt60: float = 2.1, wet_highcut: float = 3800.0, seed: int = 42) -> np.ndarray:
    """Create a realistic stereo natural valley/cave impulse response with early reflections."""
    rng = np.random.default_rng(seed)
    n = int(round(rt60 * SR))
    t = np.arange(n, dtype=np.float64) / SR
    decay = np.exp(-6.9078 * t / rt60)
    noise_l = rng.standard_normal(n) * decay
    noise_r = rng.standard_normal(n) * decay
    # Smooth diffuse build-up (attack 35ms)
    env = 1.0 - np.exp(-t / 0.035)
    noise_l *= env
    noise_r *= env
    # Distinct canyon wall early reflections
    er_times = [0.021, 0.037, 0.053, 0.079, 0.114, 0.163, 0.228]
    er_gains = [0.45, 0.36, 0.28, 0.22, 0.16, 0.12, 0.08]
    for idx, (et, eg) in enumerate(zip(er_times, er_gains)):
        pos = int(round(et * SR))
        if pos < n:
            if idx % 2 == 0:
                noise_l[pos] += eg
                noise_r[min(n - 1, pos + 19)] += eg * 0.7
            else:
                noise_r[pos] += eg
                noise_l[min(n - 1, pos + 23)] += eg * 0.7
    sos = signal.butter(2, [140.0 / (0.5 * SR), wet_highcut / (0.5 * SR)], btype="bandpass", output="sos")
    ir_l = signal.sosfilt(sos, noise_l)
    ir_r = signal.sosfilt(sos, noise_r)
    norm = max(np.max(np.abs(ir_l)), np.max(np.abs(ir_r)), 1e-6)
    return np.stack([ir_l / norm, ir_r / norm], axis=1)


def apply_reverb(stereo: np.ndarray, ir: np.ndarray, wet: float = 0.28) -> np.ndarray:
    if wet <= 0.001:
        return stereo
    n = stereo.shape[0]
    rev_l = signal.fftconvolve(stereo[:, 0], ir[:, 0])[:n]
    rev_r = signal.fftconvolve(stereo[:, 1], ir[:, 1])[:n]
    rev = np.stack([rev_l, rev_r], axis=1)
    # Normalize reverb energy relative to input
    return stereo * (1.0 - 0.35 * wet) + rev * (wet * 0.18)


# ==============================================================================
# Physical Modeling Instruments
# ==============================================================================

def synth_bone_flute(
    freq: float,
    dur: float,
    vel: float = 0.8,
    grace_from: float | None = None,
    vibrato_depth: float = 0.009,
    seed: int = 1,
) -> np.ndarray:
    """Jiahu Bone Flute (贾湖骨笛): breathy edge-tone chiff, pitch slide, warm overtones."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.18) * SR))
    t = np.arange(n, dtype=np.float64) / SR

    # Breath envelope: soft organic attack, expressive mid-note swell, gentle release
    att = 0.065
    rel = 0.16
    env = np.ones(n, dtype=np.float64)
    att_n = max(1, int(round(att * SR)))
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.4
    # Mid-phrase breath arch
    arch = 0.85 + 0.15 * np.sin(math.pi * np.clip(t / max(dur, 0.1), 0.0, 1.0))
    env *= arch
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        dt = (i - rel_start) / SR
        env[i] *= math.exp(-dt / (rel * 0.45))

    # Pitch contour: grace-note slide + delayed vibrato + subtle organic drift
    f_curve = np.full(n, freq, dtype=np.float64)
    if grace_from is not None:
        slide_tau = 0.042
        f_curve = freq + (grace_from - freq) * np.exp(-t / slide_tau)
    else:
        # Subtle upward breath scoop (25 cents)
        f_curve = freq * (1.0 - 0.014 * np.exp(-t / 0.028))

    vib_onset = np.clip((t - 0.22) / 0.25, 0.0, 1.0)
    vib = vibrato_depth * vib_onset * np.sin(2.0 * math.pi * 5.1 * t + rng.uniform(0, 2 * math.pi))
    # Slow random pitch drift
    drift_raw = rng.standard_normal(n)
    sos_drift = signal.butter(2, 3.5 / (0.5 * SR), btype="lowpass", output="sos")
    drift = signal.sosfilt(sos_drift, drift_raw) * 0.0025
    f_inst = f_curve * (1.0 + vib + drift)
    phase = 2.0 * math.pi * np.cumsum(f_inst) / SR

    # Harmonic series of an open bone pipe (strong 1st, 2nd, 3rd; expressive upper harmonics)
    h1 = np.sin(phase)
    h2 = 0.52 * np.sin(2.0 * phase + 0.3) * (0.7 + 0.3 * env)
    h3 = 0.28 * np.sin(3.0 * phase + 1.1) * (0.5 + 0.5 * env)
    h4 = 0.11 * np.sin(4.0 * phase + 0.7) * (env ** 1.5)
    h5 = 0.05 * np.sin(5.0 * phase + 1.9) * (env ** 2.0)
    tone = h1 + h2 + h3 + h4 + h5

    # Edge-tone breath turbulence (chiff on attack + airy sustain coupled to tone)
    white = rng.standard_normal(n)
    chiff_env = 0.55 * np.exp(-t / 0.028) + 0.13 * env
    bw_lo = max(300.0, min(freq * 1.6, SR * 0.42))
    bw_hi = max(bw_lo + 400.0, min(freq * 4.2, SR * 0.46))
    sos_air = signal.butter(2, [bw_lo / (0.5 * SR), bw_hi / (0.5 * SR)], btype="bandpass", output="sos")
    air = signal.sosfilt(sos_air, white) * chiff_env * (1.0 + 0.35 * h1)

    out = (tone * 0.82 + air * 0.24) * env * vel * 0.32
    # Resonant bone tube body peak around 1150 Hz
    b_peak, a_peak = signal.iirpeak(1150.0 / (0.5 * SR), Q=3.5)
    out = 0.75 * out + 0.25 * signal.lfilter(b_peak, a_peak, out)
    return out


def synth_clay_xun(
    freq: float,
    dur: float,
    vel: float = 0.75,
    glide_from: float | None = None,
    seed: int = 2,
) -> np.ndarray:
    """Clay Xun (陶埙): dark, globular Helmholtz vessel flute with warm earthen low-mid resonance."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.25) * SR))
    t = np.arange(n, dtype=np.float64) / SR

    att = 0.11
    att_n = max(1, int(round(att * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.6
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.14 * SR))

    f_curve = np.full(n, freq, dtype=np.float64)
    if glide_from is not None:
        f_curve = freq + (glide_from - freq) * np.exp(-t / 0.065)
    vib = 0.006 * np.clip((t - 0.3) / 0.3, 0.0, 1.0) * np.sin(2.0 * math.pi * 4.4 * t)
    phase = 2.0 * math.pi * np.cumsum(f_curve * (1.0 + vib)) / SR

    # Closed vessel flute emphasizes fundamental and soft 3rd harmonic (12th)
    tone = np.sin(phase) + 0.18 * np.sin(2.0 * phase) + 0.24 * np.sin(3.0 * phase + 0.5) * env

    # Hollow clay cavity air noise
    noise = rng.standard_normal(n)
    f_cav = max(180.0, min(freq * 2.0, 1200.0))
    b_cav, a_cav = signal.iirpeak(f_cav / (0.5 * SR), Q=5.0)
    breath = signal.lfilter(b_cav, a_cav, noise) * (0.22 * np.exp(-t / 0.05) + 0.08 * env)

    return (tone * 0.88 + breath * 0.25) * env * vel * 0.34


def synth_bone_horn(freq: float, dur: float, vel: float = 0.85, seed: int = 3) -> np.ndarray:
    """Ceremonial Prehistoric Bone/Conch Horn (远古螺号/骨角) for the Game-Start Intro."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.6) * SR))
    t = np.arange(n, dtype=np.float64) / SR

    # Slow majestic swell
    env = np.zeros(n, dtype=np.float64)
    swell_peak = dur * 0.45
    for i in range(n):
        ti = t[i]
        if ti < swell_peak:
            env[i] = math.sin(0.5 * math.pi * (ti / swell_peak)) ** 1.8
        elif ti < dur:
            env[i] = 1.0 - 0.18 * ((ti - swell_peak) / max(dur - swell_peak, 0.01))
        else:
            env[i] = 0.82 * math.exp(-(ti - dur) / 0.25)

    # Lip-reed pitch swell from slightly flat into pure resonance
    f_inst = freq * (1.0 - 0.025 * np.exp(-t / 0.18) + 0.004 * np.sin(2.0 * math.pi * 3.8 * t))
    phase = 2.0 * math.pi * np.cumsum(f_inst) / SR

    # Brass/horn harmonic bloom as envelope swells
    sig = np.zeros(n, dtype=np.float64)
    harm_weights = [1.0, 0.85, 0.62, 0.40, 0.25, 0.15, 0.08, 0.04]
    for k, w in enumerate(harm_weights, start=1):
        bloom = env ** (1.0 + 0.32 * (k - 1))
        sig += w * bloom * np.sin(k * phase + 0.2 * k)

    # Warm horn formant around 520 Hz and 1100 Hz
    sos_lp = signal.butter(2, 2200.0 / (0.5 * SR), btype="lowpass", output="sos")
    sig = signal.sosfilt(sos_lp, sig)
    noise = signal.sosfilt(
        signal.butter(2, [250.0 / (0.5 * SR), 900.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    )
    return (sig * 0.42 + noise * 0.06 * env) * env * vel * 0.38


def synth_lithophone(freq: float, dur: float = 1.8, vel: float = 0.7, seed: int = 4) -> np.ndarray:
    """River-Stone Lithophone (石磬/燧石编磬): inharmonic modal synthesis + stone mallet click."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR

    # Modal ratios characteristic of resonant limestone/jade-stone bars
    modes = [1.000, 2.318, 3.864, 5.412, 7.150]
    amps = [1.00, 0.42, 0.20, 0.09, 0.04]
    decays = [0.75, 0.38, 0.21, 0.11, 0.06]

    sig = np.zeros(n, dtype=np.float64)
    for ratio, amp, tau in zip(modes, amps, decays):
        f_m = freq * ratio
        if f_m < SR * 0.45:
            sig += amp * np.exp(-t / tau) * np.sin(2.0 * math.pi * f_m * t + rng.uniform(0, 0.5))

    # Crisp stone-on-stone mallet transient (first 6ms)
    click_env = np.exp(-t / 0.0025)
    click = signal.sosfilt(
        signal.butter(2, [900.0 / (0.5 * SR), 5500.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * click_env * 0.35

    att_env = 1.0 - np.exp(-t / 0.0018)
    return (sig * att_env + click) * vel * 0.24


def synth_hunting_bow(freq: float, dur: float = 1.5, vel: float = 0.75, seed: int = 5) -> np.ndarray:
    """Plucked Hunting Bow / Gourd Harp (猎弓琴): Karplus-Strong waveguide string + gourd body."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    delay = max(4, int(round(SR / freq)))

    # Initial excitation: warm finger pluck (pink-ish filtered burst + pick-position comb)
    burst = rng.standard_normal(delay)
    sos_pluck = signal.butter(2, min(0.45, (freq * 6.5) / (0.5 * SR)), btype="lowpass", output="sos")
    burst = signal.sosfilt(sos_pluck, burst)
    pick_offset = max(1, int(delay * 0.28))
    burst = burst - 0.65 * np.roll(burst, pick_offset)

    buf = np.zeros(n, dtype=np.float64)
    buf[:delay] = burst

    # Karplus-Strong loop with warm damping
    damping = 0.9945 if freq < 250.0 else 0.992
    for i in range(delay, n):
        buf[i] = damping * (0.58 * buf[i - delay] + 0.42 * buf[i - delay + 1])

    # Gourd / wooden resonator body peaks
    b1, a1 = signal.iirpeak(195.0 / (0.5 * SR), Q=3.2)
    b2, a2 = signal.iirpeak(430.0 / (0.5 * SR), Q=4.0)
    body = 0.65 * buf + 0.22 * signal.lfilter(b1, a1, buf) + 0.13 * signal.lfilter(b2, a2, buf)
    norm = max(np.max(np.abs(body)), 1e-6)
    t = np.arange(n, dtype=np.float64) / SR
    fade = np.exp(-t / (dur * 0.75))
    return (body / norm) * fade * vel * 0.28


def synth_frame_drum(freq: float = 68.0, dur: float = 0.55, vel: float = 0.85, rim: bool = False, seed: int = 6) -> np.ndarray:
    """Shamanic Animal-Skin Frame Drum (部落兽皮帧鼓): circular membrane modes + pitch drop."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR

    if rim:
        # Wooden rim / stone clapper hit
        modes = [1.0, 1.72, 2.58]
        base_f = 340.0
        sig = sum(
            w * np.exp(-t / tau) * np.sin(2.0 * math.pi * base_f * m * t)
            for m, w, tau in zip(modes, [1.0, 0.55, 0.3], [0.045, 0.025, 0.015])
        )
        snap = signal.sosfilt(
            signal.butter(2, [800.0 / (0.5 * SR), 4200.0 / (0.5 * SR)], btype="bandpass", output="sos"),
            rng.standard_normal(n),
        ) * np.exp(-t / 0.008)
        return (sig * 0.65 + snap * 0.45) * vel * 0.28

    # Membrane pitch drop on impact
    f_env = freq * (1.0 + 0.42 * np.exp(-t / 0.028))
    phase = 2.0 * math.pi * np.cumsum(f_env) / SR
    # Circular drumhead modes (01, 11, 21, 02)
    m01 = np.sin(phase) * np.exp(-t / 0.21)
    m11 = 0.42 * np.sin(1.593 * phase + 0.4) * np.exp(-t / 0.11)
    m21 = 0.22 * np.sin(2.135 * phase + 1.1) * np.exp(-t / 0.065)
    m02 = 0.14 * np.sin(2.295 * phase + 1.9) * np.exp(-t / 0.045)

    # Leather palm thump transient
    thump = signal.sosfilt(
        signal.butter(2, [120.0 / (0.5 * SR), 950.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.014) * 0.35

    return (m01 + m11 + m21 + m02 + thump) * vel * 0.36


def synth_seed_shaker(dur: float = 0.18, vel: float = 0.5, seed: int = 7) -> np.ndarray:
    """Bone/Seed-pod Shaker (果壳/骨珠摇铃): granular micro-impulses."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    env = np.sin(math.pi * np.clip(t / dur, 0.0, 1.0)) ** 1.8 * np.exp(-t / (dur * 0.55))
    # Sparse grain cluster
    raw = rng.standard_normal(n) * (rng.random(n) > 0.65).astype(np.float64)
    sos = signal.butter(2, [2800.0 / (0.5 * SR), 8500.0 / (0.5 * SR)], btype="bandpass", output="sos")
    return signal.sosfilt(sos, raw) * env * vel * 0.22


def synth_udu_clay_pot(pitch_hz: float = 105.0, bend_up: bool = True, vel: float = 0.7, seed: int = 8) -> np.ndarray:
    """Close-mic Clay Pot / Udu Hand Drum (近场陶罐指击鼓) for Camera Zoom-In."""
    rng = np.random.default_rng(seed)
    dur = 0.38
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    if bend_up:
        # Classic Udu water-pot "bloop" upward pitch bend when hand lifts off hole
        f_inst = pitch_hz * (1.0 + 0.32 * np.sin(math.pi * np.clip(t / 0.16, 0.0, 1.0)))
    else:
        f_inst = pitch_hz * (1.0 + 0.18 * np.exp(-t / 0.025))
    phase = 2.0 * math.pi * np.cumsum(f_inst) / SR
    cavity = (np.sin(phase) + 0.25 * np.sin(2.4 * phase)) * np.exp(-t / 0.12)
    finger_tap = signal.sosfilt(
        signal.butter(2, [1100.0 / (0.5 * SR), 3800.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.006) * 0.32
    return (cavity + finger_tap) * vel * 0.28


def synth_flint_knap(vel: float = 0.65, seed: int = 9) -> np.ndarray:
    """Flint-knapping stone tool strike (燧石打制脆响) for Camera Zoom-In."""
    rng = np.random.default_rng(seed)
    dur = 0.14
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    # High, glassy stone chip resonances (2100 Hz, 3450 Hz, 5200 Hz)
    chip = (
        0.6 * np.sin(2.0 * math.pi * 2120.0 * t) * np.exp(-t / 0.012)
        + 0.45 * np.sin(2.0 * math.pi * 3480.0 * t) * np.exp(-t / 0.008)
        + 0.30 * np.sin(2.0 * math.pi * 5180.0 * t) * np.exp(-t / 0.005)
    )
    scrape = signal.sosfilt(
        signal.butter(2, [1800.0 / (0.5 * SR), 7200.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.007) * 0.4
    return (chip + scrape) * vel * 0.22


def synth_ancestral_choir_chord(freqs: list[float], dur: float, vel: float = 0.65, seed: int = 10) -> np.ndarray:
    """Ancestral Clan Choir & Throat-Singing Formant Pad (氏族呼麦与人声合唱) for High Population."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.5) * SR))
    t = np.arange(n, dtype=np.float64) / SR

    # Slow, warm choral attack and release
    env = np.ones(n, dtype=np.float64)
    att_n = int(round(0.45 * SR))
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.5
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.22 * SR))

    # Rich glottal chorus source across voices (3 detuned singers per note)
    raw = np.zeros(n, dtype=np.float64)
    for f0 in freqs:
        for detune_cents in [-7.0, 0.0, +7.5]:
            f_v = f0 * (2.0 ** (detune_cents / 1200.0))
            vib = 0.004 * np.sin(2.0 * math.pi * rng.uniform(4.2, 5.3) * t + rng.uniform(0, 6.28))
            ph = 2.0 * math.pi * np.cumsum(f_v * (1.0 + vib)) / SR
            # Softened sawtooth / glottal wave (first 10 harmonics)
            voice = sum((1.0 / (k ** 1.15)) * np.sin(k * ph) for k in range(1, 11))
            raw += voice * (1.0 / len(freqs))

    # Morph between two warm vowel formants ("Ooo" [320, 780, 2350] and "Ahh" [580, 1080, 2500])
    f1_ooo, f2_ooo, f3_ooo = 330.0, 780.0, 2350.0
    f1_ahh, f2_ahh, f3_ahh = 560.0, 1060.0, 2520.0

    def apply_formants(sig: np.ndarray, f1: float, f2: float, f3: float) -> np.ndarray:
        b1, a1 = signal.iirpeak(f1 / (0.5 * SR), Q=4.5)
        b2, a2 = signal.iirpeak(f2 / (0.5 * SR), Q=5.5)
        b3, a3 = signal.iirpeak(f3 / (0.5 * SR), Q=6.5)
        return (
            0.58 * signal.lfilter(b1, a1, sig)
            + 0.30 * signal.lfilter(b2, a2, sig)
            + 0.12 * signal.lfilter(b3, a3, sig)
        )

    v_ooo = apply_formants(raw, f1_ooo, f2_ooo, f3_ooo)
    v_ahh = apply_formants(raw, f1_ahh, f2_ahh, f3_ahh)
    morph = 0.5 - 0.5 * np.cos(2.0 * math.pi * t / max(dur, 1.0))
    choral = (1.0 - morph) * v_ooo + morph * v_ahh
    norm = max(np.max(np.abs(choral)), 1e-6)
    return (choral / norm) * env * vel * 0.24


# ==============================================================================
# Seamless Loop Wrapping & Loudness Helpers
# ==============================================================================

def wrap_loop_boundaries(buf: np.ndarray) -> np.ndarray:
    """Ensure [12.8s .. 60.8s] and each 16.0s section boundary wrap seamlessly without clicks."""
    out = buf[:N_SAMPLES].copy()
    loop_start = int(round(INTRO_BARS * BAR * SR))  # 12.8s
    loop_end = N_SAMPLES                            # 60.8s
    tail_len = min(buf.shape[0] - N_SAMPLES, int(round(1.6 * SR)))

    # 1. Fold the post-60.8s reverb/release tail into the start of the loop region (12.8s)
    if tail_len > 0:
        fade_tail = np.cos(0.5 * math.pi * np.linspace(0.0, 1.0, tail_len))[:, None] ** 1.5
        out[loop_start:loop_start + tail_len] += buf[loop_end:loop_end + tail_len] * fade_tail

    # 2. Short 60ms equal-power crossfade at each 16s loop boundary so single-section
    #    loops (A, B, C) and the full cycle (60.8s -> 12.8s) have zero sample discontinuity
    xf_n = int(round(0.060 * SR))
    boundaries = [
        loop_start,
        loop_start + int(round(5 * BAR * SR)),
        loop_start + int(round(10 * BAR * SR)),
        loop_end,
    ]
    # Match end of each section smoothly toward the start of Loop A / its own start
    t_fade = np.linspace(0.0, 1.0, xf_n)[:, None]
    w_in = np.sin(0.5 * math.pi * t_fade)
    w_out = np.cos(0.5 * math.pi * t_fade)

    # Full loop wrap: smooth last xf_n samples before 60.8s into loop_start
    out[loop_end - xf_n:loop_end] = (
        out[loop_end - xf_n:loop_end] * w_out + out[loop_start:loop_start + xf_n] * (1.0 - w_out)
    )

    # Very gentle 0.25s fade-in at t=0.0s (game start)
    fi_n = int(round(0.25 * SR))
    out[:fi_n] *= np.linspace(0.0, 1.0, fi_n)[:, None]
    return out


def normalize_stem(stereo: np.ndarray, target_rms_db: float = -21.0, peak_limit_db: float = -1.5) -> tuple[np.ndarray, float, float]:
    """Normalize stereo stem to target RMS (dBFS) with soft-knee peak limiting."""
    rms = math.sqrt(float(np.mean(stereo ** 2)) + 1e-12)
    current_rms_db = 20.0 * math.log10(rms)
    gain = 10.0 ** ((target_rms_db - current_rms_db) / 20.0)
    scaled = stereo * gain

    peak_limit = 10.0 ** (peak_limit_db / 20.0)
    peak = float(np.max(np.abs(scaled)))
    if peak > peak_limit:
        # Gentle tanh soft limiter above -6 dBFS
        scaled = np.tanh(scaled / peak_limit) * peak_limit

    final_rms_db = 20.0 * math.log10(math.sqrt(float(np.mean(scaled ** 2)) + 1e-12))
    final_peak_db = 20.0 * math.log10(float(np.max(np.abs(scaled))) + 1e-12)
    return scaled, final_rms_db, final_peak_db


def write_wav(path: Path, stereo: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = np.clip(np.round(stereo * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as wf:
        wf.setparams((2, 2, SR, stereo.shape[0], "NONE", "not compressed"))
        wf.writeframes(pcm.tobytes())


# ==============================================================================
# Score Composition & Stem Rendering
# ==============================================================================

def build_stem_base_core(ir: np.ndarray) -> np.ndarray:
    """Stem 1: Core Stone Age Suite (Intro + Loop A + Loop B + Loop C)."""
    buf = np.zeros((N_EXT, 2), dtype=np.float64)

    # --- SECTION 0: 刚进入游戏 Intro (Bars 0..3, 0.0s .. 12.8s) ---
    # Ceremonial Bone Horn calls + awakening Xun drone + Lithophone spark + lone Bone Flute
    add_clip(buf, 0.3, pan_stereo(synth_bone_horn(n2f("D2"), 4.2, vel=0.90, seed=101), pan=-0.15, haas_ms=6.0))
    add_clip(buf, 2.0, pan_stereo(synth_bone_horn(n2f("A2"), 3.6, vel=0.78, seed=102), pan=0.22, haas_ms=-7.0))
    add_clip(buf, 5.2, pan_stereo(synth_bone_horn(n2f("D3"), 3.8, vel=0.82, seed=103), pan=0.05, haas_ms=5.0))

    # Shimmering river-stone strikes in the intro
    for bt, note, pan in [(1.6, "A4", -0.35), (4.8, "D5", 0.38), (5.6, "A4", -0.25), (8.4, "F4", 0.30), (11.2, "A4", -0.20)]:
        add_clip(buf, bt, pan_stereo(synth_lithophone(n2f(note), 2.2, vel=0.68, seed=int(bt * 10)), pan=pan))

    # Awakening Bone Flute call in Bars 2..3 (6.4s .. 12.8s) leading into Loop A
    intro_flute = [
        (6.4, "A4", 1.5, "G4"),
        (8.0, "G4", 0.75, None),
        (8.8, "F4", 0.85, "G4"),
        (9.6, "D4", 1.5, "C4"),
        (11.2, "C4", 0.75, None),
        (12.0, "D4", 0.85, "C4"),
    ]
    for idx, (st, nt, dur, gr) in enumerate(intro_flute):
        clip = synth_bone_flute(n2f(nt), dur, vel=0.82, grace_from=n2f(gr) if gr else None, seed=200 + idx)
        add_clip(buf, st, pan_stereo(clip, pan=-0.12, haas_ms=4.5))

    # Warm Clay Xun bass bed across all 19 bars (ensures harmonic continuity at every boundary)
    # Bar-by-bar root progression (in bars):
    # Intro (0..3): D2, D2, G2, A2
    # Loop A (4..8): D3, C3, G2, A2, D3
    # Loop B (9..13): D3, F2, G2, A2, D3
    # Loop C (14..18): D3, A2, G2, A2, D3
    bass_bars = [
        (0, "D2"), (1, "D2"), (2, "G2"), (3, "A2"),
        (4, "D3"), (5, "C3"), (6, "G2"), (7, "A2"), (8, "D3"),
        (9, "D3"), (10, "F2"), (11, "G2"), (12, "A2"), (13, "D3"),
        (14, "D3"), (15, "A2"), (16, "G2"), (17, "A2"), (18, "D3"),
    ]
    for b_idx, b_note in bass_bars:
        st = b_idx * BAR
        xun_bass = synth_clay_xun(n2f(b_note), BAR * 0.92, vel=0.62, seed=300 + b_idx)
        add_clip(buf, st, pan_stereo(xun_bass, pan=0.08))
        # Subtle fifth harmonic drone on D3/A2
        fifth_freq = n2f(b_note) * 1.5
        fifth_drone = synth_clay_xun(fifth_freq, BAR * 0.85, vel=0.32, seed=350 + b_idx)
        add_clip(buf, st + 0.15, pan_stereo(fifth_drone, pan=-0.18))

    # --- LOOP I: 常态循环 A《旷野寻踪》(Bars 4..8, 12.8s .. 28.8s) ---
    # Contemplative Jiahu Bone Flute lead + sparse Plucked Bow + Lithophone droplets
    tA = 4 * BAR  # 12.8s
    loop_a_flute = [
        (0.0, "D4", 1.4, "C4"), (1.6, "F4", 0.75, None), (2.4, "G4", 0.75, "F4"),
        (3.2, "A4", 1.9, "G4"), (5.6, "G4", 0.75, None),
        (6.4, "F4", 1.1, "G4"), (7.6, "D4", 1.1, None), (8.8, "C4", 0.75, None),
        (9.6, "D4", 1.5, "C4"), (11.2, "F4", 0.75, None), (12.0, "E4", 0.75, "F4"),
        (12.8, "D4", 2.4, "C4"),  # Bar 8: resolves to D4 with breathing room before 28.8s
    ]
    for idx, (rel_s, nt, dur, gr) in enumerate(loop_a_flute):
        clip = synth_bone_flute(n2f(nt), dur, vel=0.84, grace_from=n2f(gr) if gr else None, seed=400 + idx)
        add_clip(buf, tA + rel_s, pan_stereo(clip, pan=-0.16, haas_ms=5.0))

    # Sparse bow plucks & lithophone bells in Loop A
    for idx, (rel_s, nt, pan) in enumerate([
        (0.0, "A3", 0.28), (1.6, "D4", -0.25), (3.2, "G3", 0.30), (4.8, "C4", -0.22),
        (6.4, "D4", 0.25), (8.0, "A3", -0.28), (9.6, "E4", 0.32), (12.8, "A3", -0.20), (14.4, "D4", 0.22),
    ]):
        bow = synth_hunting_bow(n2f(nt), 1.8, vel=0.58, seed=450 + idx)
        add_clip(buf, tA + rel_s, pan_stereo(bow, pan=pan))
    for idx, (rel_s, nt) in enumerate([(2.4, "A4"), (6.0, "D5"), (11.6, "A4"), (14.8, "D5")]):
        add_clip(buf, tA + rel_s, pan_stereo(synth_lithophone(n2f(nt), 2.0, vel=0.52, seed=480 + idx), pan=0.35))

    # --- LOOP II: 常态循环 B《溪谷石语》(Bars 9..13, 28.8s .. 44.8s) ---
    # Deep Clay Xun lyrical solo + crystalline Lithophone & Hunting Bow dialogue
    tB = 9 * BAR  # 28.8s
    loop_b_xun = [
        (0.0, "A3", 1.5, "G3"), (1.6, "D4", 1.4, "C4"),
        (3.2, "C4", 1.1, None), (4.4, "A3", 1.1, "C4"), (5.6, "G3", 0.75, None),
        (6.4, "F3", 1.5, None), (8.0, "G3", 0.75, "F3"), (8.8, "A3", 0.75, None),
        # Bar 12 (9.6..12.8s): Xun pauses for canyon lithophone echo, then answers
        (11.2, "G3", 0.75, None), (12.0, "F3", 0.75, None),
        (12.8, "D3", 2.5, "C3"),
    ]
    for idx, (rel_s, nt, dur, gl) in enumerate(loop_b_xun):
        clip = synth_clay_xun(n2f(nt), dur, vel=0.86, glide_from=n2f(gl) if gl else None, seed=500 + idx)
        add_clip(buf, tB + rel_s, pan_stereo(clip, pan=0.14, haas_ms=-5.5))

    # Crystalline Lithophone melody in Loop B (especially shining in the Bar 12 breathing window)
    loop_b_stones = [
        (0.8, "D5", -0.32), (2.4, "A4", 0.30), (4.0, "F4", -0.28), (5.6, "G4", 0.34),
        (7.2, "A4", -0.30), (9.6, "D5", -0.35), (10.4, "C5", 0.35), (11.2, "A4", -0.25),
        (12.0, "G4", 0.28), (12.8, "F4", -0.30), (13.6, "D4", 0.25), (14.4, "A4", -0.20),
    ]
    for idx, (rel_s, nt, pan) in enumerate(loop_b_stones):
        add_clip(buf, tB + rel_s, pan_stereo(synth_lithophone(n2f(nt), 2.1, vel=0.72, seed=550 + idx), pan=pan))

    # Plucked Hunting Bow accompaniment in Loop B
    for bar_off in range(5):
        bar_t = tB + bar_off * BAR
        chord = ["D3", "A3", "D4", "F4"] if bar_off % 2 == 0 else ["G3", "C4", "D4", "G4"]
        for step, note in enumerate(chord):
            add_clip(
                buf,
                bar_t + step * BEAT,
                pan_stereo(synth_hunting_bow(n2f(note), 1.6, vel=0.62, seed=580 + bar_off * 10 + step), pan=-0.24),
            )

    # --- LOOP III: 常态循环 C《星火守夜》(Bars 14..18, 44.8s .. 60.8s) ---
    # Soaring upper-register Bone Flute + Xun counter-melody + warm Bow Harp arpeggios
    tC = 14 * BAR  # 44.8s
    loop_c_flute = [
        (0.0, "A4", 1.5, "G4"), (1.6, "C5", 0.75, "A4"), (2.4, "D5", 0.85, "C5"),
        (3.2, "E5", 1.1, "D5"), (4.4, "D5", 1.1, None), (5.6, "C5", 0.75, "D5"),
        (6.4, "A4", 1.5, "G4"), (8.0, "G4", 0.75, None), (8.8, "F4", 0.75, "G4"),
        (9.6, "G4", 1.1, "F4"), (10.8, "A4", 1.1, None), (12.0, "F4", 0.75, "G4"),
        (12.8, "D4", 2.4, "C4"),  # Resolves smoothly to D4 before wrapping to 12.8s
    ]
    for idx, (rel_s, nt, dur, gr) in enumerate(loop_c_flute):
        clip = synth_bone_flute(n2f(nt), dur, vel=0.85, grace_from=n2f(gr) if gr else None, seed=600 + idx)
        add_clip(buf, tC + rel_s, pan_stereo(clip, pan=-0.10, haas_ms=5.0))

    # Warm Clay Xun counter-melody in thirds/fifths during Loop C
    loop_c_xun = [
        (0.0, "D4", 1.5), (1.6, "F4", 1.5),
        (3.2, "A3", 1.5), (4.8, "G3", 1.5),
        (6.4, "D4", 1.5), (8.0, "C4", 1.5),
        (9.6, "B3", 1.5), (11.2, "A3", 1.5),
        (12.8, "A3", 1.2), (14.0, "D3", 1.6),
    ]
    for idx, (rel_s, nt, dur) in enumerate(loop_c_xun):
        clip = synth_clay_xun(n2f(nt), dur, vel=0.68, seed=650 + idx)
        add_clip(buf, tC + rel_s, pan_stereo(clip, pan=0.22, haas_ms=-5.0))

    # Harp-like Hunting Bow 8th-note arpeggios in Loop C
    arp_notes = ["D3", "A3", "D4", "F4", "A4", "F4", "D4", "A3"]
    for bar_off in range(5):
        for step, nt in enumerate(arp_notes):
            rel_s = bar_off * BAR + step * (BEAT * 0.5)
            bow = synth_hunting_bow(n2f(nt), 1.3, vel=0.54, seed=700 + bar_off * 8 + step)
            add_clip(buf, tC + rel_s, pan_stereo(bow, pan=-0.28 + 0.08 * (step % 3)))

    buf = apply_reverb(buf, ir, wet=0.32)
    return wrap_loop_boundaries(buf)


def build_stem_pop_rhythm(ir: np.ndarray) -> np.ndarray:
    """Stem 2: Population Threshold Layer 1 (Tribe Rhythm: Shamanic Frame Drum, Shaker, Clappers, Bow Ostinato)."""
    buf = np.zeros((N_EXT, 2), dtype=np.float64)

    # Pre-synthesize reusable percussion hits with human variation
    drums_low = [synth_frame_drum(66.0, 0.55, vel=0.88, rim=False, seed=800 + i) for i in range(6)]
    drums_mid = [synth_frame_drum(92.0, 0.42, vel=0.72, rim=False, seed=820 + i) for i in range(6)]
    rim_claps = [synth_frame_drum(340.0, 0.22, vel=0.65, rim=True, seed=840 + i) for i in range(6)]
    shakers_acc = [synth_seed_shaker(0.16, vel=0.58, seed=860 + i) for i in range(6)]
    shakers_soft = [synth_seed_shaker(0.13, vel=0.34, seed=880 + i) for i in range(6)]

    # In the Intro (Bars 0..3), keep percussion sparse ceremonial heartbeats building into Bar 4
    for b in range(INTRO_BARS):
        bt = b * BAR
        add_clip(buf, bt + 0.0 * BEAT, pan_stereo(drums_low[b % 6], pan=-0.05), gain=0.55 + 0.12 * b)
        add_clip(buf, bt + 0.5 * BEAT, pan_stereo(drums_mid[b % 6], pan=0.10), gain=0.45 + 0.10 * b)
        if b >= 2:
            add_clip(buf, bt + 2.0 * BEAT, pan_stereo(drums_low[(b + 1) % 6], pan=-0.05), gain=0.70)
            add_clip(buf, bt + 3.0 * BEAT, pan_stereo(rim_claps[b % 6], pan=0.25), gain=0.65)
            add_clip(buf, bt + 3.5 * BEAT, pan_stereo(drums_mid[(b + 2) % 6], pan=-0.18), gain=0.75)

    # Across Loop Bars 4..18 (12.8s .. 60.8s): full tribal groove + rhythmic hunting bow ostinato
    for b in range(INTRO_BARS, TOTAL_BARS):
        bt = b * BAR
        is_cadence = (b in (8, 13, 18))
        # Beat 1: deep shaman drum heartbeat
        add_clip(buf, bt + 0.0 * BEAT, pan_stereo(drums_low[b % 6], pan=-0.06))
        # Beat 1.75: syncopated mid skin hit
        add_clip(buf, bt + 0.75 * BEAT, pan_stereo(drums_mid[(b + 1) % 6], pan=0.18), gain=0.72)
        # Beat 2: wooden clapper / rim + low drum
        add_clip(buf, bt + 1.0 * BEAT, pan_stereo(rim_claps[b % 6], pan=-0.28), gain=0.68)
        # Beat 2.5: low drum answer
        add_clip(buf, bt + 1.5 * BEAT, pan_stereo(drums_low[(b + 2) % 6], pan=0.05), gain=0.82)
        # Beat 3: deep drum
        add_clip(buf, bt + 2.0 * BEAT, pan_stereo(drums_low[(b + 3) % 6], pan=-0.08), gain=0.90)
        # Beat 3.5: mid drum
        if not is_cadence:
            add_clip(buf, bt + 2.5 * BEAT, pan_stereo(drums_mid[(b + 4) % 6], pan=0.20), gain=0.75)
        # Beat 4: rim clapper + turnaround pickup
        add_clip(buf, bt + 3.0 * BEAT, pan_stereo(rim_claps[(b + 2) % 6], pan=0.26), gain=0.74)
        add_clip(buf, bt + 3.5 * BEAT, pan_stereo(drums_mid[(b + 5) % 6], pan=-0.16), gain=0.68)

        # 8th-note seed-pod shaker groove across the bar
        for eighth in range(8):
            sh_t = bt + eighth * (BEAT * 0.5)
            sh = shakers_acc[eighth % 6] if (eighth % 2 == 0) else shakers_soft[eighth % 6]
            add_clip(buf, sh_t, pan_stereo(sh, pan=-0.34 if eighth % 2 == 0 else 0.34))

        # Rhythmic Hunting Bow bass ostinato (gives harmonic drive when population grows)
        ost_root = "D2" if (b % 5 in (0, 4)) else ("C3" if b % 5 == 1 else ("G2" if b % 5 == 2 else "A2"))
        ost_fifth = "A2" if ost_root == "D2" else ("G3" if ost_root == "C3" else "D3")
        for step, nt in enumerate([ost_root, ost_fifth, ost_root, ost_fifth, ost_root, ost_fifth, ost_root, ost_fifth]):
            bow = synth_hunting_bow(n2f(nt), 0.55, vel=0.68 if step % 2 == 0 else 0.48, seed=900 + b * 8 + step)
            add_clip(buf, bt + step * (BEAT * 0.5), pan_stereo(bow, pan=0.15 if step % 2 == 0 else -0.15))

    buf = apply_reverb(buf, ir, wet=0.20)
    return wrap_loop_boundaries(buf)


def build_stem_pop_chorus(ir: np.ndarray) -> np.ndarray:
    """Stem 3: Population Threshold Layer 2 (Thriving Clan: Ancestral Formant Choir + High Flute & Lithophone Flourish)."""
    buf = np.zeros((N_EXT, 2), dtype=np.float64)

    # Chord progression per bar for the Ancestral Clan Choir
    bar_chords = {
        0: ["D2", "A2", "D3"], 1: ["D2", "A2", "F3"], 2: ["G2", "D3", "G3"], 3: ["A2", "E3", "A3"],
        4: ["D2", "A2", "D3", "F3"], 5: ["C3", "G3", "C4", "E4"], 6: ["G2", "D3", "G3", "B3"],
        7: ["A2", "E3", "A3", "C4"], 8: ["D2", "A2", "D3", "F3"],
        9: ["D2", "A2", "D3", "A3"], 10: ["F2", "C3", "F3", "A3"], 11: ["G2", "D3", "G3", "B3"],
        12: ["A2", "E3", "A3", "C4"], 13: ["D2", "A2", "D3", "F3"],
        14: ["D2", "A2", "D3", "F3"], 15: ["A2", "E3", "A3", "C4"], 16: ["G2", "D3", "G3", "B3"],
        17: ["A2", "E3", "A3", "C4"], 18: ["D2", "A2", "D3", "F3"],
    }
    for b, notes in bar_chords.items():
        freqs = [n2f(x) for x in notes]
        choir = synth_ancestral_choir_chord(freqs, BAR * 0.96, vel=0.78 if b >= 4 else 0.55, seed=1000 + b)
        add_clip(buf, b * BAR, pan_stereo(choir, pan=0.0, haas_ms=9.0))

    # Celebratory high bone-flute descant & lithophone arpeggios during Loop A/B/C
    descant_notes = [
        (4 * BAR + 0.0, "A4", 1.5), (4 * BAR + 1.6, "D5", 1.5), (4 * BAR + 3.2, "C5", 1.5), (4 * BAR + 4.8, "E5", 1.5),
        (4 * BAR + 6.4, "D5", 1.5), (4 * BAR + 8.0, "B4", 1.5), (4 * BAR + 9.6, "C5", 1.5), (4 * BAR + 11.2, "A4", 1.5),
        (4 * BAR + 12.8, "A4", 2.6),
        (9 * BAR + 0.0, "F4", 1.5), (9 * BAR + 1.6, "A4", 1.5), (9 * BAR + 3.2, "A4", 1.5), (9 * BAR + 4.8, "C5", 1.5),
        (9 * BAR + 6.4, "B4", 1.5), (9 * BAR + 8.0, "D5", 1.5), (9 * BAR + 9.6, "C5", 1.5), (9 * BAR + 11.2, "E5", 1.5),
        (9 * BAR + 12.8, "D5", 2.6),
        (14 * BAR + 0.0, "D5", 1.5), (14 * BAR + 1.6, "F5", 1.5), (14 * BAR + 3.2, "E5", 1.5), (14 * BAR + 4.8, "C5", 1.5),
        (14 * BAR + 6.4, "D5", 1.5), (14 * BAR + 8.0, "B4", 1.5), (14 * BAR + 9.6, "C5", 1.5), (14 * BAR + 11.2, "A4", 1.5),
        (14 * BAR + 12.8, "A4", 2.6),
    ]
    for idx, (st, nt, dur) in enumerate(descant_notes):
        fl = synth_bone_flute(n2f(nt), dur, vel=0.58, seed=1100 + idx)
        add_clip(buf, st, pan_stereo(fl, pan=0.28 if idx % 2 == 0 else -0.28, haas_ms=-6.0))
        stone = synth_lithophone(n2f(nt), 1.8, vel=0.45, seed=1200 + idx)
        add_clip(buf, st + 0.4, pan_stereo(stone, pan=-0.35 if idx % 2 == 0 else 0.35))

    buf = apply_reverb(buf, ir, wet=0.38)
    return wrap_loop_boundaries(buf)


def build_stem_zoom_close() -> np.ndarray:
    """Stem 4: Camera Zoom-In (Close-up Settlement View: Campfire Crackling, Flint-Knapping, Clay Udu Hand Percussion)."""
    rng = np.random.default_rng(2026)
    buf = np.zeros((N_EXT, 2), dtype=np.float64)
    t = np.arange(N_EXT, dtype=np.float64) / SR

    # 1. Warm Hearth Campfire bed (low flame flicker + stereo wood-sap crackles & pops)
    flame_l = signal.sosfilt(
        signal.butter(2, [55.0 / (0.5 * SR), 240.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(N_EXT),
    )
    flame_r = signal.sosfilt(
        signal.butter(2, [55.0 / (0.5 * SR), 240.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(N_EXT),
    )
    flicker = 0.65 + 0.35 * np.sin(2.0 * math.pi * 1.7 * t) * np.sin(2.0 * math.pi * 0.43 * t + 0.8)
    buf[:, 0] += flame_l * flicker * 0.045
    buf[:, 1] += flame_r * flicker * 0.045

    # Stochastic wood crackles (short resonant bursts at 1.8k..6.5kHz)
    n_crackles = int(TOTAL_DUR * 9.5)
    for i in range(n_crackles):
        ct = rng.uniform(0.1, TOTAL_DUR + 1.0)
        c_dur = rng.uniform(0.008, 0.028)
        cn = int(round(c_dur * SR))
        tt = np.arange(cn, dtype=np.float64) / SR
        f_cr = rng.uniform(1600.0, 5800.0)
        b_c, a_c = signal.iirpeak(f_cr / (0.5 * SR), Q=3.0)
        crackle = signal.lfilter(b_c, a_c, rng.standard_normal(cn)) * np.exp(-tt / (c_dur * 0.32)) * rng.uniform(0.06, 0.18)
        add_clip(buf, ct, pan_stereo(crackle, pan=rng.uniform(-0.65, 0.65)))

    # 2. Intimate Close-Mic Clay Udu Pot & Flint-Knapping rhythmic pattern (dry, tactile, village atmosphere)
    udu_up = [synth_udu_clay_pot(108.0, bend_up=True, vel=0.78, seed=1300 + i) for i in range(4)]
    udu_dn = [synth_udu_clay_pot(88.0, bend_up=False, vel=0.72, seed=1310 + i) for i in range(4)]
    flints = [synth_flint_knap(vel=0.68, seed=1320 + i) for i in range(6)]

    for b in range(TOTAL_BARS):
        bt = b * BAR
        # Clay Udu pot intimate groove
        add_clip(buf, bt + 0.0 * BEAT, pan_stereo(udu_dn[b % 4], pan=-0.22))
        add_clip(buf, bt + 0.75 * BEAT, pan_stereo(udu_up[b % 4], pan=0.24), gain=0.85)
        add_clip(buf, bt + 1.5 * BEAT, pan_stereo(udu_dn[(b + 1) % 4], pan=-0.18), gain=0.75)
        add_clip(buf, bt + 2.5 * BEAT, pan_stereo(udu_up[(b + 2) % 4], pan=0.22), gain=0.90)
        add_clip(buf, bt + 3.25 * BEAT, pan_stereo(udu_dn[(b + 3) % 4], pan=-0.25), gain=0.70)

        # Flint-knapping tool work on off-beats ("tink ... tink-tak")
        add_clip(buf, bt + 1.0 * BEAT, pan_stereo(flints[b % 6], pan=0.42), gain=0.78)
        add_clip(buf, bt + 2.0 * BEAT, pan_stereo(flints[(b + 1) % 6], pan=-0.38), gain=0.65)
        if b % 2 == 1:
            add_clip(buf, bt + 2.25 * BEAT, pan_stereo(flints[(b + 2) % 6], pan=-0.32), gain=0.52)
        add_clip(buf, bt + 3.5 * BEAT, pan_stereo(flints[(b + 3) % 6], pan=0.36), gain=0.70)

        # Close-up dry plucked hunting bow harmonic embellishments
        for step, nt in enumerate(["D4", "A4", "F4", "D4"]):
            bow_dry = synth_hunting_bow(n2f(nt), 0.75, vel=0.52, seed=1400 + b * 4 + step)
            add_clip(buf, bt + (step + 0.5) * BEAT, pan_stereo(bow_dry, pan=-0.30 if step % 2 == 0 else 0.30))

    # Keep Zoom-Close intentionally DRY (no canyon reverb) so zooming in feels right next to the hearth!
    return wrap_loop_boundaries(buf)


def build_stem_zoom_far(ir: np.ndarray) -> np.ndarray:
    """Stem 5: Camera Zoom-Out (Macro Continent View: High-Altitude Steppe Wind, Celestial Overtone Pad, Horizon Drone)."""
    rng = np.random.default_rng(3030)
    buf = np.zeros((N_EXT, 2), dtype=np.float64)
    t = np.arange(N_EXT, dtype=np.float64) / SR

    # 1. Sweeping High-Altitude Steppe Wind (dual resonant bandpass filters slowly sweeping across stereo)
    n_blocks = 96
    block_len = N_EXT // n_blocks
    noise_l = rng.standard_normal(N_EXT)
    noise_r = rng.standard_normal(N_EXT)
    wind_l = np.zeros(N_EXT, dtype=np.float64)
    wind_r = np.zeros(N_EXT, dtype=np.float64)
    for k in range(n_blocks):
        i0 = k * block_len
        i1 = N_EXT if k == n_blocks - 1 else (k + 1) * block_len
        phase_k = 2.0 * math.pi * k / n_blocks
        fc_l = 320.0 + 180.0 * math.sin(phase_k * 2.0)
        fc_r = 380.0 + 210.0 * math.cos(phase_k * 2.0 + 0.7)
        b_l, a_l = signal.iirpeak(fc_l / (0.5 * SR), Q=3.8)
        b_r, a_r = signal.iirpeak(fc_r / (0.5 * SR), Q=3.8)
        wind_l[i0:i1] = signal.lfilter(b_l, a_l, noise_l[i0:i1])
        wind_r[i0:i1] = signal.lfilter(b_r, a_r, noise_r[i0:i1])
    swell = 0.65 + 0.35 * np.sin(2.0 * math.pi * t / 8.0)
    buf[:, 0] += wind_l * swell * 0.055
    buf[:, 1] += wind_r * swell * 0.055

    # 2. Deep Earth Horizon Sub-Drone (D2 + A2 + D3 + A3 + F#4/F4 natural harmonic shimmer)
    horizon = (
        0.48 * np.sin(2.0 * math.pi * n2f("D2") * t)
        + 0.34 * np.sin(2.0 * math.pi * n2f("A2") * t + 0.5)
        + 0.26 * np.sin(2.0 * math.pi * n2f("D3") * t + 1.2) * (0.6 + 0.4 * np.sin(2.0 * math.pi * t / 6.4))
        + 0.18 * np.sin(2.0 * math.pi * n2f("A3") * t + 2.1) * (0.5 + 0.5 * np.cos(2.0 * math.pi * t / 9.6))
        + 0.12 * np.sin(2.0 * math.pi * n2f("D4") * t + 0.9) * (0.5 + 0.5 * np.sin(2.0 * math.pi * t / 12.8))
    )
    buf[:, 0] += horizon * 0.14
    buf[:, 1] += np.roll(horizon, int(0.014 * SR)) * 0.14

    # 3. Distant Vast Canyon Horn & Celestial Lithophone Harmonics (drenched in wide reverb)
    macro_notes = [
        (0.5, "D3", "A4"), (6.4, "A2", "D5"),
        (12.8, "D3", "A4"), (19.2, "G2", "D5"), (25.6, "A2", "E5"),
        (28.8, "D3", "F4"), (35.2, "G2", "A4"), (41.6, "A2", "D5"),
        (44.8, "D3", "A4"), (51.2, "G2", "C5"), (56.0, "A2", "D5"),
    ]
    for idx, (st, horn_nt, stone_nt) in enumerate(macro_notes):
        horn = synth_bone_horn(n2f(horn_nt), 4.5, vel=0.52, seed=1500 + idx)
        add_clip(buf, st, pan_stereo(horn, pan=-0.35 if idx % 2 == 0 else 0.35, haas_ms=11.0))
        stone = synth_lithophone(n2f(stone_nt), 3.2, vel=0.48, seed=1550 + idx)
        add_clip(buf, st + 1.6, pan_stereo(stone, pan=0.40 if idx % 2 == 0 else -0.40, haas_ms=-11.0))

    # Extra-wide canyon reverb on the macro view stem
    buf = apply_reverb(buf, ir, wet=0.68)
    return wrap_loop_boundaries(buf)


def main() -> None:
    print(f"Synthesizing Stone Age Interactive Suite ({TOTAL_DUR:.1f}s @ {SR} Hz Stereo)...")
    ir = make_canyon_ir(rt60=2.2, wet_highcut=3600.0, seed=42)

    stems = [
        ("stem_base_core.wav", build_stem_base_core(ir), -19.5),
        ("stem_pop_rhythm.wav", build_stem_pop_rhythm(ir), -20.5),
        ("stem_pop_chorus.wav", build_stem_pop_chorus(ir), -21.0),
        ("stem_zoom_close.wav", build_stem_zoom_close(), -21.5),
        ("stem_zoom_far.wav", build_stem_zoom_far(ir), -20.5),
    ]

    for filename, raw_audio, target_rms in stems:
        norm_audio, rms_db, peak_db = normalize_stem(raw_audio, target_rms_db=target_rms, peak_limit_db=-1.5)
        out_path = OUT_DIR / filename
        write_wav(out_path, norm_audio)
        print(f"  [OK] {filename:20s}  dur={norm_audio.shape[0]/SR:5.2f}s  RMS={rms_db:6.2f} dBFS  Peak={peak_db:6.2f} dBFS -> {out_path}")


if __name__ == "__main__":
    main()

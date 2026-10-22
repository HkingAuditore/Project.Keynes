"""Generate the Kingdom Age (王国时代) and Empire Age (帝国时代) interactive music suites + Era Advancement Transitions for FMOD.

1. KINGDOM AGE (王国时代, id="kingdom"):
   - Tempo/Grid: 85.714 BPM (1 beat = 0.70s, 1 bar = 2.80s, 19 bars = 53.20s total)
   - Tonality: C Yayue Royal Court Mode (C 雅乐宫调: C - D - E - F# - G - A - B)
   - Timeline:
     * [0.0s .. 11.2s]  (4 bars)  1. 刚进入游戏 (Intro: 《钟鸣鼎食 · 王都晨钟》)
     * [11.2s .. 25.2s] (5 bars)  2A. 常态循环 I:  《金石雅乐 · 朝堂议政》(Bianzhong, Jade Bianqing, Guqin & Court Sheng)
     * [25.2s .. 39.2s] (5 bars)  2B. 常态循环 II: 《驰道百工 · 市井通衢》(Ruan/Pipa Lute, Guzheng & Dongxiao)
     * [39.2s .. 53.2s] (5 bars)  2C. 常态循环 III:《竹简观星 · 哲思夜话》(Guqin Harmonics, Dongxiao & Jade Chimes)
   - Era Transition II (Agrarian -> Kingdom, 9.60s): `trans_agrarian_to_kingdom.wav` 《铸鼎立邦 · 礼乐初成》(G -> C V-I resolution)

2. EMPIRE AGE (帝国时代, id="empire"):
   - Tempo/Grid: 92.308 BPM (1 beat = 0.65s, 1 bar = 2.60s, 19 bars = 49.40s total)
   - Tonality: F Major / D Yanyue Grand Imperial Mode (盛世燕乐交响调式: F - G - A - Bb/B - C - D - E)
   - Timeline:
     * [0.0s .. 10.4s]  (4 bars)  1. 刚进入游戏 (Intro: 《九天阊阖 · 万国衣冠》)
     * [10.4s .. 23.4s] (5 bars)  2A. 常态循环 I:  《盛世长歌 · 京华万象》(Bowed Huqin/Strings Lead, Guzheng, Pipa & Sheng)
     * [23.4s .. 36.4s] (5 bars)  2B. 常态循环 II: 《丝路帆影 · 百工行会》(Virtuosic Pipa, Yunluo Cloud Gongs & Fangxiang)
     * [36.4s .. 49.4s] (5 bars)  2C. 常态循环 III:《太学书香 · 星海罗盘》(Low Strings/Cello, Dongxiao, Guzheng & Yunluo)
   - Era Transition III (Kingdom -> Empire, 9.60s): `trans_kingdom_to_empire.wav` 《四海一统 · 万邦来朝》(C -> F V-I resolution)
"""

from __future__ import annotations

import math
from pathlib import Path
import wave
import numpy as np
from scipy import signal

SR = 32000
ROOT = Path(__file__).resolve().parents[2]

KNG_OUT_DIR = ROOT.parent / "tmp" / "fmod_kingdom_age" / "audio"
KNG_REPO_DIR = ROOT / "Audio" / "ProjectKeynes" / "Assets" / "KingdomAge"

EMP_OUT_DIR = ROOT.parent / "tmp" / "fmod_empire_age" / "audio"
EMP_REPO_DIR = ROOT / "Audio" / "ProjectKeynes" / "Assets" / "EmpireAge"

NOTES = {
    "C1": 32.70, "F1": 43.65, "G1": 49.00, "A1": 55.00, "Bb1": 58.27,
    "C2": 65.41, "D2": 73.42, "E2": 82.41, "F2": 87.31, "F#2": 92.50, "G2": 98.00, "A2": 110.00, "Bb2": 116.54, "B2": 123.47,
    "C3": 130.81, "D3": 146.83, "E3": 164.81, "F3": 174.61, "F#3": 185.00, "G3": 196.00, "A3": 220.00, "Bb3": 233.08, "B3": 246.94,
    "C4": 261.63, "D4": 293.66, "E4": 329.63, "F4": 349.23, "F#4": 369.99, "G4": 392.00, "A4": 440.00, "Bb4": 466.16, "B4": 493.88,
    "C5": 523.25, "D5": 587.33, "E5": 659.25, "F5": 698.46, "F#5": 739.99, "G5": 783.99, "A5": 880.00, "Bb5": 932.33, "B5": 987.77,
    "C6": 1046.50, "D6": 1174.66, "E6": 1318.51, "F6": 1396.91,
}


def n2f(note: str) -> float:
    return NOTES[note]


def pan_stereo(mono: np.ndarray, pan: float = 0.0, haas_ms: float = 0.0) -> np.ndarray:
    angle = (pan + 1.0) * 0.25 * math.pi
    left = mono * math.cos(angle)
    right = mono * math.sin(angle)
    if abs(haas_ms) > 0.05:
        d = int(round(abs(haas_ms) * 0.001 * SR))
        if 0 < d < len(mono):
            if haas_ms > 0:
                right = np.pad(right[:-d], (d, 0))
            else:
                left = np.pad(left[:-d], (d, 0))
    return np.stack([left, right], axis=1)


def add_clip(buf: np.ndarray, start_s: float, clip_stereo: np.ndarray, gain: float = 1.0) -> None:
    i0 = int(round(start_s * SR))
    if i0 >= buf.shape[0] or i0 < 0:
        return
    n = min(clip_stereo.shape[0], buf.shape[0] - i0)
    if n > 0:
        buf[i0:i0 + n] += clip_stereo[:n] * gain


def make_hall_ir(rt60: float = 2.05, wet_highcut: float = 4800.0, seed: int = 202) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = int(round(rt60 * SR))
    t = np.arange(n, dtype=np.float64) / SR
    decay = np.exp(-6.9078 * t / rt60)
    env = 1.0 - np.exp(-t / 0.025)
    noise_l = rng.standard_normal(n) * decay * env
    noise_r = rng.standard_normal(n) * decay * env
    er_times = [0.014, 0.026, 0.041, 0.062, 0.089, 0.131, 0.184]
    er_gains = [0.44, 0.35, 0.28, 0.21, 0.15, 0.11, 0.07]
    for idx, (et, eg) in enumerate(zip(er_times, er_gains)):
        pos = int(round(et * SR))
        if pos < n:
            if idx % 2 == 0:
                noise_l[pos] += eg
                noise_r[min(n - 1, pos + 19)] += eg * 0.74
            else:
                noise_r[pos] += eg
                noise_l[min(n - 1, pos + 23)] += eg * 0.74
    sos = signal.butter(2, [110.0 / (0.5 * SR), wet_highcut / (0.5 * SR)], btype="bandpass", output="sos")
    ir_l = signal.sosfilt(sos, noise_l)
    ir_r = signal.sosfilt(sos, noise_r)
    norm = max(np.max(np.abs(ir_l)), np.max(np.abs(ir_r)), 1e-6)
    return np.stack([ir_l / norm, ir_r / norm], axis=1)


def apply_reverb(stereo: np.ndarray, ir: np.ndarray, wet: float = 0.26) -> np.ndarray:
    if wet <= 0.001:
        return stereo
    n = stereo.shape[0]
    rev_l = signal.fftconvolve(stereo[:, 0], ir[:, 0])[:n]
    rev_r = signal.fftconvolve(stereo[:, 1], ir[:, 1])[:n]
    rev = np.stack([rev_l, rev_r], axis=1)
    return stereo * (1.0 - 0.32 * wet) + rev * (wet * 0.18)


# ==============================================================================
# Shared Physical Modeling Instruments (Kingdom & Empire Eras)
# ==============================================================================

def synth_bianzhong(freq: float, dur: float = 3.2, vel: float = 0.80, is_bo_bass: bool = False, seed: int = 31) -> np.ndarray:
    """Zeng-Hou-Yi style Bronze Bianzhong (青铜编钟 / 镈钟): dual-pitch almond bronze bell modal synthesis."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR

    if is_bo_bass:
        modes = [1.000, 1.498, 2.000, 2.828, 3.650]
        amps = [1.00, 0.55, 0.68, 0.28, 0.14]
        decays = [dur * 0.85, dur * 0.65, dur * 0.55, dur * 0.35, dur * 0.20]
    else:
        modes = [1.000, 1.189, 1.996, 2.775, 3.880, 5.190]
        amps = [1.00, 0.52, 0.65, 0.32, 0.18, 0.10]
        decays = [dur * 0.78, dur * 0.60, dur * 0.48, dur * 0.30, dur * 0.18, dur * 0.10]

    sig = np.zeros(n, dtype=np.float64)
    for idx, (r, a, tau) in enumerate(zip(modes, amps, decays)):
        fm = freq * r
        if fm < SR * 0.45:
            beat = 1.0 + 0.09 * np.sin(2.0 * math.pi * (1.5 + 0.6 * idx) * t)
            sig += a * np.exp(-t / max(tau, 0.05)) * beat * np.sin(2.0 * math.pi * fm * t + rng.uniform(0, 0.4))

    mallet = signal.sosfilt(
        signal.butter(2, [500.0 / (0.5 * SR), 4600.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.0038) * (0.22 if is_bo_bass else 0.30)

    att = 1.0 - np.exp(-t / (0.0028 if is_bo_bass else 0.0016))
    return (sig * att + mallet) * vel * 0.24


def synth_jade_bianqing(freq: float, dur: float = 1.9, vel: float = 0.74, seed: int = 32) -> np.ndarray:
    """Royal Jade / Limestone Bianqing (玉石编磬): crystalline L-shaped chime bar."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    modes = [1.000, 2.382, 4.105, 6.180]
    amps = [1.00, 0.46, 0.22, 0.09]
    decays = [dur * 0.68, dur * 0.36, dur * 0.18, dur * 0.08]
    sig = np.zeros(n, dtype=np.float64)
    for r, a, tau in zip(modes, amps, decays):
        if freq * r < SR * 0.45:
            sig += a * np.exp(-t / max(tau, 0.04)) * np.sin(2.0 * math.pi * freq * r * t + rng.uniform(0, 0.3))
    click = signal.sosfilt(
        signal.butter(2, [1200.0 / (0.5 * SR), 6200.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.0020) * 0.26
    return (sig * (1.0 - np.exp(-t / 0.0014)) + click) * vel * 0.22


def synth_guqin(
    freq: float,
    dur: float = 2.4,
    vel: float = 0.78,
    harmonic: bool = False,
    slide_from: float | None = None,
    seed: int = 33,
) -> np.ndarray:
    """Seven-String Guqin & Gu-Se (七弦古琴/古瑟): deep lacquered wood resonance, silk strings & pitch slide."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    f0 = freq * (2.0 if harmonic else 1.0)
    if slide_from is not None:
        f_curve = f0 + (slide_from - f0) * np.exp(-t / 0.085)
    else:
        f_curve = f0 * (1.0 + 0.003 * np.sin(2.0 * math.pi * 4.2 * t) * np.clip((t - 0.15) / 0.25, 0.0, 1.0))
    phase = 2.0 * math.pi * np.cumsum(f_curve) / SR

    sig = np.zeros(n, dtype=np.float64)
    max_k = 5 if harmonic else 12
    for k in range(1, max_k + 1):
        if f0 * k >= SR * 0.44:
            break
        amp = (1.0 / (k ** (1.50 if harmonic else 1.22)))
        tau = (dur * 0.78) / (1.0 + 0.30 * (k - 1))
        sig += amp * np.exp(-t / max(tau, 0.05)) * np.sin(k * phase + rng.uniform(0, 0.3))

    pluck = signal.sosfilt(
        signal.butter(2, [280.0 / (0.5 * SR), 2600.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.005) * (0.12 if harmonic else 0.22)
    out = (sig * (1.0 - np.exp(-t / 0.0035)) + pluck) * vel * 0.27
    b1, a1 = signal.iirpeak(195.0 / (0.5 * SR), Q=3.4)
    b2, a2 = signal.iirpeak(480.0 / (0.5 * SR), Q=4.0)
    return out * 0.80 + 0.12 * signal.lfilter(b1, a1, out) + 0.08 * signal.lfilter(b2, a2, out)


def synth_pipa_ruan(
    freq: float,
    dur: float = 1.5,
    vel: float = 0.78,
    tremolo: bool = False,
    seed: int = 34,
) -> np.ndarray:
    """Plucked Pipa & Ruan Lute (琵琶/中阮): crisp plectrum attack, bright wooden soundboard & optional tremolando (轮指)."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR

    if not tremolo:
        strike_times = [0.0]
        strike_vels = [1.0]
    else:
        # Expressive 5-finger Pipa lunzhi (轮指) roll
        step = 0.058
        n_roll = max(2, int((dur * 0.78) / step))
        strike_times = [i * step for i in range(n_roll)]
        strike_vels = [0.65 + 0.30 * math.sin(math.pi * i / max(1, n_roll - 1)) for i in range(n_roll)]

    out = np.zeros(n, dtype=np.float64)
    for s_idx, (st, sv) in enumerate(zip(strike_times, strike_vels)):
        i0 = int(round(st * SR))
        if i0 >= n:
            continue
        rem = n - i0
        ts = np.arange(rem, dtype=np.float64) / SR
        p_note = np.zeros(rem, dtype=np.float64)
        for k in range(1, 15):
            if freq * k >= SR * 0.45:
                break
            # Pipa has strong odd & upper-mid partials
            w = (1.0 / (k ** 1.05)) * (1.15 if k in (2, 3, 4) else 0.9)
            tau = 0.55 / (1.0 + 0.32 * (k - 1))
            det = math.sqrt(1.0 + 0.00025 * (k ** 2))
            p_note += w * np.exp(-ts / max(tau, 0.03)) * np.sin(2.0 * math.pi * freq * k * det * ts + 0.2 * k)
        pick = signal.sosfilt(
            signal.butter(2, [700.0 / (0.5 * SR), 4800.0 / (0.5 * SR)], btype="bandpass", output="sos"),
            rng.standard_normal(rem),
        ) * np.exp(-ts / 0.0030) * 0.28
        out[i0:] += (p_note * (1.0 - np.exp(-ts / 0.0018)) + pick) * sv

    b_body, a_body = signal.iirpeak(420.0 / (0.5 * SR), Q=3.6)
    b_top, a_top = signal.iirpeak(1650.0 / (0.5 * SR), Q=4.2)
    out = out * 0.78 + 0.14 * signal.lfilter(b_body, a_body, out) + 0.08 * signal.lfilter(b_top, a_top, out)
    return out * vel * (0.18 if tremolo else 0.24)


def synth_court_sheng(freq: float, dur: float, vel: float = 0.74, fifth_chord: bool = True, seed: int = 35) -> np.ndarray:
    """36-Reed Court Sheng (宫廷排笙): warm bronze free-reed mouth organ with fifth + octave harmonic coupling."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.22) * SR))
    t = np.arange(n, dtype=np.float64) / SR
    att_n = max(1, int(round(0.075 * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.4
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.14 * SR))

    ratios = [1.0, 1.4983, 2.0] if fifth_chord else [1.0, 2.0]
    weights = [1.0, 0.68, 0.42] if fifth_chord else [1.0, 0.45]
    sig = np.zeros(n, dtype=np.float64)
    for r, w in zip(ratios, weights):
        fn = freq * r
        vib = 0.0035 * np.sin(2.0 * math.pi * 5.0 * t + rng.uniform(0, 6.28))
        p = 2.0 * math.pi * np.cumsum(fn * (1.0 + vib)) / SR
        for k, hk in enumerate([1.0, 0.58, 0.36, 0.20, 0.11, 0.06], start=1):
            if fn * k < SR * 0.44:
                sig += w * hk * np.sin(k * p + 0.3 * k)
    return sig * env * vel * 0.16


def synth_dongxiao(
    freq: float,
    dur: float,
    vel: float = 0.80,
    grace_from: float | None = None,
    bright_dizi: bool = False,
    seed: int = 36,
) -> np.ndarray:
    """Dongxiao / Court Dizi (洞箫 / 雅笛): expressive bamboo wind instrument."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.18) * SR))
    t = np.arange(n, dtype=np.float64) / SR
    att_n = max(1, int(round((0.050 if bright_dizi else 0.075) * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.4
    env *= 0.86 + 0.14 * np.sin(math.pi * np.clip(t / max(dur, 0.1), 0.0, 1.0))
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.14 * SR))

    if grace_from is not None:
        f_curve = freq + (grace_from - freq) * np.exp(-t / 0.040)
    else:
        f_curve = freq * (1.0 - 0.011 * np.exp(-t / 0.025))
    vib = 0.007 * np.clip((t - 0.20) / 0.22, 0.0, 1.0) * np.sin(2.0 * math.pi * 5.2 * t + rng.uniform(0, 6.28))
    phase = 2.0 * math.pi * np.cumsum(f_curve * (1.0 + vib)) / SR

    if bright_dizi:
        tone = np.sin(phase) + 0.60 * np.sin(2 * phase + 0.2) + 0.40 * np.sin(3 * phase + 0.8) + 0.20 * np.sin(4 * phase)
    else:
        tone = np.sin(phase) + 0.34 * np.sin(2 * phase + 0.3) + 0.26 * np.sin(3 * phase + 0.9) + 0.09 * np.sin(4 * phase)

    air = signal.sosfilt(
        signal.butter(2, [450.0 / (0.5 * SR), 3200.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * (0.28 * np.exp(-t / 0.028) + 0.09 * env)
    return (tone * 0.82 + air * 0.20) * env * vel * 0.28


def synth_bowed_strings(
    freq: float,
    dur: float,
    vel: float = 0.84,
    slide_from: float | None = None,
    ensemble_size: int = 3,
    seed: int = 37,
) -> np.ndarray:
    """Bowed Huqin / Imperial String Section (盛世胡琴 / 帝国弦乐群): rich sustained bowed string with portamento & vibrato."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.28) * SR))
    t = np.arange(n, dtype=np.float64) / SR

    att_n = max(1, int(round(0.11 * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.5
    # Expressive bow swell in middle of note
    env *= 0.82 + 0.18 * np.sin(math.pi * np.clip(t / max(dur, 0.12), 0.0, 1.0))
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.18 * SR))

    if slide_from is not None:
        f_base = freq + (slide_from - freq) * np.exp(-t / 0.065)
    else:
        f_base = freq * (1.0 - 0.008 * np.exp(-t / 0.030))

    sig = np.zeros(n, dtype=np.float64)
    detunes = [1.0] if ensemble_size <= 1 else np.linspace(0.9972, 1.0028, ensemble_size)
    for v_i, det in enumerate(detunes):
        vib_rate = 5.3 + 0.25 * v_i
        vib_onset = np.clip((t - 0.14) / 0.22, 0.0, 1.0)
        vib = 0.0085 * vib_onset * np.sin(2.0 * math.pi * vib_rate * t + rng.uniform(0, 6.28))
        p = 2.0 * math.pi * np.cumsum(f_base * det * (1.0 + vib)) / SR
        # Bowed string Helmholtz sawtooth-like harmonic series with warm upper roll-off
        for k in range(1, 14):
            if freq * k >= SR * 0.44:
                break
            amp = (1.0 / (k ** 1.08)) * (0.75 + 0.25 * env)
            sig += (amp / len(detunes)) * np.sin(k * p + rng.uniform(0, 6.28))

    # Resonant wooden/python-skin body peaks (520 Hz, 1180 Hz, 2450 Hz)
    out = sig * 0.65
    for f_res, q_res, g_res in [(520.0, 3.5, 0.22), (1180.0, 4.2, 0.25), (2450.0, 5.0, 0.14)]:
        b, a = signal.iirpeak(f_res / (0.5 * SR), Q=q_res)
        out += g_res * signal.lfilter(b, a, sig)

    return out * env * vel * 0.26


def synth_yunluo_fangxiang(freq: float, dur: float = 1.6, vel: float = 0.74, seed: int = 38) -> np.ndarray:
    """Ten-Gong Cloud Chimes & Iron Fangxiang (十面云锣 / 铁方响): shimmering tuned court metallophone."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    modes = [1.000, 2.002, 3.140, 4.580]
    amps = [1.00, 0.58, 0.26, 0.12]
    decays = [dur * 0.75, dur * 0.50, dur * 0.28, dur * 0.14]
    sig = np.zeros(n, dtype=np.float64)
    for r, a, tau in zip(modes, amps, decays):
        if freq * r < SR * 0.45:
            shimmer = 1.0 + 0.10 * np.sin(2.0 * math.pi * 6.2 * t)
            sig += a * np.exp(-t / max(tau, 0.04)) * shimmer * np.sin(2.0 * math.pi * freq * r * t + rng.uniform(0, 0.4))
    return sig * (1.0 - np.exp(-t / 0.0015)) * vel * 0.22


def synth_imperial_horn(freq: float, dur: float, vel: float = 0.84, seed: int = 39) -> np.ndarray:
    """Royal / Imperial Bronze Horn & Brass Ensemble (青铜大角 / 帝国礼乐铜管)."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.35) * SR))
    t = np.arange(n, dtype=np.float64) / SR
    att_n = max(1, int(round(0.09 * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.5
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.18 * SR))

    f_inst = freq * (1.0 - 0.012 * np.exp(-t / 0.05) + 0.003 * np.sin(2.0 * math.pi * 4.5 * t))
    phase = 2.0 * math.pi * np.cumsum(f_inst) / SR
    sig = np.zeros(n, dtype=np.float64)
    for k, w in enumerate([1.0, 0.90, 0.72, 0.52, 0.34, 0.20, 0.11, 0.06], start=1):
        if freq * k < SR * 0.44:
            sig += w * (env ** (1.0 + 0.22 * (k - 1))) * np.sin(k * phase + 0.15 * k)
    sig = signal.sosfilt(signal.butter(2, 2800.0 / (0.5 * SR), btype="lowpass", output="sos"), sig)
    return sig * env * vel * 0.24


def synth_court_drum(freq: float = 58.0, dur: float = 0.58, vel: float = 0.88, rim_wood: bool = False, seed: int = 40) -> np.ndarray:
    """Pillar Court Drum / Imperial Da-Gu (建鼓 / 帝国大堂鼓) & Wooden Zhu/Ban Clapper."""
    rng = np.random.default_rng(seed)
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    if rim_wood:
        tone = np.sin(2.0 * math.pi * 760.0 * t) * np.exp(-t / 0.025) + 0.5 * np.sin(2.0 * math.pi * 1320.0 * t) * np.exp(-t / 0.015)
        click = signal.sosfilt(
            signal.butter(2, [1000.0 / (0.5 * SR), 4800.0 / (0.5 * SR)], btype="bandpass", output="sos"),
            rng.standard_normal(n),
        ) * np.exp(-t / 0.005) * 0.42
        return (tone * 0.7 + click) * vel * 0.22

    f_inst = freq * (1.0 + 0.52 * np.exp(-t / 0.028))
    phase = 2.0 * math.pi * np.cumsum(f_inst) / SR
    sub = np.sin(phase) * np.exp(-t / 0.24)
    over = 0.38 * np.sin(1.62 * phase + 0.3) * np.exp(-t / 0.12)
    attack = signal.sosfilt(
        signal.butter(2, [80.0 / (0.5 * SR), 700.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n),
    ) * np.exp(-t / 0.014) * 0.34
    return (sub + over + attack) * vel * 0.38


def synth_grand_choir(freq: float, dur: float, vel: float = 0.78, bright_imperial: bool = False, seed: int = 41) -> np.ndarray:
    """Royal / Imperial Mixed Choir (太庙礼乐合唱 / 万邦交响圣咏)."""
    rng = np.random.default_rng(seed)
    n = int(round((dur + 0.45) * SR))
    t = np.arange(n, dtype=np.float64) / SR
    att_n = max(1, int(round(0.30 * SR)))
    env = np.ones(n, dtype=np.float64)
    env[:att_n] = np.sin(0.5 * math.pi * np.linspace(0.0, 1.0, att_n)) ** 1.5
    rel_start = int(round(dur * SR))
    for i in range(rel_start, n):
        env[i] *= math.exp(-(i - rel_start) / (0.28 * SR))

    glottal = np.zeros(n, dtype=np.float64)
    for vr, vw in [(1.0, 0.65), (1.003, 0.55), (1.997, 0.48), (2.004, 0.42)]:
        vib = 0.0045 * np.sin(2.0 * math.pi * rng.uniform(4.7, 5.5) * t + rng.uniform(0, 6.28))
        p = 2.0 * math.pi * np.cumsum(freq * vr * (1.0 + vib)) / SR
        for k in range(1, 13):
            if freq * vr * k < SR * 0.44:
                glottal += (vw / (k ** 1.12)) * np.sin(k * p + rng.uniform(0, 6.28))

    formants = [(720.0, 4.5, 1.0), (1240.0, 5.2, 0.70), (2750.0, 6.0, 0.34)] if bright_imperial else [(620.0, 4.5, 1.0), (1080.0, 5.2, 0.62), (2550.0, 6.0, 0.26)]
    out = np.zeros(n, dtype=np.float64)
    for ff, qq, gg in formants:
        b, a = signal.iirpeak(ff / (0.5 * SR), Q=qq)
        out += gg * signal.lfilter(b, a, glottal)
    return out * env * vel * 0.14


# ==============================================================================
# PART I: KINGDOM AGE (王国时代, 85.71 BPM, 1 bar = 2.80s, 53.20s total, C Yayue)
# ==============================================================================

KNG_BEAT = 0.70
KNG_BAR = 2.80
KNG_TOTAL_BARS = 19
KNG_DUR = KNG_TOTAL_BARS * KNG_BAR  # 53.20s
KNG_SAMPLES = int(round(KNG_DUR * SR))
KNG_EXT = KNG_SAMPLES + int(round(2.4 * SR))


def render_kingdom_base_core(ir: np.ndarray) -> np.ndarray:
    buf = np.zeros((KNG_EXT, 2), dtype=np.float64)

    # 1. INTRO [0.0s .. 11.2s] (4 bars): 《钟鸣鼎食 · 王都晨钟》
    # Deep Bo-Bell + Bianzhong & Jade Bianqing + Court Sheng + Guqin
    for t0, nn, is_bo, pan in [
        (0.05, "C3", True, -0.15),
        (1.40, "G3", True, 0.20),
        (2.80, "C4", False, -0.30),
        (3.50, "D4", False, 0.25),
        (4.20, "E4", False, -0.25),
        (4.90, "F#4", False, 0.30),
        (5.60, "G4", False, 0.00),
        (7.00, "E4", False, -0.20),
        (8.40, "G3", True, 0.15),
    ]:
        bz = synth_bianzhong(n2f(nn), dur=3.4, vel=0.84, is_bo_bass=is_bo, seed=4000 + int(t0 * 100))
        add_clip(buf, t0, pan_stereo(bz, pan=pan, haas_ms=4.5), 0.90)

    for idx, (t0, nn, pan) in enumerate([(0.70, "G4", 0.32), (2.10, "A4", -0.32), (6.30, "B4", 0.28), (7.70, "A4", -0.28), (9.80, "G4", 0.25)]):
        jq = synth_jade_bianqing(n2f(nn), dur=2.0, vel=0.76, seed=4100 + idx)
        add_clip(buf, t0, pan_stereo(jq, pan=pan), 0.85)

    for idx, (t0, nn, dur) in enumerate([(0.35, "C3", 5.0), (5.60, "G3", 5.2)]):
        sh = synth_court_sheng(n2f(nn), dur=dur, vel=0.74, fifth_chord=True, seed=4150 + idx)
        add_clip(buf, t0, pan_stereo(sh, pan=-0.25 if idx == 0 else 0.25, haas_ms=5.0), 0.84)

    for idx, (t0, nn, sl) in enumerate([(5.60, "G3", "E3"), (7.00, "A3", "G3"), (8.40, "B3", "A3"), (9.80, "G3", None)]):
        gq = synth_guqin(n2f(nn), dur=2.2, vel=0.80, slide_from=n2f(sl) if sl else None, seed=4180 + idx)
        add_clip(buf, t0, pan_stereo(gq, pan=0.15), 0.88)

    # 2A. LOOP A [11.2s .. 25.2s] (5 bars): 《金石雅乐 · 朝堂议政》
    # Stately Bianzhong & Jade Bianqing melody in C Yayue (C - D - E - F# - G - A - B) + Guqin & Sheng
    a_t0 = 11.2
    a_melody = [
        (0.00, "C4", 1.35, "G3", True),
        (1.40, "D4", 0.68, None, False),
        (2.10, "E4", 0.68, None, True),
        (2.80, "G4", 1.35, "E4", True),
        (4.20, "F#4", 0.68, None, False),
        (4.90, "E4", 0.68, None, True),
        (5.60, "A4", 1.35, "G4", True),
        (7.00, "G4", 0.68, None, False),
        (7.70, "E4", 0.68, None, True),
        (8.40, "D4", 1.35, "E4", True),
        (9.80, "E4", 0.68, None, False),
        (10.50, "G4", 0.68, None, True),
        (11.20, "C4", 2.00, "D4", True),
        (13.30, "G3", 0.68, None, False),
    ]
    for idx, (off, nn, dur, gr, use_bell) in enumerate(a_melody):
        t0 = a_t0 + off
        if use_bell:
            bz = synth_bianzhong(n2f(nn), dur=2.8, vel=0.80, seed=4200 + idx)
            add_clip(buf, t0, pan_stereo(bz, pan=-0.22 if idx % 2 == 0 else 0.22, haas_ms=4.0), 0.86)
        else:
            jq = synth_jade_bianqing(n2f(nn), dur=1.8, vel=0.76, seed=4250 + idx)
            add_clip(buf, t0, pan_stereo(jq, pan=0.28 if idx % 2 == 0 else -0.28), 0.84)
        dx = synth_dongxiao(n2f(nn), dur=dur, vel=0.76, grace_from=n2f(gr) if gr else None, bright_dizi=False, seed=4300 + idx)
        add_clip(buf, t0, pan_stereo(dx, pan=-0.08), 0.86)

    a_roots = ["C2", "G2", "A2", "D2", "G2"]
    for b_i, rn in enumerate(a_roots):
        bt = a_t0 + b_i * KNG_BAR
        sh = synth_court_sheng(n2f(rn) * 2.0, dur=2.5, vel=0.68, fifth_chord=True, seed=4350 + b_i)
        add_clip(buf, bt, pan_stereo(sh, pan=0.25 if b_i % 2 == 0 else -0.25, haas_ms=5.0), 0.78)
        for s_i, mult in enumerate([1.0, 1.5, 2.0, 1.5]):
            gq = synth_guqin(n2f(rn) * mult, dur=1.8, vel=0.72, seed=4380 + b_i * 4 + s_i)
            add_clip(buf, bt + s_i * KNG_BEAT, pan_stereo(gq, pan=-0.18 if s_i % 2 == 0 else 0.18), 0.82)

    # 2B. LOOP B [25.2s .. 39.2s] (5 bars): 《驰道百工 · 市井通衢》
    # Ruan/Pipa Lute rhythmic counterpoint + Dongxiao melody + Jade Bianqing
    b_t0 = 25.2
    b_chords = [
        ["C3", "G3", "C4", "E4", "G4", "E4", "C4", "G3"],
        ["A2", "E3", "A3", "C4", "E4", "C4", "A3", "E3"],
        ["D3", "A3", "D4", "F#4", "A4", "F#4", "D4", "A3"],
        ["E3", "B3", "E4", "G4", "B4", "G4", "E4", "B3"],
        ["C3", "G3", "C4", "D4", "E4", "G4", "D4", "G3"],
    ]
    for b_i, notes in enumerate(b_chords):
        bt = b_t0 + b_i * KNG_BAR
        for s_i, nn in enumerate(notes):
            nt = bt + s_i * (KNG_BEAT * 0.5)
            plk = synth_pipa_ruan(n2f(nn), dur=1.3, vel=0.76 if s_i in (0, 4) else 0.62, tremolo=False, seed=4400 + b_i * 10 + s_i)
            add_clip(buf, nt, pan_stereo(plk, pan=0.26 if s_i % 2 == 0 else -0.24, haas_ms=3.0), 0.86)

    b_xiao = [
        (0.00, "E4", 1.00, "D4"), (1.05, "G4", 0.35, None), (1.40, "A4", 1.30, "G4"),
        (2.80, "E4", 1.30, "G4"), (4.20, "D4", 0.68, None), (4.90, "C4", 0.68, None),
        (5.60, "D4", 1.00, "C4"), (6.65, "F#4", 0.35, None), (7.00, "A4", 1.30, "F#4"),
        (8.40, "G4", 1.30, "A4"), (9.80, "E4", 0.68, None), (10.50, "D4", 0.68, None),
        (11.20, "C4", 2.00, "D4"), (13.30, "D4", 0.65, None),
    ]
    for idx, (off, nn, dur, gr) in enumerate(b_xiao):
        dx = synth_dongxiao(n2f(nn), dur=dur, vel=0.84, grace_from=n2f(gr) if gr else None, bright_dizi=True, seed=4500 + idx)
        add_clip(buf, b_t0 + off, pan_stereo(dx, pan=-0.12, haas_ms=2.5), 0.90)

    # 2C. LOOP C [39.2s .. 53.2s] (5 bars): 《竹简观星 · 哲思夜话》
    # Guqin harmonics & deep slides + contemplative Dongxiao + Bronze/Jade chimes
    c_t0 = 39.2
    c_guqin = [
        (0.00, "C3", False, "A2"), (0.70, "G3", True, None), (1.40, "C4", True, None), (2.10, "E4", False, "D4"),
        (2.80, "A2", False, None), (3.50, "E3", True, None), (4.20, "A3", True, None), (4.90, "C4", False, "B3"),
        (5.60, "D3", False, "C3"), (6.30, "A3", True, None), (7.00, "D4", True, None), (7.70, "F#4", True, None),
        (8.40, "G2", False, None), (9.10, "D3", True, None), (9.80, "G3", True, None), (10.50, "B3", False, "A3"),
        (11.20, "C3", False, "D3"), (11.90, "G3", True, None), (12.60, "C4", True, None), (13.30, "G3", False, None),
    ]
    for idx, (off, nn, is_h, sl) in enumerate(c_guqin):
        gq = synth_guqin(n2f(nn), dur=2.2, vel=0.80, harmonic=is_h, slide_from=n2f(sl) if sl else None, seed=4600 + idx)
        add_clip(buf, c_t0 + off, pan_stereo(gq, pan=-0.22 if idx % 2 == 0 else 0.22, haas_ms=3.5), 0.90)

    c_xiao = [
        (0.70, "G4", 1.90, "E4"),
        (3.50, "E4", 1.90, "G4"),
        (6.30, "F#4", 1.35, "E4"), (7.70, "A4", 0.68, None),
        (8.40, "G4", 2.00, "A4"),
        (11.20, "E4", 1.90, "D4"), (13.30, "D4", 0.65, None),
    ]
    for idx, (off, nn, dur, gr) in enumerate(c_xiao):
        dx = synth_dongxiao(n2f(nn), dur=dur, vel=0.82, grace_from=n2f(gr) if gr else None, bright_dizi=False, seed=4700 + idx)
        add_clip(buf, c_t0 + off, pan_stereo(dx, pan=0.18, haas_ms=3.0), 0.88)

    for b_i, nn in enumerate(["C4", "E4", "A4", "G4", "C5"]):
        jq = synth_jade_bianqing(n2f(nn), dur=2.2, vel=0.72, seed=4750 + b_i)
        add_clip(buf, c_t0 + b_i * KNG_BAR, pan_stereo(jq, pan=-0.30 if b_i % 2 == 0 else 0.30), 0.80)

    return apply_reverb(buf, ir, wet=0.28)


def render_kingdom_pop_rhythm(ir: np.ndarray) -> np.ndarray:
    """Kingdom Track 2 Pop_Rhythm (Tier 1 >=1500 pop): Pillar Court Drum (建鼓), Bronze Chunyu, Wooden Zhu & Ruan Bass."""
    buf = np.zeros((KNG_EXT, 2), dtype=np.float64)
    for bar_idx in range(KNG_TOTAL_BARS + 1):
        bt = bar_idx * KNG_BAR
        in_intro = bar_idx < 4
        if in_intro and bar_idx < 2:
            continue
        gain = 0.50 if in_intro else 0.95
        # Stately Court March Drum pattern
        for h_i, (b_off, df, dv, is_w) in enumerate([
            (0.0, 56.0, 0.88, False),
            (1.0, 90.0, 0.58, True),
            (1.5, 60.0, 0.65, False),
            (2.0, 58.0, 0.80, False),
            (3.0, 92.0, 0.64, True),
            (3.5, 62.0, 0.58, False),
        ]):
            d = synth_court_drum(freq=df, dur=0.50, vel=dv * gain, rim_wood=is_w, seed=5000 + bar_idx * 10 + h_i)
            add_clip(buf, bt + b_off * KNG_BEAT, pan_stereo(d, pan=-0.10 if not is_w else 0.25), 0.90)

        if not in_intro:
            sec_b = (bar_idx - 4) % 5
            roots = ["C2", "A2", "D2", "G2", "C2"]
            fifths = ["G2", "E3", "A2", "D3", "G2"]
            for p_i, (b_off, nn, pv) in enumerate([
                (0.0, roots[sec_b], 0.80),
                (1.0, fifths[sec_b], 0.66),
                (2.0, roots[sec_b], 0.74),
                (3.0, fifths[sec_b], 0.68),
            ]):
                plk = synth_pipa_ruan(n2f(nn), dur=1.0, vel=pv, seed=5200 + bar_idx * 10 + p_i)
                add_clip(buf, bt + b_off * KNG_BEAT, pan_stereo(plk, pan=0.14), 0.84)

    return apply_reverb(buf, ir, wet=0.20)


def render_kingdom_pop_chorus(ir: np.ndarray) -> np.ndarray:
    """Kingdom Track 3 Pop_Chorus (Tier 2 >=4000 pop): Royal Temple Choir, Ceremonial Bronze Horns & Upper Bianzhong."""
    buf = np.zeros((KNG_EXT, 2), dtype=np.float64)
    for t0, nn, pan in [(5.6, "C3", -0.35), (5.6, "G3", 0.35)]:
        ch = synth_grand_choir(n2f(nn), dur=5.2, vel=0.74, bright_imperial=False, seed=5400 + int(t0 * 10))
        add_clip(buf, t0, pan_stereo(ch, pan=pan, haas_ms=6.0), 0.88)

    for sec_idx in range(3):
        st0 = 11.2 + sec_idx * 14.0
        prog = [
            ("C3", "G3", "E4"),
            ("A2", "E3", "C4"),
            ("D3", "A3", "F#4"),
            ("E3", "B3", "G4"),
            ("C3", "G3", "D4"),
        ]
        for b_i, (nl, nm, nh) in enumerate(prog):
            bt = st0 + b_i * KNG_BAR
            ch1 = synth_grand_choir(n2f(nl), dur=2.65, vel=0.76, bright_imperial=False, seed=5500 + sec_idx * 30 + b_i)
            ch2 = synth_grand_choir(n2f(nm), dur=2.65, vel=0.72, bright_imperial=False, seed=5501 + sec_idx * 30 + b_i)
            add_clip(buf, bt, pan_stereo(ch1, pan=-0.40, haas_ms=6.0), 0.86)
            add_clip(buf, bt, pan_stereo(ch2, pan=0.40, haas_ms=6.0), 0.84)

            if b_i in (0, 2, 4):
                hrn = synth_imperial_horn(n2f(nm), dur=2.3, vel=0.70, seed=5600 + sec_idx * 30 + b_i)
                add_clip(buf, bt, pan_stereo(hrn, pan=0.22 if b_i == 0 else -0.22, haas_ms=4.5), 0.78)
                bz = synth_bianzhong(n2f(nh), dur=2.8, vel=0.76, seed=5700 + sec_idx * 30 + b_i)
                add_clip(buf, bt + KNG_BEAT, pan_stereo(bz, pan=0.30), 0.82)

    return apply_reverb(buf, ir, wet=0.34)


def render_kingdom_zoom_close(ir: np.ndarray) -> np.ndarray:
    """Kingdom Track 4 Zoom_Close: Iron-Smelting Forge Anvil, Stone Masonry Chiseling & Market Bronze Coins."""
    buf = np.zeros((KNG_EXT, 2), dtype=np.float64)
    rng = np.random.default_rng(5800)

    # Subtle town hearth/forge draft murmur
    n_tot = KNG_EXT
    t_full = np.arange(n_tot, dtype=np.float64) / SR
    murmur = signal.sosfilt(
        signal.butter(2, [180.0 / (0.5 * SR), 1200.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n_tot),
    ) * (0.015 + 0.006 * np.sin(2.0 * math.pi * 0.35 * t_full))
    buf[:, 0] += murmur
    buf[:, 1] += murmur * 0.95

    for bar_idx in range(KNG_TOTAL_BARS + 1):
        bt = bar_idx * KNG_BAR
        # 1. Iron Forge Hammer on Anvil (冶铁锻造铁砧声: metallic high-Q ping + hammer thud on beat 0.5 & 2.5)
        for h_i, b_off in enumerate([0.5, 2.5]):
            t0 = bt + b_off * KNG_BEAT
            na = int(round(0.32 * SR))
            ta = np.arange(na, dtype=np.float64) / SR
            f_anvil = 1380.0 if h_i == 0 else 1540.0
            anvil = (
                np.sin(2.0 * math.pi * f_anvil * ta) * np.exp(-ta / 0.045)
                + 0.55 * np.sin(2.0 * math.pi * f_anvil * 1.74 * ta) * np.exp(-ta / 0.024)
                + 0.30 * np.sin(2.0 * math.pi * 240.0 * ta) * np.exp(-ta / 0.018)
            ) * 0.095
            add_clip(buf, t0, pan_stereo(anvil, pan=-0.38 if h_i == 0 else -0.25, haas_ms=2.5), 1.0)

        # 2. Stone Masonry Chisel tap (石工凿石筑城声 on beat 1.5 & 3.25)
        for c_i, b_off in enumerate([1.5, 3.25]):
            t0 = bt + b_off * KNG_BEAT
            nc = int(round(0.12 * SR))
            tc = np.arange(nc, dtype=np.float64) / SR
            chisel = signal.sosfilt(
                signal.butter(2, [1600.0 / (0.5 * SR), 5800.0 / (0.5 * SR)], btype="bandpass", output="sos"),
                rng.standard_normal(nc),
            ) * np.exp(-tc / 0.008) * 0.11
            add_clip(buf, t0, pan_stereo(chisel, pan=0.35), 1.0)

        # 3. Market Bronze Coin Jingle (市井铜钱清脆碰撞声 every 2 bars on beat 3.5)
        if bar_idx % 2 == 0:
            coin_t0 = bt + 3.5 * KNG_BEAT
            for k_i, cf in enumerate([3120.0, 3860.0, 4420.0]):
                nk = int(round(0.18 * SR))
                tk = np.arange(nk, dtype=np.float64) / SR
                coin = np.sin(2.0 * math.pi * cf * tk) * np.exp(-tk / 0.032) * 0.045
                add_clip(buf, coin_t0 + k_i * 0.035, pan_stereo(coin, pan=0.42), 1.0)

    return apply_reverb(buf, ir, wet=0.15)


def render_kingdom_zoom_far(ir: np.ndarray) -> np.ndarray:
    """Kingdom Track 5 Zoom_Far: Mountain-Pass Banner Wind, Bianzhong Harmonic Aura & Royal Realm Drone."""
    buf = np.zeros((KNG_EXT, 2), dtype=np.float64)
    rng = np.random.default_rng(5900)
    n_tot = KNG_EXT
    t = np.arange(n_tot, dtype=np.float64) / SR

    # 1. Deep Royal Realm Drone (C2 = 65.41 Hz + G2 = 98.0 Hz + C3 = 130.81 Hz)
    c2, g2, c3 = n2f("C2"), n2f("G2"), n2f("C3")
    mod = 0.85 + 0.15 * np.sin(2.0 * math.pi * (1.0 / 14.0) * t)
    d_l = (0.52 * np.sin(2 * math.pi * c2 * t) + 0.35 * np.sin(2 * math.pi * g2 * t + 0.4) + 0.22 * np.sin(2 * math.pi * c3 * t)) * mod * 0.14
    d_r = (0.52 * np.sin(2 * math.pi * c2 * t + 0.2) + 0.35 * np.sin(2 * math.pi * g2 * t + 1.7) + 0.22 * np.sin(2 * math.pi * c3 * t + 0.6)) * mod * 0.14
    buf[:, 0] += d_l
    buf[:, 1] += d_r

    # 2. Mountain-Pass Banner Wind
    w_l = signal.sosfilt(signal.butter(2, [150.0 / (0.5 * SR), 880.0 / (0.5 * SR)], btype="bandpass", output="sos"), rng.standard_normal(n_tot))
    w_r = signal.sosfilt(signal.butter(2, [170.0 / (0.5 * SR), 940.0 / (0.5 * SR)], btype="bandpass", output="sos"), rng.standard_normal(n_tot))
    buf[:, 0] += w_l * (0.042 + 0.022 * np.sin(2.0 * math.pi * 0.09 * t))
    buf[:, 1] += w_r * (0.042 + 0.022 * np.cos(2.0 * math.pi * 0.09 * t + 0.6))

    # 3. Bianzhong Harmonic Cloud Pad
    for t0, t1, notes in [
        (0.0, 11.2, ["C4", "G4", "D5", "E5"]),
        (11.2, 25.2, ["C4", "E4", "G4", "B4"]),
        (25.2, 39.2, ["A3", "E4", "F#4", "A4"]),
        (39.2, 53.2, ["G3", "D4", "G4", "B4"]),
    ]:
        dur = (t1 - t0) + 1.6
        ns = int(round(dur * SR))
        ts = np.arange(ns, dtype=np.float64) / SR
        env_s = np.sin(math.pi * np.clip(ts / dur, 0.0, 1.0)) ** 1.5
        for ni, nn in enumerate(notes):
            fn = n2f(nn)
            sig_n = (np.sin(2 * math.pi * fn * ts) + 0.32 * np.sin(4 * math.pi * fn * ts + 0.5)) * env_s * 0.045
            add_clip(buf, t0, pan_stereo(sig_n, pan=-0.5 + 0.33 * ni, haas_ms=5.5), 1.0)

    return apply_reverb(buf, ir, wet=0.42)


def render_era_transition_agrarian_to_kingdom(ir: np.ndarray) -> np.ndarray:
    """《铸鼎立邦 · 礼乐初成》(9.60s): Agrarian Age (G Pastoral) ──► Kingdom Age (C Yayue) V->I Transition.

    - Phase I   [0.0s .. 2.4s] 沃野归心: Bamboo Dizi & Silk Zither in G + Harvest Drum roll
    - Phase II  [2.4s .. 4.5s] 筑城铸鼎: Iron-Forge Anvil + Guqin/Guzheng sweeping C-Yayue glissando (with F#) + Bo-Bell on G2
    - Phase III [4.5s .. 9.6s] 礼乐初成: Grand V -> I (G -> C) resolution with Bronze Bianzhong, Jade Bianqing,
                               Court Sheng, Bronze Horns & Royal Temple Choir
    """
    dur = 9.60
    n = int(round(dur * SR))
    buf = np.zeros((n, 2), dtype=np.float64)

    # Phase I [0.0s .. 2.4s]: Agrarian Echo in G
    for idx, (t0, nn, gr) in enumerate([(0.05, "G4", "D4"), (0.75, "A4", None), (1.35, "B4", "A4"), (1.90, "D5", "B4")]):
        fl = synth_dongxiao(n2f(nn), dur=0.70, vel=0.84, grace_from=n2f(gr) if gr else None, bright_dizi=True, seed=6000 + idx)
        add_clip(buf, t0, pan_stereo(fl, pan=-0.15), 0.90)

    # Phase II [2.4s .. 4.5s]: Forging & C-Yayue Pivot (G7 -> C with F# Bian-Zhi)
    bo_g = synth_bianzhong(n2f("G2"), dur=3.0, vel=0.90, is_bo_bass=True, seed=6100)
    add_clip(buf, 2.40, pan_stereo(bo_g, pan=0.0), 0.95)

    gliss = ["G3", "A3", "B3", "C4", "D4", "E4", "F#4", "G4", "A4", "B4", "C5", "E5"]
    for idx, nn in enumerate(gliss):
        z = synth_guqin(n2f(nn), dur=2.2, vel=0.76 + 0.015 * idx, harmonic=(idx >= 9), seed=6150 + idx)
        add_clip(buf, 2.40 + idx * 0.14, pan_stereo(z, pan=-0.55 + 0.10 * idx, haas_ms=3.0), 0.88)

    for r_i, rt in enumerate([2.45, 2.80, 3.10, 3.36, 3.60, 3.82, 4.02, 4.20, 4.36]):
        d = synth_court_drum(freq=58.0 + r_i, dur=0.45, vel=0.45 + 0.06 * r_i, rim_wood=(r_i % 3 == 1), seed=6200 + r_i)
        add_clip(buf, rt, pan_stereo(d, pan=-0.15 if r_i % 2 == 0 else 0.15), 0.92)

    # Phase III [4.5s .. 9.6s]: Grand Resolution onto C Yayue Royal Court Fanfare
    for dt0, df, dv in [(4.50, 54.0, 0.98), (5.20, 88.0, 0.70), (5.90, 56.0, 0.92), (6.60, 58.0, 0.86)]:
        d = synth_court_drum(freq=df, dur=0.60, vel=dv, rim_wood=(df > 80.0), seed=6300 + int(dt0 * 100))
        add_clip(buf, dt0, pan_stereo(d, pan=0.0), 0.96)

    for idx, (t0, nn, is_bo, pan) in enumerate([
        (4.50, "C3", True, 0.0),
        (4.52, "C4", False, -0.35),
        (4.55, "G4", False, 0.35),
        (5.20, "D5", False, -0.25),
        (5.90, "E5", False, 0.25),
        (6.60, "G5", False, 0.0),
    ]):
        bz = synth_bianzhong(n2f(nn), dur=3.8, vel=0.90, is_bo_bass=is_bo, seed=6400 + idx)
        add_clip(buf, t0, pan_stereo(bz, pan=pan, haas_ms=4.5), 0.92)

    for idx, (t0, nn, pan) in enumerate([(4.85, "A4", 0.32), (5.55, "B4", -0.32), (6.25, "C5", 0.28), (6.95, "E5", -0.28)]):
        jq = synth_jade_bianqing(n2f(nn), dur=2.2, vel=0.82, seed=6450 + idx)
        add_clip(buf, t0, pan_stereo(jq, pan=pan), 0.88)

    for idx, (nn, pan) in enumerate([("C3", -0.35), ("G3", 0.35), ("E4", -0.20), ("C4", 0.20)]):
        ch = synth_grand_choir(n2f(nn), dur=3.6, vel=0.84, bright_imperial=False, seed=6500 + idx)
        add_clip(buf, 4.50, pan_stereo(ch, pan=pan, haas_ms=6.0), 0.92)
        hrn = synth_imperial_horn(n2f(nn), dur=3.4, vel=0.80, seed=6550 + idx)
        add_clip(buf, 4.50, pan_stereo(hrn, pan=-pan, haas_ms=4.5), 0.86)

    sh_final = synth_court_sheng(n2f("C4"), dur=3.8, vel=0.84, fifth_chord=True, seed=6600)
    add_clip(buf, 4.50, pan_stereo(sh_final, pan=0.0, haas_ms=5.0), 0.90)

    out = apply_reverb(buf, ir, wet=0.34)
    fi, fo = int(round(0.02 * SR)), int(round(1.20 * SR))
    out[:fi] *= np.linspace(0.0, 1.0, fi)[:, None]
    out[-fo:] *= (np.linspace(1.0, 0.0, fo) ** 1.5)[:, None]
    rms = math.sqrt(float(np.mean(out ** 2)) + 1e-12)
    out *= (10.0 ** (-18.5 / 20.0)) / rms
    if float(np.max(np.abs(out))) > 0.88:
        out = np.tanh(out * 0.95) * 0.88
    return out


# ==============================================================================
# PART II: EMPIRE AGE (帝国时代, 92.31 BPM, 1 bar = 2.60s, 49.40s total, F Yanyue)
# ==============================================================================

EMP_BEAT = 0.65
EMP_BAR = 2.60
EMP_TOTAL_BARS = 19
EMP_DUR = EMP_TOTAL_BARS * EMP_BAR  # 49.40s
EMP_SAMPLES = int(round(EMP_DUR * SR))
EMP_EXT = EMP_SAMPLES + int(round(2.4 * SR))


def render_empire_base_core(ir: np.ndarray) -> np.ndarray:
    buf = np.zeros((EMP_EXT, 2), dtype=np.float64)

    # 1. INTRO [0.0s .. 10.4s] (4 bars): 《九天阊阖 · 万国衣冠》
    # Imperial Brass/Horns + Bowed Strings swell + Yunluo Cloud Gongs + Pipa cascade
    for idx, (t0, nn, dur, pan) in enumerate([
        (0.05, "F3", 4.8, -0.30),
        (0.08, "C4", 4.8, 0.30),
        (2.60, "D3", 4.6, -0.25),
        (2.62, "A3", 4.6, 0.25),
        (5.20, "Bb2", 4.8, -0.30),
        (5.22, "F3", 4.8, 0.30),
        (7.80, "C3", 2.5, 0.00),
    ]):
        hrn = synth_imperial_horn(n2f(nn), dur=dur, vel=0.80, seed=7000 + idx)
        add_clip(buf, t0, pan_stereo(hrn, pan=pan, haas_ms=4.5), 0.84)

    intro_strings = [
        (0.65, "C4", 1.90, "A3"),
        (2.60, "D4", 1.90, "C4"),
        (4.55, "F4", 0.65, None),
        (5.20, "G4", 1.90, "F4"),
        (7.15, "A4", 0.65, None),
        (7.80, "G4", 2.40, "A4"),
    ]
    for idx, (t0, nn, dur, sl) in enumerate(intro_strings):
        st = synth_bowed_strings(n2f(nn), dur=dur, vel=0.84, slide_from=n2f(sl) if sl else None, ensemble_size=3, seed=7100 + idx)
        add_clip(buf, t0, pan_stereo(st, pan=-0.15 if idx % 2 == 0 else 0.15, haas_ms=4.0), 0.90)

    for idx, (t0, nn) in enumerate([(1.30, "C5"), (2.60, "D5"), (3.90, "F5"), (5.20, "D5"), (6.50, "C5"), (7.80, "G4"), (9.10, "C5")]):
        yl = synth_yunluo_fangxiang(n2f(nn), dur=1.8, vel=0.76, seed=7150 + idx)
        add_clip(buf, t0, pan_stereo(yl, pan=0.32 if idx % 2 == 0 else -0.32), 0.84)

    # 2A. LOOP A [10.4s .. 23.4s] (5 bars): 《盛世长歌 · 京华万象》
    # Sweeping Bowed Huqin/Strings lead melody in F Major Pentatonic/Yanyue + Pipa/Guzheng arpeggios + Sheng
    a_t0 = 10.4
    a_strings = [
        (0.00, "F4", 0.95, "C4"), (0.975, "G4", 0.325, None), (1.30, "A4", 0.95, "G4"), (2.275, "C5", 0.325, None),
        (2.60, "D5", 1.30, "C5"), (3.90, "C5", 0.65, None), (4.55, "A4", 0.65, "C5"),
        (5.20, "G4", 0.95, "F4"), (6.175, "A4", 0.325, None), (6.50, "F4", 0.95, "G4"), (7.475, "D4", 0.325, None),
        (7.80, "C4", 0.65, "D4"), (8.45, "D4", 0.65, None), (9.10, "F4", 0.65, "D4"), (9.75, "G4", 0.65, "F4"),
        (10.40, "F4", 1.90, "G4"), (12.35, "D4", 0.60, None),
    ]
    for idx, (off, nn, dur, sl) in enumerate(a_strings):
        st = synth_bowed_strings(n2f(nn), dur=dur, vel=0.86, slide_from=n2f(sl) if sl else None, ensemble_size=3, seed=7200 + idx)
        add_clip(buf, a_t0 + off, pan_stereo(st, pan=-0.14, haas_ms=3.5), 0.92)

    a_chords = [
        ["F2", "C3", "F3", "A3", "C4", "F4", "C4", "A3"],
        ["D2", "A2", "D3", "F3", "A3", "D4", "A3", "F3"],
        ["Bb2", "F3", "Bb3", "D4", "F4", "D4", "Bb3", "F3"],
        ["C3", "G3", "C4", "E4", "G4", "E4", "C4", "G3"],
        ["F2", "C3", "F3", "G3", "A3", "C4", "G3", "C3"],
    ]
    for b_i, notes in enumerate(a_chords):
        bt = a_t0 + b_i * EMP_BAR
        sh = synth_court_sheng(n2f(notes[1]) * 2.0, dur=2.3, vel=0.68, fifth_chord=True, seed=7280 + b_i)
        add_clip(buf, bt, pan_stereo(sh, pan=0.28, haas_ms=5.0), 0.78)
        for s_i, nn in enumerate(notes):
            nt = bt + s_i * (EMP_BEAT * 0.5)
            plk = synth_guqin(n2f(nn), dur=1.6, vel=0.74 if s_i in (0, 4) else 0.60, seed=7300 + b_i * 10 + s_i)
            add_clip(buf, nt, pan_stereo(plk, pan=0.24 if s_i % 2 == 0 else -0.22), 0.84)

    # 2B. LOOP B [23.4s .. 36.4s] (5 bars): 《丝路帆影 · 百工行会》
    # Virtuosic Pipa tremolando & pluck + Ten-Gong Yunluo & Iron Fangxiang + Bright Dizi
    b_t0 = 23.4
    b_pipa = [
        (0.00, "A4", 1.25, True), (1.30, "C5", 0.60, False), (1.95, "D5", 0.60, False),
        (2.60, "C5", 1.25, True), (3.90, "A4", 0.60, False), (4.55, "G4", 0.60, False),
        (5.20, "F4", 1.25, True), (6.50, "G4", 0.60, False), (7.15, "A4", 0.60, False),
        (7.80, "G4", 1.25, True), (9.10, "F4", 0.60, False), (9.75, "D4", 0.60, False),
        (10.40, "F4", 1.90, True), (12.35, "C4", 0.60, False),
    ]
    for idx, (off, nn, dur, is_trem) in enumerate(b_pipa):
        pp = synth_pipa_ruan(n2f(nn), dur=dur, vel=0.84, tremolo=is_trem, seed=7400 + idx)
        add_clip(buf, b_t0 + off, pan_stereo(pp, pan=-0.20 if idx % 2 == 0 else 0.20, haas_ms=3.0), 0.90)
        yl = synth_yunluo_fangxiang(n2f(nn), dur=1.4, vel=0.72, seed=7450 + idx)
        add_clip(buf, b_t0 + off, pan_stereo(yl, pan=0.35 if idx % 2 == 0 else -0.35), 0.82)

    for b_i, notes in enumerate(a_chords):
        bt = b_t0 + b_i * EMP_BAR
        st_low = synth_bowed_strings(n2f(notes[2]), dur=2.4, vel=0.72, ensemble_size=2, seed=7500 + b_i)
        add_clip(buf, bt, pan_stereo(st_low, pan=-0.28, haas_ms=4.5), 0.80)

    # 2C. LOOP C [36.4s .. 49.4s] (5 bars): 《太学书香 · 星海罗盘》
    # Noble Low Strings/Cello & Dongxiao duet + Guzheng harmonics + Celestial Yunluo
    c_t0 = 36.4
    c_cello = [
        (0.00, "D3", 1.25, "A2"), (1.30, "F3", 1.25, "D3"),
        (2.60, "G3", 1.25, "F3"), (3.90, "A3", 1.25, "G3"),
        (5.20, "Bb3", 1.25, "A3"), (6.50, "A3", 1.25, None),
        (7.80, "G3", 1.25, "A3"), (9.10, "C3", 1.25, None),
        (10.40, "F3", 1.90, "G3"), (12.35, "C3", 0.60, None),
    ]
    for idx, (off, nn, dur, sl) in enumerate(c_cello):
        vc = synth_bowed_strings(n2f(nn), dur=dur, vel=0.84, slide_from=n2f(sl) if sl else None, ensemble_size=2, seed=7600 + idx)
        add_clip(buf, c_t0 + off, pan_stereo(vc, pan=-0.26, haas_ms=4.0), 0.90)

    c_xiao = [
        (0.65, "A4", 1.90, "F4"),
        (3.25, "C5", 1.90, "A4"),
        (5.85, "D5", 1.25, "C5"), (7.15, "C5", 0.60, None),
        (7.80, "A4", 1.90, "C5"),
        (10.40, "F4", 1.90, "G4"), (12.35, "G4", 0.60, None),
    ]
    for idx, (off, nn, dur, gr) in enumerate(c_xiao):
        dx = synth_dongxiao(n2f(nn), dur=dur, vel=0.82, grace_from=n2f(gr) if gr else None, bright_dizi=False, seed=7650 + idx)
        add_clip(buf, c_t0 + off, pan_stereo(dx, pan=0.24, haas_ms=3.0), 0.88)

    for b_i, notes in enumerate(a_chords):
        bt = c_t0 + b_i * EMP_BAR
        for s_i, nn in enumerate(notes):
            nt = bt + s_i * (EMP_BEAT * 0.5)
            gq = synth_guqin(n2f(nn), dur=1.7, vel=0.68, harmonic=(s_i >= 4), seed=7700 + b_i * 10 + s_i)
            add_clip(buf, nt, pan_stereo(gq, pan=0.20 if s_i % 2 == 0 else -0.20), 0.80)

    return apply_reverb(buf, ir, wet=0.28)


def render_empire_pop_rhythm(ir: np.ndarray) -> np.ndarray:
    """Empire Track 2 Pop_Rhythm (Tier 1 >=4000 pop): Imperial Da-Gu & Paigu Drums, Ban Clappers & Pizzicato Bass."""
    buf = np.zeros((EMP_EXT, 2), dtype=np.float64)
    for bar_idx in range(EMP_TOTAL_BARS + 1):
        bt = bar_idx * EMP_BAR
        in_intro = bar_idx < 4
        if in_intro and bar_idx < 2:
            continue
        gain = 0.52 if in_intro else 0.96
        for h_i, (b_off, df, dv, is_w) in enumerate([
            (0.0, 52.0, 0.90, False),
            (0.75, 74.0, 0.58, False),
            (1.0, 95.0, 0.62, True),
            (1.5, 62.0, 0.68, False),
            (2.0, 55.0, 0.84, False),
            (2.5, 78.0, 0.60, False),
            (3.0, 98.0, 0.66, True),
            (3.5, 66.0, 0.64, False),
        ]):
            d = synth_court_drum(freq=df, dur=0.46, vel=dv * gain, rim_wood=is_w, seed=8000 + bar_idx * 10 + h_i)
            add_clip(buf, bt + b_off * EMP_BEAT, pan_stereo(d, pan=-0.12 if not is_w else 0.28), 0.90)

        if not in_intro:
            sec_b = (bar_idx - 4) % 5
            roots = ["F2", "D2", "Bb2", "C3", "F2"]
            fifths = ["C3", "A2", "F3", "G3", "C3"]
            for p_i, (b_off, nn, pv) in enumerate([
                (0.0, roots[sec_b], 0.82),
                (1.0, fifths[sec_b], 0.68),
                (1.5, roots[sec_b], 0.72),
                (2.5, fifths[sec_b], 0.70),
                (3.0, roots[sec_b], 0.76),
            ]):
                plk = synth_pipa_ruan(n2f(nn), dur=0.95, vel=pv, seed=8200 + bar_idx * 10 + p_i)
                add_clip(buf, bt + b_off * EMP_BEAT, pan_stereo(plk, pan=0.15), 0.84)

    return apply_reverb(buf, ir, wet=0.20)


def render_empire_pop_chorus(ir: np.ndarray) -> np.ndarray:
    """Empire Track 3 Pop_Chorus (Tier 2 >=10000 pop): Grand Imperial Choir, Majestic Brass, High Strings & Yunluo."""
    buf = np.zeros((EMP_EXT, 2), dtype=np.float64)
    for t0, nn, pan in [(5.2, "F3", -0.38), (5.2, "C4", 0.38)]:
        ch = synth_grand_choir(n2f(nn), dur=4.8, vel=0.76, bright_imperial=True, seed=8400 + int(t0 * 10))
        add_clip(buf, t0, pan_stereo(ch, pan=pan, haas_ms=6.0), 0.88)

    for sec_idx in range(3):
        st0 = 10.4 + sec_idx * 13.0
        prog = [
            ("F3", "C4", "A4"),
            ("D3", "A3", "F4"),
            ("Bb2", "F3", "D4"),
            ("C3", "G3", "E4"),
            ("F3", "C4", "G4"),
        ]
        for b_i, (nl, nm, nh) in enumerate(prog):
            bt = st0 + b_i * EMP_BAR
            ch1 = synth_grand_choir(n2f(nl), dur=2.45, vel=0.78, bright_imperial=True, seed=8500 + sec_idx * 30 + b_i)
            ch2 = synth_grand_choir(n2f(nm), dur=2.45, vel=0.74, bright_imperial=True, seed=8501 + sec_idx * 30 + b_i)
            add_clip(buf, bt, pan_stereo(ch1, pan=-0.42, haas_ms=6.0), 0.86)
            add_clip(buf, bt, pan_stereo(ch2, pan=0.42, haas_ms=6.0), 0.84)

            st_hi = synth_bowed_strings(n2f(nh), dur=2.3, vel=0.72, ensemble_size=4, seed=8600 + sec_idx * 30 + b_i)
            add_clip(buf, bt + 0.325, pan_stereo(st_hi, pan=0.25 if b_i % 2 == 0 else -0.25, haas_ms=4.5), 0.80)

            if b_i in (0, 2, 4):
                hrn = synth_imperial_horn(n2f(nm), dur=2.2, vel=0.74, seed=8700 + sec_idx * 30 + b_i)
                add_clip(buf, bt, pan_stereo(hrn, pan=-0.28, haas_ms=4.5), 0.80)
                yl = synth_yunluo_fangxiang(n2f(nh) * 2.0, dur=2.0, vel=0.70, seed=8750 + sec_idx * 30 + b_i)
                add_clip(buf, bt + EMP_BEAT, pan_stereo(yl, pan=0.32), 0.78)

    return apply_reverb(buf, ir, wet=0.35)


def render_empire_zoom_close(ir: np.ndarray) -> np.ndarray:
    """Empire Track 4 Zoom_Close: Waterwheel & Urban Waterworks, Blast-Furnace Bellows/Steel & Woodblock/Movable-Type Press."""
    buf = np.zeros((EMP_EXT, 2), dtype=np.float64)
    rng = np.random.default_rng(8800)
    n_tot = EMP_EXT
    t_full = np.arange(n_tot, dtype=np.float64) / SR

    # 1. Continuous Water-Powered Wheel & Urban Waterworks stream (水力机械水车与城市给排水声)
    water_l = signal.sosfilt(
        signal.butter(2, [240.0 / (0.5 * SR), 1850.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n_tot),
    ) * (0.020 + 0.010 * np.sin(2.0 * math.pi * (1.0 / EMP_BAR) * t_full))
    water_r = signal.sosfilt(
        signal.butter(2, [260.0 / (0.5 * SR), 1950.0 / (0.5 * SR)], btype="bandpass", output="sos"),
        rng.standard_normal(n_tot),
    ) * (0.020 + 0.010 * np.cos(2.0 * math.pi * (1.0 / EMP_BAR) * t_full + 0.7))
    buf[:, 0] += water_l
    buf[:, 1] += water_r

    for bar_idx in range(EMP_TOTAL_BARS + 1):
        bt = bar_idx * EMP_BAR
        # 2. Blast-Furnace Bellows Whoosh & Steel Quench/Hammer (高炉鼓风与百炼钢锻打 on beat 0.0 & 2.0)
        for b_i, b_off in enumerate([0.0, 2.0]):
            t0 = bt + b_off * EMP_BEAT
            nb = int(round(0.42 * SR))
            tb = np.arange(nb, dtype=np.float64) / SR
            bellows = signal.sosfilt(
                signal.butter(2, [140.0 / (0.5 * SR), 780.0 / (0.5 * SR)], btype="bandpass", output="sos"),
                rng.standard_normal(nb),
            ) * (np.sin(math.pi * tb / 0.42) ** 1.4) * 0.065
            add_clip(buf, t0, pan_stereo(bellows, pan=-0.35), 1.0)

        # 3. Movable-Type / Woodblock Printing Frame Clack & Guild Shuttle (活字排版/雕版刷印与织机梭声 on offbeats)
        for p_i, b_off in enumerate([0.5, 1.5, 2.5, 3.5]):
            t0 = bt + b_off * EMP_BEAT
            clack = synth_court_drum(freq=110.0, dur=0.14, vel=0.45, rim_wood=True, seed=8900 + bar_idx * 10 + p_i)
            add_clip(buf, t0, pan_stereo(clack, pan=0.32 if p_i % 2 == 0 else -0.28), 0.65)

    return apply_reverb(buf, ir, wet=0.16)


def render_empire_zoom_far(ir: np.ndarray) -> np.ndarray:
    """Empire Track 5 Zoom_Far: Continental & Oceanic Trade Monsoon, Imperial Harmonic Canopy & Deep F1/C2 Pedal."""
    buf = np.zeros((EMP_EXT, 2), dtype=np.float64)
    rng = np.random.default_rng(8950)
    n_tot = EMP_EXT
    t = np.arange(n_tot, dtype=np.float64) / SR

    # 1. Deep Imperial Pedal Drone (F1 = 43.65 Hz + C2 = 65.41 Hz + F2 = 87.31 Hz)
    f1, c2, f2 = n2f("F1"), n2f("C2"), n2f("F2")
    mod = 0.86 + 0.14 * np.sin(2.0 * math.pi * (1.0 / 13.0) * t)
    d_l = (0.54 * np.sin(2 * math.pi * f1 * t) + 0.36 * np.sin(2 * math.pi * c2 * t + 0.5) + 0.24 * np.sin(2 * math.pi * f2 * t)) * mod * 0.14
    d_r = (0.54 * np.sin(2 * math.pi * f1 * t + 0.2) + 0.36 * np.sin(2 * math.pi * c2 * t + 1.8) + 0.24 * np.sin(2 * math.pi * f2 * t + 0.7)) * mod * 0.14
    buf[:, 0] += d_l
    buf[:, 1] += d_r

    # 2. Oceanic & Continental Trade Wind
    w_l = signal.sosfilt(signal.butter(2, [140.0 / (0.5 * SR), 920.0 / (0.5 * SR)], btype="bandpass", output="sos"), rng.standard_normal(n_tot))
    w_r = signal.sosfilt(signal.butter(2, [160.0 / (0.5 * SR), 980.0 / (0.5 * SR)], btype="bandpass", output="sos"), rng.standard_normal(n_tot))
    buf[:, 0] += w_l * (0.044 + 0.024 * np.sin(2.0 * math.pi * 0.08 * t))
    buf[:, 1] += w_r * (0.044 + 0.024 * np.cos(2.0 * math.pi * 0.08 * t + 0.6))

    # 3. Imperial Harmonic Canopy
    for t0, t1, notes in [
        (0.0, 10.4, ["F4", "C5", "G5", "A5"]),
        (10.4, 23.4, ["F4", "A4", "C5", "D5"]),
        (23.4, 36.4, ["D4", "A4", "C5", "F5"]),
        (36.4, 49.4, ["C4", "G4", "A4", "F5"]),
    ]:
        dur = (t1 - t0) + 1.6
        ns = int(round(dur * SR))
        ts = np.arange(ns, dtype=np.float64) / SR
        env_s = np.sin(math.pi * np.clip(ts / dur, 0.0, 1.0)) ** 1.5
        for ni, nn in enumerate(notes):
            fn = n2f(nn)
            sig_n = (np.sin(2 * math.pi * fn * ts) + 0.35 * np.sin(4 * math.pi * fn * ts + 0.6)) * env_s * 0.046
            add_clip(buf, t0, pan_stereo(sig_n, pan=-0.5 + 0.33 * ni, haas_ms=6.0), 1.0)

    return apply_reverb(buf, ir, wet=0.42)


def render_era_transition_kingdom_to_empire(ir: np.ndarray) -> np.ndarray:
    """《四海一统 · 万邦来朝》(9.60s): Kingdom Age (C Yayue) ──► Empire Age (F Grand Yanyue) V->I Transition.

    - Phase I   [0.0s .. 2.4s] 列国归一: Bronze Bianzhong & Pillar Drum on C + Bronze Horn call
    - Phase II  [2.4s .. 4.5s] 丝路潮涌: Rapid Pipa tremolando + Yunluo Cloud Gongs + Bowed Strings rising on C9sus4
    - Phase III [4.5s .. 9.6s] 万邦来朝: Glorious V -> I (C -> F Major) full orchestral resolution with Bowed Strings,
                               Imperial Brass, Yunluo, Bianzhong, Taiko Drums & Grand Imperial Choir
    """
    dur = 9.60
    n = int(round(dur * SR))
    buf = np.zeros((n, 2), dtype=np.float64)

    # Phase I [0.0s .. 2.4s]: Kingdom Echo in C
    for idx, (t0, nn, is_bo) in enumerate([(0.05, "C3", True), (0.65, "G3", False), (1.25, "C4", False), (1.80, "E4", False)]):
        bz = synth_bianzhong(n2f(nn), dur=2.6, vel=0.86, is_bo_bass=is_bo, seed=9000 + idx)
        add_clip(buf, t0, pan_stereo(bz, pan=-0.25 if idx % 2 == 0 else 0.25, haas_ms=4.0), 0.90)
    hrn_c = synth_imperial_horn(n2f("C3"), dur=2.2, vel=0.84, seed=9050)
    add_clip(buf, 0.10, pan_stereo(hrn_c, pan=0.0, haas_ms=4.0), 0.88)

    # Phase II [2.4s .. 4.5s]: Imperial Surge on C9sus4 -> F
    for idx, nn in enumerate(["C4", "D4", "F4", "G4", "A4", "C5", "D5", "E5", "F5"]):
        t0 = 2.40 + idx * 0.21
        pp = synth_pipa_ruan(n2f(nn), dur=1.4, vel=0.82, tremolo=(idx >= 5), seed=9100 + idx)
        yl = synth_yunluo_fangxiang(n2f(nn), dur=1.6, vel=0.78, seed=9150 + idx)
        add_clip(buf, t0, pan_stereo(pp, pan=-0.45 + 0.11 * idx, haas_ms=3.0), 0.88)
        add_clip(buf, t0, pan_stereo(yl, pan=0.45 - 0.11 * idx), 0.84)

    st_rise = synth_bowed_strings(n2f("C5"), dur=2.0, vel=0.88, slide_from=n2f("G4"), ensemble_size=4, seed=9200)
    add_clip(buf, 2.50, pan_stereo(st_rise, pan=0.0, haas_ms=4.0), 0.92)

    for r_i, rt in enumerate([2.40, 2.72, 3.00, 3.25, 3.48, 3.68, 3.86, 4.02, 4.18, 4.34]):
        d = synth_court_drum(freq=54.0 + r_i, dur=0.45, vel=0.45 + 0.055 * r_i, rim_wood=(r_i % 3 == 2), seed=9250 + r_i)
        add_clip(buf, rt, pan_stereo(d, pan=-0.18 if r_i % 2 == 0 else 0.18), 0.94)

    # Phase III [4.5s .. 9.6s]: Grand Imperial Tutti in F Major (万邦来朝)
    for dt0, df, dv in [(4.50, 50.0, 1.00), (5.15, 85.0, 0.72), (5.80, 52.0, 0.94), (6.45, 54.0, 0.88)]:
        d = synth_court_drum(freq=df, dur=0.62, vel=dv, rim_wood=(df > 80.0), seed=9300 + int(dt0 * 100))
        add_clip(buf, dt0, pan_stereo(d, pan=0.0), 0.98)

    for idx, (nn, pan) in enumerate([("F2", -0.10), ("C3", -0.40), ("F3", 0.40), ("A3", -0.25), ("C4", 0.25), ("F4", 0.0)]):
        ch = synth_grand_choir(n2f(nn), dur=3.8, vel=0.86, bright_imperial=True, seed=9400 + idx)
        hrn = synth_imperial_horn(n2f(nn), dur=3.5, vel=0.82, seed=9450 + idx)
        add_clip(buf, 4.50, pan_stereo(ch, pan=pan, haas_ms=6.0), 0.92)
        add_clip(buf, 4.50, pan_stereo(hrn, pan=-pan, haas_ms=4.5), 0.86)

    # Soaring Bowed Strings & Yunluo Imperial Proclamation Melody (4.50s .. 8.50s)
    emp_melody = [
        (4.50, "F4", 0.65, "C4"),
        (5.15, "G4", 0.32, None),
        (5.47, "A4", 0.32, None),
        (5.80, "C5", 0.65, "A4"),
        (6.45, "D5", 0.65, "C5"),
        (7.10, "C5", 1.50, "D5"),
    ]
    for idx, (t0, nn, mdur, sl) in enumerate(emp_melody):
        st = synth_bowed_strings(n2f(nn), dur=mdur, vel=0.92, slide_from=n2f(sl) if sl else None, ensemble_size=4, seed=9500 + idx)
        yl = synth_yunluo_fangxiang(n2f(nn) * 2.0, dur=1.8, vel=0.80, seed=9550 + idx)
        add_clip(buf, t0, pan_stereo(st, pan=-0.08, haas_ms=3.5), 0.96)
        add_clip(buf, t0, pan_stereo(yl, pan=0.25), 0.84)

    out = apply_reverb(buf, ir, wet=0.35)
    fi, fo = int(round(0.02 * SR)), int(round(1.20 * SR))
    out[:fi] *= np.linspace(0.0, 1.0, fi)[:, None]
    out[-fo:] *= (np.linspace(1.0, 0.0, fo) ** 1.5)[:, None]
    rms = math.sqrt(float(np.mean(out ** 2)) + 1e-12)
    out *= (10.0 ** (-18.5 / 20.0)) / rms
    if float(np.max(np.abs(out))) > 0.88:
        out = np.tanh(out * 0.95) * 0.88
    return out


# ==============================================================================
# Export Helper
# ==============================================================================

def finalize_suite_stem(ext_buf: np.ndarray, n_samples: int, intro_sec: float, target_rms_db: float = -20.0) -> np.ndarray:
    out = ext_buf[:n_samples].copy()
    tail = ext_buf[n_samples:]
    loop_start_idx = int(round(intro_sec * SR))
    n_tail = min(len(tail), n_samples - loop_start_idx)
    if n_tail > 0:
        fade = np.linspace(1.0, 0.0, n_tail)[:, None]
        out[loop_start_idx:loop_start_idx + n_tail] += tail[:n_tail] * fade

    fi = int(round(0.025 * SR))
    out[:fi] *= np.linspace(0.0, 1.0, fi)[:, None]
    out[-fi:] *= np.linspace(1.0, 0.15, fi)[:, None]

    rms = math.sqrt(float(np.mean(out ** 2)) + 1e-12)
    out *= (10.0 ** (target_rms_db / 20.0)) / rms
    if float(np.max(np.abs(out))) > 0.84:
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
    ir_kng = make_hall_ir(rt60=1.95, wet_highcut=4800.0, seed=303)
    ir_emp = make_hall_ir(rt60=2.20, wet_highcut=5200.0, seed=404)

    print(f"=== 1. Generating Kingdom Age (王国时代) 5-stem suite ({KNG_DUR:.2f}s @ 85.7 BPM) + Transition ===")
    kng_stems = [
        ("stem_kng_base_core.wav", render_kingdom_base_core(ir_kng), -19.5),
        ("stem_kng_pop_rhythm.wav", render_kingdom_pop_rhythm(ir_kng), -20.5),
        ("stem_kng_pop_chorus.wav", render_kingdom_pop_chorus(ir_kng), -21.0),
        ("stem_kng_zoom_close.wav", render_kingdom_zoom_close(ir_kng), -21.8),
        ("stem_kng_zoom_far.wav", render_kingdom_zoom_far(ir_kng), -20.5),
    ]
    for fname, raw_ext, target_rms in kng_stems:
        audio = finalize_suite_stem(raw_ext, KNG_SAMPLES, 11.2, target_rms_db=target_rms)
        rms_db, peak_db = save_wav(KNG_OUT_DIR / fname, audio)
        save_wav(KNG_REPO_DIR / fname, audio)
        print(f"  [OK] {fname:26s} | dur={len(audio)/SR:.2f}s | RMS={rms_db:6.2f} dBFS | Peak={peak_db:6.2f} dBFS")

    t_kng = render_era_transition_agrarian_to_kingdom(ir_kng)
    rms_tk, peak_tk = save_wav(KNG_OUT_DIR / "trans_agrarian_to_kingdom.wav", t_kng)
    save_wav(KNG_REPO_DIR / "trans_agrarian_to_kingdom.wav", t_kng)
    print(f"  [OK] {'trans_agrarian_to_kingdom.wav':26s} | dur={len(t_kng)/SR:.2f}s | RMS={rms_tk:6.2f} dBFS | Peak={peak_tk:6.2f} dBFS")

    print(f"=== 2. Generating Empire Age (帝国时代) 5-stem suite ({EMP_DUR:.2f}s @ 92.3 BPM) + Transition ===")
    emp_stems = [
        ("stem_emp_base_core.wav", render_empire_base_core(ir_emp), -19.5),
        ("stem_emp_pop_rhythm.wav", render_empire_pop_rhythm(ir_emp), -20.5),
        ("stem_emp_pop_chorus.wav", render_empire_pop_chorus(ir_emp), -21.0),
        ("stem_emp_zoom_close.wav", render_empire_zoom_close(ir_emp), -21.8),
        ("stem_emp_zoom_far.wav", render_empire_zoom_far(ir_emp), -20.5),
    ]
    for fname, raw_ext, target_rms in emp_stems:
        audio = finalize_suite_stem(raw_ext, EMP_SAMPLES, 10.4, target_rms_db=target_rms)
        rms_db, peak_db = save_wav(EMP_OUT_DIR / fname, audio)
        save_wav(EMP_REPO_DIR / fname, audio)
        print(f"  [OK] {fname:26s} | dur={len(audio)/SR:.2f}s | RMS={rms_db:6.2f} dBFS | Peak={peak_db:6.2f} dBFS")

    t_emp = render_era_transition_kingdom_to_empire(ir_emp)
    rms_te, peak_te = save_wav(EMP_OUT_DIR / "trans_kingdom_to_empire.wav", t_emp)
    save_wav(EMP_REPO_DIR / "trans_kingdom_to_empire.wav", t_emp)
    print(f"  [OK] {'trans_kingdom_to_empire.wav':26s} | dur={len(t_emp)/SR:.2f}s | RMS={rms_te:6.2f} dBFS | Peak={peak_te:6.2f} dBFS")

    print("All Kingdom Age & Empire Age stems and transitions synthesized successfully!")


if __name__ == "__main__":
    main()

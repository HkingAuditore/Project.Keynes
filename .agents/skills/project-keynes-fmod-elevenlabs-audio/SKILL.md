---
name: project-keynes-fmod-elevenlabs-audio
description: >-
  Generate, separate, normalize, and integrate Project.Keynes interactive era music suites,
  era transition fanfares, and camera-zoom soundscapes using the ElevenLabs API and FMOD Studio 2.03.15.
  Use whenever the user asks to generate or improve game music, replace synthesized audio with
  ElevenLabs, create FMOD multi-stem era suites (Stone / Agrarian / Kingdom / Empire Age),
  build FMOD banks, or launch the interactive FMOD music audition window.
---

# Project.Keynes ElevenLabs + FMOD Grand Strategy Music Pipeline (v3)

Produce ~3-minute interactive era suites, era transition fanfares and camera-zoom ambience beds with ElevenLabs, split them locally with Demucs, and compile them into FMOD Studio `2.03.15` banks.

Entry point: `tools/audio/generate_grand_strategy_music_elevenlabs.py` (v3). The v2 backup lives at `D:/Godot/ProjectKeynes/tmp/generate_grand_strategy_music_elevenlabs.v2.bak.py`; do not revert to it.

## 1. Audio-Quality Rules (lessons from v2)

v2 sounded dull and smeared. Never reintroduce any of these:

- **Lossy or low-rate masters.** Request `/v1/music` with `output_format=pcm_48000`. Never use `mp3_*`, and never resample to 32 kHz (that cuts everything above 16 kHz).
- **ElevenLabs stem separation.** Its stems are low-bitrate MP3 and arrive ~25 ms (1203 samples) late. Mixing them with filtered master copies causes comb filtering and flamming. Separate locally with Demucs instead (section 3).
- **Per-layer normalisation, `tanh` saturation, or duplicated filtered content.** Layers must sum exactly to the master: `Base + Rhythm + Chorus == master`, scaled by one common gain.
- **Tonal ambience.** Zoom beds must be prompted with "no music, no tonal hum" so they never clash with the harmony.
- **Low encoding quality.** FMOD Desktop Vorbis quality is 70 in `Audio/ProjectKeynes/Metadata/EncodingSetting/{fa3463e9-0731-437c-8bee-4e68a4d3ffea}.xml`. Do not lower it.

Loudness targets:

| Asset | Target | Ceiling |
| --- | --- | --- |
| Era music (full mix) | -18 LUFS | -1 dBTP |
| Transitions | -17 LUFS | -1 dBTP |
| Ambience beds | -28 LUFS | -1 dBTP |

Output format: 48 kHz, 16-bit WAV with TPDF dither.

## 2. Composition Principles (Civ 6 / AoE 4 / EU4 / Vic 3 Reference)

- **10 sections per era** in a `music_v2_5` `CompositionPlan`: an intro, Loop A, B and C (each built from contrasting sections), and a coda that leads back to the loop start.
- **Real contrast between sections.** Each section gets its own `positive_styles` and `negative_styles` covering key, meter, tempo feel, dynamics, orchestration and solo instrument. Keep the shared era identity small (a few descriptors plus `HIFI`). Large shared style lists flatten every section into the same texture.
- **Theme recall.** Restate the era theme in a new colour (solo, then chamber, then tutti), and include at least one quiet nocturne and one climax per era.
- **No game titles.** Never put trademarked titles in `positive_styles` or `text`. ElevenLabs returns HTTP 400 `copyrighted_material_detected`. Describe the music instead, e.g. "grand historical strategy soundtrack" or "late-romantic symphony orchestra".
- **Line limit.** Each `text` line must be at most 200 characters.
- **Partial key control.** Requested modulations are only partly honoured, especially for orchestral eras: Kingdom drifts to C/F and Empire to Dm/Gm. Verify with key analysis, and strengthen the prompts if the contrast matters.

## 3. Local Stem Separation (Demucs)

- Script: `tools/audio/separate_stems_demucs.py`, model `htdemucs_ft`, CUDA.
- Venv: `D:/Godot/ProjectKeynes/tmp/audio_venv`, created with `--system-site-packages` and `demucs==4.0.1`.
- The system torchaudio DLL fails with WinError 5. The script injects a stub `torchaudio` module and does file I/O with scipy. Keep that shim.
- The generator calls Demucs at 44.1 kHz and maps stems back to 48 kHz. `LAYER_SPLIT` assigns each stem across the three layers:

| Stem | Base | Rhythm | Chorus |
| --- | --- | --- | --- |
| other | 1.0 | 0 | 0 |
| bass | 0.6 | 0.4 | 0 |
| drums | 0.3 | 0.7 | 0 |
| vocals | 0.35 | 0 | 0.65 |

- The `other` stem is further split by HPSS:
  - `OTHER_PERCUSSIVE_TO_RHYTHM = 0.6` of its percussive part goes to Rhythm.
  - `OTHER_SIDE_TO_CHORUS = 0.6` of its harmonic stereo-side part goes to Chorus.
  - The separation residual folds into Base, so the sum stays exact.
- Orchestral eras (Kingdom, Empire) yield near-empty drums and vocals: Rhythm is ~2-5% and Chorus ~15%. Tune the HPSS constants and rerun with `--no-api` (free).

## 4. Era Contract

These timings are shared by the generator, `Project/project-keynes/scripts/audio/game_audio_service.gd` (`*_SECTION_MS`), the FMOD builders, and the tests under `Project/project-keynes/tests/audio/`.

| Era | FMOD event | Prefix | Intro | Loops A / B / C | Total |
| --- | --- | --- | --- | --- | --- |
| Stone | `event:/Music/StoneAge/Suite` | `stem_` | 18 s | 3 x 54 s | 180 s |
| Agrarian | `event:/Music/AgrarianAge/Suite` | `stem_agr_` | 16 s | 3 x 52 s | 172 s |
| Kingdom | `event:/Music/KingdomAge/Suite` | `stem_kng_` | 16 s | 3 x 50 s | 166 s |
| Empire | `event:/Music/EmpireAge/Suite` | `stem_emp_` | 15 s | 3 x 50 s | 165 s |

- Event parameters are `Population`, `CameraZoom` and `LoopSection`, with loop regions A, B and C.
- Loop seams: the last 1.5 s of C is crossfaded into the audio just before A. Section ends get 60 ms micro-blends.
- Transitions are 15 s each (6 s bridge + 9 s fanfare):
  - `event:/Music/Transition/era_stone_to_agrarian`
  - `event:/Music/Transition/era_agrarian_to_kingdom`
  - `event:/Music/Transition/era_kingdom_to_empire`

## 5. Running the Generator

```powershell
python tools/audio/generate_grand_strategy_music_elevenlabs.py --eras all
python tools/audio/generate_grand_strategy_music_elevenlabs.py --eras kingdom_age --force-music   # re-compose one era (~3k credits)
python tools/audio/generate_grand_strategy_music_elevenlabs.py --no-api                           # re-split / re-mix from cache only
```

- **Flags:** `--force-music`, `--force-separation`, `--force-ambience`, `--force-transitions`, `--skip-transitions`, `--no-api`.
- **API key:** set `ELEVENLABS_API_KEY=sk_...` in the repo-root `.env`. Use the 51-character secret key, not the hex Key ID.
- **Sound-generation format:** `/v1/sound-generation` accepts `wav_48000` or `mp3_44100_192`, but not `mp3_48000_192`.
- **Cache:** `D:/Godot/ProjectKeynes/tmp/fmod_<era>/elevenlabs_cache_v3/` holds `master_48k.pcm`, `composition_plan.json`, `demucs_htdemucs_ft/`, `zoom_*.bin` and `transition_48k.pcm`.
- **Outputs:**
  - `tmp/fmod_<era>/audio/` and `Audio/ProjectKeynes/Assets/` (flat; no per-era subfolders).
  - `<prefix>reference_full_mix.wav`, an exact-sum check for A/B listening.

## 6. FMOD Events, Banks and Audition

- Shared builder: `tools/audio/fmod_lib/era_suite_builder.js`, loaded with `studio.system.require`. The per-era scripts are thin wrappers.
- Curves:
  - Rhythm fades in between Population 0.18 and 0.50.
  - Chorus fades in between Population 0.52 and 0.85.
  - Both reach 0 dB max (never boost above 0 dB).
  - Zoom-out EQ high shelf goes from +1 to -3 dB.
  - Zoom beds reach 0 dB max.

```powershell
Stop-Process -Name "PKMusicAudition" -Force -ErrorAction SilentlyContinue
& .\tools\fmod-studio\2.03.15\fmodstudiocl.exe -script .\tools\audio\build_stone_age_fmod.js .\Audio\ProjectKeynes\ProjectKeynes.fspro
& .\tools\fmod-studio\2.03.15\fmodstudiocl.exe -script .\tools\audio\build_agrarian_age_fmod.js .\Audio\ProjectKeynes\ProjectKeynes.fspro
& .\tools\fmod-studio\2.03.15\fmodstudiocl.exe -script .\tools\audio\build_kingdom_and_empire_fmod.js .\Audio\ProjectKeynes\ProjectKeynes.fspro
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\audio\Build-FmodBanks.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.agents\skills\project-keynes-fmod-elevenlabs-audio\scripts\Launch-FmodAudition.ps1 -Scene "res://tests/audio/stone_age_music_demo.tscn"
```

- If the bank copy step fails on a file lock (e.g. a running headless Godot), close that process or retry the copy. Do not kill unrelated user test runs.

**Verify** with each audio test scene:

```powershell
$env:PK_FMOD_TEST='1'
Godot_v4.6.2-stable_win64_console.exe --headless --path Project/project-keynes res://tests/audio/<test>.tscn
```

Test scenes: `stone_age_music_test`, `agrarian_age_music_test`, `kingdom_and_empire_music_test`, `fmod_audio_smoke`.

# dots_ext — ProjectKeynes DOTS GDExtension

C++ implementation of the DataCore world hot loop, part of the DOTS roadmap
(see `.codebuddy/plan/dots-roadmap-to-gdextension/`).

## Layout

```
gdext/
├── SConstruct           # SCons build script (wraps godot-cpp)
├── godot-cpp/           # git submodule, pinned to a 4.6-compatible commit on master
└── src/
    ├── register_types.{h,cpp}      # GDExtension init / class registration
    ├── world_ext.{h,cpp}           # DCWorldExt main type
    ├── components/
    │   ├── component_ids.h         # Mirrors GDScript DCComponentIds
    │   └── slot.h                  # Internal _Slot struct
    ├── systems/                    # Hot-loop ports (filled in I3.B/C)
    └── profiles/                   # ClimateProfile plain-struct serdes (I3.B)
```

Compiled binaries land in
`../Project/project-keynes/addons/dots_ext/bin/<platform>/` automatically — no
manual copy step.

## Building (Windows)

Open **x64 Native Tools Command Prompt for VS 2022**, then:

```
cd D:\Godot\ProjectKeynes\Project.Keynes\gdext
scons platform=windows target=template_debug
scons platform=windows target=template_release
```

First build will compile godot-cpp itself (~10–20 minutes). Subsequent
builds are incremental.

## Setup after fresh clone

```
git submodule update --init --recursive
```

## Why we use master HEAD of godot-cpp

godot-cpp does not yet ship a stable `4.6` branch. The `master` head at the
time of writing already targets `v4.6.stable.official` (verified in
`gdext/godot-cpp/gdextension/extension_api.json`), making it ABI-compatible
with Godot 4.6.x. The submodule is pinned to a specific commit, so future
movement on godot-cpp `master` (toward 4.7 etc.) will not surprise us — we
explicitly bump when ready.

## Targeted Godot version

Godot **4.6.2** (Windows / Linux / Android arm64).
`compatibility_minimum = 4.4` is set in `.gdextension` because no API beyond
4.4 is currently used; if a 4.6-only API is adopted, bump it.

## I3.A scope reminder

This extension currently only exposes the *interface* DCWorld already
provides — `register_component`, `view_f32/i32/u8`, `bind_map_data`,
`create_pool`, `create_archetype`, etc. The hot-loop entry points
(`run_climate_pass_a`, etc.) are stubs returning `-1.0`, signalling the
GDScript caller to fall back to the legacy path. I3.B/C will fill them in.

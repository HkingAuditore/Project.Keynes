# Project.Keynes Runtime System Map

## Modifier Runtime

| Boundary | Owner / entry | Contract |
| --- | --- | --- |
| Catalog | `data/modifiers/default_modifier_catalog.tres` -> `ModifierCatalog.compile_native_catalog()` | Stable keys at resource/save boundary; dense IDs in native runtime |
| Native state | `gdext/src/modifier_runtime.*` inside `DCWorldExt` | Four isolated stores: Climate, Country, Economy, Gameplay |
| Godot bridge | `gdext/src/world_ext_modifier.cpp`, `scripts/modifier/modifier_facade.gd` | PackedArray protocol v1; list/explain/result/journal are cold paths |
| Scheduler | `ModifierDailySystem`, id `modifier_daily`, priority 90 | expiry -> stable commands -> snapshot; precedes climate/country/economy |
| Climate | `world_ext_climate.cpp`, `map_generator.gd` fallback | Modifier after radiative base and before clamp/inertia; async reads frozen POD terms |
| Country | `NativeCountryRuntime::EconomySnapshot` | Publishes generation-safe handles and effective output factors |
| Economy | `effective_building_output_quantity*` | Country Q16 x building factor before existing fixed-point settlement |
| Gameplay | gameplay identity/base SoA in `ModifierRuntime` | Explicit handles/archetypes; no Object pointer/reflection |
| Save | PKCM v1, PKCN v2, PKEC v20, PKGP v1 | environment -> PKCM -> clock -> PKCN -> PKEC -> PKGP |

Primary documentation:
`docs/cpp-dots-runtime/native-modifier-runtime.md`.

Verification:
`.codex/skills/project-keynes-modifier-runtime/scripts/verify_modifier_runtime.ps1`.

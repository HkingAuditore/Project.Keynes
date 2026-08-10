---
name: project-keynes-player-controller
description: Develop, review, migrate, or diagnose the formal Project.Keynes PlayerController session boundary, including player input routing, map selection and camera dispatch, WorldClock controls, UI intent wiring, research command whitelists, player_view save/restore, and separation from GM/debug commands. Use when changing player_game.tscn, player_game.gd, player_controller.gd, MapCamera input, TechnologyWorkspace commands, GameSaveCoordinator player_view handling, or related runtime authority documentation.
---

# Project Keynes PlayerController

Use this skill for the Godot-side formal player session boundary. Read the
runtime architecture skill first when a change touches simulation scheduling,
DataCore slots, native passes, or authority claims.

## Authority Boundary

- `PlayerController` owns player-session orchestration only: selection, input
  gating, camera actions, clock intent, UI synchronization, command validation,
  and `player_view` capture/restore.
- `WorldRuntimeHost` remains the runtime facade and simulation tick entry point.
- `CountryFacade` and `EconomyFacade` remain domain authorities. The controller
  delegates commands and never writes `MapData`, `DCWorld`, native SoA, or
  scheduler state directly.
- GM/diagnostic commands stay on their existing host/debug paths. Never add GM
  capabilities to the formal player command registry.

## Required Invariants

1. Mount exactly one `PlayerController` under `player_game.tscn`; do not mount
   `MapInteractionController`, `SelectionController`, or
   `TimeControlsController`.
2. `PlayerController` is event-driven: no `_process()`, no per-frame `Input`
   polling, no node scans, and no command-table reconstruction in a hot path.
   `MapCamera._process()` is retained only for smoothing, inertia, and focus
   animation.
3. UI-consumed events must not reach world interaction. A focused `LineEdit` or
   `TextEdit` suppresses every shortcut and map gesture; ordinary focused UI
   controls also block direct dispatch.
4. Every formal command goes through a static allowlist and returns the stable
   result shape `{ok, code, message, effective_day, sequence}`. Unknown IDs
   return `unsupported_command`; never pass them through to a facade.
5. Validate session, player ownership, and arguments before allocating the
   monotonic command sequence. Valid commands use the next game day as
   `effective_day` and the player's country handle resolved from the formal
   start context.
6. Save/restore `player_view` only after map and rendering resources are ready;
   restore camera and selected cell through controller APIs.

## Implementation Workflow

1. Read [player-controller-runtime.md](../../../docs/cpp-dots-runtime/player-controller-runtime.md),
   the authority matrix, and the current `player_controller.gd` before editing.
2. Inspect the scene and all existing call sites with `rg`; classify each change
   as session orchestration, UI intent, domain delegation, or simulation
   authority. If it moves simulation authority, stop and use the runtime
   architecture skill as well.
3. Add or change a semantic InputMap action in `project.godot`; route it from
   `PlayerController.handle_input()` or `MapCamera.handle_player_input()`.
   Do not introduce a new hardcoded player key in `PlayerGame` or `MapCamera`.
4. For a new command, add it to the static registry, define strict argument
   validation, call the owning facade with player handle/effective day/sequence,
   normalize success and failure fields, and add a focused contract test.
5. Wire UI components with structured intent (`request_command`) rather than
   passing a facade, player handle, or local sequence into the UI.
6. Keep scene lifecycle, world generation, session routing, and autosave flow in
   `PlayerGame`; keep save provider ordering in `GameSaveCoordinator`.
7. Update the runtime docs and this skill reference in the same change when a
   command, boundary, persistence field, or input action changes.

## Verification Gate

Run, in order:

```powershell
godot --headless --path Project/project-keynes --check-only --script scripts/game/player_controller.gd
godot --headless --path Project/project-keynes --script tests/player_controller_contract_test.gd --quit
godot --headless --path Project/project-keynes --script tests/technology_workspace_smoke_test.gd --quit
godot --headless --path Project/project-keynes --script tests/player_country_ui_smoke_test.gd
godot --headless --path Project/project-keynes --script tests/player_map_overlay_smoke_test.gd
```

For save changes, run the roundtrip through the autoload-aware entry point:

```powershell
$env:PK_GAME_SAVE_ROUNDTRIP_TEST = "1"
godot --headless --path Project/project-keynes
```

Confirm static absence of old controllers, `git diff --check` for the changed
Project/docs files, and no running Godot process before handing off. Headless
dummy-renderer RID/resource leak warnings are not PlayerController failures;
report them separately from test assertions.

## Reference

See [command-contract.md](references/command-contract.md) for the current
allowlist, result codes, input actions, and save ordering.

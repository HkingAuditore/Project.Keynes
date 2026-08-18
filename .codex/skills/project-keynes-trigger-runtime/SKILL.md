---
name: project-keynes-trigger-runtime
description: Develop and review Project.Keynes native TriggerRuntime, catalog compilation, event ingress, aggregate/condition evaluation, typed effect adapters, PKTR persistence, and gap/resync validation.
---

# Trigger Runtime Skill

Use this skill for any trigger, milestone, counter, threshold reward, state-diff
rule, or event-to-effect work in Project.Keynes. Read the runtime architecture,
modifier runtime, and C++/DOTS skills first when the change crosses those owners.

## Authority

GameplayEventBus owns facts, replay, and journal cursors. TriggerRuntime owns only
packed catalog evaluation and cumulative trigger state. It must not mutate Modifier,
Country, Economy, Gameplay, DataCore, or a conserved ledger. Domain adapters enqueue
typed commands and apply them at safe boundaries.

## Hot-path contract

Compile Resources/JSON/GDScript into dense IDs and packed columns. Native loops use
SoA/POD, integer or Q16 values, fixed-capacity buffers, and source/event indexes.
Never execute script, Callable, String, or Dictionary in the hot loop. Preserve
remainder on threshold accumulators and use generation-safe handles.

## Required semantics

Implement exact event-id de-duplication, explicit source cursors, deterministic
condition IR, ordered effects, and idempotency `(trigger_id, target_generation,
fire_sequence)`. On overflow or cursor gap set `needs_resync`, retain the gap range,
rebuild from a committed snapshot when possible, otherwise pause effects and emit a
diagnostic. Do not silently approximate or double grant.

PKTR is the authoritative runtime snapshot: catalog hash/version, cursors, SoA
state, remainder, cooldown/reset, target generation, resync state, and pending
effects. Reject incompatible catalogs and truncated sections.

## Extension and verification

New aggregators add state layout/update/reset/persistence plus a catalog compiler
column. New actions add a typed POD command and a domain adapter; conserved values
remain domain commands. Register `trigger_runtime` after committed facts and before
domain consumers, expose standard scheduler diagnostics, and document fallback and
ACTIVE/SHADOW behavior. Add focused tests for aggregation, crossing/one-shot/cooldown,
dedupe/gap, target handles, effect ACK ordering, PKTR round-trip, replay parity, and
load migration. Run `quick_validate.py`, `git diff --check`, and the native build.

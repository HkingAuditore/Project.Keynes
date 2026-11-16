# Military repeated-work reduction — implementation contract

This work changes only derived lookup work in `MilitaryCore`. Military rules,
daily stage order, integer formulas, intent order, state hashing and PKMI v7
bytes remain authoritative and unchanged. No new approximation or time limit
is introduced. The implementation is prepared in an isolated worktree; build,
replay and timing results must be recorded separately after validation.

## Observed repeated work

- The first logistics request builds a radius-three BFS row for every map cell.
  General procurement reads only the first 19 entries of each row, while
  maintenance and supply probes read the complete row.
- Payroll clears and walks all cells and army slots, and walks all lots, for
  every country. Its payment order is country, garrison cell, army slot.
- Each active war repeats owner/control/value scans over the same daily map.
- Closing one engagement walks every army slot to clear its engagement field.

## Contracts

1. Supply rows are prepared only when logistics first requests them. Before
   that point a supply probe still returns false. Preparation opens access to
   every center; an individual row is then built on first use. Neighbor order,
   BFS visitation order and each consumer's existing limit remain unchanged.
   `set_terrain` and `reset_state` still invalidate rows. Restore retains rows
   for the unchanged terrain, matching existing warm/cold behavior.
2. Payroll rebuilds temporary work from current lots every call. Each lot's
   amount and each country's demanded sum use original lot order. Payment
   visits country, garrison cell, then army slot in ascending order, including
   when money runs out. No country or holder identity is inferred from a
   different store.
3. War ownership/value summaries are rebuilt after engagements on each call
   to `run_wars`. Their integer addition and score rounding remain unchanged.
   The historical “full occupation” field still means that any owned cell is
   occupied today; this optimization does not reinterpret that rule.
4. Engagement membership is a derived reverse index over the authoritative
   army engagement field. Every production assignment updates it; destroy and
   slot reuse remove the old link. Successful restore invalidates the index,
   which rebuilds from restored fields before use. Failed restore leaves it
   intact. Clearing members emits no new events and does not change front
   updates.
5. Work counters reset with the existing daily report. They count actual
   visited lots/holders/cells/engagement members and ring requests/builds.
   They are neither serialized nor hashed. There is no new shared mutable
   scratch state or parallel execution.

## Verification required

Native self-tests compare ring rows to an independent eager BFS, preserve cold
probes and differing consumer caps, exercise cash shortage/payment order,
reassignment/movement/army slot reuse and restore into a warm core. Existing
PKMI byte continuation, battle/recruitment hashes and fiscal conservation
tests remain required. Compare the same pre-change and post-change military
bench scenarios and report actual cells/armies/engagements, cold day separately,
work counters, timed hash and final hash. The large existing case has 100,000
cells and at most 2,048 armies, not 100,000 armies.

## Standalone functional evidence — 2026-11-15

The before and after native self-tests pass. Existing recruitment, war and AI
hashes remain `f3fd1d275cac4e69`, `794e9cc1b4610024` and `233657bbb5047184`.
An identical 150-day fixture produces byte-identical output in both builds:
150 daily state hashes, 1,747 emitted intents including every field and its
order, and three complete PKMI saves. The 516,170-byte trace has SHA256
`8ab1f4512ffbe9c95b008a02c2b48716f8f2f1a240806842bd669a497683c27d`.
Evidence is in `/tmp/keynes-military-redesign-delivery-20261115`.
The repaired production military20 fixture also passes on the before build:
original, repeat replay, day20 checkpoint and eight resumed days all match.
The scenario proves day5 material settlement, a real completed lodge, four
local militia, a four-person field army and war. The after GDExtension replay
and timed before/after acceptance remain pending.

# Technology Network Design Principles

## Contents

1. Strategic Objective
2. Topology
3. Branch Sustainability
4. Entry Conditions
5. Effect Design
6. Era Balance
7. Common Failure Modes
8. Review Checklist

## 1. Strategic Objective

A technology network should create path dependence, not merely display many cross-links. A decision must change what becomes efficient, available, or reachable later.

The player should be able to answer:

- What economic identity am I building?
- What opportunities did my geography and practice reveal?
- What did I delay or make more expensive by specializing?
- Which later technologies become unusually strong because of earlier choices?

## 2. Topology

Use three edge meanings:

- **Hard prerequisite**: indispensable knowledge. Keep these sparse.
- **Alternative evidence**: one of several technologies, signals, or practices can satisfy the gate.
- **Application/feedback**: does not block research completion; unlocks a method, improves a branch, or provides a downstream option.

Backbones should be dependable but not monopolize progress. Branches should have their own forward motion rather than serving as one-time detours.

Prefer this pattern:

```text
backbone A -> branch A1 -> branch A2 -> branch A3
                   \          /          |
backbone B -------- application ----------+
branch C2 -------------------------------> backbone A late method
```

Avoid this pattern:

```text
backbone -> isolated branch -> backbone
backbone -> isolated branch -> backbone
```

## 3. Branch Sustainability

A healthy branch has:

- a recognizable theme such as highland agriculture, urban waterworks, mine drainage, metallurgy, sensing, or automation;
- at least one direct unlock at entry;
- at least one later descendant;
- at least one intersection with another branch;
- a late payoff that is stronger than a generic backbone bonus;
- a tradeoff or placement constraint that preserves choice.

For every branch node before the final era, require an answer to “what can this grow into?”

Recommended branch metrics:

- chain length: at least 3 nodes;
- era span: at least 3 eras;
- branch-to-branch edges: at least 1 per chain;
- branch-to-backbone feedback edges: at least 1 per chain;
- stranded nonterminal branches: 0.

Terminal technologies are valid in the final era or when explicitly marked as a content endpoint with a strong payoff.

## 4. Entry Conditions

Use technology completion as a knowledge floor, not the only source of eligibility.

Branch conditions should usually combine two or more categories:

- technology;
- geography;
- natural resources;
- biology;
- weather experience;
- cross-country contact;
- production practice.

Useful shapes:

```text
ALL_OF(
  TECH_COMPLETED("composite tools"),
  ANY_OF(mountain, high plateau, steep slope),
  ANY_OF(freshwater, flood experience, terrace-maintenance breakthrough)
)
```

```text
AT_LEAST(2, hydraulic engineering, urban waterworks,
            mine drainage, flood experience, drought experience,
            hydraulic breakthrough)
```

Do not make geography a permanent punishment. Provide contact, practice, or imported-content routes where appropriate.

Weather conditions should represent accumulated experience or a meaningful time window, not a random one-day lock.

## 5. Effect Design

### Effect Sentence

Write effects as a subject, attribute, and change:

`Automated farm -> agricultural-worker slots 16 -> 8.`

`Highland tuber plot -> potato base output +35%; cold-stress loss -30%.`

`Country domestic trade -> capacity +10%.`

### Effect Bundle

A substantive technology normally combines two or three of:

- unlock a building or method;
- unlock production of a good;
- allow access to a natural resource;
- improve a narrow building family;
- reduce a relevant climate loss;
- change inputs or employee roles;
- create a broad but smaller spillover;
- add a cost or dependency.

### Bonus Strength

Use stronger targeted bonuses when the scope is narrow:

- narrow terrain/building/method: roughly +20% to +50%;
- building family: roughly +10% to +25%;
- broad country output/research/trade: roughly +4% to +15%;
- climate-loss reduction: roughly 10% to 35%;
- labor/input reduction: pair with capital, energy, skilled labor, or autonomous-system inputs.

These are starting ranges, not caps. Validate stacking, pacing, and replacement economics.

### Resource Language

Say “allow extraction/use of natural resource X”, not “create resource X”, unless a real regeneration or generation mechanism exists.

### Tradeoffs

Specialization should demand something:

- narrower geography;
- more construction goods;
- more skilled workers;
- electricity, fuel, computers, machinery, or autonomous systems;
- faster depletion;
- dependence on trade contact;
- vulnerability outside the target climate.

## 6. Era Balance

Audit all eleven eras together.

Symptoms of a head-heavy tree:

- most branches originate early but terminate quickly;
- later eras mostly contain direct upgrades;
- early technologies unlock whole industries while late technologies add small percentages;
- the final eras have fewer nodes, fewer condition types, and fewer cross-links.

Countermeasures:

- carry early specializations into late sensing, control, automation, and material branches;
- introduce new late-era branch decisions rather than only upgrading old buildings;
- let late technology alter labor, input composition, resource efficiency, and climate resilience;
- keep late targeted effects materially stronger because their prerequisites and capital needs are higher.

## 7. Common Failure Modes

- **Decorative web**: many lines, but every route still requires the same backbone.
- **Stranded branch**: a branch has no descendant and only returns to the backbone.
- **Opaque gate**: uses undefined labels such as “advanced society”.
- **Technology-only gate**: every condition is another completed technology.
- **Fake effect**: names a stat or behavior not consumed by the runtime.
- **Over-specific effect**: benefits one exact object and provides no wider relevance.
- **Over-general effect**: grants universal output with no relationship to the technology.
- **Resource creation claim**: says a survey technology generates mineral reserves.
- **Labor magic**: claims labor reduction without changing employee slots or inputs.
- **Legacy bypass illusion**: an alternative condition cannot bypass an ID still present in `prerequisite_ids`.
- **Era collapse**: later eras contain fewer and weaker choices than early eras.

## 8. Review Checklist

For each node:

- Is its identity understandable without reading internal IDs?
- Does its entry condition contain concrete evidence?
- Does it unlock something or change a named subject numerically?
- Is the targeted effect more important than the generic spillover?
- Is the implementation surface known?
- Is the value strong enough to change a decision?
- Is there a cost, constraint, or opportunity cost?
- Does a branch node have a branch successor?

For the whole network:

- Are all eras populated?
- Are backbone paths viable independently?
- Do branches cross and reinforce each other?
- Do later eras preserve or increase decision density?
- Are hard prerequisites a minority of intersections?
- Are all code claims verified against live content and consumers?

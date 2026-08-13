---
name: project-keynes-technology-tree-design
description: Design, review, rebalance, visualize, or prepare implementation plans for Project.Keynes technology networks across all eleven eras. Use for technology topology, backbone and branch structure, path dependence, research entry conditions and signals, technology effects and unlocks, terrain- or industry-specific bonuses, branch continuity, era pacing, code-grounded content bindings, Modifier feasibility, or audits of TechnologyCatalog proposals and example technology graphs.
---

# Project Keynes Technology Tree Design

Design a path-dependent technology network that is strategically meaningful, code-grounded, and balanced across all eleven eras.

## Load The Runtime Context

Also use these skills when available:

- `project-keynes-technology-runtime` for catalog, research state, conditions, saves, UI, and activation.
- `project-keynes-economy-runtime` for buildings, goods, professions, recipes, resources, and production behavior.
- `project-keynes-modifier-runtime` for every proposed numeric stat and consumer.
- `civ-grounded-development` for repository changes.
- `visualize` when the user asks to inspect a graph or network visually.

Read [runtime-grounding.md](references/runtime-grounding.md) before claiming that an effect or condition is supported. Read [design-principles.md](references/design-principles.md) when designing or reviewing topology and balance. Read [design-schema.md](references/design-schema.md) when producing an auditable JSON design.

## Classify The Request

Distinguish these scopes before acting:

1. **Design only**: propose topology, conditions, effects, content, and balance without repository changes.
2. **Catalog/content implementation**: edit technology definitions, research conditions, BuildingProfile or GoodProfile resources, Modifier definitions, and presentation data.
3. **Runtime expansion**: add a new predicate source, Modifier consumer, state, scheduler behavior, or save contract. Notify the user before introducing a new runtime subsystem.

Do not turn a design request into implementation unless the user asks for changes.

## Ground The Current State

For the current Project.Keynes implementation, start from
`Project/project-keynes/data/technology/technology_network.json`. It is the sole authoring source;
`TechnologyCatalog` remains the compiled/runtime authority. The current network contract is 361 stable
IDs, eleven eras, four backbones, sixteen specialist lanes, sixteen candidates per era, and a five-node
milestone threshold. Do not reintroduce keyword-selected anchors or generated route-based effects.

Inspect the authoritative source rather than relying on prior diagrams or prose:

1. Read technology definitions, prerequisite IDs, condition specs, public names, effects, and era ordering.
2. Inventory research signals and practice/contact triggers.
3. Find every building, method, good, profession, and resource bound to the affected technology IDs.
4. Confirm every proposed Modifier stat is registered and consumed by the target domain.
5. Record known blockers, dormant bindings, misleading sector classifications, and legacy hard gates.

Summarize the existing mechanism before redesigning it.

## Design The Network

Build three interacting layers:

- **Backbones**: reliable long-horizon industrial or institutional progression. A backbone must remain viable without researching every branch.
- **Sustained branches**: specialized paths with their own descendants, economic identity, and late-era payoff.
- **Application intersections**: optional cross-links where one path unlocks a production method, substitutes for evidence, or strengthens another path without becoming a universal hard gate.

Apply these rules:

- Cover all eleven eras; do not front-load most decisions into the first eras.
- Give each nonterminal branch at least one later branch successor and at least one useful application or feedback edge.
- Prefer branch chains spanning at least three nodes and three eras.
- Let backbones drive branches, branches cross each other, and mature branches feed back into backbones.
- Use hard prerequisite edges for indispensable knowledge and research eligibility. Keep optional
  industrial intersections as application bindings rather than fake research gates.
- Treat application feedback as content gating, not as a backward research prerequisite.

## Design Prerequisites And Discovery

Write the knowledge chain in `hard_prerequisite_ids`. Put geography, resources, contact samples and
practice breakthroughs in `reveal_condition`; these sources reveal possibilities but never make an
unqualified technology researchable. Keep `research_condition` empty under the current contract.

Use only active operators unless runtime work is explicitly approved:

- `TECH_COMPLETED`
- `SIGNAL_PRESENT`
- `SIGNAL_COUNT`
- `ALL_OF`
- `ANY_OF`
- `AT_LEAST`
- `NOT`

Diversify discovery inspiration with existing signal sources:

- biology and crop discovery;
- natural resources;
- landforms;
- weather experience;
- cross-country sample contact;
- production-practice breakthroughs;
- completed technologies only as era-aware reveal context, never as signal substitutes.

For each reveal condition, state what the player observed, experienced, imported or practiced. For
each hard prerequisite, name the actual completed technology. Never describe a reveal signal as a
way to bypass missing knowledge.

## Design Technology Effects

Every technology must answer at least one of these explicitly:

- What building or production method is unlocked?
- What good becomes producible?
- What existing natural resource becomes extractable or usable?
- Which exact subject and attribute receive which numeric buff?
- What input, output, employee-slot, construction, climate, trade, or research tradeoff changes?

Use this wording:

`<subject> -> <attribute> <operation/value>`

Examples:

- `Mountain terrace farm -> grain and vegetable base daily output +40%.`
- `Automated farm -> agricultural-worker slots 16 -> 8; autonomous_systems input +500/day.`
- `Country construction -> cost factor -7%.`
- `Unlock building “steam coal mine”; allow extraction of natural resource “coal”.`

Separate effects into:

1. **Direct unlock**: building, method, good, profession, or resource access.
2. **Targeted effect**: a specific terrain, climate, family, building, recipe, input, output, or role layout.
3. **Broad spillover**: an existing registered country Modifier with a real consumer.
4. **Tradeoff**: extra inputs, resource depletion, skilled jobs, construction cost, or narrower placement.

Represent terrain-specific production, labor replacement, input substitution, and output changes through BuildingProfile conditions, recipes, resources, and employee slots. Do not invent an arbitrary terrain-by-method Modifier.

Use strong bonuses when the technology is specialized, conditional, costly, or late. Avoid granting a large universal bonus with no opportunity cost.

## Record Implementation Status

Tag every effect with one status:

- `existing_binding`: current content and runtime already support it.
- `catalog_rebind`: move or add technology tags or conditions.
- `new_content`: add BuildingProfile, GoodProfile, recipe, or method data without a new runtime.
- `modifier_only`: use an existing registered stat and consumer.
- `blocked`: requires a bug fix or unsupported runtime source.
- `new_runtime`: requires explicit approval and architecture work.

Never present proposed balance values as current behavior. Distinguish existing content from strengthened design values.

## Produce Reviewable Output

For every proposed technology include:

- stable ID and player-facing name;
- era, domain, and role (`backbone` or `branch`);
- plain-language entry condition and condition-source categories;
- direct unlocks;
- targeted effect with exact subject and value;
- broad spillover with exact stat and value;
- tradeoff or constraint;
- branch successors and backbone feedback;
- implementation status and code landing point.

When drawing a network, distinguish hard prerequisites, alternative evidence, and application/feedback edges. Selecting a node should reveal all fields above.

## Audit The Design

If the design is represented as JSON, run:

```powershell
& "<python>" ".codex/skills/project-keynes-technology-tree-design/scripts/audit_technology_design.py" "<design.json>"
```

Use `--strict` to fail on warnings. The schema and examples are in [design-schema.md](references/design-schema.md).

Before delivery, verify:

- all eleven eras contain meaningful choices;
- late eras are not materially thinner than early eras without a reason;
- no nonterminal branch is stranded;
- branch conditions include non-technology evidence unless deliberately exceptional;
- research prerequisite edges are acyclic;
- every effect has an explicit subject, attribute, operation, value, and implementation path;
- every unlock names a real or explicitly proposed content object;
- every Modifier exists and has a consumer;
- sector bonuses are not used where current classification makes their target ambiguous;
- no effect directly creates or deletes conserved money, goods, population, or resource reserves through Modifier.

Report unsupported assumptions and intentionally excluded runtime work.

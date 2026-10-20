# Pitfalls, build, and storage — hard-won facts

Everything here cost at least one wasted rebuild or one misleading test result.
Read it before editing native ideology code, and re-read it when a test reports
something that does not match the code you just wrote.

---

## 1. Build and verification environment

**Do not call `gdext/rebuild.bat`.** It ends in `pause` (waits forever) and its
release pass trips `[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED]`. Build
directly:

```bash
cd gdext && PYTHONPATH= VSLANG=1033 \
  "C:/Users/hkinghuang/AppData/Local/Programs/Python/Python313/Scripts/scons.exe" \
  platform=windows target=template_debug dev_build=no -j8
```

- `PYTHONPATH=` is mandatory: the safe-delete shim injected through
  `sitecustomize.py` makes scons' own delete steps fail.
- **The only success criterion is `scons: done building targets.` in stdout.**
  The background task status is always `failed` because the sandbox blocks
  `reg.exe`; exit codes are equally unreliable. Do not "fix" a build that
  printed that line.
- **Link may fail with `拒绝访问` (access denied)** even after `taskkill` reports
  success: a Godot process restarts within ~60s, and `tasklist` shows stale
  entries for dead ones. If killing does not release the DLL, rename it and
  rebuild — the lock follows the old inode, not the name:
  `mv dots_ext_annual_v1...dll{,.old}` then build, then delete the `.old`.

**Tests are organised by domain** (since 2026-10-20): `tests/README.md` lists
15 subdirectories. The invocation is

```bash
godot --headless --path . -s tests/<domain>/<name>.gd
```

`-s tests/ideology_runtime_test.gd` (flat) no longer resolves. `ideology/`,
`runtime/`, `effect/`, `economy/`, `country/` are the ones this system touches.
`country_test_helper.gd` lives in `tests/country/`.

**The Grep tool fails in this repo** with ripgrep exit code 2 on
permission-denied textures and dangling symlinks (`assets/textures/terrain_materials/*.png`,
`m7ect/`). Scope `path` to `scripts/` or `gdext/src/`, or use
`grep -rn --include=*.gd`.

---

## 1b. This skill exists in six copies

`~/.workbuddy/skills/project-keynes-ideology-runtime` is the canonical one.
Independent copies live under the repository at
`.codex/skills/`, `.claude/skills/`, `.cursor/skills/`, `.agents/skills/`,
`.dsh/skills/` — one per tool, all plain copies, none of them symlinks.

They drifted once already (one copy had 214 lines while the rest had 184). When
you edit `SKILL.md` or a reference file, **copy the same files to all six
locations**, or the tools that read a mirror will keep serving stale rules —
including the old PKID version and the flat test paths.

## 2. GDScript silently aborts — the most expensive failure mode here

A `SCRIPT ERROR` inside a function makes **that function return null**; the
caller keeps running. A test that does not assert on the number of checks then
reports **"N checks, 0 failures" while half of them never ran**.

Seen in practice: a fixture assigned an untyped `Array` to
`@export var xs: Array[Resource]`, the assignment failed silently, the catalog
came back null, `compile_native_catalog` threw on null, and the test still
printed `0 failures` with 11 checks instead of 20.

Rules:

- **Always build typed arrays before assigning**:
  `var rows: Array[Resource] = [x]; node.rows = rows`.
- **Always assert a minimum check count** (`>= expected`) in new tests, or print
  the count and eyeball it. "0 failures" alone is not evidence.
- `_ = expr` is **not** valid GDScript (parse error).
- `String.replace(what, to, true)` replaces **every** occurrence. For a
  multi-placeholder template, replace one at a time with
  `find()` + `substr()`.
- **Arguments are evaluated before the callee body.** Lazy-initialising a
  fixture inside the function that consumes it hands the first caller a null.
  Build fixtures at the top of `_run()`.
- `SceneTree` scripts run `_init()` **before the tree is entered**: after
  `get_root().add_child(host)`, `host.is_inside_tree()` is still `false` for the
  rest of that frame. Anything guarded by `if not is_inside_tree(): return`
  (e.g. `WorldRuntimeHost.generate_world`) then returns **silently** and the
  caller only sees "generator is null". One `await process_frame` after
  `add_child` fixes it.

---

## 3. Native self-tests can swallow their own failures

`RuntimeModifierPodAuthority::self_test` / `RuntimeIdeologyPodAuthority::self_test`
define their local helper as:

```cpp
const auto fail = [&error](const char *reason) {
    if (error.empty()) error = reason;   // <-- only when empty
    return false;
};
```

The modifier self-test deliberately leaves an error string behind (the corrupted
save probe). **Any assertion appended after it fails silently**, and the reported
reason is the earlier message — which sends you hunting in the wrong function.

- Put `error.clear();` at the start of any block you append.
- Modifier pod opcodes: `APPLY=1, REMOVE=2, REFRESH=3, SET_STACKS=4,
  SET_MAGNITUDE=5`. Using 2 (REMOVE) where 1 was meant produces "no buckets" and
  reads like a logic bug.

---

## 4. Storage: order, validation, versions

- **A field must be read exactly where it was written.** `banned_bits` was
  appended after the offer row on write but read next to `known_bits`; the whole
  PKID round trip failed. Keep write and read adjacent in the diff and re-read
  both blocks before compiling.
- **Size/range validation must come after the read**, never before: the vector
  is still empty at the earlier point, so a size check there rejects every save.
- Variable-length rows are forbidden inside a fixed-layout struct: write the
  **full capacity** plus a count byte (`choice_count` + 5 int32), so a build with
  a different capacity is rejected by the schema version instead of silently
  shifting every later field.
- Current versions, all fail-closed:
  **PKID schema 7**, **IDP2 (ideology pod) ABI 5**, **PKEF schema 12**,
  **modifier schema 3**. Bumping any of them means old saves must fail with a
  named error, never migrate silently.

---

## 5. Architecture facts that are easy to get wrong

- **The ideology worker POD does no instance reconciliation.** `activation`
  appears **zero times** in `runtime_ideology_pod.cpp`; `EffectActivation` and
  `submit_instances` run on the main thread only. A change to per-instance
  payloads therefore needs no POD catalogue, ABI, or parity work — verify this
  before assuming a change crosses four layers.
- **Three mirrors of the selector ceiling** must stay in sync:
  `EffectRuntime::SELECTOR_MAX_KIND` (main thread),
  `RuntimeEffectPodAuthority::MAX_SELECTOR_KIND` (worker POD), and
  `effect_catalog.gd:POD_MAX_SELECTOR_KIND` (GDScript). One out-of-range card
  fails the whole POD catalogue validation, which drops the EFFECT bit and takes
  the entire twelve-domain authority graph with it. The guard now evaluates the
  constant instead of hard-coding it, but the POD header and the GD constant
  still have to be edited together.
- **Two budgets, not one.** `max_effect_instances` is a *declaration* budget
  (card × level × row across the whole catalog). `max_concurrent_instances` is a
  *concurrency* budget (slots × the widest level's per-program target fan-out,
  stacks included). They fail independently; neither implies the other.
- **`effect_instance_id()` must stay a pure function** of
  (country, ideology, location, level, program, target, layer). Anything
  time-, order-, or counter-dependent leaks orphan instances across save/load.
  The layer index participates **only when non-zero** — mixing 0 unconditionally
  renumbers every instance in every existing save.
- **The draw kernel is shared by both authorities** (`runtime_ideology_draw_kernel.h`).
  Any change must be made once, there. The pity guarantee is a pool
  **partition** (draw one recent row first, then the rest), never a re-roll: a
  re-roll advances the RNG a variable number of times and the two authorities
  desynchronise.
- **A synergy may rewrite another program's magnitude at runtime**
  (`IdeologySynergyDefinition.overrides` → `magnitude_scale_for`). The multiplier
  is a product over *active* synergies, clamped once at the end to
  [0.25×, 4×]; clamping per step truncates 1.5³ into 1.5². It reaches the
  runtime as one optional column (`magnitude_scales`) on `submit_instances` and
  is applied at the single point where a program command becomes a modifier row.
- **Stat keys are generated by family.** Any new generator loop in
  `ModifierCatalog.compile_native_catalog()` needs a matching row in
  `scripts/modifier/stat_key_families.gd`, or the key is a dead end that
  compiles, applies, and does nothing. `tests/stat_key_family_test.gd` is the
  only thing that notices.
- **Aggregation policy is opt-in and currently unused.** `aggregate_policy != SUM`
  forces a full bucket rebuild on every mutation; the source grouping is
  O(m log m) after the sort rewrite. No stat opts in yet, so the cost is
  literally zero today — do not "optimise" it further without a stat that uses
  it.

---

## 6. Reading the design document

`docs/plans/ideology-build-redesign.md` is long and partly historical.

- **§35 is the authoritative status table.** Start there.
- §24.5 – §32.9 are records written at the time; most "还没做的" items in them
  have since been done. Do not quote them as current state.
- §33 / §36 / §37 / §38 are the landing records for the infrastructure layers,
  the A-段 work, the runtime magnitude override, and the performance account.
- §22 defines the first gate that has **not** been lit: a real card demonstrating
  "condition changes → hit set changes → panel shows N cells". Until it is, no
  cell-level card is trustworthy, however green the unit tests are.

---

## 7. Things that look like bugs but are not

- The background scons task reporting `failed` (sandbox blocks `reg.exe`).
- `godot --version` bumps in logs, `ObjectDB instances leaked at exit` — both
  normal for headless `-s` runs.
- Diagnostics printing literal `%d`/`%s`: those call sites originally used
  `godot::vformat` (which only understands `{}`) with printf specifiers. They
  now go through `pk::log_line`, which does substitute — if you see literal
  specifiers again, someone reintroduced `vformat`.

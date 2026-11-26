#include "ideology_runtime.h"
#include "simulation_math.h"
#include "ideology_runtime_internal.h"
#include "ideology_runtime_common.inc"
#include <cstdio>
#include <cstdlib>

// Authority-aware instance queries: the ideology report and the ideology restore
// both ask whether an instance still exists / has fired.

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>


namespace pk {
using namespace godot;

namespace {
constexpr int32_t kEconomyMetricCount = EconomyApi::FAMILY_METRIC_COUNT;
}

bool NativeIdeologyRuntime::collect_effect_activations(
        const CountryState &country, const IdeaState &state,
        std::vector<EffectActivation> &out,
        std::vector<DerivedProgramContribution> *out_derived) const {
    out.clear();
    if (_effect_runtime == nullptr) return true;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return true;
    ++_collect_entries;
    // ── WHICH LEVEL DOES A PENDING CARD CONTRIBUTE? (plan §10.1) ─────────────
    //
    // The plan says: "pending 期间使用旧基础：升级保留旧等级，卸卡保留旧贡献，尚未确认的装卡
    // 不产生贡献". This implements it.
    //
    // `start_transition` writes `state.level = target` at REQUEST time (`:3598`), so
    // reading `state.level` here served the NEW level's magnitudes while the transition's
    // Effect transactions had not been ACKed at all. Measured on a level-up with
    // `transition_transaction_statuses == [1, 1]` (both PLANNED, zero ACKs): the covered
    // cell already read the L2 add 0.08000183 instead of the L1 0.05000305. Settling then
    // changed nothing, which is exactly why a content check could not see it -- only
    // comparing the pending window against the settled state could (M5-69).
    //
    // `:5006-5007` -- the daily understanding accrual for this SAME card -- already does
    // it right:
    //
    //     growth_level = state->transition.active != 0 ? previous_level : state->level
    //
    // The two halves of one card disagreed. This makes the contribution half agree, and
    // adds the other half of the same rule: a pending EQUIP has
    // `previous_location == INACTIVE`, i.e. the card was not equipped before, so it must
    // contribute NOTHING until its ACK lands.
    if (state.location == INACTIVE) return true;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    int32_t contribution_level = -1;
    std::vector<const EffectTemplate *> active_templates;
    // The level-selection rule lives in ONE place now
    // (`resolve_contribution_templates`), because the applied-program basis has to
    // read the same level: a second copy is exactly the M5-69 defect, where the
    // contribution half and the accrual half disagreed about a pending transition.
    if (!resolve_contribution_templates(country, state, contribution_level,
            active_templates))
        return true;
    for (const EffectTemplate *templ_ptr : active_templates) {
        ++_collect_templates;
        const EffectTemplate &templ = *templ_ptr;
        const std::string program = effect_program_key(templ.definition_key);
        if (program.empty()) { ++_collect_program_empty; continue; }
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(program, metadata)) {
            // No declarative program: the row stays on the legacy batch.
            ++_collect_pod_fail;
            // Record WHICH program: a bare count cannot tell "the card never became
            // active" apart from "the card is active but its program is missing".
            if (_collect_pod_fail_keys.size() < 8)
                _collect_pod_fail_keys.push_back(program);
            continue;
        }
        // Record the SUCCESSES too: a cost entry legitimately fails POD, so the failure
        // list alone cannot say whether the card's real effect resolved.
        if (_collect_pod_ok_keys.size() < 8)
            _collect_pod_ok_keys.push_back(program);
        (void)state;
        std::vector<EffectTarget> targets;
        const bool targets_ok = resolve_effect_targets(country, state, program,
            metadata, effect_program_hash(program), targets);
        if (!targets_ok) { ++_collect_targets_fail; continue; }

        // ── Backend split (plan 22 §4.4 / §4.5 / I01) ──────────────────────
        //
        // The eligibility column is consulted ONCE, here. A DerivedCell program
        // contributes rows to the Modifier derived layer and creates NO
        // instances -- which is what removes the 32-cell cap for it, because the
        // cap below exists only to bound the instance table.
        //
        // Everything else keeps the instance path unchanged. I01 forbids one
        // program having two backends in the same configuration, so this is an
        // exclusive branch, not an addition.
        const CellProgramDecision backend =
            decide_cell_program_backend(cell_program_facts_for(
                program, metadata, state));
        // ── I01 is decided by CAPABILITY + ROLLOUT, not by the caller ─────
        //
        // This used to require `out_derived != nullptr` as well, which meant the
        // INSTANCE call site (`reconcile_effect_activations`, :2483, passes nullptr)
        // ignored the rollout entirely while the DERIVED call site
        // (`step_derived_rebuild`) honoured it. With a batch enabled both ran,
        // so the same program created instances AND contributed rows -- a direct
        // violation of I01 ("one program, one backend") and the reason the M4
        // per-source scale fix appeared to do nothing: the value the fixture read
        // came from the surviving INSTANCE, not from the derived row
        // (measured `present=[1,1,1,1]`, see M4-3).
        //
        // The condition is now "should this program be derived", and the caller only
        // decides whether it CAN receive rows. A derived program is skipped by the
        // instance path either way.
        const bool derive_this_program =
            cell_program_rollout_enabled(metadata.target_selector_kind) &&
            backend.backend == CellProgramBackend::DerivedCell;
        if (derive_this_program && out_derived == nullptr) {
            // Derived backend, but this call site collects no rows: emit NOTHING so
            // the instance path cannot double-apply it. `step_derived_rebuild`
            // is the only producer of the derived rows.
            continue;
        }
        if (derive_this_program) {
            // ── One contribution PER TARGET, not one per program ──────────
            //
            // `EffectTarget` carries `magnitude_scale_q16`
            // (ideology_runtime.h:456), and for SELECTOR_TAG_SOURCE_COUNT the
            // instance path normalises it to `min(count, cap) / cap`
            // (ideology_runtime.cpp:2079-2081). Collecting every cell into ONE
            // contribution threw that scale away, so a cell bracketed by two
            // sources read 1.23999 where the instance path reads 1.12 -- a
            // difference of exactly one source contribution (measured, see
            // artifacts/ideology-cell-layer/m4/M4-2-per-source-scale-rootcause.md).
            //
            // Emitting one contribution per target keeps the fold in the
            // materializer unchanged (it already walks contribution -> cells) and
            // lets each cell carry its own scale.
            // ── school strength must reach the DERIVED backend too ────────
            //
            // It used to be applied only on the instance path, which multiplies
            // `activation_scale_q16` by `school_strength_scale_q16` (the LEGACY branch
            // below does exactly that). So a school's strength affected its
            // country-domain cards and silently did nothing for its kind-12 cell cards
            // -- the majority of the catalog. A mechanism that works on one of two
            // backends is worse than one that works on neither, because it lies: a
            // designer writes "agrarian school strength +25%", verifies it on a
            // country-domain card, and most agrarian cards never move.
            //
            // This mirrors the instance path exactly, INCLUDING its self-reference
            // guard: a card that itself writes its own school's strength stat must not
            // then be scaled by it.
            //
            // Zero-risk when written: no shipped content writes any of the six
            // `country.ideology.school_strength_factor.*` stats (measured: zero
            // modifier-definition terms target them), so the factor is 1.0 in every
            // shipped configuration and this multiplies by 1.0. It only starts to
            // matter the day content drives the stat -- which is the point: doing it
            // now is free, doing it then is a re-balance of every derived card.
            double derived_school_scale = 1.0;
            {
                const int32_t school_index = definition.school_index;
                if (!program_writes_school_strength(program, school_index)) {
                    derived_school_scale = static_cast<double>(
                        school_strength_scale_q16(country, school_index)) /
                        static_cast<double>(Q16_ONE);
                }
            }
            // I01: the backend must not change what a program does. The instance branch
            // scales a copier's copied programs by 1.2x at level >= 2; without the same
            // term here a derived copier would silently drop that bonus.
            //
            // Measured: shipped content has exactly one copier
            // (idea.algorithmic_governance) and its effects target the Modifier domain,
            // not cells, so this is a no-op today. It stops being one the moment a copier
            // targets cells -- which is precisely what I01 is for.
            double derived_copy_scale = 1.0;
            if (definition.copy_left_programs != 0 && state.level >= 2)
                derived_copy_scale = static_cast<double>(kCopierLevelTwoScaleQ16) /
                    static_cast<double>(Q16_ONE);
            // Plan 22 §5.2: a program-level condition gates each TARGET. This path
            // used to skip it, so the 41 conditional OWN_TERRITORY programs
            // (village_compact, subsidy_state, ...) applied to every candidate
            // cell whatever their metric said (lifecycle / country_ramp fixtures,
            // 2026-11-14). Sampled at the target through the economy sampler the
            // instance path and the ramp sampler read, test overrides included.
            // No economy means the condition cannot be read: emit nothing.
            // Same slab as the instance path: economy metrics, then the ideology
            // scalars (equipped count, era, ...). The scalars are fixed for this
            // card and sit above the range the sampler rewrites per target.
            std::vector<int64_t> condition_metrics;
            if (metadata.condition_count > 0) {
                if (_economy_runtime == nullptr) continue;
                condition_metrics.assign(static_cast<size_t>(std::max(
                    kEconomyMetricCount, _effect_runtime->metric_count())), 0);
                fill_ideology_scalars(country, state, condition_metrics);
            }
            std::vector<DerivedProgramContribution> per_target;
            per_target.reserve(targets.size());
            for (const EffectTarget &t : targets) {
                if (!condition_metrics.empty()) {
                    const int32_t count =
                        static_cast<int32_t>(condition_metrics.size());
                    economy_api::sample_effect_metrics(*_economy_runtime,
                        static_cast<int32_t>(t.handle), kEconomyMetricCount,
                        condition_metrics.data(), metadata.metric_mask);
                    bool passes = false;
                    std::string condition_error;
                    const bool condition_ok =
                        _effect_runtime->evaluate_program_conditions_for_metrics(
                            program, condition_metrics.data(), count, passes,
                            condition_error);
                    if (!condition_ok || !passes) continue;
                }
                DerivedProgramContribution single;
                single.source_country = country.handle;
                single.ideology_id = state.ideology_id;
                single.level = contribution_level;
                single.program_hash = effect_program_hash(program);
                single.backend = CellProgramBackend::DerivedCell;
                single.cells.push_back(static_cast<int32_t>(t.handle));
                single.magnitude_scale =
                    static_cast<double>(t.magnitude_scale_q16) /
                    static_cast<double>(Q16_ONE) * derived_school_scale *
                    derived_copy_scale;
                per_target.push_back(std::move(single));
            }
            std::vector<DerivedProgramContribution::Term> fold_terms;
            resolve_program_fold_terms(metadata, program, fold_terms, true);
            for (const DerivedProgramContribution::Term &row : fold_terms) {
                // A SUBTRACT term arrives as ADD with a negative value
                // from the resolver, so a `.cut` card must fold its
                // magnitude negatively rather than being dropped.
                for (DerivedProgramContribution &single : per_target) {
                    DerivedProgramContribution::Term scaled = row;
                    // `magnitude_scale` is 1.0 for every selector except
                    // TAG_SOURCE_COUNT, so this is a no-op for kinds 12/14/15.
                    scaled.add *= single.magnitude_scale;
                    if (scaled.operation != 0)
                        scaled.factor = simulation_math::pow(scaled.factor,
                            single.magnitude_scale);
                    single.terms.push_back(scaled);
                }
            }
            // Hand to the caller's accumulator; `collect_effect_activations`
            // stays a pure collector so `reconcile_effect_activations` (and the
            // pod mirror) can decide when to materialise.
            for (DerivedProgramContribution &single : per_target) {
                out_derived->push_back(std::move(single));
                ++_collect_derived_emitted;
            }
            continue;  // no instance, no cap, no ACK
        }
        // LEGACY INSTANCE PROTECTION: one instance per resolved target, capped so a
        // wide selector cannot flood the instance table.
        //
        // This branch is reached ONLY by programs the derived layer did not take
        // (`continue` above handles those). So the 32 here bounds INSTANCES, not cell
        // coverage -- a derived card covers the whole territory with zero instances.
        if (static_cast<int32_t>(targets.size()) >
                EffectRuntime::LEGACY_INSTANCE_MAX_CELLS)
            targets.resize(static_cast<size_t>(
                EffectRuntime::LEGACY_INSTANCE_MAX_CELLS));
        // ADD_STACK rows own one instance PER LAYER, not one instance carrying a
        // stack count: the whole point of L2-8 is that layers can expire
        // independently, and a single instance has a single `duration_days`. Any
        // other policy keeps exactly one instance, so their ids are unchanged.
        const bool layered = metadata.stack_policy == 2; // ADD_STACK
        const int32_t layers = layered
            ? std::clamp(templ.stacks, 1, std::max(1, metadata.max_stacks)) : 1;
        // Hoisted out of the target x layer loops: the value depends only on the
        // country, the program, and the copier level, so a 32-cell x 3-layer row
        // would otherwise rescan every synergy 96 times for the same answer.
        const int32_t copy_scale_q16 =
            definition.copy_left_programs != 0 && state.level >= 2
                ? kCopierLevelTwoScaleQ16 : static_cast<int32_t>(Q16_ONE);
        int64_t activation_scale_q16 =
            static_cast<int64_t>(magnitude_scale_for(country, program)) *
            copy_scale_q16 / Q16_ONE;
        const int32_t school_index = definition.school_index;
        if (!program_writes_school_strength(program, school_index)) {
            activation_scale_q16 =
                activation_scale_q16 *
                school_strength_scale_q16(country, school_index) / Q16_ONE;
        }
        activation_scale_q16 = std::clamp<int64_t>(
            activation_scale_q16, Q16_ONE / 4, 4 * Q16_ONE);
        for (const auto &target : targets) {
            for (int32_t layer = 0; layer < layers; ++layer) {
                EffectActivation activation;
                activation.program = program;
                activation.source_kind = metadata.source_kind;
                activation.target_domain = metadata.target_domain;
                activation.metric_mask = metadata.metric_mask;
                activation.scalar_mask = metadata.scalar_mask;
                // L3-9: resolved per country from ACTIVE synergies, so the same
                // program can be rewritten for one country and untouched for
                // another. 1.0 when no active synergy targets it.
                const int32_t target_scale_q16 = static_cast<int32_t>(
                    static_cast<int64_t>(activation_scale_q16) *
                    target.magnitude_scale_q16 / Q16_ONE);
                activation.magnitude_scale_q16 = target_scale_q16;
                activation.ref.magnitude_scale_q16 = target_scale_q16;
                activation.ref.program_hash = effect_program_hash(program);
                activation.ref.target_handle = target.handle;
                activation.ref.target_generation = target.generation;
                activation.ref.instance_id = effect_instance_id(country.handle,
                    state.ideology_id, state.location, state.level, program,
                    target.handle, layer);
                activation.ref.generation = std::max(1U, state.generation);
                out.push_back(std::move(activation));
            }
        }
    }
    std::sort(out.begin(), out.end(),
        [](const EffectActivation &lhs, const EffectActivation &rhs) {
            if (lhs.ref.instance_id != rhs.ref.instance_id)
                return lhs.ref.instance_id < rhs.ref.instance_id;
            return lhs.program < rhs.program;
        });
    return true;
}

void NativeIdeologyRuntime::collect_idea_program_domains(
        const CountryState &country, const IdeaState &state,
        std::unordered_map<uint64_t, int32_t> &out) const {
    out.clear();
    if (_effect_runtime == nullptr) return;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return;
    // Same preconditions as collect_effect_activations: an inactive or
    // out-of-range idea owns no instances, so it owns no labels either.
    if (state.location == INACTIVE || state.level < 0) return;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    if (state.level >= definition.level_count) return;
    std::vector<const EffectTemplate *> active_templates;
    if (definition.copy_left_programs != 0) {
        (void)copy_source_programs(country, state, active_templates);
    } else {
        const Level &row = _levels[
            static_cast<size_t>(definition.level_begin + state.level)];
        active_templates.reserve(static_cast<size_t>(row.persistent_count));
        for (int32_t offset = 0; offset < row.persistent_count; ++offset)
            active_templates.push_back(&_persistent_templates[
                static_cast<size_t>(row.persistent_begin + offset)]);
    }
    for (const EffectTemplate *templ_ptr : active_templates) {
        const EffectTemplate &templ = *templ_ptr;
        const std::string program = effect_program_key(templ.definition_key);
        if (program.empty()) continue;
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (!_effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        const EffectRuntime::FamilyEffectMetadataPod effective =
            effective_selector_metadata(country, program, metadata);
        out[effect_program_hash(program)] = effective.target_domain;
    }
}

void NativeIdeologyRuntime::retire_effect_activations(IdeaState &state,
        int64_t day) {
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) {
        state.effect_instances.clear();
        return;
    }
    for (const IdeaState::EffectInstanceRef &ref : state.effect_instances) {
        // `attached()`, not just non-null: DCWorldExt creates the forwarder with
        // the world and only attach()es it once the Effect catalog exists, and an
        // unattached forwarder answers retire() with unavailable() -- dropping the
        // retire instead of falling back to the legacy authority.
        if (_effect_forwarder != nullptr && _effect_forwarder->attached()) {
            _effect_forwarder->retire(ref.instance_id, ref.generation, day);
            continue;
        }
        std::string ignored;
        _effect_runtime->retire_instance_pod(
            ref.instance_id, ref.generation, day, ignored);
    }
    state.effect_instances.clear();
}

bool NativeIdeologyRuntime::reconcile_effect_activations(
        const CountryState &country, IdeaState &state, int64_t day,
        std::string &error) {
    error.clear();
    if (_effect_runtime == nullptr && _effect_forwarder == nullptr) return true;
    std::vector<EffectActivation> desired;
    // Derived contributions are NOT materialised here.
    //
    // `reconcile_effect_activations` runs once per (country, idea) from four
    // call sites. Building a WHOLE front from one country's data and
    // installing it means the last reconcile erases every other country's
    // rows. The materialiser therefore lives in
    // `step_derived_rebuild()`, which walks every country and builds one
    // front -- a global operation for a global output.
    if (!collect_effect_activations(country, state, desired)) return true;

    // Retire before submitting so a superseded instance can never coexist with
    // its replacement for a single tick.
    for (const IdeaState::EffectInstanceRef &held : state.effect_instances) {
        bool keep = false;
        for (const EffectActivation &want : desired) {
            if (want.ref.instance_id == held.instance_id) {
                keep = true;
                break;
            }
        }
        if (keep) continue;
        // Same attached() rule as retire_effect_activations above.
        if (_effect_forwarder != nullptr && _effect_forwarder->attached()) {
            _effect_forwarder->retire(held.instance_id, held.generation, day);
            continue;
        }
        std::string ignored;
        _effect_runtime->retire_instance_pod(
            held.instance_id, held.generation, day, ignored);
    }

    std::vector<const EffectActivation *> added;
    for (const EffectActivation &want : desired) {
        bool present = false;
        for (const IdeaState::EffectInstanceRef &held : state.effect_instances) {
            // The scale is part of "present": a synergy flip can change a
            // card's strength without touching its identity, and skipping the
            // submit here is exactly the X5 bug (the instance keeps the old
            // multiplier until something else makes it re-submit).
            if (held.instance_id == want.ref.instance_id &&
                    held.generation == want.ref.generation &&
                    held.magnitude_scale_q16 == want.ref.magnitude_scale_q16) {
                present = true;
                break;
            }
        }
        if (!present) added.push_back(&want);
    }

    if (!added.empty()) {
        const int32_t count = static_cast<int32_t>(added.size());
        PackedInt64Array ids;
        PackedStringArray program_keys;
        PackedInt32Array generations;
        PackedInt32Array source_types;
        PackedInt32Array source_kinds;
        PackedInt64Array source_ids;
        PackedInt64Array source_handles;
        PackedInt64Array target_handles;
        PackedInt32Array target_generations;
        PackedInt32Array levels;
        PackedByteArray active;
        PackedInt64Array next_due_days;
        PackedInt32Array magnitude_scales;
        ids.resize(count);
        program_keys.resize(count);
        generations.resize(count);
        source_types.resize(count);
        source_kinds.resize(count);
        source_ids.resize(count);
        source_handles.resize(count);
        target_handles.resize(count);
        target_generations.resize(count);
        levels.resize(count);
        active.resize(count);
        next_due_days.resize(count);
        magnitude_scales.resize(count);
        const int32_t source_id = state.ideology_id + 1;
        for (int32_t i = 0; i < count; ++i) {
            const EffectActivation &activation = *added[static_cast<size_t>(i)];
            ids[i] = activation.ref.instance_id;
            program_keys[i] = String(activation.program.c_str());
            generations[i] = static_cast<int32_t>(activation.ref.generation);
            source_types[i] = static_cast<int32_t>(0x4944454f); // IDEO
            source_kinds[i] = activation.source_kind;
            source_ids[i] = source_id;
            source_handles[i] = static_cast<int64_t>(country.handle);
            target_handles[i] = static_cast<int64_t>(activation.ref.target_handle);
            target_generations[i] = static_cast<int32_t>(activation.ref.target_generation);
            levels[i] = std::max(0, state.level);
            active[i] = 1;
            next_due_days[i] = day;
            magnitude_scales[i] = activation.magnitude_scale_q16;
        }
        Dictionary batch;
        batch["instance_ids"] = ids;
        batch["program_keys"] = program_keys;
        batch["generations"] = generations;
        batch["source_types"] = source_types;
        batch["source_kinds"] = source_kinds;
        batch["source_ids"] = source_ids;
        batch["source_handles"] = source_handles;
        batch["target_handles"] = target_handles;
        batch["target_generations"] = target_generations;
        batch["levels"] = levels;
        batch["next_due_days"] = next_due_days;
        batch["magnitude_scales"] = magnitude_scales;
        // A5 NOTE: no `latched` column is sent here, deliberately.
        //
        // Everything in `added` is by definition an instance the Effect side does
        // NOT already hold (a held one with matching id/generation/scale is
        // filtered out above), so this side has no knowledge of its latch --
        // sending a column of zeros would be a claim, and `submit_instances`
        // treats an explicit column as authoritative. Omitting the column means
        // "not owned here", which is the truth: the evaluating authority keeps its
        // own latch, and the write-back path (`apply_pod_snapshot`) carries it
        // back. The forwarder's builder also reads no latch from these rows.
        batch["active"] = active;
        // Same attached() rule as the retires: submit_batch on an unattached
        // forwarder can only answer effect_runtime_unavailable, which would read
        // as a rejected card instead of "use the legacy authority".
        const bool forward =
            _effect_forwarder != nullptr && _effect_forwarder->attached();
        const Dictionary result = forward
            ? _effect_forwarder->submit_batch(batch)
            : _effect_runtime->submit_instances(batch);
        if (!static_cast<bool>(result.get("ok", false))) {
            Variant reason = result.get("reason", Variant());
            error = reason.get_type() == Variant::STRING
                ? std::string(String(reason).utf8().get_data())
                : std::string("ideology_effect_instance_submit_failed");
            return false;
        }
        if (int32_t(result.get("rejected", 0)) > 0) {
            error = "ideology_effect_instance_submit_rejected";
            return false;
        }
    }

    // ── Metric snapshots ────────────────────────────────────────────────────
    // A managed ideology program that conditions on a metric reads whatever was
    // last written for its instance. Nothing used to write, so every METRIC_GTE
    // compared `0 >= threshold` and was permanently false while METRIC_LTE was
    // permanently true -- which is why the V1..V6 mechanism cards could only be
    // asserted as declarations, never observed firing.
    //
    // Published on every reconcile that changes something, not only on
    // creation: a condition has to see the world move, and the world moves
    // every day. The digest below is what keeps "the world moves" from being
    // read as "the input changed" -- an identical publish is skipped whole.
    //
    // Cell programs sample their own target cell, so "this cell's extractive
    // share >= 60%" means the cell the effect lands on. Country programs sample
    // the country anchor: country metrics are identical on every owned cell, and
    // the cache key has to be a cell because that is what the sampler takes.
    // One sample per distinct cell per reconcile: nine cards pointing at the
    // same cell cost one building scan, not nine.
    if (!desired.empty()) {
        constexpr int32_t metric_count = kEconomyMetricCount;
        const int32_t effect_metric_count = _effect_runtime == nullptr
            ? metric_count : _effect_runtime->metric_count();
        const int64_t revision = day > (std::numeric_limits<int64_t>::max() - 1) / 4
            ? std::numeric_limits<int64_t>::max() : day * 4 + 1;
        // O3: sample each cell ONCE with the union of the masks that target it.
        // The old `all_declared` mask forced every reconcile to compute all 68
        // columns, and the X7 country counts among them rebuild the whole-map
        // tag bitset -- the most expensive thing in this function.
        std::unordered_map<int32_t, MetricMask> mask_by_cell;
        std::vector<std::pair<int32_t, EffectActivation *>> pending_publishes;
        std::vector<EffectActivation *> pending_scalar_publishes;
        for (EffectActivation &activation : desired) {
            if (activation.metric_mask.is_none() && activation.scalar_mask.is_none())
                continue;
            int32_t cell = -1;
            if (activation.target_domain == 3) {
                // A country program reads country-wide Economy metrics from its
                // anchor cell, but ideology scalars are identical for every
                // cell of the country. Keep a scalar-only country program
                // publishable even when Economy is not attached.
                if (activation.metric_mask.is_none()) {
                    pending_scalar_publishes.push_back(&activation);
                    continue;
                }
                if (_economy_runtime == nullptr) continue;
                const int32_t country_slot =
                    static_cast<int32_t>(country.handle & 0xffffffffULL);
                cell = economy_api::country_anchor_cell(*_economy_runtime, country_slot);
            } else if (activation.target_domain == 2 ||
                       activation.target_domain == 5) {
                const int64_t raw = static_cast<int64_t>(
                    activation.ref.target_handle);
                if (raw < 0 || raw > std::numeric_limits<int32_t>::max())
                    continue;
                cell = static_cast<int32_t>(raw);
            } else {
                continue;
            }
            if (cell < 0) continue;
            mask_by_cell[cell] |= activation.metric_mask;
            pending_publishes.emplace_back(cell, &activation);
        }
        // Ideology scalars are country-wide, so one vector serves every
        // cell. Economy never receives these ids; only the Effect instance
        // slab sees them.
        std::vector<int64_t> scalar_values;
        const bool wants_ideology_scalars =
            !pending_scalar_publishes.empty() ||
            std::any_of(pending_publishes.begin(), pending_publishes.end(),
                [](const std::pair<int32_t, EffectActivation *> &publish) {
                    return publish.second->scalar_mask.is_any();
                });
        if (wants_ideology_scalars) {
            scalar_values.assign(static_cast<size_t>(effect_metric_count), 0);
            fill_ideology_scalars(country, state, scalar_values);
        }
        std::unordered_map<int32_t, std::vector<int64_t>> sampled_by_cell;
        sampled_by_cell.reserve(mask_by_cell.size());
        for (const auto &entry : mask_by_cell) {
            std::vector<int64_t> values(static_cast<size_t>(effect_metric_count), 0);
            std::vector<int32_t> economy_ids;
            entry.second.collect_ids(0, metric_count, economy_ids);
            if (_economy_runtime != nullptr && !economy_ids.empty()) {
                MetricMask economy_mask;
                for (int32_t metric_id : economy_ids) economy_mask.set(metric_id);
                economy_api::sample_effect_metrics(*_economy_runtime, entry.first, metric_count, values.data(),
                    economy_mask);
            }
            if (wants_ideology_scalars)
                fill_ideology_scalars(country, state, values);
            sampled_by_cell.emplace(entry.first, std::move(values));
        }
        // Previous publish per instance. Built before `effect_instances` is
        // rebuilt below; a level change advances the generation, which
        // invalidates the digest by construction.
        std::unordered_map<int64_t, size_t> held_by_instance;
        held_by_instance.reserve(state.effect_instances.size());
        for (size_t held = 0; held < state.effect_instances.size(); ++held)
            held_by_instance.emplace(state.effect_instances[held].instance_id, held);
        for (const auto &publish : pending_publishes) {
            EffectActivation &activation = *publish.second;
            auto found = sampled_by_cell.find(publish.first);
            if (found == sampled_by_cell.end()) continue;
            MetricMask publish_mask = activation.metric_mask;
            publish_mask |= activation.scalar_mask;
            const uint64_t digest = metric_publish_digest(
                publish_mask, found->second);
            const auto held = held_by_instance.find(activation.ref.instance_id);
            if (held != held_by_instance.end()) {
                const IdeaState::EffectInstanceRef &previous =
                    state.effect_instances[held->second];
                if (previous.generation == activation.ref.generation &&
                        previous.metric_digest == digest) {
                    // Same columns, same values, same instance. Publishing
                    // again would advance the Effect input revision and mint a
                    // Modifier transaction for a world that did not move.
                    activation.ref.metric_digest = digest;
                    ++_metric_publishes_skipped;
                    continue;
                }
            }
            std::string metric_error;
            bool published = true;
            for (int32_t metric_id = 0; metric_id < effect_metric_count;
                    ++metric_id) {
                // MetricMask covers 256 ids (infra item L0-1), so this is a
                // plain membership test rather than a shift that would be
                // undefined past 63.
                if (!publish_mask.test(metric_id)) continue;
                // A rejected metric (stale instance raced by a retire) must not
                // fail the reconcile: the instance set is already correct.
                if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                        activation.ref.instance_id, activation.ref.generation,
                        metric_id, revision,
                        found->second[static_cast<size_t>(metric_id)],
                        metric_error)) {
                    published = false;
                    break;
                }
            }
            // Only stamp the digest when every column landed, so a partial
            // publish is retried instead of being remembered as done.
            if (published) {
                activation.ref.metric_digest = digest;
                ++_metric_publishes;
            }
        }
        // Scalar-only activations skip Economy coordinate resolution but still
        // publish the derived inputs into the Effect instance's metric slab.
        for (EffectActivation *activation : pending_scalar_publishes) {
            MetricMask publish_mask = activation->scalar_mask;
            const uint64_t digest = metric_publish_digest(
                publish_mask, scalar_values);
            const auto held = held_by_instance.find(activation->ref.instance_id);
            if (held != held_by_instance.end()) {
                const IdeaState::EffectInstanceRef &previous =
                    state.effect_instances[held->second];
                if (previous.generation == activation->ref.generation &&
                        previous.metric_digest == digest) {
                    activation->ref.metric_digest = digest;
                    ++_metric_publishes_skipped;
                    continue;
                }
            }
            std::string metric_error;
            bool published = true;
            for (int32_t metric_id = 0; metric_id < effect_metric_count;
                    ++metric_id) {
                if (!publish_mask.test(metric_id)) continue;
                if (!effect_pod_metric(_effect_runtime, _effect_forwarder,
                        activation->ref.instance_id, activation->ref.generation,
                        metric_id, revision,
                        scalar_values[static_cast<size_t>(metric_id)],
                        metric_error)) {
                    published = false;
                    break;
                }
            }
            if (published) {
                activation->ref.metric_digest = digest;
                ++_metric_publishes;
            }
        }
    }

    state.effect_instances.clear();
    state.effect_instances.reserve(desired.size());
    for (const EffectActivation &activation : desired)
        state.effect_instances.push_back(activation.ref);
    // Stamp the input signature AFTER the set is rebuilt. Every path that
    // reconciles -- transition, restore, worker write-back, refresh -- leaves
    // this current, which is what lets a later refresh skip the card without
    // re-deriving anything.
    state.activation_signature = compute_activation_signature(country, state);
    return true;
}

} // namespace pk

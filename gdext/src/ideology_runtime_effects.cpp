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


bool NativeIdeologyRuntime::emit_templates(uint64_t country_handle, int32_t ideology_id,
        int32_t level, int32_t begin, int32_t count, bool remove, int64_t day,
        uint64_t salt,
        std::vector<EffectRuntime::ExternalEffectCommandPod> &commands,
        std::string &error) {
    if (count <= 0) return true;
    if (_effect_runtime == nullptr) { error = "ideology_effect_runtime_unavailable"; return false; }
    if (static_cast<int64_t>(commands.size()) + count >
            _max_transition_commands) {
        error = "ideology_transition_command_limit_exceeded";
        return false;
    }
    const std::vector<EffectTemplate> &templates = remove
        ? _persistent_templates : (salt == 0 ? _persistent_templates : _on_enter_templates);
    const int64_t tier_source_id = static_cast<int64_t>(
        (static_cast<uint64_t>(ideology_id + 1) << 32U) | static_cast<uint32_t>(level + 1));
    for (int32_t offset = 0; offset < count; ++offset) {
        const EffectTemplate &templ = templates[static_cast<size_t>(begin + offset)];
        // Persisted tier rows (salt 0) that resolve to a declarative managed
        // program are owned by reconcile_effect_activations(). Emitting them
        // here as well would apply the same effect twice. On-enter one-shots
        // keep using this batch: they are events, not state.
        if (salt == 0 && _effect_runtime != nullptr) {
            const std::string program = effect_program_key(templ.definition_key);
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!program.empty() &&
                    _effect_runtime->family_effect_metadata_pod(program, metadata))
                continue;
        }
        // The APPLY and its matching REMOVE must mint the SAME effect identity.
        //
        // `enqueue_external_effect_batch_pod` derives the instance id from
        // (source_type, transition_source_id, first.effect_id, first.fire_sequence)
        // and that instance id becomes the Modifier row's `source_id`
        // (`effect_runtime.cpp`: NATIVE_MODIFIER_IDEOLOGY sets
        // `source_id = source_instance->id`). A REMOVE is matched by
        // `remove_unique_command`, which keys `unique_instances` on
        // (definition, scope, scope_id, source_type, source_id) and answers
        // `already_removed` on a miss -- so any difference here leaves the applied
        // row alive while reporting success.
        //
        // `remove` used to be mixed into this hash, which guaranteed that
        // difference: every unequip retired the slot and the binding but left the
        // national Modifier row in place, and the stat kept its buffed value.
        uint64_t hash = 1469598103934665603ULL;
        hash = mixv(hash, country_handle); hash = mixv(hash, ideology_id); hash = mixv(hash, level);
        hash = mixv(hash, begin + offset); hash = mixv(hash, salt);
        const int64_t effect_id = static_cast<int64_t>(hash & 0x7fffffffffffffffULL);
        const int32_t opcode = remove ? 2 : templ.opcode; // Modifier COMMAND_REMOVE
        EffectRuntime::ExternalEffectCommandPod command;
        command.effect_id = effect_id;
        command.source_id = tier_source_id;
        command.program_key = "ideology.command";
        command.fire_sequence = static_cast<uint64_t>(offset + 1);
        command.action = templ.action;
        command.domain = templ.domain;
        command.opcode = opcode;
        command.resolved_value = templ.value_q16;
        command.duration_days = templ.duration_days;
        command.stacks = templ.stacks;
        command.command_key = templ.command_key;
        command.definition_key = templ.definition_key;
        command.payload = templ.payload;
        commands.push_back(std::move(command));
    }
    return true;
}

std::string NativeIdeologyRuntime::effect_program_key(
        const std::string &definition_key) {
    if (definition_key.empty()) return {};
    return "ideology.effect." + definition_key;
}

int64_t NativeIdeologyRuntime::effect_instance_id(uint64_t country_handle,
        int32_t ideology_id, uint8_t location, int32_t level,
        const std::string &program, uint64_t target_handle, int32_t layer) {
    // Pure function of the owning identity and the target. Anything that makes
    // the id depend on time, iteration order or counters leaks orphan
    // instances across a save/load round trip.
    uint64_t h = 1469598103934665603ULL;
    h = mixv(h, country_handle);
    h = mixv(h, ideology_id);
    h = mixv(h, location);
    h = mixv(h, level);
    h = mix(h, program.data(), program.size());
    h = mixv(h, target_handle);
    // Only for stacked programs. Mixing 0 unconditionally would renumber every
    // instance in every save, for an argument that is 0 for all of them.
    if (layer != 0) h = mixv(h, layer);
    const int64_t id = static_cast<int64_t>(h & 0x7fffffffffffffffULL);
    return id == 0 ? 1 : id;
}

bool NativeIdeologyRuntime::copy_source_state(const CountryState &country,
        const IdeaState &state, const IdeaState *&source) const {
    source = nullptr;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    if (_definitions[static_cast<size_t>(
            state.ideology_id)].copy_left_programs == 0)
        return false;
    if (state.location == INACTIVE || state.slot_index == 0)
        return false;
    const uint8_t wanted_slot = static_cast<uint8_t>(state.slot_index - 1);
    for (const IdeaState &candidate : country.ideas) {
        if (candidate.location != state.location ||
                candidate.slot_index != wanted_slot ||
                candidate.ideology_id == state.ideology_id)
            continue;
        source = &candidate;
        return true;
    }
    return false;
}

bool NativeIdeologyRuntime::copy_source_programs(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    const IdeaState *source = nullptr;
    if (!copy_source_state(country, state, source) || source == nullptr)
        return false;
    if (source->ideology_id < 0 ||
            source->ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    if (source->level < 0) return true;
    const Definition &definition = _definitions[
        static_cast<size_t>(source->ideology_id)];
    if (source->level >= definition.level_count) return true;
    // Legendary/rule cards are never copy sources, at any copier level. The
    // source program list is still the source's level list, never its live
    // Effect instance table.
    if (definition.copyable == 0) return true;
    const Level &row = _levels[
        static_cast<size_t>(definition.level_begin + source->level)];
    out.reserve(static_cast<size_t>(row.persistent_count));
    for (int32_t offset = 0; offset < row.persistent_count; ++offset)
        out.push_back(&_persistent_templates[
            static_cast<size_t>(row.persistent_begin + offset)]);
    return true;
}

void NativeIdeologyRuntime::collect_copied_legacy_templates(
        const CountryState &country, const IdeaState &state,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()) ||
            state.level < 0)
        return;
    const Definition &definition = _definitions[
        static_cast<size_t>(state.ideology_id)];
    if (state.level >= definition.level_count) return;
    const Level &own_level = _levels[
        static_cast<size_t>(definition.level_begin + state.level)];
    if (definition.copy_left_programs == 0) {
        out.reserve(static_cast<size_t>(own_level.persistent_count));
        for (int32_t offset = 0; offset < own_level.persistent_count; ++offset)
            out.push_back(&_persistent_templates[
                static_cast<size_t>(own_level.persistent_begin + offset)]);
        return;
    }
    // `emit_level_effects` is the legacy Modifier batch. Managed rows are owned by
    // the Effect reconciler, not this path, but the copier's own national/price
    // rows must remain active even when its managed list comes from a neighbour.
    for (int32_t offset = 0; offset < own_level.persistent_count; ++offset) {
        const EffectTemplate *templ = &_persistent_templates[
            static_cast<size_t>(own_level.persistent_begin + offset)];
        const std::string program = effect_program_key(templ->definition_key);
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (_effect_runtime != nullptr && !program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        out.push_back(templ);
    }
    std::vector<const EffectTemplate *> copied;
    if (!copy_source_programs(country, state, copied)) return;
    for (const EffectTemplate *templ : copied) {
        const std::string program = effect_program_key(templ->definition_key);
        EffectRuntime::FamilyEffectMetadataPod metadata;
        if (_effect_runtime != nullptr && !program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
            continue;
        out.push_back(templ);
    }
}

void NativeIdeologyRuntime::apply_fan_out_ownership_filter(
        int32_t source_cell, int32_t ownership_scope,
        std::vector<int32_t> &cells) const {
    if (_economy_runtime == nullptr) return;
    if (ownership_scope == EffectRuntime::OWNERSHIP_ANY) return;
    // The source came out of OWN_TERRITORY, so its owner IS the card's country.
    // Read per source rather than once: a multi-country world can have sources in
    // different slots once the collector is widened, and a cached slot would silently
    // mis-filter.
    const int32_t source_country = economy_api::cell_country_slot(*_economy_runtime, source_cell);
    if (source_country < 0) return;
    cells.erase(
        std::remove_if(cells.begin(), cells.end(),
            [&](int32_t target) {
                // Three cases, not two: an unowned target is neither own nor "another
                // country", and FOREIGN must not swallow neutral land.
                const pk::OwnershipRelation relation = pk::ownership_relation(
                    source_country, economy_api::cell_country_slot(*_economy_runtime, target));
                return !pk::ownership_accepts(ownership_scope, relation);
            }),
        cells.end());
}

void NativeIdeologyRuntime::apply_union_ownership_filter(
        int32_t country_slot, int32_t ownership_scope,
        std::vector<int32_t> &cells) const {
    if (_economy_runtime == nullptr) return;
    if (ownership_scope == EffectRuntime::OWNERSHIP_ANY) return;
    if (country_slot < 0) return;
    cells.erase(
        std::remove_if(cells.begin(), cells.end(),
            [&](int32_t target) {
                const pk::OwnershipRelation relation = pk::ownership_relation(
                    country_slot, economy_api::cell_country_slot(*_economy_runtime, target));
                return !pk::ownership_accepts(ownership_scope, relation);
            }),
        cells.end());
}


void NativeIdeologyRuntime::resolve_program_fold_terms(
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        const std::string &program,
        std::vector<DerivedProgramContribution::Term> &out,
        bool count_diagnostics) const {
    out.clear();
    std::vector<EffectRuntime::ProgramModifierCommand> commands;
    if (_effect_runtime == nullptr ||
            !_effect_runtime->program_modifier_commands(program, commands) ||
            _modifier_runtime == nullptr)
        return;
    for (const EffectRuntime::ProgramModifierCommand &command : commands) {
        std::vector<ModifierApi::ResolvedTerm> terms;
        if (!modifier_api::resolve_definition_terms(*_modifier_runtime,
                command.definition_key, terms))
            continue;  // counted by the materializer's missing_stat
        const int64_t magnitude = std::clamp<int64_t>(
            command.value_q16, 0, ModifierApi::MAX_MAGNITUDE_Q16);
        // ── M3: a metric-fed ramp must stay a LIVE function ──────
        //
        // `command.value_q16` is only meaningful when the magnitude is
        // a compile-time constant. For a Ramp it holds whatever the top
        // of the value stack was, NOT the program's output, so folding it
        // here would freeze the effect at the metric value seen during
        // materialise -- precisely the stale "threshold bucket" that
        // plan §15.5 forbids.
        //
        // So the term records WHICH metric it follows and at what scale,
        // and the materializer evaluates it per cell (the shipping stack
        // machine is already reachable through
        // `evaluate_program_magnitude_for_metrics`).
        //
        // A program reading several metrics would need a per-term
        // distinction no authored content currently requires; the FIRST
        // readable id is recorded so the choice is explicit rather than
        // silently made during evaluation.
        // A Ramp is exactly "not a compile-time constant AND reads a
        // metric": `value_mode != VALUE_CONSTANT` alone would also catch
        // a stack-top command that reads no metric, and
        // `metric_mask.is_any()` alone would catch a program whose
        // CONDITIONS read a metric while its magnitude stays constant.
        const bool ramp = command.value_mode !=
                EffectRuntime::VALUE_CONSTANT &&
            metadata.metric_mask.is_any();
        // Diagnostic: a ramp card that reports `taken=0 deferred=0` is
        // indistinguishable from one whose metrics never reached this
        // branch. These counters say which half of the condition failed.
        //
        // NOT counted when the caller only wants the digest: the applied-basis
        // rebuild runs on every capture, and a save must not move a number that
        // fixtures read as an exact measurement of the fold.
        if (count_diagnostics &&
                command.value_mode != EffectRuntime::VALUE_CONSTANT) {
            ++_ramp_candidates;
            if (metadata.metric_mask.is_any()) ++_ramp_metric_ok;
        }
        int32_t ramp_metric_id = -1;
        if (ramp) {
            for (int32_t id = 0; id < MetricMask::CAPACITY; ++id) {
                if (metadata.metric_mask.test(id)) {
                    ramp_metric_id = id;
                    break;
                }
            }
        }
        for (const ModifierApi::ResolvedTerm &term : terms) {
            DerivedProgramContribution::Term row;
            row.stat_id = term.stat_id;
            row.operation = term.operation;
            // Plan §5.4: `term.add * stacks * magnitude`. The sign
            // lives in the DEFINITION (a `.cut` twin is a SUBTRACT
            // term whose value is negative), never in the magnitude,
            // because magnitudes are clamped to [0, 4].
            const double scaled_magnitude =
                static_cast<double>(magnitude) /
                static_cast<double>(Q16_ONE);
            const double stacks =
                static_cast<double>(std::max(1, command.stacks));
            if (ramp && ramp_metric_id >= 0) {
                // The resolved term value becomes the SCALE; the
                // magnitude arrives per cell from the sample. `add` and
                // `factor` stay neutral here because the materializer
                // substitutes the sampled value for them -- leaving a
                // constant in `add` would double-count.
                row.magnitude_source =
                    DerivedProgramContribution::MagnitudeSource::RampMetric;
                row.metric_id = ramp_metric_id;
                // THE PROGRAM OWNS THE MAGNITUDE, not `term.value`.
                //
                // An earlier version scaled by `term.value * stacks / Q16`
                // and claimed in a comment that "the authored MIN/MAX inside
                // the instruction stream already bound the sample". That is
                // false: the derived path never executes the instruction
                // stream, so it sampled the RAW metric.
                //
                // Measured on `salt_monopoly_l1`
                // (`CONST 655 -> READ_METRIC -> CONST 983040 -> MIN -> MUL
                // -> EMIT`): the interpreter gives a constant 9825 while the
                // derived path gave 40 and 120 for the same two inputs, and
                // the contribution saturated the stat at its clamp_max
                // (M5-13). The key travels with the term so the materializer
                // can ask the stack machine instead.
                row.program_key = intern_program_key(program);
                row.ramp_scale = term.value * stacks /
                    static_cast<double>(Q16_ONE);
                row.ramp_has_ceil = false;
                row.add = 0.0;
                row.factor = 1.0;
            } else {
                row.add = term.operation == ModifierApi::ADD
                    ? term.value * stacks * scaled_magnitude : 0.0;
                row.factor = term.operation == ModifierApi::ADD
                    ? 1.0 : simulation_math::pow(term.value, stacks);
            }
            out.push_back(row);
        }
    }
}

bool NativeIdeologyRuntime::resolve_contribution_templates(
        const CountryState &country, const IdeaState &state,
        int32_t &contribution_level,
        std::vector<const EffectTemplate *> &out) const {
    out.clear();
    contribution_level = -1;
    if (state.location == INACTIVE) return false;
    if (state.ideology_id < 0 ||
            state.ideology_id >= static_cast<int32_t>(_definitions.size()))
        return false;
    const Definition &definition =
        _definitions[static_cast<size_t>(state.ideology_id)];
    // ── WHICH LEVEL DOES A PENDING CARD CONTRIBUTE? (plan §10.1) ─────────────
    //
    // "pending 期间使用旧基础": a pending TRANSITION serves the previous level, and a
    // pending EQUIP has `previous_location == INACTIVE`, i.e. the card was not
    // equipped before, so it contributes NOTHING until its ACK lands.
    int32_t level = state.level;
    if (state.transition.active != 0) {
        if (state.transition.previous_location == INACTIVE) return false;
        if (state.transition.previous_level < 0) return false;
        level = state.transition.previous_level;
    }
    if (level < 0 || level >= definition.level_count) return false;
    contribution_level = level;
    if (definition.copy_left_programs != 0) {
        // A copier never falls back to its own managed list. No left slot (or
        // a noncopyable source) means it has no managed activations.
        (void)copy_source_programs(country, state, out);
    } else {
        const Level &row = _levels[
            static_cast<size_t>(definition.level_begin + level)];
        out.reserve(static_cast<size_t>(row.persistent_count));
        for (int32_t offset = 0; offset < row.persistent_count; ++offset)
            out.push_back(&_persistent_templates[
                static_cast<size_t>(row.persistent_begin + offset)]);
    }
    return true;
}





} // namespace pk

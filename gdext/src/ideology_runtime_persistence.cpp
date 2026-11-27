#include "ideology_runtime.h"
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
constexpr uint32_t DERIVED_PROJECTION_MARKER = 0x31504344u; // DCP1
void append_derived_projection(std::vector<uint8_t> &out,
        const DerivedCellFront &front,
        const std::vector<DerivedProgramContribution> &targets) {
    append_le(out, DERIVED_PROJECTION_MARKER);
    append_le(out, front.generation);
    append_vec(out, front.stat_versions);
    append_le<uint32_t>(out, front.rows.size());
    for (const DerivedCellStatRow &row : front.rows) {
        append_le(out, row.stat_id);
        append_vec(out, row.cells);
        for (const DerivedCellContribution &term : row.contributions) {
            append_le(out, term.source_country);
            append_le(out, term.contributor_count);
            append_le(out, term.sum_add);
            append_le(out, term.product_nonzero);
            append_le(out, term.zero_factor_count);
        }
    }
    append_le<uint32_t>(out, targets.size());
    for (const DerivedProgramContribution &target : targets) {
        append_le(out, target.source_country);
        append_le(out, target.ideology_id);
        append_le(out, target.level);
        append_le(out, target.program_hash);
        append_vec(out, target.cells);
    }
}

bool read_derived_projection(const uint8_t *data, size_t size, size_t &cursor,
        DerivedCellFront &front, std::vector<DerivedProgramContribution> &targets) {
    uint32_t marker = 0, stat_count = 0, target_count = 0;
    if (!read_le(data, size, cursor, marker) || marker != DERIVED_PROJECTION_MARKER ||
        !read_le(data, size, cursor, front.generation) ||
        !read_vec(data, size, cursor, front.stat_versions, size / sizeof(uint64_t)) ||
        !read_le(data, size, cursor, stat_count) || stat_count > front.stat_versions.size())
        return false;
    for (uint32_t i = 0; i < stat_count; ++i) {
        DerivedCellStatRow row;
        if (!read_le(data, size, cursor, row.stat_id) ||
            !read_vec(data, size, cursor, row.cells, size / sizeof(int32_t)))
            return false;
        for (size_t cell = 0; cell < row.cells.size(); ++cell) {
            DerivedCellContribution term;
            if (!read_le(data, size, cursor, term.source_country) ||
                !read_le(data, size, cursor, term.contributor_count) ||
                !read_le(data, size, cursor, term.sum_add) ||
                !read_le(data, size, cursor, term.product_nonzero) ||
                !read_le(data, size, cursor, term.zero_factor_count))
                return false;
            row.contributions.push_back(term);
        }
        front.rows.push_back(std::move(row));
    }
    if (!read_le(data, size, cursor, target_count)) return false;
    for (uint32_t i = 0; i < target_count; ++i) {
        DerivedProgramContribution target;
        target.backend = CellProgramBackend::DerivedCell;
        if (!read_le(data, size, cursor, target.source_country) ||
            !read_le(data, size, cursor, target.ideology_id) ||
            !read_le(data, size, cursor, target.level) ||
            !read_le(data, size, cursor, target.program_hash) ||
            !read_vec(data, size, cursor, target.cells, size / sizeof(int32_t)))
            return false;
        targets.push_back(std::move(target));
    }
    return true;
}
} // namespace

// One line explaining WHY a scalar comparison failed, so the named refusal says what
// disagreed. `cross_domain` rows are reported too: a refusal that was mostly about
// excluded rows is a different finding from a value that moved.
static std::string describe_local_scalar_mismatch(
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &restored,
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &rebuilt,
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &cross_domain) {
    std::string out = "payload_rows=" + std::to_string(restored.size()) +
        " rebuilt_rows=" + std::to_string(rebuilt.size()) +
        " cross_domain_rows=" + std::to_string(cross_domain.size());
    const auto skip = [&cross_domain](
            const NativeIdeologyRuntime::LocalScalarValue &row) {
        for (const NativeIdeologyRuntime::LocalScalarValue &candidate : cross_domain)
            if (candidate.country_handle == row.country_handle &&
                    candidate.metric_id == row.metric_id)
                return true;
        return false;
    };
    size_t restored_index = 0;
    size_t rebuilt_index = 0;
    int32_t reported = 0;
    while (reported < 3) {
        while (restored_index < restored.size() && skip(restored[restored_index]))
            ++restored_index;
        while (rebuilt_index < rebuilt.size() && skip(rebuilt[rebuilt_index]))
            ++rebuilt_index;
        if (restored_index == restored.size() || rebuilt_index == rebuilt.size())
            break;
        const NativeIdeologyRuntime::LocalScalarValue &left =
            restored[restored_index];
        const NativeIdeologyRuntime::LocalScalarValue &right = rebuilt[rebuilt_index];
        if (left != right) {
            out += " | diff#";
            out += std::to_string(reported);
            out += " payload(handle=" + std::to_string(left.country_handle) +
                " metric=" + std::to_string(left.metric_id) +
                " value=" + std::to_string(left.value_q16) + ")";
            out += " rebuilt(handle=" + std::to_string(right.country_handle) +
                " metric=" + std::to_string(right.metric_id) +
                " value=" + std::to_string(right.value_q16) + ")";
            ++reported;
        }
        ++restored_index;
        ++rebuilt_index;
    }
    if (reported == 0 && restored.size() != rebuilt.size())
        out += " | row counts differ (presence, not value)";
    return out;
}

// Do the payload's rows agree with a fresh derivation, ignoring the rows whose value is
// NOT a function of this payload plus the catalogs? `cross_domain` is at most one row per
// country (the era term), so the linear skip test costs nothing; both inputs are
// (country, metric)-sorted by the rebuild.
//
// Anything NOT named in `cross_domain` must match exactly, including PRESENCE: a row the
// rebuild did not produce (a metric the catalogs no longer declare, or one whose key is
// gone) is a difference, which is the whole point of the content check.
static bool local_scalar_basis_agrees(
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &restored,
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &rebuilt,
        const std::vector<NativeIdeologyRuntime::LocalScalarValue> &cross_domain) {
    const auto skip = [&cross_domain](
            const NativeIdeologyRuntime::LocalScalarValue &row) {
        for (const NativeIdeologyRuntime::LocalScalarValue &candidate : cross_domain)
            if (candidate.country_handle == row.country_handle &&
                    candidate.metric_id == row.metric_id)
                return true;
        return false;
    };
    size_t restored_index = 0;
    size_t rebuilt_index = 0;
    while (true) {
        while (restored_index < restored.size() && skip(restored[restored_index]))
            ++restored_index;
        while (rebuilt_index < rebuilt.size() && skip(rebuilt[rebuilt_index]))
            ++rebuilt_index;
        if (restored_index == restored.size() && rebuilt_index == rebuilt.size())
            return true;
        if (restored_index == restored.size() || rebuilt_index == rebuilt.size())
            return false;
        if (restored[restored_index] != rebuilt[rebuilt_index]) return false;
        ++restored_index;
        ++rebuilt_index;
    }
}


#include "ideology_runtime_persistence_section_pod_export.inc"


uint64_t NativeIdeologyRuntime::compute_execution_contract_hash() const {
    uint64_t hash = 1469598103934665603ULL;
    // 1-4: the rule versions (plan §11.5 bullets 1-4).
    hash = mixv(hash, kExecutionSemanticsVersion);
    hash = mixv(hash, kProgramBackendVersion);
    hash = mixv(hash, kSelectorUnboundedVersion);
    hash = mixv(hash, kSourceCountDecodeVersion);
    hash = mixv(hash, kEvaluatorVersion);
    hash = mixv(hash, kEligibilityVersion);
    // 5: the participating compile identities. The ideology catalog hash already covers
    // routes / schools / stat keys / capacities / weights; the Effect and Modifier hashes
    // cover the program and modifier catalogs this layer folds against. A 0 here means
    // that side is absent, and is hashed as such rather than skipped -- "no Effect
    // runtime" is a different contract from "an Effect runtime with hash 0".
    hash = mixv(hash, _catalog_hash);
    hash = mixv(hash, _effect_runtime != nullptr
        ? _effect_runtime->catalog_hash() : uint64_t{0});
    hash = mixv(hash, _modifier_runtime != nullptr
        ? modifier_api::catalog_hash(*_modifier_runtime) : uint64_t{0});
    return hash;
}


uint64_t NativeIdeologyRuntime::compute_catalog_hash() const {
    uint64_t hash = 1469598103934665603ULL;
    // Route ids feed ideology-local scalars and are therefore part of the
    // catalog contract, not presentation metadata.
    for (const std::string &route : _route_keys)
        hash = mix(hash, route.data(), route.size());
    for (const std::string &school : _school_keys)
        hash = mix(hash, school.data(), school.size());
    for (const std::string &stat : _school_strength_factor_stat_keys)
        hash = mix(hash, stat.data(), stat.size());
    for (const Definition &definition : _definitions)
        hash = mixv(hash, definition.route_mask);
    hash = mixv(hash, _ideology_capacity);
    hash = mixv(hash, _spirit_capacity);
    hash = mixv(hash, _offer_cost_q16);
    hash = mixv(hash, _starting_points_q16);
    hash = mixv(hash, _political_class_hash);
    hash = mixv(hash, _opinion_owner_influence_weight);
    hash = mixv(hash, _opinion_funds_per_influence);
    hash = mixv(hash, _ideology_capacity_max);
    hash = mixv(hash, _spirit_capacity_max);
    hash = mixv(hash, _offer_cost_growth_percent);
    hash = mixv(hash, _offer_cost_max_q16);
    hash = mixv(hash, _reroll_cost_percent);
    hash = mixv(hash, _point_population_weight_q16);
    hash = mixv(hash, _point_building_weight_q16);
    hash = mixv(hash, _point_trade_weight_q16);
    hash = mixv(hash, _point_gain_cap_q16);
    hash = mix(hash, _point_gain_stat_key.data(), _point_gain_stat_key.size());
    hash = mix(hash, _point_population_factor_stat_key.data(),
               _point_population_factor_stat_key.size());
    hash = mix(hash, _point_building_factor_stat_key.data(),
               _point_building_factor_stat_key.size());
    hash = mix(hash, _point_trade_factor_stat_key.data(),
               _point_trade_factor_stat_key.size());
    hash = mix(hash, _opinion_factor_floor_stat_key.data(),
               _opinion_factor_floor_stat_key.size());
    hash = mix(hash, _understanding_gain_stat_key.data(),
               _understanding_gain_stat_key.size());
    hash = mix(hash, _reroll_cost_stat_key.data(), _reroll_cost_stat_key.size());
    // The draw-side knobs belong in the hash for the same reason the decay curve
    // does: a peer that resolves a different floor or row count draws a different
    // card from the same seed, and a mismatched hash is the only place that is
    // ever reported by name instead of as a replay divergence days later.
    hash = mix(hash, _era_decay_floor_stat_key.data(),
               _era_decay_floor_stat_key.size());
    hash = mix(hash, _offer_choice_bonus_stat_key.data(),
               _offer_choice_bonus_stat_key.size());
    hash = mixv(hash, _refine_weight_bp);
    hash = mixv(hash, _refine_understanding_q16);
    // Draw weighting is part of the catalog contract: two peers that disagree on
    // the decay curve would silently draw different cards from the same seed.
    for (const int32_t decay : _era_decay_bp) hash = mixv(hash, decay);
    for (const int32_t milestone : _era_milestone_technologies)
        hash = mixv(hash, milestone);
    for (const CapacityUnlock &unlock : _capacity_unlocks) {
        hash = mixv(hash, unlock.technology_id);
        hash = mixv(hash, unlock.ideology_delta);
        hash = mixv(hash, unlock.spirit_delta);
    }
    for (const Definition &definition : _definitions) {
        hash = mix(hash, definition.stable_id.data(),
            definition.stable_id.size());
        hash = mixv(hash, definition.acquisition);
        hash = mixv(hash, definition.copy_left_programs);
        hash = mixv(hash, definition.copyable);
        hash = mixv(hash, definition.school_index);
        hash = mixv(hash, definition.rarity_weight);
        hash = mixv(hash, definition.ideology_cost);
        hash = mixv(hash, definition.spirit_cost);
        hash = mixv(hash, definition.min_spirit_level);
        hash = mixv(hash, definition.stance_begin);
        hash = mixv(hash, definition.stance_count);
        for (const int32_t threshold :
                definition.support_threshold_q16)
            hash = mixv(hash, threshold);
        hash = mixv(hash, definition.exclusion_group_id);
        hash = mixv(hash, definition.era_index);
    }
    for (const Level &level : _levels) {
        hash = mixv(hash, level.threshold_q16);
        hash = mixv(hash, level.daily_understanding_q16);
    }
    for (const ClassStance &stance : _class_stances) {
        hash = mixv(hash, stance.class_index);
        for (const int32_t value : stance.stance_q16)
            hash = mixv(hash, value);
        for (const int32_t value : stance.critical_min_q16)
            hash = mixv(hash, value);
    }
    for (const SynergyRequirement &requirement :
            _synergy_requirements) {
        hash = mixv(hash, requirement.ideology_id);
        hash = mixv(hash, requirement.minimum_level);
        hash = mixv(hash, requirement.location_mask);
    }
    for (const Synergy &synergy : _synergies) {
        hash = mixv(hash, synergy.requirement_begin);
        hash = mixv(hash, synergy.requirement_count);
        hash = mixv(hash, synergy.effect_begin);
        hash = mixv(hash, synergy.effect_count);
        hash = mixv(hash, synergy.min_count);
        hash = mixv(hash, synergy.override_begin);
        hash = mixv(hash, synergy.override_count);
    }
    // The override rows themselves are part of the contract: two peers that
    // disagree on how hard a synergy rewrites a program would produce different
    // modifier values from the same state and never report why.
    for (const SynergyOverride &override : _synergy_overrides) {
        hash = mixv(hash, override.match_kind);
        hash = mixv(hash, override.field);
        hash = mixv(hash, override.value);
        hash = mix(hash, override.match_value.data(),
            override.match_value.size());
        hash = mix(hash, override.tag_name.data(), override.tag_name.size());
    }
    return hash;
}


// Hash of the state this runtime currently holds, basis included.
//
// Capture and restore deliberately call `compute_state_hash_with` instead: both of them
// need the rows for the payload anyway, and re-deriving them here would resolve every
// program twice on a save. This entry point is the honest "what does my state hash to"
// for anything that has no rows in hand -- and it is what makes "the hash covers the
// basis" true by construction rather than by the caller remembering to pass them.
uint64_t NativeIdeologyRuntime::compute_state_hash() const {
    std::vector<AppliedProgramBasis> basis;
    rebuild_applied_program_basis(_countries, basis);
    std::vector<LocalScalarValue> scalars;
    rebuild_local_scalar_basis(_countries, scalars);
    return compute_state_hash_with(basis, scalars, _derived_basis_sample_day);
}


uint64_t NativeIdeologyRuntime::compute_state_hash_with(
        const std::vector<AppliedProgramBasis> &basis,
        const std::vector<LocalScalarValue> &scalars,
        int64_t sample_day) const {
    uint64_t hash = _catalog_hash;
    // NOTE: `_execution_contract_hash` is deliberately NOT mixed in here.
    //
    // It is validated explicitly on restore with its own named reason
    // (`cell_program_execution_contract_mismatch`), which is what plan §11.5 requires:
    // "该身份进入整包兼容检查 … 旧档默认明确拒读". Folding it into the state hash as
    // well was belt-and-braces, and it made the hash sensitive to any difference between
    // the capture and restore runtimes -- which refused a fixture that captures and
    // restores on the same runtime for reasons unrelated to the contract. Two checks for
    // one property, one of which can misfire, is worse than one precise check.
    // Plan §9.3 basis dates. Hashed because they are now persisted: an unhashed
    // persisted scalar is one a corrupted payload can rewrite undetected.
    hash = mixv(hash, _derived_basis_confirmed_day);
    hash = mixv(hash, _derived_basis_eligible_day);
    for (const CountryState &country : _countries) {
        hash = mixv(hash, country.handle); hash = mixv(hash, country.ideology_points_q16);
        hash = mixv(hash, country.rng_state); hash = mixv(hash, country.draw_sequence);
        hash = mixv(hash, country.free_draws);
        hash = mixv(hash, country.points_revision); hash = mixv(hash, country.baseline_ready);
        hash = mixv(hash, country.baseline_population); hash = mixv(hash, country.baseline_buildings);
        hash = mixv(hash, country.lifetime_points_q16); hash = mixv(hash, country.ledger.gain_q16);
        hash = mixv(hash, country.history_count); hash = mixv(hash, country.history_head);
        hash = mixv(hash, country.unlocked_era);
        for (int64_t value : country.history_q16) hash = mixv(hash, value);
        for (uint64_t word : country.known_bits) hash = mixv(hash, word);
        for (uint64_t word : country.gate_bits) hash = mixv(hash, word);
        for (const IdeaState &state : country.ideas) {
            hash = mixv(hash, state.ideology_id); hash = mixv(hash, state.understanding_q16);
            hash = mixv(hash, state.level); hash = mixv(hash, state.entered_levels);
            hash = mixv(hash, state.generation); hash = mixv(hash, state.location);
            hash = mixv(hash, state.slot_index);
            hash = mixv(hash, state.binding_id); hash = mixv(hash, state.binding_generation);
            hash = mixv(hash, state.binding_signature); hash = mixv(hash, state.binding_program_hash);
            hash = mixv(hash, state.transition.active);
            hash = mixv(hash, state.transition.previous_level);
            hash = mixv(hash, state.transition.previous_entered_levels);
            hash = mixv(hash, state.transition.previous_generation);
            hash = mixv(hash, state.transition.previous_location);
            hash = mixv(hash, state.transition.previous_slot_index);
            hash = mixv(hash, state.transition.entered_on_success);
            for (int64_t transaction_id : state.transition.transaction_ids)
                hash = mixv(hash, transaction_id);
        }
    }
    // Plan §18.2: the applied-program basis is persisted, so it is hashed too. An
    // unhashed persisted block is one a corrupted payload can rewrite undetected --
    // which is exactly the argument the two basis dates above already make.
    hash = mix_applied_program_basis(hash, basis);
    // Plan §18.5: the local scalar basis and the sample day the projection was built
    // from. Same argument. The sample day is hashed here rather than beside the two
    // dates above because it belongs to the same record as these rows: the rows are
    // WHAT the projection read, the day is WHEN.
    hash = mix_local_scalar_basis(hash, scalars);
    hash = mixv(hash, sample_day);
    return hash;
}


uint64_t NativeIdeologyRuntime::mix_applied_program_basis(
        uint64_t hash, const std::vector<AppliedProgramBasis> &basis) {
    hash = mixv(hash, static_cast<uint64_t>(basis.size()));
    for (const AppliedProgramBasis &row : basis) {
        hash = mixv(hash, row.country_handle);
        hash = mixv(hash, static_cast<uint64_t>(row.program_key.size()));
        hash = mix(hash, row.program_key.data(), row.program_key.size());
        hash = mixv(hash, static_cast<int32_t>(row.selector_kind));
        hash = mixv(hash, static_cast<uint64_t>(row.selector_id.size()));
        hash = mix(hash, row.selector_id.data(), row.selector_id.size());
        hash = mixv(hash, row.selector_param[0]);
        hash = mixv(hash, row.selector_param[1]);
        hash = mixv(hash, row.terms_digest);
    }
    return hash;
}


bool NativeIdeologyRuntime::build_applied_program_basis_row(
        const CountryState &country, const IdeaState &state,
        const std::string &program,
        const EffectRuntime::FamilyEffectMetadataPod &metadata,
        AppliedProgramBasis &out) const {
    out = AppliedProgramBasis{};
    if (_effect_runtime == nullptr || program.empty()) return false;
    // The SAME eligibility decision the collector consults (I01), so a program the
    // instance path owns can never appear in the basis and vice versa.
    const CellProgramFacts facts = cell_program_facts_for(program, metadata, state);
    const CellProgramDecision backend = decide_cell_program_backend(facts);
    if (backend.backend != CellProgramBackend::DerivedCell) return false;
    if (!cell_program_rollout_enabled(metadata.target_selector_kind)) return false;
    // The EFFECTIVE selector: a country's active synergy can rewrite the selector
    // kind, its tag and its parameters, so recording the authored one would let two
    // worlds with different synergy rows look identical here.
    const EffectRuntime::FamilyEffectMetadataPod effective =
        effective_selector_metadata(country, program, metadata);
    std::vector<DerivedProgramContribution::Term> terms;
    resolve_program_fold_terms(metadata, program, terms, false);
    out.country_handle = country.handle;
    out.program_key = program;
    out.selector_kind = effective.target_selector_kind;
    out.selector_id = effective.target_selector_id;
    out.selector_param[0] = effective.target_selector_param[0];
    out.selector_param[1] = effective.target_selector_param[1];
    out.terms_digest = 1469598103934665603ULL;
    out.terms_digest = mixv(out.terms_digest,
        static_cast<uint64_t>(terms.size()));
    for (const DerivedProgramContribution::Term &term : terms) {
        out.terms_digest = mixv(out.terms_digest,
            static_cast<int32_t>(term.stat_id));
        out.terms_digest = mixv(out.terms_digest,
            static_cast<int32_t>(term.operation));
        out.terms_digest = mixv(out.terms_digest, basis_quantise(term.add));
        out.terms_digest = mixv(out.terms_digest, basis_quantise(term.factor));
        out.terms_digest = mixv(out.terms_digest,
            static_cast<uint32_t>(term.magnitude_source));
        out.terms_digest = mixv(out.terms_digest,
            static_cast<int32_t>(term.metric_id));
        out.terms_digest = mixv(out.terms_digest,
            basis_quantise(term.ramp_scale));
        out.terms_digest = mixv(out.terms_digest,
            basis_quantise(term.ramp_floor));
        out.terms_digest = mixv(out.terms_digest,
            basis_quantise(term.ramp_ceil));
        out.terms_digest = mixv(out.terms_digest,
            static_cast<uint8_t>(term.ramp_has_ceil ? 1 : 0));
        // The ramp's program key decides WHICH instruction stream produces the
        // magnitude, so a change there is a semantic change even when every number
        // above happens to match.
        const std::string empty;
        const std::string &key = term.program_key != nullptr
            ? *term.program_key : empty;
        out.terms_digest = mixv(out.terms_digest,
            static_cast<uint64_t>(key.size()));
        out.terms_digest = mix(out.terms_digest, key.data(), key.size());
    }
    return true;
}


void NativeIdeologyRuntime::rebuild_applied_program_basis(
        const std::vector<CountryState> &countries,
        std::vector<AppliedProgramBasis> &out) const {
    out.clear();
    if (_effect_runtime == nullptr) return;
    std::vector<const EffectTemplate *> templates;
    for (const CountryState &country : countries) {
        if (country.handle == 0) continue;
        for (const IdeaState &state : country.ideas) {
            int32_t contribution_level = -1;
            if (!resolve_contribution_templates(country, state,
                    contribution_level, templates))
                continue;
            for (const EffectTemplate *templ_ptr : templates) {
                if (templ_ptr == nullptr) continue;
                const std::string program =
                    effect_program_key(templ_ptr->definition_key);
                if (program.empty()) continue;
                EffectRuntime::FamilyEffectMetadataPod metadata;
                if (!_effect_runtime->family_effect_metadata_pod(program, metadata))
                    continue;
                AppliedProgramBasis row;
                if (!build_applied_program_basis_row(country, state, program,
                        metadata, row))
                    continue;
                out.push_back(std::move(row));
            }
        }
    }
    // Deterministic order and one row per (country, program). `stable_sort` keeps
    // the iteration order for a collision, so two cards carrying the same program
    // resolve the same way on both sides of a save -- a plain `sort` would let the
    // winner depend on the sort's internals.
    std::stable_sort(out.begin(), out.end(),
        [](const AppliedProgramBasis &lhs, const AppliedProgramBasis &rhs) {
            if (lhs.country_handle != rhs.country_handle)
                return lhs.country_handle < rhs.country_handle;
            return lhs.program_key < rhs.program_key;
        });
    out.erase(std::unique(out.begin(), out.end(),
        [](const AppliedProgramBasis &lhs, const AppliedProgramBasis &rhs) {
            return lhs.country_handle == rhs.country_handle &&
                lhs.program_key == rhs.program_key;
        }), out.end());
}


PackedByteArray NativeIdeologyRuntime::capture() const {
    PackedByteArray out;
    if (!_configured) return out;
    // One derivation, used twice: the payload's basis block AND the state hash that
    // covers it. Resolving every program twice on a save is the only alternative.
    std::vector<AppliedProgramBasis> basis;
    rebuild_applied_program_basis(_countries, basis);
    // §18.5: the same treatment for the local scalar basis -- re-derived from the
    // payload's own country rows through the CURRENT catalogs, never read from
    // `_local_scalar_basis`. That member records what the last RESTORE installed and
    // goes stale the moment a card is equipped or levelled, which would make a
    // payload refuse its own world.
    std::vector<LocalScalarValue> scalars;
    rebuild_local_scalar_basis(_countries, scalars);
    std::vector<uint8_t> bytes;
    append_le<uint32_t>(bytes, SAVE_MAGIC); append_le<int32_t>(bytes, SAVE_SCHEMA_VERSION);
    append_le<uint64_t>(bytes, _catalog_hash); append_le<int64_t>(bytes, _last_day);
    append_le<uint64_t>(bytes, _submit_order);
    append_le<uint64_t>(bytes,
        compute_state_hash_with(basis, scalars, _derived_basis_sample_day));
    std::vector<std::pair<int32_t, int64_t>> high_watermarks(
        _producer_high_watermarks.begin(), _producer_high_watermarks.end());
    std::sort(high_watermarks.begin(), high_watermarks.end());
    append_le<uint64_t>(bytes, static_cast<uint64_t>(high_watermarks.size()));
    for (const auto &entry : high_watermarks) {
        append_le<int32_t>(bytes, entry.first);
        append_le<int64_t>(bytes, entry.second);
    }
    append_le<uint64_t>(bytes, _points_revision_seen);
    append_le<uint8_t>(bytes, _worker_origin ? 1u : 0u);
    append_le<uint64_t>(bytes, static_cast<uint64_t>(_countries.size()));
    for (const CountryState &country : _countries) {
        append_le<uint64_t>(bytes, country.handle); append_le<int64_t>(bytes, country.ideology_points_q16);
        append_le<int32_t>(bytes, country.unlocked_era);
        append_le<uint64_t>(bytes, country.rng_state); append_le<uint64_t>(bytes, country.draw_sequence);
        append_le<uint16_t>(bytes, country.free_draws);
        append_le<uint64_t>(bytes, country.points_revision);
        append_le<uint8_t>(bytes, country.baseline_ready);
        append_le<uint8_t>(bytes, country.history_count);
        append_le<uint8_t>(bytes, country.history_head);
        append_le<int64_t>(bytes, country.baseline_population);
        append_le<int64_t>(bytes, country.baseline_buildings);
        append_le<int64_t>(bytes, country.lifetime_points_q16);
    append_le<int64_t>(bytes, country.trade_paid_day);
        append_le<int64_t>(bytes, country.ledger.population_q16);
        append_le<int64_t>(bytes, country.ledger.building_q16);
        append_le<int64_t>(bytes, country.ledger.trade_q16);
        append_le<int32_t>(bytes, country.ledger.opinion_factor_q16);
        append_le<int32_t>(bytes, country.ledger.gain_factor_q16);
        append_le<int64_t>(bytes, country.ledger.gain_q16);
        append_le<int64_t>(bytes, country.ledger.day);
        for (int64_t value : country.history_q16) append_le<int64_t>(bytes, value);
        append_vec(bytes, country.known_bits); append_vec(bytes, country.gate_bits);
        append_le<uint32_t>(bytes, country.offer.generation);
        append_le<uint8_t>(bytes, country.offer.active);
        append_le<uint8_t>(bytes, country.offer.choice_count);
        // Always the full capacity, never `choice_count` ints: a save written by
        // one build has to be readable by a build whose OFFER_CHOICE_CAPACITY
        // differs, and a variable-length row would silently shift every field
        // after it. The schema version covers changes to the capacity itself.
        for (int32_t ideology_id : country.offer.ideology_ids) append_le<int32_t>(bytes, ideology_id);
        append_vec(bytes, country.banned_bits);
        append_le<uint64_t>(bytes, static_cast<uint64_t>(country.ideas.size()));
        for (const IdeaState &state : country.ideas) {
            append_le<int32_t>(bytes, state.ideology_id); append_le<int64_t>(bytes, state.understanding_q16);
            append_le<int32_t>(bytes, state.level); append_le<uint64_t>(bytes, state.entered_levels);
            append_le<uint32_t>(bytes, state.generation);
            append_le<uint8_t>(bytes, state.location);
            append_le<uint8_t>(bytes, state.slot_index);
            append_le<int64_t>(bytes, state.binding_id);
            append_le<uint32_t>(bytes, state.binding_generation);
            append_le<uint64_t>(bytes, state.binding_signature);
            append_le<uint64_t>(bytes, state.binding_program_hash);
            append_le<uint8_t>(bytes, state.transition.active);
            append_le<int32_t>(bytes, state.transition.producer_id);
            append_le<int64_t>(bytes, state.transition.command_sequence);
            append_le<int32_t>(bytes, state.transition.command_opcode);
            append_le<int32_t>(bytes, state.transition.previous_level);
            append_le<uint64_t>(bytes, state.transition.previous_entered_levels);
            append_le<uint32_t>(bytes, state.transition.previous_generation);
            append_le<uint8_t>(bytes, state.transition.previous_location);
            append_le<uint8_t>(bytes, state.transition.previous_slot_index);
            append_le<uint64_t>(bytes, state.transition.entered_on_success);
            append_le<uint64_t>(bytes, static_cast<uint64_t>(state.transition.transaction_ids.size()));
            for (int64_t transaction_id : state.transition.transaction_ids) append_le<int64_t>(bytes, transaction_id);
            append_le<uint64_t>(bytes, static_cast<uint64_t>(
                state.transition.changed_synergy_ids.size()));
            for (size_t index = 0;
                    index < state.transition.changed_synergy_ids.size();
                    ++index) {
                append_le<int32_t>(bytes,
                    state.transition.changed_synergy_ids[index]);
                append_le<uint8_t>(bytes,
                    index < state.transition.previous_synergy_active.size()
                    ? state.transition.previous_synergy_active[index] : 0);
            }
            // Reconciled Effect instances owned by this idea. Persisted so a load
            // can prove the EffectRuntime still holds them; the ids are a pure
            // function of the owning identity, so a mismatch is real data loss
            // and must fail loudly instead of silently dropping the card's effect.
            append_le<uint64_t>(bytes,
                static_cast<uint64_t>(state.effect_instances.size()));
            for (const IdeaState::EffectInstanceRef &ref : state.effect_instances) {
                append_le<uint64_t>(bytes, ref.program_hash);
                append_le<uint64_t>(bytes, ref.target_handle);
                append_le<uint32_t>(bytes, ref.target_generation);
                append_le<int64_t>(bytes, ref.instance_id);
                append_le<uint32_t>(bytes, ref.generation);
            }
        }
    }
    append_le<uint64_t>(bytes, static_cast<uint64_t>(pending_command_count()));
    for (size_t command_index = _command_cursor;
            command_index < _commands.size(); ++command_index) {
        const Command &command = _commands[command_index];
        append_le<int32_t>(bytes, command.opcode); append_le<int64_t>(bytes, command.effective_day);
        append_le<int32_t>(bytes, command.producer_id);
        append_le<int32_t>(bytes, command.source_priority); append_le<int64_t>(bytes, command.sequence);
        append_le<uint64_t>(bytes, command.country_handle); append_le<int32_t>(bytes, command.ideology_id);
        append_le<int64_t>(bytes, command.value_q16); append_le<uint32_t>(bytes, command.offer_generation);
        append_le<int32_t>(bytes, command.choice_index); append_le<int32_t>(bytes, command.gate_id);
        append_le<uint64_t>(bytes, command.submit_order);
    }
    if (_worker_origin && _modifier_runtime != nullptr) {
        const auto *front = modifier_api::derived_cell_front(*_modifier_runtime);
        if (front != nullptr && front->generation == _derived_installed_generation)
            append_derived_projection(bytes, *front, _derived_installed_contributions);
    }
    // Plan §18.2: the FULL applied-program basis. One row per (country, program)
    // the derived projection folds: the program key, the effective target-selector
    // identity and a digest of the fold inputs.
    //
    // Re-derived HERE rather than read from `_applied_program_basis`: that member
    // records the last projection BUILT, which goes stale the moment a card is
    // equipped, unequipped or levelled before the next rebuild. A payload must
    // describe the state it was captured from, because that is the only thing a
    // reload can re-derive and check.
    //
    // The block is variable-length, so it carries its own total byte length as its
    // last field. That is what keeps the rest of the tail (the §18.5 scalar block
    // that follows, then the sample day / dates / contract / trailer) addressable
    // from the END of the payload with constants -- the layout fixture derives every
    // offset from the tail, and a block whose size could only be learnt by parsing it
    // from the front would be unaddressable.
    const size_t basis_block_begin = bytes.size();
    append_le<uint32_t>(bytes, static_cast<uint32_t>(basis.size()));
    for (const AppliedProgramBasis &row : basis) {
        append_le<uint64_t>(bytes, row.country_handle);
        append_string(bytes, row.program_key);
        append_le<int32_t>(bytes, row.selector_kind);
        append_string(bytes, row.selector_id);
        append_le<int32_t>(bytes, row.selector_param[0]);
        append_le<int32_t>(bytes, row.selector_param[1]);
        append_le<uint64_t>(bytes, row.terms_digest);
    }
    append_le<uint32_t>(bytes,
        static_cast<uint32_t>(bytes.size() - basis_block_begin));
    // ── plan §18.2 / §18.5: the LOCAL SCALAR BASIS ──────────────────────────
    //
    // One row per (country, slab metric id): the Q16 value the card programs read
    // through `READ_METRIC`. Written immediately after the applied-program basis and
    // closed by its own trailing u32 byte length, for the same reason that block is:
    // the tail (sample day / §9.3 dates / contract / trailer) has to stay addressable
    // from the END of the payload, and a block whose size could only be learnt by
    // parsing it from the front would make the tail unaddressable.
    const size_t scalar_block_begin = bytes.size();
    append_le<uint32_t>(bytes, static_cast<uint32_t>(scalars.size()));
    for (const LocalScalarValue &row : scalars) {
        append_le<uint64_t>(bytes, row.country_handle);
        append_le<int32_t>(bytes, row.metric_id);
        append_le<int64_t>(bytes, row.value_q16);
    }
    append_le<uint32_t>(bytes,
        static_cast<uint32_t>(bytes.size() - scalar_block_begin));
    // §18.5: the sample day the projection was built from.
    //
    // THE EPOCH ID IS DELIBERATELY NOT PERSISTED. `_derived_epoch_id` is structurally
    // 0: it is declared once (ideology_runtime.h), never assigned anywhere in the
    // codebase, and its only read is the `DerivedCellMaterializeJob` argument below --
    // so the `epoch_id` on every `DerivedCellFront` is 0 by construction. A field
    // persisting it would be 0 in every payload this build can ever write, i.e. a
    // value that cannot disagree with anything and therefore validates nothing.
    // `_derived_world_identity` and `_derived_map_generation` are in exactly the same
    // state. What actually identifies the projection's basis and CAN disagree is this
    // day plus the execution contract stamped below (which pins the rule versions and
    // the other catalogs). Extending the payload is the right move the day the epoch
    // becomes real -- and that day needs a schema bump anyway.
    append_le<int64_t>(bytes, _derived_basis_sample_day);
    // Plan §9.3 / p.719: the save must carry the basis dates so a load can tell
    // which projections are not eligible yet. Written after every variable-length
    // section (the two basis blocks above) and immediately before the contract, so
    // the layout is deterministic and the dates stay at a constant distance from the
    // END of the payload.
    append_le<int64_t>(bytes, _derived_basis_confirmed_day);
    append_le<int64_t>(bytes, _derived_basis_eligible_day);
    // Plan §11.5: the execution-contract identity, so an archive produced under other
    // execution rules is refused rather than reinterpreted.
    // Plan §11.5: computed AT CAPTURE TIME, not read from a configure-time stamp.
    //
    // A stamp fixed at configure depends on configure ORDER: `configure_ideologies` before
    // `configure_effects` records a contract whose Effect hash is still 0, so the world
    // could then never reload its own save. Computing here makes the contract describe the
    // configuration actually in force, which is what a save must record.
    append_le<uint64_t>(bytes, compute_execution_contract_hash());
    append_le<uint32_t>(bytes, SAVE_END);
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}


#include "ideology_runtime_persistence_section_restore.inc"


} // namespace pk

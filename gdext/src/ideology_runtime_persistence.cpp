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


bool NativeIdeologyRuntime::export_pod_catalog(
        const RuntimeCountryPodSnapshot &country,
        RuntimeIdeologyPodCatalog &out, std::string &error) const {
    error.clear();
    if (!_configured || !country.bootstrapped || country.catalog_hash == 0) {
        error = "ideology_pod_export_unavailable";
        return false;
    }
    RuntimeIdeologyPodCatalog catalog;
    catalog.country_catalog_hash = country.catalog_hash;
    // Same world seed on both sides: the worker seeds its offer RNG from this and
    // the country handle, exactly like `init_country_state` does on the main
    // thread.
    catalog.world_seed = _world_seed;
    catalog.class_hash = _political_class_hash;
    catalog.class_count = static_cast<uint32_t>(std::max(0, _political_class_count));
    catalog.technology_count = country.technology_count;
    catalog.research_signal_count = country.research_signal_count;
    catalog.gate_count = static_cast<uint32_t>(std::max(0, _gate_count));
    catalog.ideology_capacity = _ideology_capacity;
    catalog.spirit_capacity = _spirit_capacity;
    catalog.draw_count = _draw_count;
    catalog.offer_cost_q16 = _offer_cost_q16;
    catalog.starting_points_q16 = _starting_points_q16;
    catalog.ideology_capacity_max = _ideology_capacity_max;
    catalog.spirit_capacity_max = _spirit_capacity_max;
    catalog.offer_cost_growth_percent = _offer_cost_growth_percent;
    catalog.offer_cost_max_q16 = _offer_cost_max_q16;
    catalog.reroll_cost_percent = _reroll_cost_percent;
    catalog.point_population_weight_q16 = _point_population_weight_q16;
    catalog.point_building_weight_q16 = _point_building_weight_q16;
    catalog.point_trade_weight_q16 = _point_trade_weight_q16;
    catalog.point_gain_cap_q16 = _point_gain_cap_q16;
    catalog.point_gain_stat_id = -1;
    catalog.route_keys.clear();
    catalog.route_keys.reserve(_route_keys.size());
    for (const std::string &route : _route_keys)
        catalog.route_keys.push_back(route);
    catalog.point_population_factor_stat_id = -1;
    catalog.point_building_factor_stat_id = -1;
    catalog.point_trade_factor_stat_id = -1;
    catalog.opinion_factor_floor_stat_id = -1;
    catalog.understanding_gain_stat_id = -1;
    catalog.reroll_cost_stat_id = -1;
    catalog.school_strength_factor_stat_ids.assign(
        _school_strength_factor_stat_keys.size(), -1);
    if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime)) {
        if (!_point_gain_stat_key.empty())
            catalog.point_gain_stat_id =
                modifier_api::stat_id_for_key(*_modifier_runtime, _point_gain_stat_key);
        catalog.point_population_factor_stat_id = resolve_ideology_stat_id(
            _point_population_factor_stat_key,
            _point_population_factor_stat_id);
        catalog.point_building_factor_stat_id = resolve_ideology_stat_id(
            _point_building_factor_stat_key,
            _point_building_factor_stat_id);
        catalog.point_trade_factor_stat_id = resolve_ideology_stat_id(
            _point_trade_factor_stat_key, _point_trade_factor_stat_id);
        catalog.opinion_factor_floor_stat_id = resolve_ideology_stat_id(
            _opinion_factor_floor_stat_key, _opinion_factor_floor_stat_id);
        // Exporting the catalog is also the one place the main-thread hot path's
        // cached ids get refreshed, so both authorities resolve from the same
        // call and cannot drift apart.
        _understanding_gain_stat_id = -1;
        _reroll_cost_stat_id = -1;
        catalog.understanding_gain_stat_id = resolve_ideology_stat_id(
            _understanding_gain_stat_key, _understanding_gain_stat_id);
        catalog.reroll_cost_stat_id = resolve_ideology_stat_id(
            _reroll_cost_stat_key, _reroll_cost_stat_id);
        // The worker cannot read ModifierRuntime, so the host only needs the ID
        // here to know WHICH bucket to freeze into the opinion snapshot.
        catalog.era_decay_floor_stat_id = resolve_ideology_stat_id(
            _era_decay_floor_stat_key, _era_decay_floor_stat_id);
        catalog.offer_choice_bonus_stat_id = resolve_ideology_stat_id(
            _offer_choice_bonus_stat_key, _offer_choice_bonus_stat_id);
        for (size_t index = 0;
                index < _school_strength_factor_stat_keys.size(); ++index) {
            catalog.school_strength_factor_stat_ids[index] =
                resolve_ideology_stat_id(
                    _school_strength_factor_stat_keys[index],
                    _school_strength_factor_stat_ids[index]);
        }
    }
    catalog.school_keys = _school_keys;
    for (const CapacityUnlock &unlock : _capacity_unlocks)
        catalog.capacity_unlocks.push_back(
            {unlock.technology_id, unlock.ideology_delta, unlock.spirit_delta});
    auto modifier_template = [](const EffectTemplate &templ) {
        RuntimeIdeologyPodModifierTemplate row;
        row.definition_key_hash =
            RuntimeEffectPodAuthority::hash_text(templ.definition_key.c_str());
        row.domain = templ.domain;
        row.magnitude_q16 = static_cast<int32_t>(std::clamp<int64_t>(
            templ.value_q16 > 0 ? templ.value_q16 : Q16_ONE, 1,
            std::numeric_limits<int32_t>::max()));
        return row;
    };
    auto is_managed_program = [this](const EffectTemplate &templ) {
        if (_effect_runtime != nullptr) {
            const std::string program = effect_program_key(templ.definition_key);
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!program.empty() &&
                _effect_runtime->family_effect_metadata_pod(program, metadata))
                return true;
        }
        return false;
    };
    catalog.owner_influence_weight = _opinion_owner_influence_weight;
    catalog.funds_per_influence = _opinion_funds_per_influence;
    catalog.era_decay_bp = _era_decay_bp;
    catalog.refine_weight_bp = _refine_weight_bp;
    catalog.refine_understanding_q16 = _refine_understanding_q16;
    catalog.era_milestone_technologies = _era_milestone_technologies;
    catalog.max_commands_per_slice = static_cast<uint32_t>(
        std::max(1, _max_commands_per_slice));
    catalog.max_transition_commands = static_cast<uint32_t>(
        std::max(1, _max_transition_commands));
    catalog.max_transition_polls_per_slice = static_cast<uint32_t>(
        std::max(1, _max_transition_polls_per_slice));
    catalog.max_active_visits_per_slice = static_cast<uint32_t>(
        std::max(1, _max_active_visits_per_slice));
    catalog.levels.reserve(_levels.size());
    for (const Level &level : _levels) {
        RuntimeIdeologyPodLevel row;
        row.threshold_q16 = level.threshold_q16;
        row.daily_understanding_q16 = level.daily_understanding_q16;
        row.modifier_begin = static_cast<uint32_t>(catalog.level_modifiers.size());
        for (int32_t i = 0; i < level.persistent_count; ++i) {
            const EffectTemplate &templ = _persistent_templates[
                static_cast<size_t>(level.persistent_begin + i)];
            if (!is_managed_program(templ))
                catalog.level_modifiers.push_back(modifier_template(templ));
        }
        row.modifier_count = static_cast<uint32_t>(
            catalog.level_modifiers.size() - row.modifier_begin);
        for (int32_t i = 0; i < level.on_enter_count; ++i) {
            const EffectTemplate &templ = _on_enter_templates[
                static_cast<size_t>(level.on_enter_begin + i)];
            if (templ.action != EffectRuntime::CUSTOM_DOMAIN_COMMAND ||
                    templ.domain != 6 ||
                    templ.opcode !=
                        EffectRuntime::CUSTOM_IDEOLOGY_FREE_DRAW_OPCODE)
                continue;
            const uint32_t count = static_cast<uint32_t>(std::max<int64_t>(
                1, std::min<int64_t>(65535, templ.value_q16)));
            row.on_enter_free_draws = static_cast<uint16_t>(
                std::min<uint32_t>(65535u,
                    static_cast<uint32_t>(row.on_enter_free_draws) + count));
        }
        catalog.levels.push_back(row);
    }
    catalog.definitions.reserve(_definitions.size());
    for (const Definition &definition : _definitions) {
        RuntimeIdeologyPodDefinition row;
        row.acquisition = definition.acquisition;
        row.copy_left_programs = definition.copy_left_programs;
        row.copyable = definition.copyable;
        row.school_index = definition.school_index < 0
            ? 0 : static_cast<uint8_t>(definition.school_index);
        row.rarity_weight = definition.rarity_weight;
        row.era_index = definition.era_index;
        row.ideology_cost = definition.ideology_cost;
        row.spirit_cost = definition.spirit_cost;
        row.min_spirit_level = definition.min_spirit_level;
        row.level_begin = static_cast<uint32_t>(definition.level_begin);
        row.level_count = static_cast<uint32_t>(definition.level_count);
        row.technology_begin = static_cast<uint32_t>(definition.technology_requirement_begin);
        row.technology_count = static_cast<uint32_t>(definition.technology_requirement_count);
        row.signal_begin = static_cast<uint32_t>(definition.signal_requirement_begin);
        row.signal_count = static_cast<uint32_t>(definition.signal_requirement_count);
        row.gate_begin = static_cast<uint32_t>(definition.gate_requirement_begin);
        row.gate_count = static_cast<uint32_t>(definition.gate_requirement_count);
        row.stance_begin = static_cast<uint32_t>(definition.stance_begin);
        row.stance_count = static_cast<uint32_t>(definition.stance_count);
        row.support_threshold_q16 = definition.support_threshold_q16;
        row.exclusion_group_id = definition.exclusion_group_id;
        row.route_mask = definition.route_mask;
        catalog.definitions.push_back(row);
    }
    catalog.technology_requirements = _technology_requirements;
    catalog.signal_requirements = _signal_requirements;
    catalog.gate_requirements = _gate_requirements;
    catalog.class_stances.reserve(_class_stances.size());
    for (const ClassStance &stance : _class_stances) {
        RuntimeIdeologyPodClassStance row;
        row.class_index = stance.class_index;
        row.stance_q16 = stance.stance_q16;
        row.critical_min_q16 = stance.critical_min_q16;
        catalog.class_stances.push_back(row);
    }
    catalog.synergy_requirements.reserve(_synergy_requirements.size());
    for (const SynergyRequirement &requirement : _synergy_requirements) {
        RuntimeIdeologyPodSynergyRequirement row;
        row.ideology_id = requirement.ideology_id;
        row.minimum_level = requirement.minimum_level;
        row.location_mask = requirement.location_mask;
        catalog.synergy_requirements.push_back(row);
    }
    catalog.synergies.reserve(_synergies.size());
    for (const Synergy &synergy : _synergies) {
        RuntimeIdeologyPodSynergy row;
        row.requirement_begin = static_cast<uint32_t>(synergy.requirement_begin);
        row.requirement_count = static_cast<uint32_t>(synergy.requirement_count);
        row.min_count = static_cast<uint32_t>(synergy.min_count);
        row.modifier_begin = static_cast<uint32_t>(catalog.synergy_modifiers.size());
        for (int32_t i = 0; i < synergy.effect_count; ++i) {
            const EffectTemplate &templ = _synergy_templates[
                static_cast<size_t>(synergy.effect_begin + i)];
            if (!is_managed_program(templ))
                catalog.synergy_modifiers.push_back(modifier_template(templ));
        }
        row.modifier_count = static_cast<uint32_t>(
            catalog.synergy_modifiers.size() - row.modifier_begin);
        catalog.synergies.push_back(row);
    }
    catalog.ideology_synergy_offsets.reserve(_ideology_synergy_offsets.size());
    for (const int32_t offset : _ideology_synergy_offsets)
        catalog.ideology_synergy_offsets.push_back(static_cast<uint32_t>(offset));
    catalog.ideology_synergy_ids = _ideology_synergy_ids;
    RuntimeIdeologyPodAuthority validator;
    if (!validator.configure(catalog, error)) return false;
    catalog.catalog_hash = validator.catalog_hash();
    // The POD recomputes its catalog hash in `configure` from the SAME struct, so this is
    // the identity a POD save/import payload must carry -- `_catalog_hash` is NOT (the two
    // sides hash their catalogs with different functions; see `rng_state`'s seeding note).
    _pod_catalog_hash = catalog.catalog_hash;
    out = std::move(catalog);
    return true;
}


// Main-thread -> POD export. This is the neutral structure both sides can hash:
// `apply_self_pod_snapshot_for_test` used to build it inline, and parity needs the
// same snapshot without applying it.
bool NativeIdeologyRuntime::export_pod_business_snapshot(
        RuntimeIdeologyPodSnapshot &out) const {
    if (!_configured) return false;
    out = RuntimeIdeologyPodSnapshot{};
    out.abi_version = RUNTIME_IDEOLOGY_POD_ABI_VERSION;
    out.catalog_hash = _catalog_hash;
    out.generation = std::max<uint64_t>(1, _pod_snapshot_generation);
    out.committed_day = _last_day;
    out.round_day = _last_day;
    out.countries.resize(_countries.size());
    for (size_t slot = 0; slot < _countries.size(); ++slot) {
        const CountryState &source = _countries[slot];
        if (source.handle == 0) continue;
        RuntimeIdeologyPodCountryState &target = out.countries[slot];
        target.handle = source.handle;
        target.unlocked_era = source.unlocked_era;
        target.ideology_points_q16 = source.ideology_points_q16;
        target.points_revision = source.points_revision;
        target.rng_state = source.rng_state;
        target.draw_sequence = source.draw_sequence;
        target.free_draws = source.free_draws;
        target.known_bits = source.known_bits;
        target.banned_bits = source.banned_bits;
        target.gate_bits = source.gate_bits;
        target.synergy_bits = source.active_synergy_bits;
        target.offer.generation = source.offer.generation;
        target.offer.ideology_ids = source.offer.ideology_ids;
        target.offer.choice_count = source.offer.choice_count;
        target.offer.active = source.offer.active;
        // Everything `apply_pod_snapshot` reads has to be exported, or applying a
        // snapshot silently zeroes it -- and the business hash would report the
        // main-thread side as "0" for these forever.
        target.lifetime_points_q16 = source.lifetime_points_q16;
        target.trade_paid_day = source.trade_paid_day;
        target.baseline_ready = source.baseline_ready;
        target.baseline_population = source.baseline_population;
        target.baseline_buildings = source.baseline_buildings;
        target.history_count = source.history_count;
        target.history_head = source.history_head;
        target.history_q16 = source.history_q16;
        target.ledger = source.ledger;
        target.ideology_slots_used = source.ideology_slots_used;
        target.spirit_slots_used = source.spirit_slots_used;
        target.opinion_revision = source.opinion_revision;
        target.ideas.resize(_definitions.size());
        for (const IdeaState &idea : source.ideas) {
            if (idea.ideology_id < 0 ||
                    idea.ideology_id >= static_cast<int32_t>(_definitions.size()))
                continue;
            RuntimeIdeologyPodIdeaState &row =
                target.ideas[static_cast<size_t>(idea.ideology_id)];
            row.understanding_q16 = idea.understanding_q16;
            row.level = idea.level;
            row.entered_levels = idea.entered_levels;
            row.generation = idea.generation;
            row.location = static_cast<RuntimeIdeologyPodLocation>(idea.location);
            row.slot_index = idea.slot_index;
        }
    }
    // Business hash, not `compute_state_hash`: the latter folds in generation,
    // cursors and opinion_revision, which differ between main and worker by
    // construction and made every parity comparison a guaranteed mismatch.
    out.state_hash = ideology_business_hash(out);
    return true;
}


// ── worker IMPORT: the state a restored save must make the POD adopt ───────────
//
// WHY THIS EXISTS. `restore()` rebuilds this runtime's rows, and under IDEOLOGY worker
// authority this runtime is a MIRROR: `apply_pod_snapshot` replaces its rows wholesale
// from the next worker publish. So a restore changes only the main thread, and the
// worker's next publish puts its own state back (measured: `idea_rows [82,1,0,0] -> []`,
// §9.3 dates `7/8 -> 2/3`, then a pump with nothing to fold). The import closes that by
// producing exactly what the POD needs to ADOPT the same state -- not a merge: the POD's
// committed day, rows, points, RNG and offer all become the payload's.
//
// WHY THE BUSINESS SNAPSHOT IS NOT ENOUGH. Three things it deliberately omits are
// required for the POD to accept and reproduce the state:
//   1. the POD's CATALOG identity (`_pod_catalog_hash`, not `_catalog_hash`: the two
//      sides hash their catalogs with different functions);
//   2. the live per-slot COUNTRY generation, which `validate_inputs` compares on every
//      plan and which also encodes into the handle (`generation << 32 | slot`);
//   3. the CALENDAR: `apply_pod_snapshot` stamps the two §9.3 dates from
//      `committed_day`, so that field decides whether the mirror keeps the payload's
//      dates or adopts the worker's (`7/8` vs `2/3`).
bool NativeIdeologyRuntime::export_pod_import_state(
        RuntimeIdeologyPodSnapshot &out,
        const RuntimeCountryPodSnapshot &country, std::string &error) const {
    error.clear();
    if (!_configured) { error = "ideology_runtime_not_configured"; return false; }
    if (_pod_catalog_hash == 0) {
        error = "ideology_pod_catalog_identity_unavailable";
        return false;
    }
    if (!country.bootstrapped || country.country_count == 0 ||
        country.country_active.size() != country.country_count ||
        country.country_generation.size() != country.country_count) {
        error = "ideology_pod_import_country_snapshot_invalid";
        return false;
    }
    if (!export_pod_business_snapshot(out)) {
        error = "ideology_runtime_not_configured";
        return false;
    }
    // The POD indexes a country row by `handle & 0xffffffff` and refuses a state whose
    // row count differs from the Country snapshot it plans against (`validate_inputs`),
    // so the mirror's trailing empty rows are trimmed -- but a row that still carries a
    // handle is a country the Country domain does not know about, and dropping it would
    // silently lose a card.
    for (size_t slot = country.country_count; slot < out.countries.size(); ++slot) {
        if (out.countries[slot].handle != 0) {
            error = "ideology_pod_import_country_shape_mismatch";
            return false;
        }
    }
    if (out.countries.size() < country.country_count) {
        error = "ideology_pod_import_country_shape_mismatch";
        return false;
    }
    out.countries.resize(country.country_count);
    for (uint32_t slot = 0; slot < country.country_count; ++slot) {
        RuntimeIdeologyPodCountryState &row = out.countries[slot];
        if (country.country_active[slot] == 0) {
            row = RuntimeIdeologyPodCountryState{};
            continue;
        }
        const uint64_t handle =
            (static_cast<uint64_t>(country.country_generation[slot]) << 32u) | slot;
        if (row.handle != handle) {
            error = "ideology_pod_import_country_handle_mismatch";
            return false;
        }
        row.generation = country.country_generation[slot];
    }
    out.catalog_hash = _pod_catalog_hash;
    // ── the calendar ────────────────────────────────────────────────────────
    // The CONFIRMED day is the day this state was confirmed on, and it is the value
    // `apply_pod_snapshot` maps back onto `_derived_basis_confirmed_day`. Anything else
    // (the worker's own day, or the payload's `_last_day`) moves the mirrored dates.
    const int64_t floor_day = _derived_basis_confirmed_day >= 0
        ? _derived_basis_confirmed_day : _last_day;
    if (floor_day < 0) {
        error = "ideology_pod_import_day_unavailable";
        return false;
    }
    out.committed_day = floor_day;
    out.round_day = -1;
    out.phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
    out.pending_cursor = 0;
    out.command_cursor = 0;
    out.active_country_cursor = 0;
    out.active_idea_cursor = 0;
    out.next_submit_order = std::max<uint64_t>(1, _submit_order);
    out.producer_high_watermarks.clear();
    // `_producer_high_watermarks` is an unordered_map and the POD's restore requires
    // STRICTLY ASCENDING producer ids, so the rows are sorted here (the same way
    // `capture()` sorts its own copy) instead of relying on iteration order.
    std::vector<std::pair<int32_t, int64_t>> watermarks(
        _producer_high_watermarks.begin(), _producer_high_watermarks.end());
    std::sort(watermarks.begin(), watermarks.end());
    out.producer_high_watermarks.reserve(watermarks.size());
    for (const auto &entry : watermarks) {
        if (entry.first <= 0) continue;
        RuntimeIdeologyPodProducerWatermark watermark;
        watermark.producer_id = static_cast<uint32_t>(entry.first);
        watermark.sequence = static_cast<uint64_t>(std::max<int64_t>(0, entry.second));
        out.producer_high_watermarks.push_back(watermark);
    }
    // PKID's rows are SETTLED state: a pending transition is persisted on the row, and
    // the row already carries the level and location the transition settles to. So the
    // import carries no transition and no command -- re-emitting one would drive an
    // Effect instance this worker never ordered, on a card whose bindings live on the
    // main thread.
    out.pending_transitions.clear();
    out.commands.clear();
    out.receipts.clear();
    // One generation AHEAD of everything the mirror has applied. A snapshot the ring
    // still holds from before the import then loses the generation race instead of
    // overwriting the restore (`apply_pod_snapshot` refuses a regression).
    out.generation = std::max<uint64_t>(1, _pod_snapshot_generation + 1);
    RuntimeIdeologyPodAuthority::canonicalize_import(out);
    return true;
}


void NativeIdeologyRuntime::record_worker_import(
        const std::string &code, bool applied, bool retryable) {
    ++_worker_import_attempts;
    _worker_import_last_code = code;
    // A refused payload must not become an infinite retry: retrying would ALSO keep the
    // write-back from applying (the pending flag guards the restore), which would freeze
    // the mirror instead of reporting the refusal. Only "the worker held the day
    // boundary" is worth another attempt.
    if (applied || !retryable) _worker_import_pending = false;
}


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


Dictionary NativeIdeologyRuntime::restore(const PackedByteArray &packed) {
    if (!_configured) return fail("ideology_runtime_unconfigured");
    const uint8_t *data = packed.ptr(); const size_t size = packed.size(); size_t cursor = 0;
    uint32_t magic = 0, end = 0; int32_t schema = 0; uint64_t catalog_hash = 0, state_hash = 0;
    uint64_t submit_order = 0, country_count = 0, command_count = 0; int64_t last_day = -1;
    if (!read_le(data, size, cursor, magic) || !read_le(data, size, cursor, schema) ||
            !read_le(data, size, cursor, catalog_hash) || !read_le(data, size, cursor, last_day) ||
            !read_le(data, size, cursor, submit_order) || !read_le(data, size, cursor, state_hash) ||
            magic != SAVE_MAGIC) return fail("ideology_save_header_invalid");
    // PKID v4 (increment-only points, ledger, per-country slot capacity) is
    // fail-closed: earlier schemas are rejected instead of migrated.
    if (schema != SAVE_SCHEMA_VERSION) return fail("ideology_save_schema_unsupported");
    if (catalog_hash != _catalog_hash) return fail("ideology_save_catalog_mismatch");
    std::unordered_map<int32_t, int64_t> producer_high_watermarks;
    if (schema >= 3) {
        uint64_t high_watermark_count = 0;
        if (!read_le(data, size, cursor, high_watermark_count) ||
                high_watermark_count > 65536)
            return fail("ideology_save_producer_count_invalid");
        for (uint64_t i = 0; i < high_watermark_count; ++i) {
            int32_t producer_id = 0;
            int64_t sequence = -1;
            if (!read_le(data, size, cursor, producer_id) ||
                    !read_le(data, size, cursor, sequence) ||
                    producer_id <= 0 || sequence < 0 ||
                    !producer_high_watermarks.emplace(
                        producer_id, sequence).second)
                return fail("ideology_save_producer_invalid");
        }
    }
    uint64_t points_revision_seen = 0;
    uint8_t worker_origin = 0;
    if (!read_le(data, size, cursor, points_revision_seen) ||
            !read_le(data, size, cursor, worker_origin) || worker_origin > 1)
        return fail("ideology_save_points_header_invalid");
    if (!read_le(data, size, cursor, country_count) || country_count > 1000000) return fail("ideology_save_country_count_invalid");
    std::vector<CountryState> countries(static_cast<size_t>(country_count));
    for (CountryState &country : countries) {
        if (!read_le(data, size, cursor, country.handle) || !read_le(data, size, cursor, country.ideology_points_q16) ||
                !read_le(data, size, cursor, country.unlocked_era) ||
                !read_le(data, size, cursor, country.rng_state) || !read_le(data, size, cursor, country.draw_sequence) ||
                !read_le(data, size, cursor, country.free_draws) ||
                !read_le(data, size, cursor, country.points_revision) ||
                !read_le(data, size, cursor, country.baseline_ready) ||
                !read_le(data, size, cursor, country.history_count) ||
                !read_le(data, size, cursor, country.history_head) ||
                !read_le(data, size, cursor, country.baseline_population) ||
                !read_le(data, size, cursor, country.baseline_buildings) ||
                !read_le(data, size, cursor, country.lifetime_points_q16) ||
                !read_le(data, size, cursor, country.trade_paid_day) ||
                !read_le(data, size, cursor, country.ledger.population_q16) ||
                !read_le(data, size, cursor, country.ledger.building_q16) ||
                !read_le(data, size, cursor, country.ledger.trade_q16) ||
                !read_le(data, size, cursor, country.ledger.opinion_factor_q16) ||
                !read_le(data, size, cursor, country.ledger.gain_factor_q16) ||
                !read_le(data, size, cursor, country.ledger.gain_q16) ||
                !read_le(data, size, cursor, country.ledger.day))
            return fail("ideology_save_country_invalid");
        for (int64_t &value : country.history_q16)
            if (!read_le(data, size, cursor, value)) return fail("ideology_save_point_history_invalid");
        if (country.baseline_ready > 1 || country.history_count > POINT_HISTORY ||
                country.history_head >= POINT_HISTORY)
            return fail("ideology_save_point_history_invalid");
        if (!read_vec(data, size, cursor, country.known_bits, _idea_words) ||
                !read_vec(data, size, cursor, country.gate_bits, _gate_words) ||
                !read_le(data, size, cursor, country.offer.generation) || !read_le(data, size, cursor, country.offer.active) ||
                !read_le(data, size, cursor, country.offer.choice_count))
            return fail("ideology_save_country_invalid");
        // read_vec only enforces an upper bound. A short gate_bits vector would
        // make gate() read past the end, so the length has to match exactly.
        // banned_bits is validated where it is read, not here: it appears later
        // in the stream, so a size check at this point would compare against an
        // empty vector and reject every save.
        if (country.known_bits.size() != static_cast<size_t>(_idea_words) ||
                country.gate_bits.size() != static_cast<size_t>(_gate_words) ||
                country.unlocked_era < 0 || country.unlocked_era > MAX_ERA_INDEX ||
                country.offer.active > 1 ||
                country.offer.choice_count > OFFER_CHOICE_CAPACITY)
            return fail("ideology_save_country_invalid");
        for (int32_t &ideology_id : country.offer.ideology_ids)
            if (!read_le(data, size, cursor, ideology_id)) return fail("ideology_save_offer_invalid");
        // banned_bits follows the offer row, matching append order exactly. It is
        // NOT next to known_bits in the stream even though the two are siblings
        // conceptually -- the write site sits inside the offer block, and a
        // reader that assumes otherwise silently shifts every later field.
        if (!read_vec(data, size, cursor, country.banned_bits, _idea_words) ||
                country.banned_bits.size() != static_cast<size_t>(_idea_words))
            return fail("ideology_save_ban_invalid");
        uint64_t idea_count = 0;
        if (!read_le(data, size, cursor, idea_count) || idea_count > _definitions.size()) return fail("ideology_save_idea_count_invalid");
        for (uint64_t n = 0; n < idea_count; ++n) {
            IdeaState state; uint64_t transition_count = 0;
            if (!read_le(data, size, cursor, state.ideology_id) || !read_le(data, size, cursor, state.understanding_q16) ||
                    !read_le(data, size, cursor, state.level) || !read_le(data, size, cursor, state.entered_levels) ||
                    !read_le(data, size, cursor, state.generation) || !read_le(data, size, cursor, state.location) ||
                    (schema >= 9 && !read_le(data, size, cursor, state.slot_index)) ||
                    (schema >= 2 && (!read_le(data, size, cursor, state.binding_id) ||
                        !read_le(data, size, cursor, state.binding_generation) ||
                        !read_le(data, size, cursor, state.binding_signature) ||
                        !read_le(data, size, cursor, state.binding_program_hash))) ||
                    !read_le(data, size, cursor, state.transition.active) ||
                    (schema >= 3 && (!read_le(data, size, cursor,
                        state.transition.producer_id) ||
                        !read_le(data, size, cursor,
                            state.transition.command_sequence) ||
                        !read_le(data, size, cursor,
                            state.transition.command_opcode))) ||
                    !read_le(data, size, cursor, state.transition.previous_level) ||
                    !read_le(data, size, cursor, state.transition.previous_entered_levels) ||
                    !read_le(data, size, cursor, state.transition.previous_generation) ||
                    !read_le(data, size, cursor, state.transition.previous_location) ||
                    (schema >= 9 && !read_le(data, size, cursor,
                        state.transition.previous_slot_index)) ||
                    !read_le(data, size, cursor, state.transition.entered_on_success) ||
                    !read_le(data, size, cursor, transition_count) || transition_count > 4096 ||
                    state.ideology_id < 0 || state.ideology_id >= static_cast<int32_t>(_definitions.size()) ||
                    state.location > NATIONAL_SPIRIT || state.transition.previous_location > NATIONAL_SPIRIT)
                return fail("ideology_save_idea_invalid");
            state.transition.transaction_ids.resize(static_cast<size_t>(transition_count));
            for (int64_t &transaction_id : state.transition.transaction_ids)
                if (!read_le(data, size, cursor, transaction_id) || transaction_id <= 0) return fail("ideology_save_transition_invalid");
            if (schema >= 3) {
                uint64_t changed_synergy_count = 0;
                if (!read_le(data, size, cursor, changed_synergy_count) ||
                        changed_synergy_count > _synergies.size())
                    return fail("ideology_save_synergy_transition_invalid");
                state.transition.changed_synergy_ids.resize(
                    static_cast<size_t>(changed_synergy_count));
                state.transition.previous_synergy_active.resize(
                    static_cast<size_t>(changed_synergy_count));
                for (size_t index = 0;
                        index < static_cast<size_t>(changed_synergy_count);
                        ++index) {
                    if (!read_le(data, size, cursor,
                            state.transition.changed_synergy_ids[index]) ||
                            !read_le(data, size, cursor,
                                state.transition.previous_synergy_active[index]) ||
                            state.transition.changed_synergy_ids[index] < 0 ||
                            state.transition.changed_synergy_ids[index] >=
                                static_cast<int32_t>(_synergies.size()) ||
                            state.transition.previous_synergy_active[index] > 1)
                        return fail(
                            "ideology_save_synergy_transition_invalid");
                }
            }
            if (state.transition.active == 0 && !state.transition.transaction_ids.empty()) return fail("ideology_save_transition_invalid");
            if (schema >= 6) {
                uint64_t effect_instance_count = 0;
                if (!read_le(data, size, cursor, effect_instance_count) ||
                        effect_instance_count > 4096)
                    return fail("ideology_save_effect_instance_count_invalid");
                state.effect_instances.resize(
                    static_cast<size_t>(effect_instance_count));
                for (size_t index = 0;
                        index < static_cast<size_t>(effect_instance_count);
                        ++index) {
                    IdeaState::EffectInstanceRef &ref =
                        state.effect_instances[index];
                    if (!read_le(data, size, cursor, ref.program_hash) ||
                            !read_le(data, size, cursor, ref.target_handle) ||
                            !read_le(data, size, cursor, ref.target_generation) ||
                            !read_le(data, size, cursor, ref.instance_id) ||
                            !read_le(data, size, cursor, ref.generation) ||
                            ref.instance_id <= 0 || ref.generation == 0 ||
                            ref.program_hash == 0)
                        return fail("ideology_save_effect_instance_invalid");
                }
            }
            country.idea_indices[state.ideology_id] = static_cast<int32_t>(country.ideas.size());
            country.ideas.push_back(std::move(state));
        }
        rebuild_country_derived(country);
    }
    if (!read_le(data, size, cursor, command_count) || command_count > 10000000) return fail("ideology_save_command_count_invalid");
    std::vector<Command> commands; commands.reserve(static_cast<size_t>(command_count));
    for (uint64_t n = 0; n < command_count; ++n) {
        Command command;
        if (!read_le(data, size, cursor, command.opcode) || !read_le(data, size, cursor, command.effective_day) ||
                (schema >= 3 && !read_le(data, size, cursor, command.producer_id)) ||
                !read_le(data, size, cursor, command.source_priority) || !read_le(data, size, cursor, command.sequence) ||
                !read_le(data, size, cursor, command.country_handle) || !read_le(data, size, cursor, command.ideology_id) ||
                !read_le(data, size, cursor, command.value_q16) || !read_le(data, size, cursor, command.offer_generation) ||
                !read_le(data, size, cursor, command.choice_index) || !read_le(data, size, cursor, command.gate_id) ||
                !read_le(data, size, cursor, command.submit_order)) return fail("ideology_save_command_invalid");
        std::string error; if (!validate_command_shape(command, error)) return fail(error);
        commands.push_back(command);
    }
    if (!std::is_sorted(commands.begin(), commands.end(), command_less))
        return fail("ideology_save_command_order_invalid");
    // ── plan §18.2: the applied-program basis ─────────────────────────────────
    //
    // Read BEFORE the dates, because that is where it is written: after the command
    // table, self-delimited by its own total byte length.
    std::vector<AppliedProgramBasis> restored_basis;
    {
        const size_t basis_block_begin = cursor;
        uint32_t basis_row_count = 0;
        if (!read_le(data, size, cursor, basis_row_count))
            return fail("ideology_save_truncated");
        // Two bounds: the global cap, and what the remaining bytes could possibly
        // hold (an empty row is 8+4+4+4+4+8 fixed bytes plus two empty strings, so
        // 32 bytes). The second one is what turns a lying count into a SHAPE error
        // instead of a slow truncation deep inside a row read.
        if (basis_row_count > APPLIED_BASIS_ROW_LIMIT ||
                static_cast<uint64_t>(basis_row_count) >
                    (size - cursor) / 32U)
            return fail("ideology_save_applied_basis_invalid");
        restored_basis.reserve(static_cast<size_t>(basis_row_count));
        for (uint32_t index = 0; index < basis_row_count; ++index) {
            AppliedProgramBasis row;
            if (!read_le(data, size, cursor, row.country_handle) ||
                    !read_string(data, size, cursor, row.program_key,
                        APPLIED_BASIS_KEY_LIMIT) ||
                    !read_le(data, size, cursor, row.selector_kind) ||
                    !read_string(data, size, cursor, row.selector_id,
                        APPLIED_BASIS_KEY_LIMIT) ||
                    !read_le(data, size, cursor, row.selector_param[0]) ||
                    !read_le(data, size, cursor, row.selector_param[1]) ||
                    !read_le(data, size, cursor, row.terms_digest))
                return fail("ideology_save_truncated");
            // Shape/pair validation, the same idea as the dates' pair rule above: a
            // row that cannot describe a real program is refused by name instead of
            // being carried into the state hash and a later comparison.
            if (row.country_handle == 0 || row.program_key.empty() ||
                    row.selector_kind < 0 || row.terms_digest == 0)
                return fail("ideology_save_applied_basis_invalid");
            // Strictly ascending (country, program): rejects duplicates and an
            // unsorted block, which is what makes the byte layout a function of the
            // state rather than of iteration order.
            if (!restored_basis.empty()) {
                const AppliedProgramBasis &previous = restored_basis.back();
                const bool ordered = previous.country_handle < row.country_handle ||
                    (previous.country_handle == row.country_handle &&
                     previous.program_key < row.program_key);
                if (!ordered)
                    return fail("ideology_save_applied_basis_invalid");
            }
            restored_basis.push_back(std::move(row));
        }
        // The block's declared length must agree with the bytes actually consumed.
        // Without this a length field could point anywhere and the "addressable from
        // the tail" property would rest on data that is never checked.
        //
        // `basis_rows_end` is taken BEFORE the length field itself is read: the field
        // is not part of the length it declares. Using `cursor` directly after the read
        // counted the field, and the writer/reader disagreed by exactly four bytes --
        // measured: every restore refused a payload this same code had just written.
        const size_t basis_rows_end = cursor;
        uint32_t basis_block_bytes = 0;
        if (!read_le(data, size, cursor, basis_block_bytes))
            return fail("ideology_save_truncated");
        if (basis_block_bytes !=
                static_cast<uint32_t>(basis_rows_end - basis_block_begin))
            return fail("ideology_save_applied_basis_invalid");
    }
    // ── plan §18.2 / §18.5: the LOCAL SCALAR BASIS ────────────────────────────────
    //
    // Read immediately after the applied basis and before the sample day, because
    // that is where it is written: after the command table, self-delimited by its own
    // trailing u32.
    std::vector<LocalScalarValue> restored_scalars;
    {
        const size_t scalar_block_begin = cursor;
        uint32_t scalar_row_count = 0;
        if (!read_le(data, size, cursor, scalar_row_count))
            return fail("ideology_save_truncated");
        // Two bounds again: the global cap, and what the remaining bytes could hold.
        // `LocalScalarValue` is 8 + 4 + 8 = 20 fixed bytes with no variable part, so a
        // count above `(size - cursor) / 20` is a SHAPE error rather than a slow
        // truncation deep inside a row read.
        if (scalar_row_count > LOCAL_SCALAR_ROW_LIMIT ||
                static_cast<uint64_t>(scalar_row_count) >
                    (size - cursor) / 20U)
            return fail("ideology_save_scalar_basis_invalid");
        restored_scalars.reserve(static_cast<size_t>(scalar_row_count));
        for (uint32_t index = 0; index < scalar_row_count; ++index) {
            LocalScalarValue row;
            if (!read_le(data, size, cursor, row.country_handle) ||
                    !read_le(data, size, cursor, row.metric_id) ||
                    !read_le(data, size, cursor, row.value_q16))
                return fail("ideology_save_truncated");
            // Shape: a row must name a country and a real slab slot. `-1` is the
            // builder's own "unresolved key" sentinel, so a payload carrying it cannot
            // have come from a catalog that resolves the scalar keys.
            if (row.country_handle == 0 || row.metric_id < 0)
                return fail("ideology_save_scalar_basis_invalid");
            // Strictly ascending (country, metric): rejects duplicates and an unsorted
            // block, exactly as the applied basis does.
            if (!restored_scalars.empty()) {
                const LocalScalarValue &previous = restored_scalars.back();
                const bool ordered = previous.country_handle < row.country_handle ||
                    (previous.country_handle == row.country_handle &&
                     previous.metric_id < row.metric_id);
                if (!ordered)
                    return fail("ideology_save_scalar_basis_invalid");
            }
            restored_scalars.push_back(row);
        }
        // Same honesty requirement as the block above: the declared length must agree
        // with the bytes actually consumed, and the end is taken BEFORE the length
        // field itself is read (the field is not part of the length it declares).
        const size_t scalar_rows_end = cursor;
        uint32_t scalar_block_bytes = 0;
        if (!read_le(data, size, cursor, scalar_block_bytes))
            return fail("ideology_save_truncated");
        if (scalar_block_bytes !=
                static_cast<uint32_t>(scalar_rows_end - scalar_block_begin))
            return fail("ideology_save_scalar_basis_invalid");
    }
    // §18.5: the sample day the projection was built from. `-1` = nothing projected.
    //
    // The EPOCH ID is deliberately absent from the payload (see the writer's comment):
    // `_derived_epoch_id` is structurally 0, so a field for it would validate nothing.
    // The sample day is the half of the identity that carries information; the
    // execution contract read below pins the rules it was built under.
    int64_t restored_sample_day = -1;
    if (!read_le(data, size, cursor, restored_sample_day))
        return fail("ideology_save_truncated");
    // Shape only. There is deliberately NO pair rule tying the sample day to
    // `_last_day` or to the two §9.3 dates below:
    //   * `drain_derived_cell_layer` drives `step_derived_rebuild(day)` directly, so a
    //     projection can be built for a day the day-completion marker has not reached;
    //   * a transition may CONFIRM on a later day than the build it confirmed, so
    //     `confirmed_day > sample_day` is legal.
    // Both rules would therefore refuse payloads this same code writes, and a check
    // that fires on legal data is worse than none. What is left is the domain: below
    // -1 is neither a real day nor the "no projection" sentinel.
    if (restored_sample_day < -1)
        return fail("ideology_save_scalar_basis_invalid");
    int64_t restored_basis_confirmed_day = -1;
    int64_t restored_basis_eligible_day = -1;
    if (!read_le(data, size, cursor, restored_basis_confirmed_day) ||
        !read_le(data, size, cursor, restored_basis_eligible_day))
        return fail("ideology_save_truncated");
    // Plan §11.5: the execution-contract identity. Explicit refusal, per the plan:
    // "旧档默认明确拒读 cell_program_execution_contract_mismatch, 而不是删掉旧实例继续读."
    uint64_t restored_contract = 0;
    if (!read_le(data, size, cursor, restored_contract))
        return fail("ideology_save_truncated");
    // Compare against THIS runtime's own stamp, not a live recomputation.
    //
    // That asymmetry was a real defect (found while fixing a fixture): `configure`
    // stamps `_execution_contract_hash` on its last line from the catalogs attached AT
    // THAT MOMENT, so a world configured Effect-AFTER-Ideology carries a stamp computed
    // with an effect hash of 0. Comparing the payload against a LIVE recomputation then
    // meant such a world could restore a foreign, correctly-stamped payload yet could
    // never reload its OWN save -- the worst of both directions.
    //
    // Comparing stamp against stamp makes the rule symmetric and states it plainly:
    // a payload is accepted iff the runtime that produced it agreed on the contract. A
    // runtime that reconfigured gets a new stamp, so it refuses payloads from the old
    // one, which is what §11.5 wants ("跨不同覆盖配置加载时必须拒读").
    if (restored_contract != compute_execution_contract_hash())
        return fail("cell_program_execution_contract_mismatch");
    // Reject a nonsensical pair rather than trusting it: the gate treats
    // `eligible < 0` as "no basis yet", so a payload claiming confirmed=9999 /
    // eligible=0 would silently disable it.
    if ((restored_basis_confirmed_day < 0) != (restored_basis_eligible_day < 0) ||
        (restored_basis_eligible_day >= 0 &&
         restored_basis_eligible_day != restored_basis_confirmed_day + 1))
        return fail("ideology_save_basis_dates_invalid");
    if (!read_le(data, size, cursor, end) || end != SAVE_END || cursor != size) return fail("ideology_save_truncated");
    // ── plan §18.2: can the payload's basis be rebuilt from the CURRENT catalogs? ──
    //
    // This is the check the two basis dates cannot make: they say WHEN a projection may
    // be adopted, not WHAT it was built from. The concrete hole it closes -- measured,
    // see `ideology_save_payload_robustness_test` -- is the card-level -> program
    // mapping: `compute_catalog_hash` does not cover `Definition::level_begin`,
    // `Level::persistent_*` or `EffectTemplate::definition_key`, and the execution
    // contract covers only the version vector plus the OTHER two catalogs' hashes. So
    // two builds that disagree about which program a card level carries agree on every
    // other persisted identity, and without this check the reload would silently project
    // a DIFFERENT card from the same rows.
    //
    // Runs against the payload's own country rows, before anything is installed, using
    // the pure rebuild helper: a refusal here leaves the runtime untouched, so it needs
    // no rollback of its own.
    {
        std::vector<AppliedProgramBasis> rebuilt_basis;
        rebuild_applied_program_basis(countries, rebuilt_basis);
        if (rebuilt_basis != restored_basis)
            return fail("ideology_save_applied_basis_mismatch");
    }
    // ── plan §18.5: can the payload's SCALAR values be rebuilt from the CURRENT
    // catalogs and state? ─────────────────────────────────────────────────────────
    //
    // The applied basis above pins which PROGRAMS the projection folds; this pins the
    // NUMBERS their programs read. Two identities that agree on every program can
    // still disagree on `equipped_count` or `unlocked_era`, and a reload that silently
    // re-derives a different value reports "restored" while projecting something else.
    //
    // The comparison is a pure function of (payload country rows, current Effect
    // catalog, this runtime's Country domain), run before anything is installed, so a
    // refusal here needs no rollback: `_local_scalar_basis` still holds the previous
    // record and the country table was never moved.
    //
    // The ONE exception is a row whose input this runtime cannot answer -- the
    // `unlocked_era` term needs the Country domain, which a test or a partially-loaded
    // world may not have ready. Those rows are excluded from the comparison (named, not
    // silently zeroed); every other row is still compared strictly, presence included.
    {
        std::vector<LocalScalarValue> rebuilt_scalars;
        std::vector<LocalScalarValue> cross_domain_rows;
        rebuild_local_scalar_basis(countries, rebuilt_scalars, &cross_domain_rows);
        if (!local_scalar_basis_agrees(restored_scalars, rebuilt_scalars,
                cross_domain_rows)) {
            _last_scalar_basis_mismatch_detail = describe_local_scalar_mismatch(
                restored_scalars, rebuilt_scalars, cross_domain_rows);
            return fail("ideology_save_scalar_basis_mismatch");
        }
        _last_scalar_basis_mismatch_detail.clear();
    }
    auto previous_countries = std::move(_countries);
    auto previous_commands = std::move(_commands);
    auto previous_producer_high_watermarks =
        std::move(_producer_high_watermarks);
    const size_t previous_command_cursor = _command_cursor;
    auto previous_pending_transitions = std::move(_pending_transitions);
    const size_t previous_pending_transition_cursor = _pending_transition_cursor;
    const int64_t previous_active_progress_day = _active_progress_day;
    const int64_t previous_daily_continuation_day = _daily_continuation_day;
    const int32_t previous_active_country_cursor = _active_country_cursor;
    const int32_t previous_active_item_cursor = _active_item_cursor;
    const int64_t previous_last_day = _last_day;
    const uint64_t previous_submit_order = _submit_order;
    const uint64_t previous_points_revision_seen = _points_revision_seen;
    const bool previous_worker_origin = _worker_origin;
    _countries = std::move(countries); _commands = std::move(commands);
    _producer_high_watermarks = std::move(producer_high_watermarks);
    _points_revision_seen = points_revision_seen;
    _worker_origin = worker_origin != 0;
    if (schema < 3) {
        for (const Command &command : _commands) {
            auto &high_watermark =
                _producer_high_watermarks[command.producer_id];
            high_watermark = std::max(high_watermark, command.sequence);
        }
    }
    _command_cursor = 0;
    _daily_continuation_day = -1;
    _active_progress_day = -1;
    _active_country_cursor = 0;
    _active_item_cursor = 0;
    _last_day = last_day;
    _submit_order = submit_order;
    const int64_t previous_basis_confirmed_day = _derived_basis_confirmed_day;
    const int64_t previous_basis_eligible_day = _derived_basis_eligible_day;
    _derived_basis_confirmed_day = restored_basis_confirmed_day;
    _derived_basis_eligible_day = restored_basis_eligible_day;
    // Plan §18.2 commit point: the basis the payload described is now the basis this
    // runtime reports. Same treatment as the two dates above -- assigned at the commit
    // point and put back by `rollback`, so a later failure in this restore cannot leave
    // a basis that describes state which was itself rolled back.
    const std::vector<AppliedProgramBasis> previous_applied_basis =
        _applied_program_basis;
    _applied_program_basis = restored_basis;
    // §18.5 commit point: the scalar record and the projection's sample day. Both are
    // MEMBERS, so a failure AFTER this line (the state hash below, a missing Effect
    // instance, a missing binding) has to put them back; otherwise a refused restore
    // would leave this runtime reporting another world's scalar values -- exactly the
    // class of bug the applied-basis member was introduced to make impossible.
    const std::vector<LocalScalarValue> previous_local_scalar_basis =
        _local_scalar_basis;
    _local_scalar_basis = restored_scalars;
    const int64_t previous_basis_sample_day = _derived_basis_sample_day;
    _derived_basis_sample_day = restored_sample_day;
    rebuild_pending_transition_index();
    auto rollback = [&]() {
        _countries = std::move(previous_countries);
        _commands = std::move(previous_commands);
        _producer_high_watermarks =
            std::move(previous_producer_high_watermarks);
        _command_cursor = previous_command_cursor;
        _pending_transitions = std::move(previous_pending_transitions);
        _pending_transition_cursor = previous_pending_transition_cursor;
        _active_progress_day = previous_active_progress_day;
        _daily_continuation_day = previous_daily_continuation_day;
        _active_country_cursor = previous_active_country_cursor;
        _active_item_cursor = previous_active_item_cursor;
        _last_day = previous_last_day;
        _submit_order = previous_submit_order;
        _points_revision_seen = previous_points_revision_seen;
        _worker_origin = previous_worker_origin;
        _derived_basis_confirmed_day = previous_basis_confirmed_day;
        _derived_basis_eligible_day = previous_basis_eligible_day;
        _applied_program_basis = previous_applied_basis;
        _local_scalar_basis = previous_local_scalar_basis;
        _derived_basis_sample_day = previous_basis_sample_day;
    };
    // The hash is taken over the rows that were just verified, not over a fresh
    // derivation: `rebuilt_basis == restored_basis` was proved above, so this is the same
    // number and it resolves every program only once. Same for the scalar rows, whose
    // equality was proved by the §18.5 check above.
    if (compute_state_hash_with(restored_basis, restored_scalars,
            restored_sample_day) != state_hash) {
        rollback();
        return fail("ideology_save_state_hash_mismatch");
    }
    // A card whose effect lives on a reconciled instance is only half-restored by
    // PKID. If the Effect domain lost that instance the card would silently stop
    // producing anything, so prove ownership here instead. PKEF restores first
    // (game_save_coordinator), which makes this an ordering assertion as well.
    //
    // The check has to ask whichever side owns EFFECT: under worker authority
    // EffectRuntime is writeback-only, so the old unconditional query failed every
    // worker-owned instance and rejected a perfectly good save with
    // ideology_effect_instance_missing. "Cannot answer" is deliberately NOT a
    // failure -- a transport that is not ready yet must not fail a restore.
    if (_effect_runtime != nullptr || _effect_forwarder != nullptr) {
        for (const CountryState &country : _countries) {
            for (const IdeaState &state : country.ideas) {
                for (const IdeaState::EffectInstanceRef &ref :
                        state.effect_instances) {
                    bool ref_exists = false;
                    if (!effect_pod_instance_exists(_effect_runtime,
                            _effect_forwarder, ref.instance_id, ref.generation,
                            ref_exists))
                        continue;
                    if (!ref_exists) {
                        rollback();
                        return fail("ideology_effect_instance_missing");
                    }
                }
            }
        }
    }
    if (_worker_origin) {
        // Worker-authored state binds through Modifier UniqueSource rows that
        // PKCM restores and IDP2 audits; it never owned PKEF bindings.
        Dictionary out; out["ok"] = true; out["state_hash"] = static_cast<int64_t>(state_hash);
        out["worker_origin"] = true;
        return out;
    }
    if (_effect_runtime == nullptr) { rollback(); return fail("ideology_effect_runtime_unavailable"); }
    for (const CountryState &country : _countries) {
        std::vector<int64_t> expected_transaction_ids;
        std::vector<uint64_t> expected_source_ids;
        for (const IdeaState &state : country.ideas) {
            if (schema < 2 && (state.location != INACTIVE ||
                    state.transition.active != 0)) {
                rollback();
                return fail("ideology_legacy_active_state_unsupported");
            }
            if (state.location != INACTIVE) {
                const int64_t expected_binding_id = static_cast<int64_t>(
                    binding_id_for(country.handle, state.ideology_id,
                        state.location));
                const uint64_t expected_signature = binding_signature_for(
                    state.ideology_id, state.level);
                const uint64_t expected_program_hash =
                    _effect_runtime->catalog_hash();
                if (state.binding_id != expected_binding_id ||
                    state.binding_generation == 0 ||
                    state.binding_signature != expected_signature ||
                    state.binding_program_hash != expected_program_hash ||
                    !_effect_runtime->has_external_binding_pod(state.binding_id,
                        state.binding_generation, 0x4944454f, state.ideology_id,
                        country.handle, static_cast<uint32_t>(country.handle >> 32U),
                        state.level, state.location, state.binding_signature,
                        state.binding_program_hash)) {
                    rollback();
                    return fail("ideology_effect_binding_missing_or_mismatched");
                }
            }
            if (state.transition.active == 0) continue;
            const uint64_t source_prefix =
                static_cast<uint64_t>(state.ideology_id + 1) << 32U;
            for (const int64_t transaction_id : state.transition.transaction_ids) {
                expected_transaction_ids.push_back(transaction_id);
                expected_source_ids.push_back(source_prefix);
            }
        }
        std::string transaction_error;
        if (!_effect_runtime->verify_external_pending_transactions_pod(
                0x4944454f, country.handle, 0xffffffff00000000ULL,
                expected_transaction_ids, expected_source_ids,
                transaction_error)) {
            rollback();
            return fail(transaction_error.empty()
                ? "ideology_effect_transition_unknown" : transaction_error);
        }
    }
    // Converge the instance set after a load. The verification above proves the
    // saved set still exists; this makes a save that predates a program (or one
    // written by a path that never reconciled) self-heal instead of leaving the
    // card silently inert. Idempotent: a matching set produces no submits.
    for (CountryState &country : _countries)
        reconcile_country_effect_activations(country, std::max<int64_t>(0, _last_day));
    // The restore pass above already revisited every card and stamped its
    // signature, so the first refresh must not repeat it.
    _effect_input_revision_seen = _economy_runtime == nullptr
        ? 0 : economy_api::effect_input_revision(*_economy_runtime);
    _effect_input_revision_target = _effect_input_revision_seen;
    _instance_refresh_pending = false;
    _instance_refresh_dirty = false;
    _instance_refresh_country_cursor = 0;
    recount_managed_active();
    Dictionary out; out["ok"] = true; out["state_hash"] = static_cast<int64_t>(state_hash); return out;
}


} // namespace pk

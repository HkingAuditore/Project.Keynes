#include "runtime_switch_registry.h"
#include "runtime_ideology_pod.h"

#include "runtime_ideology_draw_kernel.h"
#include "runtime_ideology_pod_save_internal.h"
#include <algorithm>
#include <cstring>
#include <limits>
#include <tuple>
#include <type_traits>
#include <unordered_set>

namespace pk {
namespace {

constexpr uint8_t ACQUIRE_DISCOVER = 1u;
constexpr uint8_t ACQUIRE_DRAW = 2u;
constexpr uint16_t EFFECT_TRANSITION_OPCODE = 1u;
constexpr int64_t Q16_ONE = 65536;
// Economy MONEY_SCALE: trade weights are authored per whole money unit.
constexpr int64_t TRADE_MONEY_SCALE = 10000;

int64_t add_sat(int64_t a, int64_t b) {
    if (b > 0 && a > std::numeric_limits<int64_t>::max() - b)
        return std::numeric_limits<int64_t>::max();
    if (b < 0 && a < std::numeric_limits<int64_t>::min() - b)
        return std::numeric_limits<int64_t>::min();
    return a + b;
}

int64_t mul_sat(int64_t a, int64_t b) {
    if (a == 0 || b == 0) return 0;
    if (a == -1 && b == std::numeric_limits<int64_t>::min())
        return std::numeric_limits<int64_t>::max();
    if (b == -1 && a == std::numeric_limits<int64_t>::min())
        return std::numeric_limits<int64_t>::max();
    if (a > 0) {
        if (b > 0 && a > std::numeric_limits<int64_t>::max() / b)
            return std::numeric_limits<int64_t>::max();
        if (b < 0 && b < std::numeric_limits<int64_t>::min() / a)
            return std::numeric_limits<int64_t>::min();
    } else {
        if (b > 0 && a < std::numeric_limits<int64_t>::min() / b)
            return std::numeric_limits<int64_t>::min();
        if (b < 0 && a < std::numeric_limits<int64_t>::max() / b)
            return std::numeric_limits<int64_t>::max();
    }
    return a * b;
}

uint64_t next_random(uint64_t &state) {
    uint64_t value = (state += 0x9e3779b97f4a7c15ull);
    value = (value ^ (value >> 30u)) * 0xbf58476d1ce4e5b9ull;
    value = (value ^ (value >> 27u)) * 0x94d049bb133111ebull;
    return value ^ (value >> 31u);
}

bool bit_get(const std::vector<uint64_t> &bits, int32_t index) {
    return index >= 0 && static_cast<size_t>(index / 64) < bits.size() &&
        (bits[static_cast<size_t>(index / 64)] & (1ull << (index % 64))) != 0;
}

void bit_set(std::vector<uint64_t> &bits, int32_t index, bool value) {
    if (index < 0 || static_cast<size_t>(index / 64) >= bits.size()) return;
    const uint64_t mask = 1ull << (index % 64);
    if (value) bits[static_cast<size_t>(index / 64)] |= mask;
    else bits[static_cast<size_t>(index / 64)] &= ~mask;
}

uint64_t country_handle(const RuntimeCountryPodSnapshot &country, uint32_t slot) {
    return (static_cast<uint64_t>(country.country_generation[slot]) << 32u) | slot;
}

uint64_t producer_high_watermark(
        const RuntimeIdeologyPodSnapshot &state, uint32_t producer_id) {
    for (const auto &watermark : state.producer_high_watermarks)
        if (watermark.producer_id == producer_id) return watermark.sequence;
    return 0;
}

void update_producer_high_watermark(
        RuntimeIdeologyPodSnapshot &state, uint32_t producer_id,
        uint64_t sequence) {
    for (auto &watermark : state.producer_high_watermarks) {
        if (watermark.producer_id != producer_id) continue;
        watermark.sequence = std::max(watermark.sequence, sequence);
        return;
    }
    state.producer_high_watermarks.push_back({producer_id, 0, sequence});
    std::sort(state.producer_high_watermarks.begin(),
              state.producer_high_watermarks.end(),
              [](const RuntimeIdeologyPodProducerWatermark &a,
                 const RuntimeIdeologyPodProducerWatermark &b) {
                  return a.producer_id < b.producer_id;
              });
}

bool queued_producer_sequence(const RuntimeIdeologyPodSnapshot &state,
                              uint32_t producer_id, uint64_t sequence) {
    for (size_t index = state.command_cursor; index < state.commands.size(); ++index) {
        const auto &command = state.commands[index];
        if (command.producer_id == producer_id && command.sequence == sequence)
            return true;
    }
    return false;
}

void copy_error(char (&out)[64], const char *text) {
    runtime_copy_text(out, text);
}

} // namespace

RuntimeIdeologyPodAuthority::RuntimeIdeologyPodAuthority() { reset(); }

void RuntimeIdeologyPodAuthority::reset() {
    _catalog = RuntimeIdeologyPodCatalog{};
    _current = RuntimeIdeologyPodSnapshot{};
    _planned = RuntimeIdeologyPodSnapshot{};
    _configured = false;
    _plan_ready = false;
    _import_supersedes_calendar = false;
}

bool RuntimeIdeologyPodAuthority::command_less(
        const RuntimeIdeologyPodCommand &a,
        const RuntimeIdeologyPodCommand &b) noexcept {
    return std::tie(a.effective_day, a.source_priority, a.producer_id,
                    a.sequence, a.submit_order) <
           std::tie(b.effective_day, b.source_priority, b.producer_id,
                    b.sequence, b.submit_order);
}

bool RuntimeIdeologyPodAuthority::validate_catalog(
        const RuntimeIdeologyPodCatalog &catalog, std::string &error) const {
    if (catalog.abi_version != RUNTIME_IDEOLOGY_POD_ABI_VERSION) {
        error = "ideology_pod_abi_incompatible"; return false;
    }
    if (catalog.route_keys.size() > 31) {
        error = "ideology_pod_catalog_shape_invalid"; return false;
    }
    if (catalog.school_keys.size() > 64 ||
        catalog.school_strength_factor_stat_ids.size() !=
            catalog.school_keys.size()) {
        error = "ideology_pod_school_strength_invalid"; return false;
    }
    {
        std::unordered_set<std::string> seen_schools;
        std::unordered_set<int32_t> seen_stats;
        for (size_t index = 0; index < catalog.school_keys.size(); ++index) {
            if (catalog.school_keys[index].empty() ||
                !seen_schools.insert(catalog.school_keys[index]).second) {
                error = "ideology_pod_school_strength_invalid"; return false;
            }
            const int32_t stat_id =
                catalog.school_strength_factor_stat_ids[index];
            if (stat_id < -1 || (stat_id >= 0 &&
                    !seen_stats.insert(stat_id).second)) {
                error = "ideology_pod_school_strength_invalid"; return false;
            }
        }
    }
    if (catalog.definitions.empty() || catalog.definitions.size() > RUNTIME_IDEOLOGY_POD_MAX_IDEAS ||
        catalog.class_count == 0 || catalog.class_hash == 0 || catalog.country_catalog_hash == 0 ||
        catalog.ideology_capacity < 0 || catalog.spirit_capacity < 0 ||
        catalog.ideology_capacity_max < catalog.ideology_capacity ||
        catalog.spirit_capacity_max < catalog.spirit_capacity ||
        catalog.offer_cost_q16 < 0 || catalog.starting_points_q16 < 0 ||
        catalog.offer_cost_growth_percent < 100 || catalog.offer_cost_growth_percent > 400 ||
        catalog.offer_cost_max_q16 < catalog.offer_cost_q16 ||
        catalog.reroll_cost_percent < 0 || catalog.reroll_cost_percent > 400 ||
        catalog.point_population_weight_q16 < 0 || catalog.point_building_weight_q16 < 0 ||
        catalog.point_trade_weight_q16 < 0 || catalog.point_gain_cap_q16 < 0 ||
        catalog.owner_influence_weight < 0 || catalog.funds_per_influence <= 0 ||
        catalog.understanding_gain_stat_id < -1 ||
        catalog.reroll_cost_stat_id < -1 ||
        catalog.max_commands_per_slice == 0 || catalog.max_transition_commands == 0 ||
        catalog.max_transition_polls_per_slice == 0 || catalog.max_active_visits_per_slice == 0) {
        error = "ideology_pod_catalog_shape_invalid"; return false;
    }
    for (const auto &d : catalog.definitions) {
        if (d.copy_left_programs > 1 || d.copyable > 1 ||
            (!catalog.school_keys.empty() &&
             d.school_index >= catalog.school_keys.size()) ||
            d.rarity_weight <= 0 || d.ideology_cost < 0 || d.spirit_cost < 0 ||
            d.level_count == 0 || d.level_count > 64 ||
            d.level_begin > catalog.levels.size() || d.level_count > catalog.levels.size() - d.level_begin ||
            d.technology_begin > catalog.technology_requirements.size() ||
            d.technology_count > catalog.technology_requirements.size() - d.technology_begin ||
            d.signal_begin > catalog.signal_requirements.size() ||
            d.signal_count > catalog.signal_requirements.size() - d.signal_begin ||
            d.gate_begin > catalog.gate_requirements.size() ||
            d.gate_count > catalog.gate_requirements.size() - d.gate_begin ||
            d.stance_begin > catalog.class_stances.size() ||
            d.stance_count > catalog.class_stances.size() - d.stance_begin) {
            error = "ideology_pod_definition_invalid"; return false;
        }
    }
    for (int32_t id : catalog.technology_requirements)
        if (id < 0 || id >= static_cast<int32_t>(catalog.technology_count)) { error = "ideology_pod_technology_requirement_invalid"; return false; }
    for (int32_t id : catalog.signal_requirements)
        if (id < 0 || id >= static_cast<int32_t>(catalog.research_signal_count)) { error = "ideology_pod_signal_requirement_invalid"; return false; }
    for (int32_t id : catalog.gate_requirements)
        if (id < 0 || id >= static_cast<int32_t>(catalog.gate_count)) { error = "ideology_pod_gate_requirement_invalid"; return false; }
    // 0..10000 basis points per row; an out-of-range row would silently invert a
    // weight into a negative and poison the modulo below.
    for (int32_t decay : catalog.era_decay_bp)
        if (decay < 0 || decay > 10000) { error = "ideology_pod_era_decay_invalid"; return false; }
    if (catalog.refine_weight_bp < 0 || catalog.refine_weight_bp > 10000 ||
        catalog.refine_understanding_q16 < 0) {
        error = "ideology_pod_refine_invalid"; return false;
    }
    for (int32_t technology : catalog.era_milestone_technologies)
        if (technology < -1 || technology >= static_cast<int32_t>(catalog.technology_count)) { error = "ideology_pod_era_milestone_invalid"; return false; }
    for (const auto &d : catalog.definitions)
        if (d.era_index < 0) { error = "ideology_pod_era_index_invalid"; return false; }
    for (const auto &stance : catalog.class_stances)
        if (stance.class_index < 0 || stance.class_index >= static_cast<int32_t>(catalog.class_count)) { error = "ideology_pod_class_stance_invalid"; return false; }
    for (const auto &requirement : catalog.synergy_requirements)
        if (requirement.ideology_id < 0 || requirement.ideology_id >= static_cast<int32_t>(catalog.definitions.size()) || requirement.minimum_level < 0 || requirement.location_mask == 0) { error = "ideology_pod_synergy_requirement_invalid"; return false; }
    for (const auto &synergy : catalog.synergies)
        if (synergy.requirement_begin > catalog.synergy_requirements.size() || synergy.requirement_count > catalog.synergy_requirements.size() - synergy.requirement_begin ||
            synergy.min_count > synergy.requirement_count ||
            synergy.modifier_begin > catalog.synergy_modifiers.size() || synergy.modifier_count > catalog.synergy_modifiers.size() - synergy.modifier_begin) { error = "ideology_pod_synergy_invalid"; return false; }
    for (const auto &level : catalog.levels)
        if (level.modifier_begin > catalog.level_modifiers.size() || level.modifier_count > catalog.level_modifiers.size() - level.modifier_begin) { error = "ideology_pod_level_modifier_invalid"; return false; }
    for (const auto *rows : {&catalog.level_modifiers, &catalog.synergy_modifiers})
        for (const auto &row : *rows)
            if (row.definition_key_hash == 0 || row.domain < 0 || row.domain > 3 || row.magnitude_q16 < 0 || row.magnitude_q16 > 4 * Q16_ONE) { error = "ideology_pod_modifier_template_invalid"; return false; }
    for (const auto &unlock : catalog.capacity_unlocks)
        if (unlock.technology_id < 0 || unlock.technology_id >= static_cast<int32_t>(catalog.technology_count) || unlock.ideology_delta < 0 || unlock.spirit_delta < 0) { error = "ideology_pod_capacity_unlock_invalid"; return false; }
    if (catalog.ideology_synergy_offsets.size() != catalog.definitions.size() + 1u ||
        catalog.ideology_synergy_offsets.front() != 0u ||
        catalog.ideology_synergy_offsets.back() != catalog.ideology_synergy_ids.size()) {
        error = "ideology_pod_synergy_reverse_invalid";
        return false;
    }
    uint32_t previous_offset = 0;
    for (size_t ideology = 0; ideology < catalog.definitions.size(); ++ideology) {
        const uint32_t begin = catalog.ideology_synergy_offsets[ideology];
        const uint32_t end = catalog.ideology_synergy_offsets[ideology + 1u];
        if (begin < previous_offset || end < begin ||
            end > catalog.ideology_synergy_ids.size()) {
            error = "ideology_pod_synergy_reverse_invalid";
            return false;
        }
        int32_t previous_synergy = -1;
        for (uint32_t row = begin; row < end; ++row) {
            const int32_t synergy_id = catalog.ideology_synergy_ids[row];
            if (synergy_id < 0 ||
                synergy_id >= static_cast<int32_t>(catalog.synergies.size()) ||
                synergy_id <= previous_synergy) {
                error = "ideology_pod_synergy_reverse_invalid";
                return false;
            }
            previous_synergy = synergy_id;
        }
        previous_offset = end;
    }
    const uint64_t expected = compute_catalog_hash(catalog);
    if (catalog.catalog_hash != 0 && catalog.catalog_hash != expected) {
        error = "ideology_pod_catalog_hash_invalid"; return false;
    }
    return true;
}

bool RuntimeIdeologyPodAuthority::configure(
        const RuntimeIdeologyPodCatalog &catalog, std::string &error) {
    error.clear();
    if (!validate_catalog(catalog, error)) return false;
    _catalog = catalog;
    _catalog.catalog_hash = compute_catalog_hash(catalog);
    _current = RuntimeIdeologyPodSnapshot{};
    _current.catalog_hash = _catalog.catalog_hash;
    _current.state_hash = compute_state_hash(_current);
    _planned = _current;
    _configured = true;
    _plan_ready = false;
    // A fresh catalog is a fresh lifetime: nothing has been imported into it yet, so a
    // later backwards day must still fail loudly.
    _import_supersedes_calendar = false;
    return true;
}

bool RuntimeIdeologyPodAuthority::validate_inputs(
        const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion,
        std::string &error) const {
    if (!_configured) { error = "ideology_pod_not_configured"; return false; }
    if (!country.bootstrapped || country.generation == 0 ||
        country.catalog_hash != _catalog.country_catalog_hash ||
        country.technology_count != _catalog.technology_count ||
        country.research_signal_count != _catalog.research_signal_count ||
        country.country_count == 0 || country.country_count > RUNTIME_IDEOLOGY_POD_MAX_COUNTRIES ||
        country.country_active.size() != country.country_count ||
        country.country_generation.size() != country.country_count ||
        country.technology_words != (_catalog.technology_count + 63u) / 64u ||
        country.research_signal_words != (_catalog.research_signal_count + 63u) / 64u ||
        country.country_technologies.size() != static_cast<size_t>(country.country_count) * country.technology_words ||
        country.country_discovered.size() != static_cast<size_t>(country.country_count) * country.technology_words ||
        country.country_pending_technologies.size() != static_cast<size_t>(country.country_count) * country.technology_words ||
        country.country_research_signals.size() != static_cast<size_t>(country.country_count) * country.research_signal_words) {
        error = "ideology_country_snapshot_shape_invalid"; return false;
    }
    // Country commits before Ideology. Its new slots have no rows in the
    // previous Economy commit. Validate the source's own shape and identities.
    const uint32_t measured_countries = opinion.country_count;
    const size_t lanes = static_cast<size_t>(measured_countries) * _catalog.class_count;
    // Revision 0 stays REJECTED. It was briefly relaxed for the A1 day-binding
    // experiment ("no opinion for this day" handed over as revision 0), but that
    // binding is not landed (05 §2.6) and the rejection is a real invariant:
    // `ideology_self_test_revision_rejection_failed` asserts it.
    if (opinion.revision == 0 || opinion.class_hash != _catalog.class_hash ||
        opinion.class_count != _catalog.class_count || measured_countries == 0 ||
        measured_countries > country.country_count ||
        (measured_countries < country.country_count &&
         opinion.committed_day >= country.committed_day) ||
        opinion.country_handles.size() != measured_countries ||
        opinion.country_generations.size() != measured_countries ||
        opinion.population.size() != lanes || opinion.funds.size() != lanes ||
        opinion.owner_employed.size() != lanes || opinion.satisfaction_weighted.size() != lanes ||
        opinion.satisfaction_q16.size() != lanes) {
        error = "ideology_opinion_snapshot_shape_invalid"; return false;
    }
    // The incidence table drives the support gate, so a malformed one must be a
    // named rejection here rather than an out-of-range read in support_allows().
    if (opinion.incidence_channel_count < 0 ||
        (opinion.incidence_channel_count == 0
             ? (!opinion.class_incidence_q16.empty() ||
                (!opinion.incidence_measured.empty() &&
                 opinion.incidence_measured.size() != measured_countries))
             : (opinion.incidence_measured.size() != measured_countries ||
                opinion.class_incidence_q16.size() !=
                    lanes * static_cast<size_t>(opinion.incidence_channel_count)))) {
        error = "ideology_opinion_snapshot_shape_invalid"; return false;
    }
    for (uint32_t slot = 0; slot < measured_countries; ++slot) {
        if (opinion.country_generations[slot] != country.country_generation[slot] ||
            opinion.country_handles[slot] != country_handle(country, slot)) {
            error = "ideology_country_generation_mismatch"; return false;
        }
    }
    // A founded country extends the table. Existing rows must still match
    // their original handles and generations.
    if (!_current.countries.empty()) {
        if (_current.countries.size() > country.country_count ||
            (_current.round_day >= 0 && _current.countries.size() != country.country_count)) {
            error = "ideology_country_state_shape_mismatch"; return false;
        }
        for (size_t slot = 0; slot < _current.countries.size(); ++slot) {
            const auto &current = _current.countries[slot];
            const uint64_t expected_handle = country_handle(country, slot);
            if (country.country_active[slot] == 0) {
                if (current.handle != 0) {
                    error = "ideology_country_state_generation_mismatch";
                    return false;
                }
                continue;
            }
            if (current.handle != expected_handle ||
                current.generation != country.country_generation[slot]) {
                error = "ideology_country_state_generation_mismatch";
                return false;
            }
        }
    }
    return true;
}

void RuntimeIdeologyPodAuthority::append_country_rows(RuntimeIdeologyPodSnapshot &state,
        const std::vector<uint8_t> &active, const std::vector<uint32_t> &generations,
        uint64_t opinion_revision) const {
    if (state.countries.size() == active.size()) return;
    const size_t first = state.countries.size();
    state.countries.resize(active.size());
    const size_t idea_words = (_catalog.definitions.size() + 63u) / 64u;
    const size_t gate_words = (_catalog.gate_count + 63u) / 64u;
    const size_t synergy_words = (_catalog.synergies.size() + 63u) / 64u;
    for (size_t slot = first; slot < active.size(); ++slot) {
        auto &out = state.countries[slot];
        if (active[slot] == 0) continue;
        out.generation = generations[slot];
        out.handle = (uint64_t(out.generation) << 32) | uint32_t(slot);
        out.ideology_points_q16 = _catalog.starting_points_q16;
        // Seed from the handle and the SHARED constant only. Seeding from
        // `_catalog.catalog_hash` made the two sides disagree by construction,
        // because the main thread and the worker hash their catalogs with
        // different functions.
        out.rng_state = runtime_ideology_country_rng_seed(out.handle,
                                                         _catalog.world_seed);
        out.opinion_revision = opinion_revision;
        out.known_bits.assign(idea_words, 0);
        out.banned_bits.assign(idea_words, 0);
        out.gate_bits.assign(gate_words, 0);
        out.synergy_bits.assign(synergy_words, 0);
        out.ideas.resize(_catalog.definitions.size());
    }
}

bool RuntimeIdeologyPodAuthority::bootstrap(
        const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion,
        std::string &error) {
    if (!validate_inputs(country, opinion, error)) return false;
    RuntimeIdeologyPodSnapshot state;
    state.catalog_hash = _catalog.catalog_hash;
    state.input_generation = country.generation;
    state.opinion_revision = opinion.revision;
    append_country_rows(state, country.country_active, country.country_generation, opinion.revision);
    state.state_hash = compute_state_hash(state);
    _current = std::move(state);
    for (auto &country_row : _current.countries)
        rebuild_active_idea_ids(country_row);
    _planned = _current;
    _plan_ready = false;
    return true;
}

bool RuntimeIdeologyPodAuthority::validate_command(
        const RuntimeIdeologyPodCommand &command, std::string &error) const {
    const auto opcode = static_cast<uint16_t>(command.opcode);
    if (opcode < 1 || opcode > 12 || command.request_id == 0 ||
        command.producer_id == 0 || command.country_handle == 0 ||
        command.effective_day < 0 || command.requested_day < 0) {
        error = "ideology_command_invalid"; return false;
    }
    if ((command.opcode == RuntimeIdeologyPodOpcode::DISCOVER ||
         command.opcode == RuntimeIdeologyPodOpcode::EQUIP ||
         command.opcode == RuntimeIdeologyPodOpcode::UNEQUIP ||
         command.opcode == RuntimeIdeologyPodOpcode::PROMOTE ||
         command.opcode == RuntimeIdeologyPodOpcode::BAN_CARD ||
         command.opcode == RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING) &&
        (command.ideology_id < 0 || command.ideology_id >= static_cast<int32_t>(_catalog.definitions.size()))) {
        error = "ideology_id_invalid"; return false;
    }
    if ((command.opcode == RuntimeIdeologyPodOpcode::GRANT_POINTS ||
         command.opcode == RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING) && command.value_q16 < 0) {
        error = "ideology_value_negative"; return false;
    }
    if (command.opcode == RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW &&
            (command.value_q16 <= 0 || command.value_q16 > 65535 ||
             command.ideology_id != -1)) {
        error = "ideology_free_draw_invalid"; return false;
    }
    if (command.opcode == RuntimeIdeologyPodOpcode::SET_GATE &&
        (command.gate_id < 0 || command.gate_id >= static_cast<int32_t>(_catalog.gate_count))) {
        error = "ideology_gate_invalid"; return false;
    }
    return true;
}

bool RuntimeIdeologyPodAuthority::queue_command(
        RuntimeIdeologyPodCommand command, std::string &error) {
    if (_plan_ready) { error = "ideology_plan_active"; return false; }
    if (!validate_command(command, error)) return false;
    if (_current.commands.size() >= RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) {
        error = "ideology_command_capacity_exceeded"; return false;
    }
    if (command.sequence <= producer_high_watermark(_current, command.producer_id) ||
        queued_producer_sequence(_current, command.producer_id, command.sequence)) {
        return true;
    }
    if (command.submit_order == 0) command.submit_order = _current.next_submit_order++;
    else _current.next_submit_order = std::max(_current.next_submit_order, command.submit_order + 1u);
    _current.commands.push_back(command);
    std::stable_sort(_current.commands.begin() + static_cast<std::ptrdiff_t>(_current.command_cursor),
                     _current.commands.end(), command_less);
    _current.state_hash = compute_state_hash(_current);
    return true;
}

#include "runtime_ideology_pod_active_card_transitions.inc"
#include "runtime_ideology_pod_offers_and_points.inc"
#include "runtime_ideology_pod_daily_authority.inc"
#include "runtime_ideology_pod_selftest.inc"

} // namespace pk

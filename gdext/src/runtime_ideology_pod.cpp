#include "runtime_ideology_pod.h"

#include "runtime_ideology_draw_kernel.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <tuple>
#include <type_traits>
#include <unordered_set>

namespace pk {
namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;
constexpr uint32_t SAVE_MAGIC = 0x32504449u; // IDP2
constexpr uint32_t SAVE_END = 0x21444e45u;
constexpr uint32_t MAX_SAVE_BYTES = 64u * 1024u * 1024u;
// Matches NativeIdeologyRuntime::MAX_ERA_INDEX so a command accepted by the
// main runtime can never be rejected by the worker (or vice versa).
constexpr int32_t kMaxEraIndex = 63;
constexpr uint8_t ACQUIRE_DISCOVER = 1u;
constexpr uint8_t ACQUIRE_DRAW = 2u;
constexpr uint16_t EFFECT_TRANSITION_OPCODE = 1u;
constexpr int64_t Q16_ONE = 65536;
// Economy MONEY_SCALE: trade weights are authored per whole money unit.
constexpr int64_t TRADE_MONEY_SCALE = 10000;

template <typename T, bool = std::is_enum_v<std::remove_cv_t<T>>>
struct raw_type { using type = std::remove_cv_t<T>; };
template <typename T>
struct raw_type<T, true> { using type = std::underlying_type_t<std::remove_cv_t<T>>; };

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    using Raw = typename raw_type<T>::type;
    using U = std::make_unsigned_t<Raw>;
    U bits = static_cast<U>(static_cast<Raw>(value));
    for (size_t i = 0; i < sizeof(Raw); ++i) {
        out.push_back(static_cast<uint8_t>(bits & static_cast<U>(0xffu)));
        bits >>= 8u;
    }
}

template <typename T>
bool read_le(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    using Raw = typename raw_type<T>::type;
    using U = std::make_unsigned_t<Raw>;
    if (data == nullptr || cursor > size || size - cursor < sizeof(Raw)) return false;
    U bits = 0;
    for (size_t i = 0; i < sizeof(Raw); ++i)
        bits |= static_cast<U>(data[cursor + i]) << (i * 8u);
    cursor += sizeof(Raw);
    value = static_cast<T>(static_cast<Raw>(bits));
    return true;
}

uint64_t hash_bytes(uint64_t hash, const void *data, size_t size) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

template <typename T>
uint64_t hash_value(uint64_t hash, const T &value) {
    return hash_bytes(hash, &value, sizeof(value));
}

template <typename T>
uint64_t hash_vector(uint64_t hash, const std::vector<T> &values) {
    hash = hash_value(hash, static_cast<uint64_t>(values.size()));
    for (const T &value : values) hash = hash_value(hash, value);
    return hash;
}

uint64_t hash_text_vector(uint64_t hash, const std::vector<std::string> &values) {
    hash = hash_value(hash, static_cast<uint64_t>(values.size()));
    for (const std::string &value : values)
        hash = hash_bytes(hash, value.data(), value.size());
    return hash;
}

template <typename T>
void append_vector(std::vector<uint8_t> &out, const std::vector<T> &values) {
    append_le<uint32_t>(out, static_cast<uint32_t>(values.size()));
    for (const T value : values) append_le<T>(out, value);
}

template <typename T>
bool read_vector(const uint8_t *data, size_t size, size_t &cursor,
                 std::vector<T> &out, uint32_t limit) {
    uint32_t count = 0;
    if (!read_le(data, size, cursor, count) || count > limit) return false;
    out.resize(count);
    for (T &value : out) if (!read_le(data, size, cursor, value)) return false;
    return true;
}

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

void rebuild_active_idea_ids(RuntimeIdeologyPodCountryState &country) {
    country.active_idea_ids.clear();
    country.active_idea_ids.reserve(country.ideas.size());
    for (uint32_t ideology_id = 0; ideology_id < country.ideas.size(); ++ideology_id) {
        if (country.ideas[ideology_id].location != RuntimeIdeologyPodLocation::INACTIVE)
            country.active_idea_ids.push_back(ideology_id);
    }
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

uint64_t RuntimeIdeologyPodAuthority::compute_catalog_hash(
        const RuntimeIdeologyPodCatalog &catalog) {
    uint64_t hash = FNV_OFFSET;
    hash = hash_value(hash, catalog.abi_version);
    hash = hash_value(hash, catalog.country_catalog_hash);
    // The offer RNG depends on it, so a peer with a different world seed draws a
    // different card from the same sequence and must be rejected up front.
    hash = hash_value(hash, catalog.world_seed);
    hash = hash_value(hash, catalog.class_hash);
    hash = hash_value(hash, catalog.class_count);
    hash = hash_value(hash, catalog.technology_count);
    hash = hash_value(hash, catalog.research_signal_count);
    hash = hash_value(hash, catalog.gate_count);
    hash = hash_value(hash, catalog.ideology_capacity);
    hash = hash_value(hash, catalog.spirit_capacity);
    hash = hash_value(hash, catalog.ideology_capacity_max);
    hash = hash_value(hash, catalog.spirit_capacity_max);
    hash = hash_value(hash, catalog.offer_cost_q16);
    hash = hash_value(hash, catalog.offer_cost_growth_percent);
    hash = hash_value(hash, catalog.offer_cost_max_q16);
    hash = hash_value(hash, catalog.reroll_cost_percent);
    hash = hash_value(hash, catalog.starting_points_q16);
    hash = hash_value(hash, catalog.point_population_weight_q16);
    hash = hash_value(hash, catalog.point_building_weight_q16);
    hash = hash_value(hash, catalog.point_trade_weight_q16);
    hash = hash_value(hash, catalog.point_gain_cap_q16);
    hash = hash_value(hash, catalog.point_gain_stat_id);
    hash = hash_text_vector(hash, catalog.route_keys);
    hash = hash_value(hash, catalog.point_population_factor_stat_id);
    hash = hash_value(hash, catalog.point_building_factor_stat_id);
    hash = hash_value(hash, catalog.point_trade_factor_stat_id);
    hash = hash_value(hash, catalog.opinion_factor_floor_stat_id);
    hash = hash_text_vector(hash, catalog.school_keys);
    hash = hash_vector(hash, catalog.school_strength_factor_stat_ids);
    hash = hash_value(hash, catalog.understanding_gain_stat_id);
    hash = hash_value(hash, catalog.reroll_cost_stat_id);
    hash = hash_value(hash, catalog.owner_influence_weight);
    hash = hash_value(hash, catalog.funds_per_influence);
    hash = hash_value(hash, catalog.max_commands_per_slice);
    hash = hash_value(hash, catalog.max_transition_commands);
    hash = hash_value(hash, catalog.max_transition_polls_per_slice);
    hash = hash_value(hash, catalog.max_active_visits_per_slice);
    for (const auto &d : catalog.definitions) {
        hash = hash_value(hash, d.acquisition); hash = hash_value(hash, d.rarity_weight);
        hash = hash_value(hash, d.copy_left_programs);
        hash = hash_value(hash, d.copyable);
        hash = hash_value(hash, d.school_index);
        hash = hash_value(hash, d.ideology_cost); hash = hash_value(hash, d.spirit_cost);
        hash = hash_value(hash, d.min_spirit_level); hash = hash_value(hash, d.level_begin);
        hash = hash_value(hash, d.level_count); hash = hash_value(hash, d.technology_begin);
        hash = hash_value(hash, d.technology_count); hash = hash_value(hash, d.signal_begin);
        hash = hash_value(hash, d.signal_count); hash = hash_value(hash, d.gate_begin);
        hash = hash_value(hash, d.gate_count); hash = hash_value(hash, d.stance_begin);
        hash = hash_value(hash, d.stance_count);
        for (int32_t value : d.support_threshold_q16) hash = hash_value(hash, value);
        hash = hash_value(hash, d.exclusion_group_id);
        hash = hash_value(hash, d.era_index);
        hash = hash_value(hash, d.route_mask);
    }
    for (const auto &level : catalog.levels) {
        hash = hash_value(hash, level.threshold_q16);
        hash = hash_value(hash, level.daily_understanding_q16);
        hash = hash_value(hash, level.modifier_begin);
        hash = hash_value(hash, level.modifier_count);
        hash = hash_value(hash, level.on_enter_free_draws);
    }
    hash = hash_vector(hash, catalog.technology_requirements);
    hash = hash_vector(hash, catalog.signal_requirements);
    hash = hash_vector(hash, catalog.gate_requirements);
    // Peers that disagree on the decay curve would draw different cards from the
    // same seed, so the curve is part of the catalog contract.
    hash = hash_vector(hash, catalog.era_decay_bp);
    hash = hash_vector(hash, catalog.era_milestone_technologies);
    // 精进 changes which cards may appear at all, so it belongs in the contract
    // for the same reason the decay curve does.
    hash = hash_value(hash, catalog.refine_weight_bp);
    hash = hash_value(hash, catalog.refine_understanding_q16);
    hash = hash_value(hash, catalog.draw_count);
    for (const auto &stance : catalog.class_stances) {
        hash = hash_value(hash, stance.class_index);
        for (int32_t value : stance.stance_q16) hash = hash_value(hash, value);
        for (int32_t value : stance.critical_min_q16) hash = hash_value(hash, value);
    }
    for (const auto &requirement : catalog.synergy_requirements) {
        hash = hash_value(hash, requirement.ideology_id);
        hash = hash_value(hash, requirement.minimum_level);
        hash = hash_value(hash, requirement.location_mask);
    }
    for (const auto &synergy : catalog.synergies) {
        hash = hash_value(hash, synergy.requirement_begin);
        hash = hash_value(hash, synergy.requirement_count);
        hash = hash_value(hash, synergy.min_count);
        hash = hash_value(hash, synergy.modifier_begin);
        hash = hash_value(hash, synergy.modifier_count);
    }
    hash = hash_vector(hash, catalog.ideology_synergy_offsets);
    hash = hash_vector(hash, catalog.ideology_synergy_ids);
    for (const auto *rows : {&catalog.level_modifiers, &catalog.synergy_modifiers}) {
        hash = hash_value(hash, static_cast<uint64_t>(rows->size()));
        for (const auto &row : *rows) {
            hash = hash_value(hash, row.definition_key_hash);
            hash = hash_value(hash, row.domain);
            hash = hash_value(hash, row.magnitude_q16);
        }
    }
    hash = hash_value(hash, static_cast<uint64_t>(catalog.capacity_unlocks.size()));
    for (const auto &unlock : catalog.capacity_unlocks) {
        hash = hash_value(hash, unlock.technology_id);
        hash = hash_value(hash, unlock.ideology_delta);
        hash = hash_value(hash, unlock.spirit_delta);
    }
    return hash;
}

uint64_t RuntimeIdeologyPodAuthority::compute_state_hash(
        const RuntimeIdeologyPodSnapshot &state) {
    uint64_t hash = FNV_OFFSET;
    hash = hash_value(hash, state.catalog_hash); hash = hash_value(hash, state.input_generation);
    hash = hash_value(hash, state.opinion_revision); hash = hash_value(hash, state.generation);
    hash = hash_value(hash, state.committed_day); hash = hash_value(hash, state.round_day);
    hash = hash_value(hash, state.phase); hash = hash_value(hash, state.pending_cursor);
    hash = hash_value(hash, state.command_cursor); hash = hash_value(hash, state.active_country_cursor);
    hash = hash_value(hash, state.active_idea_cursor); hash = hash_value(hash, state.next_submit_order);
    hash = hash_value(hash, static_cast<uint64_t>(state.producer_high_watermarks.size()));
    for (const auto &watermark : state.producer_high_watermarks) {
        hash = hash_value(hash, watermark.producer_id);
        hash = hash_value(hash, watermark.sequence);
    }
    hash = hash_value(hash, static_cast<uint64_t>(state.countries.size()));
    for (const auto &country : state.countries) {
        hash = hash_value(hash, country.handle); hash = hash_value(hash, country.generation);
        hash = hash_value(hash, country.ideology_points_q16); hash = hash_value(hash, country.rng_state);
        hash = hash_value(hash, country.free_draws);
        hash = hash_value(hash, country.points_revision); hash = hash_value(hash, country.baseline_ready);
        hash = hash_value(hash, country.history_count); hash = hash_value(hash, country.history_head);
        hash = hash_value(hash, country.baseline_population); hash = hash_value(hash, country.baseline_buildings);
        hash = hash_value(hash, country.lifetime_points_q16);
    hash = hash_value(hash, country.trade_paid_day);
        hash = hash_value(hash, country.ledger.population_q16); hash = hash_value(hash, country.ledger.building_q16);
        hash = hash_value(hash, country.ledger.trade_q16); hash = hash_value(hash, country.ledger.opinion_factor_q16);
        hash = hash_value(hash, country.ledger.gain_factor_q16); hash = hash_value(hash, country.ledger.gain_q16);
        hash = hash_value(hash, country.ledger.day);
        for (int64_t value : country.history_q16) hash = hash_value(hash, value);
        hash = hash_value(hash, country.draw_sequence); hash = hash_value(hash, country.ideology_slots_used);
        hash = hash_value(hash, country.spirit_slots_used); hash = hash_value(hash, country.unlocked_era);
        hash = hash_value(hash, country.opinion_revision);
        hash = hash_value(hash, country.offer.generation); hash = hash_value(hash, country.offer.active);
        hash = hash_value(hash, country.offer.choice_count);
        for (int32_t id : country.offer.ideology_ids) hash = hash_value(hash, id);
        hash = hash_vector(hash, country.known_bits); hash = hash_vector(hash, country.banned_bits);
        hash = hash_vector(hash, country.gate_bits);
        hash = hash_vector(hash, country.synergy_bits);
        hash = hash_vector(hash, country.active_idea_ids);
        hash = hash_value(hash, static_cast<uint64_t>(country.ideas.size()));
        for (const auto &idea : country.ideas) {
            hash = hash_value(hash, idea.understanding_q16); hash = hash_value(hash, idea.level);
            hash = hash_value(hash, idea.entered_levels); hash = hash_value(hash, idea.generation);
            hash = hash_value(hash, idea.location); hash = hash_value(hash, idea.slot_index);
        }
    }
    hash = hash_value(hash, static_cast<uint64_t>(state.commands.size()));
    for (const auto &command : state.commands) {
        hash = hash_value(hash, command.request_id); hash = hash_value(hash, command.source_priority);
        hash = hash_value(hash, command.producer_id); hash = hash_value(hash, command.sequence);
        hash = hash_value(hash, command.submit_order); hash = hash_value(hash, command.requested_day);
        hash = hash_value(hash, command.effective_day); hash = hash_value(hash, command.opcode);
        hash = hash_value(hash, command.country_handle); hash = hash_value(hash, command.ideology_id);
        hash = hash_value(hash, command.value_q16); hash = hash_value(hash, command.offer_generation);
        hash = hash_value(hash, command.choice_index); hash = hash_value(hash, command.gate_id);
    }
    hash = hash_value(hash, static_cast<uint64_t>(state.pending_transitions.size()));
    for (const auto &transition : state.pending_transitions) {
        hash = hash_value(hash, transition.intent_id); hash = hash_value(hash, transition.request_id);
        hash = hash_value(hash, transition.producer_id); hash = hash_value(hash, transition.sequence);
        hash = hash_value(hash, transition.effective_day); hash = hash_value(hash, transition.country_slot);
        hash = hash_value(hash, transition.country_generation); hash = hash_value(hash, transition.ideology_id);
        hash = hash_value(hash, transition.desired_level); hash = hash_value(hash, transition.desired_entered_levels);
        hash = hash_value(hash, transition.desired_location);
        hash = hash_value(hash, transition.desired_slot_index);
        hash = hash_value(hash, transition.intent_emitted);
        hash = hash_value(hash, transition.previous_entered_levels);
        hash = hash_vector(hash, transition.desired_synergy_bits);
    }
    hash = hash_value(hash, static_cast<uint64_t>(state.receipts.size()));
    for (const auto &receipt : state.receipts) {
        hash = hash_value(hash, receipt.request_id); hash = hash_value(hash, receipt.producer_id);
        hash = hash_value(hash, receipt.sequence); hash = hash_value(hash, receipt.status);
        hash = hash_value(hash, receipt.opcode); hash = hash_value(hash, receipt.country_handle);
        hash = hash_value(hash, receipt.ideology_id); hash = hash_value(hash, receipt.settled_day);
        hash = hash_value(hash, receipt.reason_code);
    }
    return hash;
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
    const size_t lanes = static_cast<size_t>(country.country_count) * _catalog.class_count;
    // Revision 0 stays REJECTED. It was briefly relaxed for the A1 day-binding
    // experiment ("no opinion for this day" handed over as revision 0), but that
    // binding is not landed (05 §2.6) and the rejection is a real invariant:
    // `ideology_self_test_revision_rejection_failed` asserts it.
    if (opinion.revision == 0 || opinion.class_hash != _catalog.class_hash ||
        opinion.class_count != _catalog.class_count || opinion.country_count != country.country_count ||
        opinion.country_handles.size() != country.country_count ||
        opinion.country_generations.size() != country.country_count ||
        opinion.population.size() != lanes || opinion.funds.size() != lanes ||
        opinion.owner_employed.size() != lanes || opinion.satisfaction_weighted.size() != lanes ||
        opinion.satisfaction_q16.size() != lanes) {
        error = "ideology_opinion_snapshot_shape_invalid"; return false;
    }
    for (uint32_t slot = 0; slot < country.country_count; ++slot) {
        if (opinion.country_generations[slot] != country.country_generation[slot] ||
            opinion.country_handles[slot] != country_handle(country, slot)) {
            error = "ideology_country_generation_mismatch"; return false;
        }
    }
    // Once bootstrapped, the worker state is tied to the exact Country handle
    // table it was captured from. A newer/reused Country generation must not
    // replay commands against retained ideology state.
    if (!_current.countries.empty()) {
        if (_current.countries.size() != country.country_count) {
            error = "ideology_country_state_shape_mismatch"; return false;
        }
        for (uint32_t slot = 0; slot < country.country_count; ++slot) {
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

bool RuntimeIdeologyPodAuthority::bootstrap(
        const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion,
        std::string &error) {
    if (!validate_inputs(country, opinion, error)) return false;
    RuntimeIdeologyPodSnapshot state;
    state.catalog_hash = _catalog.catalog_hash;
    state.input_generation = country.generation;
    state.opinion_revision = opinion.revision;
    state.countries.resize(country.country_count);
    const size_t idea_words = (_catalog.definitions.size() + 63u) / 64u;
    const size_t gate_words = (_catalog.gate_count + 63u) / 64u;
    const size_t synergy_words = (_catalog.synergies.size() + 63u) / 64u;
    for (uint32_t slot = 0; slot < country.country_count; ++slot) {
        auto &out = state.countries[slot];
        if (country.country_active[slot] == 0) continue;
        out.handle = country_handle(country, slot);
        out.generation = country.country_generation[slot];
        out.ideology_points_q16 = _catalog.starting_points_q16;
        // Seed from the handle and the SHARED constant only. Seeding from
        // `_catalog.catalog_hash` made the two sides disagree by construction,
        // because the main thread and the worker hash their catalogs with
        // different functions.
        out.rng_state = runtime_ideology_country_rng_seed(out.handle,
                                                         _catalog.world_seed);
        out.opinion_revision = opinion.revision;
        out.known_bits.assign(idea_words, 0);
        out.banned_bits.assign(idea_words, 0);
        out.gate_bits.assign(gate_words, 0);
        out.synergy_bits.assign(synergy_words, 0);
        out.ideas.resize(_catalog.definitions.size());
    }
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

bool RuntimeIdeologyPodAuthority::requirements_met(
        const RuntimeIdeologyPodSnapshot &state,
        const RuntimeCountryPodSnapshot &country, uint32_t slot,
        int32_t ideology_id) const {
    const auto &d = _catalog.definitions[static_cast<size_t>(ideology_id)];
    for (uint32_t i = 0; i < d.technology_count; ++i) {
        const int32_t id = _catalog.technology_requirements[d.technology_begin + i];
        const size_t index = static_cast<size_t>(slot) * country.technology_words + id / 64;
        if ((country.country_technologies[index] & (1ull << (id % 64))) == 0) return false;
    }
    for (uint32_t i = 0; i < d.signal_count; ++i) {
        const int32_t id = _catalog.signal_requirements[d.signal_begin + i];
        const size_t index = static_cast<size_t>(slot) * country.research_signal_words + id / 64;
        if ((country.country_research_signals[index] & (1ull << (id % 64))) == 0) return false;
    }
    for (uint32_t i = 0; i < d.gate_count; ++i)
        if (!bit_get(state.countries[slot].gate_bits, _catalog.gate_requirements[d.gate_begin + i])) return false;
    return true;
}

bool RuntimeIdeologyPodAuthority::support_allows(
        const RuntimeIdeologyPodSnapshot &state,
        const RuntimeIdeologyOpinionSnapshot &opinion, uint32_t slot,
        int32_t ideology_id, uint32_t direction) const {
    (void)state;
    const auto &d = _catalog.definitions[static_cast<size_t>(ideology_id)];
    if (d.stance_count == 0) return true;
    int64_t total = 0;
    int64_t weighted = 0;
    for (uint32_t class_index = 0; class_index < _catalog.class_count; ++class_index) {
        const size_t lane = static_cast<size_t>(slot) * _catalog.class_count + class_index;
        int64_t influence = std::max<int64_t>(0, opinion.population[lane]);
        influence = add_sat(influence, mul_sat(std::max<int64_t>(0, opinion.owner_employed[lane]), _catalog.owner_influence_weight));
        influence = add_sat(influence, std::max<int64_t>(0, opinion.funds[lane]) / _catalog.funds_per_influence);
        total = add_sat(total, influence);
    }
    if (total <= 0) return false;
    for (uint32_t row = 0; row < d.stance_count; ++row) {
        const auto &stance = _catalog.class_stances[d.stance_begin + row];
        const size_t lane = static_cast<size_t>(slot) * _catalog.class_count + static_cast<uint32_t>(stance.class_index);
        int64_t influence = std::max<int64_t>(0, opinion.population[lane]);
        influence = add_sat(influence, mul_sat(std::max<int64_t>(0, opinion.owner_employed[lane]), _catalog.owner_influence_weight));
        influence = add_sat(influence, std::max<int64_t>(0, opinion.funds[lane]) / _catalog.funds_per_influence);
        const int32_t stance_value = stance.stance_q16[direction];
        weighted = add_sat(weighted, mul_sat(influence, stance_value));
        const int32_t critical = stance.critical_min_q16[direction];
        if (critical >= -65536 && (influence <= 0 || stance_value < critical)) return false;
    }
    const int64_t support = std::clamp<int64_t>(weighted / total, -Q16_ONE, Q16_ONE);
    return support >= d.support_threshold_q16[direction];
}

int32_t RuntimeIdeologyPodAuthority::unlocked_level(
        const RuntimeIdeologyPodIdeaState &idea, int32_t ideology_id) const {
    const auto &d = _catalog.definitions[static_cast<size_t>(ideology_id)];
    int32_t unlocked = -1;
    for (uint32_t level = 0; level < d.level_count; ++level) {
        if (idea.understanding_q16 < _catalog.levels[d.level_begin + level].threshold_q16) break;
        unlocked = static_cast<int32_t>(level);
    }
    return unlocked;
}

void RuntimeIdeologyPodAuthority::compute_synergies(
        const RuntimeIdeologyPodCountryState &country, int32_t override_ideology,
        int32_t override_level, RuntimeIdeologyPodLocation override_location,
        std::vector<uint64_t> &out) const {
    out = country.synergy_bits;
    if (out.size() != (_catalog.synergies.size() + 63u) / 64u)
        out.assign((_catalog.synergies.size() + 63u) / 64u, 0);
    if (override_ideology < 0 ||
        static_cast<size_t>(override_ideology + 1) >=
            _catalog.ideology_synergy_offsets.size()) return;
    const uint32_t candidate_begin = _catalog.ideology_synergy_offsets[
        static_cast<size_t>(override_ideology)];
    const uint32_t candidate_end = _catalog.ideology_synergy_offsets[
        static_cast<size_t>(override_ideology + 1)];
    for (uint32_t candidate = candidate_begin; candidate < candidate_end;
         ++candidate) {
        const uint32_t synergy_id = static_cast<uint32_t>(
            _catalog.ideology_synergy_ids[candidate]);
        const auto &synergy = _catalog.synergies[synergy_id];
        const uint32_t needed = synergy.min_count == 0 ? synergy.requirement_count : synergy.min_count;
        uint32_t held = 0;
        for (uint32_t row = 0; row < synergy.requirement_count; ++row) {
            const auto &requirement = _catalog.synergy_requirements[synergy.requirement_begin + row];
            const auto &idea = country.ideas[static_cast<size_t>(requirement.ideology_id)];
            const int32_t level = requirement.ideology_id == override_ideology ? override_level : idea.level;
            const RuntimeIdeologyPodLocation location = requirement.ideology_id == override_ideology ? override_location : idea.location;
            if (level >= requirement.minimum_level &&
                (requirement.location_mask & (1u << static_cast<uint8_t>(location))) != 0)
                ++held;
        }
        bit_set(out, static_cast<int32_t>(synergy_id), held >= needed);
    }
}

uint64_t RuntimeIdeologyPodAuthority::transition_identity(
        const RuntimeIdeologyPodTransition &transition,
        RuntimeIdeologyPodOpcode opcode) const {
    uint64_t hash = FNV_OFFSET;
    hash = hash_value(hash, _catalog.catalog_hash); hash = hash_value(hash, transition.request_id);
    hash = hash_value(hash, transition.producer_id); hash = hash_value(hash, transition.sequence);
    hash = hash_value(hash, transition.effective_day); hash = hash_value(hash, transition.country_slot);
    hash = hash_value(hash, transition.country_generation); hash = hash_value(hash, transition.ideology_id);
    hash = hash_value(hash, transition.desired_level); hash = hash_value(hash, transition.desired_location);
    hash = hash_value(hash, opcode);
    return hash == 0 ? 1 : hash;
}

void RuntimeIdeologyPodAuthority::emit_transition(
        const RuntimeIdeologyPodSnapshot &state,
        RuntimeIdeologyPodTransition &transition,
        RuntimeIdeologyPodPlan &plan) const {
    if (transition.intent_emitted != 0) return;
    // Level rows of the retained (pre-ACK) state versus the desired state.
    // UniqueSource APPLY is an upsert, so a tier change re-applies with the
    // new magnitude and only definitions absent from the new tier are removed.
    if (transition.country_slot < state.countries.size()) {
        const auto &country = state.countries[transition.country_slot];
        const auto &definition = _catalog.definitions[static_cast<size_t>(transition.ideology_id)];
        const auto &idea = country.ideas[static_cast<size_t>(transition.ideology_id)];
        auto tier = [&](int32_t level, RuntimeIdeologyPodLocation location,
                        uint32_t &begin, uint32_t &count) {
            begin = count = 0;
            if (location == RuntimeIdeologyPodLocation::INACTIVE || level < 0 ||
                level >= static_cast<int32_t>(definition.level_count)) return;
            const auto &row = _catalog.levels[definition.level_begin + static_cast<uint32_t>(level)];
            begin = row.modifier_begin; count = row.modifier_count;
        };
        uint32_t old_begin = 0, old_count = 0, new_begin = 0, new_count = 0;
        tier(idea.level, idea.location, old_begin, old_count);
        tier(transition.desired_level, transition.desired_location, new_begin, new_count);
        const uint64_t handle = (static_cast<uint64_t>(transition.country_generation) << 32u) | transition.country_slot;
        uint32_t ordinal = 0;
        auto push = [&](const RuntimeIdeologyPodModifierTemplate &templ, uint16_t opcode) {
            RuntimeIdeologyPodModifierRow row;
            row.transition_id = transition.intent_id;
            row.country_handle = handle;
            row.country_generation = transition.country_generation;
            row.opcode = opcode;
            row.domain = static_cast<uint16_t>(templ.domain);
            row.definition_key_hash = templ.definition_key_hash;
            row.source_id = static_cast<uint64_t>(transition.ideology_id + 1);
            row.magnitude_q16 = templ.magnitude_q16;
            row.ordinal = ordinal++;
            row.effective_day = transition.effective_day;
            plan.modifier_rows.push_back(row);
        };
        for (uint32_t i = 0; i < old_count; ++i) {
            const auto &old_row = _catalog.level_modifiers[old_begin + i];
            bool kept = false;
            for (uint32_t j = 0; j < new_count; ++j) {
                const auto &new_row = _catalog.level_modifiers[new_begin + j];
                if (new_row.definition_key_hash == old_row.definition_key_hash && new_row.domain == old_row.domain) { kept = true; break; }
            }
            if (!kept) push(old_row, 2u);
        }
        for (uint32_t j = 0; j < new_count; ++j) {
            const auto &new_row = _catalog.level_modifiers[new_begin + j];
            bool unchanged = false;
            for (uint32_t i = 0; i < old_count; ++i) {
                const auto &old_row = _catalog.level_modifiers[old_begin + i];
                if (old_row.definition_key_hash == new_row.definition_key_hash && old_row.domain == new_row.domain &&
                    old_row.magnitude_q16 == new_row.magnitude_q16) { unchanged = true; break; }
            }
            if (!unchanged) push(new_row, 1u);
        }
    }
    RuntimeDomainIntent intent;
    intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::IDEOLOGY);
    intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
    intent.opcode = EFFECT_TRANSITION_OPCODE;
    intent.flags = RUNTIME_DOMAIN_INTENT_DEFERRED | RUNTIME_DOMAIN_INTENT_REQUIRES_ACK;
    intent.source_id = transition.intent_id;
    intent.target_handle = (static_cast<uint64_t>(transition.country_generation) << 32u) |
        transition.country_slot;
    intent.target_generation = transition.country_generation;
    intent.effective_day = transition.effective_day;
    intent.payload[0] = transition.ideology_id;
    intent.payload[1] = transition.desired_level;
    intent.payload[2] = static_cast<int64_t>(transition.desired_location);
    intent.payload[3] = static_cast<int64_t>(transition.desired_entered_levels);
    intent.request_id = transition.request_id != 0 ? transition.request_id : transition.intent_id;
    intent.producer_id = transition.producer_id;
    intent.sequence = transition.sequence;
    intent.idempotency_key = transition.intent_id;
    plan.intents.push_back(intent);
    transition.intent_emitted = 1;
}

bool RuntimeIdeologyPodAuthority::begin_transition(
        RuntimeIdeologyPodSnapshot &state, uint32_t slot, int32_t ideology_id,
        int32_t desired_level, RuntimeIdeologyPodLocation desired_location,
        uint8_t desired_slot_index, uint64_t entered_levels,
        const RuntimeIdeologyPodCommand *command, int64_t day,
        RuntimeIdeologyPodPlan &plan, std::string &error) const {
    for (const auto &pending : state.pending_transitions)
        if (pending.country_slot == slot && pending.ideology_id == ideology_id) {
            error = "ideology_transition_pending"; return false;
        }
    if (state.pending_transitions.size() >= RUNTIME_IDEOLOGY_POD_MAX_TRANSITIONS) {
        error = "ideology_transition_capacity_exceeded"; return false;
    }
    if (plan.intents.size() >= _catalog.max_transition_commands) {
        error = "ideology_transition_command_slice_exceeded";
        return false;
    }
    RuntimeIdeologyPodTransition transition;
    transition.request_id = command != nullptr ? command->request_id : 0;
    transition.producer_id = command != nullptr ? command->producer_id : 0;
    transition.sequence = command != nullptr ? command->sequence :
        (static_cast<uint64_t>(day) << 32u) | static_cast<uint32_t>(ideology_id + 1);
    transition.effective_day = day;
    transition.country_slot = slot;
    transition.country_generation = state.countries[slot].generation;
    transition.ideology_id = ideology_id;
    transition.desired_level = desired_level;
    transition.desired_location = desired_location;
    transition.desired_slot_index = desired_slot_index;
    transition.desired_entered_levels = entered_levels;
    transition.previous_entered_levels =
        state.countries[slot].ideas[static_cast<size_t>(ideology_id)]
            .entered_levels;
    compute_synergies(state.countries[slot], ideology_id, desired_level,
                      desired_location, transition.desired_synergy_bits);
    transition.intent_id = transition_identity(transition,
        command != nullptr ? command->opcode : RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING);
    state.pending_transitions.push_back(std::move(transition));
    emit_transition(state, state.pending_transitions.back(), plan);
    return true;
}

uint8_t RuntimeIdeologyPodAuthority::next_free_slot(
        const RuntimeIdeologyPodCountryState &country,
        RuntimeIdeologyPodLocation location, int32_t exclude_ideology_id) const {
    if (location == RuntimeIdeologyPodLocation::INACTIVE) return 0;
    std::array<bool, 64> occupied{};
    for (const RuntimeIdeologyPodIdeaState &idea : country.ideas) {
        if (idea.slot_index >= occupied.size()) continue;
        const int32_t ideology_id = static_cast<int32_t>(
            &idea - country.ideas.data());
        if (ideology_id == exclude_ideology_id ||
                idea.location != location) continue;
        occupied[static_cast<size_t>(idea.slot_index)] = true;
    }
    for (uint8_t slot = 0; slot < static_cast<uint8_t>(occupied.size());
            ++slot)
        if (!occupied[static_cast<size_t>(slot)]) return slot;
    return 63;
}

void RuntimeIdeologyPodAuthority::settle_synergies(
        RuntimeIdeologyPodCountryState &country, uint32_t country_slot,
        int32_t ideology_id, int64_t day, RuntimeIdeologyPodPlan &plan) const {
    // Recompute only the reverse-CSR candidates against the settled state, so
    // two same-day transitions of one school still reach a shared resonance.
    std::vector<uint64_t> next;
    compute_synergies(country, ideology_id,
        country.ideas[static_cast<size_t>(ideology_id)].level,
        country.ideas[static_cast<size_t>(ideology_id)].location, next);
    const uint32_t begin = _catalog.ideology_synergy_offsets[static_cast<size_t>(ideology_id)];
    const uint32_t end = _catalog.ideology_synergy_offsets[static_cast<size_t>(ideology_id + 1)];
    for (uint32_t candidate = begin; candidate < end; ++candidate) {
        const int32_t synergy_id = _catalog.ideology_synergy_ids[candidate];
        const bool was = bit_get(country.synergy_bits, synergy_id);
        const bool now = bit_get(next, synergy_id);
        if (was == now) continue;
        const auto &synergy = _catalog.synergies[static_cast<size_t>(synergy_id)];
        for (uint32_t row_index = 0; row_index < synergy.modifier_count; ++row_index) {
            const auto &templ = _catalog.synergy_modifiers[synergy.modifier_begin + row_index];
            RuntimeIdeologyPodModifierRow row;
            row.transition_id = 0;
            row.country_handle = country.handle;
            row.country_generation = country.generation;
            row.opcode = now ? 1u : 2u;
            row.domain = static_cast<uint16_t>(templ.domain);
            row.definition_key_hash = templ.definition_key_hash;
            row.source_id = (1ull << 32u) | static_cast<uint64_t>(synergy_id + 1);
            row.magnitude_q16 = templ.magnitude_q16;
            row.ordinal = row_index;
            row.effective_day = day;
            plan.modifier_rows.push_back(row);
        }
        bit_set(country.synergy_bits, synergy_id, now);
    }
    (void)country_slot;
}

bool RuntimeIdeologyPodAuthority::apply_ack(
        RuntimeIdeologyPodSnapshot &state, const RuntimeDomainAck &ack,
        int64_t day, RuntimeIdeologyPodPlan &plan, std::string &error) const {
    if (ack.domain != static_cast<uint16_t>(RuntimeDomainId::EFFECT)) return true;
    for (size_t i = 0; i < state.pending_transitions.size(); ++i) {
        auto &transition = state.pending_transitions[i];
        if (ack.transaction_id != transition.intent_id && ack.request_id != transition.intent_id &&
            ack.request_id != transition.request_id) continue;
        if (ack.target_handle != ((static_cast<uint64_t>(transition.country_generation) << 32u) | transition.country_slot) ||
            ack.target_generation != transition.country_generation) {
            error = "ideology_ack_generation_mismatch"; return false;
        }
        if (ack.effective_day != transition.effective_day) {
            error = "ideology_ack_effective_day_mismatch"; return false;
        }
        if (ack.code == RuntimeDomainAckCode::RETRY || ack.code == RuntimeDomainAckCode::STALE_GENERATION) {
            transition.intent_emitted = 0;
            return true;
        }
        auto &country = state.countries[transition.country_slot];
        auto &idea = country.ideas[static_cast<size_t>(transition.ideology_id)];
        RuntimeIdeologyPodReceiptStatus status = RuntimeIdeologyPodReceiptStatus::REJECTED;
        if (ack.code == RuntimeDomainAckCode::OK) {
            const auto previous = idea.location;
            const auto &definition = _catalog.definitions[static_cast<size_t>(transition.ideology_id)];
            if (previous == RuntimeIdeologyPodLocation::IDEOLOGY) country.ideology_slots_used -= definition.ideology_cost;
            if (previous == RuntimeIdeologyPodLocation::NATIONAL_SPIRIT) country.spirit_slots_used -= definition.spirit_cost;
            idea.level = transition.desired_level;
            idea.location = transition.desired_location;
            idea.slot_index = transition.desired_slot_index;
            idea.entered_levels |= transition.desired_entered_levels;
            // X6-b on-enter grants are part of the same ACK-gated transition.
            // Appending here makes a retry/restore idempotent by construction:
            // the pending row is erased only after this successful commit.
            const auto entered = transition.desired_entered_levels &
                ~transition.previous_entered_levels;
            for (int32_t entered_level = 0; entered_level < 64; ++entered_level) {
                if ((entered & (1ull << entered_level)) == 0) continue;
                const uint32_t level_index = definition.level_begin +
                    static_cast<uint32_t>(entered_level);
                if (level_index >= _catalog.levels.size()) continue;
                const uint16_t count =
                    _catalog.levels[level_index].on_enter_free_draws;
                if (count == 0) continue;
                country.free_draws = static_cast<uint16_t>(
                    std::min<uint32_t>(65535u,
                        static_cast<uint32_t>(country.free_draws) + count));
            }
            ++idea.generation;
            if (idea.location == RuntimeIdeologyPodLocation::IDEOLOGY) country.ideology_slots_used += definition.ideology_cost;
            if (idea.location == RuntimeIdeologyPodLocation::NATIONAL_SPIRIT) country.spirit_slots_used += definition.spirit_cost;
            if (country.synergy_bits.size() != (_catalog.synergies.size() + 63u) / 64u)
                country.synergy_bits.assign((_catalog.synergies.size() + 63u) / 64u, 0);
            settle_synergies(country, transition.country_slot, transition.ideology_id, day, plan);
            rebuild_active_idea_ids(country);
            status = RuntimeIdeologyPodReceiptStatus::SETTLED;
        }
        for (auto &receipt : state.receipts) {
            if (receipt.status == RuntimeIdeologyPodReceiptStatus::PENDING &&
                receipt.request_id == transition.request_id &&
                receipt.producer_id == transition.producer_id &&
                receipt.sequence == transition.sequence) {
                receipt.status = status;
                receipt.settled_day = day;
                receipt.reason_code = status == RuntimeIdeologyPodReceiptStatus::SETTLED ? 0u : 1u;
                if (status != RuntimeIdeologyPodReceiptStatus::SETTLED)
                    receipt.reason_text = "effect_transition_rejected";
            }
        }
        state.pending_transitions.erase(state.pending_transitions.begin() + static_cast<std::ptrdiff_t>(i));
        if (state.pending_cursor > i) --state.pending_cursor;
        return true;
    }
    return true;
}

int32_t RuntimeIdeologyPodAuthority::ideology_capacity_for(
        const RuntimeCountryPodSnapshot &country, uint32_t slot) const {
    int64_t capacity = _catalog.ideology_capacity;
    for (const auto &unlock : _catalog.capacity_unlocks) {
        if (unlock.ideology_delta == 0) continue;
        const size_t index = static_cast<size_t>(slot) * country.technology_words + static_cast<size_t>(unlock.technology_id / 64);
        if (index < country.country_technologies.size() &&
            (country.country_technologies[index] & (1ull << (unlock.technology_id % 64))) != 0)
            capacity += unlock.ideology_delta;
    }
    return static_cast<int32_t>(std::min<int64_t>(capacity, _catalog.ideology_capacity_max));
}

int32_t RuntimeIdeologyPodAuthority::spirit_capacity_for(
        const RuntimeCountryPodSnapshot &country, uint32_t slot) const {
    int64_t capacity = _catalog.spirit_capacity;
    for (const auto &unlock : _catalog.capacity_unlocks) {
        if (unlock.spirit_delta == 0) continue;
        const size_t index = static_cast<size_t>(slot) * country.technology_words + static_cast<size_t>(unlock.technology_id / 64);
        if (index < country.country_technologies.size() &&
            (country.country_technologies[index] & (1ull << (unlock.technology_id % 64))) != 0)
            capacity += unlock.spirit_delta;
    }
    return static_cast<int32_t>(std::min<int64_t>(capacity, _catalog.spirit_capacity_max));
}

int64_t RuntimeIdeologyPodAuthority::offer_cost_for(uint64_t draw_sequence) const {
    return runtime_ideology_offer_cost_q16(_catalog.offer_cost_q16,
        _catalog.offer_cost_growth_percent, _catalog.offer_cost_max_q16, draw_sequence);
}

int64_t RuntimeIdeologyPodAuthority::reroll_cost_for(
        uint64_t draw_sequence, int32_t factor_q16) const {
    // The open offer was paid at draw_sequence - 1; rerolls cost a share of it.
    const int64_t paid = offer_cost_for(draw_sequence == 0 ? 0 : draw_sequence - 1u);
    // Scale the share, never the base draw: a discount card must not turn into
    // a blanket discount on the whole draw economy. ideology_reroll_percent owns
    // the cap so the main thread cannot cap it differently.
    return mul_sat(paid, ideology_reroll_percent(
        _catalog.reroll_cost_percent, factor_q16)) / 100;
}

int32_t RuntimeIdeologyPodAuthority::unlocked_era_for(
        const RuntimeCountryPodSnapshot &country, uint32_t slot) const {
    int32_t reached = 0;
    for (int32_t era = 0;
            era < static_cast<int32_t>(_catalog.era_milestone_technologies.size()); ++era) {
        const int32_t technology = _catalog.era_milestone_technologies[static_cast<size_t>(era)];
        if (technology < 0 || era <= reached) continue;
        const size_t index =
            static_cast<size_t>(slot) * country.technology_words + technology / 64;
        if ((country.country_technologies[index] & (1ull << (technology % 64))) != 0)
            reached = era;
    }
    return reached;
}

bool RuntimeIdeologyPodAuthority::draw_offer(
        RuntimeIdeologyPodSnapshot &state, const RuntimeCountryPodSnapshot &country,
        uint32_t slot, const RuntimeIdeologyOpinionSnapshot &opinion,
        std::string &error) const {
    auto &row = state.countries[slot];
    // Must stay step-for-step identical to NativeIdeologyRuntime::draw_offer.
    row.unlocked_era = unlocked_era_for(country, slot);
    const int32_t decay_floor_bp = ideology_frozen_bp(opinion.era_decay_floor_bp, slot);
    std::vector<IdeologyDrawCandidate> pool;
    std::vector<uint8_t> pool_recent;
    std::vector<IdeologyDrawCandidate> fallback_rows;
    for (int32_t id = 0; id < static_cast<int32_t>(_catalog.definitions.size()); ++id) {
        const RuntimeIdeologyPodDefinition &definition = _catalog.definitions[static_cast<size_t>(id)];
        if (bit_get(row.banned_bits, id) || (definition.acquisition & ACQUIRE_DRAW) == 0 ||
            !requirements_met(state, country, slot, id)) continue;
        const uint8_t recent = definition.era_index >= row.unlocked_era - 1 ? 1u : 0u;
        const int32_t weight = ideology_draw_weight(definition.rarity_weight,
            _catalog.era_decay_bp.data(), _catalog.era_decay_bp.size(),
            row.unlocked_era, definition.era_index, decay_floor_bp);
        IdeologyDrawCandidate candidate;
        candidate.id = id;
        if (!bit_get(row.known_bits, id)) {
            candidate.weight = weight;
            pool.push_back(candidate);
            pool_recent.push_back(recent);
            fallback_rows.push_back(candidate);
        } else if (_catalog.refine_weight_bp > 0) {
            const RuntimeIdeologyPodIdeaState &idea = row.ideas[static_cast<size_t>(id)];
            if (definition.level_count == 0 ||
                idea.level >= static_cast<int32_t>(definition.level_count) - 1) continue;
            candidate.weight = static_cast<int64_t>(definition.rarity_weight) *
                static_cast<int64_t>(_catalog.refine_weight_bp);
            pool.push_back(candidate);
            pool_recent.push_back(recent);
        }
    }
    if (pool.empty()) { error = "ideology_offer_pool_insufficient"; return false; }
    std::vector<IdeologyDrawCandidate> weighted;
    std::vector<uint8_t> weighted_recent;
    weighted.reserve(pool.size());
    weighted_recent.reserve(pool.size());
    for (size_t index = 0; index < pool.size(); ++index) {
        if (pool[index].weight > 0) {
            weighted.push_back(pool[index]);
            weighted_recent.push_back(pool_recent[index]);
        }
    }
    // Late eras only carry a handful of ideas, so once they are all known the
    // decayed pool empties permanently. Fall back to raw rarity weight; the
    // branch is a pure function of `fallback_rows`, so both authorities agree.
    if (weighted.empty()) {
        for (const IdeologyDrawCandidate &candidate : fallback_rows) {
            IdeologyDrawCandidate fallback = candidate;
            fallback.weight = static_cast<int64_t>(
                _catalog.definitions[static_cast<size_t>(candidate.id)].rarity_weight) * 10000;
            weighted.push_back(fallback);
            weighted_recent.push_back(
                _catalog.definitions[static_cast<size_t>(candidate.id)].era_index
                    >= row.unlocked_era - 1 ? 1u : 0u);
        }
    }
    if (weighted.empty()) { error = "ideology_offer_weight_invalid"; return false; }
    // Row count: the frozen bonus, on top of the base, clamped to the array. The
    // main thread reads the same bonus from ModifierRuntime; the host freezes it
    // into `opinion.offer_choice_bonus` so the two never disagree.
    const int32_t bonus = slot < opinion.offer_choice_bonus.size()
        ? std::clamp<int32_t>(opinion.offer_choice_bonus[slot], 0,
            IDEOLOGY_OFFER_CHOICE_CAPACITY - IDEOLOGY_OFFER_CHOICE_BASE) : 0;
    // The catalog's row count is the base; the stat adds on top. `IDEOLOGY_OFFER_
    // CHOICE_BASE` is only the fallback when the catalog omits the field, which
    // `configure()` already resolved into `draw_count`.
    const int32_t base_rows = std::clamp(static_cast<int32_t>(_catalog.draw_count),
        1, IDEOLOGY_OFFER_CHOICE_CAPACITY);
    const int32_t want = std::min(base_rows + bonus,
        static_cast<int32_t>(weighted.size()));
    int32_t drawn_ids[IDEOLOGY_OFFER_CHOICE_CAPACITY] = {-1, -1, -1, -1, -1};
    const int32_t drawn = ideology_weighted_draw_recent_first(weighted,
        weighted_recent, std::clamp(want, 1, IDEOLOGY_OFFER_CHOICE_CAPACITY),
        [&row]() { return next_random(row.rng_state); }, drawn_ids);
    if (drawn <= 0) { error = "ideology_offer_weight_invalid"; return false; }
    const uint32_t generation = std::max<uint32_t>(1, row.offer.generation + 1u);
    row.offer.clear();
    row.offer.active = 1;
    row.offer.generation = generation;
    for (int32_t n = 0; n < drawn; ++n)
        row.offer.ideology_ids[static_cast<size_t>(n)] = drawn_ids[static_cast<size_t>(n)];
    row.offer.choice_count = static_cast<uint8_t>(drawn);
    return true;
}

void RuntimeIdeologyPodAuthority::accrue_points(
        RuntimeIdeologyPodSnapshot &state,
        const RuntimeIdeologyOpinionSnapshot &opinion, int64_t day) const {
    const size_t countries = state.countries.size();
    if (opinion.country_population.size() != countries ||
        opinion.country_buildings_installed.size() != countries ||
        opinion.country_trade_base_value.size() != countries) return;
    const int64_t period = std::max<int64_t>(1, opinion.period_days);
    // R9-2: settle once per COMMITTED DAY, never per publish and never per
    // `period_index`.
    //
    // `period_index` was `commit_day / period_days`, and `period_days` comes from
    // `_epoch_days`, which the workset recalculates. With period 5 day 10 is
    // period 2, and after the epoch widens to 6 day 12 is ALSO period 2, so a
    // genuinely new commit was skipped as "already settled" (and the reverse split
    // one period into two). `commit_day` is monotone and independent of how many
    // times Economy publishes, so it is the only safe key on both sides.
    // `period_index` remains in the snapshot for diagnostics only.
    const uint64_t settle_key = opinion.committed_day >= 0
        ? static_cast<uint64_t>(opinion.committed_day) + 1u
        : opinion.revision;
    for (uint32_t slot = 0; slot < countries; ++slot) {
        auto &row = state.countries[slot];
        if (row.handle == 0 || row.points_revision == settle_key) continue;
        row.points_revision = settle_key;
        const int64_t population = std::max<int64_t>(0, opinion.country_population[slot]);
        const int64_t buildings = std::max<int64_t>(0, opinion.country_buildings_installed[slot]);
        if (row.baseline_ready == 0) {
            // First observation is the baseline; it never pays out.
            row.baseline_population = population;
            row.baseline_buildings = buildings;
            row.baseline_ready = 1;
            // R9-5: seed the trade marker HERE, mirroring the main thread. Left at
            // INT64_MIN, the kernel's first call did the seeding one settlement
            // later, so the whole first period's trade flow was silently dropped.
            if (row.trade_paid_day == INT64_MIN) row.trade_paid_day = day;
            continue;
        }
        // High-water baselines: only new peaks pay, so decline/recovery loops
        // cannot farm points.
        const int64_t population_gain = std::max<int64_t>(0, population - row.baseline_population);
        const int64_t building_gain = std::max<int64_t>(0, buildings - row.baseline_buildings);
        row.baseline_population = std::max(row.baseline_population, population);
        row.baseline_buildings = std::max(row.baseline_buildings, buildings);
        const int64_t trade_per_day = std::max<int64_t>(0, opinion.country_trade_base_value[slot]) / period;
        RuntimeIdeologyPodPointLedger ledger;
        ledger.day = day;
        ledger.population_q16 = ideology_point_term_q16(
            mul_sat(population_gain, _catalog.point_population_weight_q16),
            opinion.point_population_factor_q16, slot);
        ledger.building_q16 = ideology_point_term_q16(
            mul_sat(building_gain, _catalog.point_building_weight_q16),
            opinion.point_building_factor_q16, slot);
        // Trade is a flow: pay for the days that elapsed since this row last
        // paid. Clamping the span to `period` was removed: it broke "total depends
        // only on elapsed days" (1 settlement paid 5000 where 30 settled paid
        // 29000 over the same 30 days). Settling once, thirty times, or a random
        // number of times over the same span now pays the same total.
        //
        // `ledger_span_days` is the same span and feeds the per-day cap (R9-3).
        const int64_t trade_paid_before = row.trade_paid_day;
        const int64_t trade_days_q16 = ideology_trade_flow_q16(
            trade_per_day, day, period, row.trade_paid_day);
        const int64_t ledger_span_days = trade_paid_before == INT64_MIN
            ? 1 : std::max<int64_t>(1, day - trade_paid_before);
        ledger.trade_q16 = ideology_point_term_q16(
            mul_sat(trade_days_q16, _catalog.point_trade_weight_q16) /
                TRADE_MONEY_SCALE,
            opinion.point_trade_factor_q16, slot);
        int64_t total_influence = 0;
        int64_t weighted = 0;
        for (uint32_t class_index = 0; class_index < _catalog.class_count; ++class_index) {
            const size_t lane = static_cast<size_t>(slot) * _catalog.class_count + class_index;
            int64_t influence = std::max<int64_t>(0, opinion.population[lane]);
            influence = add_sat(influence, mul_sat(std::max<int64_t>(0, opinion.owner_employed[lane]), _catalog.owner_influence_weight));
            influence = add_sat(influence, std::max<int64_t>(0, opinion.funds[lane]) / _catalog.funds_per_influence);
            total_influence = add_sat(total_influence, influence);
            weighted = add_sat(weighted, mul_sat(influence, std::clamp<int64_t>(opinion.satisfaction_q16[lane], 0, Q16_ONE)));
        }
        const int64_t satisfaction = total_influence > 0 ? std::clamp<int64_t>(weighted / total_influence, 0, Q16_ONE) : Q16_ONE / 2;
        ledger.opinion_factor_q16 = ideology_opinion_factor_q16(
            satisfaction, opinion.opinion_factor_floor_q16, slot);
        ledger.gain_factor_q16 = slot < opinion.point_gain_factor_q16.size()
            ? std::clamp<int32_t>(opinion.point_gain_factor_q16[slot], 0, 4 * Q16_ONE) : static_cast<int32_t>(Q16_ONE);
        const int64_t raw = add_sat(add_sat(ledger.population_q16, ledger.building_q16), ledger.trade_q16);
        int64_t gain = mul_sat(raw, ledger.opinion_factor_q16) / Q16_ONE;
        gain = mul_sat(gain, ledger.gain_factor_q16) / Q16_ONE;
        // R9-3: the cap is authored PER DAY, so a settlement that covers a span
        // of days must be allowed `cap x span`. Applying the raw per-day cap to
        // the whole settlement made a rare settler (large span) lose to a daily
        // settler: "1 settlement == 30 settlements" held in the kernel and broke
        // here. Mirrors the main thread exactly.
        const int64_t covered_days = std::max<int64_t>(1, ledger_span_days);
        if (_catalog.point_gain_cap_q16 > 0) {
            gain = std::min(gain,
                mul_sat(_catalog.point_gain_cap_q16, covered_days * Q16_ONE) / Q16_ONE);
        }
        ledger.gain_q16 = std::max<int64_t>(0, gain);
        row.ideology_points_q16 = add_sat(row.ideology_points_q16, ledger.gain_q16);
        row.lifetime_points_q16 = add_sat(row.lifetime_points_q16, ledger.gain_q16);
        row.ledger = ledger;
        row.history_q16[row.history_head] = ledger.gain_q16;
        row.history_head = static_cast<uint8_t>((row.history_head + 1u) % RUNTIME_IDEOLOGY_POD_HISTORY);
        if (row.history_count < RUNTIME_IDEOLOGY_POD_HISTORY) ++row.history_count;
    }
}

bool RuntimeIdeologyPodAuthority::apply_command(
        RuntimeIdeologyPodSnapshot &state,
        const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion,
        const RuntimeIdeologyPodCommand &command,
        RuntimeIdeologyPodPlan &plan, std::string &error) const {
    const uint32_t slot = static_cast<uint32_t>(command.country_handle & 0xffffffffull);
    if (slot >= state.countries.size() || state.countries[slot].handle != command.country_handle ||
        state.countries[slot].generation != static_cast<uint32_t>(command.country_handle >> 32u) ||
        country.country_active[slot] == 0) {
        error = "ideology_country_handle_invalid"; return false;
    }
    auto &row = state.countries[slot];
    const int32_t idea_id = command.ideology_id;
    switch (command.opcode) {
        case RuntimeIdeologyPodOpcode::DISCOVER:
            if ((_catalog.definitions[idea_id].acquisition & ACQUIRE_DISCOVER) == 0 ||
                !requirements_met(state, country, slot, idea_id)) { error = "ideology_discovery_not_allowed"; return false; }
            bit_set(row.known_bits, idea_id, true); return true;
        case RuntimeIdeologyPodOpcode::GRANT_POINTS:
            row.ideology_points_q16 = add_sat(row.ideology_points_q16, command.value_q16); return true;
        case RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW:
            row.free_draws = static_cast<uint16_t>(std::min<int64_t>(
                65535, static_cast<int64_t>(row.free_draws) + command.value_q16));
            return true;
        case RuntimeIdeologyPodOpcode::OPEN_OFFER: {
            const int64_t cost = offer_cost_for(row.draw_sequence);
            if (row.offer.active != 0) { error = "ideology_offer_pending"; return false; }
            if (row.free_draws == 0 && row.ideology_points_q16 < cost) {
                error = "ideology_points_insufficient"; return false;
            }
            if (!draw_offer(state, country, slot, opinion, error)) return false;
            if (row.free_draws > 0) --row.free_draws;
            else row.ideology_points_q16 -= cost;
            ++row.draw_sequence; return true;
        }
        case RuntimeIdeologyPodOpcode::REROLL_OFFER: {
            const int64_t cost = reroll_cost_for(row.draw_sequence,
                ideology_frozen_factor(opinion.reroll_cost_q16, slot));
            if (row.offer.active == 0) { error = "ideology_offer_not_active"; return false; }
            if (command.offer_generation != 0 && command.offer_generation != row.offer.generation) { error = "ideology_offer_generation_stale"; return false; }
            if (row.ideology_points_q16 < cost) { error = "ideology_points_insufficient"; return false; }
            if (!draw_offer(state, country, slot, opinion, error)) return false;
            row.ideology_points_q16 -= cost; return true;
        }
        case RuntimeIdeologyPodOpcode::CHOOSE_OFFER: {
            if (row.offer.active == 0 || row.offer.generation != command.offer_generation ||
                command.choice_index < 0 ||
                command.choice_index >= static_cast<int32_t>(row.offer.choice_count)) {
                error = "ideology_offer_generation_stale"; return false;
            }
            const int32_t chosen = row.offer.ideology_ids[static_cast<size_t>(command.choice_index)];
            if (chosen < 0 || bit_get(row.banned_bits, chosen)) { error = "ideology_offer_choice_invalid"; return false; }
            if (bit_get(row.known_bits, chosen)) {
                // 精进: the row only exists because the card is owned and not
                // maxed, so the pick pays understanding and may raise the level.
                auto &idea = row.ideas[static_cast<size_t>(chosen)];
                idea.understanding_q16 = add_sat(idea.understanding_q16,
                    _catalog.refine_understanding_q16);
                const int32_t unlocked = unlocked_level(idea, chosen);
                if (unlocked > idea.level) { idea.level = unlocked; ++idea.generation; }
            } else {
                bit_set(row.known_bits, chosen, true);
            }
            row.offer.clear();
            return true;
        }
        case RuntimeIdeologyPodOpcode::BAN_CARD: {
            if (idea_id < 0 || idea_id >= static_cast<int32_t>(_catalog.definitions.size())) {
                error = "ideology_ideology_invalid"; return false;
            }
            if (bit_get(row.known_bits, idea_id)) { error = "ideology_ban_known"; return false; }
            if (bit_get(row.banned_bits, idea_id)) { error = "ideology_ban_already_banned"; return false; }
            const int64_t ban_cost = offer_cost_for(row.draw_sequence);
            if (row.ideology_points_q16 < ban_cost) { error = "ideology_points_insufficient"; return false; }
            row.ideology_points_q16 -= ban_cost;
            bit_set(row.banned_bits, idea_id, true);
            return true;
        }
        case RuntimeIdeologyPodOpcode::EQUIP: {
            if (!bit_get(row.known_bits, idea_id)) { error = "ideology_unknown"; return false; }
            auto &idea = row.ideas[idea_id];
            if (idea.location == RuntimeIdeologyPodLocation::NATIONAL_SPIRIT) { error = "ideology_is_national_spirit"; return false; }
            if (idea.location == RuntimeIdeologyPodLocation::IDEOLOGY) return true;
            const auto &definition = _catalog.definitions[idea_id];
            for (int32_t other = 0; other < static_cast<int32_t>(row.ideas.size()); ++other)
                if (other != idea_id && row.ideas[other].location != RuntimeIdeologyPodLocation::INACTIVE && definition.exclusion_group_id >= 0 && _catalog.definitions[other].exclusion_group_id == definition.exclusion_group_id) { error = "ideology_exclusion_group_conflict"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 0)) { error = "ideology_support_threshold_not_met"; return false; }
            if (row.ideology_slots_used + definition.ideology_cost > ideology_capacity_for(country, slot)) { error = "ideology_slot_capacity_exceeded"; return false; }
            const int32_t level = std::max(idea.level, unlocked_level(idea, idea_id));
            const uint64_t entered = level < 0 ? 0 : ((level == 63 ? ~0ull : ((1ull << (level + 1)) - 1ull)) & ~idea.entered_levels);
            return begin_transition(state, slot, idea_id, level,
                RuntimeIdeologyPodLocation::IDEOLOGY,
                next_free_slot(row, RuntimeIdeologyPodLocation::IDEOLOGY,
                    idea_id), entered, &command, command.effective_day, plan,
                error);
        }
        case RuntimeIdeologyPodOpcode::UNEQUIP: {
            auto &idea = row.ideas[idea_id];
            if (idea.location != RuntimeIdeologyPodLocation::IDEOLOGY) { error = "ideology_not_equipped"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 1)) { error = "ideology_support_threshold_not_met"; return false; }
            return begin_transition(state, slot, idea_id, idea.level,
                RuntimeIdeologyPodLocation::INACTIVE, idea.slot_index, 0,
                &command, command.effective_day, plan, error);
        }
        case RuntimeIdeologyPodOpcode::PROMOTE: {
            auto &idea = row.ideas[idea_id];
            const auto &definition = _catalog.definitions[idea_id];
            if (idea.location != RuntimeIdeologyPodLocation::IDEOLOGY) { error = "ideology_promotion_requires_equipped"; return false; }
            if (idea.level < definition.min_spirit_level) { error = "ideology_national_spirit_level_insufficient"; return false; }
            if (row.spirit_slots_used + definition.spirit_cost > spirit_capacity_for(country, slot)) { error = "national_spirit_slot_capacity_exceeded"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 2)) { error = "ideology_support_threshold_not_met"; return false; }
            return begin_transition(state, slot, idea_id, idea.level,
                RuntimeIdeologyPodLocation::NATIONAL_SPIRIT,
                next_free_slot(row, RuntimeIdeologyPodLocation::NATIONAL_SPIRIT,
                    idea_id), 0, &command, command.effective_day, plan, error);
        }
        case RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING: {
            if (!bit_get(row.known_bits, idea_id)) { error = "ideology_unknown"; return false; }
            auto &idea = row.ideas[idea_id];
            idea.understanding_q16 = add_sat(idea.understanding_q16, command.value_q16);
            const int32_t unlocked = unlocked_level(idea, idea_id);
            if (idea.location == RuntimeIdeologyPodLocation::INACTIVE) {
                if (unlocked > idea.level) { idea.level = unlocked; ++idea.generation; }
                return true;
            }
            if (unlocked > idea.level) {
                const uint64_t entered = unlocked == 63 ? ~idea.entered_levels : (((1ull << (unlocked + 1)) - 1ull) & ~idea.entered_levels);
                return begin_transition(state, slot, idea_id, unlocked,
                    idea.location, idea.slot_index, entered, &command,
                    command.effective_day, plan, error);
            }
            return true;
        }
        case RuntimeIdeologyPodOpcode::SET_GATE:
            bit_set(row.gate_bits, command.gate_id, command.value_q16 != 0); return true;
    }
    error = "ideology_command_unknown"; return false;
}

bool RuntimeIdeologyPodAuthority::plan_day(
        int64_t day, const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion,
        const std::vector<RuntimeDomainAck> &acks,
        RuntimeIdeologyPodPlan &plan, std::string &error) {
    error.clear(); plan = RuntimeIdeologyPodPlan{};
    if (_plan_ready) { error = "ideology_plan_already_ready"; return false; }
    if (!validate_inputs(country, opinion, error)) return false;
    if (_current.countries.empty()) { error = "ideology_pod_not_bootstrapped"; return false; }
    plan.base_generation = _current.generation;
    plan.input_generation = country.generation;
    plan.next_snapshot = _current;
    auto &state = plan.next_snapshot;
    if (state.round_day < 0) {
        if (day <= state.committed_day) {
            // ── a RESTORED state is ahead of this worker's calendar ──────────
            //
            // A restore replaces the POD's whole state INCLUDING its committed day. The
            // worker's own calendar can be behind that day: a worker world starts at the
            // host's `day`, and a save carries the day it was taken on, so a load into a
            // younger worker session (or into a fresh one) has `day <= committed_day`.
            //
            // The unguarded monotonicity rule then refuses EVERY worker day until the
            // calendar catches up -- `ideology_day_not_monotonic`, an Ideology stage that
            // fails for the rest of the session, and (because the stage returns before it
            // publishes) NO snapshot at all, so the restored rows would be frozen rather
            // than adopted. Freezing is not what "supersede" means.
            //
            // The imported state already settles those days, so the honest plan for them
            // is "nothing changes": the day completes, a generation is published so the
            // main-thread mirror is refreshed FROM the imported state, and the calendar
            // advances one day per day until it passes the floor. The rule is armed only
            // by `restore`, so a genuine backwards move still fails loudly.
            if (!_import_supersedes_calendar) {
                error = "ideology_day_not_monotonic"; return false;
            }
            plan.superseded_day = 1;
            plan.completed_day = 1;
            state.generation = _current.generation + 1u;
            state.state_hash = compute_state_hash(state);
            plan.plan_hash = state.state_hash;
            plan.preflight_ok = 1;
            _planned = state;
            _plan_ready = true;
            return true;
        }
        state.round_day = day;
        state.phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
        state.pending_cursor = state.command_cursor = 0;
        state.active_country_cursor = state.active_idea_cursor = 0;
        state.input_generation = country.generation;
        // Revision 0 cannot reach here (validate_inputs rejects it); the guard
        // documents why accrual is skipped rather than booked for a non-opinion.
        if (opinion.revision != 0) accrue_points(state, opinion, day);
    } else if (state.round_day != day || state.input_generation != country.generation) {
        error = "ideology_same_day_continuation_input_changed"; return false;
    } else if (state.opinion_revision != opinion.revision) {
        error = "ideology_same_day_continuation_opinion_changed"; return false;
    }
    state.opinion_revision = opinion.revision;
    if (state.phase == RuntimeIdeologyPodPhase::PENDING_TRANSITIONS) {
        for (const auto &ack : acks) if (!apply_ack(state, ack, day, plan, error)) return false;
        uint32_t visits = 0;
        while (state.pending_cursor < state.pending_transitions.size() &&
               visits < _catalog.max_transition_polls_per_slice) {
            emit_transition(state, state.pending_transitions[state.pending_cursor], plan);
            ++state.pending_cursor; ++visits;
        }
        plan.transition_visits = visits;
        if (state.pending_cursor < state.pending_transitions.size()) {
            plan.preflight_ok = 1; goto finish;
        }
        state.pending_cursor = 0;
        state.phase = RuntimeIdeologyPodPhase::COMMANDS;
    }
    if (state.phase == RuntimeIdeologyPodPhase::COMMANDS) {
        uint32_t consumed = 0;
        while (state.command_cursor < state.commands.size() &&
               state.commands[state.command_cursor].effective_day <= day &&
               consumed < _catalog.max_commands_per_slice) {
            const auto &command = state.commands[state.command_cursor];
            if (command.sequence <= producer_high_watermark(state,
                                                            command.producer_id)) {
                ++state.command_cursor;
                ++consumed;
                continue;
            }
            std::string command_error;
            const size_t pending_before = state.pending_transitions.size();
            const bool applied = apply_command(state, country, opinion, command, plan, command_error);
            RuntimeIdeologyPodReceipt receipt;
            receipt.request_id = command.request_id; receipt.producer_id = command.producer_id;
            receipt.sequence = command.sequence; receipt.opcode = command.opcode;
            receipt.country_handle = command.country_handle; receipt.ideology_id = command.ideology_id;
            receipt.settled_day = day;
            if (!applied) {
                receipt.status = RuntimeIdeologyPodReceiptStatus::REJECTED;
                receipt.reason_code = 1;
                receipt.reason_text = command_error;
            } else if (state.pending_transitions.size() > pending_before) { receipt.status = RuntimeIdeologyPodReceiptStatus::PENDING; receipt.settled_day = -1; }
            else receipt.status = RuntimeIdeologyPodReceiptStatus::SETTLED;
            state.receipts.push_back(receipt);
            update_producer_high_watermark(state, command.producer_id,
                                           command.sequence);
            ++state.command_cursor; ++consumed;
        }
        plan.commands_consumed = consumed;
        if (state.command_cursor < state.commands.size() &&
            state.commands[state.command_cursor].effective_day <= day) {
            plan.preflight_ok = 1; goto finish;
        }
        state.phase = RuntimeIdeologyPodPhase::ACTIVE_PROGRESS;
    }
    if (state.phase == RuntimeIdeologyPodPhase::ACTIVE_PROGRESS) {
        uint32_t visits = 0;
        while (state.active_country_cursor < state.countries.size()) {
            auto &country_row = state.countries[state.active_country_cursor];
            if (country_row.handle == 0 ||
                state.active_idea_cursor >= country_row.active_idea_ids.size()) {
                ++state.active_country_cursor; state.active_idea_cursor = 0; continue;
            }
            if (visits >= _catalog.max_active_visits_per_slice) break;
            const int32_t idea_id = static_cast<int32_t>(
                country_row.active_idea_ids[state.active_idea_cursor++]);
            auto &idea = country_row.ideas[idea_id];
            if (idea.location == RuntimeIdeologyPodLocation::INACTIVE) continue;
            ++visits;
            const auto &definition = _catalog.definitions[idea_id];
            if (idea.level >= 0 && idea.level < static_cast<int32_t>(definition.level_count)) {
                const int64_t daily = _catalog.levels[
                    definition.level_begin + static_cast<uint32_t>(idea.level)]
                    .daily_understanding_q16;
                // A zero-rate level skips the read entirely: the loop runs once
                // per active idea per day and most levels accrue nothing.
                if (daily != 0)
                    idea.understanding_q16 = add_sat(idea.understanding_q16,
                        ideology_scaled_daily(daily, ideology_frozen_factor(
                            opinion.understanding_gain_q16,
                            state.active_country_cursor)));
            }
            bool pending = false;
            for (const auto &transition : state.pending_transitions)
                if (transition.country_slot == state.active_country_cursor && transition.ideology_id == idea_id) { pending = true; break; }
            const int32_t unlocked = unlocked_level(idea, idea_id);
            if (!pending && unlocked > idea.level) {
                const uint64_t entered = unlocked == 63 ? ~idea.entered_levels : (((1ull << (unlocked + 1)) - 1ull) & ~idea.entered_levels);
                if (!begin_transition(state, state.active_country_cursor, idea_id, unlocked,
                                      idea.location, idea.slot_index, entered,
                                      nullptr, day, plan, error)) return false;
            }
        }
        plan.active_visits = visits;
        if (state.active_country_cursor < state.countries.size()) {
            plan.preflight_ok = 1; goto finish;
        }
        if (state.command_cursor > 0) {
            state.commands.erase(state.commands.begin(), state.commands.begin() + static_cast<std::ptrdiff_t>(state.command_cursor));
            state.command_cursor = 0;
        }
        state.committed_day = day; state.round_day = -1;
        state.phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
        state.active_country_cursor = state.active_idea_cursor = 0;
        plan.completed_day = 1;
    }

finish:
    state.generation = _current.generation + 1u;
    state.state_hash = compute_state_hash(state);
    plan.plan_hash = state.state_hash;
    plan.preflight_ok = 1;
    _planned = state;
    _plan_ready = true;
    return true;
}

bool RuntimeIdeologyPodAuthority::commit_day(
        RuntimeIdeologyPodPlan &plan, std::string &error) {
    if (!_plan_ready || plan.preflight_ok == 0 || plan.committed != 0 ||
        plan.base_generation != _current.generation ||
        plan.next_snapshot.state_hash != _planned.state_hash ||
        compute_state_hash(plan.next_snapshot) != plan.next_snapshot.state_hash) {
        error = "ideology_plan_commit_invalid"; return false;
    }
    _current = std::move(plan.next_snapshot);
    _planned = _current;
    plan.committed = 1;
    _plan_ready = false;
    // A day that actually advanced the calendar past the restored floor retires the
    // supersede rule; a day the import already settles keeps it armed.
    if (plan.superseded_day == 0) _import_supersedes_calendar = false;
    return true;
}

void RuntimeIdeologyPodAuthority::serialize(std::vector<uint8_t> &out) const {
    serialize_snapshot(_current, out);
}

// Derived per-country indices + the state hash, for a snapshot built OUTSIDE this
// POD (the main-thread runtime exporting the state a restore installed). The import
// path must run this before `serialize_snapshot`: `active_idea_ids` takes part in
// `compute_state_hash` and `restore` recomputes that hash, so a snapshot that skipped
// it is refused as `ideology_pod_save_state_hash_failed` -- correctly, because the
// bytes would otherwise describe a state this POD can never hold.
void RuntimeIdeologyPodAuthority::canonicalize_import(
        RuntimeIdeologyPodSnapshot &state) {
    for (auto &country : state.countries) rebuild_active_idea_ids(country);
    state.state_hash = compute_state_hash(state);
}

void RuntimeIdeologyPodAuthority::serialize_snapshot(
        const RuntimeIdeologyPodSnapshot &state, std::vector<uint8_t> &out) {
    out.clear(); out.reserve(4096);
    append_le<uint32_t>(out, SAVE_MAGIC); append_le<uint32_t>(out, RUNTIME_IDEOLOGY_POD_ABI_VERSION);
    append_le<uint64_t>(out, state.catalog_hash); append_le<uint64_t>(out, state.state_hash);
    append_le<uint64_t>(out, state.input_generation); append_le<uint64_t>(out, state.opinion_revision);
    append_le<uint64_t>(out, state.generation); append_le<int64_t>(out, state.committed_day);
    append_le<int64_t>(out, state.round_day); append_le(out, state.phase);
    append_le<uint32_t>(out, state.pending_cursor); append_le<uint32_t>(out, state.command_cursor);
    append_le<uint32_t>(out, state.active_country_cursor); append_le<uint32_t>(out, state.active_idea_cursor);
    append_le<uint64_t>(out, state.next_submit_order);
    append_le<uint32_t>(out, static_cast<uint32_t>(state.producer_high_watermarks.size()));
    for (const auto &watermark : state.producer_high_watermarks) {
        append_le<uint32_t>(out, watermark.producer_id);
        append_le<uint64_t>(out, watermark.sequence);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(state.countries.size()));
    for (const auto &country : state.countries) {
        append_le<uint64_t>(out, country.handle); append_le<uint32_t>(out, country.generation);
        append_le<int64_t>(out, country.ideology_points_q16); append_le<uint64_t>(out, country.rng_state);
        append_le<uint64_t>(out, country.points_revision); append_le<uint8_t>(out, country.baseline_ready);
        append_le<uint8_t>(out, country.history_count); append_le<uint8_t>(out, country.history_head);
        append_le<int64_t>(out, country.baseline_population); append_le<int64_t>(out, country.baseline_buildings);
        append_le<int64_t>(out, country.lifetime_points_q16);
        // Ring/day markers that gate the trade flow. Omitting one would let a
        // restored session pay trade again for a day it already paid.
        append_le<int64_t>(out, country.trade_paid_day);
        append_le<int64_t>(out, country.ledger.population_q16); append_le<int64_t>(out, country.ledger.building_q16);
        append_le<int64_t>(out, country.ledger.trade_q16); append_le<int32_t>(out, country.ledger.opinion_factor_q16);
        append_le<int32_t>(out, country.ledger.gain_factor_q16); append_le<int64_t>(out, country.ledger.gain_q16);
        append_le<int64_t>(out, country.ledger.day);
        for (int64_t value : country.history_q16) append_le<int64_t>(out, value);
        append_le<uint64_t>(out, country.draw_sequence);
        append_le<uint16_t>(out, country.free_draws);
        append_le<int32_t>(out, country.ideology_slots_used);
        append_le<int32_t>(out, country.spirit_slots_used); append_le<int32_t>(out, country.unlocked_era);
        append_le<uint64_t>(out, country.opinion_revision);
        append_le<uint32_t>(out, country.offer.generation); for (int32_t id : country.offer.ideology_ids) append_le<int32_t>(out, id);
        append_le<uint8_t>(out, country.offer.active); append_le<uint8_t>(out, country.offer.choice_count);
        append_vector(out, country.known_bits); append_vector(out, country.banned_bits);
        append_vector(out, country.gate_bits); append_vector(out, country.synergy_bits);
        append_le<uint32_t>(out, static_cast<uint32_t>(country.ideas.size()));
        for (const auto &idea : country.ideas) {
            append_le<int64_t>(out, idea.understanding_q16); append_le<int32_t>(out, idea.level);
            append_le<uint64_t>(out, idea.entered_levels); append_le<uint32_t>(out, idea.generation);
            append_le(out, idea.location); append_le<uint8_t>(out, idea.slot_index);
        }
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(state.commands.size()));
    for (const auto &command : state.commands) {
        append_le<uint64_t>(out, command.request_id); append_le<int32_t>(out, command.source_priority);
        append_le<uint32_t>(out, command.producer_id); append_le<uint64_t>(out, command.sequence);
        append_le<uint64_t>(out, command.submit_order); append_le<int64_t>(out, command.requested_day);
        append_le<int64_t>(out, command.effective_day); append_le(out, command.opcode);
        append_le<uint64_t>(out, command.country_handle); append_le<int32_t>(out, command.ideology_id);
        append_le<int64_t>(out, command.value_q16); append_le<uint32_t>(out, command.offer_generation);
        append_le<int32_t>(out, command.choice_index); append_le<int32_t>(out, command.gate_id);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(state.pending_transitions.size()));
    for (const auto &transition : state.pending_transitions) {
        append_le<uint64_t>(out, transition.intent_id); append_le<uint64_t>(out, transition.request_id);
        append_le<uint32_t>(out, transition.producer_id); append_le<uint64_t>(out, transition.sequence);
        append_le<int64_t>(out, transition.effective_day); append_le<uint32_t>(out, transition.country_slot);
        append_le<uint32_t>(out, transition.country_generation); append_le<int32_t>(out, transition.ideology_id);
        append_le<int32_t>(out, transition.desired_level); append_le<uint64_t>(out, transition.desired_entered_levels);
        append_le(out, transition.desired_location);
        append_le<uint8_t>(out, transition.desired_slot_index);
        append_le<uint8_t>(out, transition.intent_emitted);
        append_le<uint64_t>(out, transition.previous_entered_levels);
        append_vector(out, transition.desired_synergy_bits);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(state.receipts.size()));
    for (const auto &receipt : state.receipts) {
        append_le<uint64_t>(out, receipt.request_id); append_le<uint32_t>(out, receipt.producer_id);
        append_le<uint64_t>(out, receipt.sequence); append_le(out, receipt.status); append_le(out, receipt.opcode);
        append_le<uint64_t>(out, receipt.country_handle); append_le<int32_t>(out, receipt.ideology_id);
        append_le<int64_t>(out, receipt.settled_day); append_le<uint32_t>(out, receipt.reason_code);
    }
    append_le<uint32_t>(out, SAVE_END);
    append_le<uint64_t>(out, hash_bytes(FNV_OFFSET, out.data(), out.size()));
}

bool RuntimeIdeologyPodAuthority::restore(
        const uint8_t *data, size_t size, std::string &error) {
    error.clear();
    if (!_configured || data == nullptr || size < 64u || size > MAX_SAVE_BYTES) { error = "ideology_pod_save_invalid"; return false; }
    uint64_t encoded_checksum = 0; size_t checksum_cursor = size - sizeof(uint64_t);
    if (!read_le(data, size, checksum_cursor, encoded_checksum) ||
        hash_bytes(FNV_OFFSET, data, size - sizeof(uint64_t)) != encoded_checksum) { error = "ideology_pod_save_checksum_failed"; return false; }
    const size_t end = size - sizeof(uint64_t); size_t cursor = 0;
    uint32_t magic = 0, abi = 0; uint64_t catalog_hash = 0, saved_hash = 0;
    RuntimeIdeologyPodSnapshot state;
    if (!read_le(data,end,cursor,magic) || !read_le(data,end,cursor,abi) ||
        !read_le(data,end,cursor,catalog_hash) || !read_le(data,end,cursor,saved_hash) ||
        !read_le(data,end,cursor,state.input_generation) || !read_le(data,end,cursor,state.opinion_revision) ||
        !read_le(data,end,cursor,state.generation) || !read_le(data,end,cursor,state.committed_day) ||
        !read_le(data,end,cursor,state.round_day) || !read_le(data,end,cursor,state.phase) ||
        !read_le(data,end,cursor,state.pending_cursor) || !read_le(data,end,cursor,state.command_cursor) ||
        !read_le(data,end,cursor,state.active_country_cursor) || !read_le(data,end,cursor,state.active_idea_cursor) ||
        !read_le(data,end,cursor,state.next_submit_order) || magic != SAVE_MAGIC ||
        abi != RUNTIME_IDEOLOGY_POD_ABI_VERSION || catalog_hash != _catalog.catalog_hash) { error = "ideology_pod_save_header_invalid"; return false; }
    state.catalog_hash = catalog_hash;
    uint32_t count = 0;
    if (!read_le(data, end, cursor, count) ||
        count > RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) {
        error = "ideology_pod_producer_watermark_count_invalid";
        return false;
    }
    state.producer_high_watermarks.resize(count);
    uint32_t previous_producer = 0;
    for (auto &watermark : state.producer_high_watermarks) {
        if (!read_le(data, end, cursor, watermark.producer_id) ||
            !read_le(data, end, cursor, watermark.sequence) ||
            watermark.producer_id == 0 ||
            watermark.producer_id <= previous_producer) {
            error = "ideology_pod_producer_watermark_invalid";
            return false;
        }
        previous_producer = watermark.producer_id;
    }
    if (!read_le(data,end,cursor,count) || count > RUNTIME_IDEOLOGY_POD_MAX_COUNTRIES) { error = "ideology_pod_country_count_invalid"; return false; }
    state.countries.resize(count);
    const uint32_t bit_limit = static_cast<uint32_t>((std::max(_catalog.definitions.size(), _catalog.synergies.size()) + 63u) / 64u);
    for (auto &country : state.countries) {
        if (!read_le(data,end,cursor,country.handle) || !read_le(data,end,cursor,country.generation) ||
            !read_le(data,end,cursor,country.ideology_points_q16) || !read_le(data,end,cursor,country.rng_state) ||
            !read_le(data,end,cursor,country.points_revision) || !read_le(data,end,cursor,country.baseline_ready) ||
            !read_le(data,end,cursor,country.history_count) || !read_le(data,end,cursor,country.history_head) ||
            country.history_count > RUNTIME_IDEOLOGY_POD_HISTORY || country.history_head >= RUNTIME_IDEOLOGY_POD_HISTORY ||
            !read_le(data,end,cursor,country.baseline_population) || !read_le(data,end,cursor,country.baseline_buildings) ||
            !read_le(data,end,cursor,country.lifetime_points_q16) ||
            !read_le(data,end,cursor,country.trade_paid_day) ||
            !read_le(data,end,cursor,country.ledger.population_q16) || !read_le(data,end,cursor,country.ledger.building_q16) ||
            !read_le(data,end,cursor,country.ledger.trade_q16) || !read_le(data,end,cursor,country.ledger.opinion_factor_q16) ||
            !read_le(data,end,cursor,country.ledger.gain_factor_q16) || !read_le(data,end,cursor,country.ledger.gain_q16) ||
            !read_le(data,end,cursor,country.ledger.day) ||
            !std::all_of(country.history_q16.begin(), country.history_q16.end(), [&](int64_t &value) { return read_le(data,end,cursor,value); }) ||
            !read_le(data,end,cursor,country.draw_sequence) ||
            !read_le(data,end,cursor,country.free_draws) ||
            !read_le(data,end,cursor,country.ideology_slots_used) ||
            !read_le(data,end,cursor,country.spirit_slots_used) || !read_le(data,end,cursor,country.unlocked_era) ||
            !read_le(data,end,cursor,country.opinion_revision) ||
            !read_le(data,end,cursor,country.offer.generation) ||
            // The full capacity, always: the save writes a fixed-size row so a
            // build with a different capacity is rejected by the ABI version
            // instead of silently consuming the next field.
            !read_le(data,end,cursor,country.offer.ideology_ids[0]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[1]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[2]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[3]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[4]) ||
            !read_le(data,end,cursor,country.offer.active) ||
            !read_le(data,end,cursor,country.offer.choice_count) ||
            country.offer.choice_count > IDEOLOGY_OFFER_CHOICE_CAPACITY ||
            !read_vector(data,end,cursor,country.known_bits,bit_limit) ||
            !read_vector(data,end,cursor,country.banned_bits,bit_limit) ||
            !read_vector(data,end,cursor,country.gate_bits,static_cast<uint32_t>((_catalog.gate_count + 63u) / 64u)) ||
            !read_vector(data,end,cursor,country.synergy_bits,bit_limit) ||
            !read_le(data,end,cursor,count) || count != _catalog.definitions.size()) { error = "ideology_pod_country_truncated"; return false; }
        country.ideas.resize(count);
        for (auto &idea : country.ideas)
            if (!read_le(data,end,cursor,idea.understanding_q16) || !read_le(data,end,cursor,idea.level) ||
                !read_le(data,end,cursor,idea.entered_levels) || !read_le(data,end,cursor,idea.generation) ||
                !read_le(data,end,cursor,idea.location) ||
                !read_le(data,end,cursor,idea.slot_index) ||
                idea.level < -1 || idea.level >= 64) {
                error = "ideology_pod_idea_truncated"; return false;
            }
        if (country.unlocked_era < 0 || country.unlocked_era > kMaxEraIndex) { error = "ideology_pod_era_invalid"; return false; }
        rebuild_active_idea_ids(country);
    }
    if (!read_le(data,end,cursor,count) || count > RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) { error = "ideology_pod_command_count_invalid"; return false; }
    state.commands.resize(count);
    for (auto &command : state.commands) {
        if (!read_le(data,end,cursor,command.request_id) || !read_le(data,end,cursor,command.source_priority) ||
            !read_le(data,end,cursor,command.producer_id) || !read_le(data,end,cursor,command.sequence) ||
            !read_le(data,end,cursor,command.submit_order) || !read_le(data,end,cursor,command.requested_day) ||
            !read_le(data,end,cursor,command.effective_day) || !read_le(data,end,cursor,command.opcode) ||
            !read_le(data,end,cursor,command.country_handle) || !read_le(data,end,cursor,command.ideology_id) ||
            !read_le(data,end,cursor,command.value_q16) || !read_le(data,end,cursor,command.offer_generation) ||
            !read_le(data,end,cursor,command.choice_index) || !read_le(data,end,cursor,command.gate_id) ||
            !validate_command(command, error)) return false;
    }
    if (!read_le(data,end,cursor,count) || count > RUNTIME_IDEOLOGY_POD_MAX_TRANSITIONS) { error = "ideology_pod_transition_count_invalid"; return false; }
    state.pending_transitions.resize(count);
    for (auto &transition : state.pending_transitions)
        if (!read_le(data,end,cursor,transition.intent_id) || !read_le(data,end,cursor,transition.request_id) ||
            !read_le(data,end,cursor,transition.producer_id) || !read_le(data,end,cursor,transition.sequence) ||
            !read_le(data,end,cursor,transition.effective_day) || !read_le(data,end,cursor,transition.country_slot) ||
            !read_le(data,end,cursor,transition.country_generation) || !read_le(data,end,cursor,transition.ideology_id) ||
            !read_le(data,end,cursor,transition.desired_level) || !read_le(data,end,cursor,transition.desired_entered_levels) ||
            !read_le(data,end,cursor,transition.desired_location) ||
            !read_le(data,end,cursor,transition.desired_slot_index) ||
            !read_le(data,end,cursor,transition.intent_emitted) ||
            !read_le(data,end,cursor,transition.previous_entered_levels) ||
            !read_vector(data,end,cursor,transition.desired_synergy_bits,bit_limit) || transition.intent_id == 0 ||
            transition.country_slot >= state.countries.size() || transition.ideology_id < 0 ||
            transition.ideology_id >= static_cast<int32_t>(_catalog.definitions.size())) { error = "ideology_pod_transition_truncated"; return false; }
    if (!read_le(data,end,cursor,count) || count > RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) { error = "ideology_pod_receipt_count_invalid"; return false; }
    state.receipts.resize(count);
    for (auto &receipt : state.receipts)
        if (!read_le(data,end,cursor,receipt.request_id) || !read_le(data,end,cursor,receipt.producer_id) ||
            !read_le(data,end,cursor,receipt.sequence) || !read_le(data,end,cursor,receipt.status) ||
            !read_le(data,end,cursor,receipt.opcode) || !read_le(data,end,cursor,receipt.country_handle) ||
            !read_le(data,end,cursor,receipt.ideology_id) || !read_le(data,end,cursor,receipt.settled_day) ||
            !read_le(data,end,cursor,receipt.reason_code)) { error = "ideology_pod_receipt_truncated"; return false; }
    uint32_t end_marker = 0;
    if (!read_le(data,end,cursor,end_marker) || end_marker != SAVE_END || cursor != end) { error = "ideology_pod_save_trailing_bytes"; return false; }
    if (state.command_cursor > state.commands.size() || state.pending_cursor > state.pending_transitions.size() ||
        state.active_country_cursor > state.countries.size()) { error = "ideology_pod_cursor_invalid"; return false; }
    state.state_hash = compute_state_hash(state);
    if (state.state_hash != saved_hash) { error = "ideology_pod_save_state_hash_failed"; return false; }
    _current = std::move(state); _planned = _current; _plan_ready = false;
    // A restore MEANS "your authoritative state is now this" -- whether the bytes came
    // from this POD's own save or from the main-thread runtime's import. Its committed
    // day is now the FLOOR of this worker's calendar: every day at or below it is
    // already settled by the imported state and must plan as a no-op instead of
    // failing `ideology_day_not_monotonic` (see `plan_day`).
    _import_supersedes_calendar = true;
    return true;
}

void RuntimeIdeologyPodAuthority::rearm_pending_transitions() {
    bool changed = false;
    for (auto &transition : _current.pending_transitions) {
        if (transition.intent_emitted == 0) continue;
        transition.intent_emitted = 0;
        changed = true;
    }
    if (changed) {
        _current.pending_cursor = 0;
        _current.state_hash = compute_state_hash(_current);
        _planned = _current;
        _plan_ready = false;
    }
}

bool RuntimeIdeologyPodAuthority::self_test(std::string &error) {
    error.clear();
    // Shared multiplier maths first: both authorities read these, and a rounding
    // difference between them shows up as a replay mismatch weeks later rather
    // than as a wrong number here.
    {
        const int32_t one = static_cast<int32_t>(Q16_ONE);
        if (ideology_frozen_factor({}, 0) != one ||
            ideology_frozen_factor({static_cast<int32_t>(2 * Q16_ONE)}, 0) != 2 * one ||
            ideology_frozen_factor({one}, 3) != one ||
            ideology_frozen_factor({static_cast<int32_t>(100 * Q16_ONE)}, 0) != 4 * one) {
            error = "ideology_self_test_frozen_factor_failed"; return false;
        }
        if (ideology_scaled_daily(1000, one) != 1000 ||
            ideology_scaled_daily(1000, 2 * one) != 2000 ||
            ideology_scaled_daily(1000, 0) != 0 ||
            ideology_scaled_daily(0, 2 * one) != 0) {
            error = "ideology_self_test_scaled_daily_failed"; return false;
        }
        if (ideology_reroll_percent(50, one) != 50 ||
            ideology_reroll_percent(50, 2 * one) != 100 ||
            ideology_reroll_percent(50, 0) != 0 ||
            ideology_reroll_percent(400, 4 * one) != 400) {
            error = "ideology_self_test_reroll_percent_failed"; return false;
        }
    }
    // R8-3: the country RNG seed must depend on the WORLD, not only on the
    // handle. Before this the same country drew the same card sequence in every
    // game of the same map, which is a content defect rather than a parity one
    // (both authorities shared the bug, so parity could not see it).
    {
        constexpr uint64_t kHandle = 0x1ull << 32u;
        const uint64_t zero = runtime_ideology_country_rng_seed(kHandle, 0);
        const uint64_t a = runtime_ideology_country_rng_seed(kHandle, 1);
        const uint64_t b = runtime_ideology_country_rng_seed(kHandle, 2);
        if (a == b || a == zero || b == zero ||
            runtime_ideology_country_rng_seed(kHandle, 1) != a ||
            runtime_ideology_country_rng_seed(kHandle ^ 1u, 1) == a) {
            error = "ideology_self_test_world_seed_failed"; return false;
        }
    }
    RuntimeIdeologyPodCatalog catalog;
    catalog.country_catalog_hash = 77; catalog.class_hash = 88; catalog.class_count = 1;
    catalog.route_keys = {"cropland"};
    catalog.technology_count = 1; catalog.research_signal_count = 1; catalog.gate_count = 1;
    catalog.ideology_capacity = 4; catalog.spirit_capacity = 2; catalog.starting_points_q16 = Q16_ONE;
    catalog.point_population_weight_q16 = Q16_ONE;
    catalog.max_commands_per_slice = 2; catalog.max_transition_polls_per_slice = 1; catalog.max_active_visits_per_slice = 1;
    catalog.levels = {{0, 0}};
    for (int i = 0; i < 4; ++i) {
        RuntimeIdeologyPodDefinition d; d.level_begin = 0; d.level_count = 1; d.rarity_weight = i + 1;
        d.stance_begin = 0; d.stance_count = 1; d.support_threshold_q16 = {{-Q16_ONE, -Q16_ONE, -Q16_ONE}};
        catalog.definitions.push_back(d);
    }
    catalog.ideology_synergy_offsets = {0, 0, 0, 0, 0};
    RuntimeIdeologyPodClassStance stance; stance.class_index = 0; stance.stance_q16 = {{Q16_ONE, Q16_ONE, Q16_ONE}};
    catalog.class_stances.push_back(stance);
    RuntimeCountryPodSnapshot country;
    country.generation = 1; country.catalog_hash = 77; country.bootstrapped = true; country.country_count = 1;
    country.technology_count = 1; country.technology_words = 1; country.research_signal_count = 1; country.research_signal_words = 1;
    country.country_active = {1}; country.country_generation = {3}; country.country_technologies = {1};
    country.country_discovered = {1}; country.country_pending_technologies = {0}; country.country_research_signals = {1};
    RuntimeIdeologyOpinionSnapshot opinion;
    opinion.revision = 1; opinion.class_hash = 88; opinion.country_count = 1; opinion.class_count = 1;
    const uint64_t handle = (3ull << 32u); opinion.country_handles = {handle}; opinion.country_generations = {3};
    opinion.population = {100}; opinion.funds = {0}; opinion.owner_employed = {0}; opinion.satisfaction_weighted = {0}; opinion.satisfaction_q16 = {0};
    // X6-a acceptance: only the population lane is doubled. The next
    // observation must pay 20 + 7 = 27 Q16, then apply the 0.5 opinion factor
    // because satisfaction is zero. The ledger is read directly so a helper
    // that happens to add the right total cannot hide a wrong term.
    {
        RuntimeIdeologyPodCatalog factor_catalog = catalog;
        factor_catalog.point_population_weight_q16 = Q16_ONE;
        factor_catalog.point_building_weight_q16 = Q16_ONE;
        factor_catalog.point_trade_weight_q16 = Q16_ONE;
        RuntimeIdeologyOpinionSnapshot factor_opinion = opinion;
        factor_opinion.revision = 1;
        factor_opinion.country_population = {100};
        factor_opinion.country_buildings_installed = {0};
        factor_opinion.country_trade_base_value = {0};
        factor_opinion.period_days = 1;
        factor_opinion.point_population_factor_q16 = {
            static_cast<int32_t>(2 * Q16_ONE)};
        RuntimeIdeologyPodAuthority factor_authority;
        RuntimeIdeologyPodPlan factor_plan;
        if (!factor_authority.configure(factor_catalog, error) ||
            !factor_authority.bootstrap(country, factor_opinion, error) ||
            !factor_authority.plan_day(0, country, factor_opinion, {},
                                       factor_plan, error) ||
            !factor_authority.commit_day(factor_plan, error)) {
            error = "ideology_self_test_x6a_baseline_failed";
            return false;
        }
        const int64_t before = factor_authority.snapshot()
            .countries[0].ideology_points_q16;
        factor_opinion.revision = 2;
        factor_opinion.country_population = {110};
        factor_opinion.country_buildings_installed = {7};
        if (!factor_authority.plan_day(1, country, factor_opinion, {},
                                       factor_plan, error) ||
            !factor_authority.commit_day(factor_plan, error)) {
            error = "ideology_self_test_x6a_accrual_failed";
            return false;
        }
        const auto &factor_row = factor_authority.snapshot().countries[0];
        const int64_t expected_gain = 27 * Q16_ONE / 2;
        if (factor_row.ledger.population_q16 != 20 * Q16_ONE ||
            factor_row.ledger.building_q16 != 7 * Q16_ONE ||
            factor_row.ledger.trade_q16 != 0 ||
            factor_row.ledger.gain_q16 != expected_gain ||
            factor_row.ideology_points_q16 - before != expected_gain) {
            error = "ideology_self_test_x6a_ledger_failed";
            return false;
        }
    }
    RuntimeIdeologyPodAuthority authority;
    if (!authority.configure(catalog, error) || !authority.bootstrap(country, opinion, error)) return false;
    RuntimeIdeologyOpinionSnapshot invalid = opinion; invalid.revision = 0;
    RuntimeIdeologyPodPlan plan;
    if (authority.plan_day(0, country, invalid, {}, plan, error)) { error = "ideology_self_test_revision_rejection_failed"; return false; }
    RuntimeCountryPodSnapshot stale_country = country;
    stale_country.country_generation[0] = 4;
    stale_country.generation = 2;
    RuntimeIdeologyOpinionSnapshot stale_opinion = opinion;
    stale_opinion.country_generations[0] = 4;
    stale_opinion.country_handles[0] = (4ull << 32u);
    if (authority.plan_day(0, stale_country, stale_opinion, {}, plan, error) ||
        error != "ideology_country_state_generation_mismatch") {
        error = "ideology_self_test_country_generation_rejection_failed";
        return false;
    }
    auto command = [&](uint64_t id, RuntimeIdeologyPodOpcode opcode, int32_t idea, int64_t value, int32_t priority) {
        RuntimeIdeologyPodCommand c; c.request_id = id; c.producer_id = 1; c.sequence = id; c.requested_day = 0; c.effective_day = 0;
        c.source_priority = priority; c.country_handle = handle; c.opcode = opcode; c.ideology_id = idea; c.value_q16 = value; return c;
    };
    auto grant = command(1, RuntimeIdeologyPodOpcode::GRANT_POINTS, -1, Q16_ONE, 2);
    auto gate = command(2, RuntimeIdeologyPodOpcode::SET_GATE, -1, 1, 1); gate.gate_id = 0;
    auto discover = command(3, RuntimeIdeologyPodOpcode::DISCOVER, 0, 0, 3);
    if (!authority.queue_command(discover, error) || !authority.queue_command(grant, error) || !authority.queue_command(gate, error)) return false;
    bool checked_opinion_continuation = false;
    do {
        if (!authority.plan_day(0, country, opinion, {}, plan, error) ||
            !authority.commit_day(plan, error)) return false;
        if (!plan.completed_day && !checked_opinion_continuation) {
            RuntimeIdeologyOpinionSnapshot changed_opinion = opinion;
            changed_opinion.revision = 2;
            RuntimeIdeologyPodPlan rejected_plan;
            if (authority.plan_day(0, country, changed_opinion, {},
                                   rejected_plan, error) ||
                error != "ideology_same_day_continuation_opinion_changed") {
                error = "ideology_self_test_opinion_continuation_rejection_failed";
                return false;
            }
            checked_opinion_continuation = true;
            error.clear();
        }
    } while (!plan.completed_day);
    if (!bit_get(authority.snapshot().countries[0].known_bits, 0) || !bit_get(authority.snapshot().countries[0].gate_bits, 0)) { error = "ideology_self_test_order_or_basic_opcode_failed"; return false; }
    auto open = command(4, RuntimeIdeologyPodOpcode::OPEN_OFFER, -1, 0, 0); open.effective_day = open.requested_day = 1;
    if (!authority.queue_command(open, error)) return false;
    do { if (!authority.plan_day(1, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    if (authority.snapshot().countries[0].offer.active == 0) { error = "ideology_self_test_offer_failed"; return false; }
    auto choose = command(5, RuntimeIdeologyPodOpcode::CHOOSE_OFFER, -1, 0, 0); choose.effective_day = choose.requested_day = 2;
    choose.offer_generation = authority.snapshot().countries[0].offer.generation; choose.choice_index = 0;
    if (!authority.queue_command(choose, error)) return false;
    do { if (!authority.plan_day(2, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    int32_t chosen = -1; for (int32_t id = 1; id < 4; ++id) if (bit_get(authority.snapshot().countries[0].known_bits, id)) { chosen = id; break; }
    if (chosen < 0) { error = "ideology_self_test_choose_failed"; return false; }
    auto equip = command(6, RuntimeIdeologyPodOpcode::EQUIP, chosen, 0, 0); equip.effective_day = equip.requested_day = 3;
    if (!authority.queue_command(equip, error)) return false;
    bool saw_deferred_intent = false;
    do {
        if (!authority.plan_day(3, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false;
        if (!plan.intents.empty()) {
            saw_deferred_intent = true;
            if ((plan.intents[0].flags & (RUNTIME_DOMAIN_INTENT_DEFERRED | RUNTIME_DOMAIN_INTENT_REQUIRES_ACK)) !=
                    (RUNTIME_DOMAIN_INTENT_DEFERRED | RUNTIME_DOMAIN_INTENT_REQUIRES_ACK)) {
                error = "ideology_self_test_intent_flags_failed"; return false;
            }
        }
    } while (!plan.completed_day);
    if (authority.snapshot().countries[0].ideas[chosen].location != RuntimeIdeologyPodLocation::INACTIVE ||
        authority.snapshot().pending_transitions.size() != 1 || !saw_deferred_intent) { error = "ideology_self_test_deferred_transition_failed"; return false; }
    const uint64_t intent_id = authority.snapshot().pending_transitions[0].intent_id;
    RuntimeDomainAck ack; ack.transaction_id = intent_id; ack.target_handle = handle; ack.target_generation = 3;
    ack.effective_day = 3;
    ack.domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT); ack.code = RuntimeDomainAckCode::OK;
    RuntimeDomainAck wrong_day_ack = ack;
    wrong_day_ack.effective_day = 4;
    if (authority.plan_day(4, country, opinion, {wrong_day_ack}, plan, error) ||
        error != "ideology_ack_effective_day_mismatch") {
        error = "ideology_self_test_ack_day_rejection_failed";
        return false;
    }
    do { if (!authority.plan_day(4, country, opinion, {ack}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    if (authority.snapshot().countries[0].ideas[chosen].location != RuntimeIdeologyPodLocation::IDEOLOGY ||
        !authority.snapshot().pending_transitions.empty()) { error = "ideology_self_test_real_ack_failed"; return false; }
    auto add = command(7, RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING, chosen, Q16_ONE, 0); add.effective_day = add.requested_day = 5;
    if (!authority.queue_command(add, error)) return false;
    do { if (!authority.plan_day(5, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    auto promote = command(8, RuntimeIdeologyPodOpcode::PROMOTE, chosen, 0, 0); promote.effective_day = promote.requested_day = 6;
    if (!authority.queue_command(promote, error)) return false;
    do { if (!authority.plan_day(6, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    auto unequip = command(9, RuntimeIdeologyPodOpcode::UNEQUIP, chosen, 0, 0); unequip.effective_day = unequip.requested_day = 7;
    if (!authority.queue_command(unequip, error)) return false;
    do { if (!authority.plan_day(7, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    // Increment-only accrual: the first lane observation is a baseline, the
    // next pays delta-population * weight * opinion factor (satisfaction 0 -> 0.5).
    RuntimeIdeologyOpinionSnapshot grow = opinion;
    grow.revision = 5; grow.country_population = {100}; grow.country_buildings_installed = {0};
    grow.country_trade_base_value = {0}; grow.period_days = 1;
    do { if (!authority.plan_day(8, country, grow, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    const int64_t points_before = authority.snapshot().countries[0].ideology_points_q16;
    grow.revision = 6; grow.country_population = {110};
    do { if (!authority.plan_day(9, country, grow, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    if (authority.snapshot().countries[0].ideology_points_q16 - points_before != 5 * Q16_ONE ||
        authority.snapshot().countries[0].history_count != 1) {
        error = "ideology_self_test_point_accrual_failed"; return false;
    }
    auto reopen = command(10, RuntimeIdeologyPodOpcode::OPEN_OFFER, -1, 0, 0); reopen.effective_day = reopen.requested_day = 10;
    if (!authority.queue_command(reopen, error)) return false;
    do { if (!authority.plan_day(10, country, grow, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    const uint32_t offer_generation = authority.snapshot().countries[0].offer.generation;
    const int64_t before_reroll = authority.snapshot().countries[0].ideology_points_q16;
    auto reroll = command(11, RuntimeIdeologyPodOpcode::REROLL_OFFER, -1, 0, 0); reroll.effective_day = reroll.requested_day = 11;
    reroll.offer_generation = offer_generation;
    if (!authority.queue_command(reroll, error)) return false;
    do { if (!authority.plan_day(11, country, grow, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    if (authority.snapshot().countries[0].offer.active == 0 ||
        authority.snapshot().countries[0].offer.generation != offer_generation + 1u ||
        before_reroll - authority.snapshot().countries[0].ideology_points_q16 != Q16_ONE / 2) {
        error = "ideology_self_test_reroll_failed"; return false;
    }
    // X6-b: a free draw and a paid draw at the same state must consume the
    // exact same RNG path. Clone the authority after the reroll, close the
    // existing offer on both branches, then open both at the same global day.
    // The free grant is a command on an earlier day, while both OPEN_OFFER
    // commands settle on day 13; the free branch only decrements its row
    // counter, while the paid branch charges points.
    {
        auto close_offer = [](RuntimeIdeologyPodAuthority &target,
                              std::string &close_error) {
            // The only effect is removing the current offer. CHOOSE_OFFER is
            // unsuitable because it also mutates knowledge/understanding.
            // Restore-style reset through the public API would require a
            // serialized copy. The self-test runs inside this class, so direct
            // state access is intentional and keeps the test independent of
            // serialization.
            target._current.countries[0].offer.clear();
            target._current.state_hash = compute_state_hash(target._current);
            target._planned = target._current;
            target._plan_ready = false;
            close_error.clear();
            return true;
        };
        auto run_command = [&](RuntimeIdeologyPodAuthority &target,
                               RuntimeIdeologyPodOpcode opcode,
                               uint64_t request_id, int64_t target_day,
                               int64_t value,
                               RuntimeIdeologyPodPlan &day_plan,
                               std::string &day_error) {
            RuntimeIdeologyPodCommand next_command = command(
                request_id, opcode, -1, value, 0);
            next_command.effective_day = target_day;
            next_command.requested_day = target_day;
            if (!target.queue_command(next_command, day_error)) return false;
            do {
                if (!target.plan_day(target_day, country, grow, {}, day_plan,
                                     day_error) ||
                    !target.commit_day(day_plan, day_error)) return false;
            } while (!day_plan.completed_day);
            return true;
        };
        // Free branch: grant on day 12, then open alongside the paid branch on
        // day 13 so both draws see the same committed-day RNG.
        // Copy constructed from a configured authority. The branch-local
        // helpers below use only command/plan/day paths, never implementation
        // private fields.
        RuntimeIdeologyPodAuthority free_authority = authority;
        RuntimeIdeologyPodAuthority paid_authority = authority;
        std::string branch_error;
        if (!close_offer(free_authority, branch_error) ||
                !close_offer(paid_authority, branch_error)) {
            error = "ideology_self_test_x6b_setup_failed"; return false;
        }
        const uint64_t free_rng = free_authority.snapshot().countries[0].rng_state;
        const uint64_t paid_rng = paid_authority.snapshot().countries[0].rng_state;
        const uint64_t free_draw_sequence =
            free_authority.snapshot().countries[0].draw_sequence;
        const uint64_t paid_draw_sequence =
            paid_authority.snapshot().countries[0].draw_sequence;
        const int64_t free_points =
            free_authority.snapshot().countries[0].ideology_points_q16;
        const int64_t paid_points =
            paid_authority.snapshot().countries[0].ideology_points_q16;
        RuntimeIdeologyPodPlan free_plan;
        // Grant first on its own day, then open on day 13.
        if (!run_command(free_authority,
                         RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW, 101, 12,
                         1, free_plan, branch_error)) {
            error = "ideology_self_test_x6b_free_grant_failed"; return false;
        }
        free_plan = RuntimeIdeologyPodPlan{};
        const uint64_t granted_free_draws =
            free_authority.snapshot().countries[0].free_draws;
        if (granted_free_draws != 1) {
            error = "ideology_self_test_x6b_free_grant_not_visible_failed";
            return false;
        }
        if (!run_command(free_authority, RuntimeIdeologyPodOpcode::OPEN_OFFER,
                         102, 13, 0, free_plan, branch_error)) {
            error = "ideology_self_test_x6b_free_open_failed"; return false;
        }
        RuntimeIdeologyPodPlan paid_plan;
        if (!run_command(paid_authority, RuntimeIdeologyPodOpcode::OPEN_OFFER,
                         103, 13, 0, paid_plan, branch_error)) {
            error = "ideology_self_test_x6b_paid_open_failed"; return false;
        }
        const auto &free_row = free_authority.snapshot().countries[0];
        const auto &paid_row = paid_authority.snapshot().countries[0];
        if (free_rng != paid_rng ||
                free_draw_sequence != paid_draw_sequence ||
                free_points != paid_points ||
                free_row.free_draws != 0 ||
                paid_row.free_draws != 0 ||
                free_row.ideology_points_q16 != free_points ||
                paid_row.ideology_points_q16 >= paid_points ||
                free_row.draw_sequence != free_draw_sequence + 1u ||
                paid_row.draw_sequence != paid_draw_sequence + 1u ||
                free_row.rng_state != paid_row.rng_state ||
                free_row.offer.generation != paid_row.offer.generation ||
                free_row.offer.choice_count != paid_row.offer.choice_count) {
            error = "ideology_self_test_x6b_rng_or_accounting_failed"; return false;
        }
        for (int32_t choice = 0; choice < free_row.offer.choice_count; ++choice) {
            if (free_row.offer.ideology_ids[static_cast<size_t>(choice)] !=
                    paid_row.offer.ideology_ids[static_cast<size_t>(choice)]) {
                error = "ideology_self_test_x6b_offer_mismatch_failed"; return false;
            }
        }
    }
    // Same reroll, but with the frozen reroll factor at 2x: the charge has to
    // double. This is the only place the factor is observed end to end — the
    // kernel facts above only prove the arithmetic, not that apply_command
    // reads the array at all.
    {
        RuntimeIdeologyOpinionSnapshot costly = grow;
        costly.reroll_cost_q16 = {static_cast<int32_t>(2 * Q16_ONE)};
        const int64_t before_costly =
            authority.snapshot().countries[0].ideology_points_q16;
        auto reroll_costly = command(12, RuntimeIdeologyPodOpcode::REROLL_OFFER, -1, 0, 0);
        reroll_costly.effective_day = reroll_costly.requested_day = 12;
        reroll_costly.offer_generation =
            authority.snapshot().countries[0].offer.generation;
        if (!authority.queue_command(reroll_costly, error)) return false;
        do { if (!authority.plan_day(12, country, costly, {}, plan, error) ||
                   !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
        if (authority.snapshot().countries[0].offer.active == 0 ||
            before_costly - authority.snapshot().countries[0].ideology_points_q16
                != Q16_ONE) {
            error = "ideology_self_test_reroll_factor_failed"; return false;
        }
    }
    // A1 / 6b: settlement-count invariance.
    //
    // The property that makes parity possible: over the same 30 days, settling
    // once, thirty times, or a random number of times must pay the SAME trade
    // total. Previously trade paid `trade_per_day` on every settlement and then
    // suppressed a second settlement in the same day, which made the total a
    // function of the settlement count -- 46859 vs 67969 in the field.
    {
        constexpr int64_t kDays = 30;
        constexpr int64_t kTradePerDay = 1000;     // already weight-scaled
        constexpr int64_t kPeriod = 5;             // opinion period, < kDays
        // EVERY schedule starts with day 1, because the first observation SEEDS
        // the marker and pays nothing. A schedule that begins at day 30 would
        // seed there and pay zero, which is correct behaviour but not the same
        // experiment: what is under test is "the same elapsed span, settled a
        // different number of times", so all schedules share the seed day.
        auto settle_total = [&](const std::vector<int64_t> &later_settlements) {
            int64_t paid = INT64_MIN;
            int64_t total = ideology_trade_flow_q16(kTradePerDay, 1, kPeriod, paid);
            for (int64_t day : later_settlements)
                total += ideology_trade_flow_q16(kTradePerDay, day, kPeriod, paid);
            return total;
        };
        // 1) once, at the end
        // 2) every day
        // 3) every `kPeriod` days (the production case: period-aligned commits)
        // 4) an irregular deterministic subset, including same-day repeats
        std::vector<int64_t> once = {kDays};
        std::vector<int64_t> daily;
        std::vector<int64_t> periodic;
        std::vector<int64_t> ragged;
        for (int64_t day = 2; day <= kDays; ++day) {
            daily.push_back(day);
            if (day % kPeriod == 0) periodic.push_back(day);
            // Deterministic pattern with irregular gaps, including repeats.
            if ((day * 7 + 3) % 5 != 0) ragged.push_back(day);
            if (day % 11 == 0) ragged.push_back(day);
        }
        const int64_t once_total = settle_total(once);
        const int64_t daily_total = settle_total(daily);
        const int64_t periodic_total = settle_total(periodic);
        const int64_t ragged_total = settle_total(ragged);
        if (once_total != daily_total || once_total != periodic_total ||
            once_total != ragged_total) {
            error = "ideology_self_test_trade_settlement_invariance_failed";
            return false;
        }
        // And the amount itself must be right, not merely equal: day 1 seeds, so
        // 29 elapsed days at 1000/day is 29000.
        const int64_t expected = kTradePerDay * (kDays - 1);
        if (once_total != expected) {
            error = "ideology_self_test_trade_settlement_amount_failed";
            return false;
        }
        // A gap longer than the period pays the WHOLE gap, not one period. This
        // is the assertion that pins the decision not to clamp: the clamp read
        // "total depends only on elapsed days" while paying `period` for a
        // 99-day gap, which made a single settlement pay less than daily ones.
        int64_t wide_paid = INT64_MIN;
        if (ideology_trade_flow_q16(kTradePerDay, 1, kPeriod, wide_paid) != 0 ||
            ideology_trade_flow_q16(kTradePerDay, 100, kPeriod, wide_paid)
                != kTradePerDay * 99) {
            error = "ideology_self_test_trade_settlement_gap_failed";
            return false;
        }
        // Repeats in the same day pay once.
        int64_t repeat_paid = INT64_MIN;
        if (ideology_trade_flow_q16(kTradePerDay, 1, kPeriod, repeat_paid) != 0 ||
            ideology_trade_flow_q16(kTradePerDay, 1, kPeriod, repeat_paid) != 0 ||
            ideology_trade_flow_q16(kTradePerDay, 2, kPeriod, repeat_paid)
                != kTradePerDay) {
            error = "ideology_self_test_trade_settlement_repeat_failed";
            return false;
        }
    }
    std::vector<uint8_t> bytes; authority.serialize(bytes);
    RuntimeIdeologyPodAuthority restored;
    if (!restored.configure(catalog, error) || !restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().state_hash != authority.snapshot().state_hash) { error = "ideology_self_test_save_roundtrip_failed"; return false; }
    const uint64_t before = restored.snapshot().state_hash; bytes.back() ^= 0x40u;
    if (restored.restore(bytes.data(), bytes.size(), error) || restored.snapshot().state_hash != before) { error = "ideology_self_test_transactional_restore_failed"; return false; }
    error.clear();
    // R8-1: an OLDER payload must be refused by VERSION, and refused before the
    // body is decoded.
    //
    // The defect this pins: `trade_paid_day` (and then the accrual markers) were
    // appended to the country row while the ABI stayed 5, so a v5 file was
    // decoded with the v6 field layout and came out as a late, wrong error
    // (truncation or state-hash mismatch). Rebuild the header with the previous
    // ABI and a matching checksum, keeping every other byte: the catalog hash
    // and state hash are the ones this authority just wrote, so a reader that
    // skipped the version gate WOULD accept the payload. Only the version can
    // reject it, which is exactly the property being asserted.
    {
        constexpr uint32_t stale_abi = RUNTIME_IDEOLOGY_POD_ABI_VERSION - 1u;
        std::vector<uint8_t> stale;
        stale.reserve(bytes.size());
        append_le<uint32_t>(stale, SAVE_MAGIC);
        append_le<uint32_t>(stale, stale_abi);
        // Everything from the catalog hash to the last body byte, verbatim.
        constexpr size_t header_size = sizeof(uint32_t) * 2u;
        if (bytes.size() <= header_size + sizeof(uint64_t) ||
            stale.size() != header_size) {
            error = "ideology_self_test_stale_abi_setup_failed"; return false;
        }
        stale.insert(stale.end(), bytes.begin() + header_size,
                     bytes.end() - sizeof(uint64_t));
        append_le<uint64_t>(stale, hash_bytes(FNV_OFFSET, stale.data(), stale.size()));
        RuntimeIdeologyPodAuthority guard;
        if (!guard.configure(catalog, error)) {
            error = "ideology_self_test_stale_abi_setup_failed"; return false;
        }
        std::string stale_error;
        if (guard.restore(stale.data(), stale.size(), stale_error) ||
            stale_error != "ideology_pod_save_header_invalid") {
            error = "ideology_self_test_stale_abi_rejection_failed"; return false;
        }
        // And the current ABI still round-trips, so the gate rejects the old
        // version rather than everything.
        std::vector<uint8_t> fresh;
        authority.serialize(fresh);
        RuntimeIdeologyPodAuthority control;
        if (!control.configure(catalog, error) ||
            !control.restore(fresh.data(), fresh.size(), error) ||
            control.snapshot().state_hash != authority.snapshot().state_hash) {
            error = "ideology_self_test_stale_abi_control_failed"; return false;
        }
    }
    error.clear(); return true;
}

RuntimeIdeologySnapshotRing::RuntimeIdeologySnapshotRing() { reset(); }

void RuntimeIdeologySnapshotRing::reset() {
    for (Slot &slot : _slots) {
        slot.snapshot = RuntimeIdeologyPodSnapshot{};
        slot.state.store(FREE, std::memory_order_relaxed);
    }
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeIdeologySnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        uint8_t expected = FREE;
        if (_slots[i].state.compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            index = i;
            return true;
        }
    }
    uint64_t oldest_generation = std::numeric_limits<uint64_t>::max();
    uint32_t oldest_index = 0;
    bool ready_found = false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if (!ready_found || generation < oldest_generation) {
            oldest_generation = generation;
            oldest_index = i;
            ready_found = true;
        }
    }
    if (ready_found) {
        uint8_t expected = READY;
        if (_slots[oldest_index].state.compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel,
                std::memory_order_relaxed)) {
            index = oldest_index;
            return true;
        }
    }
    _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    return false;
}

void RuntimeIdeologySnapshotRing::publish(uint32_t index) {
    if (index >= _slots.size()) return;
    _published_generation.store(_slots[index].snapshot.generation,
                                std::memory_order_relaxed);
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeIdeologySnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                     uint32_t &index) {
    const bool accept_initial =
        after_generation == std::numeric_limits<uint64_t>::max();
    uint64_t best = 0;
    uint32_t best_index = 0;
    bool found = false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if ((accept_initial || generation > after_generation) &&
            (!found || generation > best)) {
            best = generation;
            best_index = i;
            found = true;
        }
    }
    if (!found) return false;
    uint8_t expected = READY;
    if (!_slots[best_index].state.compare_exchange_strong(expected, READING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    index = best_index;
    return true;
}

void RuntimeIdeologySnapshotRing::release(uint32_t index) {
    if (index >= _slots.size()) return;
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeIdeologySnapshotRing::self_test() {
    RuntimeIdeologySnapshotRing ring;
    uint32_t slot = 0;
    if (!ring.try_begin_write(slot)) return false;
    ring.write_buffer(slot).generation = 7;
    ring.publish(slot);
    uint32_t acquired = 0;
    if (!ring.try_acquire_latest(0, acquired)) return false;
    if (ring.read_buffer(acquired).generation != 7) return false;
    ring.release(acquired);
    return true;
}

namespace {
inline uint64_t business_mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}
inline uint64_t business_seed() { return 1469598103934665603ULL; }
} // namespace

void ideology_business_sections(const RuntimeIdeologyPodSnapshot &state,
                                IdeologyBusinessSections &out) {
    out = IdeologyBusinessSections{};
    // `catalog_hash` is deliberately NOT mixed in. The main thread and the worker
    // compute it with two different functions over two different structures:
    //   main   -> NativeIdeologyRuntime::compute_catalog_hash()
    //   worker -> RuntimeIdeologyPodAuthority::compute_catalog_hash()
    // so the two values differ by construction. Folding it into `points` made
    // that section permanently unequal and made every real parity comparison
    // report `field=points`. Catalog agreement is a PRECONDITION, checked
    // separately (see `ideology_catalog_mismatch`), never a business field.
    out.points = business_seed();
    out.baseline = business_seed();
    out.history = business_seed();
    out.draw = business_seed();
    out.bits = business_seed();
    out.offer = business_seed();
    out.ideas = business_seed();
    out.points_balance = business_seed();
    out.points_lifetime = business_seed();
    out.points_revision = business_seed();
    out.history_cursor = business_seed();
    for (const RuntimeIdeologyPodCountryState &country : state.countries) {
        // Empty slots depend on the array length, not on state.
        if (country.handle == 0) continue;
        const uint64_t handle = country.handle;
        // `points` is the business section: balances only. `points_revision` is a
        // per-side Economy cadence counter (see the sub-hash comment below) and
        // must not be mixed in here, or this section can never be equal.
        out.points = business_mix(business_mix(out.points, handle),
            static_cast<uint64_t>(country.ideology_points_q16));
        out.points = business_mix(out.points,
            static_cast<uint64_t>(country.lifetime_points_q16));
        // Same rows, split by field, so `field=` can say which one moved.
        out.points_balance = business_mix(
            business_mix(out.points_balance, handle),
            static_cast<uint64_t>(country.ideology_points_q16));
        out.points_lifetime = business_mix(
            business_mix(out.points_lifetime, handle),
            static_cast<uint64_t>(country.lifetime_points_q16));
        // `points_revision` is deliberately NOT part of `points`.
        //
        // It is not "how many times this row accrued"; it is the external
        // Economy opinion revision the row last settled against:
        //     row->points_revision = opinion.revision;
        // That counter increments once per Economy development publish, and the
        // two sides publish on different cadences -- the worker on its own
        // clock, the main thread on cooperative slices. So the two numbers
        // differ by construction even when every business value is identical
        // (observed: reference_revision=1 vs worker_revision=3 while
        // ideology_points_q16 and lifetime_points_q16 matched exactly).
        //
        // It is kept as its own diagnostic sub-hash so a real divergence in
        // accrual cadence is still visible, but it cannot make `points` unequal.
        out.points_revision = business_mix(
            business_mix(out.points_revision, handle),
            static_cast<uint64_t>(country.points_revision));
        out.baseline = business_mix(business_mix(out.baseline, handle),
            static_cast<uint64_t>(country.baseline_ready));
        out.baseline = business_mix(business_mix(out.baseline,
            static_cast<uint64_t>(country.baseline_population)),
            static_cast<uint64_t>(country.baseline_buildings));
        // History is compared by CONTENT, normalised for ring cadence.
        //
        // `history_count` / `history_head` are positions in a fixed-size ring:
        // they count how many accruals wrote into it. Two sides that accrued a
        // different NUMBER of times (the worker settles against a higher Economy
        // revision because it publishes on its own clock) therefore carry
        // different cursors even when every stored gain is identical. Observed:
        // reference_history_count=0 vs worker_history_count=2 while both
        // `reference_history_q16` and `worker_history_q16` were all zero.
        //
        // So: mix every NON-ZERO stored gain in ring order. "No gains" then
        // hashes the same no matter how many empty notches the ring took, while
        // any real gain still differs. The raw cursors go to a separate
        // diagnostic sub-hash that cannot make `history` unequal.
        //
        // This does not weaken the section: a genuine accrual difference changes
        // `ideology_points_q16` / `lifetime_points_q16` (in `points`) and the
        // non-zero entries here.
        out.history = business_mix(out.history, handle);
        for (int64_t value : country.history_q16) {
            if (value == 0) continue;
            out.history = business_mix(out.history,
                static_cast<uint64_t>(value));
        }
        out.history_cursor = business_mix(
            business_mix(out.history_cursor, handle),
            static_cast<uint64_t>(country.history_count) << 32 |
            static_cast<uint64_t>(country.history_head));
        out.draw = business_mix(business_mix(out.draw, handle),
            country.rng_state);
        out.draw = business_mix(out.draw,
            static_cast<uint64_t>(country.draw_sequence));
        out.draw = business_mix(out.draw,
            static_cast<uint64_t>(country.unlocked_era));
        out.bits = business_mix(business_mix(out.bits, handle),
            static_cast<uint64_t>(country.known_bits.size()));
        for (uint64_t word : country.known_bits)
            out.bits = business_mix(out.bits, word);
        for (uint64_t word : country.banned_bits)
            out.bits = business_mix(out.bits, word);
        for (uint64_t word : country.gate_bits)
            out.bits = business_mix(out.bits, word);
        for (uint64_t word : country.synergy_bits)
            out.bits = business_mix(out.bits, word);
        out.offer = business_mix(business_mix(out.offer, handle),
            country.offer.generation);
        out.offer = business_mix(out.offer,
            static_cast<uint64_t>(country.offer.active) << 32 |
            static_cast<uint64_t>(country.offer.choice_count));
        for (int32_t id : country.offer.ideology_ids)
            out.offer = business_mix(out.offer,
                static_cast<uint64_t>(static_cast<int64_t>(id)));
        out.ideas = business_mix(business_mix(out.ideas, handle),
            static_cast<uint64_t>(country.ideas.size()));
        for (const RuntimeIdeologyPodIdeaState &idea : country.ideas) {
            out.ideas = business_mix(out.ideas,
                static_cast<uint64_t>(idea.understanding_q16));
            out.ideas = business_mix(out.ideas,
                static_cast<uint64_t>(static_cast<int64_t>(idea.level)) << 32 |
                static_cast<uint64_t>(idea.generation));
            out.ideas = business_mix(out.ideas, idea.entered_levels);
            out.ideas = business_mix(out.ideas,
                static_cast<uint64_t>(static_cast<int32_t>(idea.location)));
            out.ideas = business_mix(out.ideas,
                static_cast<uint64_t>(idea.slot_index));
        }
    }
}

uint64_t ideology_business_hash(const RuntimeIdeologyPodSnapshot &state) {
    IdeologyBusinessSections sections;
    ideology_business_sections(state, sections);
    uint64_t hash = business_mix(business_seed(), state.committed_day);
    hash = business_mix(hash, sections.points);
    hash = business_mix(hash, sections.baseline);
    hash = business_mix(hash, sections.history);
    hash = business_mix(hash, sections.draw);
    hash = business_mix(hash, sections.bits);
    hash = business_mix(hash, sections.offer);
    hash = business_mix(hash, sections.ideas);
    return hash;
}

} // namespace pk

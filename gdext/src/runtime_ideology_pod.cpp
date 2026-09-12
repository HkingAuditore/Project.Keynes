#include "runtime_ideology_pod.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <tuple>
#include <type_traits>

namespace pk {
namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;
constexpr uint32_t SAVE_MAGIC = 0x31504449u; // IDP1
constexpr uint32_t SAVE_END = 0x21444e45u;
constexpr uint32_t MAX_SAVE_BYTES = 64u * 1024u * 1024u;
constexpr uint8_t ACQUIRE_DISCOVER = 1u;
constexpr uint8_t ACQUIRE_DRAW = 2u;
constexpr uint16_t EFFECT_TRANSITION_OPCODE = 1u;
constexpr int64_t Q16_ONE = 65536;

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
    hash = hash_value(hash, catalog.class_hash);
    hash = hash_value(hash, catalog.class_count);
    hash = hash_value(hash, catalog.technology_count);
    hash = hash_value(hash, catalog.research_signal_count);
    hash = hash_value(hash, catalog.gate_count);
    hash = hash_value(hash, catalog.ideology_capacity);
    hash = hash_value(hash, catalog.spirit_capacity);
    hash = hash_value(hash, catalog.offer_cost_q16);
    hash = hash_value(hash, catalog.starting_points_q16);
    hash = hash_value(hash, catalog.owner_influence_weight);
    hash = hash_value(hash, catalog.funds_per_influence);
    hash = hash_value(hash, catalog.max_commands_per_slice);
    hash = hash_value(hash, catalog.max_transition_commands);
    hash = hash_value(hash, catalog.max_transition_polls_per_slice);
    hash = hash_value(hash, catalog.max_active_visits_per_slice);
    for (const auto &d : catalog.definitions) {
        hash = hash_value(hash, d.acquisition); hash = hash_value(hash, d.rarity_weight);
        hash = hash_value(hash, d.ideology_cost); hash = hash_value(hash, d.spirit_cost);
        hash = hash_value(hash, d.min_spirit_level); hash = hash_value(hash, d.level_begin);
        hash = hash_value(hash, d.level_count); hash = hash_value(hash, d.technology_begin);
        hash = hash_value(hash, d.technology_count); hash = hash_value(hash, d.signal_begin);
        hash = hash_value(hash, d.signal_count); hash = hash_value(hash, d.gate_begin);
        hash = hash_value(hash, d.gate_count); hash = hash_value(hash, d.stance_begin);
        hash = hash_value(hash, d.stance_count);
        for (int32_t value : d.support_threshold_q16) hash = hash_value(hash, value);
        hash = hash_value(hash, d.exclusion_group_id);
    }
    for (const auto &level : catalog.levels) {
        hash = hash_value(hash, level.threshold_q16);
        hash = hash_value(hash, level.daily_understanding_q16);
    }
    hash = hash_vector(hash, catalog.technology_requirements);
    hash = hash_vector(hash, catalog.signal_requirements);
    hash = hash_vector(hash, catalog.gate_requirements);
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
    }
    hash = hash_vector(hash, catalog.ideology_synergy_offsets);
    hash = hash_vector(hash, catalog.ideology_synergy_ids);
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
        hash = hash_value(hash, country.draw_sequence); hash = hash_value(hash, country.ideology_slots_used);
        hash = hash_value(hash, country.spirit_slots_used); hash = hash_value(hash, country.opinion_revision);
        hash = hash_value(hash, country.offer.generation); hash = hash_value(hash, country.offer.active);
        for (int32_t id : country.offer.ideology_ids) hash = hash_value(hash, id);
        hash = hash_vector(hash, country.known_bits); hash = hash_vector(hash, country.gate_bits);
        hash = hash_vector(hash, country.synergy_bits);
        hash = hash_vector(hash, country.active_idea_ids);
        hash = hash_value(hash, static_cast<uint64_t>(country.ideas.size()));
        for (const auto &idea : country.ideas) {
            hash = hash_value(hash, idea.understanding_q16); hash = hash_value(hash, idea.level);
            hash = hash_value(hash, idea.entered_levels); hash = hash_value(hash, idea.generation);
            hash = hash_value(hash, idea.location);
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
        hash = hash_value(hash, transition.desired_location); hash = hash_value(hash, transition.intent_emitted);
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
    if (catalog.definitions.empty() || catalog.definitions.size() > RUNTIME_IDEOLOGY_POD_MAX_IDEAS ||
        catalog.class_count == 0 || catalog.class_hash == 0 || catalog.country_catalog_hash == 0 ||
        catalog.ideology_capacity < 0 || catalog.spirit_capacity < 0 ||
        catalog.offer_cost_q16 < 0 || catalog.starting_points_q16 < 0 ||
        catalog.owner_influence_weight < 0 || catalog.funds_per_influence <= 0 ||
        catalog.max_commands_per_slice == 0 || catalog.max_transition_commands == 0 ||
        catalog.max_transition_polls_per_slice == 0 || catalog.max_active_visits_per_slice == 0) {
        error = "ideology_pod_catalog_shape_invalid"; return false;
    }
    for (const auto &d : catalog.definitions) {
        if (d.rarity_weight <= 0 || d.ideology_cost < 0 || d.spirit_cost < 0 ||
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
    for (const auto &stance : catalog.class_stances)
        if (stance.class_index < 0 || stance.class_index >= static_cast<int32_t>(catalog.class_count)) { error = "ideology_pod_class_stance_invalid"; return false; }
    for (const auto &requirement : catalog.synergy_requirements)
        if (requirement.ideology_id < 0 || requirement.ideology_id >= static_cast<int32_t>(catalog.definitions.size()) || requirement.minimum_level < 0 || requirement.location_mask == 0) { error = "ideology_pod_synergy_requirement_invalid"; return false; }
    for (const auto &synergy : catalog.synergies)
        if (synergy.requirement_begin > catalog.synergy_requirements.size() || synergy.requirement_count > catalog.synergy_requirements.size() - synergy.requirement_begin) { error = "ideology_pod_synergy_invalid"; return false; }
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
        out.rng_state = out.handle ^ (_catalog.catalog_hash + 0x9e3779b97f4a7c15ull);
        out.opinion_revision = opinion.revision;
        out.known_bits.assign(idea_words, 0);
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
    if (opcode < 1 || opcode > 9 || command.request_id == 0 ||
        command.producer_id == 0 || command.country_handle == 0 ||
        command.effective_day < 0 || command.requested_day < 0) {
        error = "ideology_command_invalid"; return false;
    }
    if ((command.opcode == RuntimeIdeologyPodOpcode::DISCOVER ||
         command.opcode == RuntimeIdeologyPodOpcode::EQUIP ||
         command.opcode == RuntimeIdeologyPodOpcode::UNEQUIP ||
         command.opcode == RuntimeIdeologyPodOpcode::PROMOTE ||
         command.opcode == RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING) &&
        (command.ideology_id < 0 || command.ideology_id >= static_cast<int32_t>(_catalog.definitions.size()))) {
        error = "ideology_id_invalid"; return false;
    }
    if ((command.opcode == RuntimeIdeologyPodOpcode::GRANT_POINTS ||
         command.opcode == RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING) && command.value_q16 < 0) {
        error = "ideology_value_negative"; return false;
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
        bool active = true;
        for (uint32_t row = 0; row < synergy.requirement_count; ++row) {
            const auto &requirement = _catalog.synergy_requirements[synergy.requirement_begin + row];
            const auto &idea = country.ideas[static_cast<size_t>(requirement.ideology_id)];
            const int32_t level = requirement.ideology_id == override_ideology ? override_level : idea.level;
            const RuntimeIdeologyPodLocation location = requirement.ideology_id == override_ideology ? override_location : idea.location;
            if (level < requirement.minimum_level ||
                (requirement.location_mask & (1u << static_cast<uint8_t>(location))) == 0) {
                active = false; break;
            }
        }
        bit_set(out, static_cast<int32_t>(synergy_id), active);
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
        RuntimeIdeologyPodTransition &transition,
        RuntimeIdeologyPodPlan &plan) const {
    if (transition.intent_emitted != 0) return;
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
        uint64_t entered_levels, const RuntimeIdeologyPodCommand *command,
        int64_t day, RuntimeIdeologyPodPlan &plan, std::string &error) const {
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
    transition.desired_entered_levels = entered_levels;
    compute_synergies(state.countries[slot], ideology_id, desired_level,
                      desired_location, transition.desired_synergy_bits);
    transition.intent_id = transition_identity(transition,
        command != nullptr ? command->opcode : RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING);
    state.pending_transitions.push_back(std::move(transition));
    emit_transition(state.pending_transitions.back(), plan);
    return true;
}

bool RuntimeIdeologyPodAuthority::apply_ack(
        RuntimeIdeologyPodSnapshot &state, const RuntimeDomainAck &ack,
        int64_t day, std::string &error) const {
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
            idea.entered_levels |= transition.desired_entered_levels;
            ++idea.generation;
            if (idea.location == RuntimeIdeologyPodLocation::IDEOLOGY) country.ideology_slots_used += definition.ideology_cost;
            if (idea.location == RuntimeIdeologyPodLocation::NATIONAL_SPIRIT) country.spirit_slots_used += definition.spirit_cost;
            country.synergy_bits = transition.desired_synergy_bits;
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
            }
        }
        state.pending_transitions.erase(state.pending_transitions.begin() + static_cast<std::ptrdiff_t>(i));
        if (state.pending_cursor > i) --state.pending_cursor;
        return true;
    }
    return true;
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
        case RuntimeIdeologyPodOpcode::OPEN_OFFER: {
            if (row.offer.active != 0 || row.ideology_points_q16 < _catalog.offer_cost_q16) { error = "ideology_offer_unavailable"; return false; }
            std::vector<int32_t> pool;
            for (int32_t id = 0; id < static_cast<int32_t>(_catalog.definitions.size()); ++id)
                if (!bit_get(row.known_bits, id) && (_catalog.definitions[id].acquisition & ACQUIRE_DRAW) != 0 && requirements_met(state, country, slot, id)) pool.push_back(id);
            if (pool.size() < 3) { error = "ideology_offer_pool_insufficient"; return false; }
            for (int32_t draw = 0; draw < 3; ++draw) {
                int64_t total = 0;
                for (int32_t id : pool) total += _catalog.definitions[id].rarity_weight;
                uint64_t roll = next_random(row.rng_state) % static_cast<uint64_t>(total);
                size_t selected = 0;
                for (; selected + 1 < pool.size(); ++selected) {
                    const uint64_t weight = static_cast<uint64_t>(_catalog.definitions[pool[selected]].rarity_weight);
                    if (roll < weight) break;
                    roll -= weight;
                }
                row.offer.ideology_ids[draw] = pool[selected];
                pool.erase(pool.begin() + static_cast<std::ptrdiff_t>(selected));
            }
            row.ideology_points_q16 -= _catalog.offer_cost_q16;
            row.offer.active = 1; row.offer.generation = std::max<uint32_t>(1, row.offer.generation + 1u);
            ++row.draw_sequence; return true;
        }
        case RuntimeIdeologyPodOpcode::CHOOSE_OFFER:
            if (row.offer.active == 0 || row.offer.generation != command.offer_generation || command.choice_index < 0 || command.choice_index >= 3) { error = "ideology_offer_generation_stale"; return false; }
            if (row.offer.ideology_ids[command.choice_index] < 0) { error = "ideology_offer_choice_invalid"; return false; }
            bit_set(row.known_bits, row.offer.ideology_ids[command.choice_index], true);
            row.offer.active = 0; row.offer.ideology_ids = {{-1, -1, -1}}; return true;
        case RuntimeIdeologyPodOpcode::EQUIP: {
            if (!bit_get(row.known_bits, idea_id)) { error = "ideology_unknown"; return false; }
            auto &idea = row.ideas[idea_id];
            if (idea.location == RuntimeIdeologyPodLocation::NATIONAL_SPIRIT) { error = "ideology_is_national_spirit"; return false; }
            if (idea.location == RuntimeIdeologyPodLocation::IDEOLOGY) return true;
            const auto &definition = _catalog.definitions[idea_id];
            for (int32_t other = 0; other < static_cast<int32_t>(row.ideas.size()); ++other)
                if (other != idea_id && row.ideas[other].location != RuntimeIdeologyPodLocation::INACTIVE && definition.exclusion_group_id >= 0 && _catalog.definitions[other].exclusion_group_id == definition.exclusion_group_id) { error = "ideology_exclusion_group_conflict"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 0)) { error = "ideology_support_threshold_not_met"; return false; }
            if (row.ideology_slots_used + definition.ideology_cost > _catalog.ideology_capacity) { error = "ideology_slot_capacity_exceeded"; return false; }
            const int32_t level = std::max(idea.level, unlocked_level(idea, idea_id));
            const uint64_t entered = level < 0 ? 0 : ((level == 63 ? ~0ull : ((1ull << (level + 1)) - 1ull)) & ~idea.entered_levels);
            return begin_transition(state, slot, idea_id, level, RuntimeIdeologyPodLocation::IDEOLOGY, entered, &command, command.effective_day, plan, error);
        }
        case RuntimeIdeologyPodOpcode::UNEQUIP: {
            auto &idea = row.ideas[idea_id];
            if (idea.location != RuntimeIdeologyPodLocation::IDEOLOGY) { error = "ideology_not_equipped"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 1)) { error = "ideology_support_threshold_not_met"; return false; }
            return begin_transition(state, slot, idea_id, idea.level, RuntimeIdeologyPodLocation::INACTIVE, 0, &command, command.effective_day, plan, error);
        }
        case RuntimeIdeologyPodOpcode::PROMOTE: {
            auto &idea = row.ideas[idea_id];
            const auto &definition = _catalog.definitions[idea_id];
            if (idea.location != RuntimeIdeologyPodLocation::IDEOLOGY) { error = "ideology_promotion_requires_equipped"; return false; }
            if (idea.level < definition.min_spirit_level) { error = "ideology_national_spirit_level_insufficient"; return false; }
            if (row.spirit_slots_used + definition.spirit_cost > _catalog.spirit_capacity) { error = "national_spirit_slot_capacity_exceeded"; return false; }
            if (!support_allows(state, opinion, slot, idea_id, 2)) { error = "ideology_support_threshold_not_met"; return false; }
            return begin_transition(state, slot, idea_id, idea.level, RuntimeIdeologyPodLocation::NATIONAL_SPIRIT, 0, &command, command.effective_day, plan, error);
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
                return begin_transition(state, slot, idea_id, unlocked, idea.location, entered, &command, command.effective_day, plan, error);
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
        if (day <= state.committed_day) { error = "ideology_day_not_monotonic"; return false; }
        state.round_day = day;
        state.phase = RuntimeIdeologyPodPhase::PENDING_TRANSITIONS;
        state.pending_cursor = state.command_cursor = 0;
        state.active_country_cursor = state.active_idea_cursor = 0;
        state.input_generation = country.generation;
    } else if (state.round_day != day || state.input_generation != country.generation) {
        error = "ideology_same_day_continuation_input_changed"; return false;
    } else if (state.opinion_revision != opinion.revision) {
        error = "ideology_same_day_continuation_opinion_changed"; return false;
    }
    state.opinion_revision = opinion.revision;
    if (state.phase == RuntimeIdeologyPodPhase::PENDING_TRANSITIONS) {
        for (const auto &ack : acks) if (!apply_ack(state, ack, day, error)) return false;
        uint32_t visits = 0;
        while (state.pending_cursor < state.pending_transitions.size() &&
               visits < _catalog.max_transition_polls_per_slice) {
            emit_transition(state.pending_transitions[state.pending_cursor], plan);
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
            if (!applied) { receipt.status = RuntimeIdeologyPodReceiptStatus::REJECTED; receipt.reason_code = 1; }
            else if (state.pending_transitions.size() > pending_before) { receipt.status = RuntimeIdeologyPodReceiptStatus::PENDING; receipt.settled_day = -1; }
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
            if (idea.level >= 0 && idea.level < static_cast<int32_t>(definition.level_count))
                idea.understanding_q16 = add_sat(idea.understanding_q16,
                    _catalog.levels[definition.level_begin + static_cast<uint32_t>(idea.level)].daily_understanding_q16);
            bool pending = false;
            for (const auto &transition : state.pending_transitions)
                if (transition.country_slot == state.active_country_cursor && transition.ideology_id == idea_id) { pending = true; break; }
            const int32_t unlocked = unlocked_level(idea, idea_id);
            if (!pending && unlocked > idea.level) {
                const uint64_t entered = unlocked == 63 ? ~idea.entered_levels : (((1ull << (unlocked + 1)) - 1ull) & ~idea.entered_levels);
                if (!begin_transition(state, state.active_country_cursor, idea_id, unlocked,
                                      idea.location, entered, nullptr, day, plan, error)) return false;
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
    return true;
}

void RuntimeIdeologyPodAuthority::serialize(std::vector<uint8_t> &out) const {
    out.clear(); out.reserve(4096);
    append_le<uint32_t>(out, SAVE_MAGIC); append_le<uint32_t>(out, RUNTIME_IDEOLOGY_POD_ABI_VERSION);
    append_le<uint64_t>(out, _catalog.catalog_hash); append_le<uint64_t>(out, _current.state_hash);
    append_le<uint64_t>(out, _current.input_generation); append_le<uint64_t>(out, _current.opinion_revision);
    append_le<uint64_t>(out, _current.generation); append_le<int64_t>(out, _current.committed_day);
    append_le<int64_t>(out, _current.round_day); append_le(out, _current.phase);
    append_le<uint32_t>(out, _current.pending_cursor); append_le<uint32_t>(out, _current.command_cursor);
    append_le<uint32_t>(out, _current.active_country_cursor); append_le<uint32_t>(out, _current.active_idea_cursor);
    append_le<uint64_t>(out, _current.next_submit_order);
    append_le<uint32_t>(out, static_cast<uint32_t>(_current.producer_high_watermarks.size()));
    for (const auto &watermark : _current.producer_high_watermarks) {
        append_le<uint32_t>(out, watermark.producer_id);
        append_le<uint64_t>(out, watermark.sequence);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(_current.countries.size()));
    for (const auto &country : _current.countries) {
        append_le<uint64_t>(out, country.handle); append_le<uint32_t>(out, country.generation);
        append_le<int64_t>(out, country.ideology_points_q16); append_le<uint64_t>(out, country.rng_state);
        append_le<uint64_t>(out, country.draw_sequence); append_le<int32_t>(out, country.ideology_slots_used);
        append_le<int32_t>(out, country.spirit_slots_used); append_le<uint64_t>(out, country.opinion_revision);
        append_le<uint32_t>(out, country.offer.generation); for (int32_t id : country.offer.ideology_ids) append_le<int32_t>(out, id);
        append_le<uint8_t>(out, country.offer.active); append_vector(out, country.known_bits);
        append_vector(out, country.gate_bits); append_vector(out, country.synergy_bits);
        append_le<uint32_t>(out, static_cast<uint32_t>(country.ideas.size()));
        for (const auto &idea : country.ideas) {
            append_le<int64_t>(out, idea.understanding_q16); append_le<int32_t>(out, idea.level);
            append_le<uint64_t>(out, idea.entered_levels); append_le<uint32_t>(out, idea.generation);
            append_le(out, idea.location);
        }
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(_current.commands.size()));
    for (const auto &command : _current.commands) {
        append_le<uint64_t>(out, command.request_id); append_le<int32_t>(out, command.source_priority);
        append_le<uint32_t>(out, command.producer_id); append_le<uint64_t>(out, command.sequence);
        append_le<uint64_t>(out, command.submit_order); append_le<int64_t>(out, command.requested_day);
        append_le<int64_t>(out, command.effective_day); append_le(out, command.opcode);
        append_le<uint64_t>(out, command.country_handle); append_le<int32_t>(out, command.ideology_id);
        append_le<int64_t>(out, command.value_q16); append_le<uint32_t>(out, command.offer_generation);
        append_le<int32_t>(out, command.choice_index); append_le<int32_t>(out, command.gate_id);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(_current.pending_transitions.size()));
    for (const auto &transition : _current.pending_transitions) {
        append_le<uint64_t>(out, transition.intent_id); append_le<uint64_t>(out, transition.request_id);
        append_le<uint32_t>(out, transition.producer_id); append_le<uint64_t>(out, transition.sequence);
        append_le<int64_t>(out, transition.effective_day); append_le<uint32_t>(out, transition.country_slot);
        append_le<uint32_t>(out, transition.country_generation); append_le<int32_t>(out, transition.ideology_id);
        append_le<int32_t>(out, transition.desired_level); append_le<uint64_t>(out, transition.desired_entered_levels);
        append_le(out, transition.desired_location); append_le<uint8_t>(out, transition.intent_emitted);
        append_vector(out, transition.desired_synergy_bits);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(_current.receipts.size()));
    for (const auto &receipt : _current.receipts) {
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
            !read_le(data,end,cursor,country.draw_sequence) || !read_le(data,end,cursor,country.ideology_slots_used) ||
            !read_le(data,end,cursor,country.spirit_slots_used) || !read_le(data,end,cursor,country.opinion_revision) ||
            !read_le(data,end,cursor,country.offer.generation) || !read_le(data,end,cursor,country.offer.ideology_ids[0]) ||
            !read_le(data,end,cursor,country.offer.ideology_ids[1]) || !read_le(data,end,cursor,country.offer.ideology_ids[2]) ||
            !read_le(data,end,cursor,country.offer.active) ||
            !read_vector(data,end,cursor,country.known_bits,bit_limit) ||
            !read_vector(data,end,cursor,country.gate_bits,static_cast<uint32_t>((_catalog.gate_count + 63u) / 64u)) ||
            !read_vector(data,end,cursor,country.synergy_bits,bit_limit) ||
            !read_le(data,end,cursor,count) || count != _catalog.definitions.size()) { error = "ideology_pod_country_truncated"; return false; }
        country.ideas.resize(count);
        for (auto &idea : country.ideas)
            if (!read_le(data,end,cursor,idea.understanding_q16) || !read_le(data,end,cursor,idea.level) ||
                !read_le(data,end,cursor,idea.entered_levels) || !read_le(data,end,cursor,idea.generation) ||
                !read_le(data,end,cursor,idea.location) || idea.level < -1 || idea.level >= 64) { error = "ideology_pod_idea_truncated"; return false; }
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
            !read_le(data,end,cursor,transition.desired_location) || !read_le(data,end,cursor,transition.intent_emitted) ||
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
    return true;
}

bool RuntimeIdeologyPodAuthority::self_test(std::string &error) {
    error.clear();
    RuntimeIdeologyPodCatalog catalog;
    catalog.country_catalog_hash = 77; catalog.class_hash = 88; catalog.class_count = 1;
    catalog.technology_count = 1; catalog.research_signal_count = 1; catalog.gate_count = 1;
    catalog.ideology_capacity = 4; catalog.spirit_capacity = 2; catalog.starting_points_q16 = Q16_ONE;
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
    std::vector<uint8_t> bytes; authority.serialize(bytes);
    RuntimeIdeologyPodAuthority restored;
    if (!restored.configure(catalog, error) || !restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().state_hash != authority.snapshot().state_hash) { error = "ideology_self_test_save_roundtrip_failed"; return false; }
    const uint64_t before = restored.snapshot().state_hash; bytes.back() ^= 0x40u;
    if (restored.restore(bytes.data(), bytes.size(), error) || restored.snapshot().state_hash != before) { error = "ideology_self_test_transactional_restore_failed"; return false; }
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

} // namespace pk

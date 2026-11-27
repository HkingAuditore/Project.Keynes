#include "runtime_modifier_pod.h"
#include "simulation_math.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <type_traits>
#include <unordered_map>

namespace pk {

namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;
constexpr uint32_t MAX_SERIALIZED_BYTES = 64u * 1024u * 1024u;
constexpr int32_t Q16_ONE = 65536;
constexpr int32_t MAX_MAGNITUDE_Q16 = Q16_ONE * 4;
constexpr uint16_t COMMAND_APPLY = 1;
constexpr uint16_t COMMAND_REMOVE = 2;
constexpr uint16_t COMMAND_REFRESH = 3;
constexpr uint16_t COMMAND_SET_STACKS = 4;
constexpr uint16_t COMMAND_SET_MAGNITUDE = 5;
constexpr int32_t POLICY_INDEPENDENT = 0;
constexpr int32_t POLICY_UNIQUE_SOURCE = 1;
constexpr int32_t POLICY_STACK_REFRESH = 2;

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    static_assert(std::is_integral_v<T>);
    using U = std::make_unsigned_t<T>;
    U bits = static_cast<U>(value);
    for (size_t i = 0; i < sizeof(T); ++i) {
        out.push_back(static_cast<uint8_t>(bits & static_cast<U>(0xffu)));
        bits >>= 8u;
    }
}

void append_f64(std::vector<uint8_t> &out, double value) {
    uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    append_le(out, bits);
}

template <typename T>
bool read_le(const uint8_t *data, size_t size, size_t &cursor, T &value) {
    if (data == nullptr || cursor > size || size - cursor < sizeof(T)) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(T); ++i)
        bits |= static_cast<U>(data[cursor + i]) << (i * 8u);
    cursor += sizeof(T);
    value = static_cast<T>(bits);
    return true;
}

bool read_f64(const uint8_t *data, size_t size, size_t &cursor, double &value) {
    uint64_t bits = 0;
    if (!read_le(data, size, cursor, bits)) return false;
    std::memcpy(&value, &bits, sizeof(value));
    return std::isfinite(value);
}

uint64_t hash_bytes(uint64_t hash, const void *data, size_t size) {
    const auto *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= static_cast<uint64_t>(bytes[i]);
        hash *= FNV_PRIME;
    }
    return hash;
}

template <typename T>
uint64_t hash_value(uint64_t hash, const T &value) {
    return hash_bytes(hash, &value, sizeof(value));
}

void clear_error(std::string &error) { error.clear(); }

} // namespace

RuntimeModifierPodAuthority::RuntimeModifierPodAuthority() {
    reset();
}

void RuntimeModifierPodAuthority::reset(size_t entry_capacity) {
    _current = State{};
    _next = State{};
    for (DomainState &domain : _current.domains) {
        domain.entries.reserve(entry_capacity);
        domain.handle_generations.reserve(entry_capacity);
        domain.free_indices.reserve(entry_capacity);
        domain.expiry_queue.reserve(entry_capacity);
    }
    for (DomainState &domain : _next.domains) {
        domain.entries.reserve(entry_capacity);
        domain.handle_generations.reserve(entry_capacity);
        domain.free_indices.reserve(entry_capacity);
        domain.expiry_queue.reserve(entry_capacity);
    }
    _snapshot = RuntimeModifierPodSnapshot{};
    _planned_snapshot = RuntimeModifierPodSnapshot{};
    _report = RuntimeModifierPodReport{};
    _configured = false;
    _plan_ready = false; _view_cursor = {};
}

uint64_t RuntimeModifierPodAuthority::hash_mix(uint64_t value, uint64_t input) noexcept {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6u) + (value >> 2u);
    return value * FNV_PRIME;
}

uint64_t RuntimeModifierPodAuthority::hash_bytes(uint64_t value,
                                                  const void *data,
                                                  size_t size) noexcept {
    return ::pk::hash_bytes(value, data, size);
}

bool RuntimeModifierPodAuthority::configure(const RuntimeModifierPodCatalog &catalog,
                                            std::string &error) {
    clear_error(error);
    if (catalog.abi_version != RUNTIME_MODIFIER_POD_ABI_VERSION) {
        error = "modifier_pod_abi_incompatible";
        return false;
    }
    if (catalog.stats.empty() || catalog.definitions.empty()) {
        error = "modifier_pod_catalog_empty";
        return false;
    }
    if (catalog.terms.empty()) {
        error = "modifier_pod_catalog_terms_empty";
        return false;
    }
    for (const RuntimeModifierPodStat &stat : catalog.stats) {
        if (stat.domain < 0 || stat.domain >= 4 || !std::isfinite(stat.min_value) ||
            !std::isfinite(stat.max_value) || stat.min_value > stat.max_value ||
            stat.aggregate_policy < 0 || stat.aggregate_policy > 2 || stat.source_cap < 0) {
            error = "modifier_pod_stat_invalid";
            return false;
        }
    }
    uint64_t expected_hash = FNV_OFFSET;
    for (const RuntimeModifierPodStat &stat : catalog.stats) {
        expected_hash = hash_value(expected_hash, stat.domain);
        expected_hash = hash_value(expected_hash, stat.min_value);
        expected_hash = hash_value(expected_hash, stat.max_value);
        expected_hash = hash_value(expected_hash, stat.persistable);
        expected_hash = hash_value(expected_hash, stat.aggregate_policy);
        expected_hash = hash_value(expected_hash, stat.source_cap);
    }
    for (const RuntimeModifierPodDefinition &definition : catalog.definitions) {
        if (definition.version <= 0 || definition.domain < 0 || definition.domain >= 4 ||
            definition.policy < POLICY_INDEPENDENT || definition.policy > POLICY_STACK_REFRESH ||
            definition.max_stacks <= 0 ||
            (definition.default_duration != -1 && definition.default_duration <= 0) ||
            definition.term_begin > catalog.terms.size() ||
            definition.term_count > catalog.terms.size() - definition.term_begin) {
            error = "modifier_pod_definition_invalid";
            return false;
        }
        expected_hash = hash_value(expected_hash, definition.version);
        expected_hash = hash_value(expected_hash, definition.domain);
        expected_hash = hash_value(expected_hash, definition.policy);
        expected_hash = hash_value(expected_hash, definition.max_stacks);
        expected_hash = hash_value(expected_hash, definition.default_duration);
        expected_hash = hash_value(expected_hash, definition.term_begin);
        expected_hash = hash_value(expected_hash, definition.term_count);
    }
    for (const RuntimeModifierPodTerm &term : catalog.terms) {
        if (term.stat_id < 0 || term.stat_id >= static_cast<int32_t>(catalog.stats.size()) ||
            !std::isfinite(term.add) || !std::isfinite(term.factor)) {
            error = "modifier_pod_term_invalid";
            return false;
        }
        expected_hash = hash_value(expected_hash, term.stat_id);
        expected_hash = hash_value(expected_hash, term.add);
        expected_hash = hash_value(expected_hash, term.factor);
    }
    for (const RuntimeModifierPodDefinition &definition : catalog.definitions) {
        for (uint32_t i = 0; i < definition.term_count; ++i) {
            const RuntimeModifierPodTerm &term =
                catalog.terms[definition.term_begin + i];
            if (catalog.stats[static_cast<size_t>(term.stat_id)].domain != definition.domain) {
                error = "modifier_pod_term_domain_mismatch";
                return false;
            }
        }
    }
    if (catalog.catalog_hash != 0 && catalog.catalog_hash != expected_hash) {
        error = "modifier_pod_catalog_hash_invalid";
        return false;
    }
    _catalog = catalog;
    _catalog.catalog_hash = expected_hash;
    _configured = true;
    _plan_ready = false;
    _current = State{};
    _current.state_hash = state_hash(_current);
    _next = State{};
    _next.state_hash = _current.state_hash;
    for (DomainState &domain : _current.domains) {
        domain.entries.reserve(256);
        domain.handle_generations.reserve(256);
        domain.free_indices.reserve(256);
        domain.expiry_queue.reserve(256);
    }
    for (DomainState &domain : _next.domains) {
        domain.entries.reserve(256);
        domain.handle_generations.reserve(256);
        domain.free_indices.reserve(256);
        domain.expiry_queue.reserve(256);
    }
    _snapshot = RuntimeModifierPodSnapshot{};
    _snapshot.abi_version = RUNTIME_MODIFIER_POD_ABI_VERSION;
    _snapshot.catalog_hash = expected_hash;
    _current.state_hash = state_hash(_current);
    _next = _current;
    _snapshot.state_hash = _current.state_hash;
    _report = RuntimeModifierPodReport{};
    return true;
}

uint64_t RuntimeModifierPodAuthority::scope_id(
        const RuntimeModifierPodCommand &command) noexcept {
    if (command.scope == 0) return 0;
    return command.scope == 1 ? command.group_handle : command.entity_handle;
}

void RuntimeModifierPodAuthority::rebuild_expiry_queue(DomainState &domain) const {
    domain.expiry_queue.clear();
    for (uint32_t index = 0; index < domain.entries.size(); ++index) {
        const RuntimeModifierPodEntry &entry = domain.entries[index];
        if (entry.modifier_handle != 0 && entry.expires_day >= 0)
            domain.expiry_queue.push_back(index);
    }
    std::sort(domain.expiry_queue.begin(), domain.expiry_queue.end(),
        [&domain](uint32_t lhs, uint32_t rhs) {
            const auto &a = domain.entries[lhs];
            const auto &b = domain.entries[rhs];
            if (a.expires_day != b.expires_day) return a.expires_day < b.expires_day;
            return a.modifier_handle < b.modifier_handle;
        });
}

uint64_t RuntimeModifierPodAuthority::scope_id(
        const RuntimeModifierPodEntry &entry) noexcept {
    if (entry.scope == 0) return 0;
    return entry.scope == 1 ? entry.group_handle : entry.entity_handle;
}

bool RuntimeModifierPodAuthority::command_less(
        const RuntimeModifierPodCommand &a,
        const RuntimeModifierPodCommand &b) noexcept {
    if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
    if (a.producer_id != b.producer_id) return a.producer_id < b.producer_id;
    if (a.sequence != b.sequence) return a.sequence < b.sequence;
    return a.request_id < b.request_id;
}

bool RuntimeModifierPodAuthority::validate_command(
        const RuntimeModifierPodCommand &command, std::string &error) const {
    if (!_configured) { error = "modifier_pod_not_configured"; return false; }
    if (command.opcode < COMMAND_APPLY || command.opcode > COMMAND_SET_MAGNITUDE) {
        error = "modifier_pod_opcode_invalid";
        return false;
    }
    if (command.domain >= 4 || command.scope < 0 || command.scope > 2) {
        error = "modifier_pod_domain_or_scope_invalid";
        return false;
    }
    if (command.opcode == COMMAND_APPLY) {
        if (command.definition_id < 0 ||
            command.definition_id >= static_cast<int32_t>(_catalog.definitions.size())) {
            error = "modifier_pod_definition_unknown";
            return false;
        }
        const auto &definition = _catalog.definitions[static_cast<size_t>(command.definition_id)];
        if (definition.domain != static_cast<int32_t>(command.domain)) {
            error = "modifier_pod_definition_domain_mismatch";
            return false;
        }
        if (command.magnitude_q16 < 0 || command.magnitude_q16 > MAX_MAGNITUDE_Q16) {
            error = "modifier_pod_magnitude_invalid";
            return false;
        }
        if (command.duration_days != -1 && command.duration_days != -2 &&
            command.duration_days <= 0) {
            error = "modifier_pod_duration_invalid";
            return false;
        }
        if (command.stacks <= 0 || command.stacks > definition.max_stacks) {
            error = "modifier_pod_stack_invalid";
            return false;
        }
    } else if (command.opcode == COMMAND_SET_STACKS && command.stacks <= 0) {
        error = "modifier_pod_stack_invalid";
        return false;
    } else if (command.opcode == COMMAND_SET_MAGNITUDE &&
               (command.magnitude_q16 < 0 || command.magnitude_q16 > MAX_MAGNITUDE_Q16)) {
        error = "modifier_pod_magnitude_invalid";
        return false;
    }
    if (command.opcode != COMMAND_APPLY && command.opcode != COMMAND_REMOVE &&
        command.modifier_handle == 0) {
        error = "modifier_pod_handle_missing";
        return false;
    }
    if (command.opcode == COMMAND_REMOVE && command.modifier_handle == 0 &&
        (command.definition_id < 0 ||
         command.definition_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
         _catalog.definitions[static_cast<size_t>(command.definition_id)].policy ==
             POLICY_INDEPENDENT)) {
        error = "modifier_pod_unique_remove_invalid";
        return false;
    }
    if (command.effective_day < 0) {
        error = "modifier_pod_day_invalid";
        return false;
    }
    return true;
}

bool RuntimeModifierPodAuthority::resolve_entry(const DomainState &domain,
                                                uint64_t handle,
                                                size_t &index) const {
    if (handle == 0) return false;
    const uint32_t slot = static_cast<uint32_t>(handle & 0xffffffffull);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32u);
    if (generation == 0 || slot >= domain.entries.size() ||
        slot >= domain.handle_generations.size() ||
        domain.entries[slot].modifier_handle == 0 ||
        domain.handle_generations[slot] != generation) return false;
    index = slot;
    return true;
}

#include "runtime_modifier_pod_active_entries.inc"
#include "runtime_modifier_pod_daily_authority.inc"
#include "runtime_modifier_pod_checkpoint.inc"
#include "runtime_modifier_pod_selftest.inc"

} // namespace pk

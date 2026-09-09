#include "runtime_modifier_pod.h"

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
    _plan_ready = false;
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
            !std::isfinite(stat.max_value) || stat.min_value > stat.max_value) {
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

bool RuntimeModifierPodAuthority::apply_command(
        State &state, const RuntimeModifierPodCommand &command, int64_t day,
        RuntimeDomainAck &ack, bool &changed, std::string &error) {
    const auto &definition = _catalog.definitions[static_cast<size_t>(command.definition_id)];
    DomainState &domain = state.domains[command.domain];
    const int32_t duration = command.duration_days == -2
        ? definition.default_duration : command.duration_days;
    if (duration != -1 && duration <= 0) { error = "modifier_pod_duration_invalid"; return false; }
    const uint64_t wanted_scope = scope_id(command);
    size_t existing = domain.entries.size();
    if (definition.policy != POLICY_INDEPENDENT) {
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            const auto &entry = domain.entries[i];
            if (entry.modifier_handle != 0 && entry.definition_id == command.definition_id &&
                entry.scope == command.scope && scope_id(entry) == wanted_scope &&
                entry.source_type == command.source_type && entry.source_id == command.source_id) {
                existing = i;
                break;
            }
        }
    }
    if (existing < domain.entries.size()) {
        auto &entry = domain.entries[existing];
        if (command.target_generation != 0 &&
            command.target_generation != entry.target_generation) {
            error = "modifier_pod_stale_generation";
            return false;
        }
        if (definition.policy == POLICY_STACK_REFRESH)
            entry.stacks = std::min(definition.max_stacks, entry.stacks + command.stacks);
        else
            entry.stacks = command.stacks;
        entry.magnitude_q16 = command.magnitude_q16;
        entry.value_q16 = command.magnitude_q16;
        entry.applied_day = day;
        entry.expires_day = duration < 0 ? -1 : day + duration;
        ++domain.version;
        changed = true;
        return true;
    }
    uint32_t slot = 0;
    if (!domain.free_indices.empty()) {
        slot = domain.free_indices.back();
        domain.free_indices.pop_back();
        if (++domain.handle_generations[slot] == 0) domain.handle_generations[slot] = 1;
    } else {
        slot = static_cast<uint32_t>(domain.entries.size());
        domain.handle_generations.push_back(1);
        domain.entries.emplace_back();
    }
    auto &entry = domain.entries[slot];
    entry = RuntimeModifierPodEntry{};
    entry.domain = command.domain;
    entry.modifier_handle = (static_cast<uint64_t>(domain.handle_generations[slot]) << 32u) | slot;
    entry.target_handle = command.entity_handle;
    entry.target_generation = command.target_generation;
    entry.definition_id = command.definition_id;
    entry.scope = command.scope;
    entry.entity_handle = command.entity_handle;
    entry.group_handle = command.group_handle;
    entry.source_type = command.source_type;
    entry.source_id = command.source_id;
    entry.stacks = command.stacks;
    entry.magnitude_q16 = command.magnitude_q16;
    entry.value_q16 = command.magnitude_q16;
    entry.applied_day = day;
    entry.expires_day = duration < 0 ? -1 : day + duration;
    ++domain.version;
    changed = true;
    return true;
}

bool RuntimeModifierPodAuthority::remove_entry(
        State &state, const RuntimeModifierPodCommand &command, int64_t day,
        RuntimeDomainAck &ack, bool &changed, std::string &error) {
    DomainState &domain = state.domains[command.domain];
    size_t index = 0;
    if (command.modifier_handle != 0) {
        if (!resolve_entry(domain, command.modifier_handle, index)) {
            error = "modifier_pod_stale_generation";
            return false;
        }
    } else {
        if (command.definition_id < 0 ||
            command.definition_id >= static_cast<int32_t>(_catalog.definitions.size())) {
            error = "modifier_pod_definition_unknown";
            return false;
        }
        const uint64_t wanted_scope = scope_id(command);
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            const auto &entry = domain.entries[i];
            if (entry.modifier_handle != 0 && entry.definition_id == command.definition_id &&
                entry.scope == command.scope && scope_id(entry) == wanted_scope &&
                entry.source_type == command.source_type && entry.source_id == command.source_id) {
                index = i;
                break;
            }
        }
        if (index >= domain.entries.size() || domain.entries[index].modifier_handle == 0) {
            changed = false;
            return true;
        }
    }
    auto &entry = domain.entries[index];
    if (command.target_generation != 0 &&
        command.target_generation != entry.target_generation) {
        error = "modifier_pod_stale_generation";
        return false;
    }
    entry.modifier_handle = 0;
    entry.target_handle = 0;
    domain.free_indices.push_back(static_cast<uint32_t>(index));
    ++domain.version;
    changed = true;
    (void)day;
    return true;
}

void RuntimeModifierPodAuthority::rebuild_buckets(
        const State &state, std::vector<RuntimeModifierPodBucket> &out) const {
    out.clear();
    struct Key {
        uint16_t domain = 0;
        uint16_t scope = 0;
        uint32_t stat = 0;
        uint64_t id = 0;
        bool operator==(const Key &other) const {
            return domain == other.domain && scope == other.scope && stat == other.stat && id == other.id;
        }
    };
    struct KeyHash {
        size_t operator()(const Key &key) const noexcept {
            uint64_t value = key.domain;
            value = value * 1315423911ull + key.scope;
            value = value * 1315423911ull + key.stat;
            value = value * 1315423911ull + key.id;
            return static_cast<size_t>(value);
        }
    };
    std::unordered_map<Key, RuntimeModifierPodBucket, KeyHash> map;
    for (size_t d = 0; d < state.domains.size(); ++d) {
        const DomainState &domain = state.domains[d];
        for (const auto &entry : domain.entries) {
            if (entry.modifier_handle == 0 || entry.definition_id < 0 ||
                entry.definition_id >= static_cast<int32_t>(_catalog.definitions.size())) continue;
            const auto &definition = _catalog.definitions[static_cast<size_t>(entry.definition_id)];
            const double magnitude = static_cast<double>(entry.magnitude_q16) / Q16_ONE;
            const uint64_t id = scope_id(entry);
            for (uint32_t i = 0; i < definition.term_count; ++i) {
                const auto &term = _catalog.terms[definition.term_begin + i];
                const Key key{static_cast<uint16_t>(d), static_cast<uint16_t>(entry.scope),
                              static_cast<uint32_t>(term.stat_id), id};
                auto &bucket = map[key];
                bucket.domain = key.domain;
                bucket.scope = key.scope;
                bucket.stat_id = key.stat;
                bucket.scope_id = key.id;
                bucket.sum_add += term.add * entry.stacks * magnitude;
                const double factor = std::pow(1.0 + (term.factor - 1.0) * magnitude,
                                               static_cast<double>(entry.stacks));
                bucket.product_factor *= factor;
                ++bucket.active_count;
            }
        }
    }
    out.reserve(map.size());
    for (const auto &pair : map) out.push_back(pair.second);
    std::sort(out.begin(), out.end(), [](const auto &a, const auto &b) {
        if (a.domain != b.domain) return a.domain < b.domain;
        if (a.scope != b.scope) return a.scope < b.scope;
        if (a.stat_id != b.stat_id) return a.stat_id < b.stat_id;
        return a.scope_id < b.scope_id;
    });
}

uint64_t RuntimeModifierPodAuthority::state_hash(const State &state) const {
    uint64_t hash = FNV_OFFSET;
    hash = hash_value(hash, state.generation);
    hash = hash_value(hash, state.committed_day);
    for (size_t d = 0; d < state.domains.size(); ++d) {
        const DomainState &domain = state.domains[d];
        hash = hash_value(hash, static_cast<uint16_t>(d));
        hash = hash_value(hash, domain.version);
        hash = hash_value(hash, static_cast<uint64_t>(domain.entries.size()));
        hash = hash_value(hash, static_cast<uint64_t>(domain.handle_generations.size()));
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            hash = hash_value(hash, static_cast<uint32_t>(i));
            const uint32_t generation = i < domain.handle_generations.size()
                ? domain.handle_generations[i] : 0;
            hash = hash_value(hash, generation);
            const auto &entry = domain.entries[i];
            hash = hash_value(hash, entry.modifier_handle);
            if (entry.modifier_handle == 0) continue;
            hash = hash_value(hash, entry.target_handle);
            hash = hash_value(hash, entry.target_generation);
            hash = hash_value(hash, entry.definition_id);
            hash = hash_value(hash, entry.scope);
            hash = hash_value(hash, entry.entity_handle);
            hash = hash_value(hash, entry.group_handle);
            hash = hash_value(hash, entry.source_type);
            hash = hash_value(hash, entry.source_id);
            hash = hash_value(hash, entry.stacks);
            hash = hash_value(hash, entry.magnitude_q16);
            hash = hash_value(hash, entry.applied_day);
            hash = hash_value(hash, entry.expires_day);
        }
        hash = hash_value(hash, static_cast<uint64_t>(domain.free_indices.size()));
        for (const uint32_t index : domain.free_indices) hash = hash_value(hash, index);
        hash = hash_value(hash, static_cast<uint64_t>(domain.expiry_queue.size()));
        for (const uint32_t index : domain.expiry_queue) hash = hash_value(hash, index);
    }
    return hash;
}

void RuntimeModifierPodAuthority::build_snapshot(
        const State &state, RuntimeModifierPodSnapshot &out) const {
    out = RuntimeModifierPodSnapshot{};
    out.abi_version = RUNTIME_MODIFIER_POD_ABI_VERSION;
    out.catalog_hash = _catalog.catalog_hash;
    out.generation = state.generation;
    out.committed_day = state.committed_day;
    out.state_hash = state_hash(state);
    for (size_t i = 0; i < state.domains.size(); ++i) {
        out.domain_versions[i] = state.domains[i].version;
        for (const auto &entry : state.domains[i].entries) {
            if (entry.modifier_handle == 0) continue;
            RuntimeModifierPodEntry copy = entry;
            copy.domain = static_cast<uint16_t>(i);
            out.entries.push_back(copy);
        }
    }
    std::sort(out.entries.begin(), out.entries.end(), [](const auto &a, const auto &b) {
        if (a.domain != b.domain) return a.domain < b.domain;
        if (a.modifier_handle != b.modifier_handle) return a.modifier_handle < b.modifier_handle;
        if (a.definition_id != b.definition_id) return a.definition_id < b.definition_id;
        return a.scope < b.scope;
    });
    rebuild_buckets(state, out.buckets);
}

void RuntimeModifierPodAuthority::set_error(RuntimeModifierPodReport &report,
                                             const char *reason) const {
    runtime_copy_text(report.fallback_reason, reason != nullptr ? reason : "modifier_pod_failed");
    report.completed = 0;
    report.preflight_ok = 0;
}

bool RuntimeModifierPodAuthority::plan_day(
        int64_t day, uint64_t input_generation,
        const std::vector<RuntimeModifierPodCommand> &commands,
        const std::vector<RuntimeModifierPodCommand> &intents,
        RuntimeModifierPodSnapshot &planned_snapshot,
        std::vector<RuntimeDomainAck> &acks,
        RuntimeModifierPodReport &report,
        std::string &error) {
    clear_error(error);
    report = RuntimeModifierPodReport{};
    report.generation = _current.generation;
    if (!_configured) { error = "modifier_pod_not_configured"; set_error(report, error.c_str()); return false; }
    if (day < _current.committed_day) { error = "modifier_pod_day_regression"; set_error(report, error.c_str()); return false; }
    _next = _current;
    acks.clear();
    // Expiry is part of the plan lane. It is intentionally applied before
    // commands, matching the legacy daily boundary semantics.
    for (DomainState &domain : _next.domains) {
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            auto &entry = domain.entries[i];
            if (entry.modifier_handle != 0 && entry.expires_day >= 0 &&
                entry.expires_day <= day) {
                entry.modifier_handle = 0;
                domain.free_indices.push_back(static_cast<uint32_t>(i));
                ++domain.version;
                ++report.expired_entries;
            }
        }
        rebuild_expiry_queue(domain);
    }
    struct OrderedCommand {
        RuntimeModifierPodCommand command;
        bool is_intent = false;
    };
    std::vector<OrderedCommand> ordered;
    ordered.reserve(commands.size() + intents.size());
    for (const auto &command : commands)
        if (command.effective_day <= day) ordered.push_back({command, false});
    for (const auto &intent : intents) {
        RuntimeModifierPodCommand command = intent;
        command.request_id = intent.request_id != 0 ? intent.request_id : intent.source_id;
        command.producer_id = intent.producer_id;
        command.sequence = intent.sequence;
        command.input_generation = input_generation;
        ordered.push_back({command, true});
    }
    if (intents.size() > RUNTIME_DOMAIN_INTENT_CAPACITY) {
        error = "modifier_pod_ack_capacity_exceeded";
        set_error(report, error.c_str());
        _plan_ready = false;
        return false;
    }
    std::stable_sort(ordered.begin(), ordered.end(),
        [](const OrderedCommand &a, const OrderedCommand &b) {
            return RuntimeModifierPodAuthority::command_less(a.command, b.command);
        });
    for (size_t ordered_index = 0; ordered_index < ordered.size(); ++ordered_index) {
        const auto &command = ordered[ordered_index].command;
        std::string command_error;
        bool valid = validate_command(command, command_error);
        if (valid && command.input_generation != 0 &&
            command.input_generation != input_generation) {
            valid = false;
            command_error = "modifier_pod_input_generation_stale";
        }
        RuntimeDomainAck ack;
        ack.request_id = command.request_id;
        ack.transaction_id = command.request_id;
        ack.target_handle = command.entity_handle;
        ack.target_generation = command.target_generation;
        ack.domain = static_cast<uint16_t>(RuntimeDomainId::MODIFIER);
        ack.effective_day = command.effective_day;
        ack.producer_id = command.producer_id;
        ack.sequence = command.sequence;
        bool changed = false;
        bool ok = false;
        if (valid) {
            if (command.opcode == COMMAND_APPLY) {
                ok = apply_command(_next, command, day, ack, changed, command_error);
            } else if (command.opcode == COMMAND_REMOVE) {
                ok = remove_entry(_next, command, day, ack, changed, command_error);
            } else {
                DomainState &domain = _next.domains[command.domain];
                size_t index = 0;
                if (!resolve_entry(domain, command.modifier_handle, index)) {
                    command_error = "modifier_pod_stale_generation";
                    ack.code = RuntimeDomainAckCode::STALE_GENERATION;
                } else {
                    auto &entry = domain.entries[index];
                    if (command.target_generation != 0 &&
                        command.target_generation != entry.target_generation) {
                        command_error = "modifier_pod_stale_generation";
                        ack.code = RuntimeDomainAckCode::STALE_GENERATION;
                    } else if (command.opcode == COMMAND_REFRESH) {
                        if (command.duration_days != -1 && command.duration_days <= 0) {
                            command_error = "modifier_pod_duration_invalid";
                        } else {
                            entry.applied_day = day;
                            entry.expires_day = command.duration_days < 0 ? -1 : day + command.duration_days;
                            ++domain.version;
                            changed = true;
                            ok = true;
                        }
                    } else if (command.opcode == COMMAND_SET_STACKS) {
                        const auto &definition = _catalog.definitions[static_cast<size_t>(entry.definition_id)];
                        if (command.stacks <= 0 || command.stacks > definition.max_stacks) {
                            command_error = "modifier_pod_stack_invalid";
                        } else {
                            entry.stacks = command.stacks;
                            ++domain.version;
                            changed = true;
                            ok = true;
                        }
                    } else {
                        entry.magnitude_q16 = command.magnitude_q16;
                        entry.value_q16 = command.magnitude_q16;
                        ++domain.version;
                        changed = true;
                        ok = true;
                    }
                }
            }
        }
        if (ok) {
            ++report.applied_commands;
            ack.code = RuntimeDomainAckCode::OK;
        } else {
            ++report.rejected_commands;
            if (ack.code == RuntimeDomainAckCode::OK)
                ack.code = command_error == "modifier_pod_stale_generation"
                    ? RuntimeDomainAckCode::STALE_GENERATION : RuntimeDomainAckCode::REJECTED;
        }
        const bool is_intent = ordered[ordered_index].is_intent;
        // Only Effect/cross-domain intents require domain ACKs. Host command
        // receipts remain on the existing RuntimeCommandReceipt path.
        if (is_intent) {
            if (acks.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
                error = "modifier_pod_ack_capacity_exceeded";
                set_error(report, error.c_str());
                _plan_ready = false;
                return false;
            }
            acks.push_back(ack);
        }
        if (changed) ++report.work_units;
        if (is_intent && !ok) {
            error = command_error.empty() ? "modifier_pod_intent_rejected" : command_error;
            set_error(report, error.c_str());
            _plan_ready = false;
            return false;
        }
        if (!ok && error.empty()) error = command_error;
    }
    for (DomainState &domain : _next.domains) rebuild_expiry_queue(domain);
    _next.generation = _current.generation + 1;
    _next.committed_day = day;
    _next.state_hash = state_hash(_next);
    build_snapshot(_next, planned_snapshot);
    planned_snapshot.acks = acks;
    report.generation = _next.generation;
    report.state_hash = planned_snapshot.state_hash;
    report.ack_count = static_cast<uint32_t>(acks.size());
    report.work_units += report.expired_entries;
    report.completed = 1;
    report.preflight_ok = 1;
    _planned_snapshot = planned_snapshot;
    _report = report;
    _plan_ready = true;
    return true;
}

bool RuntimeModifierPodAuthority::commit_day(RuntimeModifierPodSnapshot &planned_snapshot,
                                             std::string &error) {
    clear_error(error);
    if (!_plan_ready) { error = "modifier_pod_plan_missing"; return false; }
    if (planned_snapshot.catalog_hash != _catalog.catalog_hash ||
        planned_snapshot.generation != _next.generation ||
        planned_snapshot.state_hash != state_hash(_next)) {
        error = "modifier_pod_snapshot_invalid";
        _plan_ready = false;
        return false;
    }
    _current = std::move(_next);
    _snapshot = std::move(planned_snapshot);
    _planned_snapshot = RuntimeModifierPodSnapshot{};
    _plan_ready = false;
    return true;
}

void RuntimeModifierPodAuthority::discard_plan() {
    _next = _current;
    _planned_snapshot = RuntimeModifierPodSnapshot{};
    _plan_ready = false;
}

void RuntimeModifierPodAuthority::serialize(std::vector<uint8_t> &out) const {
    out.clear();
    out.insert(out.end(), {'M', 'D', 'F', '2'});
    append_le(out, RUNTIME_MODIFIER_POD_ABI_VERSION);
    append_le(out, _catalog.catalog_hash);
    append_le(out, _current.generation);
    append_le(out, _current.state_hash);
    append_le(out, _current.committed_day);
    for (const DomainState &domain : _current.domains) append_le(out, domain.version);
    const auto append_entry = [&out](const RuntimeModifierPodEntry &entry) {
        append_le(out, entry.modifier_handle);
        append_le(out, entry.target_handle);
        append_le(out, entry.target_generation);
        append_le(out, entry.definition_id);
        append_le(out, entry.scope);
        append_le(out, entry.entity_handle);
        append_le(out, entry.group_handle);
        append_le(out, entry.source_type);
        append_le(out, entry.source_id);
        append_le(out, entry.stacks);
        append_le(out, entry.magnitude_q16);
        append_le(out, entry.applied_day);
        append_le(out, entry.expires_day);
    };
    for (const DomainState &domain : _current.domains) {
        append_le(out, static_cast<uint32_t>(domain.entries.size()));
        for (size_t i = 0; i < domain.entries.size(); ++i) {
            const uint32_t generation = i < domain.handle_generations.size()
                ? domain.handle_generations[i] : 0;
            append_le(out, generation);
            const uint8_t active = domain.entries[i].modifier_handle != 0 ? 1u : 0u;
            append_le(out, active);
            if (active != 0) append_entry(domain.entries[i]);
        }
        append_le(out, static_cast<uint32_t>(domain.free_indices.size()));
        for (const uint32_t index : domain.free_indices) append_le(out, index);
        append_le(out, static_cast<uint32_t>(domain.expiry_queue.size()));
        for (const uint32_t index : domain.expiry_queue) append_le(out, index);
    }
    const uint32_t pending_count = static_cast<uint32_t>(std::min<size_t>(
        _pending_identities.size(), RUNTIME_MODIFIER_POD_MAX_ENTRIES));
    append_le(out, pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        const RuntimeModifierPodCommand &command = _pending_identities[i];
        append_le(out, command.request_id);
        append_le(out, command.producer_id);
        append_le(out, command.sequence);
        append_le(out, command.effective_day);
        append_le(out, command.opcode);
        append_le(out, command.domain);
    }
    const uint64_t checksum = hash_bytes(FNV_OFFSET, out.data(), out.size());
    append_le(out, checksum);
}

bool RuntimeModifierPodAuthority::restore(const uint8_t *data, size_t size,
                                          std::string &error) {
    clear_error(error);
    if (data == nullptr || size < 4u + 4u + 8u * 6u + 8u ||
        size > MAX_SERIALIZED_BYTES || std::memcmp(data, "MDF2", 4) != 0) {
        error = "modifier_pod_save_invalid";
        return false;
    }
    const size_t encoded_at = size - sizeof(uint64_t);
    size_t check_cursor = encoded_at;
    uint64_t encoded = 0;
    if (!read_le(data, size, check_cursor, encoded) ||
        hash_bytes(FNV_OFFSET, data, encoded_at) != encoded) {
        error = "modifier_pod_save_checksum_failed";
        return false;
    }
    size_t cursor = 4u;
    uint32_t abi = 0;
    uint64_t catalog_hash = 0, generation = 0, saved_state_hash = 0;
    int64_t committed_day = -1;
    std::array<uint64_t, 4> versions{};
    if (!read_le(data, size, cursor, abi) || !read_le(data, size, cursor, catalog_hash) ||
        !read_le(data, size, cursor, generation) ||
        !read_le(data, size, cursor, saved_state_hash) ||
        !read_le(data, size, cursor, committed_day)) {
        error = "modifier_pod_save_truncated";
        return false;
    }
    for (uint64_t &version : versions) {
        if (!read_le(data, size, cursor, version)) {
            error = "modifier_pod_save_truncated";
            return false;
        }
    }
    if (!_configured || abi != RUNTIME_MODIFIER_POD_ABI_VERSION ||
        catalog_hash != _catalog.catalog_hash) {
        error = "modifier_pod_save_catalog_mismatch";
        return false;
    }

    State restored;
    restored.generation = generation;
    restored.committed_day = committed_day;
    const auto read_entry = [this, data, size, &cursor](RuntimeModifierPodEntry &entry) {
        return read_le(data, size, cursor, entry.modifier_handle) &&
            read_le(data, size, cursor, entry.target_handle) &&
            read_le(data, size, cursor, entry.target_generation) &&
            read_le(data, size, cursor, entry.definition_id) &&
            read_le(data, size, cursor, entry.scope) &&
            read_le(data, size, cursor, entry.entity_handle) &&
            read_le(data, size, cursor, entry.group_handle) &&
            read_le(data, size, cursor, entry.source_type) &&
            read_le(data, size, cursor, entry.source_id) &&
            read_le(data, size, cursor, entry.stacks) &&
            read_le(data, size, cursor, entry.magnitude_q16) &&
            read_le(data, size, cursor, entry.applied_day) &&
            read_le(data, size, cursor, entry.expires_day);
    };
    for (size_t d = 0; d < restored.domains.size(); ++d) {
        DomainState &domain = restored.domains[d];
        domain.version = versions[d];
        uint32_t slot_count = 0;
        if (!read_le(data, size, cursor, slot_count) ||
            slot_count > RUNTIME_MODIFIER_POD_MAX_ENTRIES) {
            error = "modifier_pod_save_count_invalid";
            return false;
        }
        domain.entries.resize(slot_count);
        domain.handle_generations.resize(slot_count);
        for (uint32_t slot = 0; slot < slot_count; ++slot) {
            uint8_t active = 0;
            if (!read_le(data, size, cursor, domain.handle_generations[slot]) ||
                !read_le(data, size, cursor, active) || active > 1u) {
                error = "modifier_pod_save_entry_truncated";
                return false;
            }
            if (active != 0 && !read_entry(domain.entries[slot])) {
                error = "modifier_pod_save_entry_truncated";
                return false;
            }
            if (active == 0) {
                domain.entries[slot] = RuntimeModifierPodEntry{};
            } else {
                RuntimeModifierPodEntry &entry = domain.entries[slot];
                entry.domain = static_cast<uint16_t>(d);
                const uint32_t encoded_slot = static_cast<uint32_t>(
                    entry.modifier_handle & 0xffffffffull);
                const uint32_t encoded_generation = static_cast<uint32_t>(
                    entry.modifier_handle >> 32u);
                if (encoded_slot != slot || encoded_generation == 0 ||
                    domain.handle_generations[slot] != encoded_generation ||
                    entry.definition_id < 0 ||
                    entry.definition_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
                    _catalog.definitions[static_cast<size_t>(entry.definition_id)].domain !=
                        static_cast<int32_t>(d) || entry.scope < 0 || entry.scope > 2 ||
                    entry.stacks <= 0 || entry.stacks > _catalog.definitions[
                        static_cast<size_t>(entry.definition_id)].max_stacks ||
                    entry.magnitude_q16 < 0 ||
                    entry.magnitude_q16 > MAX_MAGNITUDE_Q16 ||
                    (entry.expires_day != -1 && entry.expires_day < entry.applied_day)) {
                    error = "modifier_pod_save_entry_invalid";
                    return false;
                }
                entry.value_q16 = entry.magnitude_q16;
            }
        }
        uint32_t free_count = 0;
        if (!read_le(data, size, cursor, free_count) || free_count > slot_count) {
            error = "modifier_pod_save_free_list_invalid";
            return false;
        }
        domain.free_indices.resize(free_count);
        std::vector<uint8_t> free_seen(slot_count, 0);
        for (uint32_t &index : domain.free_indices) {
            if (!read_le(data, size, cursor, index) || index >= slot_count ||
                free_seen[index] != 0 || domain.entries[index].modifier_handle != 0) {
                error = "modifier_pod_save_free_list_invalid";
                return false;
            }
            free_seen[index] = 1;
        }
        uint32_t expiry_count = 0;
        if (!read_le(data, size, cursor, expiry_count) || expiry_count > slot_count) {
            error = "modifier_pod_save_expiry_invalid";
            return false;
        }
        domain.expiry_queue.resize(expiry_count);
        for (uint32_t &index : domain.expiry_queue) {
            if (!read_le(data, size, cursor, index) || index >= slot_count ||
                domain.entries[index].modifier_handle == 0 ||
                domain.entries[index].expires_day < 0) {
                error = "modifier_pod_save_expiry_invalid";
                return false;
            }
        }
        std::vector<uint32_t> canonical = domain.expiry_queue;
        rebuild_expiry_queue(domain);
        if (canonical != domain.expiry_queue) {
            error = "modifier_pod_save_expiry_order_invalid";
            return false;
        }
    }
    uint32_t pending_count = 0;
    if (!read_le(data, size, cursor, pending_count) ||
        pending_count > RUNTIME_MODIFIER_POD_MAX_ENTRIES) {
        error = "modifier_pod_save_pending_invalid";
        return false;
    }
    std::vector<RuntimeModifierPodCommand> pending;
    pending.reserve(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        RuntimeModifierPodCommand command;
        if (!read_le(data, size, cursor, command.request_id) ||
            !read_le(data, size, cursor, command.producer_id) ||
            !read_le(data, size, cursor, command.sequence) ||
            !read_le(data, size, cursor, command.effective_day) ||
            !read_le(data, size, cursor, command.opcode) ||
            !read_le(data, size, cursor, command.domain)) {
            error = "modifier_pod_save_pending_truncated";
            return false;
        }
        pending.push_back(command);
    }
    if (cursor != encoded_at) {
        error = "modifier_pod_save_trailing_bytes";
        return false;
    }
    restored.state_hash = state_hash(restored);
    if (restored.state_hash != saved_state_hash) {
        error = "modifier_pod_save_state_hash_failed";
        return false;
    }
    _current = std::move(restored);
    _next = _current;
    _pending_identities = std::move(pending);
    build_snapshot(_current, _snapshot);
    _report.generation = _current.generation;
    _report.state_hash = _snapshot.state_hash;
    _plan_ready = false;
    return true;
}

bool RuntimeModifierPodAuthority::restore_legacy_entries(
        const std::vector<std::pair<uint16_t, RuntimeModifierPodEntry>> &entries,
        uint64_t generation, uint64_t saved_state_hash, int64_t committed_day,
        const std::array<uint64_t, 4> &domain_versions, std::string &error) {
    clear_error(error);
    if (!_configured || entries.size() > RUNTIME_MODIFIER_POD_MAX_ENTRIES) {
        error = "modifier_pod_legacy_restore_invalid";
        return false;
    }
    State restored;
    restored.generation = generation;
    restored.committed_day = committed_day;
    for (size_t d = 0; d < restored.domains.size(); ++d)
        restored.domains[d].version = domain_versions[d];
    for (const auto &pair : entries) {
        const uint16_t domain_id = pair.first;
        const RuntimeModifierPodEntry &entry = pair.second;
        if (domain_id >= 4 || entry.modifier_handle == 0 ||
            entry.definition_id < 0 ||
            entry.definition_id >= static_cast<int32_t>(_catalog.definitions.size()) ||
            _catalog.definitions[static_cast<size_t>(entry.definition_id)].domain !=
                static_cast<int32_t>(domain_id)) {
            error = "modifier_pod_legacy_entry_invalid";
            return false;
        }
        DomainState &domain = restored.domains[domain_id];
        const uint32_t slot = static_cast<uint32_t>(entry.modifier_handle & 0xffffffffull);
        const uint32_t generation_bits = static_cast<uint32_t>(entry.modifier_handle >> 32u);
        if (generation_bits == 0 || slot >= RUNTIME_MODIFIER_POD_MAX_ENTRIES) {
            error = "modifier_pod_legacy_handle_invalid";
            return false;
        }
        if (domain.entries.size() <= slot) {
            domain.entries.resize(static_cast<size_t>(slot) + 1u);
            domain.handle_generations.resize(static_cast<size_t>(slot) + 1u, 0);
        }
        if (domain.entries[slot].modifier_handle != 0) {
            error = "modifier_pod_legacy_handle_duplicate";
            return false;
        }
        domain.entries[slot] = entry;
        domain.entries[slot].domain = domain_id;
        domain.entries[slot].value_q16 = entry.magnitude_q16;
        domain.handle_generations[slot] = generation_bits;
    }
    for (DomainState &domain : restored.domains) {
        for (uint32_t index = 0; index < domain.entries.size(); ++index) {
            if (domain.entries[index].modifier_handle == 0)
                domain.free_indices.push_back(index);
        }
        rebuild_expiry_queue(domain);
    }
    restored.state_hash = state_hash(restored);
    if (saved_state_hash != 0 && restored.state_hash != saved_state_hash) {
        error = "modifier_pod_legacy_state_hash_failed";
        return false;
    }
    _current = std::move(restored);
    _next = _current;
    _pending_identities.clear();
    build_snapshot(_current, _snapshot);
    _report.generation = _current.generation;
    _report.state_hash = _snapshot.state_hash;
    _plan_ready = false;
    return true;
}

bool RuntimeModifierPodAuthority::self_test(std::string &error) {
    clear_error(error);
    const auto fail = [&error](const char *reason) {
        if (error.empty()) error = reason;
        return false;
    };
    RuntimeModifierPodCatalog catalog;
    catalog.stats = {{0, -100.0, 100.0, 1}, {1, 0.0, 10.0, 1},
                     {2, 0.0, 100.0, 1}, {3, 0.0, 100.0, 1}};
    catalog.definitions = {{1, 0, POLICY_STACK_REFRESH, 4, 2, 0, 2},
                           {1, 1, POLICY_UNIQUE_SOURCE, 1, -1, 2, 1},
                           {1, 2, POLICY_INDEPENDENT, 2, -1, 3, 1},
                           {1, 3, POLICY_INDEPENDENT, 2, -1, 4, 1}};
    catalog.terms = {{0, 2.0, 1.0}, {0, 0.0, 1.5},
                     {1, 0.0, 1.25}, {2, 3.0, 1.0},
                     {3, 0.0, 0.75}};
    RuntimeModifierPodAuthority authority;
    if (!authority.configure(catalog, error)) return false;
    RuntimeModifierPodCatalog invalid_catalog = catalog;
    invalid_catalog.stats[0].domain = 4;
    RuntimeModifierPodAuthority catalog_probe;
    std::string expected_error;
    if (catalog_probe.configure(invalid_catalog, expected_error))
        return fail("modifier_pod_catalog_shape_self_test_failed");
    invalid_catalog = catalog;
    invalid_catalog.catalog_hash = 1;
    expected_error.clear();
    if (catalog_probe.configure(invalid_catalog, expected_error))
        return fail("modifier_pod_catalog_hash_self_test_failed");
    RuntimeModifierPodCommand apply;
    apply.request_id = 1; apply.producer_id = 2; apply.sequence = 1;
    apply.effective_day = 0; apply.opcode = COMMAND_APPLY; apply.domain = 0;
    apply.definition_id = 0; apply.scope = 2; apply.entity_handle = 7;
    apply.duration_days = 2; apply.stacks = 1; apply.magnitude_q16 = Q16_ONE;
    RuntimeModifierPodSnapshot planned;
    std::vector<RuntimeDomainAck> acks;
    RuntimeModifierPodReport report;
    if (!authority.plan_day(0, 1, {apply}, {}, planned, acks, report, error) ||
        !authority.commit_day(planned, error) || authority.snapshot().entries.size() != 1) return false;
    RuntimeModifierPodCommand stack = apply;
    stack.request_id = 2; stack.sequence = 2; stack.stacks = 2;
    if (!authority.plan_day(1, 1, {stack}, {}, planned, acks, report, error) ||
        !authority.commit_day(planned, error) || authority.snapshot().entries[0].stacks != 3) return false;
    RuntimeModifierPodCommand stale;
    stale.request_id = 3; stale.effective_day = 1; stale.opcode = COMMAND_SET_MAGNITUDE;
    stale.domain = 0; stale.modifier_handle = authority.snapshot().entries[0].modifier_handle + (1ull << 32u);
    stale.magnitude_q16 = Q16_ONE;
    if (!authority.plan_day(1, 1, {stale}, {}, planned, acks, report, error) ||
        acks.size() != 0 || report.rejected_commands != 1) return false;
    authority.discard_plan();
    std::vector<uint8_t> bytes;
    authority.serialize(bytes);
    RuntimeModifierPodAuthority restored;
    if (!restored.configure(catalog, error) || !restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().state_hash != authority.snapshot().state_hash) return false;

    RuntimeModifierPodAuthority semantics;
    if (!semantics.configure(catalog, error)) return false;
    apply.target_generation = 9;
    apply.magnitude_q16 = Q16_ONE / 2;
    std::vector<RuntimeModifierPodCommand> initial{apply};
    for (uint16_t domain = 1; domain < 4; ++domain) {
        RuntimeModifierPodCommand command = apply;
        command.request_id = static_cast<uint64_t>(domain) + 10u;
        command.sequence = static_cast<uint64_t>(domain) + 10u;
        command.domain = domain;
        command.definition_id = domain;
        command.scope = domain == 1 ? 1 : 2;
        command.entity_handle = 20u + domain;
        command.group_handle = 20u + domain;
        command.source_type = 30u + domain;
        command.source_id = 40u + domain;
        command.target_generation = 0;
        command.duration_days = -1;
        command.magnitude_q16 = Q16_ONE;
        initial.push_back(command);
    }
    if (!semantics.plan_day(0, 1, initial, {}, planned, acks, report, error) ||
        !semantics.commit_day(planned, error))
        return fail("modifier_pod_apply_self_test_failed");
    const RuntimeModifierPodSnapshot first = semantics.snapshot();
    if (first.entries.size() != 4 || first.buckets.size() != 4)
        return fail("modifier_pod_domain_isolation_self_test_failed");
    std::array<uint32_t, 4> domain_counts{};
    for (const auto &entry : first.entries) {
        if (entry.domain >= domain_counts.size())
            return fail("modifier_pod_entry_domain_self_test_failed");
        ++domain_counts[entry.domain];
    }
    if (domain_counts != std::array<uint32_t, 4>{1, 1, 1, 1})
        return fail("modifier_pod_domain_isolation_self_test_failed");
    const auto first_bucket = std::find_if(first.buckets.begin(), first.buckets.end(),
        [](const RuntimeModifierPodBucket &bucket) {
            return bucket.domain == 0 && bucket.scope == 2 &&
                bucket.stat_id == 0 && bucket.scope_id == 7;
        });
    if (first_bucket == first.buckets.end() ||
        std::abs(first_bucket->sum_add - 1.0) > 1e-12 ||
        std::abs(first_bucket->product_factor - 1.25) > 1e-12 ||
        std::abs(std::clamp((3.0 + first_bucket->sum_add) *
            first_bucket->product_factor, -100.0, 100.0) - 5.0) > 1e-12)
        return fail("modifier_pod_formula_self_test_failed");

    const uint64_t domain0_handle = first.entries[0].modifier_handle;
    const uint64_t domain2_handle = first.entries[2].modifier_handle;
    stack = apply;
    stack.request_id = 20; stack.sequence = 20; stack.effective_day = 1;
    stack.stacks = 2; stack.magnitude_q16 = Q16_ONE;
    RuntimeModifierPodCommand set_stacks = stack;
    set_stacks.request_id = 21; set_stacks.sequence = 21;
    set_stacks.opcode = COMMAND_SET_STACKS;
    set_stacks.modifier_handle = domain0_handle; set_stacks.stacks = 4;
    RuntimeModifierPodCommand set_magnitude = set_stacks;
    set_magnitude.request_id = 22; set_magnitude.sequence = 22;
    set_magnitude.opcode = COMMAND_SET_MAGNITUDE;
    set_magnitude.magnitude_q16 = Q16_ONE / 2;
    RuntimeModifierPodCommand refresh = set_stacks;
    refresh.request_id = 23; refresh.sequence = 23;
    refresh.opcode = COMMAND_REFRESH; refresh.duration_days = 3;
    RuntimeModifierPodCommand remove_unique = initial[1];
    remove_unique.request_id = 24; remove_unique.sequence = 24;
    remove_unique.effective_day = 1; remove_unique.opcode = COMMAND_REMOVE;
    remove_unique.modifier_handle = 0;
    RuntimeModifierPodCommand remove_exact = initial[2];
    remove_exact.request_id = 25; remove_exact.sequence = 25;
    remove_exact.effective_day = 1; remove_exact.opcode = COMMAND_REMOVE;
    remove_exact.modifier_handle = domain2_handle;
    const std::vector<RuntimeModifierPodCommand> mutations{
        refresh, remove_exact, set_magnitude, stack, remove_unique, set_stacks};
    if (!semantics.plan_day(1, 1, mutations, {}, planned, acks, report, error) ||
        !semantics.commit_day(planned, error))
        return fail("modifier_pod_opcode_self_test_failed");
    const RuntimeModifierPodSnapshot mutated = semantics.snapshot();
    const auto active0 = std::find_if(mutated.entries.begin(), mutated.entries.end(),
        [](const RuntimeModifierPodEntry &entry) { return entry.domain == 0; });
    if (mutated.entries.size() != 2 || active0 == mutated.entries.end() ||
        active0->stacks != 4 || active0->magnitude_q16 != Q16_ONE / 2 ||
        active0->applied_day != 1 || active0->expires_day != 4)
        return fail("modifier_pod_opcode_state_self_test_failed");
    const auto clamped_bucket = std::find_if(mutated.buckets.begin(), mutated.buckets.end(),
        [](const RuntimeModifierPodBucket &bucket) {
            return bucket.domain == 0 && bucket.stat_id == 0;
        });
    if (clamped_bucket == mutated.buckets.end() ||
        std::abs(clamped_bucket->sum_add - 4.0) > 1e-12 ||
        std::abs(clamped_bucket->product_factor - std::pow(1.25, 4.0)) > 1e-12 ||
        std::clamp((90.0 + clamped_bucket->sum_add) *
            clamped_bucket->product_factor, -100.0, 100.0) != 100.0)
        return fail("modifier_pod_magnitude_clamp_self_test_failed");

    if (!semantics.plan_day(2, 1, {}, {}, planned, acks, report, error) ||
        !semantics.commit_day(planned, error) || semantics.snapshot().entries.size() != 2)
        return fail("modifier_pod_expiry_early_self_test_failed");
    const uint64_t before_reject_hash = semantics.snapshot().state_hash;
    const uint64_t before_reject_generation = semantics.snapshot().generation;
    stale = set_magnitude;
    stale.request_id = 30; stale.sequence = 30; stale.effective_day = 3;
    stale.modifier_handle = domain0_handle + (1ull << 32u);
    if (!semantics.plan_day(3, 1, {stale}, {}, planned, acks, report, error) ||
        !acks.empty() || report.rejected_commands != 1)
        return fail("modifier_pod_stale_generation_self_test_failed");
    semantics.discard_plan();
    if (semantics.snapshot().state_hash != before_reject_hash ||
        semantics.snapshot().generation != before_reject_generation)
        return fail("modifier_pod_discard_self_test_failed");

    RuntimeModifierPodCommand valid_before_failure = initial[2];
    valid_before_failure.request_id = 31; valid_before_failure.sequence = 1;
    valid_before_failure.effective_day = 3;
    RuntimeModifierPodCommand rejected_intent = stale;
    rejected_intent.request_id = 32; rejected_intent.producer_id = 7;
    rejected_intent.sequence = 2; rejected_intent.entity_handle = 7;
    error.clear();
    if (semantics.plan_day(3, 1, {valid_before_failure}, {rejected_intent},
            planned, acks, report, error))
        return fail("modifier_pod_failed_plan_self_test_failed");
    semantics.discard_plan();
    if (semantics.snapshot().state_hash != before_reject_hash ||
        semantics.snapshot().generation != before_reject_generation)
        return fail("modifier_pod_failed_plan_mutated_current");

    error.clear();
    if (!semantics.plan_day(4, 1, {}, {}, planned, acks, report, error) ||
        !semantics.commit_day(planned, error) || semantics.snapshot().entries.size() != 1 ||
        semantics.snapshot().entries[0].domain != 3)
        return fail("modifier_pod_expiry_boundary_self_test_failed");

    RuntimeModifierPodAuthority ordered_a;
    RuntimeModifierPodAuthority ordered_b;
    if (!ordered_a.configure(catalog, error) || !ordered_b.configure(catalog, error))
        return fail("modifier_pod_ordering_configure_failed");
    RuntimeModifierPodCommand earlier = initial[1];
    earlier.request_id = 40; earlier.producer_id = 1; earlier.sequence = 1;
    earlier.magnitude_q16 = Q16_ONE;
    RuntimeModifierPodCommand later = earlier;
    later.request_id = 41; later.producer_id = 2;
    later.magnitude_q16 = Q16_ONE / 2;
    RuntimeModifierPodSnapshot planned_b;
    std::vector<RuntimeDomainAck> acks_b;
    RuntimeModifierPodReport report_b;
    if (!ordered_a.plan_day(0, 1, {later, earlier}, {}, planned, acks, report, error) ||
        !ordered_a.commit_day(planned, error) ||
        !ordered_b.plan_day(0, 1, {earlier, later}, {}, planned_b, acks_b,
                            report_b, error) ||
        !ordered_b.commit_day(planned_b, error) ||
        ordered_a.snapshot().state_hash != ordered_b.snapshot().state_hash ||
        ordered_a.snapshot().entries[0].magnitude_q16 != Q16_ONE / 2)
        return fail("modifier_pod_stable_order_self_test_failed");

    RuntimeModifierPodAuthority ack_authority;
    if (!ack_authority.configure(catalog, error)) return false;
    RuntimeModifierPodCommand intent = apply;
    intent.request_id = 50; intent.producer_id = 5; intent.sequence = 6;
    intent.entity_handle = (static_cast<uint64_t>(9) << 32u) | 7u;
    intent.target_generation = 9;
    if (!ack_authority.plan_day(0, 1, {}, {intent}, planned, acks, report, error) ||
        acks.size() != 1 || acks[0].code != RuntimeDomainAckCode::OK ||
        acks[0].request_id != intent.request_id ||
        acks[0].transaction_id != intent.request_id ||
        acks[0].producer_id != intent.producer_id ||
        acks[0].sequence != intent.sequence ||
        acks[0].target_handle != intent.entity_handle ||
        acks[0].target_generation != intent.target_generation ||
        acks[0].effective_day != intent.effective_day)
        return fail("modifier_pod_ack_identity_self_test_failed");
    ack_authority.discard_plan();

    const uint64_t restored_hash = restored.snapshot().state_hash;
    bytes.back() ^= 0x80u;
    error.clear();
    if (restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().state_hash != restored_hash)
        return fail("modifier_pod_mdf2_transaction_self_test_failed");
    error.clear();
    return true;
}

RuntimeModifierSnapshotRing::RuntimeModifierSnapshotRing() { reset(); }

void RuntimeModifierSnapshotRing::reset() {
    for (Slot &slot : _slots) {
        slot.snapshot = RuntimeModifierPodSnapshot{};
        slot.state.store(FREE, std::memory_order_relaxed);
    }
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeModifierSnapshotRing::try_begin_write(uint32_t &index) {
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

void RuntimeModifierSnapshotRing::publish(uint32_t index) {
    if (index >= _slots.size()) return;
    _published_generation.store(_slots[index].snapshot.generation,
                                std::memory_order_relaxed);
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeModifierSnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                     uint32_t &index) {
    const bool accept_initial = after_generation == std::numeric_limits<uint64_t>::max();
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
            std::memory_order_acq_rel, std::memory_order_relaxed)) return false;
    index = best_index;
    return true;
}

bool RuntimeModifierSnapshotRing::try_acquire_generation(uint64_t generation,
                                                         uint32_t &index) {
    if (generation == 0) return false;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].snapshot.generation != generation) continue;
        uint8_t expected = READY;
        if (_slots[i].state.compare_exchange_strong(expected, READING,
                std::memory_order_acq_rel, std::memory_order_relaxed)) {
            index = i;
            return true;
        }
    }
    return false;
}

void RuntimeModifierSnapshotRing::release(uint32_t index) {
    if (index < _slots.size()) _slots[index].state.store(FREE, std::memory_order_release);
}

bool RuntimeModifierSnapshotRing::self_test() {
    RuntimeModifierSnapshotRing ring;
    uint32_t index = 0;
    if (!ring.try_begin_write(index)) return false;
    ring.write_buffer(index).generation = 1;
    ring.publish(index);
    if (!ring.try_acquire_latest(0, index) ||
        ring.read_buffer(index).generation != 1) return false;
    ring.release(index);
    return true;
}

} // namespace pk

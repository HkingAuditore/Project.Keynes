#include "modifier_runtime.h"

#include "country_runtime.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <set>

#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace pk {

using namespace godot;

namespace {
constexpr uint32_t SAVE_MAGIC = 0x444d4b50U; // PKMD
constexpr uint32_t SAVE_END = 0x21444e45U;
constexpr size_t JOURNAL_CAPACITY = 4096;
constexpr uint32_t BUCKET_REBUILD_INTERVAL = 256;

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    const uint8_t *bytes = reinterpret_cast<const uint8_t *>(&value);
    out.insert(out.end(), bytes, bytes + sizeof(T));
}

template <typename T>
bool read_le(const std::vector<uint8_t> &bytes, size_t &cursor, T &value) {
    if (cursor + sizeof(T) > bytes.size()) return false;
    std::memcpy(&value, bytes.data() + cursor, sizeof(T));
    cursor += sizeof(T);
    return true;
}

void append_string(std::vector<uint8_t> &out, const std::string &value) {
    append_le<uint32_t>(out, static_cast<uint32_t>(value.size()));
    out.insert(out.end(), value.begin(), value.end());
}

bool read_string(const std::vector<uint8_t> &bytes, size_t &cursor,
                 std::string &value) {
    uint32_t size = 0;
    if (!read_le(bytes, cursor, size) || size > 1024 * 1024 ||
        cursor + size > bytes.size()) return false;
    value.assign(reinterpret_cast<const char *>(bytes.data() + cursor), size);
    cursor += size;
    return true;
}

uint64_t fnv_mix(uint64_t hash, const void *data, size_t size) {
    const uint8_t *bytes = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

uint64_t fnv_string(uint64_t hash, const std::string &value) {
    return fnv_mix(hash, value.data(), value.size());
}

double elapsed_ms(const std::chrono::steady_clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
}

Dictionary fail_dict(const char *reason) {
    Dictionary out;
    out["ok"] = false;
    out["reason"] = reason;
    return out;
}
} // namespace

size_t ModifierRuntime::BucketKeyHash::operator()(const BucketKey &key) const noexcept {
    uint64_t hash = static_cast<uint32_t>(key.stat_id) * 0x9e3779b185ebca87ULL;
    hash ^= static_cast<uint64_t>(static_cast<uint32_t>(key.scope)) << 48U;
    hash ^= key.scope_id + 0x9e3779b97f4a7c15ULL + (hash << 6U) + (hash >> 2U);
    return static_cast<size_t>(hash);
}

bool ModifierRuntime::UniqueKey::operator==(const UniqueKey &other) const {
    return definition_id == other.definition_id && scope == other.scope &&
        scope_id == other.scope_id && source_type == other.source_type &&
        source_id == other.source_id;
}

size_t ModifierRuntime::UniqueKeyHash::operator()(const UniqueKey &key) const noexcept {
    uint64_t hash = static_cast<uint32_t>(key.definition_id) * 0x9e3779b185ebca87ULL;
    hash ^= static_cast<uint64_t>(static_cast<uint32_t>(key.scope)) << 32U;
    hash ^= key.scope_id + (hash << 6U) + (hash >> 2U);
    hash ^= key.source_type + (hash << 6U) + (hash >> 2U);
    hash ^= key.source_id + (hash << 6U) + (hash >> 2U);
    return static_cast<size_t>(hash);
}

bool ModifierRuntime::ExpiryNode::operator>(const ExpiryNode &other) const {
    if (day != other.day) return day > other.day;
    if (index != other.index) return index > other.index;
    return generation > other.generation;
}

size_t ModifierRuntime::BuildingKeyHash::operator()(const BuildingKey &key) const noexcept {
    uint64_t value = static_cast<uint32_t>(key.cell);
    value = value * 0x9e3779b185ebca87ULL ^ static_cast<uint32_t>(key.type);
    value = value * 0xc2b2ae3d27d4eb4fULL ^ static_cast<uint32_t>(key.owner);
    return static_cast<size_t>(value);
}

int32_t ModifierRuntime::stat_id(const std::string &key) const {
    const auto it = _stat_ids.find(key);
    return it == _stat_ids.end() ? -1 : it->second;
}

int32_t ModifierRuntime::definition_id(const std::string &key) const {
    const auto it = _definition_ids.find(key);
    return it == _definition_ids.end() ? -1 : it->second;
}

bool ModifierRuntime::compile_catalog(const Dictionary &catalog,
                                      std::string &error) {
    const PackedStringArray stat_keys = catalog.get("stat_keys", PackedStringArray());
    const PackedInt32Array stat_domains = catalog.get("stat_domains", PackedInt32Array());
    const PackedFloat64Array stat_min = catalog.get("stat_min_values", PackedFloat64Array());
    const PackedFloat64Array stat_max = catalog.get("stat_max_values", PackedFloat64Array());
    const PackedByteArray stat_persistable = catalog.get("stat_persistable", PackedByteArray());
    const int32_t stat_count = stat_keys.size();
    if (stat_count <= 0 || stat_domains.size() != stat_count ||
        stat_min.size() != stat_count || stat_max.size() != stat_count ||
        stat_persistable.size() != stat_count) {
        error = "modifier_stat_catalog_shape_invalid";
        return false;
    }

    std::vector<StatDefinition> stats;
    std::unordered_map<std::string, int32_t> stat_ids;
    stats.reserve(stat_count);
    for (int32_t i = 0; i < stat_count; ++i) {
        const std::string key = stat_keys[i].utf8().get_data();
        const int32_t domain = stat_domains[i];
        const double lo = stat_min[i], hi = stat_max[i];
        if (key.empty() || domain < 0 || domain >= DOMAIN_COUNT ||
            !std::isfinite(lo) || !std::isfinite(hi) || lo > hi ||
            !stat_ids.emplace(key, i).second) {
            error = "modifier_stat_catalog_entry_invalid";
            return false;
        }
        stats.push_back({key, domain, lo, hi, stat_persistable[i] != 0});
    }

    const PackedStringArray definition_keys = catalog.get(
        "definition_keys", PackedStringArray());
    const PackedInt32Array definition_versions = catalog.get(
        "definition_versions", PackedInt32Array());
    const PackedInt32Array definition_domains = catalog.get(
        "definition_domains", PackedInt32Array());
    const PackedInt32Array definition_policies = catalog.get(
        "definition_policies", PackedInt32Array());
    const PackedInt32Array definition_max_stacks = catalog.get(
        "definition_max_stacks", PackedInt32Array());
    const PackedInt32Array definition_default_duration = catalog.get(
        "definition_default_duration", PackedInt32Array());
    const PackedInt32Array term_offsets = catalog.get(
        "definition_term_offsets", PackedInt32Array());
    const PackedInt32Array term_stat_ids = catalog.get("term_stat_ids", PackedInt32Array());
    const PackedInt32Array term_operations = catalog.get("term_operations", PackedInt32Array());
    const PackedFloat64Array term_values = catalog.get("term_values", PackedFloat64Array());
    const int32_t definition_count = definition_keys.size();
    if (definition_count <= 0 || definition_versions.size() != definition_count ||
        definition_domains.size() != definition_count ||
        definition_policies.size() != definition_count ||
        definition_max_stacks.size() != definition_count ||
        definition_default_duration.size() != definition_count ||
        term_offsets.size() != definition_count + 1 ||
        term_stat_ids.size() != term_operations.size() ||
        term_stat_ids.size() != term_values.size() || term_offsets[0] != 0 ||
        term_offsets[definition_count] != term_values.size()) {
        error = "modifier_definition_catalog_shape_invalid";
        return false;
    }

    std::vector<Definition> definitions;
    std::vector<TermDefinition> terms;
    std::unordered_map<std::string, int32_t> definition_ids;
    definitions.reserve(definition_count);
    terms.reserve(term_values.size());
    for (int32_t i = 0; i < definition_count; ++i) {
        const std::string key = definition_keys[i].utf8().get_data();
        const int32_t domain = definition_domains[i];
        const int32_t policy = definition_policies[i];
        const int32_t begin = term_offsets[i], end = term_offsets[i + 1];
        if (key.empty() || definition_versions[i] <= 0 ||
            domain < 0 || domain >= DOMAIN_COUNT || policy < INDEPENDENT ||
            policy > STACK_REFRESH || definition_max_stacks[i] <= 0 ||
            (definition_default_duration[i] != -1 &&
             definition_default_duration[i] <= 0) || begin >= end ||
            !definition_ids.emplace(key, i).second) {
            error = "modifier_definition_catalog_entry_invalid";
            return false;
        }
        Definition definition;
        definition.key = key;
        definition.version = definition_versions[i];
        definition.domain = domain;
        definition.policy = policy;
        definition.max_stacks = definition_max_stacks[i];
        definition.default_duration = definition_default_duration[i];
        definition.term_begin = static_cast<uint32_t>(terms.size());
        for (int32_t term_index = begin; term_index < end; ++term_index) {
            const int32_t sid = term_stat_ids[term_index];
            const int32_t operation = term_operations[term_index];
            const double value = term_values[term_index];
            if (sid < 0 || sid >= stat_count || stats[sid].domain != domain ||
                operation < ADD || operation > DIVIDE || !std::isfinite(value) ||
                (operation == DIVIDE && value == 0.0)) {
                error = "modifier_term_catalog_entry_invalid";
                return false;
            }
            TermDefinition term;
            term.stat_id = sid;
            if (operation == ADD) term.add = value;
            else if (operation == SUBTRACT) term.add = -value;
            else if (operation == MULTIPLY) term.factor = value;
            else term.factor = 1.0 / value;
            if (!std::isfinite(term.add) || !std::isfinite(term.factor)) {
                error = "modifier_term_normalization_invalid";
                return false;
            }
            terms.push_back(term);
        }
        definition.term_count = static_cast<uint32_t>(terms.size()) - definition.term_begin;
        definitions.push_back(std::move(definition));
    }

    uint64_t hash = 1469598103934665603ULL;
    for (const StatDefinition &stat : stats) {
        hash = fnv_string(hash, stat.key);
        hash = fnv_mix(hash, &stat.domain, sizeof(stat.domain));
        hash = fnv_mix(hash, &stat.min_value, sizeof(stat.min_value));
        hash = fnv_mix(hash, &stat.max_value, sizeof(stat.max_value));
    }
    for (const Definition &definition : definitions) {
        hash = fnv_string(hash, definition.key);
        hash = fnv_mix(hash, &definition.version, sizeof(definition.version));
    }
    for (const TermDefinition &term : terms) hash = fnv_mix(hash, &term, sizeof(term));
    uint64_t legacy_hash = 1469598103934665603ULL;
    for (const StatDefinition &stat : stats) {
        if (stat.key.rfind("country.tax.", 0) == 0) continue;
        legacy_hash = fnv_string(legacy_hash, stat.key);
        legacy_hash = fnv_mix(legacy_hash, &stat.domain, sizeof(stat.domain));
        legacy_hash = fnv_mix(legacy_hash, &stat.min_value, sizeof(stat.min_value));
        legacy_hash = fnv_mix(legacy_hash, &stat.max_value, sizeof(stat.max_value));
    }
    for (const Definition &definition : definitions) {
        legacy_hash = fnv_string(legacy_hash, definition.key);
        legacy_hash = fnv_mix(
            legacy_hash, &definition.version, sizeof(definition.version));
    }
    for (const TermDefinition &term : terms)
        legacy_hash = fnv_mix(legacy_hash, &term, sizeof(term));

    _stats = std::move(stats);
    _definitions = std::move(definitions);
    _terms = std::move(terms);
    _stat_ids = std::move(stat_ids);
    _definition_ids = std::move(definition_ids);
    _catalog_hash = hash;
    _legacy_catalog_hash_without_tax = legacy_hash;
    return true;
}

Dictionary ModifierRuntime::configure(const Dictionary &catalog, int32_t cell_count) {
    if (cell_count <= 0) return fail_dict("modifier_cell_count_invalid");
    std::string error;
    if (!compile_catalog(catalog, error)) return fail_dict(error.c_str());
    _cell_count = cell_count;
    _configured = true;
    _current_day = -1;
    _pending_commands.clear();
    _results.clear();
    _events.clear();
    _next_request_id = 1;
    _next_event_id = 1;
    _submit_order = 0;
    _journal_overflow = 0;
    _commands_applied = 0;
    _commands_rejected = 0;
    _expired = 0;
    _last_command_ms = 0.0;
    _last_expiry_ms = 0.0;
    _last_publish_ms = 0.0;
    _last_bucket_update_ms = 0.0;
    _last_bucket_rebuild_ms = 0.0;
    _bucket_update_ms_total = 0.0;
    _bucket_rebuild_ms_total = 0.0;
    _error_counts.clear();
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) clear_domain(domain);
    _gameplay_base_by_stat.assign(_stats.size(), {});
    Dictionary out;
    out["ok"] = true;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["stat_count"] = static_cast<int32_t>(_stats.size());
    out["definition_count"] = static_cast<int32_t>(_definitions.size());
    return out;
}

Dictionary ModifierRuntime::submit_commands(const Dictionary &batch) {
    if (!_configured) return fail_dict("modifier_runtime_not_configured");
    const int32_t protocol = batch.get("protocol_version", 0);
    if (protocol != PROTOCOL_VERSION) return fail_dict("modifier_protocol_unsupported");
    const PackedInt32Array opcodes = batch.get("opcodes", PackedInt32Array());
    const PackedInt32Array producers = batch.get("producer_ids", PackedInt32Array());
    const PackedInt64Array sequences = batch.get("sequences", PackedInt64Array());
    const PackedInt64Array days = batch.get("effective_days", PackedInt64Array());
    const PackedStringArray definition_keys = batch.get("definition_keys", PackedStringArray());
    const PackedInt32Array domains = batch.get("domains", PackedInt32Array());
    const PackedInt32Array scopes = batch.get("scopes", PackedInt32Array());
    const PackedInt64Array entities = batch.get("entity_handles", PackedInt64Array());
    const PackedInt64Array groups = batch.get("group_handles", PackedInt64Array());
    const PackedInt64Array source_types = batch.get("source_types", PackedInt64Array());
    const PackedInt64Array source_ids = batch.get("source_ids", PackedInt64Array());
    const PackedInt32Array durations = batch.get("duration_days", PackedInt32Array());
    const PackedInt32Array stacks = batch.get("stacks", PackedInt32Array());
    const PackedInt64Array handles = batch.get("modifier_handles", PackedInt64Array());
    const int32_t count = opcodes.size();
    if (count <= 0 || producers.size() != count || sequences.size() != count ||
        days.size() != count || definition_keys.size() != count || domains.size() != count ||
        scopes.size() != count || entities.size() != count || groups.size() != count ||
        source_types.size() != count || source_ids.size() != count ||
        durations.size() != count || stacks.size() != count || handles.size() != count) {
        return fail_dict("modifier_command_shape_invalid");
    }
    PackedInt64Array request_ids;
    request_ids.resize(count);
    for (int32_t i = 0; i < count; ++i) {
        Command command;
        command.opcode = opcodes[i];
        command.producer = producers[i];
        command.sequence = sequences[i];
        command.effective_day = days[i];
        command.request_id = _next_request_id++;
        command.definition_id = definition_id(definition_keys[i].utf8().get_data());
        command.domain = domains[i];
        command.scope = scopes[i];
        command.entity_handle = static_cast<uint64_t>(entities[i]);
        command.group_handle = static_cast<uint64_t>(groups[i]);
        command.source_type = static_cast<uint64_t>(source_types[i]);
        command.source_id = static_cast<uint64_t>(source_ids[i]);
        command.duration_days = durations[i];
        command.stacks = stacks[i];
        command.modifier_handle = static_cast<uint64_t>(handles[i]);
        command.submit_order = ++_submit_order;
        request_ids.set(i, command.request_id);
        _pending_commands.push_back(command);
        _results[command.request_id] = {false, "pending", 0, -1};
    }
    Dictionary out;
    out["ok"] = true;
    out["request_ids"] = request_ids;
    out["pending_count"] = static_cast<int64_t>(_pending_commands.size());
    return out;
}

bool ModifierRuntime::should_run(int64_t day_index) const {
    if (!_configured) return false;
    for (const Command &command : _pending_commands)
        if (command.effective_day <= day_index) return true;
    for (const Store &store : _stores)
        if (!store.expiry_heap.empty() && store.expiry_heap.top().day <= day_index) return true;
    return _current_day < day_index;
}

bool ModifierRuntime::valid_identity(const IdentityStore &store, uint64_t handle) const {
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
    return index < store.active.size() && store.active[index] != 0 && generation != 0 &&
        store.generation[index] == generation;
}

bool ModifierRuntime::validate_target(const Command &command, std::string &error) const {
    if (command.domain < 0 || command.domain >= DOMAIN_COUNT ||
        command.scope < GLOBAL || command.scope > ENTITY) {
        error = "modifier_target_shape_invalid";
        return false;
    }
    if (command.scope == GROUP && command.group_handle == 0) {
        error = "modifier_group_target_missing";
        return false;
    }
    if (command.domain == ECONOMY && command.group_handle != 0 &&
        _country_runtime != nullptr &&
        !_country_runtime->valid_handle(static_cast<int64_t>(command.group_handle))) {
        error = "modifier_country_group_handle_stale";
        return false;
    }
    if (command.scope == ENTITY && command.entity_handle == 0 && command.domain != CLIMATE) {
        error = "modifier_entity_target_missing";
        return false;
    }
    if (command.scope == ENTITY) {
        if (command.domain == CLIMATE && command.entity_handle >= static_cast<uint64_t>(_cell_count)) {
            error = "modifier_cell_target_invalid";
            return false;
        }
        if (command.domain == COUNTRY && _country_runtime != nullptr &&
            !_country_runtime->valid_handle(static_cast<int64_t>(command.entity_handle))) {
            error = "modifier_country_handle_stale";
            return false;
        }
        if (command.domain == ECONOMY && !valid_identity(_building_identities, command.entity_handle)) {
            error = "modifier_building_handle_stale";
            return false;
        }
        if (command.domain == GAMEPLAY && !valid_identity(_gameplay_identities, command.entity_handle)) {
            error = "modifier_gameplay_handle_stale";
            return false;
        }
    }
    return true;
}

uint64_t ModifierRuntime::make_handle(const Store &store, uint32_t index) const {
    return (static_cast<uint64_t>(store.generation[index]) << 32U) | index;
}

bool ModifierRuntime::resolve_handle(const Store &store, uint64_t handle,
                                     uint32_t &index) const {
    index = static_cast<uint32_t>(handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(handle >> 32U);
    return index < store.active.size() && store.active[index] != 0 && generation != 0 &&
        store.generation[index] == generation;
}

uint64_t ModifierRuntime::scope_id_for(const Command &command) const {
    if (command.scope == GLOBAL) return 0;
    return command.scope == GROUP ? command.group_handle : command.entity_handle;
}

double ModifierRuntime::scaled_add(const TermDefinition &term, int32_t stacks) const {
    return term.add * static_cast<double>(stacks);
}

double ModifierRuntime::scaled_factor(const TermDefinition &term, int32_t stacks) const {
    return std::pow(term.factor, static_cast<double>(stacks));
}

double ModifierRuntime::bucket_factor(const Bucket &bucket) const {
    return bucket.zero_factor_count > 0 ? 0.0 : bucket.product_nonzero;
}

void ModifierRuntime::rebuild_bucket(int32_t domain, const BucketKey &key,
                                     Bucket &bucket) {
    const auto start = std::chrono::steady_clock::now();
    Store &store = _stores[domain];
    bucket.sum_add = 0.0;
    bucket.product_nonzero = 1.0;
    bucket.zero_factor_count = 0;
    std::vector<Contribution> live;
    live.reserve(bucket.members.size());
    for (const Contribution contribution : bucket.members) {
        if (contribution.instance >= store.active.size() ||
            store.active[contribution.instance] == 0) continue;
        const Definition &definition = _definitions[store.definition_id[contribution.instance]];
        if (contribution.term >= definition.term_count) continue;
        const TermDefinition &term = _terms[definition.term_begin + contribution.term];
        if (term.stat_id != key.stat_id) continue;
        const int32_t stacks = store.stacks[contribution.instance];
        bucket.sum_add += scaled_add(term, stacks);
        const double factor = scaled_factor(term, stacks);
        if (factor == 0.0) ++bucket.zero_factor_count;
        else bucket.product_nonzero *= factor;
        live.push_back(contribution);
    }
    bucket.members.swap(live);
    bucket.mutations_since_rebuild = 0;
    ++store.bucket_rebuilds;
    const double duration_ms = elapsed_ms(start);
    _last_bucket_rebuild_ms += duration_ms;
    _bucket_rebuild_ms_total += duration_ms;
}

void ModifierRuntime::add_instance_to_buckets(int32_t domain, uint32_t index) {
    const auto start = std::chrono::steady_clock::now();
    Store &store = _stores[domain];
    const Definition &definition = _definitions[store.definition_id[index]];
    const uint64_t scope_id = store.scope[index] == GLOBAL ? 0 :
        (store.scope[index] == GROUP ? store.group_handle[index] : store.entity_handle[index]);
    for (uint32_t term_offset = 0; term_offset < definition.term_count; ++term_offset) {
        const TermDefinition &term = _terms[definition.term_begin + term_offset];
        const BucketKey key{term.stat_id, store.scope[index], scope_id};
        Bucket &bucket = store.buckets[key];
        bucket.members.push_back({index, static_cast<uint16_t>(term_offset)});
        bucket.sum_add += scaled_add(term, store.stacks[index]);
        const double factor = scaled_factor(term, store.stacks[index]);
        if (factor == 0.0) ++bucket.zero_factor_count;
        else bucket.product_nonzero *= factor;
        if (++bucket.mutations_since_rebuild >= BUCKET_REBUILD_INTERVAL ||
            !std::isfinite(bucket.sum_add) || !std::isfinite(bucket.product_nonzero)) {
            rebuild_bucket(domain, key, bucket);
        }
    }
    const double duration_ms = elapsed_ms(start);
    _last_bucket_update_ms += duration_ms;
    _bucket_update_ms_total += duration_ms;
}

void ModifierRuntime::remove_instance_from_buckets(int32_t domain, uint32_t index) {
    const auto start = std::chrono::steady_clock::now();
    Store &store = _stores[domain];
    const Definition &definition = _definitions[store.definition_id[index]];
    const uint64_t scope_id = store.scope[index] == GLOBAL ? 0 :
        (store.scope[index] == GROUP ? store.group_handle[index] : store.entity_handle[index]);
    for (uint32_t term_offset = 0; term_offset < definition.term_count; ++term_offset) {
        const TermDefinition &term = _terms[definition.term_begin + term_offset];
        const BucketKey key{term.stat_id, store.scope[index], scope_id};
        auto it = store.buckets.find(key);
        if (it == store.buckets.end()) continue;
        Bucket &bucket = it->second;
        bucket.sum_add -= scaled_add(term, store.stacks[index]);
        const double factor = scaled_factor(term, store.stacks[index]);
        if (factor == 0.0) --bucket.zero_factor_count;
        else bucket.product_nonzero /= factor;
        bucket.members.erase(std::remove_if(bucket.members.begin(), bucket.members.end(),
            [&](const Contribution &entry) {
                return entry.instance == index && entry.term == term_offset;
            }), bucket.members.end());
        if (bucket.members.empty()) store.buckets.erase(it);
        else if (++bucket.mutations_since_rebuild >= BUCKET_REBUILD_INTERVAL ||
                 !std::isfinite(bucket.sum_add) || !std::isfinite(bucket.product_nonzero))
            rebuild_bucket(domain, key, bucket);
    }
    const double duration_ms = elapsed_ms(start);
    _last_bucket_update_ms += duration_ms;
    _bucket_update_ms_total += duration_ms;
}

void ModifierRuntime::push_event(Event event) {
    if (event.domain >= 0 && event.domain < DOMAIN_COUNT) {
        Store &store = _stores[event.domain];
        if (event.kind == EVENT_APPLY || event.kind == EVENT_REPLACE ||
            event.kind == EVENT_STACK || event.kind == EVENT_REFRESH) {
            ++store.apply_events;
        } else if (event.kind == EVENT_REMOVE) {
            ++store.remove_events;
        } else if (event.kind == EVENT_EXPIRE) {
            ++store.expire_events;
        } else if (event.kind == EVENT_REJECT) {
            ++store.reject_events;
        } else if (event.kind == EVENT_TARGET_CLEANUP) {
            ++store.target_cleanup_events;
        }
    }
    if (event.kind == EVENT_REJECT && !event.reason.empty()) record_error(event.reason);
    event.id = _next_event_id++;
    _events.push_back(std::move(event));
    while (_events.size() > JOURNAL_CAPACITY) {
        _events.pop_front();
        ++_journal_overflow;
    }
}

void ModifierRuntime::reject_command(const Command &command, int64_t day,
                                     const std::string &reason) {
    _results[command.request_id] = {false, reason, 0, day};
    ++_commands_rejected;
    push_event({0, day, EVENT_REJECT, command.domain, command.modifier_handle,
        command.definition_id, command.entity_handle, command.group_handle,
        command.scope, command.source_type, command.source_id, 0, 0,
        command.request_id, reason});
}

uint64_t ModifierRuntime::apply_command(const Command &command, int64_t day,
                                        Result &result) {
    if (command.definition_id < 0 ||
        command.definition_id >= static_cast<int32_t>(_definitions.size())) {
        result = {false, "modifier_definition_unknown", 0, day};
        return 0;
    }
    const Definition &definition = _definitions[command.definition_id];
    if (definition.domain != command.domain) {
        result = {false, "modifier_definition_domain_mismatch", 0, day};
        return 0;
    }
    std::string target_error;
    if (!validate_target(command, target_error)) {
        result = {false, target_error, 0, day};
        return 0;
    }
    const int32_t duration = command.duration_days == -2
        ? definition.default_duration : command.duration_days;
    if (duration != -1 && duration <= 0) {
        result = {false, "modifier_duration_invalid", 0, day};
        return 0;
    }
    const int32_t requested_stacks = std::clamp(command.stacks, 1, definition.max_stacks);
    Store &store = _stores[command.domain];
    const UniqueKey unique{command.definition_id, command.scope,
        scope_id_for(command), command.source_type, command.source_id};
    if (definition.policy != INDEPENDENT) {
        const auto existing = store.unique_instances.find(unique);
        if (existing != store.unique_instances.end() &&
            existing->second < store.active.size() && store.active[existing->second] != 0) {
            const uint32_t index = existing->second;
            remove_instance_from_buckets(command.domain, index);
            const int32_t old_stacks = store.stacks[index];
            store.stacks[index] = definition.policy == STACK_REFRESH
                ? std::min(definition.max_stacks, old_stacks + requested_stacks)
                : requested_stacks;
            store.applied_day[index] = day;
            store.expiry_day[index] = duration < 0 ? PERMANENT_EXPIRY : day + duration;
            ++store.expiry_revision[index];
            if (store.expiry_day[index] >= 0) store.expiry_heap.push({
                store.expiry_day[index], index, store.generation[index],
                store.expiry_revision[index]});
            add_instance_to_buckets(command.domain, index);
            ++store.snapshot_version;
            const uint64_t handle = make_handle(store, index);
            result = {true, "", handle, day};
            push_event({0, day,
                definition.policy == STACK_REFRESH ? EVENT_STACK : EVENT_REPLACE,
                command.domain, handle, command.definition_id, command.entity_handle,
                command.group_handle, command.scope, command.source_type,
                command.source_id, old_stacks,
                store.stacks[index], command.request_id, ""});
            return handle;
        }
    }

    uint32_t index = 0;
    if (!store.free_list.empty()) {
        index = store.free_list.back();
        store.free_list.pop_back();
        if (++store.generation[index] == 0) store.generation[index] = 1;
    } else {
        index = static_cast<uint32_t>(store.active.size());
        store.active.push_back(0);
        store.generation.push_back(1);
        store.definition_id.push_back(-1);
        store.entity_handle.push_back(0);
        store.group_handle.push_back(0);
        store.source_type.push_back(0);
        store.source_id.push_back(0);
        store.scope.push_back(GLOBAL);
        store.stacks.push_back(1);
        store.applied_day.push_back(-1);
        store.expiry_day.push_back(PERMANENT_EXPIRY);
        store.expiry_revision.push_back(0);
    }
    store.active[index] = 1;
    store.definition_id[index] = command.definition_id;
    store.entity_handle[index] = command.entity_handle;
    store.group_handle[index] = command.group_handle;
    store.source_type[index] = command.source_type;
    store.source_id[index] = command.source_id;
    store.scope[index] = command.scope;
    store.stacks[index] = requested_stacks;
    store.applied_day[index] = day;
    store.expiry_day[index] = duration < 0 ? PERMANENT_EXPIRY : day + duration;
    ++store.expiry_revision[index];
    if (store.expiry_day[index] >= 0) store.expiry_heap.push({store.expiry_day[index],
        index, store.generation[index], store.expiry_revision[index]});
    if (definition.policy != INDEPENDENT) store.unique_instances[unique] = index;
    add_instance_to_buckets(command.domain, index);
    ++store.active_instances;
    store.peak_instances = std::max(store.peak_instances, store.active_instances);
    ++store.snapshot_version;
    const uint64_t handle = make_handle(store, index);
    result = {true, "", handle, day};
    push_event({0, day, EVENT_APPLY, command.domain, handle,
        command.definition_id, command.entity_handle, command.group_handle,
        command.scope, command.source_type, command.source_id, 0,
        requested_stacks, command.request_id, ""});
    return handle;
}

bool ModifierRuntime::remove_handle(int32_t domain, uint64_t handle, int64_t day,
                                    int32_t event_kind, int64_t request_id,
                                    const std::string &reason, Result *result) {
    if (domain < 0 || domain >= DOMAIN_COUNT) {
        if (result) *result = {false, "modifier_domain_invalid", 0, day};
        return false;
    }
    Store &store = _stores[domain];
    uint32_t index = 0;
    if (!resolve_handle(store, handle, index)) {
        if (result) *result = {false, "modifier_handle_stale", 0, day};
        return false;
    }
    const int32_t definition_id_value = store.definition_id[index];
    const Definition &definition = _definitions[definition_id_value];
    const int32_t old_stacks = store.stacks[index];
    if (definition.policy != INDEPENDENT) {
        const uint64_t sid = store.scope[index] == GLOBAL ? 0 :
            (store.scope[index] == GROUP ? store.group_handle[index] : store.entity_handle[index]);
        store.unique_instances.erase({definition_id_value, store.scope[index], sid,
            store.source_type[index], store.source_id[index]});
    }
    remove_instance_from_buckets(domain, index);
    const uint64_t entity = store.entity_handle[index];
    const uint64_t group = store.group_handle[index];
    const int32_t scope = store.scope[index];
    const uint64_t source_type = store.source_type[index];
    const uint64_t source_id = store.source_id[index];
    store.active[index] = 0;
    store.free_list.push_back(index);
    --store.active_instances;
    ++store.snapshot_version;
    if (result) *result = {true, "", handle, day};
    push_event({0, day, event_kind, domain, handle, definition_id_value, entity,
        group, scope, source_type, source_id, old_stacks, 0, request_id, reason});
    return true;
}

bool ModifierRuntime::refresh_handle(const Command &command, int64_t day,
                                     Result &result) {
    if (command.domain < 0 || command.domain >= DOMAIN_COUNT) {
        result = {false, "modifier_domain_invalid", 0, day};
        return false;
    }
    Store &store = _stores[command.domain];
    uint32_t index = 0;
    if (!resolve_handle(store, command.modifier_handle, index)) {
        result = {false, "modifier_handle_stale", 0, day};
        return false;
    }
    if (command.duration_days != -1 && command.duration_days <= 0) {
        result = {false, "modifier_duration_invalid", 0, day};
        return false;
    }
    store.applied_day[index] = day;
    store.expiry_day[index] = command.duration_days < 0 ? PERMANENT_EXPIRY :
        day + command.duration_days;
    ++store.expiry_revision[index];
    if (store.expiry_day[index] >= 0) store.expiry_heap.push({store.expiry_day[index],
        index, store.generation[index], store.expiry_revision[index]});
    ++store.snapshot_version;
    result = {true, "", command.modifier_handle, day};
    push_event({0, day, EVENT_REFRESH, command.domain, command.modifier_handle,
        store.definition_id[index], store.entity_handle[index], store.group_handle[index],
        store.scope[index], store.source_type[index], store.source_id[index],
        store.stacks[index], store.stacks[index], command.request_id, ""});
    return true;
}

bool ModifierRuntime::set_stacks(const Command &command, int64_t day,
                                 Result &result) {
    if (command.domain < 0 || command.domain >= DOMAIN_COUNT) {
        result = {false, "modifier_domain_invalid", 0, day};
        return false;
    }
    Store &store = _stores[command.domain];
    uint32_t index = 0;
    if (!resolve_handle(store, command.modifier_handle, index)) {
        result = {false, "modifier_handle_stale", 0, day};
        return false;
    }
    const Definition &definition = _definitions[store.definition_id[index]];
    if (command.stacks <= 0 || command.stacks > definition.max_stacks) {
        result = {false, "modifier_stack_count_invalid", 0, day};
        return false;
    }
    const int32_t old_stacks = store.stacks[index];
    remove_instance_from_buckets(command.domain, index);
    store.stacks[index] = command.stacks;
    add_instance_to_buckets(command.domain, index);
    ++store.snapshot_version;
    result = {true, "", command.modifier_handle, day};
    push_event({0, day, EVENT_STACK, command.domain, command.modifier_handle,
        store.definition_id[index], store.entity_handle[index], store.group_handle[index],
        store.scope[index], store.source_type[index], store.source_id[index],
        old_stacks, command.stacks, command.request_id, ""});
    return true;
}

Dictionary ModifierRuntime::run_daily(int64_t day_index) {
    if (!_configured) return fail_dict("modifier_runtime_not_configured");
    if (day_index < _current_day) return fail_dict("modifier_day_regression");
    _last_bucket_update_ms = 0.0;
    _last_bucket_rebuild_ms = 0.0;
    const auto expiry_start = std::chrono::steady_clock::now();
    int64_t expired_count = 0;
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain) {
        Store &store = _stores[domain];
        while (!store.expiry_heap.empty() && store.expiry_heap.top().day <= day_index) {
            const ExpiryNode node = store.expiry_heap.top();
            store.expiry_heap.pop();
            if (node.index >= store.active.size() || store.active[node.index] == 0 ||
                store.generation[node.index] != node.generation ||
                store.expiry_revision[node.index] != node.revision ||
                store.expiry_day[node.index] != node.day) continue;
            const uint64_t handle = make_handle(store, node.index);
            if (remove_handle(domain, handle, day_index, EVENT_EXPIRE, 0, "expired")) {
                ++expired_count;
                ++_expired;
            }
        }
    }
    _last_expiry_ms = elapsed_ms(expiry_start);

    const auto command_start = std::chrono::steady_clock::now();
    std::stable_sort(_pending_commands.begin(), _pending_commands.end(),
        [](const Command &a, const Command &b) {
            if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
            if (a.producer != b.producer) return a.producer < b.producer;
            if (a.sequence != b.sequence) return a.sequence < b.sequence;
            return a.submit_order < b.submit_order;
        });
    std::vector<Command> retained;
    retained.reserve(_pending_commands.size());
    int64_t applied_count = 0;
    for (const Command &command : _pending_commands) {
        if (command.effective_day > day_index) {
            retained.push_back(command);
            continue;
        }
        Result result;
        bool ok = false;
        if (command.opcode == COMMAND_APPLY) {
            ok = apply_command(command, day_index, result) != 0;
        } else if (command.opcode == COMMAND_REMOVE) {
            ok = remove_handle(command.domain, command.modifier_handle, day_index,
                EVENT_REMOVE, command.request_id, "removed", &result);
        } else if (command.opcode == COMMAND_REFRESH) {
            ok = refresh_handle(command, day_index, result);
        } else if (command.opcode == COMMAND_SET_STACKS) {
            ok = set_stacks(command, day_index, result);
        } else {
            result = {false, "modifier_command_opcode_invalid", 0, day_index};
        }
        _results[command.request_id] = result;
        if (ok) {
            ++applied_count;
            ++_commands_applied;
        } else {
            ++_commands_rejected;
            push_event({0, day_index, EVENT_REJECT, command.domain,
                command.modifier_handle, command.definition_id, command.entity_handle,
                command.group_handle, command.scope, command.source_type,
                command.source_id, 0, 0,
                command.request_id, result.reason});
        }
    }
    _pending_commands.swap(retained);
    _last_command_ms = elapsed_ms(command_start);
    const auto publish_start = std::chrono::steady_clock::now();
    _current_day = day_index;
    _last_publish_ms = elapsed_ms(publish_start);
    Dictionary out = report();
    out["ok"] = true;
    out["done"] = true;
    out["path"] = "MODIFIER_GRAPH";
    out["stage"] = "modifier_publish";
    out["day_index"] = day_index;
    out["commands_applied"] = applied_count;
    out["expired"] = expired_count;
    out["work_done"] = applied_count + expired_count;
    return out;
}

double ModifierRuntime::effective_value(int32_t domain, int32_t sid,
                                        uint64_t entity_handle,
                                        uint64_t group_handle,
                                        double base_value) const {
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT || sid < 0 ||
        sid >= static_cast<int32_t>(_stats.size()) || _stats[sid].domain != domain ||
        !std::isfinite(base_value)) return base_value;
    const Store &store = _stores[domain];
    ++store.query_count;
    double add = 0.0;
    double factor = 1.0;
    const BucketKey keys[3] = {{sid, GLOBAL, 0}, {sid, GROUP, group_handle},
                               {sid, ENTITY, entity_handle}};
    for (int i = 0; i < 3; ++i) {
        if (i == 1 && group_handle == 0) continue;
        const auto it = store.buckets.find(keys[i]);
        if (it == store.buckets.end()) continue;
        ++store.bucket_reads;
        add += it->second.sum_add;
        factor *= bucket_factor(it->second);
    }
    double value = (base_value + add) * factor;
    if (!std::isfinite(value)) value = value < 0.0 ? _stats[sid].min_value : _stats[sid].max_value;
    return std::clamp(value, _stats[sid].min_value, _stats[sid].max_value);
}

double ModifierRuntime::effective_value(int32_t domain, const char *key,
                                        uint64_t entity_handle,
                                        uint64_t group_handle,
                                        double base_value) const {
    return effective_value(domain, stat_id(key), entity_handle, group_handle, base_value);
}

void ModifierRuntime::effective_values(int32_t domain, const int32_t *stat_ids,
                                       uint64_t entity_handle,
                                       const int8_t *base_values,
                                       int8_t *out_values, size_t count) const {
    if (stat_ids == nullptr || base_values == nullptr || out_values == nullptr) return;
    for (size_t i = 0; i < count; ++i) {
        const double value = effective_value(domain, stat_ids[i], entity_handle, 0,
                                             base_values[i]);
        const int32_t rounded = static_cast<int32_t>(std::round(value));
        out_values[i] = static_cast<int8_t>(std::clamp(rounded, -100, 100));
    }
}

float ModifierRuntime::climate_radiative_target(int32_t cell, float base_value) const {
    return static_cast<float>(effective_value(CLIMATE, "climate.cell.radiative_target",
        static_cast<uint64_t>(std::max(0, cell)), 0, base_value));
}

void ModifierRuntime::climate_radiative_terms(int32_t cell, double &add,
                                               double &factor) const {
    add = 0.0;
    factor = 1.0;
    const int32_t sid = stat_id("climate.cell.radiative_target");
    if (!_configured || sid < 0) return;
    const Store &store = _stores[CLIMATE];
    const BucketKey keys[2] = {
        {sid, GLOBAL, 0},
        {sid, ENTITY, static_cast<uint64_t>(std::max(0, cell))},
    };
    for (const BucketKey &key : keys) {
        const auto it = store.buckets.find(key);
        if (it == store.buckets.end()) continue;
        add += it->second.sum_add;
        factor *= bucket_factor(it->second);
    }
}

double ModifierRuntime::country_economy_output_factor(uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.economy_output_factor", country_handle,
                           0, 1.0);
}

double ModifierRuntime::country_sector_output_factor(
        uint64_t country_handle, int32_t economic_sector) const {
    static const char *SECTOR_STATS[5] = {
        "country.output.agriculture_factor",
        "country.output.extractive_factor",
        "country.output.manufacturing_factor",
        "country.output.energy_factor",
        "country.output.knowledge_factor",
    };
    if (economic_sector < 0 || economic_sector >= 5) return 1.0;
    return effective_value(COUNTRY, SECTOR_STATS[economic_sector],
                           country_handle, 0, 1.0);
}

double ModifierRuntime::country_research_institution_output_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY,
        "country.research.institution_output_factor",
        country_handle, 0, 1.0);
}

double ModifierRuntime::country_trade_capacity_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.trade.capacity_factor",
                           country_handle, 0, 1.0);
}

double ModifierRuntime::country_trade_speed_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.trade.speed_factor",
                           country_handle, 0, 1.0);
}

double ModifierRuntime::country_construction_cost_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.construction.cost_factor",
                           country_handle, 0, 1.0);
}

double ModifierRuntime::country_construction_time_factor(
        uint64_t country_handle) const {
    return effective_value(COUNTRY, "country.construction.time_factor",
                           country_handle, 0, 1.0);
}

bool ModifierRuntime::apply_technology_effect(uint64_t country_handle,
                                              const std::string &definition_key,
                                              int32_t technology_id,
                                              int64_t day_index,
                                              std::string &error) {
    if (!_configured) {
        error = "modifier_not_configured";
        return false;
    }
    const int32_t definition = definition_id(definition_key);
    if (definition < 0 || _definitions[static_cast<size_t>(definition)].domain != COUNTRY) {
        error = "technology_modifier_definition_unknown";
        return false;
    }
    Command command;
    command.opcode = COMMAND_APPLY;
    command.definition_id = definition;
    command.domain = COUNTRY;
    command.scope = ENTITY;
    command.entity_handle = country_handle;
    command.source_type = 0x54454348ULL; // "TECH"
    command.source_id = static_cast<uint64_t>(technology_id + 1);
    command.duration_days = PERMANENT_EXPIRY;
    command.stacks = 1;
    command.effective_day = day_index;
    Result result;
    apply_command(command, day_index, result);
    if (!result.ok) {
        error = result.reason;
        return false;
    }
    _current_day = std::max(_current_day, day_index);
    return true;
}

double ModifierRuntime::economy_building_output_factor(uint64_t building_handle,
                                                        uint64_t country_handle) const {
    return effective_value(ECONOMY, "economy.building.output_factor",
                           building_handle, country_handle, 1.0);
}

Dictionary ModifierRuntime::command_result(int64_t request_id) const {
    const auto it = _results.find(request_id);
    if (it == _results.end()) return fail_dict("modifier_request_unknown");
    Dictionary out;
    out["ok"] = it->second.ok;
    out["reason"] = String(it->second.reason.c_str());
    out["modifier_handle"] = static_cast<int64_t>(it->second.handle);
    out["day"] = it->second.day;
    out["pending"] = it->second.reason == "pending";
    return out;
}

Dictionary ModifierRuntime::list_modifiers(int32_t domain, uint64_t entity_handle,
                                           const String &stat_key_value) const {
    if (domain < 0 || domain >= DOMAIN_COUNT) return fail_dict("modifier_domain_invalid");
    const int32_t filter_stat = stat_key_value.is_empty() ? -1 :
        stat_id(stat_key_value.utf8().get_data());
    if (!stat_key_value.is_empty() && filter_stat < 0)
        return fail_dict("modifier_stat_unknown");
    PackedInt64Array handles, entities, groups, source_types, source_ids, applied, expiry;
    PackedInt32Array scopes, stacks, versions;
    PackedStringArray definitions;
    const Store &store = _stores[domain];
    for (uint32_t index = 0; index < store.active.size(); ++index) {
        if (store.active[index] == 0 ||
            (entity_handle != 0 && store.entity_handle[index] != entity_handle)) continue;
        const Definition &definition = _definitions[store.definition_id[index]];
        if (filter_stat >= 0) {
            bool found = false;
            for (uint32_t t = 0; t < definition.term_count; ++t)
                found = found || _terms[definition.term_begin + t].stat_id == filter_stat;
            if (!found) continue;
        }
        handles.push_back(static_cast<int64_t>(make_handle(store, index)));
        definitions.push_back(definition.key.c_str());
        versions.push_back(definition.version);
        entities.push_back(static_cast<int64_t>(store.entity_handle[index]));
        groups.push_back(static_cast<int64_t>(store.group_handle[index]));
        source_types.push_back(static_cast<int64_t>(store.source_type[index]));
        source_ids.push_back(static_cast<int64_t>(store.source_id[index]));
        scopes.push_back(store.scope[index]);
        stacks.push_back(store.stacks[index]);
        applied.push_back(store.applied_day[index]);
        expiry.push_back(store.expiry_day[index]);
    }
    Dictionary out;
    out["ok"] = true;
    out["handles"] = handles;
    out["definition_keys"] = definitions;
    out["definition_versions"] = versions;
    out["entity_handles"] = entities;
    out["group_handles"] = groups;
    out["source_types"] = source_types;
    out["source_ids"] = source_ids;
    out["scopes"] = scopes;
    out["stacks"] = stacks;
    out["applied_days"] = applied;
    out["expiry_days"] = expiry;
    return out;
}

Dictionary ModifierRuntime::explain(int32_t domain, uint64_t entity_handle,
                                    uint64_t group_handle, const String &stat_key_value,
                                    double base_value) const {
    const int32_t sid = stat_id(stat_key_value.utf8().get_data());
    if (sid < 0 || domain < 0 || domain >= DOMAIN_COUNT || _stats[sid].domain != domain)
        return fail_dict("modifier_stat_unknown_or_domain_mismatch");
    PackedInt64Array handles;
    PackedInt32Array scopes, stacks;
    PackedFloat64Array adds, factors;
    PackedStringArray definitions;
    double sum_add = 0.0, product_factor = 1.0;
    const Store &store = _stores[domain];
    for (uint32_t index = 0; index < store.active.size(); ++index) {
        if (store.active[index] == 0) continue;
        const bool in_scope = store.scope[index] == GLOBAL ||
            (store.scope[index] == GROUP && store.group_handle[index] == group_handle) ||
            (store.scope[index] == ENTITY && store.entity_handle[index] == entity_handle);
        if (!in_scope) continue;
        const Definition &definition = _definitions[store.definition_id[index]];
        for (uint32_t term_offset = 0; term_offset < definition.term_count; ++term_offset) {
            const TermDefinition &term = _terms[definition.term_begin + term_offset];
            if (term.stat_id != sid) continue;
            const double add = scaled_add(term, store.stacks[index]);
            const double factor = scaled_factor(term, store.stacks[index]);
            handles.push_back(static_cast<int64_t>(make_handle(store, index)));
            definitions.push_back(definition.key.c_str());
            scopes.push_back(store.scope[index]);
            stacks.push_back(store.stacks[index]);
            adds.push_back(add);
            factors.push_back(factor);
            sum_add += add;
            product_factor *= factor;
        }
    }
    Dictionary out;
    out["ok"] = true;
    out["stat_key"] = stat_key_value;
    out["base_value"] = base_value;
    out["sum_add"] = sum_add;
    out["product_factor"] = product_factor;
    out["unclamped_value"] = (base_value + sum_add) * product_factor;
    out["effective_value"] = effective_value(domain, sid, entity_handle, group_handle, base_value);
    out["clamp_min"] = _stats[sid].min_value;
    out["clamp_max"] = _stats[sid].max_value;
    out["handles"] = handles;
    out["definition_keys"] = definitions;
    out["scopes"] = scopes;
    out["stacks"] = stacks;
    out["adds"] = adds;
    out["factors"] = factors;
    return out;
}

uint64_t ModifierRuntime::estimated_store_bytes(int32_t domain) const {
    if (domain < 0 || domain >= DOMAIN_COUNT) return 0;
    const Store &store = _stores[domain];
    uint64_t bytes = 0;
#define PK_CAPACITY_BYTES(field) bytes += static_cast<uint64_t>(store.field.capacity()) * sizeof(typename decltype(store.field)::value_type)
    PK_CAPACITY_BYTES(active);
    PK_CAPACITY_BYTES(generation);
    PK_CAPACITY_BYTES(definition_id);
    PK_CAPACITY_BYTES(entity_handle);
    PK_CAPACITY_BYTES(group_handle);
    PK_CAPACITY_BYTES(source_type);
    PK_CAPACITY_BYTES(source_id);
    PK_CAPACITY_BYTES(scope);
    PK_CAPACITY_BYTES(stacks);
    PK_CAPACITY_BYTES(applied_day);
    PK_CAPACITY_BYTES(expiry_day);
    PK_CAPACITY_BYTES(expiry_revision);
    PK_CAPACITY_BYTES(free_list);
#undef PK_CAPACITY_BYTES
    bytes += static_cast<uint64_t>(store.expiry_heap.size()) * sizeof(ExpiryNode);
    bytes += static_cast<uint64_t>(store.unique_instances.size()) *
        (sizeof(UniqueKey) + sizeof(uint32_t) + sizeof(void *) * 2);
    bytes += static_cast<uint64_t>(store.buckets.size()) *
        (sizeof(BucketKey) + sizeof(Bucket) + sizeof(void *) * 2);
    for (const auto &entry : store.buckets)
        bytes += static_cast<uint64_t>(entry.second.members.capacity()) * sizeof(Contribution);
    const IdentityStore *identities = domain == ECONOMY ? &_building_identities :
        (domain == GAMEPLAY ? &_gameplay_identities : nullptr);
    if (identities != nullptr) {
        bytes += identities->active.capacity() * sizeof(uint8_t);
        bytes += identities->generation.capacity() * sizeof(uint32_t);
        bytes += identities->labels.capacity() * sizeof(std::string);
        bytes += identities->free_list.capacity() * sizeof(uint32_t);
        for (const std::string &label : identities->labels) bytes += label.capacity();
    }
    if (domain == GAMEPLAY) {
        bytes += _gameplay_base_by_stat.capacity() * sizeof(std::vector<double>);
        for (const std::vector<double> &values : _gameplay_base_by_stat)
            bytes += values.capacity() * sizeof(double);
    }
    return bytes;
}

void ModifierRuntime::record_error(const std::string &reason) const {
    if (!reason.empty()) ++_error_counts[reason];
}

Dictionary ModifierRuntime::report() const {
    Dictionary out;
    out["configured"] = _configured;
    out["protocol_version"] = PROTOCOL_VERSION;
    out["save_schema_version"] = SAVE_SCHEMA_VERSION;
    out["catalog_hash"] = static_cast<int64_t>(_catalog_hash);
    out["current_day"] = _current_day;
    out["pending_commands"] = static_cast<int64_t>(_pending_commands.size());
    out["commands_applied_total"] = static_cast<int64_t>(_commands_applied);
    out["commands_rejected_total"] = static_cast<int64_t>(_commands_rejected);
    out["expired_total"] = static_cast<int64_t>(_expired);
    out["journal_overflow"] = static_cast<int64_t>(_journal_overflow);
    out["journal_version"] = 2;
    out["command_merge_ms"] = _last_command_ms;
    out["expiry_ms"] = _last_expiry_ms;
    out["snapshot_publish_ms"] = _last_publish_ms;
    out["bucket_update_ms"] = _last_bucket_update_ms;
    out["bucket_rebuild_ms"] = _last_bucket_rebuild_ms;
    out["bucket_update_ms_total"] = _bucket_update_ms_total;
    out["bucket_rebuild_ms_total"] = _bucket_rebuild_ms_total;
    PackedInt64Array active, peak, buckets, queries, bucket_reads, rebuilds, versions,
        apply_events, remove_events, expire_events, reject_events, cleanup_events,
        estimated_memory;
    for (const Store &store : _stores) {
        active.push_back(static_cast<int64_t>(store.active_instances));
        peak.push_back(static_cast<int64_t>(store.peak_instances));
        buckets.push_back(static_cast<int64_t>(store.buckets.size()));
        queries.push_back(static_cast<int64_t>(store.query_count));
        bucket_reads.push_back(static_cast<int64_t>(store.bucket_reads));
        rebuilds.push_back(static_cast<int64_t>(store.bucket_rebuilds));
        versions.push_back(static_cast<int64_t>(store.snapshot_version));
        apply_events.push_back(static_cast<int64_t>(store.apply_events));
        remove_events.push_back(static_cast<int64_t>(store.remove_events));
        expire_events.push_back(static_cast<int64_t>(store.expire_events));
        reject_events.push_back(static_cast<int64_t>(store.reject_events));
        cleanup_events.push_back(static_cast<int64_t>(store.target_cleanup_events));
    }
    for (int32_t domain = 0; domain < DOMAIN_COUNT; ++domain)
        estimated_memory.push_back(static_cast<int64_t>(estimated_store_bytes(domain)));
    out["active_instances_by_domain"] = active;
    out["peak_instances_by_domain"] = peak;
    out["bucket_count_by_domain"] = buckets;
    out["query_count_by_domain"] = queries;
    out["bucket_reads_by_domain"] = bucket_reads;
    out["bucket_rebuilds_by_domain"] = rebuilds;
    out["snapshot_versions"] = versions;
    out["apply_events_by_domain"] = apply_events;
    out["remove_events_by_domain"] = remove_events;
    out["expire_events_by_domain"] = expire_events;
    out["reject_events_by_domain"] = reject_events;
    out["target_cleanup_events_by_domain"] = cleanup_events;
    out["estimated_memory_bytes_by_domain"] = estimated_memory;
    std::vector<std::pair<std::string, uint64_t>> errors(_error_counts.begin(),
                                                         _error_counts.end());
    std::sort(errors.begin(), errors.end(), [](const auto &a, const auto &b) {
        return a.first < b.first;
    });
    PackedStringArray error_reasons;
    PackedInt64Array error_counts;
    for (const auto &entry : errors) {
        error_reasons.push_back(entry.first.c_str());
        error_counts.push_back(static_cast<int64_t>(entry.second));
    }
    out["error_reasons"] = error_reasons;
    out["error_counts"] = error_counts;
    return out;
}

Dictionary ModifierRuntime::poll_events(int64_t after_event_id, int32_t limit) const {
    limit = std::clamp(limit, 1, 512);
    PackedInt64Array ids, days, handles, entities, groups, source_types, source_ids, requests;
    PackedInt32Array kinds, domains, scopes, old_stacks, new_stacks;
    PackedStringArray definitions, reasons;
    for (const Event &event : _events) {
        if (event.id <= after_event_id || ids.size() >= limit) continue;
        ids.push_back(event.id);
        days.push_back(event.day);
        kinds.push_back(event.kind);
        domains.push_back(event.domain);
        handles.push_back(static_cast<int64_t>(event.handle));
        entities.push_back(static_cast<int64_t>(event.entity_handle));
        groups.push_back(static_cast<int64_t>(event.group_handle));
        scopes.push_back(event.scope);
        source_types.push_back(static_cast<int64_t>(event.source_type));
        source_ids.push_back(static_cast<int64_t>(event.source_id));
        requests.push_back(event.request_id);
        old_stacks.push_back(event.old_stacks);
        new_stacks.push_back(event.new_stacks);
        definitions.push_back(event.definition_id >= 0 &&
            event.definition_id < static_cast<int32_t>(_definitions.size())
                ? _definitions[event.definition_id].key.c_str() : "");
        reasons.push_back(event.reason.c_str());
    }
    Dictionary out;
    out["ok"] = true;
    out["journal_version"] = 2;
    out["event_ids"] = ids;
    out["days"] = days;
    out["kinds"] = kinds;
    out["domains"] = domains;
    out["modifier_handles"] = handles;
    out["entity_handles"] = entities;
    out["group_handles"] = groups;
    out["scopes"] = scopes;
    out["source_types"] = source_types;
    out["source_ids"] = source_ids;
    out["request_ids"] = requests;
    out["old_stacks"] = old_stacks;
    out["new_stacks"] = new_stacks;
    out["definition_keys"] = definitions;
    out["reasons"] = reasons;
    out["journal_overflow"] = static_cast<int64_t>(_journal_overflow);
    return out;
}

uint64_t ModifierRuntime::allocate_identity(IdentityStore &store,
                                            const std::string &label) {
    uint32_t index = 0;
    if (!store.free_list.empty()) {
        index = store.free_list.back();
        store.free_list.pop_back();
        if (++store.generation[index] == 0) store.generation[index] = 1;
        store.labels[index] = label;
    } else {
        index = static_cast<uint32_t>(store.active.size());
        store.active.push_back(0);
        store.generation.push_back(1);
        store.labels.push_back(label);
    }
    store.active[index] = 1;
    return (static_cast<uint64_t>(store.generation[index]) << 32U) | index;
}

bool ModifierRuntime::retire_identity(IdentityStore &store, uint64_t handle) {
    if (!valid_identity(store, handle)) return false;
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    store.active[index] = 0;
    store.labels[index].clear();
    store.free_list.push_back(index);
    return true;
}

uint64_t ModifierRuntime::register_gameplay_object(const std::string &archetype) {
    const uint64_t handle = allocate_identity(_gameplay_identities, archetype);
    const size_t size = _gameplay_identities.active.size();
    for (size_t sid = 0; sid < _stats.size(); ++sid) {
        if (_stats[sid].domain != GAMEPLAY) continue;
        if (_gameplay_base_by_stat[sid].size() < size)
            _gameplay_base_by_stat[sid].resize(size, 0.0);
    }
    return handle;
}

bool ModifierRuntime::unregister_gameplay_object(uint64_t handle, int64_t day_index) {
    if (!valid_identity(_gameplay_identities, handle)) return false;
    std::vector<uint64_t> remove;
    const Store &store = _stores[GAMEPLAY];
    for (uint32_t index = 0; index < store.active.size(); ++index)
        if (store.active[index] != 0 && store.scope[index] == ENTITY &&
            store.entity_handle[index] == handle) remove.push_back(make_handle(store, index));
    for (uint64_t modifier : remove)
        remove_handle(GAMEPLAY, modifier, day_index, EVENT_TARGET_CLEANUP, 0,
                      "gameplay_target_destroyed");
    return retire_identity(_gameplay_identities, handle);
}

bool ModifierRuntime::set_gameplay_base(uint64_t handle, const std::string &key,
                                        double value, std::string &error) {
    if (!valid_identity(_gameplay_identities, handle)) {
        error = "modifier_gameplay_handle_stale";
        return false;
    }
    const int32_t sid = stat_id(key);
    if (sid < 0 || _stats[sid].domain != GAMEPLAY || !std::isfinite(value)) {
        error = "modifier_gameplay_stat_invalid";
        return false;
    }
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    if (_gameplay_base_by_stat[sid].size() <= index)
        _gameplay_base_by_stat[sid].resize(index + 1, 0.0);
    _gameplay_base_by_stat[sid][index] = value;
    return true;
}

bool ModifierRuntime::gameplay_effective(uint64_t handle, uint64_t group_handle,
                                         const std::string &key, double &out,
                                         std::string &error) const {
    if (!valid_identity(_gameplay_identities, handle)) {
        error = "modifier_gameplay_handle_stale";
        return false;
    }
    const int32_t sid = stat_id(key);
    const uint32_t index = static_cast<uint32_t>(handle & 0xffffffffULL);
    if (sid < 0 || _stats[sid].domain != GAMEPLAY ||
        sid >= static_cast<int32_t>(_gameplay_base_by_stat.size()) ||
        index >= _gameplay_base_by_stat[sid].size()) {
        error = "modifier_gameplay_stat_invalid";
        return false;
    }
    out = effective_value(GAMEPLAY, sid, handle, group_handle,
                          _gameplay_base_by_stat[sid][index]);
    return true;
}

uint64_t ModifierRuntime::ensure_building_identity(int32_t cell, int32_t type_id,
                                                   int32_t owner_signature_id) {
    const BuildingKey key{cell, type_id, owner_signature_id};
    const auto it = _building_handles.find(key);
    if (it != _building_handles.end() && valid_identity(_building_identities, it->second))
        return it->second;
    const uint64_t handle = allocate_identity(_building_identities,
        std::to_string(cell) + ":" + std::to_string(type_id) + ":" +
        std::to_string(owner_signature_id));
    _building_handles[key] = handle;
    return handle;
}

bool ModifierRuntime::retire_building_identity(int32_t cell, int32_t type_id,
                                               int32_t owner_signature_id,
                                               int64_t day_index) {
    const BuildingKey key{cell, type_id, owner_signature_id};
    const auto it = _building_handles.find(key);
    if (it == _building_handles.end()) return false;
    const uint64_t handle = it->second;
    std::vector<uint64_t> remove;
    const Store &store = _stores[ECONOMY];
    for (uint32_t index = 0; index < store.active.size(); ++index)
        if (store.active[index] != 0 && store.scope[index] == ENTITY &&
            store.entity_handle[index] == handle) remove.push_back(make_handle(store, index));
    for (uint64_t modifier : remove)
        remove_handle(ECONOMY, modifier, day_index, EVENT_TARGET_CLEANUP, 0,
                      "building_target_destroyed");
    _building_handles.erase(it);
    return retire_identity(_building_identities, handle);
}

void ModifierRuntime::clear_domain(int32_t domain) {
    if (domain < 0 || domain >= DOMAIN_COUNT) return;
    _stores[domain] = Store{};
    if (domain == ECONOMY) {
        _building_identities = IdentityStore{};
        _building_handles.clear();
    } else if (domain == GAMEPLAY) {
        _gameplay_identities = IdentityStore{};
        for (std::vector<double> &values : _gameplay_base_by_stat) values.clear();
    }
}

bool ModifierRuntime::serialize_domain(int32_t domain, std::vector<uint8_t> &out,
                                       std::string &error) const {
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT) {
        error = "modifier_save_domain_invalid";
        return false;
    }
    out.clear();
    append_le<uint32_t>(out, SAVE_MAGIC);
    append_le<uint32_t>(out, SAVE_SCHEMA_VERSION);
    append_le<int32_t>(out, domain);
    append_le<uint64_t>(out, _catalog_hash);
    append_le<int64_t>(out, _current_day);
    const Store &store = _stores[domain];
    append_le<uint64_t>(out, store.snapshot_version);
    append_le<uint64_t>(out, store.active_instances);
    for (uint32_t index = 0; index < store.active.size(); ++index) {
        if (store.active[index] == 0) continue;
        const Definition &definition = _definitions[store.definition_id[index]];
        append_le<uint64_t>(out, make_handle(store, index));
        append_string(out, definition.key);
        append_le<int32_t>(out, definition.version);
        append_le<uint64_t>(out, store.entity_handle[index]);
        append_le<uint64_t>(out, store.group_handle[index]);
        append_le<uint64_t>(out, store.source_type[index]);
        append_le<uint64_t>(out, store.source_id[index]);
        append_le<int32_t>(out, store.scope[index]);
        append_le<int32_t>(out, store.stacks[index]);
        append_le<int64_t>(out, store.applied_day[index]);
        append_le<int64_t>(out, store.expiry_day[index]);
        append_le<uint32_t>(out, definition.term_count);
        for (uint32_t t = 0; t < definition.term_count; ++t) {
            const TermDefinition &term = _terms[definition.term_begin + t];
            append_string(out, _stats[term.stat_id].key);
            append_le<double>(out, term.add);
            append_le<double>(out, term.factor);
        }
    }
    const IdentityStore *identities = domain == ECONOMY ? &_building_identities :
        (domain == GAMEPLAY ? &_gameplay_identities : nullptr);
    append_le<uint64_t>(out, identities == nullptr ? 0 : identities->active.size());
    if (identities != nullptr) {
        for (size_t i = 0; i < identities->active.size(); ++i) {
            append_le<uint8_t>(out, identities->active[i]);
            append_le<uint32_t>(out, identities->generation[i]);
            append_string(out, identities->labels[i]);
        }
    }
    if (domain == GAMEPLAY) {
        append_le<uint64_t>(out, _stats.size());
        for (size_t sid = 0; sid < _stats.size(); ++sid) {
            append_string(out, _stats[sid].key);
            append_le<uint64_t>(out, _gameplay_base_by_stat[sid].size());
            for (double value : _gameplay_base_by_stat[sid]) append_le<double>(out, value);
        }
    }
    append_le<uint32_t>(out, SAVE_END);
    return true;
}

bool ModifierRuntime::restore_domain(int32_t domain, const std::vector<uint8_t> &bytes,
                                     std::string &error,
                                     bool allow_tax_catalog_extension) {
    if (!_configured || domain < 0 || domain >= DOMAIN_COUNT) {
        error = "modifier_restore_domain_invalid";
        return false;
    }
    size_t cursor = 0;
    uint32_t magic = 0, version = 0, end = 0;
    int32_t saved_domain = -1;
    uint64_t saved_catalog = 0, snapshot_version = 0, count = 0;
    int64_t saved_day = -1;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, version) ||
        !read_le(bytes, cursor, saved_domain) || !read_le(bytes, cursor, saved_catalog) ||
        !read_le(bytes, cursor, saved_day) || !read_le(bytes, cursor, snapshot_version) ||
        !read_le(bytes, cursor, count) || magic != SAVE_MAGIC ||
        version != SAVE_SCHEMA_VERSION || saved_domain != domain ||
        (saved_catalog != _catalog_hash &&
         (!allow_tax_catalog_extension ||
          saved_catalog != _legacy_catalog_hash_without_tax)) ||
        count > 10000000ULL) {
        error = "modifier_restore_header_invalid";
        return false;
    }
    struct SavedInstance {
        uint64_t handle = 0, entity = 0, group = 0, source_type = 0, source_id = 0;
        int32_t definition = -1, scope = 0, stacks = 1;
        int64_t applied = -1, expiry = -1;
    };
    std::vector<SavedInstance> saved;
    saved.reserve(static_cast<size_t>(count));
    uint32_t max_index = 0;
    for (uint64_t i = 0; i < count; ++i) {
        SavedInstance item;
        std::string definition_key;
        int32_t definition_version = 0;
        uint32_t term_count = 0;
        if (!read_le(bytes, cursor, item.handle) ||
            !read_string(bytes, cursor, definition_key) ||
            !read_le(bytes, cursor, definition_version) ||
            !read_le(bytes, cursor, item.entity) || !read_le(bytes, cursor, item.group) ||
            !read_le(bytes, cursor, item.source_type) || !read_le(bytes, cursor, item.source_id) ||
            !read_le(bytes, cursor, item.scope) || !read_le(bytes, cursor, item.stacks) ||
            !read_le(bytes, cursor, item.applied) || !read_le(bytes, cursor, item.expiry) ||
            !read_le(bytes, cursor, term_count)) {
            error = "modifier_restore_instance_truncated";
            return false;
        }
        item.definition = definition_id(definition_key);
        if (item.definition < 0 || _definitions[item.definition].version != definition_version ||
            _definitions[item.definition].domain != domain ||
            term_count != _definitions[item.definition].term_count || item.stacks <= 0 ||
            item.stacks > _definitions[item.definition].max_stacks) {
            error = "modifier_restore_definition_incompatible";
            return false;
        }
        for (uint32_t t = 0; t < term_count; ++t) {
            std::string stat_key_value;
            double add = 0.0, factor = 1.0;
            if (!read_string(bytes, cursor, stat_key_value) || !read_le(bytes, cursor, add) ||
                !read_le(bytes, cursor, factor)) {
                error = "modifier_restore_term_truncated";
                return false;
            }
            const TermDefinition &expected = _terms[_definitions[item.definition].term_begin + t];
            if (stat_id(stat_key_value) != expected.stat_id || add != expected.add ||
                factor != expected.factor) {
                error = "modifier_restore_term_incompatible";
                return false;
            }
        }
        const uint32_t index = static_cast<uint32_t>(item.handle & 0xffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(item.handle >> 32U);
        if (generation == 0) { error = "modifier_restore_handle_invalid"; return false; }
        max_index = std::max(max_index, index);
        saved.push_back(item);
    }

    IdentityStore identities;
    uint64_t identity_count = 0;
    if (!read_le(bytes, cursor, identity_count) || identity_count > 10000000ULL) {
        error = "modifier_restore_identity_count_invalid";
        return false;
    }
    identities.active.resize(static_cast<size_t>(identity_count));
    identities.generation.resize(static_cast<size_t>(identity_count));
    identities.labels.resize(static_cast<size_t>(identity_count));
    for (size_t i = 0; i < identity_count; ++i) {
        if (!read_le(bytes, cursor, identities.active[i]) ||
            !read_le(bytes, cursor, identities.generation[i]) ||
            !read_string(bytes, cursor, identities.labels[i]) ||
            identities.generation[i] == 0) {
            error = "modifier_restore_identity_invalid";
            return false;
        }
        if (identities.active[i] == 0) identities.free_list.push_back(static_cast<uint32_t>(i));
    }
    std::vector<std::vector<double>> gameplay_values;
    if (domain == GAMEPLAY) {
        uint64_t stat_count = 0;
        if (!read_le(bytes, cursor, stat_count) || stat_count != _stats.size()) {
            error = "modifier_restore_gameplay_stat_count_invalid";
            return false;
        }
        gameplay_values.resize(_stats.size());
        for (size_t sid = 0; sid < _stats.size(); ++sid) {
            std::string key;
            uint64_t value_count = 0;
            if (!read_string(bytes, cursor, key) || key != _stats[sid].key ||
                !read_le(bytes, cursor, value_count) || value_count > 10000000ULL) {
                error = "modifier_restore_gameplay_stat_invalid";
                return false;
            }
            gameplay_values[sid].resize(static_cast<size_t>(value_count));
            for (double &value : gameplay_values[sid])
                if (!read_le(bytes, cursor, value) || !std::isfinite(value)) {
                    error = "modifier_restore_gameplay_value_invalid";
                    return false;
                }
        }
    }
    if (!read_le(bytes, cursor, end) || end != SAVE_END || cursor != bytes.size()) {
        error = "modifier_restore_end_invalid";
        return false;
    }

    clear_domain(domain);
    Store &store = _stores[domain];
    const size_t slots = saved.empty() ? 0 : static_cast<size_t>(max_index) + 1;
    store.active.assign(slots, 0);
    store.generation.assign(slots, 1);
    store.definition_id.assign(slots, -1);
    store.entity_handle.assign(slots, 0);
    store.group_handle.assign(slots, 0);
    store.source_type.assign(slots, 0);
    store.source_id.assign(slots, 0);
    store.scope.assign(slots, GLOBAL);
    store.stacks.assign(slots, 1);
    store.applied_day.assign(slots, -1);
    store.expiry_day.assign(slots, PERMANENT_EXPIRY);
    store.expiry_revision.assign(slots, 0);
    std::set<uint32_t> occupied;
    for (const SavedInstance &item : saved) {
        const uint32_t index = static_cast<uint32_t>(item.handle & 0xffffffffULL);
        if (!occupied.insert(index).second) { error = "modifier_restore_duplicate_slot"; return false; }
        store.active[index] = 1;
        store.generation[index] = static_cast<uint32_t>(item.handle >> 32U);
        store.definition_id[index] = item.definition;
        store.entity_handle[index] = item.entity;
        store.group_handle[index] = item.group;
        store.source_type[index] = item.source_type;
        store.source_id[index] = item.source_id;
        store.scope[index] = item.scope;
        store.stacks[index] = item.stacks;
        store.applied_day[index] = item.applied;
        store.expiry_day[index] = item.expiry;
        store.expiry_revision[index] = 1;
        const Definition &definition = _definitions[item.definition];
        if (definition.policy != INDEPENDENT) {
            const uint64_t sid = item.scope == GLOBAL ? 0 :
                (item.scope == GROUP ? item.group : item.entity);
            if (!store.unique_instances.emplace(UniqueKey{item.definition, item.scope,
                    sid, item.source_type, item.source_id}, index).second) {
                error = "modifier_restore_unique_collision";
                return false;
            }
        }
        add_instance_to_buckets(domain, index);
        if (item.expiry >= 0) store.expiry_heap.push({item.expiry, index,
            store.generation[index], store.expiry_revision[index]});
    }
    for (uint32_t index = 0; index < slots; ++index)
        if (store.active[index] == 0) store.free_list.push_back(index);
    store.active_instances = saved.size();
    store.peak_instances = saved.size();
    store.snapshot_version = snapshot_version + 1;
    if (domain == ECONOMY) {
        _building_identities = std::move(identities);
        _building_handles.clear();
        for (size_t i = 0; i < _building_identities.active.size(); ++i) {
            if (_building_identities.active[i] == 0) continue;
            int cell = -1, type = -1, owner = -1;
            if (std::sscanf(_building_identities.labels[i].c_str(), "%d:%d:%d", &cell, &type, &owner) == 3)
                _building_handles[{cell, type, owner}] =
                    (static_cast<uint64_t>(_building_identities.generation[i]) << 32U) | i;
        }
    } else if (domain == GAMEPLAY) {
        _gameplay_identities = std::move(identities);
        _gameplay_base_by_stat = std::move(gameplay_values);
    }
    _current_day = std::max(_current_day, saved_day);
    return true;
}

} // namespace pk

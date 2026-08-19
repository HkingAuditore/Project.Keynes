#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <queue>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

class NativeCountryRuntime;

// Shared native implementation. Each authority domain owns an independent Store;
// catalog strings are resolved only at the Godot/save boundary.
class ModifierRuntime {
public:
    static constexpr int32_t PROTOCOL_VERSION = 2;
    static constexpr int32_t SAVE_SCHEMA_VERSION = 2;
    static constexpr int64_t PERMANENT_EXPIRY = -1;
    static constexpr int32_t Q16_ONE = 65536;
    static constexpr int32_t MAX_MAGNITUDE_Q16 = Q16_ONE * 4;

    enum Domain : int32_t { CLIMATE = 0, COUNTRY = 1, ECONOMY = 2, GAMEPLAY = 3, DOMAIN_COUNT = 4 };
    enum Scope : int32_t { GLOBAL = 0, GROUP = 1, ENTITY = 2 };
    enum StackPolicy : int32_t { INDEPENDENT = 0, UNIQUE_SOURCE = 1, STACK_REFRESH = 2 };
    enum Operation : int32_t { ADD = 0, SUBTRACT = 1, MULTIPLY = 2, DIVIDE = 3 };
    enum CommandOpcode : int32_t {
        COMMAND_APPLY = 1, COMMAND_REMOVE = 2, COMMAND_REFRESH = 3,
        COMMAND_SET_STACKS = 4, COMMAND_SET_MAGNITUDE = 5,
    };
    enum EventKind : int32_t {
        EVENT_APPLY = 1, EVENT_REPLACE = 2, EVENT_STACK = 3, EVENT_REFRESH = 4,
        EVENT_REMOVE = 5, EVENT_EXPIRE = 6, EVENT_TARGET_CLEANUP = 7,
        EVENT_REJECT = 8, EVENT_MAGNITUDE = 9,
    };
    // Native batch ingress used by EffectRuntime. `definition_key` is resolved
    // before entering the Modifier daily commit, so no Godot Variant or
    // Dictionary construction occurs per Effect command.
    struct NativeCommand {
        int32_t opcode = 0;
        int32_t producer = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        const char *definition_key = nullptr;
        int32_t domain = CLIMATE;
        int32_t scope = ENTITY;
        uint64_t entity_handle = 0;
        uint64_t group_handle = 0;
        uint64_t source_type = 0;
        uint64_t source_id = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        int32_t magnitude_q16 = Q16_ONE;
        uint64_t modifier_handle = 0;
    };

    godot::Dictionary configure(const godot::Dictionary &catalog, int32_t cell_count);
    godot::Dictionary submit_commands(const godot::Dictionary &packed_batch);
    bool submit_commands_pod(const NativeCommand *commands, size_t count,
                             std::vector<int64_t> &request_ids,
                             std::string &error);
    godot::Dictionary run_daily(int64_t day_index);
    bool should_run(int64_t day_index) const;

    godot::Dictionary command_result(int64_t request_id) const;
    bool command_result_pod(int64_t request_id, bool &complete, bool &ok,
                            std::string &reason) const;
    godot::Dictionary list_modifiers(int32_t domain, uint64_t entity_handle,
                                     const godot::String &stat_key) const;
    godot::Dictionary explain(int32_t domain, uint64_t entity_handle,
                              uint64_t group_handle, const godot::String &stat_key,
                              double base_value) const;
    godot::Dictionary report() const;
    godot::Dictionary poll_events(int64_t after_event_id, int32_t limit) const;

    double effective_value(int32_t domain, int32_t stat_id, uint64_t entity_handle,
                           uint64_t group_handle, double base_value) const;
    int32_t stat_id_for_key(const std::string &key) const { return stat_id(key); }
    void effective_values(int32_t domain, const int32_t *stat_ids,
                          uint64_t entity_handle, const int8_t *base_values,
                          int8_t *out_values, size_t count) const;
    double effective_value(int32_t domain, const char *stat_key, uint64_t entity_handle,
                           uint64_t group_handle, double base_value) const;
    // Ascending, de-duplicated scope ids that currently hold a bucket in
    // `domain` for `scope` and any of `stat_ids`. Any scope id absent from the
    // result provably contributes nothing, so callers building dense per-entity
    // tables can fill the rest with one precomputed default instead of probing
    // every entity.
    void collect_scope_ids(int32_t domain, int32_t scope, const int32_t *stat_ids,
                           size_t stat_count,
                           std::vector<uint64_t> &out_scope_ids) const;
    // Combined bucket revision of the given stats. Unlike domain_snapshot_version
    // this ignores mutations to unrelated stats, so a cache over a stat subset is
    // not invalidated by every modifier applied elsewhere in the domain.
    uint64_t stat_bucket_version(int32_t domain, const int32_t *stat_ids,
                                 size_t stat_count) const;
    float climate_radiative_target(int32_t cell, float base_value) const;
    void climate_radiative_terms(int32_t cell, double &add,
                                 double &factor) const;
    double country_economy_output_factor(uint64_t country_handle) const;
    double country_sector_output_factor(uint64_t country_handle,
                                        int32_t economic_sector) const;
    double country_research_institution_output_factor(uint64_t country_handle) const;
    double country_trade_capacity_factor(uint64_t country_handle) const;
    double country_trade_speed_factor(uint64_t country_handle) const;
    double country_construction_cost_factor(uint64_t country_handle) const;
    double country_construction_time_factor(uint64_t country_handle) const;
    double economy_building_output_factor(uint64_t building_handle,
                                           uint64_t settlement_cell,
                                           int32_t economic_sector) const;
    // Combined bucket revision of every stat economy_building_output_factor
    // reads, for callers caching one factor per building.
    uint64_t building_output_stat_version() const;
    bool apply_technology_effect(uint64_t country_handle,
                                 const std::string &definition_key,
                                 int32_t technology_id, int64_t day_index,
                                 std::string &error);
    bool has_technology_effect(uint64_t country_handle,
                               const std::string &definition_key,
                               int32_t technology_id) const;
    bool queue_family_group_effect(const std::string &definition_key,
                                   int32_t settlement_cell,
                                   uint64_t branch_stable_id,
                                   int32_t magnitude_q16,
                                   int64_t day_index,
                                   std::string &error);
    bool queue_family_group_effect_remove(const std::string &definition_key,
                                          int32_t settlement_cell,
                                          uint64_t branch_stable_id,
                                          int64_t day_index,
                                          std::string &error);
    int32_t family_group_effect_magnitude(const std::string &definition_key,
                                          int32_t settlement_cell,
                                          uint64_t branch_stable_id) const;

    uint64_t register_gameplay_object(const std::string &archetype);
    bool unregister_gameplay_object(uint64_t handle, int64_t day_index);
    bool set_gameplay_base(uint64_t handle, const std::string &stat_key, double value,
                           std::string &error);
    bool gameplay_effective(uint64_t handle, uint64_t group_handle,
                            const std::string &stat_key, double &out,
                            std::string &error) const;

    uint64_t ensure_building_identity(int32_t cell, int32_t type_id,
                                      int32_t owner_signature_id);
    bool retire_building_identity(int32_t cell, int32_t type_id,
                                  int32_t owner_signature_id, int64_t day_index);
    void register_person_target(uint64_t handle);
    void unregister_person_target(uint64_t handle);

    void attach_country_runtime(NativeCountryRuntime *runtime) { _country_runtime = runtime; }
    bool serialize_domain(int32_t domain, std::vector<uint8_t> &out,
                          std::string &error) const;
    bool restore_domain(int32_t domain, const std::vector<uint8_t> &bytes,
                        std::string &error,
                        bool allow_tax_catalog_extension = false);
    void clear_domain(int32_t domain);
    uint64_t catalog_hash() const { return _catalog_hash; }
    // Bumps on every apply/remove/expire/set-stacks mutation of the domain
    // store. Callers may use it as an exact invalidation token for caches keyed
    // on that domain's effective values.
    uint64_t domain_snapshot_version(int32_t domain) const {
        return domain >= 0 && domain < DOMAIN_COUNT
            ? _stores[domain].snapshot_version : 0;
    }
    bool configured() const { return _configured; }

private:
    struct StatDefinition {
        std::string key;
        int32_t domain = CLIMATE;
        double min_value = 0.0;
        double max_value = 1.0;
        bool persistable = true;
    };
    struct TermDefinition { int32_t stat_id = -1; double add = 0.0; double factor = 1.0; };
    struct Definition {
        std::string key;
        int32_t version = 1;
        int32_t domain = CLIMATE;
        int32_t policy = INDEPENDENT;
        int32_t max_stacks = 1;
        int32_t default_duration = -1;
        uint32_t term_begin = 0;
        uint32_t term_count = 0;
    };
    struct BucketKey {
        int32_t stat_id = -1;
        int32_t scope = GLOBAL;
        uint64_t scope_id = 0;
        bool operator==(const BucketKey &other) const {
            return stat_id == other.stat_id && scope == other.scope && scope_id == other.scope_id;
        }
    };
    struct BucketKeyHash {
        size_t operator()(const BucketKey &key) const noexcept;
    };
    struct Contribution { uint32_t instance = 0; uint16_t term = 0; };
    struct Bucket {
        double sum_add = 0.0;
        double product_nonzero = 1.0;
        int32_t zero_factor_count = 0;
        uint32_t mutations_since_rebuild = 0;
        std::vector<Contribution> members;
    };
    struct UniqueKey {
        int32_t definition_id = -1;
        int32_t scope = GLOBAL;
        uint64_t scope_id = 0;
        uint64_t source_type = 0;
        uint64_t source_id = 0;
        bool operator==(const UniqueKey &other) const;
    };
    struct UniqueKeyHash { size_t operator()(const UniqueKey &key) const noexcept; };
    struct ExpiryNode {
        int64_t day = 0;
        uint32_t index = 0;
        uint32_t generation = 0;
        uint32_t revision = 0;
        bool operator>(const ExpiryNode &other) const;
    };
    struct Store {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<int32_t> definition_id;
        std::vector<uint64_t> entity_handle;
        std::vector<uint64_t> group_handle;
        std::vector<uint64_t> source_type;
        std::vector<uint64_t> source_id;
        std::vector<int32_t> scope;
        std::vector<int32_t> stacks;
        std::vector<int32_t> magnitude_q16;
        std::vector<int64_t> applied_day;
        std::vector<int64_t> expiry_day;
        std::vector<uint32_t> expiry_revision;
        std::vector<uint32_t> free_list;
        std::unordered_map<BucketKey, Bucket, BucketKeyHash> buckets;
        std::unordered_map<UniqueKey, uint32_t, UniqueKeyHash> unique_instances;
        std::priority_queue<ExpiryNode, std::vector<ExpiryNode>, std::greater<ExpiryNode>> expiry_heap;
        // Per-stat bucket revisions, indexed by stat id. Grown lazily because a
        // cleared store outlives the catalog it was sized for. structure_epoch
        // covers wholesale replacements (clear/restore) that per-stat counters
        // cannot express, so a stat with no buckets before and after still
        // invalidates caches.
        std::vector<uint64_t> stat_versions;
        uint64_t structure_epoch = 0;
        uint64_t snapshot_version = 0;
        uint64_t peak_instances = 0;
        uint64_t active_instances = 0;
        mutable uint64_t query_count = 0;
        mutable uint64_t bucket_reads = 0;
        uint64_t bucket_rebuilds = 0;
        uint64_t apply_events = 0;
        uint64_t remove_events = 0;
        uint64_t expire_events = 0;
        uint64_t reject_events = 0;
        uint64_t target_cleanup_events = 0;
    };
    struct Command {
        int32_t opcode = 0;
        int32_t producer = 0;
        int64_t sequence = 0;
        int64_t effective_day = 0;
        int64_t request_id = 0;
        int32_t definition_id = -1;
        int32_t domain = CLIMATE;
        int32_t scope = ENTITY;
        uint64_t entity_handle = 0;
        uint64_t group_handle = 0;
        uint64_t source_type = 0;
        uint64_t source_id = 0;
        int32_t duration_days = -1;
        int32_t stacks = 1;
        int32_t magnitude_q16 = Q16_ONE;
        uint64_t modifier_handle = 0;
        uint64_t submit_order = 0;
    };
    struct Result {
        bool ok = false;
        std::string reason;
        uint64_t handle = 0;
        int64_t day = -1;
    };
    struct Event {
        int64_t id = 0;
        int64_t day = -1;
        int32_t kind = 0;
        int32_t domain = CLIMATE;
        uint64_t handle = 0;
        int32_t definition_id = -1;
        uint64_t entity_handle = 0;
        uint64_t group_handle = 0;
        int32_t scope = GLOBAL;
        uint64_t source_type = 0;
        uint64_t source_id = 0;
        int32_t old_stacks = 0;
        int32_t new_stacks = 0;
        int64_t request_id = 0;
        std::string reason;
        int32_t old_magnitude_q16 = Q16_ONE;
        int32_t new_magnitude_q16 = Q16_ONE;
    };
    struct IdentityStore {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<std::string> labels;
        std::vector<uint32_t> free_list;
    };
    struct BuildingKey {
        int32_t cell = -1;
        int32_t type = -1;
        int32_t owner = -1;
        bool operator==(const BuildingKey &other) const {
            return cell == other.cell && type == other.type && owner == other.owner;
        }
    };
    struct BuildingKeyHash { size_t operator()(const BuildingKey &key) const noexcept; };

    bool compile_catalog(const godot::Dictionary &catalog, std::string &error);
    bool validate_target(const Command &command, std::string &error) const;
    uint64_t apply_command(const Command &command, int64_t day, Result &result);
    bool remove_handle(int32_t domain, uint64_t handle, int64_t day, int32_t event_kind,
                       int64_t request_id, const std::string &reason, Result *result = nullptr);
    bool remove_unique_command(const Command &command, int64_t day, Result &result);
    bool refresh_handle(const Command &command, int64_t day, Result &result);
    bool set_stacks(const Command &command, int64_t day, Result &result);
    bool set_magnitude(const Command &command, int64_t day, Result &result);
    static void bump_stat_version(Store &store, int32_t stat_id);
    void add_instance_to_buckets(int32_t domain, uint32_t index);
    void remove_instance_from_buckets(int32_t domain, uint32_t index);
    void rebuild_bucket(int32_t domain, const BucketKey &key, Bucket &bucket);
    double bucket_factor(const Bucket &bucket) const;
    double scaled_add(const TermDefinition &term, int32_t stacks,
                      int32_t magnitude_q16) const;
    double scaled_factor(const TermDefinition &term, int32_t stacks,
                         int32_t magnitude_q16) const;
    uint64_t make_handle(const Store &store, uint32_t index) const;
    bool resolve_handle(const Store &store, uint64_t handle, uint32_t &index) const;
    uint64_t scope_id_for(const Command &command) const;
    void push_event(Event event);
    void reject_command(const Command &command, int64_t day, const std::string &reason);
    int32_t stat_id(const std::string &key) const;
    int32_t definition_id(const std::string &key) const;
    uint64_t allocate_identity(IdentityStore &store, const std::string &label);
    bool valid_identity(const IdentityStore &store, uint64_t handle) const;
    bool retire_identity(IdentityStore &store, uint64_t handle);
    uint64_t estimated_store_bytes(int32_t domain) const;
    void record_error(const std::string &reason) const;

    bool _configured = false;
    int32_t _cell_count = 0;
    uint64_t _catalog_hash = 0;
    uint64_t _legacy_catalog_hash_without_tax = 0;
    static constexpr size_t BUILDING_OUTPUT_STAT_COUNT = 7;
    int32_t _building_output_stat_ids[BUILDING_OUTPUT_STAT_COUNT] = {
        -1, -1, -1, -1, -1, -1, -1};
    int64_t _current_day = -1;
    int64_t _next_request_id = 1;
    int64_t _next_event_id = 1;
    uint64_t _submit_order = 0;
    uint64_t _journal_overflow = 0;
    uint64_t _commands_applied = 0;
    uint64_t _commands_rejected = 0;
    uint64_t _expired = 0;
    double _last_command_ms = 0.0;
    double _last_expiry_ms = 0.0;
    double _last_publish_ms = 0.0;
    double _last_bucket_update_ms = 0.0;
    double _last_bucket_rebuild_ms = 0.0;
    double _bucket_update_ms_total = 0.0;
    double _bucket_rebuild_ms_total = 0.0;
    std::vector<StatDefinition> _stats;
    std::vector<Definition> _definitions;
    std::vector<TermDefinition> _terms;
    std::unordered_map<std::string, int32_t> _stat_ids;
    std::unordered_map<std::string, int32_t> _definition_ids;
    std::array<Store, DOMAIN_COUNT> _stores;
    std::vector<Command> _pending_commands;
    std::unordered_map<int64_t, Result> _results;
    std::deque<Event> _events;
    mutable std::unordered_map<std::string, uint64_t> _error_counts;
    IdentityStore _gameplay_identities;
    std::vector<std::vector<double>> _gameplay_base_by_stat;
    IdentityStore _building_identities;
    std::unordered_map<BuildingKey, uint64_t, BuildingKeyHash> _building_handles;
    std::unordered_set<uint64_t> _person_targets;
    NativeCountryRuntime *_country_runtime = nullptr;
};

} // namespace pk

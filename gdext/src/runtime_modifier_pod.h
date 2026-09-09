#pragma once

#include "runtime_pod_protocol.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

constexpr uint32_t RUNTIME_MODIFIER_POD_ABI_VERSION = 1u;
constexpr uint32_t RUNTIME_MODIFIER_POD_WIRE_ABI_VERSION = 1u;
// ABI 1 payload: abi(4), domain/scope(2+2), definition(4),
// entity/group/source_type/source_id(8*4), duration/stacks/magnitude(4*3),
// modifier handle(8), target generation(4), input generation(8).
constexpr uint32_t RUNTIME_MODIFIER_POD_WIRE_SIZE = 76u;
constexpr uint32_t RUNTIME_MODIFIER_POD_MAX_ENTRIES = 1u << 20;

enum class RuntimeModifierPodOpcode : uint16_t {
    APPLY = 1,
    REMOVE = 2,
    REFRESH = 3,
    SET_STACKS = 4,
    SET_MAGNITUDE = 5,
};

struct RuntimeModifierPodStat {
    int32_t domain = 0;
    double min_value = 0.0;
    double max_value = 1.0;
    uint8_t persistable = 1;
};

struct RuntimeModifierPodDefinition {
    int32_t version = 1;
    int32_t domain = 0;
    int32_t policy = 0;
    int32_t max_stacks = 1;
    int32_t default_duration = -1;
    uint32_t term_begin = 0;
    uint32_t term_count = 0;
};

struct RuntimeModifierPodTerm {
    int32_t stat_id = -1;
    double add = 0.0;
    double factor = 1.0;
};

struct RuntimeModifierPodCatalog {
    uint32_t abi_version = RUNTIME_MODIFIER_POD_ABI_VERSION;
    uint64_t catalog_hash = 0;
    std::vector<RuntimeModifierPodStat> stats;
    std::vector<RuntimeModifierPodDefinition> definitions;
    std::vector<RuntimeModifierPodTerm> terms;
};

struct RuntimeModifierPodCommand {
    uint64_t request_id = 0;
    uint32_t producer_id = 0;
    uint64_t sequence = 0;
    int64_t requested_day = 0;
    int64_t effective_day = 0;
    uint16_t opcode = 0;
    uint16_t domain = 0;
    int32_t definition_id = -1;
    int32_t scope = 0;
    uint64_t entity_handle = 0;
    uint64_t group_handle = 0;
    uint64_t source_type = 0;
    uint64_t source_id = 0;
    int32_t duration_days = -1;
    int32_t stacks = 1;
    int32_t magnitude_q16 = 65536;
    uint64_t modifier_handle = 0;
    uint32_t target_generation = 0;
    uint64_t input_generation = 0;
};

struct RuntimeModifierPodEntry {
    uint16_t domain = 0;
    uint16_t reserved = 0;
    uint64_t modifier_handle = 0;
    uint64_t target_handle = 0;
    uint32_t target_generation = 0;
    int32_t definition_id = -1;
    int32_t scope = 0;
    uint64_t entity_handle = 0;
    uint64_t group_handle = 0;
    uint64_t source_type = 0;
    uint64_t source_id = 0;
    int32_t stacks = 0;
    int32_t magnitude_q16 = 65536;
    // Legacy PDP3 stores this lane under the historical name value_q16. Keep
    // it as a wire-compatible alias until the composite section is retired.
    int64_t value_q16 = 65536;
    int64_t applied_day = -1;
    int64_t expires_day = -1;
};

struct RuntimeModifierPodBucket {
    uint16_t domain = 0;
    uint16_t scope = 0;
    uint32_t stat_id = 0;
    uint64_t scope_id = 0;
    double sum_add = 0.0;
    double product_factor = 1.0;
    uint32_t active_count = 0;
};

struct RuntimeModifierPodSnapshot {
    uint32_t abi_version = RUNTIME_MODIFIER_POD_ABI_VERSION;
    uint64_t catalog_hash = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    int64_t committed_day = -1;
    std::array<uint64_t, 4> domain_versions{};
    std::vector<RuntimeModifierPodEntry> entries;
    std::vector<RuntimeModifierPodBucket> buckets;
    std::vector<RuntimeDomainAck> acks;
};

struct RuntimeModifierPodReport {
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t work_units = 0;
    uint32_t applied_commands = 0;
    uint32_t rejected_commands = 0;
    uint32_t expired_entries = 0;
    uint32_t ack_count = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
    char fallback_reason[64]{};
};

class RuntimeModifierPodAuthority {
public:
    RuntimeModifierPodAuthority();

    void reset(size_t entry_capacity = 256u);
    bool configure(const RuntimeModifierPodCatalog &catalog, std::string &error);
    bool configured() const { return _configured; }
    uint64_t catalog_hash() const { return _catalog.catalog_hash; }
    const RuntimeModifierPodCatalog &catalog() const { return _catalog; }

    bool plan_day(int64_t day, uint64_t input_generation,
                  const std::vector<RuntimeModifierPodCommand> &commands,
                  const std::vector<RuntimeModifierPodCommand> &intents,
                  RuntimeModifierPodSnapshot &planned_snapshot,
                  std::vector<RuntimeDomainAck> &acks,
                  RuntimeModifierPodReport &report,
                  std::string &error);
    bool commit_day(RuntimeModifierPodSnapshot &planned_snapshot,
                    std::string &error);
    void discard_plan();

    const RuntimeModifierPodSnapshot &snapshot() const { return _snapshot; }
    const RuntimeModifierPodReport &report() const { return _report; }

    void serialize(std::vector<uint8_t> &out) const;
    bool restore(const uint8_t *data, size_t size, std::string &error);
    void set_pending_command_identities(
            const std::vector<RuntimeModifierPodCommand> &commands) {
        _pending_identities = commands;
    }
    // One-time migration hook for PDP3 saves.  The old composite section did
    // not carry free-slot metadata, so the migration rebuilds the dense slot
    // arrays and preserves every encoded handle generation.
    bool restore_legacy_entries(
            const std::vector<std::pair<uint16_t, RuntimeModifierPodEntry>> &entries,
            uint64_t generation, uint64_t state_hash, int64_t committed_day,
            const std::array<uint64_t, 4> &domain_versions,
            std::string &error);

    static bool self_test(std::string &error);

private:
    struct DomainState {
        std::vector<RuntimeModifierPodEntry> entries;
        std::vector<uint32_t> handle_generations;
        std::vector<uint32_t> free_indices;
        std::vector<uint32_t> expiry_queue;
        uint64_t version = 0;
    };
    struct State {
        std::array<DomainState, 4> domains;
        uint64_t generation = 0;
        uint64_t state_hash = 1469598103934665603ull;
        int64_t committed_day = -1;
    };

    static uint64_t hash_mix(uint64_t value, uint64_t input) noexcept;
    static uint64_t hash_bytes(uint64_t value, const void *data, size_t size) noexcept;
    static uint64_t scope_id(const RuntimeModifierPodCommand &command) noexcept;
    static uint64_t scope_id(const RuntimeModifierPodEntry &entry) noexcept;
    static bool command_less(const RuntimeModifierPodCommand &a,
                             const RuntimeModifierPodCommand &b) noexcept;
    bool validate_command(const RuntimeModifierPodCommand &command,
                          std::string &error) const;
    bool resolve_entry(const DomainState &domain, uint64_t handle,
                       size_t &index) const;
    bool apply_command(State &state, const RuntimeModifierPodCommand &command,
                       int64_t day, RuntimeDomainAck &ack, bool &changed,
                       std::string &error);
    bool remove_entry(State &state, const RuntimeModifierPodCommand &command,
                      int64_t day, RuntimeDomainAck &ack, bool &changed,
                      std::string &error);
    void rebuild_buckets(const State &state,
                         std::vector<RuntimeModifierPodBucket> &out) const;
    void rebuild_expiry_queue(DomainState &domain) const;
    void build_snapshot(const State &state, RuntimeModifierPodSnapshot &out) const;
    uint64_t state_hash(const State &state) const;
    void set_error(RuntimeModifierPodReport &report, const char *reason) const;

    RuntimeModifierPodCatalog _catalog;
    State _current;
    State _next;
    RuntimeModifierPodSnapshot _snapshot;
    RuntimeModifierPodSnapshot _planned_snapshot;
    RuntimeModifierPodReport _report{};
    std::vector<RuntimeModifierPodCommand> _pending_identities;
    bool _configured = false;
    bool _plan_ready = false;
};

class RuntimeModifierSnapshotRing {
public:
    RuntimeModifierSnapshotRing();
    bool try_begin_write(uint32_t &index);
    RuntimeModifierPodSnapshot &write_buffer(uint32_t index) { return _slots[index].snapshot; }
    const RuntimeModifierPodSnapshot &read_buffer(uint32_t index) const { return _slots[index].snapshot; }
    void publish(uint32_t index);
    bool try_acquire_latest(uint64_t after_generation, uint32_t &index);
    bool try_acquire_generation(uint64_t generation, uint32_t &index);
    void release(uint32_t index);
    void reset();
    uint64_t publish_drop_count() const { return _publish_drop_count.load(std::memory_order_relaxed); }
    static bool self_test();
private:
    enum : uint8_t { FREE = 0, WRITING = 1, READY = 2, READING = 3 };
    struct Slot {
        std::atomic<uint8_t> state{FREE};
        RuntimeModifierPodSnapshot snapshot{};
    };
    std::array<Slot, RUNTIME_SNAPSHOT_RING_SIZE> _slots{};
    std::atomic<uint64_t> _published_generation{0};
    std::atomic<uint64_t> _publish_drop_count{0};
};

} // namespace pk

#pragma once

#include "runtime_pod_protocol.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

constexpr uint32_t RUNTIME_EVENTS_ABI_VERSION = 1u;
constexpr uint32_t RUNTIME_EVENTS_DEFAULT_CAPACITY = 8192u;
constexpr uint32_t RUNTIME_EVENTS_MAX_BATCH_RECORDS = 12u;

struct RuntimeEventsRecord {
    int64_t event_id = 0;
    int64_t tick = 0;
    int32_t phase = 0;
    int32_t type = 0;
    int32_t source = 0;
    int32_t flags = 0;
    uint64_t entity_handle = 0;
    int32_t entity_id = -1;
    int32_t cell_idx = -1;
    int32_t payload_schema = 0;
    int64_t value_i64 = 0;
    int32_t payload_i0 = 0;
    int32_t payload_i1 = 0;
    int32_t payload_i2 = 0;
    int32_t payload_i3 = 0;
};

struct RuntimeEventsConsumerAck {
    uint64_t consumer_key = 0;
    int64_t event_id = 0;
};

struct RuntimeEventsIdempotencyEvidence {
    uint64_t key = 0;
    uint64_t request_id = 0;
    int64_t event_id = 0;
};

struct RuntimeEventsSnapshot {
    uint32_t abi_version = RUNTIME_EVENTS_ABI_VERSION;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    int64_t committed_day = -1;
    int64_t next_event_id = 1;
    uint32_t capacity = RUNTIME_EVENTS_DEFAULT_CAPACITY;
    uint64_t dropped_event_count = 0;
    int64_t first_dropped_event_id = 0;
    std::vector<RuntimeEventsRecord> events;
    std::vector<RuntimeEventsConsumerAck> consumer_acks;
    std::vector<RuntimeEventsIdempotencyEvidence> idempotency;
};

struct RuntimeEventsReport {
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t work_units = 0;
    uint32_t appended_events = 0;
    uint32_t acknowledged_consumers = 0;
    uint32_t dropped_events = 0;
    uint32_t rejected_commands = 0;
    uint8_t completed = 0;
    uint8_t preflight_ok = 1;
    char fallback_reason[64]{};
};

class RuntimeEventsAuthority {
public:
    RuntimeEventsAuthority();

    void reset(uint32_t capacity = RUNTIME_EVENTS_DEFAULT_CAPACITY);
    bool plan_day(int64_t day, const std::vector<RuntimeCommandPacket> &commands,
                  RuntimeEventsSnapshot &planned_snapshot,
                  std::vector<RuntimeCommandReceipt> &receipts,
                  RuntimeEventsReport &report, std::string &error);
    bool commit_day(const RuntimeEventsSnapshot &planned_snapshot,
                    std::string &error);
    void discard_plan();

    const RuntimeEventsSnapshot &snapshot() const { return _current; }
    const RuntimeEventsReport &report() const { return _report; }

    bool serialize(std::vector<uint8_t> &out, std::string &error) const;
    bool restore(const uint8_t *data, size_t size, std::string &error);

    static bool self_test(std::string &error);

private:
    static uint64_t hash_snapshot(const RuntimeEventsSnapshot &snapshot);
    static bool packet_less(const RuntimeCommandPacket &lhs,
                            const RuntimeCommandPacket &rhs) noexcept;
    static bool validate_snapshot(const RuntimeEventsSnapshot &snapshot,
                                  std::string &error);
    static void set_error(RuntimeEventsReport &report, const char *reason);
    bool apply_packet(RuntimeEventsSnapshot &state,
                      const RuntimeCommandPacket &packet, int64_t day,
                      RuntimeEventsReport &report, std::string &error);

    RuntimeEventsSnapshot _current;
    RuntimeEventsSnapshot _planned;
    RuntimeEventsReport _report{};
    bool _plan_ready = false;
};

class RuntimeEventsSnapshotRing {
public:
    RuntimeEventsSnapshotRing();
    bool try_begin_write(uint32_t &index);
    RuntimeEventsSnapshot &write_buffer(uint32_t index) { return _slots[index].snapshot; }
    const RuntimeEventsSnapshot &read_buffer(uint32_t index) const {
        return _slots[index].snapshot;
    }
    void publish(uint32_t index);
    bool try_acquire_latest(uint64_t after_generation, uint32_t &index);
    void release(uint32_t index);
    void reset();
    uint64_t publish_drop_count() const {
        return _publish_drop_count.load(std::memory_order_relaxed);
    }
    static bool self_test();

private:
    enum : uint8_t { FREE = 0, WRITING = 1, READY = 2, READING = 3 };
    struct Slot {
        std::atomic<uint8_t> state{FREE};
        RuntimeEventsSnapshot snapshot{};
    };
    std::array<Slot, RUNTIME_SNAPSHOT_RING_SIZE> _slots{};
    std::atomic<uint64_t> _published_generation{0};
    std::atomic<uint64_t> _publish_drop_count{0};
};

} // namespace pk

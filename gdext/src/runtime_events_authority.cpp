#include "runtime_events_authority.h"

#include <algorithm>
#include <cstring>
#include <limits>
#include <type_traits>

namespace pk {
namespace {

constexpr uint32_t SAVE_MAGIC = 0x31545645u; // EVT1
constexpr uint32_t SAVE_END = 0x31444e45u; // END1
constexpr size_t MAX_SAVE_BYTES = 64u * 1024u * 1024u;
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t mix(uint64_t hash, uint64_t value) noexcept {
    hash ^= value;
    return hash * FNV_PRIME;
}

template <typename T>
void append_le(std::vector<uint8_t> &out, T value) {
    using U = std::make_unsigned_t<T>;
    const U bits = static_cast<U>(value);
    for (size_t i = 0; i < sizeof(T); ++i)
        out.push_back(static_cast<uint8_t>((bits >> (i * 8u)) & 0xffu));
}

template <typename T>
bool read_le(const uint8_t *data, size_t size, size_t &cursor, T &out) {
    if (data == nullptr || cursor > size || size - cursor < sizeof(T)) return false;
    using U = std::make_unsigned_t<T>;
    U bits = 0;
    for (size_t i = 0; i < sizeof(T); ++i)
        bits |= static_cast<U>(data[cursor + i]) << (i * 8u);
    cursor += sizeof(T);
    out = static_cast<T>(bits);
    return true;
}

void append_record(std::vector<uint8_t> &out, const RuntimeEventsRecord &record,
                   uint64_t idempotency_key) {
    append_le<int64_t>(out, record.tick);
    append_le<int32_t>(out, record.phase);
    append_le<int32_t>(out, record.type);
    append_le<int32_t>(out, record.source);
    append_le<int32_t>(out, record.flags);
    append_le<uint64_t>(out, record.entity_handle);
    append_le<int32_t>(out, record.entity_id);
    append_le<int32_t>(out, record.cell_idx);
    append_le<int32_t>(out, record.payload_schema);
    append_le<int64_t>(out, record.value_i64);
    append_le<int32_t>(out, record.payload_i0);
    append_le<int32_t>(out, record.payload_i1);
    append_le<int32_t>(out, record.payload_i2);
    append_le<int32_t>(out, record.payload_i3);
    append_le<uint64_t>(out, idempotency_key);
}

bool read_record(const uint8_t *data, size_t size, size_t &cursor,
                 RuntimeEventsRecord &record, uint64_t &idempotency_key) {
    return read_le(data, size, cursor, record.tick) &&
        read_le(data, size, cursor, record.phase) &&
        read_le(data, size, cursor, record.type) &&
        read_le(data, size, cursor, record.source) &&
        read_le(data, size, cursor, record.flags) &&
        read_le(data, size, cursor, record.entity_handle) &&
        read_le(data, size, cursor, record.entity_id) &&
        read_le(data, size, cursor, record.cell_idx) &&
        read_le(data, size, cursor, record.payload_schema) &&
        read_le(data, size, cursor, record.value_i64) &&
        read_le(data, size, cursor, record.payload_i0) &&
        read_le(data, size, cursor, record.payload_i1) &&
        read_le(data, size, cursor, record.payload_i2) &&
        read_le(data, size, cursor, record.payload_i3) &&
        read_le(data, size, cursor, idempotency_key);
}

bool packet_payload_valid(const RuntimeCommandPacket &packet) {
    const RuntimeCommandEnvelope &envelope = packet.envelope;
    return envelope.payload_offset <= RUNTIME_MAX_COMMAND_PAYLOAD &&
        envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD &&
        envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD - envelope.payload_offset;
}

std::vector<RuntimeEventsConsumerAck>::iterator find_ack(
        std::vector<RuntimeEventsConsumerAck> &acks, uint64_t key) {
    return std::lower_bound(acks.begin(), acks.end(), key,
        [](const RuntimeEventsConsumerAck &entry, uint64_t value) {
            return entry.consumer_key < value;
        });
}

std::vector<RuntimeEventsIdempotencyEvidence>::iterator find_evidence(
        std::vector<RuntimeEventsIdempotencyEvidence> &entries, uint64_t key) {
    return std::lower_bound(entries.begin(), entries.end(), key,
        [](const RuntimeEventsIdempotencyEvidence &entry, uint64_t value) {
            return entry.key < value;
        });
}

RuntimeCommandPacket make_append_packet(uint64_t request, uint32_t producer,
                                        uint64_t sequence, int64_t day,
                                        const RuntimeEventsRecord &record,
                                        uint64_t idempotency = 0) {
    RuntimeCommandPacket packet{};
    packet.envelope.request_id = request;
    packet.envelope.producer_id = producer;
    packet.envelope.sequence = sequence;
    packet.envelope.requested_day = day;
    packet.envelope.effective_day = day;
    packet.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
    packet.envelope.opcode = static_cast<uint16_t>(RuntimeEventsCommand::APPEND_BATCH);
    std::vector<uint8_t> payload;
    append_le<uint32_t>(payload, RUNTIME_EVENTS_ABI_VERSION);
    append_le<uint32_t>(payload, 1u);
    append_record(payload, record, idempotency);
    packet.envelope.payload_size = static_cast<uint32_t>(payload.size());
    std::memcpy(packet.payload.data(), payload.data(), payload.size());
    return packet;
}

} // namespace

RuntimeEventsAuthority::RuntimeEventsAuthority() { reset(); }

void RuntimeEventsAuthority::reset(uint32_t capacity) {
    const uint32_t bounded = std::clamp(capacity, 1u, RUNTIME_DOMAIN_EVENT_CAPACITY);
    _current = RuntimeEventsSnapshot{};
    _current.capacity = bounded;
    _current.events.reserve(bounded);
    _current.consumer_acks.reserve(128u);
    _current.idempotency.reserve(bounded);
    _current.state_hash = hash_snapshot(_current);
    _planned = RuntimeEventsSnapshot{};
    _report = RuntimeEventsReport{};
    _plan_ready = false;
}

uint64_t RuntimeEventsAuthority::hash_snapshot(const RuntimeEventsSnapshot &snapshot) {
    uint64_t hash = mix(FNV_OFFSET, snapshot.abi_version);
    hash = mix(hash, snapshot.generation);
    hash = mix(hash, static_cast<uint64_t>(snapshot.committed_day));
    hash = mix(hash, static_cast<uint64_t>(snapshot.next_event_id));
    hash = mix(hash, snapshot.capacity);
    hash = mix(hash, snapshot.dropped_event_count);
    hash = mix(hash, static_cast<uint64_t>(snapshot.first_dropped_event_id));
    for (const RuntimeEventsRecord &record : snapshot.events) {
        hash = mix(hash, static_cast<uint64_t>(record.event_id));
        hash = mix(hash, static_cast<uint64_t>(record.tick));
        hash = mix(hash, static_cast<uint32_t>(record.phase));
        hash = mix(hash, static_cast<uint32_t>(record.type));
        hash = mix(hash, static_cast<uint32_t>(record.source));
        hash = mix(hash, static_cast<uint32_t>(record.flags));
        hash = mix(hash, record.entity_handle);
        hash = mix(hash, static_cast<uint32_t>(record.entity_id));
        hash = mix(hash, static_cast<uint32_t>(record.cell_idx));
        hash = mix(hash, static_cast<uint32_t>(record.payload_schema));
        hash = mix(hash, static_cast<uint64_t>(record.value_i64));
        hash = mix(hash, static_cast<uint32_t>(record.payload_i0));
        hash = mix(hash, static_cast<uint32_t>(record.payload_i1));
        hash = mix(hash, static_cast<uint32_t>(record.payload_i2));
        hash = mix(hash, static_cast<uint32_t>(record.payload_i3));
    }
    for (const RuntimeEventsConsumerAck &ack : snapshot.consumer_acks) {
        hash = mix(hash, ack.consumer_key);
        hash = mix(hash, static_cast<uint64_t>(ack.event_id));
    }
    for (const RuntimeEventsIdempotencyEvidence &entry : snapshot.idempotency) {
        hash = mix(hash, entry.key);
        hash = mix(hash, entry.request_id);
        hash = mix(hash, static_cast<uint64_t>(entry.event_id));
    }
    return hash;
}

bool RuntimeEventsAuthority::packet_less(const RuntimeCommandPacket &lhs,
                                         const RuntimeCommandPacket &rhs) noexcept {
    const RuntimeCommandEnvelope &a = lhs.envelope;
    const RuntimeCommandEnvelope &b = rhs.envelope;
    if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
    if (a.sequence != b.sequence) return a.sequence < b.sequence;
    if (lhs.submit_order != rhs.submit_order)
        return lhs.submit_order < rhs.submit_order;
    return a.request_id < b.request_id;
}

void RuntimeEventsAuthority::set_error(RuntimeEventsReport &report, const char *reason) {
    const char *source = reason != nullptr ? reason : "events_unknown_error";
    size_t index = 0;
    for (; index + 1u < sizeof(report.fallback_reason) && source[index] != '\0'; ++index)
        report.fallback_reason[index] = source[index];
    report.fallback_reason[index] = '\0';
}

bool RuntimeEventsAuthority::validate_snapshot(const RuntimeEventsSnapshot &snapshot,
                                               std::string &error) {
    if (snapshot.abi_version != RUNTIME_EVENTS_ABI_VERSION || snapshot.capacity == 0 ||
        snapshot.capacity > RUNTIME_DOMAIN_EVENT_CAPACITY ||
        snapshot.events.size() > snapshot.capacity || snapshot.next_event_id <= 0 ||
        snapshot.events.size() > RUNTIME_DOMAIN_EVENT_CAPACITY ||
        snapshot.consumer_acks.size() > RUNTIME_DOMAIN_EVENT_CAPACITY ||
        snapshot.idempotency.size() > RUNTIME_DOMAIN_EVENT_CAPACITY) {
        error = "events_snapshot_shape_invalid";
        return false;
    }
    int64_t prior_event = 0;
    for (const RuntimeEventsRecord &record : snapshot.events) {
        if (record.event_id <= 0 || record.event_id <= prior_event || record.type <= 0 ||
            record.event_id >= snapshot.next_event_id) {
            error = "events_snapshot_event_invalid";
            return false;
        }
        prior_event = record.event_id;
    }
    uint64_t prior_consumer = 0;
    for (size_t i = 0; i < snapshot.consumer_acks.size(); ++i) {
        const RuntimeEventsConsumerAck &ack = snapshot.consumer_acks[i];
        if (ack.consumer_key == 0 || ack.event_id < 0 ||
            (i != 0 && ack.consumer_key <= prior_consumer) ||
            ack.event_id >= snapshot.next_event_id) {
            error = "events_snapshot_ack_invalid";
            return false;
        }
        prior_consumer = ack.consumer_key;
    }
    uint64_t prior_key = 0;
    for (size_t i = 0; i < snapshot.idempotency.size(); ++i) {
        const RuntimeEventsIdempotencyEvidence &entry = snapshot.idempotency[i];
        if (entry.key == 0 || entry.request_id == 0 || entry.event_id <= 0 ||
            entry.event_id >= snapshot.next_event_id ||
            (i != 0 && entry.key <= prior_key)) {
            error = "events_snapshot_idempotency_invalid";
            return false;
        }
        prior_key = entry.key;
    }
    return true;
}

bool RuntimeEventsAuthority::apply_packet(RuntimeEventsSnapshot &state,
                                          const RuntimeCommandPacket &packet,
                                          int64_t day, RuntimeEventsReport &report,
                                          std::string &error) {
    const RuntimeCommandEnvelope &envelope = packet.envelope;
    if (!packet_payload_valid(packet) || envelope.domain !=
            static_cast<uint16_t>(RuntimeDomainId::EVENTS) ||
        envelope.opcode == 0 || envelope.effective_day > day) {
        error = "events_packet_invalid";
        return false;
    }
    const uint8_t *data = packet.payload.data() + envelope.payload_offset;
    const size_t size = envelope.payload_size;
    size_t cursor = 0;
    const RuntimeEventsCommand opcode = static_cast<RuntimeEventsCommand>(envelope.opcode);
    if (opcode == RuntimeEventsCommand::APPEND_BATCH) {
        uint32_t abi = 0;
        uint32_t count = 0;
        if (!read_le(data, size, cursor, abi) || !read_le(data, size, cursor, count) ||
            abi != RUNTIME_EVENTS_ABI_VERSION || count == 0 ||
            count > RUNTIME_EVENTS_MAX_BATCH_RECORDS) {
            error = "events_append_header_invalid";
            return false;
        }
        std::vector<std::pair<RuntimeEventsRecord, uint64_t>> decoded;
        decoded.reserve(count);
        for (uint32_t row = 0; row < count; ++row) {
            RuntimeEventsRecord record;
            uint64_t key = 0;
            if (!read_record(data, size, cursor, record, key) || record.type <= 0) {
                error = "events_append_record_invalid";
                return false;
            }
            decoded.push_back({record, key});
        }
        if (cursor != size) { error = "events_append_trailing_bytes"; return false; }
        for (const auto &entry : decoded) {
            RuntimeEventsRecord record = entry.first;
            const uint64_t key = entry.second;
            if (key != 0) {
                const auto existing = find_evidence(state.idempotency, key);
                if (existing != state.idempotency.end() && existing->key == key) continue;
            }
            record.event_id = state.next_event_id++;
            state.events.push_back(record);
            if (key != 0) {
                RuntimeEventsIdempotencyEvidence evidence;
                evidence.key = key;
                evidence.request_id = envelope.request_id;
                evidence.event_id = record.event_id;
                const auto at = find_evidence(state.idempotency, key);
                state.idempotency.insert(at, evidence);
            }
            ++report.appended_events;
            ++report.work_units;
            if (state.events.size() > state.capacity) {
                const int64_t dropped = state.events.front().event_id;
                if (state.first_dropped_event_id == 0) state.first_dropped_event_id = dropped;
                state.events.erase(state.events.begin());
                ++state.dropped_event_count;
                ++report.dropped_events;
            }
        }
        return true;
    }
    if (opcode == RuntimeEventsCommand::ACK_CONSUMER) {
        uint32_t abi = 0;
        uint64_t consumer = 0;
        int64_t event_id = 0;
        if (!read_le(data, size, cursor, abi) || !read_le(data, size, cursor, consumer) ||
            !read_le(data, size, cursor, event_id) || cursor != size ||
            abi != RUNTIME_EVENTS_ABI_VERSION || consumer == 0 || event_id < 0 ||
            event_id >= state.next_event_id) {
            error = "events_ack_payload_invalid";
            return false;
        }
        auto at = find_ack(state.consumer_acks, consumer);
        if (at == state.consumer_acks.end() || at->consumer_key != consumer) {
            state.consumer_acks.insert(at, RuntimeEventsConsumerAck{consumer, event_id});
        } else if (event_id > at->event_id) {
            at->event_id = event_id;
        }
        ++report.acknowledged_consumers;
        ++report.work_units;
        return true;
    }
    if (opcode == RuntimeEventsCommand::CONFIGURE_CAPACITY) {
        uint32_t abi = 0;
        uint32_t capacity = 0;
        if (!read_le(data, size, cursor, abi) || !read_le(data, size, cursor, capacity) ||
            cursor != size || abi != RUNTIME_EVENTS_ABI_VERSION || capacity == 0 ||
            capacity > RUNTIME_DOMAIN_EVENT_CAPACITY) {
            error = "events_capacity_payload_invalid";
            return false;
        }
        state.capacity = capacity;
        while (state.events.size() > state.capacity) {
            const int64_t dropped = state.events.front().event_id;
            if (state.first_dropped_event_id == 0) state.first_dropped_event_id = dropped;
            state.events.erase(state.events.begin());
            ++state.dropped_event_count;
            ++report.dropped_events;
        }
        ++report.work_units;
        return true;
    }
    if (opcode == RuntimeEventsCommand::CLEAR_RESET) {
        uint32_t abi = 0;
        if (!read_le(data, size, cursor, abi) || cursor != size ||
            abi != RUNTIME_EVENTS_ABI_VERSION) {
            error = "events_clear_payload_invalid";
            return false;
        }
        const uint32_t capacity = state.capacity;
        state = RuntimeEventsSnapshot{};
        state.capacity = capacity;
        state.events.reserve(capacity);
        ++report.work_units;
        return true;
    }
    error = "events_opcode_invalid";
    return false;
}

bool RuntimeEventsAuthority::plan_day(int64_t day,
                                      const std::vector<RuntimeCommandPacket> &commands,
                                      RuntimeEventsSnapshot &planned_snapshot,
                                      std::vector<RuntimeCommandReceipt> &receipts,
                                      RuntimeEventsReport &report,
                                      std::string &error) {
    error.clear();
    receipts.clear();
    report = RuntimeEventsReport{};
    if (day < 0) { error = "events_day_invalid"; set_error(report, error.c_str()); return false; }
    _planned = _current;
    std::vector<RuntimeCommandPacket> ordered;
    ordered.reserve(commands.size());
    for (const RuntimeCommandPacket &packet : commands) {
        if (packet.envelope.domain == static_cast<uint16_t>(RuntimeDomainId::EVENTS))
            ordered.push_back(packet);
    }
    std::stable_sort(ordered.begin(), ordered.end(), packet_less);
    for (const RuntimeCommandPacket &packet : ordered) {
        RuntimeCommandReceipt receipt;
        receipt.request_id = packet.envelope.request_id;
        receipt.producer_id = packet.envelope.producer_id;
        receipt.sequence = packet.envelope.sequence;
        receipt.effective_day = packet.envelope.effective_day;
        receipt.generation = _current.generation + 1u;
        std::string packet_error;
        if (!apply_packet(_planned, packet, day, report, packet_error)) {
            receipt.code = packet_error.find("payload") != std::string::npos ||
                packet_error.find("record") != std::string::npos ||
                packet_error.find("header") != std::string::npos
                ? RuntimeReceiptCode::INVALID_PAYLOAD : RuntimeReceiptCode::INVALID_VALUE;
            ++report.rejected_commands;
            if (error.empty()) error = packet_error;
        }
        receipts.push_back(receipt);
    }
    if (!error.empty()) {
        report.preflight_ok = 0;
        set_error(report, error.c_str());
        _plan_ready = false;
        return false;
    }
    _planned.committed_day = day;
    _planned.generation = _current.generation + 1u;
    _planned.state_hash = hash_snapshot(_planned);
    report.generation = _planned.generation;
    report.state_hash = _planned.state_hash;
    report.completed = 1;
    planned_snapshot = _planned;
    _report = report;
    _plan_ready = true;
    return true;
}

bool RuntimeEventsAuthority::commit_day(const RuntimeEventsSnapshot &planned_snapshot,
                                        std::string &error) {
    error.clear();
    if (!_plan_ready || planned_snapshot.generation != _planned.generation ||
        planned_snapshot.state_hash != _planned.state_hash ||
        !validate_snapshot(_planned, error)) {
        if (error.empty()) error = "events_commit_plan_invalid";
        return false;
    }
    _current = _planned;
    _plan_ready = false;
    return true;
}

void RuntimeEventsAuthority::discard_plan() { _plan_ready = false; }

bool RuntimeEventsAuthority::serialize(std::vector<uint8_t> &out,
                                       std::string &error) const {
    error.clear();
    if (!validate_snapshot(_current, error)) return false;
    out.clear();
    out.reserve(96u + _current.events.size() * 80u);
    append_le<uint32_t>(out, SAVE_MAGIC);
    append_le<uint32_t>(out, RUNTIME_EVENTS_ABI_VERSION);
    append_le<uint64_t>(out, _current.generation);
    append_le<uint64_t>(out, _current.state_hash);
    append_le<int64_t>(out, _current.committed_day);
    append_le<int64_t>(out, _current.next_event_id);
    append_le<uint32_t>(out, _current.capacity);
    append_le<uint64_t>(out, _current.dropped_event_count);
    append_le<int64_t>(out, _current.first_dropped_event_id);
    append_le<uint32_t>(out, static_cast<uint32_t>(_current.events.size()));
    for (const RuntimeEventsRecord &record : _current.events) {
        append_le<int64_t>(out, record.event_id);
        append_record(out, record, 0);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(_current.consumer_acks.size()));
    for (const RuntimeEventsConsumerAck &ack : _current.consumer_acks) {
        append_le<uint64_t>(out, ack.consumer_key);
        append_le<int64_t>(out, ack.event_id);
    }
    append_le<uint32_t>(out, static_cast<uint32_t>(_current.idempotency.size()));
    for (const RuntimeEventsIdempotencyEvidence &entry : _current.idempotency) {
        append_le<uint64_t>(out, entry.key);
        append_le<uint64_t>(out, entry.request_id);
        append_le<int64_t>(out, entry.event_id);
    }
    append_le<uint32_t>(out, SAVE_END);
    if (out.size() > MAX_SAVE_BYTES) { error = "events_save_size_exceeded"; return false; }
    return true;
}

bool RuntimeEventsAuthority::restore(const uint8_t *data, size_t size,
                                     std::string &error) {
    error.clear();
    RuntimeEventsSnapshot candidate;
    size_t cursor = 0;
    uint32_t magic = 0;
    uint32_t version = 0;
    if (!read_le(data, size, cursor, magic) || !read_le(data, size, cursor, version) ||
        magic != SAVE_MAGIC || version != RUNTIME_EVENTS_ABI_VERSION ||
        !read_le(data, size, cursor, candidate.generation) ||
        !read_le(data, size, cursor, candidate.state_hash) ||
        !read_le(data, size, cursor, candidate.committed_day) ||
        !read_le(data, size, cursor, candidate.next_event_id) ||
        !read_le(data, size, cursor, candidate.capacity) ||
        !read_le(data, size, cursor, candidate.dropped_event_count) ||
        !read_le(data, size, cursor, candidate.first_dropped_event_id)) {
        error = "events_save_header_invalid";
        return false;
    }
    uint32_t count = 0;
    if (!read_le(data, size, cursor, count) || count > RUNTIME_DOMAIN_EVENT_CAPACITY) {
        error = "events_save_event_count_invalid";
        return false;
    }
    candidate.events.resize(count);
    for (RuntimeEventsRecord &record : candidate.events) {
        uint64_t ignored = 0;
        if (!read_le(data, size, cursor, record.event_id) ||
            !read_record(data, size, cursor, record, ignored)) {
            error = "events_save_event_truncated";
            return false;
        }
    }
    if (!read_le(data, size, cursor, count) || count > RUNTIME_DOMAIN_EVENT_CAPACITY) {
        error = "events_save_ack_count_invalid";
        return false;
    }
    candidate.consumer_acks.resize(count);
    for (RuntimeEventsConsumerAck &ack : candidate.consumer_acks) {
        if (!read_le(data, size, cursor, ack.consumer_key) ||
            !read_le(data, size, cursor, ack.event_id)) {
            error = "events_save_ack_truncated";
            return false;
        }
    }
    if (!read_le(data, size, cursor, count) || count > RUNTIME_DOMAIN_EVENT_CAPACITY) {
        error = "events_save_idempotency_count_invalid";
        return false;
    }
    candidate.idempotency.resize(count);
    for (RuntimeEventsIdempotencyEvidence &entry : candidate.idempotency) {
        if (!read_le(data, size, cursor, entry.key) ||
            !read_le(data, size, cursor, entry.request_id) ||
            !read_le(data, size, cursor, entry.event_id)) {
            error = "events_save_idempotency_truncated";
            return false;
        }
    }
    uint32_t end = 0;
    if (!read_le(data, size, cursor, end) || end != SAVE_END || cursor != size ||
        !validate_snapshot(candidate, error) || hash_snapshot(candidate) != candidate.state_hash) {
        if (error.empty()) error = "events_save_state_hash_invalid";
        return false;
    }
    _current = std::move(candidate);
    _planned = RuntimeEventsSnapshot{};
    _report = RuntimeEventsReport{};
    _report.generation = _current.generation;
    _report.state_hash = _current.state_hash;
    _plan_ready = false;
    return true;
}

bool RuntimeEventsAuthority::self_test(std::string &error) {
    error.clear();
    RuntimeEventsAuthority authority;
    authority.reset(2u);
    RuntimeEventsRecord first;
    first.tick = 4; first.phase = 9; first.type = 3; first.source = 2;
    first.flags = 7; first.entity_handle = 44; first.entity_id = 5;
    first.cell_idx = 6; first.payload_schema = 8; first.value_i64 = 99;
    first.payload_i0 = 1; first.payload_i1 = 2; first.payload_i2 = 3; first.payload_i3 = 4;
    RuntimeEventsRecord second = first;
    second.type = 4; second.cell_idx = 7;
    RuntimeEventsRecord third = first;
    third.type = 5; third.cell_idx = 8;
    std::vector<RuntimeCommandPacket> commands;
    commands.push_back(make_append_packet(20u, 2u, 1u, 1, second, 900u));
    commands.push_back(make_append_packet(10u, 1u, 1u, 1, first, 800u));
    commands.push_back(make_append_packet(30u, 3u, 1u, 1, third));
    RuntimeEventsSnapshot planned;
    std::vector<RuntimeCommandReceipt> receipts;
    RuntimeEventsReport report;
    if (!authority.plan_day(1, commands, planned, receipts, report, error) ||
        !authority.commit_day(planned, error) || authority.snapshot().events.size() != 2u ||
        authority.snapshot().events[0].type != 4 || authority.snapshot().events[1].type != 5 ||
        authority.snapshot().dropped_event_count != 1u) {
        if (error.empty()) error = "events_order_or_overflow_invalid";
        return false;
    }
    RuntimeCommandPacket ack{};
    ack.envelope.request_id = 31; ack.envelope.producer_id = 1; ack.envelope.sequence = 2;
    ack.envelope.requested_day = 2; ack.envelope.effective_day = 2;
    ack.envelope.domain = static_cast<uint16_t>(RuntimeDomainId::EVENTS);
    ack.envelope.opcode = static_cast<uint16_t>(RuntimeEventsCommand::ACK_CONSUMER);
    std::vector<uint8_t> ack_payload;
    append_le<uint32_t>(ack_payload, RUNTIME_EVENTS_ABI_VERSION);
    append_le<uint64_t>(ack_payload, 123u);
    append_le<int64_t>(ack_payload, 3);
    ack.envelope.payload_size = static_cast<uint32_t>(ack_payload.size());
    std::memcpy(ack.payload.data(), ack_payload.data(), ack_payload.size());
    commands = {ack};
    if (!authority.plan_day(2, commands, planned, receipts, report, error) ||
        !authority.commit_day(planned, error)) return false;
    ack.envelope.request_id = 32; ack.envelope.sequence = 3;
    ack_payload.clear();
    append_le<uint32_t>(ack_payload, RUNTIME_EVENTS_ABI_VERSION);
    append_le<uint64_t>(ack_payload, 123u);
    append_le<int64_t>(ack_payload, 2);
    ack.envelope.payload_size = static_cast<uint32_t>(ack_payload.size());
    std::memcpy(ack.payload.data(), ack_payload.data(), ack_payload.size());
    commands = {ack};
    if (!authority.plan_day(3, commands, planned, receipts, report, error) ||
        !authority.commit_day(planned, error) ||
        authority.snapshot().consumer_acks[0].event_id != 3) {
        if (error.empty()) error = "events_ack_monotonic_invalid";
        return false;
    }
    const RuntimeEventsSnapshot copy = authority.snapshot();
    if (copy.events.empty() || copy.state_hash != authority.snapshot().state_hash) {
        error = "events_snapshot_copy_invalid";
        return false;
    }
    std::vector<uint8_t> bytes;
    if (!authority.serialize(bytes, error)) return false;
    RuntimeEventsAuthority restored;
    if (!restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().state_hash != authority.snapshot().state_hash ||
        restored.snapshot().consumer_acks.size() != 1u ||
        restored.snapshot().idempotency.size() != 2u) {
        if (error.empty()) error = "events_save_roundtrip_invalid";
        return false;
    }
    return RuntimeEventsSnapshotRing::self_test();
}

RuntimeEventsSnapshotRing::RuntimeEventsSnapshotRing() { reset(); }

bool RuntimeEventsSnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        uint8_t expected = FREE;
        if (_slots[i].state.compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_acquire)) {
            index = i;
            return true;
        }
    }
    // The consumer is allowed to observe only the newest generation. Reclaim
    // the oldest READY frame when the reader has fallen behind, otherwise a
    // long-running probe can permanently exhaust the ring without changing
    // the authority state.
    uint32_t oldest = _slots.size();
    uint64_t oldest_generation = std::numeric_limits<uint64_t>::max();
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if (generation < oldest_generation) {
            oldest = i;
            oldest_generation = generation;
        }
    }
    if (oldest < _slots.size()) {
        uint8_t expected = READY;
        if (_slots[oldest].state.compare_exchange_strong(expected, WRITING,
                std::memory_order_acq_rel, std::memory_order_acquire)) {
            _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
            index = oldest;
            return true;
        }
    }
    _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
    return false;
}

void RuntimeEventsSnapshotRing::publish(uint32_t index) {
    if (index >= _slots.size()) return;
    _published_generation.store(_slots[index].snapshot.generation,
                               std::memory_order_release);
    _slots[index].state.store(READY, std::memory_order_release);
}

bool RuntimeEventsSnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                    uint32_t &index) {
    uint32_t best = _slots.size();
    uint64_t best_generation = after_generation;
    for (uint32_t i = 0; i < _slots.size(); ++i) {
        if (_slots[i].state.load(std::memory_order_acquire) != READY) continue;
        const uint64_t generation = _slots[i].snapshot.generation;
        if (generation > best_generation) { best = i; best_generation = generation; }
    }
    if (best >= _slots.size()) return false;
    uint8_t expected = READY;
    if (!_slots[best].state.compare_exchange_strong(expected, READING,
            std::memory_order_acq_rel, std::memory_order_acquire)) return false;
    index = best;
    return true;
}

void RuntimeEventsSnapshotRing::release(uint32_t index) {
    if (index < _slots.size()) _slots[index].state.store(FREE, std::memory_order_release);
}

void RuntimeEventsSnapshotRing::reset() {
    for (Slot &slot : _slots) {
        slot.snapshot = RuntimeEventsSnapshot{};
        slot.state.store(FREE, std::memory_order_relaxed);
    }
    _published_generation.store(0, std::memory_order_relaxed);
    _publish_drop_count.store(0, std::memory_order_relaxed);
}

bool RuntimeEventsSnapshotRing::self_test() {
    RuntimeEventsSnapshotRing ring;
    uint32_t slot = 0;
    if (!ring.try_begin_write(slot)) return false;
    ring.write_buffer(slot).generation = 3;
    ring.publish(slot);
    uint32_t read = 0;
    if (!ring.try_acquire_latest(2, read) || ring.read_buffer(read).generation != 3) return false;
    ring.release(read);
    return !ring.try_acquire_latest(3, read);
}

} // namespace pk

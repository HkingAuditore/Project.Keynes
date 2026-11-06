#include "native_simulation_host.h"
#include <type_traits>

namespace pk {
namespace {
struct Writer {
    std::vector<uint8_t> bytes;
    template<class T> bool field(T &value) {
        const uint64_t bits = static_cast<uint64_t>(value);
        for (size_t i = 0; i < sizeof(T); ++i) bytes.push_back(uint8_t(bits >> (8u * i)));
        return true;
    }
};
struct Reader {
    const std::vector<uint8_t> &bytes;
    size_t cursor = 0;
    template<class T> bool field(T &value) {
        if (sizeof(T) > bytes.size() - cursor) return false;
        uint64_t bits = 0;
        for (size_t i = 0; i < sizeof(T); ++i) bits |= uint64_t(bytes[cursor++]) << (8u * i);
        value = static_cast<T>(bits);
        return true;
    }
};
template<class IO> bool fields(IO &io, RuntimeTriggerEffectIntent &v) {
    if (!(io.field(v.id) && io.field(v.effective_day) && io.field(v.source_priority) &&
        io.field(v.trigger_id) && io.field(v.effect_definition_id) && io.field(v.target_handle) &&
        io.field(v.target_generation) && io.field(v.fire_sequence) && io.field(v.action) &&
        io.field(v.domain) && io.field(v.opcode) && io.field(v.resolved_value) &&
        io.field(v.duration_days) && io.field(v.stacks))) return false;
    for (auto &item : v.payload) if (!io.field(item)) return false;
    return true;
}
template<class IO> bool fields(IO &io, RuntimeDomainAck &v) {
    return io.field(v.request_id) && io.field(v.transaction_id) && io.field(v.target_handle) &&
        io.field(v.target_generation) && io.field(v.domain) && io.field(v.code) &&
        io.field(v.effective_day) && io.field(v.producer_id) && io.field(v.sequence) &&
        io.field(v.technology_flags);
}
}
std::vector<uint8_t> NativeSimulationHost::encode_trigger_transport() const {
    std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
    Writer out;
    uint32_t magic = 0x31514354u; // TCQ1, independent of the Trigger authority TPD1.
    out.field(magic);
    auto published = _trigger_published_intent_id;
    out.field(published);
    auto request_cursor = _command_request_id.load(std::memory_order_acquire);
    out.field(request_cursor);
    uint32_t count = static_cast<uint32_t>(_trigger_intents.size());
    out.field(count);
    for (auto item : _trigger_intents) fields(out, item);
    count = static_cast<uint32_t>(_trigger_acks.size());
    out.field(count);
    for (auto item : _trigger_acks) fields(out, item);
    return std::move(out.bytes);
}
bool NativeSimulationHost::restore_trigger_transport(const std::vector<uint8_t> &bytes,
        std::string &error, bool install) {
    Reader in{bytes};
    uint32_t magic = 0, count = 0;
    int64_t published = 0;
    uint64_t request_cursor = 0;
    std::deque<RuntimeTriggerEffectIntent> intents;
    std::deque<RuntimeDomainAck> acks;
    auto invalid = [&]() { error = "trigger_transport_continuation_invalid"; return false; };
    if (!in.field(magic) || magic != 0x31514354u || !in.field(published) || published < 0 ||
        !in.field(request_cursor) || !in.field(count) || count > RUNTIME_DOMAIN_INTENT_CAPACITY || count > (bytes.size() - in.cursor) / 108u) return invalid();
    for (uint32_t i = 0; i < count; ++i) {
        RuntimeTriggerEffectIntent item;
        if (!fields(in, item) || item.id <= 0 || item.id > published || item.effective_day < 0) return invalid();
        intents.push_back(item);
    }
    if (!in.field(count) || count > RUNTIME_DOMAIN_INTENT_CAPACITY || count > (bytes.size() - in.cursor) / 53u) return invalid();
    for (uint32_t i = 0; i < count; ++i) {
        RuntimeDomainAck item;
        if (!fields(in, item) || item.transaction_id == 0 || item.effective_day < 0 ||
            static_cast<uint16_t>(item.code) > static_cast<uint16_t>(RuntimeDomainAckCode::STALE_GENERATION)) return invalid();
        acks.push_back(item);
    }
    if (in.cursor != bytes.size()) return invalid();
    if (install) {
        std::lock_guard<std::mutex> lock(_trigger_transport_mutex);
        _trigger_intents = std::move(intents);
        _trigger_acks = std::move(acks);
        _trigger_published_intent_id = published;
        // Journals also contain caller-supplied IDs from separate namespaces.
        // Their maximum is not the Host allocator's continuation cursor.
        _command_request_id.store(request_cursor, std::memory_order_release);
    }
    return true;
}
} // namespace pk

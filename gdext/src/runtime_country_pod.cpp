#include "runtime_resolve_contract.h"
#include "runtime_country_pod.h"
#include "runtime_country_pod_internal.h"
#include "country_core_apply.h"
#include "country_core.h"
#include "country_api.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace pk {

namespace {
constexpr uint32_t COUNTRY_SECTION_MARKER = 0x32445043u; // CPD2
constexpr uint32_t COUNTRY_SECTION_ABI = 3u;
constexpr uint32_t COUNTRY_COMMAND_CAPACITY = RUNTIME_COMMAND_QUEUE_CAPACITY;
constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

void copy_reason(char *dst, size_t capacity, const std::string &value) {
    if (capacity == 0) return;
    const size_t count = std::min(capacity - 1u, value.size());
    std::memcpy(dst, value.data(), count);
    dst[count] = '\0';
}

uint64_t checksum(const uint8_t *data, size_t size) noexcept {
    uint64_t hash = FNV_OFFSET;
    for (size_t i = 0; i < size; ++i) {
        hash ^= data[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

void append_u8(std::vector<uint8_t> &out, uint8_t value) { out.push_back(value); }
void append_u32(std::vector<uint8_t> &out, uint32_t value) {
    for (uint32_t i = 0; i < 4; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}
void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (uint32_t i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8u)) & 0xffu));
}
void append_i64(std::vector<uint8_t> &out, int64_t value) {
    append_u64(out, static_cast<uint64_t>(value));
}
void append_i32(std::vector<uint8_t> &out, int32_t value) {
    append_u32(out, static_cast<uint32_t>(value));
}
template <size_t N>
void append_fixed_text(std::vector<uint8_t> &out,
                       const std::array<char, N> &value) {
    out.insert(out.end(), value.begin(), value.end());
}
void append_f64(std::vector<uint8_t> &out, double value) {
    uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    append_u64(out, bits);
}

template <typename T>
void append_vector(std::vector<uint8_t> &out, const std::vector<T> &values);

template <>
void append_vector<uint8_t>(std::vector<uint8_t> &out,
                            const std::vector<uint8_t> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    out.insert(out.end(), values.begin(), values.end());
}
template <>
void append_vector<int32_t>(std::vector<uint8_t> &out,
                            const std::vector<int32_t> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    for (int32_t value : values) append_i32(out, value);
}
template <>
void append_vector<uint32_t>(std::vector<uint8_t> &out,
                             const std::vector<uint32_t> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    for (uint32_t value : values) append_u32(out, value);
}
template <>
void append_vector<uint64_t>(std::vector<uint8_t> &out,
                             const std::vector<uint64_t> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    for (uint64_t value : values) append_u64(out, value);
}
template <>
void append_vector<int64_t>(std::vector<uint8_t> &out,
                            const std::vector<int64_t> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    for (int64_t value : values) append_i64(out, value);
}
template <>
void append_vector<double>(std::vector<uint8_t> &out,
                            const std::vector<double> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    for (double value : values) append_f64(out, value);
}

void append_strings(std::vector<uint8_t> &out,
                    const std::vector<std::string> &values) {
    append_u32(out, static_cast<uint32_t>(values.size()));
    for (const std::string &value : values) {
        append_u32(out, static_cast<uint32_t>(value.size()));
        out.insert(out.end(), value.begin(), value.end());
    }
}

struct Reader {
    const uint8_t *data = nullptr;
    size_t size = 0;
    size_t cursor = 0;

    bool bytes(size_t count, const uint8_t *&out) {
        if (cursor > size || size - cursor < count) return false;
        out = data + cursor;
        cursor += count;
        return true;
    }
    bool u8(uint8_t &value) {
        const uint8_t *ptr = nullptr;
        if (!bytes(1, ptr)) return false;
        value = *ptr;
        return true;
    }
    bool u32(uint32_t &value) {
        const uint8_t *ptr = nullptr;
        if (!bytes(4, ptr)) return false;
        value = static_cast<uint32_t>(ptr[0]) |
                (static_cast<uint32_t>(ptr[1]) << 8u) |
                (static_cast<uint32_t>(ptr[2]) << 16u) |
                (static_cast<uint32_t>(ptr[3]) << 24u);
        return true;
    }
    bool peek_u32(uint32_t &value) const {
        if (cursor > size || size - cursor < 4) return false;
        const uint8_t *ptr = data + cursor;
        value = static_cast<uint32_t>(ptr[0]) |
                (static_cast<uint32_t>(ptr[1]) << 8u) |
                (static_cast<uint32_t>(ptr[2]) << 16u) |
                (static_cast<uint32_t>(ptr[3]) << 24u);
        return true;
    }
    bool u64(uint64_t &value) {
        const uint8_t *ptr = nullptr;
        if (!bytes(8, ptr)) return false;
        value = 0;
        for (uint32_t i = 0; i < 8; ++i)
            value |= static_cast<uint64_t>(ptr[i]) << (i * 8u);
        return true;
    }
    bool i32(int32_t &value) {
        uint32_t raw = 0;
        if (!u32(raw)) return false;
        value = static_cast<int32_t>(raw);
        return true;
    }
    bool i64(int64_t &value) {
        uint64_t raw = 0;
        if (!u64(raw)) return false;
        value = static_cast<int64_t>(raw);
        return true;
    }
    bool f64(double &value) {
        uint64_t raw = 0;
        if (!u64(raw)) return false;
        static_assert(sizeof(raw) == sizeof(value));
        std::memcpy(&value, &raw, sizeof(value));
        return true;
    }
    bool strings(std::vector<std::string> &out, uint32_t max_count) {
        uint32_t count = 0;
        if (!u32(count) || count > max_count) return false;
        out.resize(count);
        for (std::string &value : out) {
            uint32_t length = 0;
            if (!u32(length) || length > 4096u) return false;
            const uint8_t *ptr = nullptr;
            if (!bytes(length, ptr)) return false;
            value.assign(reinterpret_cast<const char *>(ptr), length);
        }
        return true;
    }

    template <typename T>
    bool vector(std::vector<T> &out, uint32_t max_count);
};

template <>
bool Reader::vector<uint8_t>(std::vector<uint8_t> &out, uint32_t max_count) {
    uint32_t count = 0;
    const uint8_t *ptr = nullptr;
    if (!u32(count) || count > max_count || !bytes(count, ptr)) return false;
    out.assign(ptr, ptr + count);
    return true;
}
template <>
bool Reader::vector<int32_t>(std::vector<int32_t> &out, uint32_t max_count) {
    uint32_t count = 0;
    if (!u32(count) || count > max_count) return false;
    out.resize(count);
    for (int32_t &value : out) if (!i32(value)) return false;
    return true;
}
template <>
bool Reader::vector<uint32_t>(std::vector<uint32_t> &out, uint32_t max_count) {
    uint32_t count = 0;
    if (!u32(count) || count > max_count) return false;
    out.resize(count);
    for (uint32_t &value : out) if (!u32(value)) return false;
    return true;
}
template <>
bool Reader::vector<uint64_t>(std::vector<uint64_t> &out, uint32_t max_count) {
    uint32_t count = 0;
    if (!u32(count) || count > max_count) return false;
    out.resize(count);
    for (uint64_t &value : out) if (!u64(value)) return false;
    return true;
}
template <>
bool Reader::vector<int64_t>(std::vector<int64_t> &out, uint32_t max_count) {
    uint32_t count = 0;
    if (!u32(count) || count > max_count) return false;
    out.resize(count);
    for (int64_t &value : out) if (!i64(value)) return false;
    return true;
}
template <>
bool Reader::vector<double>(std::vector<double> &out, uint32_t max_count) {
    uint32_t count = 0;
    if (!u32(count) || count > max_count) return false;
    out.resize(count);
    for (double &value : out) if (!f64(value)) return false;
    return true;
}

bool same_target_ack(const RuntimeDomainIntent &intent,
                     const RuntimeDomainAck &ack) noexcept {
    return (ack.transaction_id == intent.source_id ||
            ack.request_id == intent.source_id) &&
           ack.target_handle == intent.target_handle &&
           ack.target_generation == intent.target_generation &&
           ack.domain == intent.target_domain;
}

void append_command(std::vector<uint8_t> &out,
                    const RuntimeCountryCommand &command) {
    append_u64(out, command.request_id);
    append_u32(out, command.producer_id);
    append_u64(out, command.sequence);
    append_u64(out, command.observed_generation);
    append_i64(out, command.requested_day);
    append_i64(out, command.effective_day);
    append_u32(out, command.opcode);
    append_u64(out, command.target_handle);
    append_i32(out, command.cell);
    append_i32(out, command.aux);
    append_i32(out, command.domain);
    append_i32(out, command.position);
    for (int32_t value : command.weights_bp) append_i32(out, value);
    append_i32(out, command.tax_kind);
    append_i32(out, command.tax_item);
    append_i32(out, command.tax_rate_basis_points);
    append_i32(out, command.tax_assessment_mode);
    append_i64(out, command.value);
    append_fixed_text(out, command.stable_id);
    append_fixed_text(out, command.display_name);
}

bool read_command(Reader &reader, RuntimeCountryCommand &command) {
    uint64_t request = 0, sequence = 0, observed = 0, target = 0;
    uint32_t producer = 0, opcode = 0;
    int64_t requested = 0, effective = 0, value = 0;
    int32_t cell = -1, aux = -1, domain = -1, position = -1;
    if (!reader.u64(request) || !reader.u32(producer) || !reader.u64(sequence) ||
        !reader.u64(observed) || !reader.i64(requested) ||
        !reader.i64(effective) || !reader.u32(opcode) ||
        !reader.u64(target) || !reader.i32(cell) ||
        !reader.i32(aux) || !reader.i32(domain) ||
        !reader.i32(position)) return false;
    command = RuntimeCountryCommand{};
    command.request_id = request;
    command.producer_id = producer;
    command.sequence = sequence;
    command.observed_generation = observed;
    command.requested_day = requested;
    command.effective_day = effective;
    command.opcode = static_cast<uint16_t>(opcode);
    command.target_handle = target;
    command.cell = cell;
    command.aux = aux;
    command.domain = domain;
    command.position = position;
    for (int32_t &weight : command.weights_bp)
        if (!reader.i32(weight)) return false;
    if (!reader.i32(command.tax_kind) || !reader.i32(command.tax_item) ||
        !reader.i32(command.tax_rate_basis_points) ||
        !reader.i32(command.tax_assessment_mode) || !reader.i64(value)) return false;
    const uint8_t *stable = nullptr;
    const uint8_t *display = nullptr;
    if (!reader.bytes(command.stable_id.size(), stable) ||
        !reader.bytes(command.display_name.size(), display)) return false;
    std::memcpy(command.stable_id.data(), stable, command.stable_id.size());
    std::memcpy(command.display_name.data(), display, command.display_name.size());
    command.stable_id.back() = '\0';
    command.display_name.back() = '\0';
    command.value = value;
    return true;
}

} // namespace

namespace {
constexpr size_t COUNTRY_COMMAND_WIRE_SIZE = 112u + RUNTIME_COUNTRY_STABLE_ID_CAPACITY +
    RUNTIME_COUNTRY_DISPLAY_NAME_CAPACITY;
static_assert(COUNTRY_COMMAND_WIRE_SIZE <= RUNTIME_MAX_COMMAND_PAYLOAD);
}

#include "runtime_country_pod_command_adapter.inc"

RuntimeCountryPodAuthority::RuntimeCountryPodAuthority() {
    _pending.reserve(COUNTRY_COMMAND_CAPACITY);
    _receipt_scratch.reserve(COUNTRY_COMMAND_CAPACITY);
    _intent_scratch.reserve(RUNTIME_DOMAIN_INTENT_CAPACITY);
}

bool RuntimeCountryPodAuthority::bootstrap(
        const RuntimeCountryPodSnapshot &snapshot,
        const RuntimeCountryPodCatalog &catalog, std::string &error) {
    error.clear();
    if (!validate_catalog(catalog, error)) return false;
    if (!validate_state(snapshot, error)) return false;
    if (snapshot.catalog_hash != catalog.catalog_hash ||
        snapshot.technology_count != catalog.technology_count ||
        snapshot.technology_words != catalog.technology_words) {
        error = "country_catalog_hash_mismatch";
        return false;
    }
    _state = snapshot;
    country_core_repair_research_active_index(_state);
    // Older diagnostic captures did not carry a transport session. They are
    // safe to normalize at the authority boundary; a persisted ABI-2 section
    // must always contain the explicit non-zero session value.
    if (_state.session_epoch == 0) _state.session_epoch = 1;
    _catalog = catalog;
    _pending.clear();
    _receipt_scratch.clear();
    _intent_scratch.clear();
    _state.state_hash = hash_business_state(_state);
    _bootstrapped = true;
    _plan_active = false;
    _next_generation = _state.generation + 1u;
    return true;
}

bool RuntimeCountryPodAuthority::validate_target(
        const RuntimeCountryPodSnapshot &state,
        const RuntimeCountryCommand &command, int32_t &slot,
        std::string &error) const {
    return country_core_validate_target(state, command, slot, error);
}

bool RuntimeCountryPodAuthority::research_condition_met(
        const RuntimeCountryPodSnapshot &state, int32_t slot,
        int32_t technology) const {
    return country_core_research_condition_met(state, _catalog, slot, technology);
}

bool RuntimeCountryPodAuthority::technology_prerequisites_met(
        const RuntimeCountryPodSnapshot &state, int32_t slot,
        int32_t technology) const {
    return country_core_technology_prerequisites_met(
        state, _catalog, slot, technology);
}

bool RuntimeCountryPodAuthority::queue_command(
        const RuntimeCountryCommand &command, std::string &error) {
    error.clear();
    if (!_bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    if (_pending.size() >= COUNTRY_COMMAND_CAPACITY) {
        error = "command_queue_capacity_exceeded";
        return false;
    }
    if (!RuntimeCountryPodAdapter::validate_command(command, error)) return false;
    // RuntimeCountryCommand::domain is an opcode payload lane (for example a
    // research domain), not the RuntimeDomainId carried by the outer packet
    // envelope. Command-specific validation owns its legal range.
    // An observed-generation mismatch is intentionally deferred to the day
    // preflight. The command remains ordered and receives a deterministic
    // stale-generation receipt; queue admission must not rewrite its
    // business semantics or silently drop it.
    if (command.effective_day <= _state.committed_day) {
        error = "country_command_day_already_committed";
        return false;
    }
    return resolve_enqueue<ResolveFlow::CountryCommand>(_pending, command, COUNTRY_COMMAND_CAPACITY) == ResolveResult::Accepted;
}

#include "runtime_country_pod_research.inc"
void RuntimeCountryPodAuthority::remove_pending_commands(
        const std::vector<uint64_t> &request_ids) noexcept {
    if (request_ids.empty() || _pending.empty()) return;
    _pending.erase(std::remove_if(_pending.begin(), _pending.end(),
        [&request_ids](const RuntimeCountryCommand &command) {
            return std::find(request_ids.begin(), request_ids.end(),
                             command.request_id) != request_ids.end();
        }), _pending.end());
}

size_t RuntimeCountryPodAuthority::remove_pending_producer(
        uint64_t producer_id) noexcept {
    const size_t before = _pending.size();
    _pending.erase(std::remove_if(_pending.begin(), _pending.end(),
        [producer_id](const RuntimeCountryCommand &command) {
            return command.producer_id == producer_id;
        }), _pending.end());
    return before - _pending.size();
}

bool RuntimeCountryPodAuthority::apply_command(
        RuntimeCountryPodSnapshot &state, const RuntimeCountryCommand &command,
        RuntimeCountryPodPlan &plan, std::string &error) const {
    return country_core_apply_command(state, _catalog, command, plan, error);
}

void RuntimeCountryPodAuthority::rebuild_territory_csr(
        RuntimeCountryPodSnapshot &state) const {
    country_core_rebuild_territory_csr(state);
}

uint64_t RuntimeCountryPodAuthority::hash_business_state(
        const RuntimeCountryPodSnapshot &state) {
    return country_core_hash_business_state(state);
}

#include "runtime_country_pod_daily_plan.inc"
bool RuntimeCountryPodAuthority::commit_day(
        RuntimeCountryPodPlan &plan, const std::vector<RuntimeDomainAck> &acks,
        std::string &error) {
    error.clear();
    if (!_bootstrapped || !_plan_active || plan.preflight_ok == 0 ||
        plan.header.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
        plan.header.base_generation != _state.generation ||
        plan.header.day != _state.committed_day + 1) {
        error = "country_plan_commit_invalid";
        return false;
    }
    struct PendingActivation {
        int32_t slot = -1;
        int32_t technology = -1;
        uint8_t peer_flags = 0;
    };
    std::vector<PendingActivation> activations;
    activations.reserve(plan.intents.size());
    for (const RuntimeDomainIntent &intent : plan.intents) {
        const auto it = std::find_if(acks.begin(), acks.end(),
            [&](const RuntimeDomainAck &ack) { return same_target_ack(intent, ack); });
        if (it == acks.end()) {
            error = "country_ack_barrier_missing";
            return false;
        }
        if (it->code != RuntimeDomainAckCode::OK) {
            error = it->code == RuntimeDomainAckCode::STALE_GENERATION
                ? "country_ack_stale_generation" : "country_ack_rejected";
            return false;
        }
        if (intent.opcode == static_cast<uint16_t>(
                CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT) ||
            intent.opcode == static_cast<uint16_t>(
                CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT) ||
            intent.opcode == static_cast<uint16_t>(
                CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER)) {
            const int64_t raw_technology = intent.payload[0];
            if (raw_technology < 0 ||
                raw_technology >= static_cast<int64_t>(_state.technology_count)) {
                error = "country_ack_technology_invalid";
                return false;
            }
            uint8_t peer_flags = it->technology_flags;
            // Older adapters only returned a typed OK. Preserve their
            // semantics while newer adapters can report the precise flags.
            if (peer_flags == 0) {
                peer_flags = intent.opcode == static_cast<uint16_t>(
                    CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER)
                    ? COUNTRY_PEER_MODIFIER_APPLIED
                    : COUNTRY_PEER_EFFECT_FIRE_ACKED;
            }
            activations.push_back(PendingActivation{
                static_cast<int32_t>(intent.target_handle & 0xffffffffULL),
                static_cast<int32_t>(raw_technology), peer_flags});
        }
        ++plan.header.ack_count;
    }
    RuntimeCountryPodSnapshot next = plan.next_state;
    for (const PendingActivation &activation : activations) {
        if (!activate_pending_technology(
                next, activation.slot, activation.technology, plan,
                activation.peer_flags, error)) {
            return false;
        }
    }
    const bool changed = plan.header.dirty_families != 0 || !plan.commands.empty();
    next.committed_day = plan.header.day;
    if (changed) next.generation = _next_generation++;
    next.state_hash = hash_business_state(next);
    _state = std::move(next);
    // The plan took every due queued command. Internal observations never
    // occupy that queue, so removing them must not scan it once per signal.
    _pending.erase(std::remove_if(_pending.begin(), _pending.end(),
        [&](const RuntimeCountryCommand &queued) {
            return queued.effective_day <= plan.header.day;
        }), _pending.end());
    for (const RuntimeCountryCommand &command : plan.commands) {
        RuntimeCommandReceipt receipt;
        receipt.request_id = command.request_id;
        receipt.producer_id = command.producer_id;
        receipt.sequence = command.sequence;
        receipt.effective_day = command.effective_day;
        receipt.generation = _state.generation;
        receipt.code = RuntimeReceiptCode::OK;
        plan.receipts.push_back(receipt);
    }
    plan.header.base_generation = _state.generation;
    plan.header.state_hash = _state.state_hash;
    plan.header.preflight_ok = 1;
    plan.committed = 1;
    _plan_active = false;
    return true;
}

#include "runtime_country_pod_rejected_commit.inc"
#include "runtime_country_pod_checkpoint.inc"
#include "runtime_country_pod_selftest.inc"

} // namespace pk

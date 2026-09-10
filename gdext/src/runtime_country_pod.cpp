#include "runtime_country_pod.h"
#include "country_core.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

namespace pk {

namespace {
constexpr uint32_t COUNTRY_SECTION_MARKER = 0x32445043u; // CPD2
constexpr uint32_t COUNTRY_SECTION_ABI = 2u;
constexpr uint32_t COUNTRY_QUEUE_SLOTS = 8u;
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

template <typename T>
uint64_t hash_vector(uint64_t hash, const std::vector<T> &values) noexcept {
    const uint32_t count = static_cast<uint32_t>(values.size());
    for (size_t i = 0; i < sizeof(count); ++i) {
        hash ^= static_cast<uint8_t>(count >> (i * 8u));
        hash *= FNV_PRIME;
    }
    if (!values.empty()) {
        const auto *bytes = reinterpret_cast<const uint8_t *>(values.data());
        for (size_t i = 0; i < values.size() * sizeof(T); ++i) {
            hash ^= bytes[i];
            hash *= FNV_PRIME;
        }
    }
    return hash;
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

bool RuntimeCountryPodAdapter::validate_snapshot(
        const RuntimeCountryPodSnapshot &snapshot, std::string &error) {
    error.clear();
    if (!snapshot.bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    if (snapshot.last_research_day > snapshot.committed_day) {
        error = "country_pod_research_day_ahead_of_state";
        return false;
    }
    const size_t countries = snapshot.country_count;
    const size_t cells = snapshot.cell_count;
    if (snapshot.country_stable_ids.size() != countries ||
        snapshot.country_display_names.size() != countries ||
        snapshot.profession_count == 0 || snapshot.building_type_count == 0) {
        error = "country_pod_identity_or_tax_catalog_missing";
        return false;
    }
    if (snapshot.country_active.size() != countries ||
        snapshot.country_generation.size() != countries ||
        snapshot.territory_count.size() != countries ||
        snapshot.country_cash.size() != countries ||
        snapshot.cell_country_slot.size() != cells ||
        (!snapshot.is_water.empty() && snapshot.is_water.size() != cells)) {
        error = "country_pod_snapshot_shape_mismatch";
        return false;
    }
    if (snapshot.technology_words > 0 &&
        snapshot.country_technologies.size() != countries * snapshot.technology_words) {
        error = "country_pod_technology_shape_mismatch";
        return false;
    }
    if (snapshot.technology_words > 0 &&
        snapshot.country_pending_technologies.size() != countries * snapshot.technology_words) {
        error = "country_pod_pending_shape_mismatch";
        return false;
    }
    if (snapshot.country_state_version.size() != countries ||
        snapshot.country_goods.size() != countries * snapshot.good_count ||
        snapshot.territory_offsets.size() != countries + 1u ||
        snapshot.territory_cells.size() !=
            static_cast<size_t>(snapshot.territory_offsets.empty()
                                    ? 0 : snapshot.territory_offsets.back()) ||
        snapshot.research_auto_purchase.size() != countries ||
        snapshot.research_daily_budgets.size() != countries ||
        snapshot.research_deferred_points.size() != countries ||
        snapshot.research_progress_total.size() != countries ||
        snapshot.research_completed_total.size() != countries ||
        snapshot.research_purchased_total.size() != countries ||
        snapshot.research_consumed_total.size() != countries ||
        snapshot.research_progress.size() != countries * snapshot.technology_count ||
        snapshot.research_cost_factor.size() != countries ||
        snapshot.research_efficiency.size() != countries * 4u ||
        snapshot.research_peer_flags.size() != countries * snapshot.technology_count) {
        error = "country_pod_authority_state_shape_mismatch";
        return false;
    }
    if (snapshot.research_signal_words != 0 &&
        snapshot.country_research_signals.size() !=
            countries * snapshot.research_signal_words) {
        error = "country_pod_signal_shape_mismatch";
        return false;
    }
    if (snapshot.research_signal_evidence_offsets.size() != countries + 1u ||
        snapshot.research_signal_evidence_offsets.empty() ||
        snapshot.research_signal_evidence_offsets.front() != 0 ||
        snapshot.research_signal_evidence_offsets.back() !=
            static_cast<int32_t>(snapshot.research_signal_evidence.size())) {
        error = "country_pod_signal_evidence_csr_invalid";
        return false;
    }
    for (size_t i = 1; i < snapshot.research_signal_evidence_offsets.size(); ++i) {
        if (snapshot.research_signal_evidence_offsets[i] <
            snapshot.research_signal_evidence_offsets[i - 1u]) {
            error = "country_pod_signal_evidence_csr_invalid";
            return false;
        }
    }
    for (const auto &entry : snapshot.research_signal_evidence) {
        if (entry.signal < 0 || entry.signal >= static_cast<int32_t>(snapshot.research_signal_count) ||
            entry.count < 0 || entry.first_day > entry.last_day) {
            error = "country_pod_signal_evidence_invalid";
            return false;
        }
    }
    if (snapshot.territory_offsets.empty() || snapshot.territory_offsets.front() != 0) {
        error = "country_pod_territory_csr_invalid";
        return false;
    }
    for (size_t i = 1; i < snapshot.territory_offsets.size(); ++i) {
        if (snapshot.territory_offsets[i] < snapshot.territory_offsets[i - 1]) {
            error = "country_pod_territory_csr_invalid";
            return false;
        }
    }
    int32_t previous_active_slot = -1;
    for (const int32_t active_slot : snapshot.research_active_country_slots) {
        if (active_slot < 0 || active_slot >= static_cast<int32_t>(countries) ||
            active_slot <= previous_active_slot ||
            snapshot.country_active[static_cast<size_t>(active_slot)] == 0) {
            error = "country_pod_active_index_invalid";
            return false;
        }
        previous_active_slot = active_slot;
    }
    if (snapshot.research_weights_bp.size() != countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT ||
        snapshot.research_queue_lengths.size() != countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) {
        error = "country_pod_research_shape_mismatch";
        return false;
    }
    for (size_t cell = 0; cell < cells; ++cell) {
        const int32_t owner = snapshot.cell_country_slot[cell];
        if (owner < -1 || owner >= static_cast<int32_t>(countries)) {
            error = "country_pod_invalid_cell_owner";
            return false;
        }
        if (!snapshot.is_water.empty() && snapshot.is_water[cell] != 0 && owner != -1) {
            error = "country_pod_water_owned";
            return false;
        }
    }
    std::vector<int32_t> territory_seen(cells, -1);
    for (size_t slot = 0; slot < countries; ++slot) {
        const int32_t begin = snapshot.territory_offsets[slot];
        const int32_t end = snapshot.territory_offsets[slot + 1u];
        if (begin < 0 || end < begin ||
            end > static_cast<int32_t>(snapshot.territory_cells.size())) {
            error = "country_pod_territory_csr_invalid";
            return false;
        }
        if (snapshot.country_active[slot] != 0 && end - begin == 0) {
            error = "country_pod_active_country_without_territory";
            return false;
        }
        if (snapshot.territory_count[slot] != end - begin) {
            error = "country_pod_territory_count_mismatch";
            return false;
        }
        for (int32_t cursor = begin; cursor < end; ++cursor) {
            const int32_t cell = snapshot.territory_cells[static_cast<size_t>(cursor)];
            if (cell < 0 || cell >= static_cast<int32_t>(cells) ||
                territory_seen[static_cast<size_t>(cell)] != -1 ||
                snapshot.cell_country_slot[static_cast<size_t>(cell)] !=
                    static_cast<int32_t>(slot) ||
                (!snapshot.is_water.empty() && snapshot.is_water[static_cast<size_t>(cell)] != 0)) {
                error = "country_pod_territory_csr_invalid";
                return false;
            }
            territory_seen[static_cast<size_t>(cell)] = static_cast<int32_t>(slot);
        }
    }
    for (size_t slot = 0; slot < countries; ++slot) {
        if (snapshot.country_active[slot] != 0 && snapshot.country_generation[slot] == 0) {
            error = "country_pod_invalid_country_generation";
            return false;
        }
        if (snapshot.territory_count[slot] < 0 || snapshot.country_cash[slot] < 0) {
            error = "country_pod_negative_country_state";
            return false;
        }
        if (snapshot.research_auto_purchase[slot] > 1 ||
            snapshot.research_daily_budgets[slot] < 0 ||
            snapshot.research_deferred_points[slot] < 0 ||
            snapshot.research_progress_total[slot] < 0 ||
            snapshot.research_completed_total[slot] < 0 ||
            snapshot.research_purchased_total[slot] < 0 ||
            snapshot.research_consumed_total[slot] < 0) {
            error = "country_pod_negative_research_state";
            return false;
        }
        if (!(snapshot.research_cost_factor[slot] > 0.0) ||
            !std::isfinite(snapshot.research_cost_factor[slot])) {
            error = "country_pod_invalid_research_cost_factor";
            return false;
        }
        for (uint32_t domain = 0; domain < 4u; ++domain) {
            const double efficiency = snapshot.research_efficiency[
                slot * 4u + domain];
            if (!(efficiency > 0.0) || !std::isfinite(efficiency)) {
                error = "country_pod_invalid_research_efficiency";
                return false;
            }
        }
        for (uint32_t technology = 0;
             technology < snapshot.technology_count; ++technology) {
            const int64_t progress = snapshot.research_progress[
                slot * snapshot.technology_count + technology];
            if (progress < 0) {
                error = "country_pod_negative_research_progress";
                return false;
            }
        }
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            const int32_t weight = snapshot.research_weights_bp[
                slot * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT + domain];
            if (weight < 0 || weight > 10000) {
                error = "country_pod_invalid_research_weight";
                return false;
            }
        }
        const auto begin = snapshot.research_weights_bp.begin() +
            static_cast<ptrdiff_t>(slot * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT);
        if (!runtime_country_research_weights_valid({begin[0], begin[1], begin[2], begin[3]})) {
            error = "country_pod_research_weight_sum";
            return false;
        }
    }
    for (size_t index = 0; index < snapshot.research_queue_lengths.size(); ++index) {
        if (snapshot.research_queue_lengths[index] > COUNTRY_QUEUE_SLOTS) {
            error = "country_pod_research_queue_length_invalid";
            return false;
        }
    }
    return true;
}

bool RuntimeCountryPodAdapter::decode_command(
        const RuntimeCommandPacket &packet, RuntimeCountryCommand &command,
        std::string &error) {
    error.clear();
    const auto &envelope = packet.envelope;
    if (envelope.payload_offset > RUNTIME_MAX_COMMAND_PAYLOAD ||
        envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD ||
        envelope.payload_offset + envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD) {
        error = "invalid_command_payload";
        return false;
    }
    if (envelope.payload_size != sizeof(RuntimeCountryCommand)) {
        error = "invalid_country_command_payload_size";
        return false;
    }
    std::memcpy(&command, packet.payload.data() + envelope.payload_offset,
                sizeof(RuntimeCountryCommand));
    command.request_id = envelope.request_id;
    command.producer_id = envelope.producer_id;
    command.sequence = envelope.sequence;
    command.submit_order = packet.submit_order;
    command.observed_generation = envelope.observed_generation;
    command.requested_day = envelope.requested_day;
    command.effective_day = envelope.effective_day;
    return validate_command(command, error);
}

bool RuntimeCountryPodAdapter::validate_command(
        const RuntimeCountryCommand &command, std::string &error) {
    error.clear();
    if (command.request_id == 0 || command.sequence == 0 ||
        command.effective_day < command.requested_day) {
        error = "invalid_country_command_value";
        return false;
    }
    if (command.opcode == 5 && !runtime_country_research_weights_valid(command.weights_bp)) {
        error = "invalid_research_weights";
        return false;
    }
    if (command.cell < -1 || command.domain < -1 || command.position < -1) {
        error = "invalid_country_command_target";
        return false;
    }
    return true;
}

bool RuntimeCountryPodAdapter::execute_day(
        const RuntimeCountryPodSnapshot &snapshot,
        const RuntimeCountryDayContext &context,
        RuntimeCountryDayCommit &commit,
        RuntimeCountryPodDiagnostics &diagnostics) {
    commit = RuntimeCountryDayCommit{};
    diagnostics = RuntimeCountryPodDiagnostics{};
    if (context.day < 0 || !std::isfinite(context.speed_scale)) {
        commit.error_code = RuntimeCountryPodError::INVALID_CONTEXT;
        runtime_copy_text(diagnostics.blocker, "invalid_context");
        return false;
    }
    std::string error;
    if (!validate_snapshot(snapshot, error)) {
        commit.error_code = RuntimeCountryPodError::NOT_BOOTSTRAPPED;
        runtime_copy_text(diagnostics.blocker, error.c_str());
        return false;
    }
    uint64_t work = 0;
    uint32_t active = 0;
    uint32_t pending = 0;
    // Country maintains this sorted membership index whenever research
    // inputs change.  Iterating it avoids touching dormant countries on every
    // shadow/worker day.  Empty snapshots remain valid for old captures and
    // deliberately use the conservative full scan.
    const auto visit_slot = [&](uint32_t slot) {
        if (snapshot.country_active[slot] == 0) return;
        ++active;
        work += 1;
        const size_t base = static_cast<size_t>(slot) * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            const uint8_t length = snapshot.research_queue_lengths[base + domain];
            pending += length > 0 ? 1u : 0u;
            work += length;
        }
    };
    if (snapshot.research_active_index_valid) {
        for (const int32_t slot : snapshot.research_active_country_slots)
            visit_slot(static_cast<uint32_t>(slot));
    } else {
        for (uint32_t slot = 0; slot < snapshot.country_count; ++slot)
            visit_slot(slot);
    }
    commit.completed = 1;
    commit.preflight_ok = 1;
    commit.ack_required = 1; // Effect/Modifier/Economy ACK adapters are not migrated yet.
    commit.error_code = RuntimeCountryPodError::CROSS_DOMAIN_BARRIER_REQUIRED;
    commit.changed_countries = 0;
    commit.changed_territory_cells = 0;
    commit.research_work_units = work;
    commit.country_generation = snapshot.generation;
    commit.state_hash = snapshot.state_hash ^ static_cast<uint64_t>(context.day);
    if (active > 0) commit.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
    diagnostics.snapshot_generation = snapshot.generation;
    diagnostics.state_hash = commit.state_hash;
    diagnostics.work_units = work;
    diagnostics.active_country_count = active;
    diagnostics.active_index_count = !snapshot.research_active_index_valid
        ? snapshot.country_count
        : static_cast<uint32_t>(snapshot.research_active_country_slots.size());
    diagnostics.pending_checks = pending;
    diagnostics.ack_pending = 1;
    runtime_copy_text(diagnostics.blocker, "cross_domain_ack_adapter_missing");
    return true;
}

RuntimeCountryPodAuthority::RuntimeCountryPodAuthority() {
    _pending.reserve(COUNTRY_COMMAND_CAPACITY);
    _receipt_scratch.reserve(COUNTRY_COMMAND_CAPACITY);
    _intent_scratch.reserve(RUNTIME_DOMAIN_INTENT_CAPACITY);
}

bool RuntimeCountryPodAuthority::validate_catalog(
        const RuntimeCountryPodCatalog &catalog, std::string &error) const {
    error.clear();
    if (catalog.catalog_hash == 0 ||
        catalog.technology_words == 0 ||
        catalog.technology_words !=
            (catalog.technology_count + 63u) / 64u) {
        error = "country_catalog_shape_invalid";
        return false;
    }
    const size_t count = catalog.technology_count;
    if (catalog.technology_count == 0 || catalog.technology_costs.size() != count ||
        catalog.technology_domains.size() != count ||
        catalog.technology_flags.size() != count ||
        catalog.technology_effect_required.size() != count ||
        catalog.prerequisite_offsets.size() != count + 1u ||
        catalog.entry_milestone_indices.size() != count) {
        error = "country_catalog_shape_invalid";
        return false;
    }
    if (catalog.prerequisite_offsets.front() != 0 ||
        catalog.prerequisite_offsets.back() !=
            static_cast<int32_t>(catalog.prerequisites.size())) {
        error = "country_catalog_prerequisite_csr_invalid";
        return false;
    }
    for (size_t i = 1; i < catalog.prerequisite_offsets.size(); ++i) {
        if (catalog.prerequisite_offsets[i] < catalog.prerequisite_offsets[i - 1]) {
            error = "country_catalog_prerequisite_csr_invalid";
            return false;
        }
    }
    for (int32_t technology : catalog.prerequisites) {
        if (technology < 0 || technology >= static_cast<int32_t>(count)) {
            error = "country_catalog_prerequisite_target_invalid";
            return false;
        }
    }
    if (!catalog.milestone_offsets.empty()) {
        if (catalog.milestone_offsets.size() != count + 1u ||
            catalog.milestone_offsets.front() != 0 ||
            catalog.milestone_offsets.back() !=
                static_cast<int32_t>(catalog.milestone_candidates.size()) ||
            catalog.milestone_required_counts.size() != count) {
            error = "country_catalog_milestone_csr_invalid";
            return false;
        }
        for (size_t i = 1; i < catalog.milestone_offsets.size(); ++i)
            if (catalog.milestone_offsets[i] < catalog.milestone_offsets[i - 1]) {
                error = "country_catalog_milestone_csr_invalid";
                return false;
            }
        for (int32_t technology : catalog.milestone_candidates)
            if (technology < 0 || technology >= static_cast<int32_t>(count)) {
                error = "country_catalog_milestone_target_invalid";
                return false;
            }
    }
    if (catalog.research_conditions_complete) {
        if (catalog.research_condition_offsets.size() != count + 1u ||
            catalog.research_condition_offsets.front() != 0 ||
            catalog.research_condition_offsets.back() !=
                static_cast<int32_t>(catalog.research_condition_ops.size()) ||
            catalog.research_condition_ops.size() !=
                catalog.research_condition_refs.size() ||
            catalog.research_condition_ops.size() !=
                catalog.research_condition_values.size()) {
            error = "country_catalog_research_condition_csr_invalid";
            return false;
        }
    }
    for (size_t i = 0; i < count; ++i) {
        // Production catalogs use zero cost for non-researchable/content
        // placeholder entries. The authoritative core already rejects such
        // entries when they are queued; capture validation must not reject a
        // complete catalog merely because it contains those slots.
        if (catalog.technology_costs[i] < 0 ||
            catalog.technology_domains[i] < 0 ||
            catalog.technology_domains[i] >=
                static_cast<int32_t>(RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT)) {
            error = "country_catalog_technology_value_invalid";
            return false;
        }
        if (catalog.technology_effect_required[i] > 1u) {
            error = "country_catalog_effect_requirement_invalid";
            return false;
        }
    }
    return true;
}

bool RuntimeCountryPodAuthority::validate_state(
        const RuntimeCountryPodSnapshot &snapshot, std::string &error) const {
    if (!RuntimeCountryPodAdapter::validate_snapshot(snapshot, error)) return false;
    if (snapshot.catalog_hash == 0 || snapshot.technology_count == 0 ||
        snapshot.generation == 0) {
        error = "country_pod_capture_contract_incomplete";
        return false;
    }
    if (snapshot.territory_offsets.size() !=
        static_cast<size_t>(snapshot.country_count) + 1u ||
        snapshot.territory_offsets.front() != 0 ||
        snapshot.territory_offsets.back() !=
            static_cast<int32_t>(snapshot.territory_cells.size())) {
        error = "country_pod_territory_csr_invalid";
        return false;
    }
    return true;
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
    slot = -1;
    const uint32_t raw_slot = static_cast<uint32_t>(command.target_handle & 0xffffffffULL);
    const uint32_t generation = static_cast<uint32_t>(command.target_handle >> 32u);
    if (command.target_handle == 0 || raw_slot >= state.country_count ||
        state.country_active[raw_slot] == 0 ||
        state.country_generation[raw_slot] != generation) {
        error = "country_handle_invalid";
        return false;
    }
    slot = static_cast<int32_t>(raw_slot);
    return true;
}

bool RuntimeCountryPodAuthority::research_condition_met(
        const RuntimeCountryPodSnapshot &state, int32_t slot,
        int32_t technology) const {
    if (!_catalog.research_conditions_complete || slot < 0 ||
        slot >= static_cast<int32_t>(state.country_count) || technology < 0 ||
        technology >= static_cast<int32_t>(_catalog.technology_count)) return false;
    if (_catalog.research_condition_offsets.size() !=
        static_cast<size_t>(_catalog.technology_count) + 1u) return false;
    const int32_t begin = _catalog.research_condition_offsets[static_cast<size_t>(technology)];
    const int32_t end = _catalog.research_condition_offsets[static_cast<size_t>(technology + 1)];
    if (begin < 0 || end < begin || end > static_cast<int32_t>(_catalog.research_condition_ops.size()))
        return false;
    if (begin == end) return true;
    std::array<uint8_t, 128> stack{};
    int32_t depth = 0;
    const size_t word_base = static_cast<size_t>(slot) * _catalog.technology_words;
    const auto has_technology = [&](int32_t ref) {
        return ref >= 0 && ref < static_cast<int32_t>(_catalog.technology_count) &&
               (state.country_technologies[word_base + static_cast<size_t>(ref / 64)] &
                (uint64_t{1} << (ref % 64))) != 0;
    };
    const auto has_signal = [&](int32_t ref) {
        if (ref < 0 || ref >= static_cast<int32_t>(state.research_signal_count) ||
            state.research_signal_words == 0 ||
            state.country_research_signals.size() !=
                static_cast<size_t>(state.country_count) * state.research_signal_words)
            return false;
        const size_t index = static_cast<size_t>(slot) * state.research_signal_words +
                             static_cast<size_t>(ref / 64);
        return index < state.country_research_signals.size() &&
               (state.country_research_signals[index] & (uint64_t{1} << (ref % 64))) != 0;
    };
    const auto signal_count = [&](int32_t ref) {
        if (ref < 0 || ref >= static_cast<int32_t>(state.research_signal_count) ||
            state.research_signal_evidence_offsets.size() !=
                static_cast<size_t>(state.country_count) + 1u)
            return int32_t{0};
        const int32_t first = state.research_signal_evidence_offsets[static_cast<size_t>(slot)];
        const int32_t last = state.research_signal_evidence_offsets[static_cast<size_t>(slot + 1)];
        for (int32_t i = first; i < last; ++i)
            if (state.research_signal_evidence[static_cast<size_t>(i)].signal == ref)
                return state.research_signal_evidence[static_cast<size_t>(i)].count;
        return int32_t{0};
    };
    for (int32_t cursor = begin; cursor < end; ++cursor) {
        const int32_t op = _catalog.research_condition_ops[static_cast<size_t>(cursor)];
        const int32_t ref = _catalog.research_condition_refs[static_cast<size_t>(cursor)];
        const int64_t value = _catalog.research_condition_values[static_cast<size_t>(cursor)];
        if (op == 1) {
            if (depth >= static_cast<int32_t>(stack.size()) || ref < 0 ||
                ref >= static_cast<int32_t>(_catalog.technology_count)) return false;
            stack[static_cast<size_t>(depth++)] = has_technology(ref) ? 1u : 0u;
        } else if (op == 2) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[static_cast<size_t>(depth++)] = has_signal(ref) ? 1u : 0u;
        } else if (op == 3) {
            if (depth >= static_cast<int32_t>(stack.size())) return false;
            stack[static_cast<size_t>(depth++)] = signal_count(ref) >= value ? 1u : 0u;
        } else if (op == 13) {
            if (depth < 1) return false;
            stack[static_cast<size_t>(depth - 1)] =
                stack[static_cast<size_t>(depth - 1)] == 0 ? 1u : 0u;
        } else if (op == 10 || op == 11 || op == 12) {
            if (ref <= 0 || ref > depth) return false;
            int32_t truth_count = 0;
            for (int32_t i = depth - ref; i < depth; ++i)
                truth_count += stack[static_cast<size_t>(i)] != 0;
            depth -= ref;
            stack[static_cast<size_t>(depth++)] = op == 10
                ? (truth_count == ref ? 1u : 0u)
                : (op == 11 ? (truth_count > 0 ? 1u : 0u)
                            : (truth_count >= value ? 1u : 0u));
        } else {
            return false;
        }
    }
    return depth == 1 && stack[0] != 0;
}

bool RuntimeCountryPodAuthority::technology_prerequisites_met(
        const RuntimeCountryPodSnapshot &state, int32_t slot,
        int32_t technology) const {
    if (technology < 0 || technology >= static_cast<int32_t>(_catalog.technology_count) ||
        slot < 0 || slot >= static_cast<int32_t>(state.country_count)) return false;
    const size_t base = static_cast<size_t>(slot) * _catalog.technology_words;
    const auto has = [&](int32_t ref) {
        return ref >= 0 && ref < static_cast<int32_t>(_catalog.technology_count) &&
               (state.country_technologies[base + static_cast<size_t>(ref / 64)] &
                (uint64_t{1} << (ref % 64))) != 0;
    };
    if (technology < static_cast<int32_t>(_catalog.entry_milestone_indices.size())) {
        const int32_t entry = _catalog.entry_milestone_indices[static_cast<size_t>(technology)];
        if (entry >= 0 && !has(entry)) return false;
    }
    const int32_t milestone_begin = _catalog.milestone_offsets.empty()
        ? 0 : _catalog.milestone_offsets[static_cast<size_t>(technology)];
    const int32_t milestone_end = _catalog.milestone_offsets.empty()
        ? 0 : _catalog.milestone_offsets[static_cast<size_t>(technology + 1)];
    if (milestone_end > milestone_begin) {
        int32_t count = 0;
        for (int32_t edge = milestone_begin; edge < milestone_end; ++edge)
            if (has(_catalog.milestone_candidates[static_cast<size_t>(edge)])) ++count;
        return count >= _catalog.milestone_required_counts[static_cast<size_t>(technology)];
    }
    const int32_t begin = _catalog.prerequisite_offsets[static_cast<size_t>(technology)];
    const int32_t end = _catalog.prerequisite_offsets[static_cast<size_t>(technology + 1)];
    for (int32_t edge = begin; edge < end; ++edge)
        if (!has(_catalog.prerequisites[static_cast<size_t>(edge)])) return false;
    return true;
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
    if (command.domain != -1 &&
        command.domain != static_cast<int32_t>(RuntimeDomainId::COUNTRY)) {
        error = "country_command_domain_mismatch";
        return false;
    }
    // An observed-generation mismatch is intentionally deferred to the day
    // preflight. The command remains ordered and receives a deterministic
    // stale-generation receipt; queue admission must not rewrite its
    // business semantics or silently drop it.
    if (command.effective_day <= _state.committed_day) {
        error = "country_command_day_already_committed";
        return false;
    }
    _pending.push_back(command);
    return true;
}

bool RuntimeCountryPodAuthority::run_research_day(
        RuntimeCountryPodSnapshot &state, int64_t day,
        RuntimeCountryPodPlan &plan, std::string &error) const {
    error.clear();
    if (_catalog.technology_points_good_id < 0 ||
        _catalog.technology_points_good_id >= static_cast<int32_t>(state.good_count)) {
        error = "country_research_points_good_missing";
        return false;
    }
    if (state.last_research_day > day) {
        error = "country_research_day_regressed";
        return false;
    }
    const bool research_due = day > state.last_research_day;
    const auto make_handle = [&state](int32_t slot) {
        return (static_cast<uint64_t>(state.country_generation[
            static_cast<size_t>(slot)]) << 32u) |
            static_cast<uint32_t>(slot);
    };
    const auto pending_bit = [&state](int32_t slot, int32_t technology) {
        const size_t word = static_cast<size_t>(slot) * state.technology_words +
            static_cast<size_t>(technology / 64);
        return std::pair<size_t, uint64_t>{word, uint64_t{1} << (technology % 64)};
    };
    const auto add_effect_intent = [&](int32_t slot, int32_t technology) {
        for (const RuntimeDomainIntent &existing : plan.intents) {
            if (existing.target_handle == make_handle(slot) &&
                existing.payload[0] == technology &&
                existing.opcode == static_cast<uint16_t>(
                    CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT))
                return;
        }
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
        intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        intent.opcode = static_cast<uint16_t>(
            CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT);
        intent.flags = RUNTIME_DOMAIN_INTENT_REQUIRES_ACK;
        intent.target_handle = make_handle(slot);
        intent.target_generation = state.country_generation[static_cast<size_t>(slot)];
        intent.effective_day = day;
        intent.payload[0] = technology;
        intent.request_id = country_peer_request_id(
            state.session_epoch == 0 ? 1u : state.session_epoch,
            state.generation, day, 0u, slot, technology,
            CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT);
        intent.source_id = intent.request_id;
        intent.idempotency_key = intent.request_id;
        intent.producer_id = 0;
        intent.sequence = intent.request_id;
        plan.intents.push_back(intent);
    };

    const auto visit_slot = [&](int32_t slot) -> bool {
        if (slot < 0 || slot >= static_cast<int32_t>(state.country_count) ||
            state.country_active[static_cast<size_t>(slot)] == 0)
            return true;
        const size_t country_base = static_cast<size_t>(slot) *
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        // Activation is always checked, including same-day continuation.
        for (uint32_t technology = 0; technology < state.technology_count; ++technology) {
            const auto [word, bit] = pending_bit(slot, static_cast<int32_t>(technology));
            if ((state.country_pending_technologies[word] & bit) == 0) continue;
            const uint8_t flags = state.research_peer_flags[
                static_cast<size_t>(slot) * state.technology_count + technology];
            const bool requires_peer = _catalog.technology_effect_required[technology] != 0;
            const bool peer_ready = !requires_peer ||
                (flags & (COUNTRY_PEER_EFFECT_FIRE_ACKED |
                          COUNTRY_PEER_MODIFIER_APPLIED)) != 0;
            if (peer_ready) {
                if (!activate_pending_technology(
                        state, slot, static_cast<int32_t>(technology), plan,
                        flags, error))
                    return false;
                if ((state.country_pending_technologies[word] & bit) == 0)
                    plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
            } else {
                add_effect_intent(slot, static_cast<int32_t>(technology));
            }
        }
        if (!research_due) return true;

        int64_t &stock = state.country_goods[static_cast<size_t>(slot) *
            state.good_count + static_cast<size_t>(_catalog.technology_points_good_id)];
        const int64_t prior_deferred = std::min(
            state.research_deferred_points[static_cast<size_t>(slot)], stock);
        const int64_t available = stock - prior_deferred;
        if (available <= 0) return true;
        std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> weights{{0, 0, 0, 0}};
        for (uint32_t domain = 0; domain < COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain)
            weights[domain] = state.research_weights_bp[country_base + domain];
        uint64_t remainder_iterations = 0;
        const CountryResearchAllocation allocation = country_allocate_research_points(
            available, weights, &remainder_iterations);
        plan.header.work_units += remainder_iterations;
        int64_t consumed = 0;
        int64_t newly_deferred = 0;
        for (uint32_t domain = 0; domain < COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            int64_t domain_points = allocation.shares[domain];
            const size_t lane = country_base + domain;
            const uint8_t initial_length = state.research_queue_lengths[lane];
            while (domain_points > 0) {
                uint8_t &length = state.research_queue_lengths[lane];
                if (length == 0) break;
                const size_t queue_base = lane * COUNTRY_QUEUE_SLOTS;
                const int32_t technology = state.research_queues[queue_base];
                if (technology < 0 || technology >= static_cast<int32_t>(state.technology_count)) {
                    error = "country_research_queue_technology_invalid";
                    return false;
                }
                if (!technology_prerequisites_met(state, slot, technology)) break;
                const int64_t progress = state.research_progress[
                    static_cast<size_t>(slot) * state.technology_count +
                    static_cast<size_t>(technology)];
                const double cost_factor = state.research_cost_factor[static_cast<size_t>(slot)];
                const double efficiency = state.research_efficiency[
                    static_cast<size_t>(slot) * 4u + domain];
                const CountryResearchProgress step = country_advance_research_progress(
                    progress, _catalog.technology_costs[static_cast<size_t>(technology)],
                    cost_factor, efficiency, domain_points);
                if (!step.valid || step.spend <= 0) break;
                state.research_progress[static_cast<size_t>(slot) * state.technology_count +
                                        static_cast<size_t>(technology)] =
                    progress + step.progress_gain;
                domain_points -= step.spend;
                consumed += step.spend;
                state.research_progress_total[static_cast<size_t>(slot)] +=
                    step.progress_gain;
                plan.header.work_units += static_cast<uint64_t>(step.spend);
                if (!step.completed) break;

                const auto [word, bit] = pending_bit(slot, technology);
                state.country_pending_technologies[word] |= bit;
                ++state.research_completed_total[static_cast<size_t>(slot)];
                ++state.country_state_version[static_cast<size_t>(slot)];
                for (int32_t index = 1; index < length; ++index)
                    state.research_queues[queue_base + static_cast<size_t>(index - 1)] =
                        state.research_queues[queue_base + static_cast<size_t>(index)];
                state.research_queues[queue_base + static_cast<size_t>(--length)] = -1;
                if (_catalog.technology_effect_required[static_cast<size_t>(technology)] != 0)
                    add_effect_intent(slot, technology);
            }
            if (initial_length > 0) newly_deferred += domain_points;
        }
        if (consumed > 0) {
            stock -= consumed;
            state.research_consumed_total[static_cast<size_t>(slot)] += consumed;
            ++state.country_state_version[static_cast<size_t>(slot)];
            plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        }
        state.research_deferred_points[static_cast<size_t>(slot)] = std::min(
            stock, prior_deferred + newly_deferred);
        return true;
    };

    bool research_ok = true;
    if (state.research_active_index_valid && !state.research_active_country_slots.empty()) {
        for (const int32_t slot : state.research_active_country_slots) {
            if (!visit_slot(slot)) {
                research_ok = false;
                break;
            }
        }
    } else {
        for (uint32_t slot = 0; slot < state.country_count; ++slot) {
            if (!visit_slot(static_cast<int32_t>(slot))) {
                research_ok = false;
                break;
            }
        }
    }
    if (!research_ok) return false;
    if (research_due) state.last_research_day = day;
    plan.header.dirty_families |= plan.intents.empty() ? 0u : RUNTIME_DIRTY_COUNTRY_STATE;
    return error.empty();
}

bool RuntimeCountryPodAuthority::activate_pending_technology(
        RuntimeCountryPodSnapshot &state, int32_t slot, int32_t technology,
        const RuntimeCountryPodPlan &, uint8_t peer_flags,
        std::string &error) const {
    error.clear();
    if (slot < 0 || technology < 0 ||
        slot >= static_cast<int32_t>(state.country_count) ||
        technology >= static_cast<int32_t>(state.technology_count)) {
        error = "country_pending_activation_target_invalid";
        return false;
    }
    const size_t word = static_cast<size_t>(slot) * state.technology_words +
        static_cast<size_t>(technology / 64);
    const uint64_t bit = uint64_t{1} << (technology % 64);
    if ((state.country_pending_technologies[word] & bit) == 0) return true;

    const size_t peer_index = static_cast<size_t>(slot) * state.technology_count +
        static_cast<size_t>(technology);
    if (peer_index >= state.research_peer_flags.size()) {
        error = "country_pending_activation_peer_state_missing";
        return false;
    }
    state.research_peer_flags[peer_index] |= peer_flags;
    const bool requires_peer = _catalog.technology_effect_required[
        static_cast<size_t>(technology)] != 0;
    if (requires_peer &&
        (state.research_peer_flags[peer_index] &
            (COUNTRY_PEER_EFFECT_FIRE_ACKED | COUNTRY_PEER_MODIFIER_APPLIED)) == 0) {
        error = "country_pending_activation_peer_ack_missing";
        return false;
    }

    state.country_pending_technologies[word] &= ~bit;
    state.country_technologies[word] |= bit;
    ++state.country_state_version[static_cast<size_t>(slot)];

    // Refresh only the frontier affected by this completion. This mirrors
    // the production discovery rule while keeping the worker numeric and
    // independent from the Godot catalog objects.
    const size_t country_word_base =
        static_cast<size_t>(slot) * _catalog.technology_words;
    for (uint32_t candidate = 0; candidate < _catalog.technology_count; ++candidate) {
        const size_t candidate_word = country_word_base + candidate / 64u;
        const uint64_t candidate_bit = uint64_t{1} << (candidate % 64u);
        if ((state.country_technologies[candidate_word] & candidate_bit) != 0) {
            state.country_discovered[candidate_word] |= candidate_bit;
            continue;
        }

        bool reveal = false;
        if (_catalog.research_conditions_complete &&
            _catalog.research_condition_offsets.size() ==
                static_cast<size_t>(_catalog.technology_count) + 1u) {
            const int32_t condition_begin = _catalog.research_condition_offsets[
                candidate];
            const int32_t condition_end = _catalog.research_condition_offsets[
                candidate + 1u];
            if (condition_end > condition_begin)
                reveal = research_condition_met(
                    state, slot, static_cast<int32_t>(candidate));
        }

        bool has_milestones = false;
        if (!_catalog.milestone_offsets.empty()) {
            const int32_t begin = _catalog.milestone_offsets[candidate];
            const int32_t end = _catalog.milestone_offsets[candidate + 1u];
            has_milestones = end > begin;
            for (int32_t edge = begin; edge < end && !reveal; ++edge) {
                const int32_t prerequisite = _catalog.milestone_candidates[
                    static_cast<size_t>(edge)];
                const size_t prerequisite_word = country_word_base +
                    static_cast<size_t>(prerequisite / 64);
                reveal = (state.country_technologies[prerequisite_word] &
                    (uint64_t{1} << (prerequisite % 64))) != 0;
            }
        }
        if (!reveal && !has_milestones) {
            const int32_t begin = _catalog.prerequisite_offsets[candidate];
            const int32_t end = _catalog.prerequisite_offsets[candidate + 1u];
            for (int32_t edge = begin; edge < end && !reveal; ++edge) {
                const int32_t prerequisite = _catalog.prerequisites[
                    static_cast<size_t>(edge)];
                const size_t prerequisite_word = country_word_base +
                    static_cast<size_t>(prerequisite / 64);
                reveal = (state.country_technologies[prerequisite_word] &
                    (uint64_t{1} << (prerequisite % 64))) != 0;
            }
        }

        if (!reveal && candidate < _catalog.entry_milestone_indices.size()) {
            const int32_t entry = _catalog.entry_milestone_indices[candidate];
            if (entry >= 0) {
                const size_t entry_word = country_word_base +
                    static_cast<size_t>(entry / 64);
                reveal = (state.country_technologies[entry_word] &
                    (uint64_t{1} << (entry % 64))) != 0;
            }
        }
        if (reveal) state.country_discovered[candidate_word] |= candidate_bit;
    }
    return true;
}

void RuntimeCountryPodAuthority::remove_pending_commands(
        const std::vector<uint64_t> &request_ids) noexcept {
    if (request_ids.empty() || _pending.empty()) return;
    _pending.erase(std::remove_if(_pending.begin(), _pending.end(),
        [&request_ids](const RuntimeCountryCommand &command) {
            return std::find(request_ids.begin(), request_ids.end(),
                             command.request_id) != request_ids.end();
        }), _pending.end());
}

bool RuntimeCountryPodAuthority::apply_command(
        RuntimeCountryPodSnapshot &state, const RuntimeCountryCommand &command,
        RuntimeCountryPodPlan &plan, std::string &error) const {
    error.clear();
    int32_t slot = -1;
    constexpr int32_t TAX_INHERIT = std::numeric_limits<int32_t>::min();
    constexpr int32_t TAX_MODE_INHERIT = std::numeric_limits<int32_t>::min();
    constexpr int32_t TAX_MODE_PERCENT = 0;
    constexpr int32_t TAX_MODE_ABSOLUTE = 1;
    const auto tax_item_count = [&](int32_t kind) -> int32_t {
        if (kind == 0) return static_cast<int32_t>(state.profession_count);
        if (kind == 2) return static_cast<int32_t>(state.building_type_count);
        if (kind == 1 || kind == 3 || kind == 4)
            return static_cast<int32_t>(state.good_count);
        return 0;
    };
    const auto tax_value_valid = [&](int32_t mode, int32_t value) {
        if (mode == TAX_MODE_PERCENT)
            return value >= -100000 && value <= 10000;
        if (mode == TAX_MODE_ABSOLUTE)
            return value >= -1000000000 && value <= 1000000000;
        return false;
    };
    const auto copy_fixed = [](const std::array<char, RUNTIME_COUNTRY_STABLE_ID_CAPACITY> &value) {
        return std::string(value.data());
    };
    const auto copy_display = [](const std::array<char, RUNTIME_COUNTRY_DISPLAY_NAME_CAPACITY> &value) {
        return std::string(value.data());
    };
    const auto ensure_cell_policy = [&](int32_t cell) -> RuntimeCountryPodSnapshot::CellTaxPolicy * {
        if (cell < 0 || cell >= static_cast<int32_t>(state.cell_tax_policy_ids.size()) ||
            state.cell_tax_policies.empty()) return nullptr;
        uint32_t policy_id = state.cell_tax_policy_ids[static_cast<size_t>(cell)];
        if (policy_id >= state.cell_tax_policies.size()) return nullptr;
        state.cell_tax_policies.push_back(state.cell_tax_policies[policy_id]);
        state.cell_tax_policy_ids[static_cast<size_t>(cell)] =
            static_cast<uint32_t>(state.cell_tax_policies.size() - 1u);
        return &state.cell_tax_policies.back();
    };
    const auto country_tax_vectors = [&](int32_t kind,
            std::vector<int32_t> *&rates, std::vector<int32_t> *&modes) {
        rates = nullptr; modes = nullptr;
        switch (kind) {
        case 0: rates = &state.country_income_tax_overrides;
                modes = &state.country_income_tax_mode_overrides; break;
        case 1: rates = &state.country_consumption_tax_overrides;
                modes = &state.country_consumption_tax_mode_overrides; break;
        case 2: rates = &state.country_business_tax_overrides;
                modes = &state.country_business_tax_mode_overrides; break;
        case 3: rates = &state.country_import_tax_overrides;
                modes = &state.country_import_tax_mode_overrides; break;
        case 4: rates = &state.country_export_tax_overrides;
                modes = &state.country_export_tax_mode_overrides; break;
        default: break;
        }
    };
    switch (command.opcode) {
    case 1: { // create country
        const std::string stable_id = copy_fixed(command.stable_id);
        const std::string display_name = copy_display(command.display_name);
        if (stable_id.empty() || display_name.empty() ||
            std::find(state.country_stable_ids.begin(), state.country_stable_ids.end(),
                      stable_id) != state.country_stable_ids.end()) {
            error = "country_create_identity_invalid";
            return false;
        }
        if (command.cell < 0 || command.cell >= static_cast<int32_t>(state.cell_count) ||
            (!state.is_water.empty() && state.is_water[static_cast<size_t>(command.cell)] != 0)) {
            error = "country_create_territory_invalid";
            return false;
        }
        const int32_t old_owner = state.cell_country_slot[static_cast<size_t>(command.cell)];
        const int32_t new_slot = static_cast<int32_t>(state.country_count);
        ++state.country_count;
        state.country_active.push_back(1);
        state.country_generation.push_back(1);
        state.country_stable_ids.push_back(stable_id);
        state.country_display_names.push_back(display_name);
        state.territory_count.push_back(1);
        state.country_state_version.push_back(1);
        state.country_cash.push_back(0);
        state.country_technologies.insert(state.country_technologies.end(), state.technology_words, 0);
        state.country_discovered.insert(state.country_discovered.end(), state.technology_words, 0);
        state.country_pending_technologies.insert(state.country_pending_technologies.end(), state.technology_words, 0);
        state.country_goods.insert(state.country_goods.end(), state.good_count, 0);
        state.research_progress.insert(state.research_progress.end(), state.technology_count, 0);
        state.research_queues.insert(state.research_queues.end(),
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT * COUNTRY_QUEUE_SLOTS, -1);
        state.research_queue_lengths.insert(state.research_queue_lengths.end(),
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT, 0);
        state.research_weights_bp.insert(state.research_weights_bp.end(),
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT, 2500);
        state.research_daily_budgets.push_back(1000 * 10000);
        state.research_deferred_points.push_back(0);
        state.research_progress_total.push_back(0);
        state.research_completed_total.push_back(0);
        state.research_auto_purchase.push_back(1);
        state.research_purchased_total.push_back(0);
        state.research_consumed_total.push_back(0);
        state.research_peer_flags.insert(state.research_peer_flags.end(), state.technology_count, 0);
        state.research_signal_cell_offsets.push_back(
            state.research_signal_cell_offsets.back());
        state.research_signal_evidence_offsets.push_back(
            state.research_signal_evidence_offsets.back());
        state.country_tax_defaults.insert(state.country_tax_defaults.end(),
            RuntimeCountryPodSnapshot::TAX_KIND_COUNT, 0);
        state.country_tax_default_modes.insert(state.country_tax_default_modes.end(),
            RuntimeCountryPodSnapshot::TAX_KIND_COUNT, TAX_MODE_PERCENT);
        const auto add_tax_arrays = [&](std::vector<int32_t> &rates,
                                        std::vector<int32_t> &modes,
                                        int32_t count) {
            rates.insert(rates.end(), count, TAX_INHERIT);
            modes.insert(modes.end(), count, TAX_MODE_INHERIT);
        };
        add_tax_arrays(state.country_income_tax_overrides, state.country_income_tax_mode_overrides,
                       static_cast<int32_t>(state.profession_count));
        add_tax_arrays(state.country_consumption_tax_overrides, state.country_consumption_tax_mode_overrides,
                       static_cast<int32_t>(state.good_count));
        add_tax_arrays(state.country_business_tax_overrides, state.country_business_tax_mode_overrides,
                       static_cast<int32_t>(state.building_type_count));
        add_tax_arrays(state.country_import_tax_overrides, state.country_import_tax_mode_overrides,
                       static_cast<int32_t>(state.good_count));
        add_tax_arrays(state.country_export_tax_overrides, state.country_export_tax_mode_overrides,
                       static_cast<int32_t>(state.good_count));
        if (old_owner >= 0) {
            if (state.territory_count[static_cast<size_t>(old_owner)] <= 0) {
                error = "country_territory_count_underflow";
                return false;
            }
            --state.territory_count[static_cast<size_t>(old_owner)];
            for (uint32_t word = 0; word < state.technology_words; ++word) {
                state.country_technologies[static_cast<size_t>(new_slot) * state.technology_words + word] =
                    state.country_technologies[static_cast<size_t>(old_owner) * state.technology_words + word];
                state.country_discovered[static_cast<size_t>(new_slot) * state.technology_words + word] =
                    state.country_discovered[static_cast<size_t>(old_owner) * state.technology_words + word];
            }
        } else {
            for (const int32_t technology : _catalog.starting_technologies) {
                if (technology < 0 || technology >= static_cast<int32_t>(state.technology_count)) continue;
                const size_t word = static_cast<size_t>(new_slot) * state.technology_words + technology / 64u;
                const uint64_t bit = uint64_t{1} << (technology % 64u);
                state.country_technologies[word] |= bit;
                state.country_discovered[word] |= bit;
            }
        }
        state.cell_country_slot[static_cast<size_t>(command.cell)] = new_slot;
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_TERRITORY |
                                      RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 2: { // rename country
        if (!validate_target(state, command, slot, error)) return false;
        const std::string display_name = copy_display(command.display_name);
        if (display_name.empty()) { error = "country_name_empty"; return false; }
        state.country_display_names[static_cast<size_t>(slot)] = display_name;
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 3: // transfer territory / claim unowned when target_handle is zero
    case 20: {
        if (command.cell < 0 || command.cell >= static_cast<int32_t>(state.cell_count) ||
            (!state.is_water.empty() && state.is_water[static_cast<size_t>(command.cell)] != 0)) {
            error = "country_transfer_cell_invalid";
            return false;
        }
        if (command.opcode == 20 && command.target_handle == 0) {
            error = "country_claim_target_missing";
            return false;
        }
        if (command.target_handle != 0 && !validate_target(state, command, slot, error))
            return false;
        const int32_t old_owner = state.cell_country_slot[static_cast<size_t>(command.cell)];
        if (command.opcode == 20 && old_owner != -1) {
            error = "country_claim_target_not_unowned";
            return false;
        }
        const int32_t target = slot;
        if (old_owner == target) return true;
        if (old_owner >= 0) {
            if (state.territory_count[static_cast<size_t>(old_owner)] <= 0) {
                error = "country_territory_count_underflow";
                return false;
            }
            --state.territory_count[static_cast<size_t>(old_owner)];
            ++state.country_state_version[static_cast<size_t>(old_owner)];
        }
        ++state.territory_count[static_cast<size_t>(target)];
        ++state.country_state_version[static_cast<size_t>(target)];
        state.cell_country_slot[static_cast<size_t>(command.cell)] = target;
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_TERRITORY |
                                      RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 4: // grant technology: completion is an Effect ACK boundary
        if (!validate_target(state, command, slot, error)) return false;
        if (command.aux < 0 || command.aux >= static_cast<int32_t>(_catalog.technology_count)) {
            error = "country_technology_invalid";
            return false;
        }
        {
            const size_t word = static_cast<size_t>(slot) * _catalog.technology_words +
                                static_cast<size_t>(command.aux / 64);
            const uint64_t bit = uint64_t{1} << (command.aux % 64);
            if ((state.country_technologies[word] & bit) == 0) {
                state.country_pending_technologies[word] |= bit;
                ++state.country_state_version[static_cast<size_t>(slot)];
                RuntimeDomainIntent intent;
                intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
                intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
                // `RuntimeDomainIntent::opcode` is the peer operation at this
                // boundary, not the originating Country command opcode.  The
                // two enums intentionally do not share a wire namespace:
                // GRANT_TECHNOLOGY is Country command 4, while ENSURE is peer
                // operation 1.  Keeping the typed peer opcode here prevents
                // the Host adapter from having to guess which semantic was
                // intended from an overlapping integer value.
                intent.opcode = static_cast<uint16_t>(
                    CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT);
                intent.source_id = command.request_id;
                intent.target_handle = command.target_handle;
                intent.target_generation = state.country_generation[static_cast<size_t>(slot)];
                intent.effective_day = command.effective_day;
                intent.payload[0] = command.aux;
                plan.intents.push_back(intent);
                ++plan.required_ack_count;
                plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
            }
        }
        return true;
    case 5: // set research weights
        if (!validate_target(state, command, slot, error)) return false;
        if (!runtime_country_research_weights_valid(command.weights_bp)) {
            error = "country_research_weight_total_invalid";
            return false;
        }
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain)
            state.research_weights_bp[static_cast<size_t>(slot) *
                                      RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT + domain] =
                command.weights_bp[domain];
        state.research_deferred_points[static_cast<size_t>(slot)] = 0;
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    case 6: // enqueue research; full condition CSR is mandatory
    case 8: { // move research
        if (!validate_target(state, command, slot, error)) return false;
        if (!_catalog.research_conditions_complete) {
            error = "country_catalog_research_conditions_missing";
            return false;
        }
        if (command.aux < 0 || command.aux >= static_cast<int32_t>(_catalog.technology_count) ||
            command.domain < 0 || command.domain >= static_cast<int32_t>(RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) ||
            command.position < -1 || command.position >= static_cast<int32_t>(COUNTRY_QUEUE_SLOTS)) {
            error = "country_research_queue_argument_invalid";
            return false;
        }
        const size_t word = static_cast<size_t>(slot) * _catalog.technology_words +
                            static_cast<size_t>(command.aux / 64);
        const uint64_t bit = uint64_t{1} << (command.aux % 64);
        if ((state.country_discovered[word] & bit) == 0 ||
            (state.country_technologies[word] & bit) != 0 ||
            (state.country_pending_technologies[word] & bit) != 0) {
            error = "country_research_technology_unavailable";
            return false;
        }
        if (!technology_prerequisites_met(state, slot, command.aux) ||
            !research_condition_met(state, slot, command.aux)) {
            error = "country_research_requirements_incomplete";
            return false;
        }
        if (_catalog.technology_domains[static_cast<size_t>(command.aux)] != command.domain) {
            error = "country_research_domain_mismatch";
            return false;
        }
        const size_t country_base = static_cast<size_t>(slot) *
                                    RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        int32_t found_domain = -1, found_position = -1;
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            const size_t length_index = country_base + domain;
            const size_t queue_base = length_index * COUNTRY_QUEUE_SLOTS;
            for (uint32_t position = 0; position < state.research_queue_lengths[length_index]; ++position)
                if (state.research_queues[queue_base + position] == command.aux) {
                    found_domain = static_cast<int32_t>(domain);
                    found_position = static_cast<int32_t>(position);
                }
        }
        if (command.opcode == 6 && found_domain >= 0) {
            error = "country_research_already_queued";
            return false;
        }
        if (command.opcode == 8 && found_domain < 0) {
            error = "country_research_not_queued";
            return false;
        }
        if (found_domain >= 0) {
            const size_t old_index = country_base + static_cast<size_t>(found_domain);
            const size_t old_base = old_index * COUNTRY_QUEUE_SLOTS;
            uint8_t &old_length = state.research_queue_lengths[old_index];
            for (int32_t i = found_position + 1; i < old_length; ++i)
                state.research_queues[old_base + static_cast<size_t>(i - 1)] =
                    state.research_queues[old_base + static_cast<size_t>(i)];
            state.research_queues[old_base + static_cast<size_t>(--old_length)] = -1;
        }
        const size_t index = country_base + static_cast<size_t>(command.domain);
        const size_t base = index * COUNTRY_QUEUE_SLOTS;
        uint8_t &length = state.research_queue_lengths[index];
        if (length >= COUNTRY_QUEUE_SLOTS) {
            error = "country_research_queue_full";
            return false;
        }
        const int32_t insert_at = command.position < 0
            ? static_cast<int32_t>(length)
            : std::min<int32_t>(command.position, length);
        for (int32_t i = length; i > insert_at; --i)
            state.research_queues[base + static_cast<size_t>(i)] =
                state.research_queues[base + static_cast<size_t>(i - 1)];
        state.research_queues[base + static_cast<size_t>(insert_at)] = command.aux;
        ++length;
        state.research_deferred_points[static_cast<size_t>(slot)] = 0;
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 7: { // remove research
        if (!validate_target(state, command, slot, error)) return false;
        bool removed = false;
        const size_t country_base = static_cast<size_t>(slot) *
                                    RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        for (uint32_t domain = 0; domain < RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT && !removed; ++domain) {
            const size_t index = country_base + domain;
            const size_t base = index * COUNTRY_QUEUE_SLOTS;
            uint8_t &length = state.research_queue_lengths[index];
            for (uint32_t position = 0; position < length; ++position) {
                if (state.research_queues[base + position] != command.aux) continue;
                for (uint32_t i = position + 1; i < length; ++i)
                    state.research_queues[base + i - 1u] = state.research_queues[base + i];
                state.research_queues[base + --length] = -1;
                removed = true;
                break;
            }
        }
        if (!removed) {
            error = "country_research_not_queued";
            return false;
        }
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 9: // budget and auto purchase
        if (!validate_target(state, command, slot, error)) return false;
        if (command.value < 0 || (command.aux != 0 && command.aux != 1)) {
            error = "country_research_budget_invalid";
            return false;
        }
        state.research_daily_budgets[static_cast<size_t>(slot)] = command.value;
        state.research_auto_purchase[static_cast<size_t>(slot)] =
            static_cast<uint8_t>(command.aux);
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    case 10: // reveal all technologies
        if (!validate_target(state, command, slot, error)) return false;
        for (uint32_t tech = 0; tech < _catalog.technology_count; ++tech)
            state.country_discovered[static_cast<size_t>(slot) * _catalog.technology_words +
                                      tech / 64u] |= uint64_t{1} << (tech % 64u);
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    case 11: // country tax default
    case 12: // country tax override
    case 13: { // clear country tax override
        if (!validate_target(state, command, slot, error)) return false;
        if (command.tax_kind < 0 || command.tax_kind >= static_cast<int32_t>(RuntimeCountryPodSnapshot::TAX_KIND_COUNT)) {
            error = "country_tax_kind_invalid"; return false;
        }
        const bool needs_value = command.opcode != 13;
        if (needs_value && !tax_value_valid(command.tax_assessment_mode,
                                            command.tax_rate_basis_points)) {
            error = "country_tax_command_invalid"; return false;
        }
        if (command.opcode == 11) {
            const size_t index = static_cast<size_t>(slot) * RuntimeCountryPodSnapshot::TAX_KIND_COUNT + command.tax_kind;
            state.country_tax_defaults[index] = command.tax_rate_basis_points;
            state.country_tax_default_modes[index] = command.tax_assessment_mode;
        } else {
            const int32_t count = tax_item_count(command.tax_kind);
            if (command.tax_item < 0 || command.tax_item >= count) {
                error = "country_tax_item_invalid"; return false;
            }
            std::vector<int32_t> *rates = nullptr, *modes = nullptr;
            country_tax_vectors(command.tax_kind, rates, modes);
            const size_t index = static_cast<size_t>(slot) * count + command.tax_item;
            (*rates)[index] = command.opcode == 13 ? TAX_INHERIT : command.tax_rate_basis_points;
            (*modes)[index] = command.opcode == 13 ? TAX_MODE_INHERIT : command.tax_assessment_mode;
        }
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 14: { // discover country signal
        if (!validate_target(state, command, slot, error)) return false;
        if (command.aux < 0 || command.aux >= static_cast<int32_t>(state.research_signal_count) ||
            command.cell < 0 || command.cell >= static_cast<int32_t>(state.cell_count)) {
            error = "country_research_signal_command_invalid"; return false;
        }
        const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(command.aux)) << 32u) |
                             static_cast<uint32_t>(command.cell);
        const size_t begin = static_cast<size_t>(state.research_signal_cell_offsets[static_cast<size_t>(slot)]);
        const size_t end = static_cast<size_t>(state.research_signal_cell_offsets[static_cast<size_t>(slot) + 1u]);
        auto cells = state.research_signal_cells.begin() + static_cast<ptrdiff_t>(begin);
        auto cells_end = state.research_signal_cells.begin() + static_cast<ptrdiff_t>(end);
        auto found = std::lower_bound(cells, cells_end, key);
        if (found != cells_end && *found == key) return true;
        const size_t insertion = static_cast<size_t>(found - state.research_signal_cells.begin());
        state.research_signal_cells.insert(state.research_signal_cells.begin() + static_cast<ptrdiff_t>(insertion), key);
        for (size_t index = static_cast<size_t>(slot) + 1u; index < state.research_signal_cell_offsets.size(); ++index)
            ++state.research_signal_cell_offsets[index];
        const size_t evidence_begin = static_cast<size_t>(state.research_signal_evidence_offsets[static_cast<size_t>(slot)]);
        const size_t evidence_end = static_cast<size_t>(state.research_signal_evidence_offsets[static_cast<size_t>(slot) + 1u]);
        auto evidence = state.research_signal_evidence.begin() + static_cast<ptrdiff_t>(evidence_begin);
        auto evidence_end_it = state.research_signal_evidence.begin() + static_cast<ptrdiff_t>(evidence_end);
        auto evidence_it = std::lower_bound(evidence, evidence_end_it, command.aux,
            [](const RuntimeCountryPodSnapshot::SignalEvidence &entry, int32_t signal) {
                return entry.signal < signal;
            });
        if (evidence_it == evidence_end_it || evidence_it->signal != command.aux) {
            RuntimeCountryPodSnapshot::SignalEvidence entry;
            entry.signal = command.aux; entry.count = 0; entry.first_day = command.effective_day;
            entry.last_day = command.effective_day; entry.first_cell = command.cell;
            const size_t evidence_index = static_cast<size_t>(evidence_it - state.research_signal_evidence.begin());
            state.research_signal_evidence.insert(state.research_signal_evidence.begin() + static_cast<ptrdiff_t>(evidence_index), entry);
            for (size_t index = static_cast<size_t>(slot) + 1u; index < state.research_signal_evidence_offsets.size(); ++index)
                ++state.research_signal_evidence_offsets[index];
            evidence_it = state.research_signal_evidence.begin() + static_cast<ptrdiff_t>(evidence_index);
        }
        ++evidence_it->count;
        evidence_it->last_day = command.effective_day;
        if (state.research_signal_words > 0)
            state.country_research_signals[static_cast<size_t>(slot) * state.research_signal_words + command.aux / 64] |=
                uint64_t{1} << (command.aux % 64);
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    case 15: // cell tax default
    case 16: // clear cell tax default
    case 17: // cell tax override
    case 18: // clear cell tax override
    case 19: { // clear cell tax policy
        if (!validate_target(state, command, slot, error)) return false;
        if (command.cell < 0 || command.cell >= static_cast<int32_t>(state.cell_count) ||
            (!state.is_water.empty() && state.is_water[static_cast<size_t>(command.cell)] != 0) ||
            state.cell_country_slot[static_cast<size_t>(command.cell)] != slot) {
            error = "country_cell_tax_territory_invalid"; return false;
        }
        if (command.opcode == 19) {
            state.cell_tax_policy_ids[static_cast<size_t>(command.cell)] = 0;
        } else {
            auto *policy = ensure_cell_policy(command.cell);
            if (policy == nullptr) { error = "country_cell_tax_policy_invalid"; return false; }
            if (command.tax_kind < 0 || command.tax_kind >= static_cast<int32_t>(RuntimeCountryPodSnapshot::TAX_KIND_COUNT)) {
                error = "country_cell_tax_kind_invalid"; return false;
            }
            if (command.opcode == 15 || command.opcode == 16) {
                if (command.opcode == 15 && !tax_value_valid(command.tax_assessment_mode, command.tax_rate_basis_points)) {
                    error = "country_cell_tax_rate_invalid"; return false;
                }
                policy->defaults[static_cast<size_t>(command.tax_kind)] = command.opcode == 16 ? TAX_INHERIT : command.tax_rate_basis_points;
                policy->modes[static_cast<size_t>(command.tax_kind)] = command.opcode == 16 ? TAX_MODE_INHERIT : command.tax_assessment_mode;
            } else {
                const int32_t count = tax_item_count(command.tax_kind);
                if (command.tax_item < 0 || command.tax_item >= count) { error = "country_cell_tax_item_invalid"; return false; }
                auto entry = std::lower_bound(policy->overrides.begin(), policy->overrides.end(),
                    std::pair<int32_t, int32_t>{command.tax_kind, command.tax_item},
                    [](const RuntimeCountryPodSnapshot::CellTaxOverride &value,
                       const std::pair<int32_t, int32_t> &key) {
                        return value.kind < key.first || (value.kind == key.first && value.item < key.second);
                    });
                if (command.opcode == 18) {
                    if (entry != policy->overrides.end() && entry->kind == command.tax_kind && entry->item == command.tax_item)
                        policy->overrides.erase(entry);
                } else {
                    if (!tax_value_valid(command.tax_assessment_mode, command.tax_rate_basis_points)) { error = "country_cell_tax_rate_invalid"; return false; }
                    RuntimeCountryPodSnapshot::CellTaxOverride replacement{command.tax_kind, command.tax_item, command.tax_rate_basis_points, command.tax_assessment_mode};
                    if (entry != policy->overrides.end() && entry->kind == command.tax_kind && entry->item == command.tax_item) *entry = replacement;
                    else policy->overrides.insert(entry, replacement);
                }
            }
        }
        ++state.country_state_version[static_cast<size_t>(slot)];
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    }
    default:
        error = "country_command_capture_contract_missing";
        return false;
    }
}

void RuntimeCountryPodAuthority::rebuild_territory_csr(
        RuntimeCountryPodSnapshot &state) const {
    state.territory_offsets.assign(static_cast<size_t>(state.country_count) + 1u, 0);
    for (int32_t owner : state.cell_country_slot)
        if (owner >= 0 && owner < static_cast<int32_t>(state.country_count))
            ++state.territory_offsets[static_cast<size_t>(owner) + 1u];
    for (size_t i = 1; i < state.territory_offsets.size(); ++i)
        state.territory_offsets[i] += state.territory_offsets[i - 1u];
    state.territory_cells.assign(state.territory_offsets.back(), -1);
    std::vector<int32_t> cursor = state.territory_offsets;
    for (int32_t cell = 0; cell < static_cast<int32_t>(state.cell_country_slot.size()); ++cell) {
        const int32_t owner = state.cell_country_slot[static_cast<size_t>(cell)];
        if (owner < 0 || owner >= static_cast<int32_t>(state.country_count)) continue;
        state.territory_cells[static_cast<size_t>(cursor[static_cast<size_t>(owner)]++)] = cell;
    }
    state.territory_count.assign(state.country_count, 0);
    for (uint32_t slot = 0; slot < state.country_count; ++slot)
        state.territory_count[slot] = state.territory_offsets[slot + 1u] -
                                      state.territory_offsets[slot];
}

uint64_t RuntimeCountryPodAuthority::hash_business_state(
        const RuntimeCountryPodSnapshot &state) {
    uint64_t hash = FNV_OFFSET;
    const auto mix_u64 = [&](uint64_t value) {
        for (uint32_t i = 0; i < 8; ++i) {
            hash ^= static_cast<uint8_t>(value >> (i * 8u));
            hash *= FNV_PRIME;
        }
    };
    // Keep this hash limited to the Country business projection. Transport
    // session identity, catalog identity and peer inputs belong to the
    // checkpoint/protocol contract, not to production business parity.
    mix_u64(state.generation);
    mix_u64(static_cast<uint64_t>(state.last_research_day));
    hash = hash_vector(hash, state.country_active);
    hash = hash_vector(hash, state.country_generation);
    const auto hash_strings = [&](const std::vector<std::string> &values) {
        for (const std::string &value : values) {
            hash = hash_vector(hash, std::vector<uint8_t>(value.begin(), value.end()));
            mix_u64(0);
        }
    };
    hash_strings(state.country_stable_ids);
    hash_strings(state.country_display_names);
    hash = hash_vector(hash, state.country_state_version);
    hash = hash_vector(hash, state.territory_count);
    hash = hash_vector(hash, state.country_cash);
    hash = hash_vector(hash, state.country_goods);
    hash = hash_vector(hash, state.cell_country_slot);
    hash = hash_vector(hash, state.territory_offsets);
    hash = hash_vector(hash, state.territory_cells);
    hash = hash_vector(hash, state.country_technologies);
    hash = hash_vector(hash, state.country_discovered);
    hash = hash_vector(hash, state.country_pending_technologies);
    hash = hash_vector(hash, state.country_research_signals);
    hash = hash_vector(hash, state.research_signal_cell_offsets);
    hash = hash_vector(hash, state.research_signal_cells);
    hash = hash_vector(hash, state.research_signal_evidence_offsets);
    for (const auto &entry : state.research_signal_evidence) {
        mix_u64(static_cast<uint64_t>(entry.signal));
        mix_u64(static_cast<uint64_t>(entry.count));
        mix_u64(static_cast<uint64_t>(entry.first_day));
        mix_u64(static_cast<uint64_t>(entry.last_day));
        mix_u64(static_cast<uint64_t>(entry.first_cell));
    }
    hash = hash_vector(hash, state.research_queues);
    hash = hash_vector(hash, state.research_queue_lengths);
    hash = hash_vector(hash, state.research_weights_bp);
    hash = hash_vector(hash, state.research_auto_purchase);
    hash = hash_vector(hash, state.research_daily_budgets);
    hash = hash_vector(hash, state.research_deferred_points);
    hash = hash_vector(hash, state.research_progress);
    hash = hash_vector(hash, state.research_purchased_total);
    hash = hash_vector(hash, state.research_consumed_total);
    hash = hash_vector(hash, state.research_progress_total);
    hash = hash_vector(hash, state.research_completed_total);
    hash = hash_vector(hash, state.country_tax_defaults);
    hash = hash_vector(hash, state.country_tax_default_modes);
    hash = hash_vector(hash, state.country_income_tax_overrides);
    hash = hash_vector(hash, state.country_consumption_tax_overrides);
    hash = hash_vector(hash, state.country_business_tax_overrides);
    hash = hash_vector(hash, state.country_import_tax_overrides);
    hash = hash_vector(hash, state.country_export_tax_overrides);
    hash = hash_vector(hash, state.country_income_tax_mode_overrides);
    hash = hash_vector(hash, state.country_consumption_tax_mode_overrides);
    hash = hash_vector(hash, state.country_business_tax_mode_overrides);
    hash = hash_vector(hash, state.country_import_tax_mode_overrides);
    hash = hash_vector(hash, state.country_export_tax_mode_overrides);
    hash = hash_vector(hash, state.cell_tax_policy_ids);
    for (const auto &policy : state.cell_tax_policies) {
        for (const int32_t value : policy.defaults)
            mix_u64(static_cast<uint64_t>(value));
        for (const int32_t value : policy.modes)
            mix_u64(static_cast<uint64_t>(value));
        for (const auto &entry : policy.overrides) {
            mix_u64(static_cast<uint64_t>(entry.kind));
            mix_u64(static_cast<uint64_t>(entry.item));
            mix_u64(static_cast<uint64_t>(entry.rate));
            mix_u64(static_cast<uint64_t>(entry.mode));
        }
    }
    return hash;
}

bool RuntimeCountryPodAuthority::plan_day(
        int64_t day, uint64_t input_generation, RuntimeCountryPodPlan &plan,
        std::string &error) {
    error.clear();
    plan = RuntimeCountryPodPlan{};
    if (!_bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    if (_plan_active) {
        error = "country_plan_already_active";
        return false;
    }
    if (day != _state.committed_day + 1) {
        error = "country_day_not_contiguous";
        return false;
    }
    if (input_generation == 0) {
        error = "country_input_generation_invalid";
        return false;
    }
    plan.next_state = _state;
    plan.header.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    plan.header.abi_version = RUNTIME_DOMAIN_POD_ABI_VERSION;
    plan.header.day = day;
    plan.header.input_generation = input_generation;
    plan.header.base_generation = _state.generation;
    plan.header.preflight_ok = 1;
    plan.commands.reserve(_pending.size());
    for (const RuntimeCountryCommand &command : _pending)
        if (command.effective_day <= day) plan.commands.push_back(command);
    std::sort(plan.commands.begin(), plan.commands.end(),
        [](const RuntimeCountryCommand &lhs, const RuntimeCountryCommand &rhs) {
            if (lhs.effective_day != rhs.effective_day)
                return lhs.effective_day < rhs.effective_day;
            if (lhs.sequence != rhs.sequence) return lhs.sequence < rhs.sequence;
            if (lhs.submit_order != rhs.submit_order)
                return lhs.submit_order < rhs.submit_order;
            return lhs.request_id < rhs.request_id;
        });
    plan.header.work_units = plan.commands.size();
    for (const RuntimeCountryCommand &command : plan.commands) {
        if (command.observed_generation != 0 &&
            command.observed_generation != _state.generation) {
            error = "stale_command_generation";
            plan.header.preflight_ok = 0;
            copy_reason(plan.header.fallback_reason, sizeof(plan.header.fallback_reason), error);
            return false;
        }
        if (!apply_command(plan.next_state, command, plan, error)) {
            plan.header.preflight_ok = 0;
            copy_reason(plan.header.fallback_reason, sizeof(plan.header.fallback_reason), error);
            return false;
        }
    }
    // Run the research boundary after commands, matching the production
    // ordering. The second pass is a continuation inside the same semantic
    // day: it never allocates research points again because the first pass
    // advances last_research_day, but it can activate a newly completed
    // content-only technology immediately or emit the peer barrier for a
    // technology completed by the first pass.
    if (!run_research_day(plan.next_state, day, plan, error) ||
        !run_research_day(plan.next_state, day, plan, error)) {
        plan.header.preflight_ok = 0;
        copy_reason(plan.header.fallback_reason, sizeof(plan.header.fallback_reason), error);
        return false;
    }
    if ((plan.header.dirty_families & RUNTIME_DIRTY_COUNTRY_TERRITORY) != 0)
        rebuild_territory_csr(plan.next_state);
    plan.header.intent_count = static_cast<uint32_t>(plan.intents.size());
    plan.header.ack_count = 0;
    plan.header.state_hash = hash_business_state(plan.next_state);
    plan.preflight_ok = 1;
    _plan_active = true;
    return true;
}

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
    for (const RuntimeCountryCommand &command : plan.commands) {
        _pending.erase(std::remove_if(_pending.begin(), _pending.end(),
            [&](const RuntimeCountryCommand &queued) {
                return queued.request_id == command.request_id;
            }), _pending.end());
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

bool RuntimeCountryPodAuthority::commit_rejected_day(
        RuntimeCountryPodPlan &plan, std::string &error) {
    error.clear();
    if (!_bootstrapped || !_plan_active || plan.preflight_ok == 0 ||
        plan.header.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
        plan.header.base_generation != _state.generation ||
        plan.header.day != _state.committed_day + 1) {
        error = "country_rejected_plan_commit_invalid";
        return false;
    }

    // Country work before the peer barrier is already a semantic commit in
    // the production ordering: commands, research consumption and the
    // pending activation survive the peer rejection. The calendar boundary
    // closes, but the generation does not advance and the pending technology
    // remains blocked until a later-day retry gets a new request identity.
    RuntimeCountryPodSnapshot next = plan.next_state;
    next.committed_day = plan.header.day;
    next.state_hash = hash_business_state(next);
    _state = std::move(next);
    for (const RuntimeCountryCommand &command : plan.commands) {
        _pending.erase(std::remove_if(_pending.begin(), _pending.end(),
            [&](const RuntimeCountryCommand &queued) {
                return queued.request_id == command.request_id;
            }), _pending.end());
        RuntimeCommandReceipt receipt;
        receipt.request_id = command.request_id;
        receipt.producer_id = command.producer_id;
        receipt.sequence = command.sequence;
        receipt.effective_day = command.effective_day;
        receipt.generation = _state.generation;
        // Generic runtime receipts only describe successful application;
        // the typed Country terminal projection reports COMMITTED separately.
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

bool RuntimeCountryPodAuthority::snapshot(
        RuntimeCountryPodSnapshot &out, std::string &error) const {
    error.clear();
    if (!_bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    out = _state;
    return true;
}

bool RuntimeCountryPodAuthority::encode_save(
        RuntimeCountryPodSaveSection &out, std::string &error) const {
    error.clear();
    out = RuntimeCountryPodSaveSection{};
    if (!_bootstrapped) {
        error = "country_pod_not_bootstrapped";
        return false;
    }
    std::vector<uint8_t> payload;
    payload.reserve(256u + _state.cell_country_slot.size() * 8u +
                    _state.country_goods.size() * sizeof(int64_t));
    append_u32(payload, COUNTRY_SECTION_MARKER);
    append_u32(payload, COUNTRY_SECTION_ABI);
    append_u64(payload, _state.session_epoch);
    append_u64(payload, _catalog.catalog_hash);
    append_i64(payload, _state.committed_day);
    append_i64(payload, _state.last_research_day);
    append_u64(payload, _state.generation);
    append_u64(payload, _state.state_hash);
    append_u32(payload, _state.cell_count);
    append_u32(payload, _state.country_count);
    append_u32(payload, _state.technology_words);
    append_u32(payload, _state.technology_count);
    append_u32(payload, _state.good_count);
    append_u32(payload, _state.research_signal_words);
    append_u32(payload, _state.research_signal_count);
    append_u8(payload, _state.bootstrapped ? 1u : 0u);
    append_u8(payload, _state.research_active_index_valid ? 1u : 0u);
    append_vector(payload, _state.country_active);
    append_vector(payload, _state.country_generation);
    append_vector(payload, _state.country_state_version);
    append_vector(payload, _state.research_active_country_slots);
    append_vector(payload, _state.territory_count);
    append_vector(payload, _state.country_cash);
    append_vector(payload, _state.country_goods);
    append_vector(payload, _state.cell_country_slot);
    append_vector(payload, _state.territory_offsets);
    append_vector(payload, _state.territory_cells);
    append_vector(payload, _state.country_technologies);
    append_vector(payload, _state.country_discovered);
    append_vector(payload, _state.country_pending_technologies);
    append_vector(payload, _state.country_research_signals);
    append_vector(payload, _state.research_signal_evidence_offsets);
    append_u32(payload, static_cast<uint32_t>(_state.research_signal_evidence.size()));
    for (const auto &entry : _state.research_signal_evidence) {
        append_i32(payload, entry.signal);
        append_i32(payload, entry.count);
        append_i64(payload, entry.first_day);
        append_i64(payload, entry.last_day);
        append_i32(payload, entry.first_cell);
    }
    append_vector(payload, _state.research_queues);
    append_vector(payload, _state.research_queue_lengths);
    append_vector(payload, _state.research_weights_bp);
    append_vector(payload, _state.research_daily_budgets);
    append_vector(payload, _state.research_deferred_points);
    append_vector(payload, _state.research_progress);
    append_vector(payload, _state.research_cost_factor);
    append_vector(payload, _state.research_efficiency);
    append_vector(payload, _state.research_peer_flags);
    append_vector(payload, _state.research_auto_purchase);
    append_vector(payload, _state.research_purchased_total);
    append_vector(payload, _state.research_consumed_total);
    append_vector(payload, _state.research_progress_total);
    append_vector(payload, _state.research_completed_total);
    append_vector(payload, _state.is_water);
    append_u32(payload, static_cast<uint32_t>(_pending.size()));
    for (const RuntimeCountryCommand &command : _pending) append_command(payload, command);
    out.payload = std::move(payload);
    out.catalog_hash = _catalog.catalog_hash;
    out.committed_day = _state.committed_day;
    out.generation = _state.generation;
    out.state_hash = _state.state_hash;
    out.descriptor.domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
    out.descriptor.version = COUNTRY_SECTION_ABI;
    out.descriptor.payload_offset = 0;
    out.descriptor.payload_size = static_cast<uint32_t>(out.payload.size());
    out.descriptor.checksum = checksum(out.payload.data(), out.payload.size());
    return true;
}

bool RuntimeCountryPodAuthority::restore_save(
        const RuntimeCountryPodSaveSection &section,
        const RuntimeCountryPodCatalog &catalog, std::string &error) {
    error.clear();
    if (!validate_catalog(catalog, error)) return false;
    if (section.descriptor.domain != static_cast<uint16_t>(RuntimeDomainId::COUNTRY) ||
        section.descriptor.version != COUNTRY_SECTION_ABI ||
        section.descriptor.payload_size != section.payload.size() ||
        section.descriptor.checksum != checksum(section.payload.data(), section.payload.size())) {
        error = "country_section_checksum_or_abi_mismatch";
        return false;
    }
    Reader reader{section.payload.data(), section.payload.size(), 0};
    uint32_t marker = 0, abi = 0, cell_count = 0, country_count = 0;
    uint32_t technology_words = 0, technology_count = 0, good_count = 0;
    uint32_t research_signal_words = 0, research_signal_count = 0;
    uint64_t session_epoch = 0, catalog_hash = 0, generation = 0, state_hash = 0;
    int64_t committed_day = -1, last_research_day = -1;
    uint8_t bootstrapped = 0, active_index_valid = 0;
    if (!reader.u32(marker) || marker != COUNTRY_SECTION_MARKER ||
        !reader.u32(abi) || abi != COUNTRY_SECTION_ABI ||
        !reader.u64(session_epoch) || !reader.u64(catalog_hash) ||
        !reader.i64(committed_day) || !reader.i64(last_research_day) ||
        !reader.u64(generation) || !reader.u64(state_hash) ||
        !reader.u32(cell_count) || !reader.u32(country_count) ||
        !reader.u32(technology_words) || !reader.u32(technology_count) ||
        !reader.u32(good_count) || !reader.u32(research_signal_words) ||
        !reader.u32(research_signal_count) || !reader.u8(bootstrapped) ||
        !reader.u8(active_index_valid)) {
        error = "country_section_payload_truncated";
        return false;
    }
    if (catalog_hash != catalog.catalog_hash ||
        session_epoch == 0 || generation == 0 || committed_day < -1 ||
        last_research_day > committed_day || bootstrapped == 0 ||
        cell_count == 0 || country_count == 0 ||
        technology_count != catalog.technology_count ||
        technology_words != catalog.technology_words ||
        good_count == 0) {
        error = "country_section_header_mismatch";
        return false;
    }
    RuntimeCountryPodSnapshot restored;
    restored.session_epoch = session_epoch;
    restored.generation = generation;
    restored.state_hash = state_hash;
    restored.catalog_hash = catalog_hash;
    restored.committed_day = committed_day;
    restored.last_research_day = last_research_day;
    restored.cell_count = cell_count;
    restored.country_count = country_count;
    restored.technology_words = technology_words;
    restored.technology_count = technology_count;
    restored.good_count = good_count;
    restored.research_signal_words = research_signal_words;
    restored.research_signal_count = research_signal_count;
    restored.bootstrapped = true;
    restored.research_active_index_valid = active_index_valid != 0;
    const uint32_t max_cells = std::max<uint32_t>(cell_count, 1u << 20u);
    const uint32_t max_countries = std::max<uint32_t>(country_count, 1u << 16u);
    if (!reader.vector(restored.country_active, max_countries) ||
        !reader.vector(restored.country_generation, max_countries) ||
        !reader.vector(restored.country_state_version, max_countries) ||
        !reader.vector(restored.research_active_country_slots, max_countries) ||
        !reader.vector(restored.territory_count, max_countries) ||
        !reader.vector(restored.country_cash, max_countries) ||
        !reader.vector(restored.country_goods, max_countries * std::max<uint32_t>(good_count, 1u)) ||
        !reader.vector(restored.cell_country_slot, max_cells) ||
        !reader.vector(restored.territory_offsets, max_countries + 1u) ||
        !reader.vector(restored.territory_cells, max_cells) ||
        !reader.vector(restored.country_technologies, max_countries * technology_words) ||
        !reader.vector(restored.country_discovered, max_countries * technology_words) ||
        !reader.vector(restored.country_pending_technologies, max_countries * technology_words) ||
        !reader.vector(restored.country_research_signals,
                       max_countries * research_signal_words) ||
        !reader.vector(restored.research_signal_evidence_offsets, max_countries + 1u)) {
        error = "country_section_payload_invalid";
        return false;
    }
    uint32_t evidence_count = 0;
    if (!reader.u32(evidence_count) || evidence_count > max_cells * 16u) {
        error = "country_section_signal_evidence_invalid";
        return false;
    }
    restored.research_signal_evidence.resize(evidence_count);
    for (auto &entry : restored.research_signal_evidence) {
        if (!reader.i32(entry.signal) || !reader.i32(entry.count) ||
            !reader.i64(entry.first_day) || !reader.i64(entry.last_day) ||
            !reader.i32(entry.first_cell)) {
            error = "country_section_signal_evidence_truncated";
            return false;
        }
    }
    if (!reader.vector(restored.research_queues, max_countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT * COUNTRY_QUEUE_SLOTS) ||
        !reader.vector(restored.research_queue_lengths, max_countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) ||
        !reader.vector(restored.research_weights_bp, max_countries * RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT) ||
        !reader.vector(restored.research_daily_budgets, max_countries) ||
        !reader.vector(restored.research_deferred_points, max_countries) ||
        !reader.vector(restored.research_progress, max_countries * technology_count) ||
        !reader.vector(restored.research_cost_factor, max_countries) ||
        !reader.vector(restored.research_efficiency, max_countries * 4u) ||
        !reader.vector(restored.research_peer_flags, max_countries * technology_count) ||
        !reader.vector(restored.research_auto_purchase, max_countries) ||
        !reader.vector(restored.research_purchased_total, max_countries) ||
        !reader.vector(restored.research_consumed_total, max_countries) ||
        !reader.vector(restored.research_progress_total, max_countries) ||
        !reader.vector(restored.research_completed_total, max_countries) ||
        !reader.vector(restored.is_water, max_cells)) {
        error = "country_section_payload_invalid";
        return false;
    }
    uint32_t pending_count = 0;
    if (!reader.u32(pending_count) || pending_count > COUNTRY_COMMAND_CAPACITY) {
        error = "country_section_pending_commands_invalid";
        return false;
    }
    std::vector<RuntimeCountryCommand> restored_pending;
    restored_pending.reserve(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        RuntimeCountryCommand command;
        if (!read_command(reader, command)) {
            error = "country_section_pending_commands_truncated";
            return false;
        }
        std::string command_error;
        if (!RuntimeCountryPodAdapter::validate_command(command, command_error) ||
            command.effective_day <= committed_day) {
            error = "country_section_pending_command_invalid";
            return false;
        }
        restored_pending.push_back(command);
    }
    if (reader.cursor != reader.size) {
        error = "country_section_payload_trailing_bytes";
        return false;
    }
    std::string state_error;
    if (!validate_state(restored, state_error)) {
        error = state_error.empty() ? "country_section_state_invalid" : state_error;
        return false;
    }
    restored.state_hash = hash_business_state(restored);
    if (restored.state_hash != state_hash) {
        error = "country_section_state_hash_mismatch";
        return false;
    }
    // Commit only after every header, vector shape, checksum, and state hash
    // has validated. A failed restore leaves the previous worker state intact.
    _state = std::move(restored);
    _catalog = catalog;
    _pending = std::move(restored_pending);
    _plan_active = false;
    _bootstrapped = true;
    _next_generation = _state.generation + 1u;
    return true;
}

bool RuntimeCountryPodAuthority::self_test(std::string &error) {
    error.clear();
    RuntimeCountryPodCatalog catalog;
    catalog.catalog_hash = 0x43545259504f4433ULL; // CTRY POD3
    catalog.technology_count = 4;
    catalog.technology_words = 1;
    catalog.technology_points_good_id = 0;
    catalog.technology_costs.assign(4, 1);
    catalog.technology_domains = {0, 1, 2, 3};
    catalog.technology_flags.assign(4, 0);
    catalog.technology_effect_required.assign(4, 0);
    catalog.prerequisite_offsets.assign(5, 0);
    catalog.entry_milestone_indices.assign(4, -1);
    catalog.research_condition_offsets.assign(5, 0);
    catalog.research_conditions_complete = true;

    RuntimeCountryPodSnapshot state;
    state.session_epoch = 1;
    state.generation = 1;
    state.committed_day = -1;
    state.last_research_day = -1;
    state.catalog_hash = catalog.catalog_hash;
    state.cell_count = 4;
    state.country_count = 2;
    state.technology_words = 1;
    state.technology_count = 4;
    state.good_count = 1;
    state.research_signal_words = 0;
    state.research_signal_count = 0;
    state.bootstrapped = true;
    state.research_active_index_valid = true;
    state.country_active = {1, 1};
    state.country_generation = {1, 1};
    state.country_state_version = {0, 0};
    state.research_active_country_slots = {0, 1};
    state.territory_count = {2, 2};
    state.country_cash = {0, 0};
    state.country_goods = {0, 0};
    state.cell_country_slot = {0, 0, 1, 1};
    state.territory_offsets = {0, 2, 4};
    state.territory_cells = {0, 1, 2, 3};
    state.country_technologies = {0, 0};
    state.country_discovered = {15, 15};
    state.country_pending_technologies = {0, 0};
    state.research_signal_evidence_offsets = {0, 0, 0};
    state.research_queues.assign(2 * 4 * COUNTRY_QUEUE_SLOTS, -1);
    state.research_queue_lengths.assign(2 * 4, 0);
    state.research_weights_bp.assign(2 * 4, 2500);
    state.research_auto_purchase = {0, 0};
    state.research_daily_budgets = {0, 0};
    state.research_deferred_points = {0, 0};
    state.research_progress.assign(2 * 4, 0);
    state.research_cost_factor = {1.0, 1.0};
    state.research_efficiency.assign(2 * 4, 1.0);
    state.research_peer_flags.assign(2 * 4, 0);
    state.research_purchased_total = {0, 0};
    state.research_consumed_total = {0, 0};
    state.research_progress_total = {0, 0};
    state.research_completed_total = {0, 0};
    state.is_water = {0, 0, 0, 0};

    RuntimeCountryPodAuthority authority;
    if (!authority.bootstrap(state, catalog, error)) return false;
    RuntimeCountryPodSnapshot malformed = state;
    malformed.territory_offsets[1] = 4;
    RuntimeCountryPodAuthority malformed_authority;
    if (malformed_authority.bootstrap(malformed, catalog, error)) {
        error = "country_pod_self_test_malformed_snapshot_accepted";
        return false;
    }
    RuntimeCountryCommand transfer;
    transfer.request_id = 1;
    transfer.producer_id = 2;
    transfer.sequence = 1;
    transfer.requested_day = 0;
    transfer.effective_day = 0;
    transfer.opcode = 3;
    transfer.target_handle = (uint64_t{1} << 32u) | 1u;
    transfer.cell = 0;
    if (!authority.queue_command(transfer, error)) return false;
    RuntimeCountryPodPlan plan;
    if (!authority.plan_day(0, 1, plan, error) ||
        !authority.commit_day(plan, {}, error)) return false;
    RuntimeCountryPodSnapshot committed;
    if (!authority.snapshot(committed, error) || committed.committed_day != 0 ||
        committed.cell_country_slot[0] != 1 ||
        committed.territory_offsets != std::vector<int32_t>({0, 1, 4})) {
        error = "country_pod_self_test_commit_failed";
        return false;
    }
    RuntimeCountryCommand stale = transfer;
    stale.request_id = 2;
    stale.sequence = 2;
    stale.requested_day = 0;
    stale.effective_day = 0;
    stale.observed_generation = 999;
    RuntimeCountryPodAuthority stale_authority;
    if (!stale_authority.bootstrap(state, catalog, error) ||
        !stale_authority.queue_command(stale, error)) return false;
    RuntimeCountryPodPlan stale_plan;
    if (stale_authority.plan_day(0, 1, stale_plan, error) ||
        error != "stale_command_generation") {
        error = "country_pod_self_test_stale_generation_not_rejected";
        return false;
    }
    RuntimeCountryPodSaveSection save;
    if (!authority.encode_save(save, error)) return false;
    RuntimeCountryPodAuthority restored;
    if (!restored.restore_save(save, catalog, error) ||
        restored.state_hash() != authority.state_hash()) {
        error = "country_pod_self_test_restore_failed";
        return false;
    }
    save.payload.back() ^= 1u;
    if (restored.restore_save(save, catalog, error) ||
        restored.state_hash() != authority.state_hash()) {
        error = "country_pod_self_test_restore_not_transactional";
        return false;
    }

    RuntimeCountryPodCatalog research_catalog = catalog;
    research_catalog.technology_effect_required.assign(4, 0);
    research_catalog.technology_effect_required[0] = 1;
    RuntimeCountryPodSnapshot research_state = state;
    research_state.country_goods = {1, 0};
    research_state.research_queues.assign(2 * 4 * COUNTRY_QUEUE_SLOTS, -1);
    research_state.research_queue_lengths.assign(2 * 4, 0);
    research_state.research_queues[0] = 0;
    research_state.research_queue_lengths[0] = 1;
    research_state.research_weights_bp.assign(2 * 4, 0);
    research_state.research_weights_bp[0] = 10000;
    research_state.research_weights_bp[4] = 10000;
    research_state.research_progress.assign(2 * 4, 0);
    research_state.research_cost_factor = {1.0, 1.0};
    research_state.research_efficiency.assign(2 * 4, 1.0);
    research_state.research_peer_flags.assign(2 * 4, 0);
    research_state.last_research_day = -1;
    RuntimeCountryPodAuthority research_authority;
    if (!research_authority.bootstrap(research_state, research_catalog, error))
        return false;
    RuntimeCountryPodPlan research_plan;
    if (!research_authority.plan_day(0, 1, research_plan, error) ||
        research_plan.intents.size() != 1u ||
        research_plan.next_state.research_consumed_total[0] != 1 ||
        research_plan.next_state.last_research_day != 0) {
        error = "country_pod_self_test_research_plan_failed";
        return false;
    }
    RuntimeDomainAck research_ack;
    research_ack.request_id = research_plan.intents[0].request_id;
    research_ack.transaction_id = research_plan.intents[0].source_id;
    research_ack.target_handle = research_plan.intents[0].target_handle;
    research_ack.target_generation = research_plan.intents[0].target_generation;
    research_ack.domain = research_plan.intents[0].target_domain;
    research_ack.code = RuntimeDomainAckCode::OK;
    research_ack.effective_day = research_plan.intents[0].effective_day;
    research_ack.technology_flags = COUNTRY_PEER_EFFECT_EXISTS |
        COUNTRY_PEER_EFFECT_FIRE_ACKED;
    if (!research_authority.commit_day(research_plan, {research_ack}, error))
        return false;
    RuntimeCountryPodSnapshot researched;
    if (!research_authority.snapshot(researched, error) ||
        (researched.country_technologies[0] & 1u) == 0 ||
        (researched.country_pending_technologies[0] & 1u) != 0 ||
        researched.research_consumed_total[0] != 1 ||
        researched.last_research_day != 0) {
        error = "country_pod_self_test_research_commit_failed";
        return false;
    }
    RuntimeCountryPodPlan continuation_plan;
    if (!research_authority.plan_day(1, 2, continuation_plan, error) ||
        continuation_plan.next_state.research_consumed_total[0] != 1) {
        error = "country_pod_self_test_research_double_consume";
        return false;
    }
    if (!research_authority.commit_day(continuation_plan, {}, error)) return false;
    return true;
}

} // namespace pk

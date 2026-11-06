#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "economy_runtime_owned_state_codec.h"
#include "economy_runtime_publication_codec.h"
#include "runtime_economy_ecp2.h"
#include <cmath>
#include <cstring>

namespace pk {
namespace {
// Integer stock is a consumer projection, not a lossless checkpoint of the
// resource integrator. Preserve float bits and the per-cell elapsed-day basis.
struct ResourceContinuation {
    uint8_t seeded = 0;
    std::vector<float> reserve, extra;
    std::vector<uint8_t> dirty, was_live;
    std::vector<int32_t> last_day;
};

void put_floats(publication_codec::PublicationWriter &out, std::vector<float> &values) {
    uint32_t count = static_cast<uint32_t>(values.size());
    out.scalar(count);
    for (float value : values) {
        uint32_t bits = 0;
        std::memcpy(&bits, &value, sizeof(bits));
        out.scalar(bits);
    }
}

bool get_floats(publication_codec::PublicationReader &in, std::vector<float> &values) {
    uint32_t count = 0;
    if (!in.scalar(count) || count > (in.bytes.size() - in.cursor) / 4u) return false;
    values.resize(count);
    for (float &value : values) {
        uint32_t bits = 0;
        if (!in.scalar(bits)) return false;
        std::memcpy(&value, &bits, sizeof(bits));
        if (!std::isfinite(value)) return false;
    }
    return true;
}

bool decode(const RuntimeEconomyEcp2State &state, size_t resources,
            ResourceContinuation &out, std::string &error) {
    const auto found = state.domain_blobs.find(ECP2_DOMAIN_OWNED_STATE);
    if (found == state.domain_blobs.end()) { error = "ecp2_resource_continuation_missing"; return false; }
    const auto wire = persistence_codec::publication_block(found->second, 9u);
    publication_codec::PublicationReader in{wire};
    if (!in.scalar(out.seeded) || out.seeded > 1 || !get_floats(in, out.reserve) ||
        !get_floats(in, out.extra) || !in.lanes(out.dirty) || !in.lanes(out.last_day) ||
        !in.lanes(out.was_live) || in.cursor != wire.size()) {
        error = "ecp2_resource_continuation_invalid"; return false;
    }
    const size_t cells = out.seeded ? static_cast<size_t>(std::max(0, state.envelope.cell_count)) : 0;
    if (cells && resources > std::numeric_limits<size_t>::max() / cells) {
        error = "ecp2_resource_continuation_shape_overflow"; return false;
    }
    const size_t lanes = cells * resources;
    if (out.reserve.size() != lanes || out.extra.size() != lanes ||
        out.dirty.size() != (out.seeded ? resources : 0) ||
        out.last_day.size() != cells || out.was_live.size() != cells) {
        error = "ecp2_resource_continuation_shape_invalid"; return false;
    }
    for (float value : out.reserve) if (value < 0) {
        error = "ecp2_resource_continuation_reserve_invalid"; return false;
    }
    for (int32_t day : out.last_day) if (day < 0 || day > state.envelope.current_day) {
        error = "ecp2_resource_continuation_day_invalid"; return false;
    }
    for (uint8_t value : out.dirty) if (value > 1) {
        error = "ecp2_resource_continuation_dirty_invalid"; return false;
    }
    for (uint8_t value : out.was_live) if (value > 1) {
        error = "ecp2_resource_continuation_live_invalid"; return false;
    }
    return true;
}
} // namespace

std::vector<uint8_t> EconomyAuthorityTransfer::capture_resource_continuation(
        const NativeEconomyRuntime &runtime) {
    ResourceContinuation value;
    value.seeded = runtime._worker_resource_seeded;
    if (value.seeded) {
        value.reserve = runtime._worker_resource_reserve;
        value.extra = runtime._worker_resource_extra;
        value.dirty = runtime._worker_resource_extra_dirty;
        value.last_day = runtime._worker_resource_last_day;
        value.was_live = runtime._worker_resource_was_live;
    }
    publication_codec::PublicationWriter out;
    out.scalar(value.seeded);
    put_floats(out, value.reserve);
    put_floats(out, value.extra);
    out.lanes(value.dirty);
    out.lanes(value.last_day);
    out.lanes(value.was_live);
    return std::move(out.bytes);
}

bool EconomyAuthorityTransfer::validate_resource_continuation(const NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error) {
    ResourceContinuation candidate;
    return decode(state, runtime._resource_ids.size(), candidate, error);
}

bool EconomyAuthorityTransfer::restore_resource_continuation(NativeEconomyRuntime &runtime,
        const RuntimeEconomyEcp2State &state, std::string &error) {
    ResourceContinuation candidate;
    if (!decode(state, runtime._resource_ids.size(), candidate, error)) return false;
    runtime._worker_resource_seeded = candidate.seeded;
    runtime._worker_resource_reserve = std::move(candidate.reserve);
    runtime._worker_resource_extra = std::move(candidate.extra);
    runtime._worker_resource_extra_dirty = std::move(candidate.dirty);
    runtime._worker_resource_last_day = std::move(candidate.last_day);
    runtime._worker_resource_was_live = std::move(candidate.was_live);
    const size_t cells = runtime._worker_resource_last_day.size();
    // These scratch lanes are overwritten before read. Republish the restored
    // owner state once because the old dynamic-world mirror can lag its owner.
    runtime._worker_resource_cell_live.assign(cells, 0);
    runtime._worker_resource_regen_factors.assign(cells, 1.0f);
    runtime._worker_resource_mirror_mark.assign(cells, 0);
    runtime._worker_resource_mirror_cells.clear();
    for (size_t cell = 0; cell < cells; ++cell)
        runtime.mark_worker_resource_mirror_cell(static_cast<int32_t>(cell));
    return true;
}
} // namespace pk

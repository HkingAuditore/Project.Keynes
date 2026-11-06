#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "economy_runtime_owned_state_codec.h"
#include "economy_runtime_publication_codec.h"
#include "runtime_economy_ecp2.h"

namespace pk {
namespace {
struct Cooldown { int32_t cell, source_group, target_group; int64_t until_day; };
bool decode(const RuntimeEconomyEcp2State &state, std::vector<Cooldown> &rows,
            std::string &error) {
    const auto found = state.domain_blobs.find(ECP2_DOMAIN_OWNED_STATE);
    if (found == state.domain_blobs.end()) {
        error = "ecp2_owner_mobility_continuation_missing"; return false;
    }
    const auto wire = persistence_codec::publication_block(found->second, 10u);
    publication_codec::PublicationReader in{wire};
    uint32_t count = 0;
    if (!in.scalar(count) || count > (wire.size() - in.cursor) / 20u) {
        error = "ecp2_owner_mobility_continuation_invalid"; return false;
    }
    rows.resize(count);
    for (auto &row : rows) {
        if (!in.scalar(row.cell) || !in.scalar(row.source_group) ||
            !in.scalar(row.target_group) || !in.scalar(row.until_day) ||
            row.cell < 0 || row.cell >= state.envelope.cell_count ||
            row.source_group < 0 || row.target_group < 0 || row.until_day < 0) {
            error = "ecp2_owner_mobility_continuation_invalid"; return false;
        }
    }
    if (in.cursor != wire.size()) {
        error = "ecp2_owner_mobility_continuation_trailing"; return false;
    }
    return true;
}
} // namespace

std::vector<uint8_t> EconomyAuthorityTransfer::capture_owner_mobility_continuation(
        const NativeEconomyRuntime &runtime) {
    publication_codec::PublicationWriter out;
    uint32_t count = static_cast<uint32_t>(runtime._owner_mobility_cooldowns.size());
    out.scalar(count);
    // Keep the exact owner order, including expired rows. No pruning on save.
    for (auto row : runtime._owner_mobility_cooldowns) {
        out.scalar(row.cell); out.scalar(row.source_group);
        out.scalar(row.target_group); out.scalar(row.until_day);
    }
    return std::move(out.bytes);
}

bool EconomyAuthorityTransfer::validate_owner_mobility_continuation(
        const NativeEconomyRuntime &, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    std::vector<Cooldown> rows;
    return decode(state, rows, error);
}

bool EconomyAuthorityTransfer::restore_owner_mobility_continuation(
        NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    std::vector<Cooldown> rows;
    if (!decode(state, rows, error)) return false;
    runtime._owner_mobility_cooldowns.clear();
    for (const auto &row : rows)
        runtime._owner_mobility_cooldowns.push_back(
            {row.cell, row.source_group, row.target_group, row.until_day});
    return true;
}
} // namespace pk

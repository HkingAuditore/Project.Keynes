#include "economy_authority_transfer.h"
#include "economy_runtime.h"
#include "economy_runtime_owned_state_codec.h"
#include "runtime_checkpoint_wire.h"
#include "runtime_economy_ecp2.h"

#include <algorithm>

namespace pk {
namespace {
constexpr auto structural_fields = [](auto &io, auto &entry) {
    return io.field(entry.opcode) && io.field(entry.source_slot) &&
        io.field(entry.cell) && io.field(entry.signature) &&
        io.field(entry.population) && io.field(entry.funds) &&
        io.field(entry.sequence);
};

constexpr auto procurement_line_fields = [](auto &io, auto &line) {
    return io.field(line.good) && io.field(line.required) &&
        io.field(line.purchased_total);
};

constexpr auto procurement_state_fields = [](auto &io, auto &state) {
    return io.field(state.country_handle) && io.field(state.policy_enabled) &&
        io.field(state.treasury_share_bp) && io.field(state.research_share_bp) &&
        io.field(state.era_share_bp) && io.field(state.colonization_share_bp) &&
        io.field(state.era_active) && io.rows(state.era_goods, procurement_line_fields) &&
        io.field(state.national_daily) && io.field(state.research_daily) &&
        io.field(state.other_daily) && io.field(state.era_daily) &&
        io.field(state.colonization_daily) && io.field(state.colonization_allowance) &&
        io.field(state.colonization_allowance_day) && io.field(state.era_cash_spent_total) &&
        io.field(state.era_cash_epoch) && io.field(state.era_last_epoch_cash) &&
        io.field(state.research_cash_epoch) && io.field(state.research_cash_last_epoch) &&
        io.field(state.colonization_cash_epoch) && io.field(state.colonization_cash_last_epoch);
};

constexpr auto procurement_update_fields = [](auto &io, auto &update) {
    return io.field(update.kind) && io.field(update.country_handle) && io.field(update.flag) &&
        io.field(update.treasury_share_bp) && io.field(update.research_share_bp) &&
        io.field(update.era_share_bp) && io.field(update.colonization_share_bp) &&
        io.rows(update.goods, checkpoint_scalar) && io.rows(update.quantities, checkpoint_scalar) &&
        update.goods.size() == update.quantities.size() &&
        io.field(update.effective_day) && io.field(update.sequence) && io.field(update.order);
};

constexpr auto pair_fields = [](auto &io, auto &row) {
    return io.field(row.first) && io.field(row.second);
};

template<class Labor>
int64_t archived_living_cost(const Labor &labor, size_t cell) {
    if (cell + 1 >= labor.cell_offsets.size()) return 0;
    int64_t cost = 0;
    // The daily sample is shared across professions. New rows start at zero.
    for (int32_t row = labor.cell_offsets[cell]; row < labor.cell_offsets[cell + 1]; ++row)
        cost = std::max(cost, labor.base_living_cost[row]);
    return cost;
}
} // namespace

void EconomyAuthorityTransfer::append_continuations(
        const NativeEconomyRuntime &runtime, std::vector<uint8_t> &wire) {
    persistence_codec::append_publication_block(wire, capture_resource_continuation(runtime), 9u);
    persistence_codec::append_publication_block(wire, capture_owner_mobility_continuation(runtime), 10u);
    persistence_codec::append_publication_block(wire, capture_cadence_continuation(runtime), 11u);
    persistence_codec::append_publication_block(wire, capture_population_continuation(runtime), 12u);
    persistence_codec::append_publication_block(wire, capture_climate_continuation(runtime), 13u);
    // A command applied after the Economy epoch closes can enqueue structural
    // work for the next epoch. Its committed receipt does not store that work.
    if (!runtime._structural_commands.empty()) {
        CheckpointWriter out;
        out.rows(runtime._structural_commands, structural_fields);
        persistence_codec::append_publication_block(
            wire, out.bytes, persistence_codec::OWNED_PENDING_STRUCTURE_BLOCK);
    }
    if (!runtime._deferred_population_reconcile_cells.empty()) {
        CheckpointWriter out;
        out.rows(runtime._deferred_population_reconcile_cells, checkpoint_scalar);
        persistence_codec::append_publication_block(
            wire, out.bytes, persistence_codec::OWNED_POPULATION_RECONCILE_BLOCK);
    }
    {
        auto &inbox = *runtime._procurement_inbox;
        std::lock_guard<std::mutex> lock(inbox.mutex);
        CheckpointWriter out;
        out.field(inbox.next_order);
        out.rows(runtime._country_procurement, [](auto &io, const auto &entry) {
            return procurement_state_fields(io, entry.second);
        });
        out.rows(inbox.updates, procurement_update_fields);
        out.rows(runtime._country_trade_orders_by_slot, pair_fields);
        out.rows(runtime._epoch_research_daily, checkpoint_scalar);
        persistence_codec::append_publication_block(
            wire, out.bytes, persistence_codec::OWNED_PROCUREMENT_BLOCK);
    }
    const auto trade = capture_trade_continuation(runtime);
    if (!trade.empty()) {
        persistence_codec::append_publication_block(
            wire, trade, persistence_codec::OWNED_TRADE_PLAN_BLOCK);
    }
    std::vector<std::pair<uint32_t, int64_t>> living_cost_exceptions;
    for (size_t cell = 0; cell < runtime._cell_living_cost_per_capita.size(); ++cell) {
        const int64_t cost = runtime._cell_living_cost_per_capita[cell];
        if (cost != archived_living_cost(runtime._labor_signals, cell))
            living_cost_exceptions.emplace_back(cell, cost);
    }
    if (!living_cost_exceptions.empty()) {
        CheckpointWriter out;
        out.rows(living_cost_exceptions, pair_fields);
        persistence_codec::append_publication_block(
            wire, out.bytes, persistence_codec::OWNED_LIVING_COST_EXCEPTIONS_BLOCK);
    }
}
bool EconomyAuthorityTransfer::validate_continuations(
        const NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    return validate_resource_continuation(runtime, state, error) &&
           validate_owner_mobility_continuation(runtime, state, error) &&
           validate_cadence_continuation(runtime, state, error) &&
           validate_population_continuation(runtime, state, error) &&
           validate_climate_continuation(runtime, state, error);
}
bool EconomyAuthorityTransfer::restore_continuations(
        NativeEconomyRuntime &runtime, const RuntimeEconomyEcp2State &state,
        std::string &error) {
    if (!restore_resource_continuation(runtime, state, error) ||
        !restore_owner_mobility_continuation(runtime, state, error) ||
        !restore_cadence_continuation(runtime, state, error) ||
        !restore_population_continuation(runtime, state, error) ||
        !restore_climate_continuation(runtime, state, error)) return false;
    bool structure_present = false;
    const auto wire = persistence_codec::publication_block(
        state.domain_blobs.at(ECP2_DOMAIN_OWNED_STATE),
        persistence_codec::OWNED_PENDING_STRUCTURE_BLOCK, &structure_present);
    CheckpointReader in{wire.data(), wire.size()};
    std::vector<NativeEconomyRuntime::StructuralCommand> pending;
    if (structure_present && (!in.rows(pending, structural_fields) || in.cursor != in.size)) {
        error = "economy_pending_structure_checkpoint_corrupt";
        return false;
    }
    runtime._structural_commands.swap(pending);
    const auto population = persistence_codec::publication_block(
        state.domain_blobs.at(ECP2_DOMAIN_OWNED_STATE),
        persistence_codec::OWNED_POPULATION_RECONCILE_BLOCK);
    CheckpointReader population_in{population.data(), population.size()};
    std::vector<int32_t> cells;
    if (!population_in.rows(cells, checkpoint_scalar) || population_in.cursor != population_in.size)
        cells.clear();
    runtime._deferred_population_reconcile_cells.swap(cells);
    const auto procurement = persistence_codec::publication_block(
        state.domain_blobs.at(ECP2_DOMAIN_OWNED_STATE),
        persistence_codec::OWNED_PROCUREMENT_BLOCK);
    if (!procurement.empty()) {
        CheckpointReader procurement_in{procurement.data(), procurement.size()};
        uint64_t next_order = 1;
        std::vector<decltype(runtime._country_procurement)::mapped_type> rows;
        std::vector<NativeEconomyRuntime::PendingProcurementUpdate> updates;
        std::vector<std::pair<uint64_t, int64_t>> trades;
        std::vector<int64_t> research;
        if (procurement_in.field(next_order) && procurement_in.rows(rows, procurement_state_fields) &&
            procurement_in.rows(updates, procurement_update_fields) &&
            procurement_in.rows(trades, pair_fields) &&
            procurement_in.rows(research, checkpoint_scalar) &&
            procurement_in.cursor == procurement_in.size) {
            for (auto &row : rows)
                runtime._country_procurement.emplace(row.country_handle, std::move(row));
            runtime._country_trade_orders_by_slot = std::move(trades);
            runtime._epoch_research_daily = std::move(research);
            auto &inbox = *runtime._procurement_inbox;
            std::lock_guard<std::mutex> lock(inbox.mutex);
            inbox.updates = std::move(updates);
            inbox.next_order = next_order;
        }
    }
    restore_trade_continuation(runtime, persistence_codec::publication_block(
        state.domain_blobs.at(ECP2_DOMAIN_OWNED_STATE),
        persistence_codec::OWNED_TRADE_PLAN_BLOCK));
    auto &living_cost = runtime._cell_living_cost_per_capita;
    for (size_t cell = 0; cell < living_cost.size(); ++cell)
        living_cost[cell] = archived_living_cost(runtime._labor_signals, cell);
    const auto exceptions = persistence_codec::publication_block(
        state.domain_blobs.at(ECP2_DOMAIN_OWNED_STATE), persistence_codec::OWNED_LIVING_COST_EXCEPTIONS_BLOCK);
    CheckpointReader costs_in{exceptions.data(), exceptions.size()};
    std::vector<std::pair<uint32_t, int64_t>> costs;
    if (costs_in.rows(costs, pair_fields) && costs_in.cursor == costs_in.size) {
        for (const auto &[cell, cost] : costs)
            if (cell < living_cost.size() && cost >= 0) living_cost[cell] = cost;
    }
    return true;
}
} // namespace pk

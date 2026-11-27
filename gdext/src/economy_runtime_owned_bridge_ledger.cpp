#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "economy_resource_projection.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "economy_host_port.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

namespace {
using Clock = std::chrono::steady_clock;
double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

void NativeEconomyRuntime::fill_economy_audit_snapshot(
        int64_t &pop_err, int64_t &money_err, int64_t &goods_err,
        uint32_t &dirty_family_mask, int64_t &changed_cells,
        int64_t &changed_cohorts) const {
    pop_err = 0;
    money_err = 0;
    goods_err = 0;
    dirty_family_mask = 0;
    changed_cells = static_cast<int64_t>(_population_changed_cells.size());
    changed_cohorts = 0;
    if (_fatal) {
        pop_err = 1;
        money_err = 1;
        goods_err = 1;
        return;
    }
    if (_epoch_active) return;
    const int64_t population_expected =
        _opening_totals.population + _births - _deaths +
        _external_population_delta;
    const int64_t money_open = _opening_totals.cohort_funds +
        _opening_totals.country_cash + _opening_totals.escrow_cash;
    const int64_t money_close = _closing_totals.cohort_funds +
        _closing_totals.country_cash + _closing_totals.escrow_cash;
    const int64_t goods_expected = _opening_totals.goods_stock +
        _explicit_stock_delta + _production_output_stock +
        _production_output_discarded + _production_output_retained -
        _consumed_goods - _owner_output_consumed -
        _construction_goods_consumed - _production_inputs_consumed -
        _maintenance_goods_consumed -
        _production_output_discarded - _cycle_flow_discarded -
        _bullion_stock_consumed - _country_research_goods_consumed;
    pop_err = _closing_totals.population - population_expected;
    money_err = money_close -
        (money_open + _explicit_money_mint - _explicit_money_burn);
    goods_err = _closing_totals.goods_stock - goods_expected;
    dirty_family_mask = families_store().active_count > 0 ? 1u : 0u;
    changed_cohorts = population_store().active_count;
}

void NativeEconomyRuntime::fill_ledger_building_from_store(
        RuntimeEconomyBuildingCommittedBlock &block,
        const RuntimeEconomyBuildingStore &store) const {
    block.captured = true;
    block.catalog_hash =
        static_cast<uint64_t>(std::max<int64_t>(0, _building_catalog_hash.get()));
    const auto block_copy_started = Clock::now();
    block.store = store;
    EconomyCostProbe::record("domain_projection.building_block_copy",
                             _current_day.get(), elapsed_ms(block_copy_started));
    block.sync_counts_from_store();
    const auto block_hash_started = Clock::now();
    block.recompute_content_hash();
    EconomyCostProbe::record("domain_projection.building_block_hash",
                             _current_day.get(), elapsed_ms(block_hash_started));
}

void NativeEconomyRuntime::fill_ledger_trade_escrow_from_store(
        RuntimeEconomyTradeEscrowCommittedBlock &block,
        const RuntimeEconomyTradeEscrowStore &store) const {
    block.captured = true;
    block.country_trade_revision = _country_trade_revision.get();
    block.next_id = trade_orders_store().next_id;
    block.store = store;
    block.sync_counts_from_store();
    block.recompute_content_hash();
}

void NativeEconomyRuntime::fill_ledger_family_from_store(
        RuntimeEconomyFamilyCommittedBlock &block,
        const RuntimeEconomyFamilyStore &store) const {
    block.captured = true;
    block.catalog_hash =
        static_cast<uint64_t>(std::max<int64_t>(0, _family_catalog_hash.get()));
    block.person_catalog_hash =
        static_cast<uint64_t>(std::max<int64_t>(0, _person_catalog_hash.get()));
    block.trait_catalog_hash =
        static_cast<uint64_t>(std::max<int64_t>(0, _family_trait_catalog_hash.get()));
    block.runtime_mode = _family_runtime_mode.get();
    block.person_runtime_mode = _person_runtime_mode.get();
    block.next_expedition_stable_id = _next_family_expedition_stable_id.get();
    block.store = store;
    block.sync_counts_from_store();
    block.recompute_content_hash();
}

void NativeEconomyRuntime::fill_ledger_resource_from_store(
        RuntimeEconomyResourceCommittedBlock &block,
        const RuntimeEconomyResourceStore &store) const {
    EconomyCostProbe projection_cost("projection.resource_mirror", _current_day.get());
    static const bool scalar_projection = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_RESOURCE_PROJECTION_SCALAR);
        return value && std::strcmp(value, "1") == 0;
    }();
    block.captured = true;
    block.catalog_hash =
        static_cast<uint64_t>(std::max<int64_t>(0, _catalog_hash.get()));
    block.environment_hash =
        static_cast<uint64_t>(std::max<int64_t>(0, _environment_hash.get()));
    block.context_day = _building_context_day;
    block.min_reserve_q16 = _resource_min_reserve_q16.get();
    block.safe_harvest_q16 = _resource_safe_harvest_q16.get();
    block.min_horizon_days = _resource_min_horizon_days.get();
    // Only the ABI9 wire columns belong in the committed mirror; the epoch
    // harvest scratch on a live store is transient and is never published.
    block.store.resource_count = store.resource_count;
    block.store.cell_count = store.cell_count;
    {
        EconomyCostProbe copy_cost("projection.resource_wire_copy", _current_day.get());
        const auto stock_bytes = project_resource_wire_column(
            block.store.stock, store.stock, scalar_projection);
        const auto generation_bytes = project_resource_wire_column(
            block.store.cell_generation, store.cell_generation, scalar_projection);
        copy_cost.set_work(stock_bytes + generation_bytes);
    }
    block.sync_counts_from_store();
    {
        EconomyCostProbe hash_cost("projection.resource_wire_hash", _current_day.get());
        block.recompute_content_hash();
    }
}

void NativeEconomyRuntime::fill_ledger_epoch_cursor(
        RuntimeEconomyEpochCursorCommittedBlock &block) const {
    block.captured = true;
    block.sample_day = _sample_day;
    block.current_day = _current_day.get();
    block.last_committed_day = _last_committed_day.get();
    block.epoch_id = _epoch_id.get();
    block.epoch_days = _epoch_days.get();
    block.epoch_active = _epoch_active ? 1 : 0;
    block.native_stage = static_cast<int32_t>(_stage);
    block.graph_completed_mask =
        _epoch_active ? 0u : RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
    // Committed-day mirror stores an idle marker only; mid-epoch resume
    // blobs remain a later production-writer concern.
    block.store.idle_marker = 0;
    block.recompute_content_hash();
}

void NativeEconomyRuntime::capture_committed_ledger_state(
        RuntimeEconomyLedgerState &out, uint64_t completed_stage_hash,
        bool compute_ledger_hash) const {
    out.clear();
    // ECP2 mid-epoch checkpoints need the live SoA shape as a rollback source;
    // the public legacy save gate still rejects mid-epoch writes unless its
    // explicit ECP2 flag is enabled.
    if (_fatal) return;
    const auto source_started = Clock::now();
    out.source_state_hash = completed_stage_hash != 0 ? completed_stage_hash :
        static_cast<uint64_t>(std::max<int64_t>(0, state_hash()));
    const auto population_started = Clock::now();
    out.generation = _committed_generation;
    out.committed_day = _current_day.get();
    out.market_count = market_store().market_count.get();
    out.good_count = market_store().good_count.get();
    out.cohort_active = population_store().active;
    out.cohort_cell.assign(population_store().active.size(), -1);
    out.cohort_slot.resize(population_store().active.size());
    for (size_t i = 0; i < out.cohort_slot.size(); ++i) out.cohort_slot[i] = static_cast<int32_t>(i);
    for (size_t page = 0; page < population_store().page_cell.size(); ++page) {
        const int32_t cell = population_store().page_cell[page];
        const size_t base = page * RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < RuntimeEconomyPopulationStore::COHORT_PAGE_SIZE && base + static_cast<size_t>(lane) < out.cohort_cell.size(); ++lane)
            out.cohort_cell[base + static_cast<size_t>(lane)] = cell;
    }
    out.cohort_signature_id = population_store().signature_id;
    out.cohort_generation = population_store().generation;
    out.cohort_reserved = population_store().reserved;
    out.cohort_reservation_owner = population_store().reservation_owner;
    out.cohort_population = population_store().population;
    out.cohort_funds = population_store().funds;
    out.cohort_epoch_income = population_store().epoch_income;
    out.cohort_epoch_expense = population_store().epoch_expense;
    out.cohort_needs_satisfaction = population_store().needs_satisfaction;
    out.cohort_composite_satisfaction = population_store().composite_satisfaction;
    out.cohort_owner_employed = population_store().owner_employed;
    out.cohort_employee_employed = population_store().employee_employed;
    const auto market_started = Clock::now();
    out.market_stock = market_store().stock;
    out.market_price = market_store().price;
    out.market_demand_ema = market_store().demand_ema;
    out.market_last_shortage_q16 = market_store().last_shortage_q16;
    out.market_cell_to_market = market_store().cell_to_market;
    // A cell→market column that the restore did not carry must not reach `begin_save`.
    //
    // ECP2 does not serialize this column (it is derived: `market_store().clear()` fills
    // it with the identity mapping). After a POD restore the bound OwnedState therefore
    // has an EMPTY `cell_to_market` while every other market lane is sized correctly, and
    // `NativeEconomyRuntime::begin_save` rejects the shape with
    // `economy_save_state_shape_invalid`. That gate runs for the ROLLBACK BACKUP that
    // `apply_ecp2_authority` takes before applying anything, so a restored world could
    // not start its worker at all (`ecp2_atomic_backup_failed` ->
    // `runtime_worker_start_failed`), which production hits on every load
    // (`world_runtime_host.gd:804`). Measured: `[save-shape] market_cell_to_market
    // actual=0 expected=192`.
    //
    // Rebuilding it here is exact, not a guess: the derived column IS the identity
    // mapping when the archive has no override, which is the same value `clear()` packs.
    if (out.market_cell_to_market.size() !=
            static_cast<size_t>(std::max(0, market_store().market_count.get()))) {
        if (pk::runtime_switch_value(pk::RuntimeSwitch::PK_SAVE_SHAPE_PROBE) != nullptr)
            pk::log_error("[save-shape/capture] cell_to_market=%zu market_count=%d "
                "bound=%d cells=%d stock=%zu",
                out.market_cell_to_market.size(),
                market_store().market_count.get(),
                formula_owned_bound() ? 1 : 0, _cell_count.get(),
                market_store().stock.size());
        const size_t markets = static_cast<size_t>(
            std::max(0, market_store().market_count.get()));
        out.market_cell_to_market.resize(markets);
        for (size_t cell = 0; cell < markets; ++cell)
            out.market_cell_to_market[cell] = static_cast<int32_t>(cell);
    }

    // A+Y N2/N8: one live group/pending lane in both modes; sync only repacks
    // the role CSR before the ledger reads it.
    const auto building_started = Clock::now();
    sync_owned_building_store(mutable_buildings_store());
    fill_ledger_building_from_store(out.building, buildings_store());
    const auto blocks_started = Clock::now();

    if (formula_owned_bound()) {
        out.trade_escrow = _formula_owned->trade_escrow;
        out.family = _formula_owned->family;
        out.resource = _formula_owned->resource;
        // The bound OwnedState is a COMPLETE capture, so every block must report that.
        //
        // `building` above is filled by `fill_ledger_building_from_store`, which always
        // sets `captured = true`. The three blocks copied here took their flag from the
        // OwnedState verbatim, and after a POD restore those flags can still be false.
        // The result was `building.captured != trade_escrow.captured`, rejected as
        // `building_trade_block_pairing` -- i.e. the rollback backup that
        // `apply_ecp2_authority` takes BEFORE applying anything could not be produced,
        // surfacing as `ecp2_atomic_backup_failed` and killing `start_runtime_worker`.
        // Production hits this on every load that restarts the worker
        // (`world_runtime_host.gd:804`).
        //
        // Marking them here is the same statement the non-bound branch makes
        // unconditionally: this runtime just repacked those stores from its live tables.
        // The block stores must accompany the flag -- a block that reports `captured`
        // with an empty store fails the shape check one layer down
        // (`economy_save_state_shape_invalid`), so the store is packed from the live
        // table too rather than copied from a possibly-stale OwnedState field.
        out.trade_escrow.captured = true;
        out.trade_escrow.country_trade_revision = _country_trade_revision.get();
        out.trade_escrow.next_id = trade_orders_store().next_id;
        sync_owned_trade_escrow_store(out.trade_escrow.store);
        out.trade_escrow.sync_counts_from_store();
        out.trade_escrow.recompute_content_hash();

        out.family.captured = true;
        out.family.catalog_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _family_catalog_hash.get()));
        out.family.person_catalog_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _person_catalog_hash.get()));
        out.family.trait_catalog_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _family_trait_catalog_hash.get()));
        out.family.runtime_mode = _family_runtime_mode.get();
        out.family.person_runtime_mode = _person_runtime_mode.get();
        out.family.next_expedition_stable_id = _next_family_expedition_stable_id.get();
        sync_owned_family_store(out.family.store);
        out.family.sync_counts_from_store();
        out.family.recompute_content_hash();

        out.resource.captured = true;
        out.resource.catalog_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _catalog_hash.get()));
        out.resource.environment_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _environment_hash.get()));
        out.resource.context_day = _building_context_day;
        out.resource.min_reserve_q16 = _resource_min_reserve_q16.get();
    } else {
        out.trade_escrow.captured = true;
        out.trade_escrow.country_trade_revision = _country_trade_revision.get();
        out.trade_escrow.next_id = trade_orders_store().next_id;
        sync_owned_trade_escrow_store(out.trade_escrow.store);
        out.trade_escrow.sync_counts_from_store();
        out.trade_escrow.recompute_content_hash();

        out.family.captured = true;
        out.family.catalog_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _family_catalog_hash.get()));
        out.family.person_catalog_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _person_catalog_hash.get()));
        out.family.trait_catalog_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _family_trait_catalog_hash.get()));
        out.family.runtime_mode = _family_runtime_mode.get();
        out.family.person_runtime_mode = _person_runtime_mode.get();
        out.family.next_expedition_stable_id = _next_family_expedition_stable_id.get();
        sync_owned_family_store(out.family.store);
        out.family.sync_counts_from_store();
        out.family.recompute_content_hash();

        out.resource.captured = true;
        out.resource.catalog_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _catalog_hash.get()));
        out.resource.environment_hash =
            static_cast<uint64_t>(std::max<int64_t>(0, _environment_hash.get()));
        out.resource.context_day = _building_context_day;
        out.resource.min_reserve_q16 = _resource_min_reserve_q16.get();
        out.resource.safe_harvest_q16 = _resource_safe_harvest_q16.get();
        out.resource.min_horizon_days = _resource_min_horizon_days.get();
        sync_owned_resource_store(out.resource.store);
        out.resource.sync_counts_from_store();
        out.resource.recompute_content_hash();
    }

    fill_ledger_epoch_cursor(out.epoch_cursor);

    const auto hash_started = Clock::now();
    if (compute_ledger_hash) out.recompute_hash();
    const auto finished = Clock::now();
    const auto ms = [](Clock::time_point from, Clock::time_point to) {
        return std::chrono::duration<double, std::milli>(to - from).count();
    };
    const int64_t day = out.committed_day;
    EconomyCostProbe::record("mirror.capture.source_hash", day, ms(source_started, population_started));
    EconomyCostProbe::record("mirror.capture.population", day, ms(population_started, market_started),
        out.cohort_active.size());
    EconomyCostProbe::record("mirror.capture.market", day, ms(market_started, building_started),
        out.market_stock.size());
    EconomyCostProbe::record("mirror.capture.building", day, ms(building_started, blocks_started));
    EconomyCostProbe::record("mirror.capture.blocks", day, ms(blocks_started, hash_started));
    EconomyCostProbe::record("mirror.capture.hash", day, ms(hash_started, finished));
}

} // namespace pk

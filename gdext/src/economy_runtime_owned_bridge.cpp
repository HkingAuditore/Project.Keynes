#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
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

void NativeEconomyRuntime::publish_shadow_graph_stage_reference(
        RuntimeEconomyGraphStage stage) {
    // Skip when worker owns ECONOMY unless ACTIVE_WITH_PARITY needs stage refs
    // for the post-epoch StageOps hash probe (mutate=false, no second ledger).
    if (_simulation_host == nullptr) return;
    const bool worker_owns = _simulation_host->domain_is_worker_authoritative(
        RuntimeDomainId::ECONOMY);
    if (worker_owns && !_simulation_host->economy_parity_shadow_enabled()) {
        return;
    }
    const uint64_t hash =
        static_cast<uint64_t>(std::max<int64_t>(0, state_hash()));
    const uint64_t work_units =
        static_cast<uint64_t>(std::max(0, _cell_count.get()));
    _simulation_host->publish_economy_stage_reference(
        static_cast<uint32_t>(stage), _sample_day, hash, hash, work_units);
}

bool NativeEconomyRuntime::bind_soa_view(EconomySoAView &view,
                                         std::string &error) {
    error.clear();
    view = EconomySoAView{};
    view.cell_count = static_cast<uint32_t>(std::max(0, _cell_count.get()));
    view.country_count = static_cast<uint32_t>(std::max(0, _epoch_country_count));
    view.good_count = static_cast<uint32_t>(std::max(0, market_store().good_count.get()));
    view.building_cell_offsets = _building_cell_offsets.empty()
        ? nullptr : _building_cell_offsets.data();
    view.building_cell_offsets_count = _building_cell_offsets.size();
    view.building_active_cells = _building_active_cells.empty()
        ? nullptr : _building_active_cells.data();
    view.building_active_cells_count = _building_active_cells.size();
    view.epoch_plan_cells =
        _epoch_plan_cells.empty() ? nullptr : _epoch_plan_cells.data();
    view.epoch_plan_cells_count = _epoch_plan_cells.size();
    view.survival_food_good_mask = _survival_food_good_mask.empty()
        ? nullptr : _survival_food_good_mask.data();
    view.survival_clothing_good_mask = _survival_clothing_good_mask.empty()
        ? nullptr : _survival_clothing_good_mask.data();
    view.survival_mask_count = std::min(_survival_food_good_mask.size(),
                                        _survival_clothing_good_mask.size());
    view.population_by_cell = _cell_population_total.empty()
        ? nullptr : _cell_population_total.data();
    view.treasury_by_country = _fiscal_escrow_by_country.empty()
        ? nullptr : _fiscal_escrow_by_country.data();
    view.generation = _committed_generation;
    view.sample_day = _current_day.get();
    view.committed_day = _last_committed_day.get();
    view.runtime_hook = this;
    // Phase-5: expose live formula stores (OwnedState when bound).
    view.population = &population_store();
    view.market = &market_store();
    // The graph stages read `view.market` for the whole epoch. An unshaped store
    // here is the same defect the day-entry probe reports; keep this one quiet
    // unless the view really captured a matrix that cannot be addressed.
    {
        const size_t markets = static_cast<size_t>(
            std::max(0, view.market->market_count.get()));
        const size_t goods = static_cast<size_t>(
            std::max(0, view.market->good_count.get()));
        if (markets <= 0 || goods <= 0 ||
            view.market->stock.size() != markets * goods) {
            std::fprintf(stderr,
                "[economy-soa-view] day=%lld backing=%s market=%p stock=%zu "
                "market_count=%d good_count=%d cell_to_market=%zu cell_count=%u\n",
                static_cast<long long>(_current_day.get()),
                formula_owned_bound() ? "owned_state" : "ner_local",
                static_cast<const void *>(view.market), view.market->stock.size(),
                view.market->market_count.get(), view.market->good_count.get(),
                view.market->cell_to_market.size(), view.cell_count);
            std::fflush(stderr);
        }
    }
    if (_formula_owned != nullptr) {
        view.buildings = &_formula_owned->buildings;
        view.trade_orders = &_formula_owned->trade_orders;
        view.families = &_formula_owned->families;
        view.resources = &_formula_owned->resources;
        view.owned_state = _formula_owned;
    }
    return true;
}

bool NativeEconomyRuntime::bind_formula_owned_state(
        RuntimeEconomyOwnedState &owned, std::string &error) {
    error.clear();
    if (_formula_owned == &owned) return true;
    if (_formula_owned != nullptr) {
        error = "economy_formula_owned_already_bound";
        return false;
    }
    // The market store is only carried across when the local population lane is
    // live. When it is not, the OwnedState's own market becomes authoritative
    // for every later read, so its shape has to be the same one the runtime was
    // configured with -- log both sides before the swap.
    std::fprintf(stderr,
        "[economy-owned-bind] cell_count=%d local_population_active=%zu "
        "owned_population_active=%zu local_stock=%zu local_markets=%d "
        "local_goods=%d owned_stock=%zu owned_markets=%d owned_goods=%d "
        "owned_cell_to_market=%zu\n",
        _cell_count.get(), _population_local.active.size(),
        owned.population.active.size(), _market_local.stock.size(),
        _market_local.market_count.get(), _market_local.good_count.get(),
        owned.market.stock.size(), owned.market.market_count.get(),
        owned.market.good_count.get(), owned.market.cell_to_market.size());
    std::fflush(stderr);
    // Live NER-local wins at bind time so StageOps does not drop in-memory work.
    if (!_population_local.active.empty()) {
        owned.population = std::move(_population_local);
        owned.market = std::move(_market_local);
        // A+Y N2: the group lane itself moves, so there is never a second live
        // copy. Projections are repacked from the new home after the bind.
        owned.buildings = std::move(_buildings_soa_local);
    } else if (owned.population.active.empty()) {
        error = "economy_formula_owned_empty";
        return false;
    }
    _population_local = PopulationStore{};
    _market_local = MarketStore{};
    _buildings_soa_local = RuntimeEconomyBuildingStore{};
    _formula_owned = &owned;
    // Publish the binding to the store's own protocol owner: from this instant
    // the OwnedState's dense lanes are this runtime's live state, so nothing may
    // clear them out from under it (see RuntimeEconomyPodAuthority::reset()).
    owned.formula_owner_bound = true;
    // A+Y N3/N4: hand the live trade/family tables to OwnedState before the ECP
    // projections are packed, so the sync helpers below already read the new
    // home through trade_orders_store()/families_store().
    owned.live_trade_orders = std::move(_trade_orders_local);
    owned.live_families = std::move(_families_local);
    _trade_orders_local.clear();
    _families_local.clear();
    // A+Y N5: the family side tables follow live_families in the same bind, so
    // the sync helpers below and every later stage read the OwnedState home
    // through persons_store()/family_memberships()/... Derived CSR caches are
    // untouched: their contents stay valid because the rows only change home,
    // not value.
    owned.live_persons = std::move(_persons_local);
    owned.live_memberships = std::move(_family_memberships_local);
    owned.live_ownerships = std::move(_family_ownerships_local);
    owned.live_expeditions = std::move(_family_expeditions_local);
    owned.live_expedition_route_cells =
        std::move(_family_expedition_route_cells_local);
    owned.live_expedition_route_costs =
        std::move(_family_expedition_route_costs_local);
    owned.live_expedition_payloads =
        std::move(_family_expedition_payloads_local);
    owned.live_expedition_person_handles =
        std::move(_family_expedition_person_handles_local);
    owned.live_expedition_cargo = std::move(_family_expedition_cargo_local);
    owned.live_expedition_kit_buildings =
        std::move(_family_expedition_kit_buildings_local);
    owned.live_expedition_missing_good_ids =
        std::move(_family_expedition_missing_good_ids_local);
    owned.live_expedition_missing_good_quantities =
        std::move(_family_expedition_missing_good_quantities_local);
    owned.live_influences = std::move(_family_influences_local);
    owned.live_traits = std::move(_family_traits_local);
    owned.live_person_needs = std::move(_person_needs_local);
    _persons_local.clear();
    _family_memberships_local.clear();
    _family_ownerships_local.clear();
    _family_expeditions_local.clear();
    _family_expedition_route_cells_local.clear();
    _family_expedition_route_costs_local.clear();
    _family_expedition_payloads_local.clear();
    _family_expedition_person_handles_local.clear();
    _family_expedition_cargo_local.clear();
    _family_expedition_kit_buildings_local.clear();
    _family_expedition_missing_good_ids_local.clear();
    _family_expedition_missing_good_quantities_local.clear();
    _family_influences_local.clear();
    _family_traits_local.clear();
    _person_needs_local.clear();
    sync_owned_building_store(owned.buildings);
    sync_owned_trade_escrow_store(owned.trade_orders);
    sync_owned_family_store(owned.families);
    // Move live stock and the epoch harvest scratch into OwnedState; hot paths
    // read/write them via resource_*_lanes() while bind_resource_store is
    // active, so the NER locals stay empty.
    owned.resources.resource_count = static_cast<int32_t>(_resource_ids.size());
    owned.resources.cell_count = _cell_count.get();
    owned.resources.stock.move_from(_resource_snapshot);
    owned.resources.remaining = std::move(_resource_remaining);
    owned.resources.harvest_remaining = std::move(_resource_harvest_remaining);
    owned.resources.deltas = std::move(_resource_deltas);
    owned.resources.lane_generation = std::move(_resource_lane_generation);
    _resource_snapshot.clear();
    _resource_remaining.clear();
    _resource_harvest_remaining.clear();
    _resource_deltas.clear();
    _resource_lane_generation.clear();
    owned.resources.cell_generation.assign(
        static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    const int32_t gen_cells = std::min(
        _cell_count.get(), static_cast<int32_t>(_cell_resource_gen.size()));
    for (int32_t cell = 0; cell < gen_cells; ++cell)
        owned.resources.cell_generation.write_scalar(static_cast<size_t>(cell),
            _cell_resource_gen[static_cast<size_t>(cell)]);
    bind_resource_store(&owned.resources);
    // A bound OwnedState is a CAPTURE, and every ledger block must say so.
    //
    // `capture_ecp2_authority` reads the blocks out of `_formula_owned` verbatim when
    // this runtime is bound (`formula_owned_bound()` branch below). It fills `building`
    // through `fill_ledger_building_from_store`, which always sets `captured = true`,
    // but the other blocks were copied as-is. So as soon as a POD-owned world tried to
    // capture a backup -- which `restore_ecp2_authority` does before applying anything,
    // i.e. exactly the restore path -- the shape check saw
    // `building.captured != trade_escrow.captured` and rejected with
    // `building_trade_block_pairing`, surfacing one layer up as
    // `ecp2_atomic_backup_failed` and killing `start_runtime_worker`.
    //
    // The sync helpers immediately above have just repacked these four stores from the
    // live tables, so "captured" is true by construction at this point.
    owned.trade_escrow.captured = true;
    owned.family.captured = true;
    owned.resource.captured = true;
    owned.epoch_cursor.captured = true;
    return true;
}

void NativeEconomyRuntime::unbind_formula_owned_state() noexcept {
    if (_formula_owned == nullptr) return;
    std::fprintf(stderr,
        "[economy-owned-unbind] cell_count=%d owned_stock=%zu owned_markets=%d "
        "owned_goods=%d owned_cell_to_market=%zu local_stock=%zu\n",
        _cell_count.get(), _formula_owned->market.stock.size(),
        _formula_owned->market.market_count.get(),
        _formula_owned->market.good_count.get(),
        _formula_owned->market.cell_to_market.size(), _market_local.stock.size());
    std::fflush(stderr);
    // Copy sole OwnedState columns back into NER-local storage, then detach.
    _population_local = _formula_owned->population;
    _market_local = _formula_owned->market;
    _buildings_soa_local = _formula_owned->buildings;
    // A+Y N3/N4: the live trade/family tables move back; the ECP projections
    // (owned.trade_orders / owned.families) stay as the captured mirror.
    _trade_orders_local = std::move(_formula_owned->live_trade_orders);
    _families_local = std::move(_formula_owned->live_families);
    _formula_owned->live_trade_orders.clear();
    _formula_owned->live_families.clear();
    // A+Y N5: the family side tables move back with live_families.
    _persons_local = std::move(_formula_owned->live_persons);
    _family_memberships_local = std::move(_formula_owned->live_memberships);
    _family_ownerships_local = std::move(_formula_owned->live_ownerships);
    _family_expeditions_local = std::move(_formula_owned->live_expeditions);
    _family_expedition_route_cells_local =
        std::move(_formula_owned->live_expedition_route_cells);
    _family_expedition_route_costs_local =
        std::move(_formula_owned->live_expedition_route_costs);
    _family_expedition_payloads_local =
        std::move(_formula_owned->live_expedition_payloads);
    _family_expedition_person_handles_local =
        std::move(_formula_owned->live_expedition_person_handles);
    _family_expedition_cargo_local =
        std::move(_formula_owned->live_expedition_cargo);
    _family_expedition_kit_buildings_local =
        std::move(_formula_owned->live_expedition_kit_buildings);
    _family_expedition_missing_good_ids_local =
        std::move(_formula_owned->live_expedition_missing_good_ids);
    _family_expedition_missing_good_quantities_local =
        std::move(_formula_owned->live_expedition_missing_good_quantities);
    _family_influences_local = std::move(_formula_owned->live_influences);
    _family_traits_local = std::move(_formula_owned->live_traits);
    _person_needs_local = std::move(_formula_owned->live_person_needs);
    _formula_owned->live_persons.clear();
    _formula_owned->live_memberships.clear();
    _formula_owned->live_ownerships.clear();
    _formula_owned->live_expeditions.clear();
    _formula_owned->live_expedition_route_cells.clear();
    _formula_owned->live_expedition_route_costs.clear();
    _formula_owned->live_expedition_payloads.clear();
    _formula_owned->live_expedition_person_handles.clear();
    _formula_owned->live_expedition_cargo.clear();
    _formula_owned->live_expedition_kit_buildings.clear();
    _formula_owned->live_expedition_missing_good_ids.clear();
    _formula_owned->live_expedition_missing_good_quantities.clear();
    _formula_owned->live_influences.clear();
    _formula_owned->live_traits.clear();
    _formula_owned->live_person_needs.clear();
    _resource_snapshot.move_from(_formula_owned->resources.stock);
    _resource_remaining = std::move(_formula_owned->resources.remaining);
    _resource_harvest_remaining =
        std::move(_formula_owned->resources.harvest_remaining);
    _resource_deltas = std::move(_formula_owned->resources.deltas);
    _resource_lane_generation =
        std::move(_formula_owned->resources.lane_generation);
    _formula_owned->resources.remaining.clear();
    _formula_owned->resources.harvest_remaining.clear();
    _formula_owned->resources.deltas.clear();
    _formula_owned->resources.lane_generation.clear();
    bind_resource_store(nullptr);
    _formula_owned->formula_owner_bound = false;
    _formula_owned = nullptr;
}

std::unique_ptr<EconomyGraphStageOps>
NativeEconomyRuntime::make_graph_stage_ops(bool mutate) {
    return std::make_unique<NativeEconomyGraphStageOps>(this, mutate);
}

NativeEconomyRuntime::Command NativeEconomyRuntime::command_from_pod(
        const RuntimeEconomyPodCommand &pod) const {
    Command cmd;
    cmd.opcode = pod.opcode;
    cmd.target_handle = static_cast<uint64_t>(
        pod.target_cohort != 0 ? pod.target_cohort : pod.target_building);
    cmd.i32_0 = pod.target_cell;
    cmd.i32_1 = static_cast<int32_t>(pod.target_country);
    cmd.i64_0 = pod.payload0;
    cmd.i64_1 = pod.payload1;
    cmd.sequence = static_cast<int64_t>(pod.submit_order);
    cmd.submit_order = pod.submit_order;
    cmd.effective_day = _epoch_active ? _sample_day : _current_day.get();
    if (cmd.effective_day < 0) cmd.effective_day = 0;
    return cmd;
}

bool NativeEconomyRuntime::apply_pod_command(
        const RuntimeEconomyPodCommand &pod, std::string &error) {
    error.clear();
    if (pod.opcode == COMMAND_BUILD_CANAL && pod.payload0 == 0) {
        error = "economy_command_build_canal_token_missing";
        return false;
    }
    const Command cmd = command_from_pod(pod);
    return apply_command(cmd, error);
}

bool NativeEconomyRuntime::sync_owned_columns_to_production(
        const RuntimeEconomyOwnedState &owned, std::string &error) {
    error.clear();
    // Phase-5: when formulas already alias OwnedState, column copies are
    // identity; still apply peer-side bookkeeping fields below.
    const bool same_instance =
        _formula_owned != nullptr && _formula_owned == &owned;
    if (!same_instance) {
        if (owned.population.funds.size() != population_store().funds.size() ||
            owned.population.epoch_income.size() !=
                population_store().epoch_income.size() ||
            owned.population.epoch_expense.size() !=
                population_store().epoch_expense.size() ||
            owned.population.owner_employed.size() !=
                population_store().owner_employed.size() ||
            owned.population.employee_employed.size() !=
                population_store().employee_employed.size() ||
            owned.market.stock.size() != market_store().stock.size()) {
            error = "economy_pod_owned_core_shape_mismatch";
            return false;
        }
        population_store().funds = owned.population.funds;
        population_store().epoch_income = owned.population.epoch_income;
        population_store().epoch_expense = owned.population.epoch_expense;
        if (owned.population.population.size() ==
            population_store().population.size())
            population_store().population = owned.population.population;
        population_store().owner_employed = owned.population.owner_employed;
        population_store().employee_employed =
            owned.population.employee_employed;
        market_store().stock = owned.market.stock;
    } else if (owned.population.funds.size() != population_store().funds.size() ||
               owned.population.owner_employed.size() !=
                   population_store().owner_employed.size() ||
               owned.population.employee_employed.size() !=
                   population_store().employee_employed.size() ||
               owned.market.stock.size() != market_store().stock.size()) {
        error = "economy_pod_owned_core_shape_mismatch";
        return false;
    }
    _external_population_delta = owned.external_population_delta;
    _structural_commands.clear();
    _structural_commands.reserve(owned.structural_commands.size());
    for (const RuntimeEconomyOwnedStructuralCommand &cmd :
         owned.structural_commands) {
        StructuralCommand ner_cmd{};
        ner_cmd.opcode = cmd.opcode;
        ner_cmd.source_slot = cmd.source_slot;
        ner_cmd.cell = cmd.cell;
        ner_cmd.signature = cmd.signature;
        ner_cmd.population = cmd.population;
        ner_cmd.funds = cmd.funds;
        ner_cmd.sequence = cmd.sequence;
        _structural_commands.push_back(ner_cmd);
    }
    if (!owned.families.purchase_factor_q16.empty()) {
        ensure_family_policy_factors();
        const size_t n = std::min(owned.families.purchase_factor_q16.size(),
                                  _family_purchase_factor_q16.size());
        for (size_t i = 0; i < n; ++i)
            _family_purchase_factor_q16[i] =
                owned.families.purchase_factor_q16[i];
    }
    if (!owned.families.family_flags.empty() &&
        owned.families.family_flags.size() == families_store().flags.size())
        families_store().flags = owned.families.family_flags;
    if (owned.building.captured &&
        owned.buildings.group_units.size() == building_count()) {
        for (size_t i = 0; i < building_count(); ++i)
            buildings_store().group_units.write_scalar(i, owned.buildings.group_units[i]);
        _building_handle_index_clean = false;
    }
    return true;
}

void NativeEconomyRuntime::sync_production_core_columns_to_owned(
        RuntimeEconomyOwnedState &owned) const {
    const bool same_instance =
        _formula_owned != nullptr && _formula_owned == &owned;
    if (!same_instance) {
        if (owned.population.funds.size() == population_store().funds.size()) {
            owned.population.funds = population_store().funds;
            owned.population.epoch_income = population_store().epoch_income;
            owned.population.epoch_expense = population_store().epoch_expense;
        }
        if (owned.population.population.size() ==
            population_store().population.size())
            owned.population.population = population_store().population;
        if (owned.population.owner_employed.size() ==
                population_store().owner_employed.size())
            owned.population.owner_employed = population_store().owner_employed;
        if (owned.population.employee_employed.size() ==
                population_store().employee_employed.size())
            owned.population.employee_employed =
                population_store().employee_employed;
        if (owned.market.stock.size() == market_store().stock.size())
            owned.market.stock = market_store().stock;
    }
    owned.external_population_delta = _external_population_delta;
    owned.structural_commands.clear();
    owned.structural_commands.reserve(_structural_commands.size());
    for (const StructuralCommand &cmd : _structural_commands) {
        RuntimeEconomyOwnedStructuralCommand owned_cmd{};
        owned_cmd.opcode = cmd.opcode;
        owned_cmd.source_slot = cmd.source_slot;
        owned_cmd.cell = cmd.cell;
        owned_cmd.signature = cmd.signature;
        owned_cmd.population = cmd.population;
        owned_cmd.funds = cmd.funds;
        owned_cmd.sequence = cmd.sequence;
        owned.structural_commands.push_back(owned_cmd);
    }
}

void NativeEconomyRuntime::capture_owned_mirror_stores(
        RuntimeEconomyOwnedState &owned) const {
    RuntimeEconomyLedgerState ledger;
    capture_committed_ledger_state(ledger);
    if (!ledger.valid()) return;
    owned.building = ledger.building;
    owned.buildings = ledger.building.store;
    owned.trade_escrow = ledger.trade_escrow;
    owned.trade_orders = ledger.trade_escrow.store;
    owned.family = ledger.family;
    const std::vector<int32_t> purchase_factors =
        std::move(owned.families.purchase_factor_q16);
    owned.families = ledger.family.store;
    if (!purchase_factors.empty())
        owned.families.purchase_factor_q16 = purchase_factors;
}

bool NativeEconomyRuntime::pull_owned_core_columns(
        const RuntimeEconomyOwnedState &owned, int32_t opcode, int64_t settled,
        std::string &error) {
    RuntimeEconomyPodCommand command{};
    command.opcode = opcode;
    if (_formula_owned != nullptr && _formula_owned == &owned) {
        return pull_owned_command_result(*_formula_owned, command, settled,
                                         error);
    }
    RuntimeEconomyOwnedState mutable_owned = owned;
    return pull_owned_command_result(mutable_owned, command, settled, error);
}

bool NativeEconomyRuntime::enqueue_or_apply_pod_command(
        const RuntimeEconomyPodCommand &pod, std::string &error) {
    error.clear();
    if (_epoch_active) {
        _epoch_commands.push_back(command_from_pod(pod));
        return true;
    }
    return apply_pod_command(pod, error);
}

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

void NativeEconomyRuntime::fill_economy_business_summary(
        int64_t &summary_population, int64_t &summary_funds,
        int32_t &summary_markets, int32_t &summary_buildings,
        int32_t &summary_cohorts, int32_t &summary_families) const {
    summary_population = _closing_totals.population != 0
        ? _closing_totals.population
        : _opening_totals.population;
    summary_funds = (_closing_totals.cohort_funds != 0 ||
                     _closing_totals.country_cash != 0)
        ? (_closing_totals.cohort_funds + _closing_totals.country_cash +
           _closing_totals.escrow_cash)
        : (_opening_totals.cohort_funds + _opening_totals.country_cash +
           _opening_totals.escrow_cash);
    summary_markets = market_store().market_count.get();
    summary_buildings = static_cast<int32_t>(building_count());
    summary_cohorts = static_cast<int32_t>(std::min<int64_t>(
        std::max<int64_t>(0, population_store().active_count),
        static_cast<int64_t>(std::numeric_limits<int32_t>::max())));
    summary_families = static_cast<int32_t>(std::min<int64_t>(
        std::max<int64_t>(0, families_store().active_count),
        static_cast<int64_t>(std::numeric_limits<int32_t>::max())));
}

void NativeEconomyRuntime::sync_owned_building_store(
        RuntimeEconomyBuildingStore &out) const {
    // A+Y N2/N8: group and pending columns are already the sole live storage.
    // Only the packed role CSR still needs repacking, and only a foreign
    // destination gets a copy.
    const auto role_lane_started = Clock::now();
    refresh_building_store_role_lanes();
    EconomyCostProbe::record("domain_projection.role_lanes", _current_day.get(),
                             elapsed_ms(role_lane_started));
    const auto store_copy_started = Clock::now();
    const RuntimeEconomyBuildingStore &live = buildings_store();
    if (&out != &live) out = live;
    EconomyCostProbe::record("domain_projection.building_copy", _current_day.get(),
                             elapsed_ms(store_copy_started));
}

void NativeEconomyRuntime::sync_owned_trade_escrow_store(
        RuntimeEconomyTradeEscrowStore &out) const {
    out.clear();
    const size_t order_n = static_cast<size_t>(trade_orders_store().size());
    out.ids.reserve(order_n);
    out.line_goods.reserve(trade_orders_store().line_goods.size());
    out.seller_handles.reserve(trade_orders_store().seller_handles.size());
    for (int32_t order = 0; order < trade_orders_store().size(); ++order) {
        out.ids.push_back(trade_orders_store().ids[order]);
        out.sources.push_back(trade_orders_store().sources[order]);
        out.destinations.push_back(trade_orders_store().destinations[order]);
        out.countries.push_back(trade_orders_store().countries[order]);
        out.source_country_handles.push_back(
            trade_orders_store().source_country_handles[order]);
        out.destination_country_handles.push_back(
            trade_orders_store().destination_country_handles[order]);
        out.source_country_slots.push_back(
            trade_orders_store().source_country_slots[order]);
        out.destination_country_slots.push_back(
            trade_orders_store().destination_country_slots[order]);
        out.departure_days.push_back(trade_orders_store().departure_days[order]);
        out.arrival_days.push_back(trade_orders_store().arrival_days[order]);
        out.cash_escrow.push_back(trade_orders_store().cash_escrow[order]);
        out.capacity_work.push_back(trade_orders_store().capacity_work[order]);
        out.states.push_back(trade_orders_store().states[order]);
        out.cargo_delivered.push_back(trade_orders_store().cargo_delivered[order]);
        const int32_t line_count = trade_orders_store().line_offsets[order + 1] -
                                   trade_orders_store().line_offsets[order];
        const int32_t seller_count = trade_orders_store().seller_offsets[order + 1] -
                                     trade_orders_store().seller_offsets[order];
        out.line_count.push_back(line_count);
        out.line_begin.push_back(
            static_cast<int32_t>(out.line_goods.size()));
        out.seller_count.push_back(seller_count);
        out.seller_begin.push_back(
            static_cast<int32_t>(out.seller_handles.size()));
        for (int32_t line = trade_orders_store().line_offsets[order];
             line < trade_orders_store().line_offsets[order + 1]; ++line) {
            out.line_goods.push_back(trade_orders_store().line_goods[line]);
            out.line_quantities.push_back(trade_orders_store().line_quantities[line]);
            out.line_unit_prices.push_back(trade_orders_store().line_unit_prices[line]);
            out.line_destination_prices.push_back(
                trade_orders_store().line_destination_prices[line]);
            out.line_base_values.push_back(trade_orders_store().line_base_values[line]);
            out.line_retail_values.push_back(
                trade_orders_store().line_retail_values[line]);
            out.line_import_transfers.push_back(
                trade_orders_store().line_import_transfers[line]);
            out.line_export_transfers.push_back(
                trade_orders_store().line_export_transfers[line]);
            out.line_transaction_transfers.push_back(
                trade_orders_store().line_transaction_transfers[line]);
            out.line_flags.push_back(trade_orders_store().line_flags[line]);
        }
        for (int32_t seller = trade_orders_store().seller_offsets[order];
             seller < trade_orders_store().seller_offsets[order + 1]; ++seller) {
            out.seller_handles.push_back(trade_orders_store().seller_handles[seller]);
            out.seller_weights.push_back(trade_orders_store().seller_weights[seller]);
        }
    }
}

void NativeEconomyRuntime::sync_owned_resource_store(
        RuntimeEconomyResourceStore &out) const {
    EconomyCostProbe projection_cost("projection.resource_source", _current_day.get());
    static const bool scalar_projection = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_RESOURCE_PROJECTION_SCALAR);
        return value && std::strcmp(value, "1") == 0;
    }();
    out.resource_count = static_cast<int32_t>(_resource_ids.size());
    out.cell_count = _cell_count.get();
    const auto &source_stock = resource_stock_lanes();
    if (!scalar_projection && out.stock.size() == source_stock.size()) {
        if (&out.stock != &source_stock)
            out.stock.write_values(0, source_stock.values().data(), source_stock.size());
    } else out.stock = source_stock;
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
    if (!scalar_projection && out.cell_generation.size() == cells &&
            _cell_resource_gen.size() == cells) {
        out.cell_generation.write_values(0, _cell_resource_gen.values().data(), cells);
        return;
    }
    out.cell_generation.assign(static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    const int32_t gen_cells = std::min(
        _cell_count.get(), static_cast<int32_t>(_cell_resource_gen.size()));
    for (int32_t cell = 0; cell < gen_cells; ++cell)
        out.cell_generation.write_scalar(static_cast<size_t>(cell),
            _cell_resource_gen[static_cast<size_t>(cell)]);
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
    // Structural assign/reorder marks every page dirty even when bytes match.
    // The existing tracked range writer compares exact bytes and touches only
    // changed runs, so unchanged mirror pages retain their canonical digest.
    const auto project = [&](auto &target, const auto &source) {
        if (&target == &source) return;
        if (!scalar_projection && target.size() == source.size())
            target.write_values(0, source.values().data(), source.size());
        else target = source;
    };
    project(block.store.stock, store.stock);
    project(block.store.cell_generation, store.cell_generation);
    block.sync_counts_from_store();
    block.recompute_content_hash();
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

void NativeEconomyRuntime::flush_formula_owned_domain_mirrors() {
    EconomyCostProbe probe("domain_projection", _current_day.get());
    if (_formula_owned == nullptr) return;
    const auto domain_building_started = Clock::now();
    sync_owned_building_store(_formula_owned->buildings);
    // N10: the Owned committed blocks are the day-end export source, so every
    // domain block (not just trade/family/resource) has to be refreshed here.
    fill_ledger_building_from_store(_formula_owned->building,
                                    _formula_owned->buildings);
    EconomyCostProbe::record("domain_projection.building", _current_day.get(),
                             elapsed_ms(domain_building_started));
    const auto domain_trade_started = Clock::now();
    sync_owned_trade_escrow_store(_formula_owned->trade_orders);
    fill_ledger_trade_escrow_from_store(_formula_owned->trade_escrow,
                                        _formula_owned->trade_orders);
    EconomyCostProbe::record("domain_projection.trade", _current_day.get(),
                             elapsed_ms(domain_trade_started));
    const auto domain_family_started = Clock::now();
    sync_owned_family_store(_formula_owned->families);
    fill_ledger_family_from_store(_formula_owned->family,
                                  _formula_owned->families);
    EconomyCostProbe::record("domain_projection.family", _current_day.get(),
                             elapsed_ms(domain_family_started));
    const auto domain_resource_started = Clock::now();
    sync_owned_resource_store(_formula_owned->resources);
    fill_ledger_resource_from_store(_formula_owned->resource,
                                    _formula_owned->resources);
    EconomyCostProbe::record("domain_projection.resource", _current_day.get(),
                             elapsed_ms(domain_resource_started));
    const auto domain_cursor_started = Clock::now();
    fill_ledger_epoch_cursor(_formula_owned->epoch_cursor);
    _formula_owned->epoch_cursors = _formula_owned->epoch_cursor.store;
    EconomyCostProbe::record("domain_projection.cursor", _current_day.get(),
                             elapsed_ms(domain_cursor_started));
}

EconomyTrackedColumn<int64_t> &NativeEconomyRuntime::resource_stock_lanes() noexcept {
    if (_resource_store_alias != nullptr) return _resource_store_alias->stock;
    return _resource_snapshot;
}

const EconomyTrackedColumn<int64_t> &NativeEconomyRuntime::resource_stock_lanes()
        const noexcept {
    if (_resource_store_alias != nullptr) return _resource_store_alias->stock;
    return _resource_snapshot;
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

bool NativeEconomyRuntime::kernel_run_household_market_boundary(
        EconomyStageCursor &cursor, const RuntimeEconomyEpochInput &input,
        EconomyStageResult &result, std::string &error) {
    (void)cursor;
    result.reset();
    error.clear();
    if (!_bootstrapped || _fatal) {
        result.work_units = input.cell_count;
        result.state_hash = static_cast<uint64_t>(
            std::max<int64_t>(0, state_hash()));
        result.ok = true;
        return true;
    }
    // One household post-building finalize chunk when that phase is active;
    // otherwise ok boundary (full settle remains on compact slice).
    if (_household_market_phase == 1 && !_epoch_building_cells.empty()) {
        const int32_t begin = _household_post_cursor;
        const int32_t end = household_post_slice_end(begin);
        const int32_t count = end - begin;
        for (int32_t relative = 0; relative < count; ++relative) {
            int64_t sat = 0;
            int64_t restarted = 0;
            int64_t failed = 0;
            finalize_household_building_cell(
                _epoch_building_cells[static_cast<size_t>(begin + relative)],
                sat, restarted, failed);
            _saturation_count =
                saturating_add(_saturation_count, sat, _saturation_count);
            _recovery_restarted = saturating_add(_recovery_restarted,
                                                 restarted, _saturation_count);
            _recovery_failed = saturating_add(_recovery_failed, failed,
                                              _saturation_count);
        }
        _household_post_cursor = end;
        if (_household_post_cursor >=
            static_cast<int32_t>(_epoch_building_cells.size())) {
            _household_post_cursor = 0;
            _household_market_phase = 2;
        }
    }
    result.work_units = input.cell_count;
    result.state_hash = static_cast<uint64_t>(
        std::max<int64_t>(0, state_hash()));
    result.ok = true;
    return true;
}

} // namespace pk

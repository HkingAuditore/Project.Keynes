#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "native_simulation_host.h"
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

bool NativeEconomyRuntime::slot_has_merchant_profession(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[slot] == 0) return false;
    const uint32_t signature = population_store().signature_id[slot];
    return signature < _signatures.size() &&
           _signatures[signature].profession_id == _merchant_profession_id;
}

bool NativeEconomyRuntime::is_merchant_slot(int32_t slot) const {
    return slot_has_merchant_profession(slot) &&
           population_store().population[slot] > 0;
}

int64_t NativeEconomyRuntime::living_merchant_population(int32_t cell) const {
    int64_t total = 0;
    int64_t sat = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        if (is_merchant_slot(slot))
            total = saturating_add(total, population_store().population[slot], sat);
    });
    return total;
}

bool NativeEconomyRuntime::market_has_living_merchant(int32_t market) const {
    if (_merchant_offsets.size() == static_cast<size_t>(_cell_count.get() + 1) &&
        market >= 0 && market < _cell_count.get()) {
        for (int32_t k = _merchant_offsets[market];
             k < _merchant_offsets[market + 1]; ++k) {
            if (is_merchant_slot(_merchant_slots[k])) return true;
        }
    }
    if (_market_cell_offsets.size() != static_cast<size_t>(market_store().market_count.get() + 1) ||
        market < 0 || market >= market_store().market_count.get()) {
        return false;
    }
    bool found = false;
    for (int32_t k = _market_cell_offsets[market];
         k < _market_cell_offsets[market + 1] && !found; ++k) {
        population_store().for_each_in_cell(_market_cells[k], [&](int32_t slot) {
            if (!found && is_merchant_slot(slot)) found = true;
        });
    }
    return found;
}

void NativeEconomyRuntime::collect_living_merchant_slots(
        int32_t market, std::vector<int32_t> &out) const {
    out.clear();
    if (_market_cell_offsets.size() != static_cast<size_t>(market_store().market_count.get() + 1) ||
        market < 0 || market >= market_store().market_count.get()) {
        return;
    }
    for (int32_t k = _market_cell_offsets[market];
         k < _market_cell_offsets[market + 1]; ++k) {
        population_store().for_each_in_cell(_market_cells[k], [&](int32_t slot) {
            if (is_merchant_slot(slot)) out.push_back(slot);
        });
    }
    std::sort(out.begin(), out.end());
}

bool NativeEconomyRuntime::ensure_market_has_living_merchant(
        int32_t market, int64_t &repair_count, std::string &error) {
    if (market_has_living_merchant(market)) return true;
    if (_market_cell_offsets.size() != static_cast<size_t>(market_store().market_count.get() + 1) ||
        market < 0 || market >= market_store().market_count.get()) {
        return true;
    }
    for (int32_t k = _market_cell_offsets[market];
         k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        int64_t repairs = 0;
        if (!ensure_merchant_invariant(cell, repairs, error)) return false;
        repair_count = saturating_add(repair_count, repairs, _saturation_count);
        if (repairs > 0) _population_changed_cells.push_back(cell);
    }
    return true;
}

void NativeEconomyRuntime::rebuild_incremental_audit_shadow() {
    _audit_shadow_population.resize(population_store().active.size());
    _audit_shadow_funds.resize(population_store().active.size());
    for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
        const bool active = population_store().active[slot] != 0;
        _audit_shadow_population[slot] =
            active ? population_store().population[slot] : 0;
        _audit_shadow_funds[slot] =
            active ? population_store().funds[slot] : 0;
    }
    _audit_shadow_market_stock = market_store().stock;
    _audit_population_lane_stamp.assign(population_store().active.size(), 0);
    _audit_market_lane_stamp.assign(market_store().stock.size(), 0);
    _audit_population_touched_lanes.clear();
    _audit_market_touched_lanes.clear();
    _audit_mutation_generation = 0;
}

bool NativeEconomyRuntime::audit_shadow_reuse_enabled() {
    static const bool disabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_AUDIT_SHADOW_REUSE);
        return value && std::strcmp(value, "0") == 0;
    }();
    return !disabled;
}

void NativeEconomyRuntime::begin_incremental_audit_epoch() {
    // Retain preimages for worker sinks, which register lanes after their
    // writes. Idle writes join the same generation and are installed before
    // starting the next epoch. Full mode never trusts this.
    const bool retain = audit_shadow_reuse_enabled() &&
        _closing_audit_mode == 2 && !_closing_audit_runtime_disabled &&
        _audit_mutation_generation != 0 &&
        _audit_shadow_population.size() == population_store().active.size() &&
        _audit_shadow_market_stock.size() == market_store().stock.size();
    if (retain) {
        EconomyCostProbe probe("audit_shadow_touched", _current_day.get(),
            _audit_population_touched_lanes.size() + _audit_market_touched_lanes.size());
        commit_incremental_audit_shadow();
    } else {
        EconomyCostProbe probe("audit_shadow_rebuild", _current_day.get(),
            population_store().active.size() + market_store().stock.size());
        rebuild_incremental_audit_shadow();
    }
    if (_audit_population_lane_stamp.size() != population_store().active.size())
        _audit_population_lane_stamp.resize(population_store().active.size(), 0);
    if (_audit_market_lane_stamp.size() != market_store().stock.size())
        _audit_market_lane_stamp.resize(market_store().stock.size(), 0);
    ++_audit_mutation_generation;
    if (_audit_mutation_generation == 0) {
        std::fill(_audit_population_lane_stamp.begin(),
                  _audit_population_lane_stamp.end(), 0);
        std::fill(_audit_market_lane_stamp.begin(),
                  _audit_market_lane_stamp.end(), 0);
        _audit_mutation_generation = 1;
    }
    _audit_population_touched_lanes.clear();
    _audit_market_touched_lanes.clear();
}

void NativeEconomyRuntime::audit_touch_population_lane(int32_t slot) {
    if (_audit_mutation_generation == 0 || _closing_audit_mode == 0 ||
        _closing_audit_runtime_disabled || slot < 0 ||
        slot >= static_cast<int32_t>(population_store().active.size()))
        return;
    const size_t index = static_cast<size_t>(slot);
    if (_production_result_sink != nullptr) {
        _production_result_sink->audit_population_lanes.push_back(index);
        return;
    }
    if (_market_result_sink != nullptr) {
        _market_result_sink->audit_population_lanes.push_back(index);
        return;
    }
    if (_audit_population_lane_stamp.size() < population_store().active.size()) {
        _audit_population_lane_stamp.resize(population_store().active.size(), 0);
        _audit_shadow_population.resize(population_store().active.size(), 0);
        _audit_shadow_funds.resize(population_store().active.size(), 0);
    }
    if (_audit_population_lane_stamp[index] == _audit_mutation_generation)
        return;
    _audit_population_lane_stamp[index] = _audit_mutation_generation;
    _audit_population_touched_lanes.push_back(index);
}

void NativeEconomyRuntime::audit_touch_market_lane(size_t index) {
    if (_audit_mutation_generation == 0 || _closing_audit_mode == 0 ||
        _closing_audit_runtime_disabled || index >= market_store().stock.size())
        return;
    if (_production_result_sink != nullptr) {
        _production_result_sink->audit_market_lanes.push_back(index);
        return;
    }
    if (_market_result_sink != nullptr) {
        _market_result_sink->audit_market_lanes.push_back(index);
        return;
    }
    if (_audit_market_lane_stamp.size() < market_store().stock.size()) {
        _audit_market_lane_stamp.resize(market_store().stock.size(), 0);
        _audit_shadow_market_stock.resize(market_store().stock.size(), 0);
    }
    if (_audit_market_lane_stamp[index] == _audit_mutation_generation) return;
    _audit_market_lane_stamp[index] = _audit_mutation_generation;
    _audit_market_touched_lanes.push_back(index);
}

void NativeEconomyRuntime::sum_family_expedition_holdings(
        int64_t &population, int64_t &funds, int64_t &goods,
        int64_t &saturation) const {
    population = 0;
    funds = 0;
    goods = 0;
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++expedition) {
        if (family_expeditions_store().active[expedition] == 0) continue;
        population = saturating_add(population,
            family_expedition_payload_people(expedition), saturation);
        const uint32_t begin = family_expeditions_store().payload_begin[expedition];
        const uint32_t end = std::min<uint32_t>(
            static_cast<uint32_t>(family_expedition_payloads().size()),
            begin + family_expeditions_store().payload_count[expedition]);
        for (uint32_t payload = begin; payload < end; ++payload)
            funds = saturating_add(funds,
                family_expedition_payloads()[payload].funds, saturation);
        const uint32_t cargo_begin = family_expeditions_store().cargo_begin[expedition];
        const uint32_t cargo_end = std::min<uint32_t>(
            static_cast<uint32_t>(family_expedition_cargo().size()),
            cargo_begin + family_expeditions_store().cargo_count[expedition]);
        for (uint32_t cargo = cargo_begin; cargo < cargo_end; ++cargo)
            goods = saturating_add(goods,
                family_expedition_cargo()[cargo].quantity, saturation);
    }
}

int64_t NativeEconomyRuntime::family_expedition_payload_people(
        int32_t expedition) const {
    if (expedition < 0 ||
        expedition >= static_cast<int32_t>(family_expeditions_store().active.size()) ||
        family_expeditions_store().active[expedition] == 0)
        return 0;
    int64_t people = 0;
    const uint32_t begin = family_expeditions_store().payload_begin[expedition];
    const uint32_t end = std::min<uint32_t>(
        static_cast<uint32_t>(family_expedition_payloads().size()),
        begin + family_expeditions_store().payload_count[expedition]);
    for (uint32_t payload = begin; payload < end; ++payload)
        people += std::max<int64_t>(0,
            family_expedition_payloads()[payload].people);
    return people;
}

void NativeEconomyRuntime::note_family_expedition_audit_invalidation() {
    _opening_audit_force_full = true;
    _closing_audit_force_full = true;
}

NativeEconomyRuntime::AuditTotals
NativeEconomyRuntime::incremental_audit_totals() const {
    return audit_totals_from_shadow(_opening_totals);
}

void NativeEconomyRuntime::commit_incremental_audit_shadow() {
    for (const size_t slot : _audit_population_touched_lanes) {
        if (slot >= _audit_shadow_population.size() ||
            slot >= _audit_shadow_funds.size())
            continue;
        const bool active =
            slot < population_store().active.size() && population_store().active[slot] != 0;
        _audit_shadow_population[slot] =
            active ? population_store().population[slot] : 0;
        _audit_shadow_funds[slot] = active ? population_store().funds[slot] : 0;
    }
    for (const size_t index : _audit_market_touched_lanes) {
        if (index < _audit_shadow_market_stock.size() &&
            index < market_store().stock.size())
            _audit_shadow_market_stock[index] = market_store().stock[index];
    }
}

void NativeEconomyRuntime::diagnose_incremental_audit_mismatch(
        const AuditTotals &full) {
    _closing_audit_mismatch_ledger = "unknown";
    _closing_audit_mismatch_lane = -1;
    if (_incremental_closing_totals.population != full.population) {
        _closing_audit_mismatch_ledger = "population";
        for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
            const int64_t current = population_store().active[slot] != 0
                ? population_store().population[slot] : 0;
            if (slot < _audit_shadow_population.size() &&
                current != _audit_shadow_population[slot] &&
                (slot >= _audit_population_lane_stamp.size() ||
                 _audit_population_lane_stamp[slot] !=
                    _audit_mutation_generation)) {
                _closing_audit_mismatch_lane = static_cast<int64_t>(slot);
                return;
            }
        }
        return;
    }
    const int64_t incremental_money =
        _incremental_closing_totals.cohort_funds +
        _incremental_closing_totals.country_cash +
        _incremental_closing_totals.escrow_cash;
    const int64_t full_money =
        full.cohort_funds + full.country_cash + full.escrow_cash;
    if (incremental_money != full_money) {
        _closing_audit_mismatch_ledger = "money";
        for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
            const int64_t current = population_store().active[slot] != 0
                ? population_store().funds[slot] : 0;
            if (slot < _audit_shadow_funds.size() &&
                current != _audit_shadow_funds[slot] &&
                (slot >= _audit_population_lane_stamp.size() ||
                 _audit_population_lane_stamp[slot] !=
                    _audit_mutation_generation)) {
                _closing_audit_mismatch_lane = static_cast<int64_t>(slot);
                return;
            }
        }
        return;
    }
    if (_incremental_closing_totals.goods_stock != full.goods_stock) {
        _closing_audit_mismatch_ledger = "goods";
        capture_goods_audit_candidates();
        for (size_t index = 0; index < market_store().stock.size(); ++index) {
            if (index < _audit_shadow_market_stock.size() &&
                market_store().stock[index] != _audit_shadow_market_stock[index] &&
                (index >= _audit_market_lane_stamp.size() ||
                 _audit_market_lane_stamp[index] !=
                    _audit_mutation_generation)) {
                _closing_audit_mismatch_lane = static_cast<int64_t>(index);
                return;
            }
        }
    }
}

void NativeEconomyRuntime::capture_goods_audit_candidates() {
    _goods_audit_candidate_lanes.clear();
    if (_audit_shadow_market_stock.size() != market_store().stock.size() ||
        market_store().good_count.get() <= 0)
        return;

    std::vector<GoodsAuditLaneDiagnostic> candidates;
    candidates.reserve(16);
    for (size_t lane = 0; lane < market_store().stock.size(); ++lane) {
        const int64_t opening = _audit_shadow_market_stock[lane];
        const int64_t closing = market_store().stock[lane];
        if (opening == closing) continue;
        const int32_t market = static_cast<int32_t>(
            lane / static_cast<size_t>(market_store().good_count.get()));
        const int32_t good = static_cast<int32_t>(
            lane % static_cast<size_t>(market_store().good_count.get()));
        int32_t cell = -1;
        if (market >= 0 && market + 1 < static_cast<int32_t>(_market_cell_offsets.size()) &&
            _market_cell_offsets[market] < _market_cell_offsets[market + 1])
            cell = _market_cells[_market_cell_offsets[market]];
        candidates.push_back({market, cell, good, opening, closing,
                              closing - opening});
    }
    std::sort(candidates.begin(), candidates.end(), [](const auto &a, const auto &b) {
        const int64_t abs_a = a.net_change < 0 ? -a.net_change : a.net_change;
        const int64_t abs_b = b.net_change < 0 ? -b.net_change : b.net_change;
        if (abs_a != abs_b) return abs_a > abs_b;
        if (a.market != b.market) return a.market < b.market;
        return a.good < b.good;
    });
    const size_t count = std::min<size_t>(12, candidates.size());
    _goods_audit_candidate_lanes.assign(candidates.begin(), candidates.begin() + count);
}

void NativeEconomyRuntime::capture_money_audit_candidates() {
    _money_audit_candidate_accounts.clear();
    const size_t slot_count = population_store().active.size();
    if (_audit_shadow_funds.size() < slot_count) return;
    std::vector<MoneyAuditAccountDiagnostic> candidates;
    candidates.reserve(slot_count);
    for (size_t slot = 0; slot < slot_count; ++slot) {
        const int64_t opening = _audit_shadow_funds[slot];
        const int64_t closing = population_store().active[slot] != 0
            ? population_store().funds[slot] : 0;
        if (opening == closing) continue;
        const int32_t signature = slot < population_store().signature_id.size()
            ? static_cast<int32_t>(population_store().signature_id[slot]) : -1;
        const int32_t cell = slot / COHORT_PAGE_SIZE < population_store().page_cell.size()
            ? population_store().page_cell[slot / COHORT_PAGE_SIZE] : -1;
        const int32_t profession = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].profession_id : -1;
        const uint64_t handle = population_store().active[slot] != 0
            ? population_store().handle_for_slot(static_cast<int32_t>(slot)) : 0;
        candidates.push_back({static_cast<int32_t>(slot), cell, signature,
                              profession, handle, opening, closing,
                              closing - opening});
    }
    std::sort(candidates.begin(), candidates.end(), [](const auto &a, const auto &b) {
        const uint64_t abs_a = a.net_change < 0
            ? static_cast<uint64_t>(-(a.net_change + 1)) + 1
            : static_cast<uint64_t>(a.net_change);
        const uint64_t abs_b = b.net_change < 0
            ? static_cast<uint64_t>(-(b.net_change + 1)) + 1
            : static_cast<uint64_t>(b.net_change);
        if (abs_a != abs_b) return abs_a > abs_b;
        return a.slot < b.slot;
    });
    const size_t count = std::min<size_t>(16, candidates.size());
    _money_audit_candidate_accounts.assign(candidates.begin(), candidates.begin() + count);
}

void NativeEconomyRuntime::touch_accounting_slot(int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[slot] == 0) return;
    audit_touch_population_lane(slot);
    constexpr uint16_t ACCOUNTING_EPOCH_BIT = 0x8000u;
    const uint16_t expected = (_epoch_id.get() & 1LL) != 0 ? ACCOUNTING_EPOCH_BIT : 0u;
    if ((population_store().flags[slot] & ACCOUNTING_EPOCH_BIT) == expected) return;
    population_store().epoch_income.write_scalar(slot, 0, market_mutation_sink());
    population_store().epoch_expense.write_scalar(slot, 0, market_mutation_sink());
    population_store().epoch_in_kind_income.write_scalar(slot, 0, market_mutation_sink());
    population_store().epoch_tax_paid.write_scalar(slot, 0, market_mutation_sink());
    population_store().epoch_subsidy_received.write_scalar(slot, 0, market_mutation_sink());
    population_store().flags.write_scalar(slot, static_cast<uint16_t>(
        (population_store().flags[slot] & ~ACCOUNTING_EPOCH_BIT) | expected), market_mutation_sink());
}

bool NativeEconomyRuntime::ensure_merchant_invariant(int32_t cell, int64_t &repair_count,
                                                      std::string &error) {
    int32_t source = -1;
    int64_t source_population = -1;
    int32_t civilian_source = -1;
    int64_t civilian_population = -1;
    int64_t total_population = 0;
    bool has_living_merchant = false;
    int32_t zombie_merchant = -1;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        total_population = saturating_add(total_population, population_store().population[slot],
                                          _saturation_count);
        if (slot_has_merchant_profession(slot)) {
            if (population_store().population[slot] > 0) has_living_merchant = true;
            else if (zombie_merchant < 0 || slot < zombie_merchant)
                zombie_merchant = slot;
            return;
        }
        if (population_store().population[slot] > source_population ||
            (population_store().population[slot] == source_population && slot < source)) {
            source = slot;
            source_population = population_store().population[slot];
        }
        // State-service heads (the soldier) belong to another domain: Military
        // books a formation 1:1 against this cohort, so turning one of them into
        // a merchant here silently breaks that alignment (military 12 vs economy
        // 11 soldiers). Prefer a civilian source; see the solo-garrison rule
        // below for the case where the cell has none.
        if (!signature_is_state_service_only(
                static_cast<int32_t>(population_store().signature_id[slot])) &&
            (population_store().population[slot] > civilian_population ||
             (population_store().population[slot] == civilian_population &&
              slot < civilian_source))) {
            civilian_source = slot;
            civilian_population = population_store().population[slot];
        }
    });
    if (total_population <= 0 || has_living_merchant) return true;
    if (source < 0 || source_population <= 0) {
        error = "merchant_invariant_source_missing";
        return false;
    }
    if (civilian_source < 0 || civilian_population <= 0) {
        // The cell holds nothing but state-service people (a formation that
        // disbanded in the field). One of them still has to become the market
        // maker: with no living merchant the household revenue of this cell has
        // no owner and the next settlement is a
        // market_revenue_has_no_merchant_owner fatal, which is exactly what
        // happened when this repair was skipped. Keep `source` (the largest
        // state-service cohort) and let the repair convert one head; Military's
        // roster reconcile reads the soldier cohort back and trims its lots to
        // it, so the two books stay equal.
    } else {
        source = civilian_source;
        source_population = civilian_population;
    }
    const int32_t source_signature_id = static_cast<int32_t>(population_store().signature_id[source]);
    const Signature &source_signature = _signatures[source_signature_id];
    int32_t merchant_signature = -1;
    for (int32_t i = 0; i < static_cast<int32_t>(_signatures.size()); ++i) {
        if (_signatures[i].profession_id == _merchant_profession_id &&
            _signatures[i].ethnicity_id == source_signature.ethnicity_id) {
            merchant_signature = i;
            break;
        }
    }
    if (merchant_signature < 0) {
        error = "merchant_signature_missing_for_ethnicity";
        return false;
    }
    const int64_t source_handle = static_cast<int64_t>(population_store().handle_for_slot(source));
    if (source_population == 1) {
        _merchant_ranges_dirty = true;
        population_store().signature_id.write_scalar(source, static_cast<uint32_t>(merchant_signature), market_mutation_sink());
        if (_epoch_active) {
            std::vector<EventLeg> legs;
            if (trace_detail_for_cell(cell)) {
                legs.push_back({FIELD_COHORT_SIGNATURE, SUBJECT_COHORT, source_handle, -1,
                                source_signature_id, merchant_signature});
            }
            trace_append(EVENT_STRUCTURAL_CHANGE,
                         static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), cell,
                         SUBJECT_COHORT, source_handle, merchant_signature, 1,
                         1, 0, source_population, merchant_signature,
                         legs.empty() ? nullptr : &legs);
        }
        ++repair_count;
        return true;
    }
    const int64_t source_funds_before = population_store().funds[source];
    const int64_t funds_share = mul_div_sat(population_store().funds[source], 1,
                              source_population, _saturation_count);
    const int32_t destination = zombie_merchant >= 0
        ? zombie_merchant
        : population_store().allocate_slot(
            cell, static_cast<uint32_t>(merchant_signature));
    if (destination < 0) {
        error = "merchant_slot_allocation_failed";
        return false;
    }
    const bool family_split = !family_memberships().empty();
    if (family_split) plan_family_membership_move(source, cell, 1, 0, false);
    const int64_t destination_pop_before = population_store().population[destination];
    const int64_t destination_funds_before = population_store().funds[destination];
    touch_accounting_slot(source);
    touch_accounting_slot(destination);
    _merchant_ranges_dirty = true;
    population_store().population.write_scalar(source, population_store().population[source] - (1), market_mutation_sink());
    population_store().funds.write_scalar(source, population_store().funds[source] - (funds_share), market_mutation_sink());
    population_store().population.write_scalar(destination, saturating_add(
        population_store().population[destination], 1, _saturation_count), market_mutation_sink());
    population_store().funds.write_scalar(destination, saturating_add(
        population_store().funds[destination], funds_share, _saturation_count), market_mutation_sink());
    if (family_split) move_family_membership(source, destination, funds_share);
    if (_epoch_active) {
        std::vector<EventLeg> split_legs;
        if (trace_detail_for_cell(cell)) {
            const int64_t destination_handle = static_cast<int64_t>(
                population_store().handle_for_slot(destination));
            split_legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, source_handle, -1,
                            source_population, source_population - 1});
            split_legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                            source_funds_before, population_store().funds[source]});
            split_legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            destination_handle, -1, destination_pop_before,
                            population_store().population[destination]});
            split_legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                            destination_handle, -1, destination_funds_before,
                            population_store().funds[destination]});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), cell,
                     SUBJECT_COHORT, source_handle, merchant_signature, 1,
                     1, funds_share, source_population, merchant_signature,
                     split_legs.empty() ? nullptr : &split_legs);
    }
    ++repair_count;
    return true;
}

bool NativeEconomyRuntime::rebuild_merchant_ranges(std::string &error) {
    _merchant_primary_slot.assign(_cell_count.get(), -1);
    _merchant_offsets.assign(_cell_count.get() + 1, 0);
    _merchant_slots.clear();
    _merchant_nonempty_cells.clear();
    _merchant_nonempty_cells_valid = false;
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        auto collect_cell_merchants = [&]() {
            _merchant_slots.resize(static_cast<size_t>(_merchant_offsets[cell]));
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                if (is_merchant_slot(slot)) _merchant_slots.push_back(slot);
            });
        };
        collect_cell_merchants();
        if (static_cast<int32_t>(_merchant_slots.size()) == _merchant_offsets[cell]) {
            int64_t population = 0;
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                population = saturating_add(population, population_store().population[slot],
                                            _saturation_count);
            });
            if (population > 0) {
                int64_t repairs = 0;
                if (!ensure_merchant_invariant(cell, repairs, error)) return false;
                _merchant_repairs = saturating_add(
                    _merchant_repairs, repairs, _saturation_count);
                collect_cell_merchants();
                if (static_cast<int32_t>(_merchant_slots.size()) ==
                    _merchant_offsets[cell]) {
                    error = "merchant_invariant_broken:cell=" + std::to_string(cell);
                    return false;
                }
            }
        }
        _merchant_offsets[cell + 1] = static_cast<int32_t>(_merchant_slots.size());
        if (_merchant_offsets[cell + 1] > _merchant_offsets[cell]) {
            _merchant_primary_slot[cell] = _merchant_slots[_merchant_offsets[cell]];
            _merchant_nonempty_cells.push_back(cell);
        }
    }
    _merchant_nonempty_cells_valid = true;
    _merchant_ranges_dirty = false;
    return true;
}

bool NativeEconomyRuntime::refresh_merchant_ranges_if_dirty(std::string &error) {
    return !_merchant_ranges_dirty || rebuild_merchant_ranges(error);
}

bool NativeEconomyRuntime::repair_cell_merchant_and_rebuild(
        int32_t cell, std::string &error) {
    int64_t repairs = 0;
    if (!ensure_merchant_invariant(cell, repairs, error)) return false;
    _merchant_repairs = saturating_add(
        _merchant_repairs, repairs, _saturation_count);
    return rebuild_merchant_ranges(error);
}

} // namespace pk

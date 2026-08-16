#include "economy_runtime.h"
#include "effect_runtime.h"
#include "country_runtime.h"
#include "economy_runtime_variant_helpers.h"
#include "modifier_runtime.h"
#include "parallel_dispatcher.h"
#include "trigger_runtime.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <numeric>
#include <tuple>
#include <type_traits>
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
bool reconcile_trigger_branch_binding(TriggerRuntime *runtime,
                                      const std::string &key,
                                      uint64_t branch_handle,
                                      int32_t cell,
                                      int32_t reward_target,
                                      bool enabled) {
    if (runtime == nullptr || key.empty()) return false;
    Dictionary batch;
    PackedStringArray keys;
    PackedInt64Array branches;
    PackedInt32Array cells;
    PackedInt32Array rewards;
    PackedByteArray states;
    keys.push_back(key.c_str());
    branches.push_back(static_cast<int64_t>(branch_handle));
    cells.push_back(cell);
    rewards.push_back(reward_target);
    states.push_back(enabled ? 1 : 0);
    batch["trigger_keys"] = keys;
    batch["branch_handles"] = branches;
    batch["cells"] = cells;
    batch["reward_targets"] = rewards;
    batch["enabled"] = states;
    const Dictionary result = runtime->reconcile_branch_bindings(batch);
    return static_cast<bool>(result.get("ok", false));
}

int32_t modifier_factor_q16(double factor) {
    if (!std::isfinite(factor) || factor <= 0.0) return 0;
    const double scaled = std::round(factor *
        static_cast<double>(NativeEconomyRuntime::Q16_ONE));
    return static_cast<int32_t>(std::clamp(
        scaled, 0.0, static_cast<double>(std::numeric_limits<int32_t>::max())));
}
} // namespace

namespace {

using Clock = std::chrono::steady_clock;

constexpr int64_t price_adjustment_reference(
        int64_t current_price, int64_t adjustment_anchor_price,
        int64_t period_change_q16) {
    return period_change_q16 < 0
        ? std::max<int64_t>(NativeEconomyRuntime::PRICE_NUMERIC_GUARD_MIN,
                            current_price)
        : adjustment_anchor_price;
}

static_assert(price_adjustment_reference(100, 1000, -1) == 100);
static_assert(price_adjustment_reference(100, 1000, 1) == 1000);

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}


} // namespace

// ─── PopulationStore ───────────────────────────────────────────────────

// PopulationStore implementation moved to economy_runtime_storage.cpp.

// PopulationStore allocation and lookup implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore::allocate_slot implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore handle/release implementation moved to
// economy_runtime_storage.cpp.

int32_t popcount_u64(uint64_t value) {
    int32_t count = 0;
    while (value != 0) {
        value &= value - 1;
        ++count;
    }
    return count;
}


// FamilyStore implementation moved to economy_runtime_storage.cpp.

bool NativeEconomyRuntime::is_merchant_slot(int32_t slot) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0) return false;
    const uint32_t signature = _population.signature_id[slot];
    return signature < _signatures.size() &&
           _signatures[signature].profession_id == _merchant_profession_id;
}

void NativeEconomyRuntime::rebuild_incremental_audit_shadow() {
    _audit_shadow_population.resize(_population.active.size());
    _audit_shadow_funds.resize(_population.active.size());
    for (size_t slot = 0; slot < _population.active.size(); ++slot) {
        const bool active = _population.active[slot] != 0;
        _audit_shadow_population[slot] =
            active ? _population.population[slot] : 0;
        _audit_shadow_funds[slot] =
            active ? _population.funds[slot] : 0;
    }
    _audit_shadow_market_stock = _market.stock;
    _audit_population_lane_stamp.assign(_population.active.size(), 0);
    _audit_market_lane_stamp.assign(_market.stock.size(), 0);
    _audit_population_touched_lanes.clear();
    _audit_market_touched_lanes.clear();
    _audit_mutation_generation = 0;
}

void NativeEconomyRuntime::begin_incremental_audit_epoch() {
    if (_audit_shadow_population.size() != _population.active.size() ||
        _audit_shadow_funds.size() != _population.active.size() ||
        _audit_shadow_market_stock.size() != _market.stock.size()) {
        rebuild_incremental_audit_shadow();
    }
    if (_audit_population_lane_stamp.size() != _population.active.size())
        _audit_population_lane_stamp.resize(_population.active.size(), 0);
    if (_audit_market_lane_stamp.size() != _market.stock.size())
        _audit_market_lane_stamp.resize(_market.stock.size(), 0);
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
    if (!_epoch_active || _closing_audit_mode == 0 ||
        _closing_audit_runtime_disabled || slot < 0 ||
        slot >= static_cast<int32_t>(_population.active.size()))
        return;
    const size_t index = static_cast<size_t>(slot);
    if (_production_result_sink != nullptr || _market_result_sink != nullptr)
        return;
    if (_audit_population_lane_stamp.size() < _population.active.size()) {
        _audit_population_lane_stamp.resize(_population.active.size(), 0);
        _audit_shadow_population.resize(_population.active.size(), 0);
        _audit_shadow_funds.resize(_population.active.size(), 0);
    }
    if (_audit_population_lane_stamp[index] == _audit_mutation_generation)
        return;
    _audit_population_lane_stamp[index] = _audit_mutation_generation;
    _audit_population_touched_lanes.push_back(index);
}

void NativeEconomyRuntime::audit_touch_market_lane(size_t index) {
    if (!_epoch_active || _closing_audit_mode == 0 ||
        _closing_audit_runtime_disabled || index >= _market.stock.size())
        return;
    if (_production_result_sink != nullptr || _market_result_sink != nullptr)
        return;
    if (_audit_market_lane_stamp.size() < _market.stock.size()) {
        _audit_market_lane_stamp.resize(_market.stock.size(), 0);
        _audit_shadow_market_stock.resize(_market.stock.size(), 0);
    }
    if (_audit_market_lane_stamp[index] == _audit_mutation_generation) return;
    _audit_market_lane_stamp[index] = _audit_mutation_generation;
    _audit_market_touched_lanes.push_back(index);
}

NativeEconomyRuntime::AuditTotals
NativeEconomyRuntime::incremental_audit_totals() const {
    AuditTotals totals = _opening_totals;
    for (const size_t slot : _audit_population_touched_lanes) {
        if (slot >= _audit_shadow_population.size() ||
            slot >= _audit_shadow_funds.size())
            continue;
        const bool active =
            slot < _population.active.size() && _population.active[slot] != 0;
        const int64_t population =
            active ? _population.population[slot] : 0;
        const int64_t funds = active ? _population.funds[slot] : 0;
        totals.population += population - _audit_shadow_population[slot];
        totals.cohort_funds += funds - _audit_shadow_funds[slot];
    }
    for (const size_t index : _audit_market_touched_lanes) {
        if (index >= _audit_shadow_market_stock.size() ||
            index >= _market.stock.size())
            continue;
        totals.goods_stock +=
            _market.stock[index] - _audit_shadow_market_stock[index];
    }
    totals.country_cash =
        _country_runtime == nullptr ? 0 : _country_runtime->total_cash();
    totals.merchant_cash = 0;
    for (const int32_t slot : _merchant_slots) {
        if (slot >= 0 &&
            slot < static_cast<int32_t>(_population.active.size()) &&
            _population.active[slot] != 0) {
            totals.merchant_cash += std::max<int64_t>(
                0, _population.funds[slot]);
        }
    }
    const int64_t transit = trade_transit_goods();
    totals.goods_stock += transit - totals.transit_goods;
    totals.transit_goods = transit;
    int64_t expedition_population = 0;
    int64_t expedition_funds = 0;
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            _family_expeditions.active.size()); ++expedition) {
        if (_family_expeditions.active[expedition] == 0) continue;
        expedition_population += _family_expeditions.population[expedition];
        const uint32_t begin = _family_expeditions.payload_begin[expedition];
        const uint32_t end = std::min<uint32_t>(
            static_cast<uint32_t>(_family_expedition_payloads.size()),
            begin + _family_expeditions.payload_count[expedition]);
        for (uint32_t payload = begin; payload < end; ++payload)
            expedition_funds += _family_expedition_payloads[payload].funds;
    }
    totals.population += expedition_population - totals.transit_population;
    totals.transit_population = expedition_population;
    const int64_t escrow = trade_escrow_cash();
    int64_t ignored_saturation = 0;
    totals.escrow_cash = saturating_add(
        saturating_add(escrow, fiscal_escrow_total(), ignored_saturation),
        expedition_funds, ignored_saturation);
    int64_t country_goods = 0;
    if (_country_runtime != nullptr) {
        for (int32_t good = 0; good < _market.good_count; ++good)
            country_goods += _country_runtime->total_good(good);
    }
    totals.goods_stock += country_goods - totals.country_goods;
    totals.country_goods = country_goods;
    return totals;
}

void NativeEconomyRuntime::commit_incremental_audit_shadow() {
    for (const size_t slot : _audit_population_touched_lanes) {
        if (slot >= _audit_shadow_population.size() ||
            slot >= _audit_shadow_funds.size())
            continue;
        const bool active =
            slot < _population.active.size() && _population.active[slot] != 0;
        _audit_shadow_population[slot] =
            active ? _population.population[slot] : 0;
        _audit_shadow_funds[slot] = active ? _population.funds[slot] : 0;
    }
    for (const size_t index : _audit_market_touched_lanes) {
        if (index < _audit_shadow_market_stock.size() &&
            index < _market.stock.size())
            _audit_shadow_market_stock[index] = _market.stock[index];
    }
}

void NativeEconomyRuntime::diagnose_incremental_audit_mismatch(
        const AuditTotals &full) {
    _closing_audit_mismatch_ledger = "unknown";
    _closing_audit_mismatch_lane = -1;
    if (_incremental_closing_totals.population != full.population) {
        _closing_audit_mismatch_ledger = "population";
        for (size_t slot = 0; slot < _population.active.size(); ++slot) {
            const int64_t current = _population.active[slot] != 0
                ? _population.population[slot] : 0;
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
        for (size_t slot = 0; slot < _population.active.size(); ++slot) {
            const int64_t current = _population.active[slot] != 0
                ? _population.funds[slot] : 0;
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
        for (size_t index = 0; index < _market.stock.size(); ++index) {
            if (index < _audit_shadow_market_stock.size() &&
                _market.stock[index] != _audit_shadow_market_stock[index] &&
                (index >= _audit_market_lane_stamp.size() ||
                 _audit_market_lane_stamp[index] !=
                    _audit_mutation_generation)) {
                _closing_audit_mismatch_lane = static_cast<int64_t>(index);
                return;
            }
        }
    }
}

void NativeEconomyRuntime::touch_accounting_slot(int32_t slot) {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0) return;
    audit_touch_population_lane(slot);
    constexpr uint16_t ACCOUNTING_EPOCH_BIT = 0x8000u;
    const uint16_t expected = (_epoch_id & 1LL) != 0 ? ACCOUNTING_EPOCH_BIT : 0u;
    if ((_population.flags[slot] & ACCOUNTING_EPOCH_BIT) == expected) return;
    _population.epoch_income[slot] = 0;
    _population.epoch_expense[slot] = 0;
    _population.epoch_in_kind_income[slot] = 0;
    _population.epoch_tax_paid[slot] = 0;
    _population.epoch_subsidy_received[slot] = 0;
    _population.flags[slot] = static_cast<uint16_t>(
        (_population.flags[slot] & ~ACCOUNTING_EPOCH_BIT) | expected);
}

bool NativeEconomyRuntime::ensure_merchant_invariant(int32_t cell, int64_t &repair_count,
                                                      std::string &error) {
    int32_t source = -1;
    int64_t source_population = -1;
    int64_t total_population = 0;
    bool has_merchant = false;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        total_population = saturating_add(total_population, _population.population[slot],
                                          _saturation_count);
        if (is_merchant_slot(slot)) has_merchant = true;
        if (!is_merchant_slot(slot) &&
            (_population.population[slot] > source_population ||
             (_population.population[slot] == source_population && slot < source))) {
            source = slot;
            source_population = _population.population[slot];
        }
    });
    if (total_population <= 0 || has_merchant) return true;
    if (source < 0 || source_population <= 0) {
        error = "merchant_invariant_source_missing";
        return false;
    }
    const int32_t source_signature_id = static_cast<int32_t>(_population.signature_id[source]);
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
    const int64_t source_handle = static_cast<int64_t>(_population.handle_for_slot(source));
    const int64_t source_funds_before = _population.funds[source];
    int32_t destination = source;
    int64_t funds_share = 0;
    if (source_population == 1) {
        _population.signature_id[source] = static_cast<uint32_t>(merchant_signature);
    } else {
        funds_share = mul_div_sat(_population.funds[source], 1,
                                  source_population, _saturation_count);
        destination = _population.allocate_slot(
            cell, static_cast<uint32_t>(merchant_signature));
        if (destination < 0) {
            error = "merchant_slot_allocation_failed";
            return false;
        }
        audit_touch_population_lane(source);
        touch_accounting_slot(destination);
        _population.population[source] -= 1;
        _population.funds[source] -= funds_share;
        _population.population[destination] = saturating_add(
            _population.population[destination], 1, _saturation_count);
        _population.funds[destination] = saturating_add(
            _population.funds[destination], funds_share, _saturation_count);
    }
    if (_epoch_active) {
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cell)) {
            if (source_population == 1) {
                legs.push_back({FIELD_COHORT_SIGNATURE, SUBJECT_COHORT, source_handle, -1,
                                source_signature_id, merchant_signature});
            } else {
                const int64_t destination_handle = static_cast<int64_t>(
                    _population.handle_for_slot(destination));
                legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, source_handle, -1,
                                source_population, source_population - 1});
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                                source_funds_before, _population.funds[source]});
                legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                                destination_handle, -1, 0,
                                _population.population[destination]});
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                                destination_handle, -1, 0,
                                _population.funds[destination]});
            }
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), cell,
                     SUBJECT_COHORT, source_handle, merchant_signature, 1,
                     1, funds_share, source_population, merchant_signature,
                     legs.empty() ? nullptr : &legs);
    }
    ++repair_count;
    return true;
}

bool NativeEconomyRuntime::rebuild_merchant_ranges(std::string &error) {
    _merchant_primary_slot.assign(_cell_count, -1);
    _merchant_offsets.assign(_cell_count + 1, 0);
    _merchant_slots.clear();
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            if (is_merchant_slot(slot)) _merchant_slots.push_back(slot);
        });
        _merchant_offsets[cell + 1] = static_cast<int32_t>(_merchant_slots.size());
        if (_merchant_offsets[cell + 1] > _merchant_offsets[cell]) {
            _merchant_primary_slot[cell] = _merchant_slots[_merchant_offsets[cell]];
        } else {
            int64_t population = 0;
            _population.for_each_in_cell(cell, [&](int32_t slot) {
                population = saturating_add(population, _population.population[slot],
                                            _saturation_count);
            });
            if (population > 0) {
                error = "merchant_invariant_broken";
                return false;
            }
        }
    }
    return true;
}

void NativeEconomyRuntime::refresh_country_research_goods_consumed() {
    if (_country_runtime == nullptr) {
        _country_research_goods_consumed = 0;
        return;
    }
    const int64_t current = _country_runtime->research_consumed_total();
    _country_research_goods_consumed = current >= _country_research_consumed_opening
        ? current - _country_research_consumed_opening : 0;
}

bool NativeEconomyRuntime::run_government_research_procurement(std::string &error) {
    if (_country_runtime == nullptr || !_country_runtime->economy_available()) return true;
    const int32_t good = _country_runtime->technology_points_good_id();
    if (good < 0 || good >= _market.good_count) {
        error = "government_research_good_invalid";
        return false;
    }
    struct Candidate {
        int32_t country = -1;
        int32_t market = -1;
        int64_t price = 0;
    };
    thread_local std::vector<Candidate> candidates;
    candidates.clear();
    candidates.reserve(_epoch_market_ids.size());
    for (const int32_t market : _epoch_market_ids) {
        if (market < 0 || market >= _cell_count ||
            market >= static_cast<int32_t>(_epoch_cell_country.size()) ||
            _merchant_offsets[market] >= _merchant_offsets[market + 1]) continue;
        const int32_t country = _epoch_cell_country[market];
        if (country < 0 || country >= _epoch_country_count) continue;
        const int64_t index = _market.index(market, good);
        if (_market.stock[index] <= 0) continue;
        candidates.push_back({country, market, _market.price[index]});
    }
    std::stable_sort(candidates.begin(), candidates.end(),
        [](const Candidate &lhs, const Candidate &rhs) {
            if (lhs.country != rhs.country) return lhs.country < rhs.country;
            if (lhs.price != rhs.price) return lhs.price < rhs.price;
            return lhs.market < rhs.market;
        });
    std::vector<int64_t> budgets(static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    std::vector<int64_t> remaining(static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    std::vector<uint8_t> enabled(static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        bool policy_enabled = false;
        int64_t daily_budget = 0;
        int64_t demand = 0;
        if (!_country_runtime->research_procurement_policy(
                country, policy_enabled, daily_budget, demand) ||
            !policy_enabled || daily_budget <= 0 || demand <= 0) continue;
        enabled[static_cast<size_t>(country)] = 1;
        budgets[static_cast<size_t>(country)] = std::min(
            _country_runtime->cash_for_slot(country),
            saturating_mul(daily_budget, std::max(1, _epoch_days),
                           _saturation_count));
        remaining[static_cast<size_t>(country)] = demand;
    }
    for (const Candidate &candidate : candidates) {
        const size_t country = static_cast<size_t>(candidate.country);
        if (enabled[country] == 0 || budgets[country] <= 0 ||
            remaining[country] <= 0 || candidate.price <= 0) continue;
        const int64_t index = _market.index(candidate.market, good);
        const int64_t affordable = mul_div_sat(
            budgets[country], GOODS_SCALE, candidate.price, _saturation_count);
        const int64_t quantity = std::min({
            _market.stock[index], remaining[country], affordable});
        if (quantity <= 0) continue;
        const int64_t cash = mul_div_sat(
            quantity, candidate.price, GOODS_SCALE, _saturation_count);
        if (cash <= 0 || !_country_runtime->purchase_research_points(
                candidate.country, quantity, cash)) continue;

        audit_touch_market_lane(static_cast<size_t>(index));
        _market.stock[index] -= quantity;
        budgets[country] -= cash;
        remaining[country] -= quantity;
        int64_t merchant_population = 0;
        for (int32_t edge = _merchant_offsets[candidate.market];
             edge < _merchant_offsets[candidate.market + 1]; ++edge) {
            merchant_population = saturating_add(
                merchant_population,
                _population.population[_merchant_slots[edge]],
                _saturation_count);
        }
        if (merchant_population <= 0) {
            error = "government_research_purchase_has_no_merchant";
            return false;
        }
        int64_t population_prefix = 0;
        int64_t distributed = 0;
        for (int32_t edge = _merchant_offsets[candidate.market];
             edge < _merchant_offsets[candidate.market + 1]; ++edge) {
            const int32_t slot = _merchant_slots[edge];
            audit_touch_population_lane(slot);
            touch_accounting_slot(slot);
            population_prefix = saturating_add(
                population_prefix, _population.population[slot],
                _saturation_count);
            const int64_t next = mul_div_sat(
                cash, population_prefix, merchant_population,
                _saturation_count);
            const int64_t share = std::max<int64_t>(0, next - distributed);
            distributed = next;
            _population.funds[slot] = saturating_add(
                _population.funds[slot], share, _saturation_count);
            _population.epoch_income[slot] = saturating_add(
                _population.epoch_income[slot], share, _saturation_count);
        }
        const int32_t signal = market_signal_index(candidate.market, good);
        if (signal >= 0) {
            if (signal < static_cast<int32_t>(_epoch_nonhousehold_withdrawals.size()))
                _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                    _epoch_nonhousehold_withdrawals[signal], quantity,
                    _saturation_count);
            const int64_t daily = quantity / std::max(1, _epoch_days);
            const int64_t alpha = std::min<int64_t>(
                Q16_ONE, static_cast<int64_t>(std::clamp<int32_t>(
                    _good_demand_ema_alpha_q16[good], 0, Q16_ONE)) *
                    std::max(1, _epoch_days));
            const int64_t addition = mul_div_sat(
                daily, alpha, Q16_ONE, _saturation_count);
            _market_signals.business_demand_ema[signal] = saturating_add(
                _market_signals.business_demand_ema[signal], addition,
                _saturation_count);
            _market_signals.realized_withdrawal_ema[signal] = saturating_add(
                _market_signals.realized_withdrawal_ema[signal], addition,
                _saturation_count);
        }
        _government_research_procured_points = saturating_add(
            _government_research_procured_points, quantity, _saturation_count);
        _government_research_procurement_cash = saturating_add(
            _government_research_procurement_cash, cash, _saturation_count);
        ++_government_research_procurement_orders;
    }
    return true;
}

bool NativeEconomyRuntime::capture_environment(int64_t day_index, const float *temperature,
                                               const float *temperature_30d,
                                               const float *moisture,
                                               const float *plant_available_water,
                                               const float *snow_cover,
                                               const float *weather_intensity, int32_t count,
                                               std::string &error) {
    if (!_configured || count != _cell_count || temperature == nullptr ||
        temperature_30d == nullptr || moisture == nullptr || plant_available_water == nullptr ||
        snow_cover == nullptr || weather_intensity == nullptr) {
        error = "economy_environment_snapshot_invalid";
        return false;
    }
    auto quantize = [](float value) -> int32_t {
        if (!std::isfinite(value)) return 0;
        return static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(std::llround(std::clamp(value, 0.0f, 1.0f) * Q16_ONE)),
            0, Q16_ONE));
    };
    _environment_temperature_q16.resize(count);
    _environment_temperature_30d_q16.resize(count);
    _environment_moisture_q16.resize(count);
    _environment_plant_available_water_q16.resize(count);
    _environment_snow_q16.resize(count);
    _environment_weather_q16.resize(count);
    uint64_t hash = 1469598103934665603ULL;
    auto mix = [&](uint32_t value) {
        for (int32_t b = 0; b < 4; ++b) {
            hash ^= static_cast<uint8_t>((value >> (b * 8)) & 0xffU);
            hash *= 1099511628211ULL;
        }
    };
    for (int32_t i = 0; i < count; ++i) {
        _environment_temperature_q16[i] = quantize(temperature[i]);
        _environment_temperature_30d_q16[i] = quantize(temperature_30d[i]);
        _environment_moisture_q16[i] = quantize(moisture[i]);
        _environment_plant_available_water_q16[i] = quantize(plant_available_water[i]);
        _environment_snow_q16[i] = quantize(snow_cover[i]);
        _environment_weather_q16[i] = quantize(weather_intensity[i]);
        mix(static_cast<uint32_t>(_environment_temperature_q16[i]));
        mix(static_cast<uint32_t>(_environment_temperature_30d_q16[i]));
        mix(static_cast<uint32_t>(_environment_moisture_q16[i]));
        mix(static_cast<uint32_t>(_environment_plant_available_water_q16[i]));
        mix(static_cast<uint32_t>(_environment_snow_q16[i]));
        mix(static_cast<uint32_t>(_environment_weather_q16[i]));
    }
    _environment_day = day_index;
    _environment_hash = static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
    return true;
}

bool NativeEconomyRuntime::capture_building_context(
        int64_t day_index, const float *elevation, const uint8_t *terrain,
        const uint8_t *landform, const uint8_t *vegetation, const uint8_t *is_water,
        const uint8_t *has_river, const int32_t *neighbor_indices,
        const std::vector<const float *> &resources,
        const std::vector<const float *> &resource_changes,
        int32_t count, std::string &error) {
    if (!_configured || count != _cell_count ||
        resources.size() != _resource_ids.size()) {
        error = "building_context_snapshot_invalid";
        return false;
    }
    auto quantize_q16 = [](float value) -> int32_t {
        if (!std::isfinite(value)) return 0;
        const double scaled = static_cast<double>(value) * static_cast<double>(Q16_ONE);
        return static_cast<int32_t>(std::clamp<double>(
            std::llround(scaled), std::numeric_limits<int32_t>::min(),
            std::numeric_limits<int32_t>::max()));
    };
    _building_elevation_q16.resize(count);
    _building_terrain.resize(count);
    _building_landform.resize(count);
    _building_vegetation.resize(count);
    _building_is_water.resize(count);
    _building_has_river.resize(count);
    _building_neighbors.assign(static_cast<size_t>(count) * 6, -1);
    for (int32_t cell = 0; cell < count; ++cell) {
        _building_elevation_q16[cell] = elevation != nullptr ? quantize_q16(elevation[cell]) : 0;
        _building_terrain[cell] = terrain != nullptr ? terrain[cell] : 0;
        _building_landform[cell] = landform != nullptr ? landform[cell] : 0;
        _building_vegetation[cell] = vegetation != nullptr ? vegetation[cell] : 0;
        _building_is_water[cell] = is_water != nullptr ? is_water[cell] : 0;
        _building_has_river[cell] = has_river != nullptr ? has_river[cell] : 0;
        if (neighbor_indices != nullptr) {
            for (int32_t direction = 0; direction < 6; ++direction) {
                const int32_t neighbor = neighbor_indices[cell * 6 + direction];
                _building_neighbors[static_cast<size_t>(cell) * 6 + direction] =
                    neighbor >= 0 && neighbor < count && neighbor != cell ? neighbor : -1;
            }
        }
    }
    if (resource_changes.size() != resources.size()) {
        error = "building_resource_change_shape_invalid";
        return false;
    }
    _resource_snapshot.assign(static_cast<size_t>(count) * resources.size(), 0);
    for (size_t r = 0; r < resources.size(); ++r) {
        const float *src = resources[r];
        const float *change = resource_changes[r];
        if (src == nullptr) continue;
        for (int32_t cell = 0; cell < count; ++cell) {
            const double reserve = std::isfinite(src[cell])
                ? static_cast<double>(src[cell]) : 0.0;
            const double pending = change != nullptr && std::isfinite(change[cell])
                ? static_cast<double>(change[cell]) : 0.0;
            const double value = std::max(0.0, reserve + std::min(0.0, pending));
            _resource_snapshot[r * static_cast<size_t>(count) + cell] =
                static_cast<int64_t>(std::min<double>(
                    value * static_cast<double>(GOODS_SCALE),
                    static_cast<double>(std::numeric_limits<int64_t>::max())));
        }
    }
    _building_context_day = day_index;
    return true;
}

bool NativeEconomyRuntime::drain_building_resource_deltas(std::vector<int64_t> &out) {
    if (!_resource_deltas_ready) return false;
    for (const size_t index : _last_published_resource_touched_lanes) {
        if (index < _last_published_resource_deltas.size())
            _last_published_resource_deltas[index] = 0;
    }
    _last_published_resource_touched_lanes.clear();
    _last_published_resource_touched_lanes.reserve(
        _resource_touched_lanes.size());
    for (const size_t index : _resource_touched_lanes) {
        if (index >= _resource_deltas.size() ||
            index >= _last_published_resource_deltas.size() ||
            _resource_deltas[index] == 0) continue;
        _last_published_resource_deltas[index] = _resource_deltas[index];
        _last_published_resource_touched_lanes.push_back(index);
    }
    out = _last_published_resource_deltas;
    _resource_deltas_ready = false;
    return true;
}

int32_t NativeEconomyRuntime::sample_environment_curve(int32_t curve_id, int32_t cell) const {
    if (curve_id < 0) return Q16_ONE;
    if (curve_id >= static_cast<int32_t>(_environment_curves.size()) || cell < 0 ||
        cell >= _cell_count) return 0;
    return sample_environment_curve(curve_id, environment_sample_for_cell(cell));
}

int32_t NativeEconomyRuntime::sample_environment_curve(
        int32_t curve_id, const EnvironmentSample &sample) const {
    if (curve_id < 0) return Q16_ONE;
    if (curve_id >= static_cast<int32_t>(_environment_curves.size())) return 0;
    const EnvironmentCurve &curve = _environment_curves[curve_id];
    int32_t signal = 0;
    switch (curve.signal_id) {
        case 0: signal = sample.temperature_q16; break;
        case 1: signal = sample.moisture_q16; break;
        case 2: signal = sample.snow_q16; break;
        case 3: signal = sample.weather_q16; break;
        default: return 0;
    }
    const int64_t scaled = static_cast<int64_t>(std::clamp(signal, 0, static_cast<int32_t>(Q16_ONE))) *
                           (ENV_CURVE_SAMPLES - 1);
    const int32_t lo = std::min(ENV_CURVE_SAMPLES - 1,
                                static_cast<int32_t>(scaled / Q16_ONE));
    const int32_t hi = std::min(ENV_CURVE_SAMPLES - 1, lo + 1);
    const int64_t frac = scaled - static_cast<int64_t>(lo) * Q16_ONE;
    return static_cast<int32_t>(curve.values_q16[lo] +
        ((static_cast<int64_t>(curve.values_q16[hi] - curve.values_q16[lo]) * frac) >> 16));
}

NativeEconomyRuntime::EnvironmentSample NativeEconomyRuntime::environment_sample_for_cell(
        int32_t cell) const {
    EnvironmentSample sample;
    if (cell < 0 || cell >= _cell_count ||
        _environment_temperature_q16.size() != static_cast<size_t>(_cell_count) ||
        _environment_temperature_30d_q16.size() != static_cast<size_t>(_cell_count) ||
        _environment_moisture_q16.size() != static_cast<size_t>(_cell_count) ||
        _environment_plant_available_water_q16.size() != static_cast<size_t>(_cell_count) ||
        _environment_snow_q16.size() != static_cast<size_t>(_cell_count) ||
        _environment_weather_q16.size() != static_cast<size_t>(_cell_count)) {
        return sample;
    }
    sample.temperature_q16 = _environment_temperature_q16[cell];
    sample.temperature_30d_q16 = _environment_temperature_30d_q16[cell];
    sample.moisture_q16 = _environment_moisture_q16[cell];
    sample.plant_available_water_q16 = _environment_plant_available_water_q16[cell];
    sample.snow_q16 = _environment_snow_q16[cell];
    sample.weather_q16 = _environment_weather_q16[cell];
    sample.ready = _environment_day >= 0;
    return sample;
}

NativeEconomyRuntime::EnvironmentSample NativeEconomyRuntime::environment_sample_from_float(
        float temperature, float moisture, float snow_cover, float weather_intensity,
        bool ready) {
    auto quantize = [](float value, int32_t fallback) -> int32_t {
        if (!std::isfinite(value)) return fallback;
        return static_cast<int32_t>(std::clamp<int64_t>(
            static_cast<int64_t>(std::llround(std::clamp(value, 0.0f, 1.0f) * Q16_ONE)),
            0, Q16_ONE));
    };
    EnvironmentSample sample;
    sample.temperature_q16 = quantize(temperature, Q16_ONE / 2);
    sample.temperature_30d_q16 = sample.temperature_q16;
    sample.moisture_q16 = quantize(moisture, Q16_ONE / 2);
    sample.plant_available_water_q16 = sample.moisture_q16;
    sample.snow_q16 = quantize(snow_cover, 0);
    sample.weather_q16 = quantize(weather_intensity, 0);
    sample.ready = ready;
    return sample;
}

NativeEconomyRuntime::NativeEconomyRuntime() {
    register_builtin_formulas();
    _trade_orders.clear();
}

NativeEconomyRuntime::~NativeEconomyRuntime() = default;

bool NativeEconomyRuntime::cell_has_technology(int32_t cell, int32_t technology_id,
                                               bool frozen) const {
    if (cell < 0 || cell >= _cell_count || technology_id < 0 ||
        technology_id >= static_cast<int32_t>(_technology_ids.size()) ||
        _technology_words <= 0) return false;
    if (frozen && _epoch_active) {
        if (_epoch_cell_country.size() != static_cast<size_t>(_cell_count) ||
            _epoch_country_technology_words <= 0) return false;
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) return false;
        const size_t index = static_cast<size_t>(country) * _epoch_country_technology_words +
            technology_id / 64;
        return index < _epoch_country_technologies.size() &&
            (_epoch_country_technologies[index] & (uint64_t{1} << (technology_id % 64))) != 0;
    }
    const int32_t country = _country_runtime == nullptr
        ? NativeCountryRuntime::NEUTRAL_SLOT : _country_runtime->country_slot_for_cell(cell);
    return _country_runtime != nullptr && _country_runtime->has_technology(country, technology_id);
}

bool NativeEconomyRuntime::cell_has_requirements(
        int32_t cell, int32_t begin, int32_t end,
        const std::vector<int32_t> &requirements, bool frozen) const {
    if (begin < 0 || end < begin || end > static_cast<int32_t>(requirements.size())) return false;
    if (begin == end) return true;
    for (int32_t i = begin; i < end; ++i) {
        if (cell_has_technology(cell, requirements[i], frozen)) return true;
    }
    return false;
}

bool NativeEconomyRuntime::cell_has_all_requirements(
        int32_t cell, int32_t begin, int32_t end,
        const std::vector<int32_t> &requirements, bool frozen) const {
    if (begin < 0 || end < begin || end > static_cast<int32_t>(requirements.size())) return false;
    for (int32_t i = begin; i < end; ++i) {
        if (!cell_has_technology(cell, requirements[i], frozen)) return false;
    }
    return true;
}

bool NativeEconomyRuntime::good_production_available(
        int32_t cell, int32_t good_id, bool frozen) const {
    if (frozen && _epoch_active && cell >= 0 && cell < _cell_count &&
        good_id >= 0 && good_id < static_cast<int32_t>(_good_ids.size()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count)) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        const size_t index = static_cast<size_t>(std::max(0, country)) *
            _good_ids.size() + static_cast<size_t>(good_id);
        return country >= 0 && country < _epoch_country_count &&
            index < _epoch_country_good_available.size() &&
            _epoch_country_good_available[index] != 0;
    }
    return good_id >= 0 && good_id + 1 < static_cast<int32_t>(_good_technology_offsets.size()) &&
        cell_has_requirements(cell, _good_technology_offsets[good_id],
            _good_technology_offsets[good_id + 1], _good_required_technologies, frozen);
}

bool NativeEconomyRuntime::good_market_available(
        int32_t cell, int32_t good_id, bool frozen) const {
    if (frozen && _epoch_active && cell >= 0 && cell < _cell_count &&
        good_id >= 0 && good_id < static_cast<int32_t>(_good_ids.size()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count)) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) return false;
        const size_t index = static_cast<size_t>(country) * _good_ids.size() +
            static_cast<size_t>(good_id);
        return index < _epoch_country_market_available.size() &&
            _epoch_country_market_available[index] != 0;
    }
    if (good_production_available(cell, good_id, frozen)) return true;
    return good_id >= 0 && good_id < static_cast<int32_t>(_good_ids.size()) &&
        good_id < static_cast<int32_t>(_good_trade_enabled.size()) &&
        good_id < static_cast<int32_t>(_good_storage_modes.size()) &&
        _good_trade_enabled[good_id] != 0 && _good_storage_modes[good_id] == 0;
}

bool NativeEconomyRuntime::good_available(
        int32_t cell, int32_t good_id, bool frozen) const {
    return good_production_available(cell, good_id, frozen);
}

bool NativeEconomyRuntime::profession_available(int32_t cell, int32_t profession_id,
                                                bool frozen) const {
    if (frozen && _epoch_active && cell >= 0 && cell < _cell_count &&
        profession_id >= 0 &&
        profession_id < static_cast<int32_t>(_profession_ids.size()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count)) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        const size_t index = static_cast<size_t>(std::max(0, country)) *
            _profession_ids.size() + static_cast<size_t>(profession_id);
        return country >= 0 && country < _epoch_country_count &&
            index < _epoch_country_profession_available.size() &&
            _epoch_country_profession_available[index] != 0;
    }
    return profession_id >= 0 &&
        profession_id + 1 < static_cast<int32_t>(_profession_technology_offsets.size()) &&
        cell_has_requirements(cell, _profession_technology_offsets[profession_id],
            _profession_technology_offsets[profession_id + 1],
            _profession_required_technologies, frozen);
}

// Building availability/constructibility gates live in
// economy_runtime_building_production.cpp.

bool NativeEconomyRuntime::capture_country_epoch(std::string &error) {
    _technology_words = static_cast<int32_t>((_technology_ids.size() + 63) / 64);
    if (_country_runtime == nullptr || !_country_runtime->economy_available() ||
        _country_runtime->good_count() != static_cast<int32_t>(_good_ids.size()) ||
        _country_runtime->technology_count() != static_cast<int32_t>(_technology_ids.size())) {
        error = "country_runtime_required";
        return false;
    }
    NativeCountryRuntime::EconomySnapshot snapshot;
    if (!_country_runtime->copy_economy_snapshot(snapshot) ||
        snapshot.cell_country_slot.size() != static_cast<size_t>(_cell_count) ||
        snapshot.country_handles.size() != static_cast<size_t>(snapshot.country_count) ||
        snapshot.technology_words != _technology_words) {
        error = "country_snapshot_shape_invalid";
        return false;
    }
    _epoch_cell_country = std::move(snapshot.cell_country_slot);
    _epoch_country_handles = std::move(snapshot.country_handles);
    _epoch_country_technologies = std::move(snapshot.country_technologies);
    _epoch_country_count = snapshot.country_count;
    _epoch_country_technology_words = snapshot.technology_words;
    _epoch_country_generation = snapshot.generation;
    _epoch_country_hash = snapshot.state_hash;
    _epoch_tax_policy_version = snapshot.tax_policy_version;
    _epoch_income_tax_rates = std::move(snapshot.income_tax_rates);
    _epoch_consumption_tax_rates = std::move(snapshot.consumption_tax_rates);
    _epoch_business_tax_rates = std::move(snapshot.business_tax_rates);
    _epoch_import_tax_rates = std::move(snapshot.import_tax_rates);
    _epoch_export_tax_rates = std::move(snapshot.export_tax_rates);
    std::vector<uint32_t> snapshot_cell_tax_policy_ids =
        std::move(snapshot.cell_tax_policy_ids);
    std::vector<NativeCountryRuntime::CellTaxPolicy>
        snapshot_cell_tax_policies = std::move(snapshot.cell_tax_policies);
    const auto tax_shape_valid = [&](const std::vector<int8_t> &rates,
                                     size_t item_count) {
        return rates.size() == static_cast<size_t>(
            std::max(0, _epoch_country_count)) * item_count;
    };
    if (!tax_shape_valid(_epoch_income_tax_rates, _profession_ids.size()) ||
        !tax_shape_valid(_epoch_consumption_tax_rates, _good_ids.size()) ||
        !tax_shape_valid(_epoch_business_tax_rates, _building_types.size()) ||
        !tax_shape_valid(_epoch_import_tax_rates, _good_ids.size()) ||
        !tax_shape_valid(_epoch_export_tax_rates, _good_ids.size())) {
        error = "country_tax_snapshot_shape_invalid";
        return false;
    }
    if (snapshot_cell_tax_policy_ids.size() !=
            static_cast<size_t>(_cell_count) ||
        snapshot_cell_tax_policies.empty()) {
        error = "country_cell_tax_snapshot_shape_invalid";
        return false;
    }
    const auto requirements_available = [&](int32_t country, int32_t begin,
                                             int32_t end,
                                             const std::vector<int32_t> &requirements) {
        if (begin < 0 || end < begin ||
            end > static_cast<int32_t>(requirements.size())) return false;
        if (begin == end) return true;
        for (int32_t i = begin; i < end; ++i) {
            const int32_t technology_id = requirements[i];
            if (technology_id < 0 ||
                technology_id >= static_cast<int32_t>(_technology_ids.size()))
                return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            if (word_index < _epoch_country_technologies.size() &&
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) != 0) return true;
        }
        return false;
    };
    const auto all_requirements_available = [&](int32_t country, int32_t begin,
                                                 int32_t end,
                                                 const std::vector<int32_t> &requirements) {
        if (begin < 0 || end < begin ||
            end > static_cast<int32_t>(requirements.size())) return false;
        for (int32_t i = begin; i < end; ++i) {
            const int32_t technology_id = requirements[i];
            if (technology_id < 0 ||
                technology_id >= static_cast<int32_t>(_technology_ids.size())) return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            if (word_index >= _epoch_country_technologies.size() ||
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) == 0) return false;
        }
        return true;
    };
    const auto dependency_requirements_available = [&](int32_t country,
                                                        int32_t type_id) {
        if (type_id < 0 || type_id + 1 >= static_cast<int32_t>(
                _building_dependency_branch_offsets.size())) return false;
        const int32_t branch_begin = _building_dependency_branch_offsets[
            static_cast<size_t>(type_id)];
        const int32_t branch_end = _building_dependency_branch_offsets[
            static_cast<size_t>(type_id + 1)];
        auto has_technology = [&](int32_t technology_id) {
            if (technology_id < 0 || technology_id >= static_cast<int32_t>(
                    _technology_ids.size())) return false;
            const size_t word_index = static_cast<size_t>(country) *
                _epoch_country_technology_words + technology_id / 64;
            return word_index < _epoch_country_technologies.size() &&
                (_epoch_country_technologies[word_index] &
                 (uint64_t{1} << (technology_id % 64))) != 0;
        };
        for (int32_t branch = branch_begin; branch < branch_end; ++branch) {
            const int32_t tech_begin = _building_dependency_branch_technology_offsets[
                static_cast<size_t>(branch)];
            const int32_t tech_end = _building_dependency_branch_technology_offsets[
                static_cast<size_t>(branch + 1)];
            bool branch_ready = true;
            for (int32_t edge = tech_begin; edge < tech_end; ++edge) {
                if (!has_technology(_building_dependency_branch_technologies[
                        static_cast<size_t>(edge)])) {
                    branch_ready = false;
                    break;
                }
            }
            if (!branch_ready) continue;
            const int32_t group_begin = _building_dependency_branch_group_offsets[
                static_cast<size_t>(branch)];
            const int32_t group_end = _building_dependency_branch_group_offsets[
                static_cast<size_t>(branch + 1)];
            for (int32_t group = group_begin; group < group_end; ++group) {
                bool group_ready = false;
                for (int32_t tag = _building_dependency_tag_offsets[
                        static_cast<size_t>(group)];
                     tag < _building_dependency_tag_offsets[
                        static_cast<size_t>(group + 1)]; ++tag) {
                    if (has_technology(_building_dependency_tags[
                            static_cast<size_t>(tag)])) {
                        group_ready = true;
                        break;
                    }
                }
                if (!group_ready) {
                    branch_ready = false;
                    break;
                }
            }
            if (branch_ready) return true;
        }
        return false;
    };
    _epoch_country_good_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), 0);
    _epoch_country_market_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), 0);
    _epoch_country_profession_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _profession_ids.size(), 0);
    _epoch_country_variant_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _variants.size(), 0);
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t good = 0;
             good < static_cast<int32_t>(_good_ids.size()); ++good) {
            const bool available =
                good + 1 < static_cast<int32_t>(
                    _good_technology_offsets.size()) &&
                requirements_available(country,
                    _good_technology_offsets[good],
                    _good_technology_offsets[good + 1],
                    _good_required_technologies);
            _epoch_country_good_available[
                static_cast<size_t>(country) * _good_ids.size() + good] =
                    available ? 1 : 0;
            const bool market_available = available ||
                (good < static_cast<int32_t>(_good_trade_enabled.size()) &&
                 _good_trade_enabled[good] != 0 &&
                 good < static_cast<int32_t>(_good_storage_modes.size()) &&
                 _good_storage_modes[good] == 0);
            _epoch_country_market_available[
                static_cast<size_t>(country) * _good_ids.size() + good] =
                    market_available ? 1 : 0;
        }
        for (int32_t profession = 0;
             profession < static_cast<int32_t>(_profession_ids.size());
             ++profession) {
            const bool available =
                profession + 1 < static_cast<int32_t>(
                    _profession_technology_offsets.size()) &&
                requirements_available(country,
                    _profession_technology_offsets[profession],
                    _profession_technology_offsets[profession + 1],
                    _profession_required_technologies);
            _epoch_country_profession_available[
                static_cast<size_t>(country) * _profession_ids.size() +
                profession] = available ? 1 : 0;
        }
        for (int32_t variant = 0;
             variant < static_cast<int32_t>(_variants.size()); ++variant) {
            const VariantChoice &choice = _variants[variant];
            bool available = true;
            for (int32_t component = 0;
                 component < choice.component_count; ++component) {
                const int32_t good = _components[
                    choice.component_begin + component].good_id;
                const size_t good_index = static_cast<size_t>(country) *
                    _good_ids.size() + static_cast<size_t>(std::max(0, good));
                if (good < 0 ||
                    good >= static_cast<int32_t>(_good_ids.size()) ||
                    good_index >= _epoch_country_good_available.size() ||
                    _epoch_country_good_available[good_index] == 0) {
                    available = false;
                    break;
                }
            }
            _epoch_country_variant_available[
                static_cast<size_t>(country) * _variants.size() + variant] =
                    available ? 1 : 0;
        }
    }
    _epoch_country_building_available.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_types.size(), 0);
    _epoch_country_building_type_offsets.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) + 1, 0);
    _epoch_country_building_type_indices.clear();
    _epoch_country_building_type_indices.reserve(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_types.size());
    for (int32_t country = 0; country < _epoch_country_count; ++country) {
        for (int32_t type_id = 0;
             type_id < static_cast<int32_t>(_building_types.size()); ++type_id) {
            const bool available = type_id + 1 < static_cast<int32_t>(
                    _building_technology_offsets.size()) &&
                requirements_available(country,
                    _building_technology_offsets[type_id],
                    _building_technology_offsets[type_id + 1],
                    _building_required_technologies) &&
                type_id + 1 < static_cast<int32_t>(
                    _building_all_technology_offsets.size()) &&
                all_requirements_available(country,
                    _building_all_technology_offsets[type_id],
                    _building_all_technology_offsets[type_id + 1],
                    _building_all_required_technologies) &&
                dependency_requirements_available(country, type_id);
            const size_t cache_index = static_cast<size_t>(country) *
                _building_types.size() + static_cast<size_t>(type_id);
            _epoch_country_building_available[cache_index] = available ? 1 : 0;
            if (available)
                _epoch_country_building_type_indices.push_back(type_id);
        }
        _epoch_country_building_type_offsets[country + 1] =
            static_cast<int32_t>(_epoch_country_building_type_indices.size());
    }
    uint64_t topology_hash = 1469598103934665603ULL;
    for (const int32_t country : _epoch_cell_country) {
        const uint32_t value = static_cast<uint32_t>(country);
        for (int32_t byte = 0; byte < 4; ++byte) {
            topology_hash ^= static_cast<uint8_t>((value >> (byte * 8)) & 0xffU);
            topology_hash *= 1099511628211ULL;
        }
    }
    _epoch_country_topology_hash = (topology_hash & 0x7fffffffffffffffULL) | 1ULL;
    _epoch_country_merchant_population.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    if (_merchant_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            const int32_t country = _epoch_cell_country[cell];
            if (country < 0 || country >= _epoch_country_count) continue;
            for (int32_t k = _merchant_offsets[cell];
                 k < _merchant_offsets[cell + 1]; ++k) {
                const int32_t slot = _merchant_slots[k];
                if (slot < 0 || slot >= static_cast<int32_t>(_population.population.size()))
                    continue;
                _epoch_country_merchant_population[static_cast<size_t>(country)] =
                    saturating_add(_epoch_country_merchant_population[
                        static_cast<size_t>(country)],
                        std::max<int64_t>(0, _population.population[slot]),
                        _saturation_count);
            }
        }
    }
    _epoch_country_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_sector_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) * 5U, Q16_ONE);
    _epoch_country_research_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_family_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_upgrade_family_ids.size(), Q16_ONE);
    _epoch_country_good_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), Q16_ONE);
    _epoch_country_good_input_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), Q16_ONE);
    _epoch_country_good_consumption_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _good_ids.size(), Q16_ONE);
    _epoch_country_resource_use_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _resource_ids.size(), Q16_ONE);
    _epoch_country_resource_generation_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _resource_ids.size(), Q16_ONE);
    _epoch_country_terrain_sector_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _modifier_terrain_ids.size() * 5U, Q16_ONE);
    _epoch_country_landform_sector_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _modifier_landform_ids.size() * 5U, Q16_ONE);
    _epoch_country_building_output_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) *
            _building_type_ids.size(), Q16_ONE);
    _epoch_country_production_input_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_household_consumption_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_resource_global_use_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_climate_loss_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)) * 4U, Q16_ONE);
    _epoch_country_trade_capacity_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_trade_speed_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_construction_cost_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    _epoch_country_construction_time_factor_q16.assign(
        static_cast<size_t>(std::max(0, _epoch_country_count)), Q16_ONE);
    const auto city_factor_started = Clock::now();
    refresh_city_modifier_factors();
    _epoch_begin_city_factor_ms = elapsed_ms(city_factor_started);
    if (_modifier_runtime != nullptr) {
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const uint64_t country_handle =
                _epoch_country_handles[static_cast<size_t>(country)];
            const auto freeze_tax_group = [&](const std::vector<int32_t> &stat_ids,
                                              std::vector<int8_t> &rates,
                                              size_t item_count) {
                if (item_count == 0) return;
                const size_t begin = static_cast<size_t>(country) * item_count;
                _modifier_runtime->effective_values(
                    ModifierRuntime::COUNTRY, stat_ids.data(), country_handle,
                    rates.data() + begin, rates.data() + begin, item_count);
            };
            freeze_tax_group(_income_tax_stat_ids, _epoch_income_tax_rates,
                             _profession_ids.size());
            freeze_tax_group(_consumption_tax_stat_ids, _epoch_consumption_tax_rates,
                             _good_ids.size());
            freeze_tax_group(_business_tax_stat_ids, _epoch_business_tax_rates,
                             _building_types.size());
            freeze_tax_group(_import_tax_stat_ids, _epoch_import_tax_rates,
                             _good_ids.size());
            freeze_tax_group(_export_tax_stat_ids, _epoch_export_tax_rates,
                             _good_ids.size());
            _epoch_country_output_factor_q16[static_cast<size_t>(country)] =
                modifier_factor_q16(_modifier_runtime->country_economy_output_factor(
                    country_handle));
            for (int32_t sector = 0; sector < 5; ++sector)
                _epoch_country_sector_output_factor_q16[
                    static_cast<size_t>(country) * 5U + sector] =
                    modifier_factor_q16(
                        _modifier_runtime->country_sector_output_factor(
                            _epoch_country_handles[static_cast<size_t>(country)],
                            sector));
            _epoch_country_research_output_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_research_institution_output_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
            for (size_t family = 0;
                 family < _country_family_output_stat_ids.size(); ++family) {
                _epoch_country_family_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_family_output_stat_ids.size() + family] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_family_output_stat_ids[family], country_handle,
                        0, 1.0));
            }
            for (size_t good = 0;
                 good < _country_good_output_stat_ids.size(); ++good) {
                _epoch_country_good_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_good_output_stat_ids.size() + good] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_good_output_stat_ids[good], country_handle,
                        0, 1.0));
                _epoch_country_good_input_factor_q16[
                    static_cast<size_t>(country) * _good_ids.size() + good] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_good_input_stat_ids[good], country_handle,
                        0, 1.0));
                _epoch_country_good_consumption_factor_q16[
                    static_cast<size_t>(country) * _good_ids.size() + good] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_good_consumption_stat_ids[good], country_handle,
                        0, 1.0));
            }
            for (size_t resource = 0; resource < _resource_ids.size(); ++resource) {
                const size_t index = static_cast<size_t>(country) *
                    _resource_ids.size() + resource;
                _epoch_country_resource_use_factor_q16[index] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_resource_use_stat_ids[resource], country_handle,
                        0, 1.0));
                _epoch_country_resource_generation_factor_q16[index] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_resource_generation_stat_ids[resource],
                        country_handle, 0, 1.0));
            }
            const auto freeze_geography = [&](const std::vector<int32_t> &stat_ids,
                    size_t geography_count, std::vector<int32_t> &target) {
                const size_t row_width = geography_count * 5U;
                for (size_t index = 0; index < row_width; ++index)
                    target[static_cast<size_t>(country) * row_width + index] =
                        modifier_factor_q16(_modifier_runtime->effective_value(
                            ModifierRuntime::COUNTRY, stat_ids[index],
                            country_handle, 0, 1.0));
            };
            freeze_geography(_country_terrain_sector_output_stat_ids,
                _modifier_terrain_ids.size(),
                _epoch_country_terrain_sector_output_factor_q16);
            freeze_geography(_country_landform_sector_output_stat_ids,
                _modifier_landform_ids.size(),
                _epoch_country_landform_sector_output_factor_q16);
            _epoch_country_production_input_factor_q16[country] =
                modifier_factor_q16(_modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY, _country_production_input_stat_id,
                    country_handle, 0, 1.0));
            _epoch_country_household_consumption_factor_q16[country] =
                modifier_factor_q16(_modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY,
                    _country_household_consumption_stat_id,
                    country_handle, 0, 1.0));
            _epoch_country_resource_global_use_factor_q16[country] =
                modifier_factor_q16(_modifier_runtime->effective_value(
                    ModifierRuntime::COUNTRY, _country_resource_use_stat_id,
                    country_handle, 0, 1.0));
            for (size_t building = 0;
                 building < _country_building_output_stat_ids.size(); ++building) {
                _epoch_country_building_output_factor_q16[
                    static_cast<size_t>(country) *
                        _country_building_output_stat_ids.size() + building] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_building_output_stat_ids[building], country_handle,
                        0, 1.0));
            }
            for (size_t climate = 0;
                 climate < _country_climate_loss_stat_ids.size(); ++climate) {
                _epoch_country_climate_loss_factor_q16[
                    static_cast<size_t>(country) * 4U + climate] =
                    modifier_factor_q16(_modifier_runtime->effective_value(
                        ModifierRuntime::COUNTRY,
                        _country_climate_loss_stat_ids[climate], country_handle,
                        0, 1.0));
            }
            _epoch_country_trade_capacity_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_trade_capacity_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
            _epoch_country_trade_speed_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_trade_speed_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
            _epoch_country_construction_cost_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_construction_cost_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
            _epoch_country_construction_time_factor_q16[country] =
                modifier_factor_q16(
                    _modifier_runtime->country_construction_time_factor(
                        _epoch_country_handles[static_cast<size_t>(country)]));
        }
    }
    const auto cell_tax_compile_started = Clock::now();
    _epoch_cell_compiled_tax_policy.assign(
        static_cast<size_t>(_cell_count), 0);
    _epoch_cell_active_tax_mask.assign(static_cast<size_t>(_cell_count), 0);
    _epoch_compiled_cell_tax_policies.assign(1, CompiledCellTaxPolicy{});
    _epoch_compiled_cell_tax_overrides.clear();
    _epoch_compiled_cell_tax_default_rows.clear();
    _epoch_compiled_cell_tax_default_rates.clear();
    _epoch_has_cell_tax_policies = false;
    std::unordered_map<uint64_t, uint32_t> compiled_policy_ids;
    std::unordered_map<uint64_t, int32_t> default_row_ids;
    const auto item_count_for_kind = [&](int32_t kind) -> size_t {
        switch (kind) {
            case NativeCountryRuntime::TAX_INCOME:
                return _profession_ids.size();
            case NativeCountryRuntime::TAX_BUSINESS:
                return _building_types.size();
            case NativeCountryRuntime::TAX_CONSUMPTION:
            case NativeCountryRuntime::TAX_IMPORT:
            case NativeCountryRuntime::TAX_EXPORT:
                return _good_ids.size();
            default: return 0;
        }
    };
    const auto &stat_ids_for_kind = [&](int32_t kind)
            -> const std::vector<int32_t> & {
        switch (kind) {
            case NativeCountryRuntime::TAX_INCOME:
                return _income_tax_stat_ids;
            case NativeCountryRuntime::TAX_CONSUMPTION:
                return _consumption_tax_stat_ids;
            case NativeCountryRuntime::TAX_BUSINESS:
                return _business_tax_stat_ids;
            case NativeCountryRuntime::TAX_IMPORT:
                return _import_tax_stat_ids;
            case NativeCountryRuntime::TAX_EXPORT:
                return _export_tax_stat_ids;
            default: {
                static const std::vector<int32_t> empty;
                return empty;
            }
        }
    };
    const auto ensure_default_row = [&](int32_t country, int32_t kind,
                                        int8_t base_rate) -> int32_t {
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 32U) |
            (static_cast<uint64_t>(static_cast<uint8_t>(kind)) << 16U) |
            static_cast<uint16_t>(static_cast<int32_t>(base_rate) + 100);
        const auto found = default_row_ids.find(key);
        if (found != default_row_ids.end()) return found->second;
        const size_t item_count = item_count_for_kind(kind);
        CompiledCellTaxDefaultRow row;
        row.kind = kind;
        row.country = country;
        row.base_rate = base_rate;
        row.offset = static_cast<int32_t>(
            _epoch_compiled_cell_tax_default_rates.size());
        row.count = static_cast<int32_t>(item_count);
        _epoch_compiled_cell_tax_default_rates.resize(
            _epoch_compiled_cell_tax_default_rates.size() + item_count,
            base_rate);
        if (_modifier_runtime != nullptr && item_count > 0) {
            const auto &stat_ids = stat_ids_for_kind(kind);
            _modifier_runtime->effective_values(
                ModifierRuntime::COUNTRY, stat_ids.data(),
                _epoch_country_handles[static_cast<size_t>(country)],
                _epoch_compiled_cell_tax_default_rates.data() + row.offset,
                _epoch_compiled_cell_tax_default_rates.data() + row.offset,
                item_count);
        }
        const int32_t row_id = static_cast<int32_t>(
            _epoch_compiled_cell_tax_default_rows.size());
        _epoch_compiled_cell_tax_default_rows.push_back(row);
        default_row_ids.emplace(key, row_id);
        return row_id;
    };
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const uint32_t authority_id =
            snapshot_cell_tax_policy_ids[static_cast<size_t>(cell)];
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (authority_id == 0 ||
            authority_id >= snapshot_cell_tax_policies.size() ||
            country < 0 || country >= _epoch_country_count)
            continue;
        _epoch_has_cell_tax_policies = true;
        const uint64_t key =
            (static_cast<uint64_t>(static_cast<uint32_t>(country)) << 32U) |
            authority_id;
        auto compiled_found = compiled_policy_ids.find(key);
        if (compiled_found == compiled_policy_ids.end()) {
            const auto &authority = snapshot_cell_tax_policies[authority_id];
            CompiledCellTaxPolicy compiled;
            for (int32_t kind = 0;
                 kind < NativeCountryRuntime::TAX_KIND_COUNT; ++kind) {
                compiled.override_begin[static_cast<size_t>(kind)] =
                    static_cast<int32_t>(
                        _epoch_compiled_cell_tax_overrides.size());
                for (const auto &entry : authority.overrides) {
                    if (entry.kind != kind) continue;
                    int8_t effective = entry.rate;
                    if (_modifier_runtime != nullptr) {
                        const auto &stat_ids = stat_ids_for_kind(kind);
                        _modifier_runtime->effective_values(
                            ModifierRuntime::COUNTRY,
                            stat_ids.data() + entry.item,
                            _epoch_country_handles[static_cast<size_t>(country)],
                            &effective, &effective, 1);
                    }
                    _epoch_compiled_cell_tax_overrides.push_back(
                        {entry.item, effective});
                    if (effective != 0)
                        compiled.active_mask |= static_cast<uint8_t>(1U << kind);
                }
                compiled.override_end[static_cast<size_t>(kind)] =
                    static_cast<int32_t>(
                        _epoch_compiled_cell_tax_overrides.size());
                const int8_t local_default =
                    authority.defaults[static_cast<size_t>(kind)];
                if (local_default != NativeCountryRuntime::TAX_RATE_INHERIT) {
                    const int32_t row_id = ensure_default_row(
                        country, kind, local_default);
                    compiled.default_row_ids[static_cast<size_t>(kind)] = row_id;
                    const CompiledCellTaxDefaultRow &row =
                        _epoch_compiled_cell_tax_default_rows[
                            static_cast<size_t>(row_id)];
                    if (std::any_of(
                            _epoch_compiled_cell_tax_default_rates.begin() +
                                row.offset,
                            _epoch_compiled_cell_tax_default_rates.begin() +
                                row.offset + row.count,
                            [](int8_t rate) { return rate != 0; })) {
                        compiled.active_mask |=
                            static_cast<uint8_t>(1U << kind);
                    }
                }
            }
            compiled.active_mask = 0;
            const auto national_rates_for_kind = [&](int32_t kind)
                    -> const std::vector<int8_t> & {
                switch (kind) {
                    case NativeCountryRuntime::TAX_INCOME:
                        return _epoch_income_tax_rates;
                    case NativeCountryRuntime::TAX_CONSUMPTION:
                        return _epoch_consumption_tax_rates;
                    case NativeCountryRuntime::TAX_BUSINESS:
                        return _epoch_business_tax_rates;
                    case NativeCountryRuntime::TAX_IMPORT:
                        return _epoch_import_tax_rates;
                    default: return _epoch_export_tax_rates;
                }
            };
            for (int32_t kind = 0;
                 kind < NativeCountryRuntime::TAX_KIND_COUNT; ++kind) {
                const size_t item_count = item_count_for_kind(kind);
                const auto &national = national_rates_for_kind(kind);
                int32_t override_cursor =
                    compiled.override_begin[static_cast<size_t>(kind)];
                const int32_t override_end =
                    compiled.override_end[static_cast<size_t>(kind)];
                const int32_t row_id =
                    compiled.default_row_ids[static_cast<size_t>(kind)];
                for (int32_t item = 0;
                     item < static_cast<int32_t>(item_count); ++item) {
                    int8_t rate = 0;
                    while (override_cursor < override_end &&
                           _epoch_compiled_cell_tax_overrides[
                               static_cast<size_t>(override_cursor)].item < item)
                        ++override_cursor;
                    if (override_cursor < override_end &&
                        _epoch_compiled_cell_tax_overrides[
                            static_cast<size_t>(override_cursor)].item == item) {
                        rate = _epoch_compiled_cell_tax_overrides[
                            static_cast<size_t>(override_cursor)].rate;
                    } else if (row_id >= 0) {
                        const CompiledCellTaxDefaultRow &row =
                            _epoch_compiled_cell_tax_default_rows[
                                static_cast<size_t>(row_id)];
                        rate = _epoch_compiled_cell_tax_default_rates[
                            static_cast<size_t>(row.offset + item)];
                    } else {
                        rate = national[
                            static_cast<size_t>(country) * item_count +
                            static_cast<size_t>(item)];
                    }
                    if (rate != 0) {
                        compiled.active_mask |=
                            static_cast<uint8_t>(1U << kind);
                        break;
                    }
                }
            }
            const uint32_t compiled_id = static_cast<uint32_t>(
                _epoch_compiled_cell_tax_policies.size());
            _epoch_compiled_cell_tax_policies.push_back(compiled);
            compiled_policy_ids.emplace(key, compiled_id);
            compiled_found = compiled_policy_ids.find(key);
        }
        _epoch_cell_compiled_tax_policy[static_cast<size_t>(cell)] =
            compiled_found->second;
    }
    std::vector<uint8_t> country_tax_masks(
        static_cast<size_t>(std::max(0, _epoch_country_count)), 0);
    const auto mark_country_tax = [&](int32_t kind,
                                      const std::vector<int8_t> &rates,
                                      size_t item_count) {
        for (int32_t country = 0; country < _epoch_country_count; ++country) {
            const auto begin = rates.begin() +
                static_cast<ptrdiff_t>(static_cast<size_t>(country) * item_count);
            if (std::any_of(begin, begin + static_cast<ptrdiff_t>(item_count),
                            [](int8_t rate) { return rate != 0; }))
                country_tax_masks[static_cast<size_t>(country)] |=
                    static_cast<uint8_t>(1U << kind);
        }
    };
    mark_country_tax(NativeCountryRuntime::TAX_INCOME,
                     _epoch_income_tax_rates, _profession_ids.size());
    mark_country_tax(NativeCountryRuntime::TAX_CONSUMPTION,
                     _epoch_consumption_tax_rates, _good_ids.size());
    mark_country_tax(NativeCountryRuntime::TAX_BUSINESS,
                     _epoch_business_tax_rates, _building_types.size());
    mark_country_tax(NativeCountryRuntime::TAX_IMPORT,
                     _epoch_import_tax_rates, _good_ids.size());
    mark_country_tax(NativeCountryRuntime::TAX_EXPORT,
                     _epoch_export_tax_rates, _good_ids.size());
    _epoch_active_tax_mask = 0;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        uint8_t mask = 0;
        const uint32_t compiled_id =
            _epoch_cell_compiled_tax_policy[static_cast<size_t>(cell)];
        if (compiled_id > 0 &&
            compiled_id < _epoch_compiled_cell_tax_policies.size())
            mask = _epoch_compiled_cell_tax_policies[compiled_id].active_mask;
        else if (country >= 0 && country < _epoch_country_count)
            mask = country_tax_masks[static_cast<size_t>(country)];
        _epoch_cell_active_tax_mask[static_cast<size_t>(cell)] = mask;
        _epoch_active_tax_mask |= mask;
    }
    _epoch_cell_tax_cache_bytes = static_cast<int64_t>(
        _epoch_cell_compiled_tax_policy.size() * sizeof(uint32_t) +
        _epoch_cell_active_tax_mask.size() * sizeof(uint8_t) +
        _epoch_compiled_cell_tax_policies.size() *
            sizeof(CompiledCellTaxPolicy) +
        _epoch_compiled_cell_tax_overrides.size() *
            sizeof(CompiledCellTaxOverride) +
        _epoch_compiled_cell_tax_default_rows.size() *
            sizeof(CompiledCellTaxDefaultRow) +
        _epoch_compiled_cell_tax_default_rates.size() * sizeof(int8_t));
    _epoch_cell_tax_compile_ms = elapsed_ms(cell_tax_compile_started);
    const auto building_factor_started = Clock::now();
    refresh_building_modifier_factors();
    _epoch_begin_building_factor_ms = elapsed_ms(building_factor_started);
    refresh_epoch_development();
    return true;
}

int64_t NativeEconomyRuntime::update_cohort_satisfaction(
        int32_t slot, int32_t cell, int64_t subsistence_q16,
        const Signature &signature, const int64_t *tier_weighted_q16,
        const int64_t *tier_weight_q16, int64_t &sat) {
    std::array<int64_t, SAT_DIM_COUNT> dims{};
    std::array<int64_t, SAT_DIM_COUNT> weights{};
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
        weights[static_cast<size_t>(dim)] =
            signature.satisfaction_weights_q16[static_cast<size_t>(dim)];

    // Tiers 0-3 come from the need reduction that just ran. The subsistence tier
    // is overridden by the calorie/cold survival figure so starvation semantics
    // stay identical to the pre-composite runtime.
    for (int32_t tier = 0; tier < SAT_TIER_COUNT; ++tier) {
        const int64_t weight = tier_weight_q16[tier];
        if (weight <= 0) {
            // The plan never asks for this tier, so scoring it would punish a
            // class for needs it does not have. Drop it from the denominator.
            weights[static_cast<size_t>(tier)] = 0;
            dims[static_cast<size_t>(tier)] = Q16_ONE - 1;
            continue;
        }
        dims[static_cast<size_t>(tier)] = std::clamp<int64_t>(
            tier_weighted_q16[tier] / weight, 0, Q16_ONE - 1);
    }
    dims[SAT_DIM_SUBSISTENCE] = std::clamp<int64_t>(subsistence_q16, 0,
                                                    Q16_ONE - 1);

    const int64_t population = std::max<int64_t>(1, _population.population[slot]);
    const int64_t per_capita_income = _population.income_ema[slot] / population;
    const int64_t per_capita_baseline =
        _population.income_baseline_ema[slot] / population;
    if (per_capita_baseline <= 0) {
        // No trailing baseline yet (a freshly seeded or freshly emptied cohort).
        // Treat growth as neutral rather than inventing a ratio from zero.
        dims[SAT_DIM_INCOME] = per_capita_income > 0 ? Q16_ONE - 1 : Q16_ONE / 2;
    } else {
        const int64_t growth_q16 = mul_div_sat(
            std::max<int64_t>(0, per_capita_income), Q16_ONE,
            per_capita_baseline, sat);
        dims[SAT_DIM_INCOME] = normalize_band_q16(
            growth_q16, _satisfaction_income_growth_floor_q16,
            _satisfaction_income_growth_ceiling_q16, sat);
    }

    const int64_t daily_living_cost = cell >= 0 &&
            cell < static_cast<int32_t>(_cell_living_cost_per_capita.size())
        ? _cell_living_cost_per_capita[cell] : 0;
    const int64_t monthly_cost = saturating_mul(
        saturating_mul(std::max<int64_t>(0, daily_living_cost), population, sat),
        30, sat);
    if (monthly_cost <= 0) {
        // Nothing costs anything here, so savings cannot express anxiety.
        dims[SAT_DIM_SAVINGS] = Q16_ONE - 1;
    } else {
        const int64_t months_q16 = mul_div_sat(
            std::max<int64_t>(0, _population.funds[slot]), Q16_ONE, monthly_cost,
            sat);
        dims[SAT_DIM_SAVINGS] = normalize_band_q16(
            months_q16, 0, _satisfaction_savings_target_months_q16, sat);
    }

    const int64_t gross_income = saturating_add(
        std::max<int64_t>(0, _population.epoch_income[slot]),
        std::max<int64_t>(0, _population.epoch_in_kind_income[slot]), sat);
    const int64_t net_tax = saturating_sub(_population.epoch_tax_paid[slot],
                                           _population.epoch_subsidy_received[slot],
                                           sat);
    if (net_tax <= 0) {
        dims[SAT_DIM_TAX] = Q16_ONE - 1;
    } else if (gross_income <= 0) {
        // Taxed while earning nothing is the worst possible burden.
        dims[SAT_DIM_TAX] = 0;
    } else {
        const int64_t burden_q16 = mul_div_sat(net_tax, Q16_ONE, gross_income, sat);
        dims[SAT_DIM_TAX] = Q16_ONE - 1 - normalize_band_q16(
            burden_q16, 0, _satisfaction_tax_tolerance_q16, sat);
    }

    dims[SAT_DIM_DEVELOPMENT] = cell >= 0 &&
            cell < static_cast<int32_t>(_epoch_cell_development_q16.size())
        ? _epoch_cell_development_q16[cell] : 0;

    int64_t weighted_total = 0;
    int64_t weight_total = 0;
    int64_t worst_shortfall = -1;
    int32_t worst_dimension = static_cast<int32_t>(
        std::numeric_limits<uint8_t>::max());
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
        const int64_t weight = weights[static_cast<size_t>(dim)];
        if (weight <= 0) continue;
        const int64_t value = dims[static_cast<size_t>(dim)];
        weighted_total = saturating_add(weighted_total,
                                        saturating_mul(value, weight, sat), sat);
        weight_total = saturating_add(weight_total, weight, sat);
        const int64_t shortfall = saturating_mul(Q16_ONE - 1 - value, weight, sat);
        if (shortfall > worst_shortfall) {
            worst_shortfall = shortfall;
            worst_dimension = dim;
        }
    }
    const int64_t raw_q16 = weight_total > 0
        ? std::clamp<int64_t>(weighted_total / weight_total, 0, Q16_ONE - 1)
        : Q16_ONE - 1;
    // Needs are hierarchical: a cohort that cannot eat may not be rated
    // satisfied because it banked money or lives in a developed city. The
    // ceiling lets the other dimensions lift it only through the configured
    // slack above its subsistence floor.
    const int64_t ceiling_q16 = saturating_add(
        dims[SAT_DIM_SUBSISTENCE],
        mul_div_sat(Q16_ONE - 1 - dims[SAT_DIM_SUBSISTENCE],
                    _satisfaction_subsistence_gate_slack_q16, Q16_ONE, sat), sat);
    const int64_t composite_q16 = std::clamp<int64_t>(
        std::min(raw_q16, ceiling_q16), 0, Q16_ONE - 1);

    _population.composite_satisfaction[slot] =
        static_cast<uint16_t>(composite_q16);
    _population.worst_dimension_id[slot] = static_cast<uint8_t>(worst_dimension);
    const size_t base = static_cast<size_t>(slot) *
        static_cast<size_t>(SAT_DIM_COUNT);
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
        _population.satisfaction_dims[base + static_cast<size_t>(dim)] =
            static_cast<uint16_t>(dims[static_cast<size_t>(dim)]);
    return composite_q16;
}

int32_t NativeEconomyRuntime::living_standard_level_for(int64_t composite_q16) const {
    // Seven presentation bands over the composite. They are display-only; every
    // gameplay consumer reads composite_satisfaction or a single dimension.
    // Calibrated against the composite, not the old survival figure: a cohort
    // that eats well but owns nothing and lives in a hamlet lands near 0.45, so
    // the bands sit well below the pre-composite thresholds.
    static constexpr int64_t THRESHOLDS[6] = {
        Q16_ONE * 12 / 100, Q16_ONE * 22 / 100, Q16_ONE * 33 / 100,
        Q16_ONE * 45 / 100, Q16_ONE * 58 / 100, Q16_ONE * 72 / 100,
    };
    int32_t level = 0;
    while (level < 6 && composite_q16 >= THRESHOLDS[level]) ++level;
    return level;
}

int32_t NativeEconomyRuntime::social_pressure_level_for(
        int64_t composite_q16) const {
    int32_t level = 0;
    while (level < SAT_PRESSURE_LEVEL_COUNT - 1 &&
           composite_q16 >= _satisfaction_pressure_thresholds_q16[level])
        ++level;
    return level;
}

// Emits one gameplay fact per settled cell whose population-weighted pressure
// level actually changed. The level, not the raw composite, is the dedup key,
// so a cell drifting inside a band stays silent and the event volume per epoch
// is bounded by the rolling workset.
int64_t NativeEconomyRuntime::normalize_band_q16(int64_t value, int64_t floor,
                                                 int64_t ceiling,
                                                 int64_t &sat) const {
    if (ceiling <= floor) return value >= ceiling ? Q16_ONE - 1 : 0;
    if (value <= floor) return 0;
    if (value >= ceiling) return Q16_ONE - 1;
    return std::clamp<int64_t>(
        mul_div_sat(value - floor, Q16_ONE - 1, ceiling - floor, sat), 0,
        Q16_ONE - 1);
}

void NativeEconomyRuntime::refresh_epoch_development() {
    const int32_t country_count = std::max(0, _epoch_country_count);
    _epoch_country_technology_progress_q16.assign(
        static_cast<size_t>(country_count), 0);
    const int64_t technology_total = static_cast<int64_t>(_technology_ids.size());
    for (int32_t country = 0; country < country_count; ++country) {
        if (technology_total <= 0) continue;
        int64_t known = 0;
        const size_t begin = static_cast<size_t>(country) *
            static_cast<size_t>(_epoch_country_technology_words);
        for (int32_t word = 0; word < _epoch_country_technology_words; ++word) {
            const size_t index = begin + static_cast<size_t>(word);
            if (index >= _epoch_country_technologies.size()) break;
            known += popcount_u64(_epoch_country_technologies[index]);
        }
        _epoch_country_technology_progress_q16[country] = static_cast<int32_t>(
            std::clamp<int64_t>(mul_div_sat(std::min(known, technology_total),
                                            Q16_ONE, technology_total,
                                            _saturation_count),
                                0, Q16_ONE));
    }

    const size_t cells = static_cast<size_t>(std::max(0, _cell_count));
    _epoch_cell_development_q16.assign(cells, 0);
    const int64_t weight_total = static_cast<int64_t>(
        _satisfaction_development_weights_q16[0]) +
        _satisfaction_development_weights_q16[1] +
        _satisfaction_development_weights_q16[2];
    if (weight_total <= 0) return;
    const int64_t tier_max = std::max<int64_t>(
        1, static_cast<int64_t>(_prosperity_thresholds.size()) - 1);
    const int64_t variety_target = std::max<int64_t>(
        1, _satisfaction_development_variety_target);
    const bool building_csr_valid =
        _building_cell_offsets.size() == cells + 1;
    for (size_t cell = 0; cell < cells; ++cell) {
        const int64_t tier = cell < _settlements.tier.size()
            ? std::min<int64_t>(_settlements.tier[cell], tier_max) : 0;
        const int64_t tier_q16 = mul_div_sat(tier, Q16_ONE, tier_max,
                                             _saturation_count);
        int64_t technology_q16 = 0;
        if (cell < _epoch_cell_country.size()) {
            const int32_t country = _epoch_cell_country[cell];
            if (country >= 0 && country < country_count)
                technology_q16 = _epoch_country_technology_progress_q16[
                    static_cast<size_t>(country)];
        }
        int64_t variety = 0;
        if (building_csr_valid) {
            // Groups are stored in stable (cell, type, owner) order, so distinct
            // building types are the number of type transitions in the span.
            const int32_t begin = _building_cell_offsets[cell];
            const int32_t end = _building_cell_offsets[cell + 1];
            int32_t previous_type = -1;
            for (int32_t group = begin; group < end; ++group) {
                const int32_t type_id = _buildings[group].type_id;
                if (type_id == previous_type) continue;
                previous_type = type_id;
                ++variety;
            }
        }
        const int64_t variety_q16 = mul_div_sat(
            std::min(variety, variety_target), Q16_ONE, variety_target,
            _saturation_count);
        const int64_t weighted = saturating_add(saturating_add(
            saturating_mul(tier_q16, _satisfaction_development_weights_q16[0],
                           _saturation_count),
            saturating_mul(technology_q16, _satisfaction_development_weights_q16[1],
                           _saturation_count), _saturation_count),
            saturating_mul(variety_q16, _satisfaction_development_weights_q16[2],
                           _saturation_count), _saturation_count);
        _epoch_cell_development_q16[cell] = static_cast<int32_t>(
            std::clamp<int64_t>(weighted / weight_total, 0, Q16_ONE - 1));
    }
}

void NativeEconomyRuntime::refresh_city_modifier_factors() {
    const size_t cells = static_cast<size_t>(std::max(0, _cell_count));
    const size_t need_count = _need_ids.size();
    const size_t good_count = _good_ids.size();
    const bool shape_valid =
        _epoch_cell_birth_factor_q16.size() == cells &&
        _epoch_cell_need_consumption_factor_q16.size() == cells * need_count &&
        _epoch_cell_good_consumption_factor_q16.size() == cells * good_count;
    if (_modifier_runtime == nullptr) {
        if (_epoch_city_factor_valid && shape_valid) return;
        _epoch_cell_birth_factor_q16.assign(cells, Q16_ONE);
        _epoch_cell_need_consumption_factor_q16.assign(cells * need_count, Q16_ONE);
        _epoch_cell_good_consumption_factor_q16.assign(cells * good_count, Q16_ONE);
        _city_factor_shared_birth_q16 = Q16_ONE;
        _city_factor_shared_needs_q16.assign(need_count, Q16_ONE);
        _city_factor_shared_goods_q16.assign(good_count, Q16_ONE);
        _city_factor_dirty_cells.clear();
        _epoch_city_factor_valid = true;
        return;
    }

    _city_factor_stat_ids_scratch.clear();
    _city_factor_stat_ids_scratch.reserve(2 + need_count + good_count);
    _city_factor_stat_ids_scratch.push_back(_city_birth_stat_id);
    _city_factor_stat_ids_scratch.push_back(_city_consumption_stat_id);
    _city_factor_stat_ids_scratch.insert(
        _city_factor_stat_ids_scratch.end(),
        _city_need_consumption_stat_ids.begin(),
        _city_need_consumption_stat_ids.end());
    _city_factor_stat_ids_scratch.insert(
        _city_factor_stat_ids_scratch.end(),
        _city_good_consumption_stat_ids.begin(),
        _city_good_consumption_stat_ids.end());
    const uint64_t version = _modifier_runtime->stat_bucket_version(
        ModifierRuntime::ECONOMY, _city_factor_stat_ids_scratch.data(),
        _city_factor_stat_ids_scratch.size());
    if (_epoch_city_factor_valid && shape_valid &&
        _epoch_city_factor_stat_version == version)
        return;

    // A cell id enters effective_value() as the GROUP key, so the GLOBAL and
    // ENTITY(0) contributions are shared by every cell. Resolve that shared row
    // once with an empty group handle, then re-probe only the cells that own a
    // group bucket.
    const auto shared_factor = [&](int32_t stat_id) {
        return modifier_factor_q16(_modifier_runtime->effective_value(
            ModifierRuntime::ECONOMY, stat_id, 0, 0, 1.0));
    };
    const auto need_factor = [](int32_t general, int32_t selected) {
        int64_t sat = 0;
        return static_cast<int32_t>(std::clamp<int64_t>(mul_div_sat(
            general, selected, Q16_ONE, sat), 0, 4 * Q16_ONE));
    };
    const int32_t shared_birth = shared_factor(_city_birth_stat_id);
    const int32_t shared_general = shared_factor(_city_consumption_stat_id);
    std::vector<int32_t> shared_needs(need_count, Q16_ONE);
    for (size_t need = 0; need < need_count; ++need)
        shared_needs[need] = need_factor(
            shared_general, shared_factor(_city_need_consumption_stat_ids[need]));
    std::vector<int32_t> shared_goods(good_count, Q16_ONE);
    for (size_t good = 0; good < good_count; ++good)
        shared_goods[good] = shared_factor(_city_good_consumption_stat_ids[good]);

    const bool shared_changed = !_epoch_city_factor_valid || !shape_valid ||
        shared_birth != _city_factor_shared_birth_q16 ||
        shared_needs != _city_factor_shared_needs_q16 ||
        shared_goods != _city_factor_shared_goods_q16;
    const auto paint_shared = [&](size_t cell) {
        _epoch_cell_birth_factor_q16[cell] = shared_birth;
        std::copy(shared_needs.begin(), shared_needs.end(),
                  _epoch_cell_need_consumption_factor_q16.begin() +
                      static_cast<ptrdiff_t>(cell * need_count));
        std::copy(shared_goods.begin(), shared_goods.end(),
                  _epoch_cell_good_consumption_factor_q16.begin() +
                      static_cast<ptrdiff_t>(cell * good_count));
    };
    if (shared_changed) {
        _epoch_cell_birth_factor_q16.assign(cells, shared_birth);
        _epoch_cell_need_consumption_factor_q16.resize(cells * need_count);
        _epoch_cell_good_consumption_factor_q16.resize(cells * good_count);
        for (size_t cell = 0; cell < cells; ++cell) paint_shared(cell);
    } else {
        // Only the previously overridden cells can still hold a stale row.
        for (const int32_t cell : _city_factor_dirty_cells)
            if (cell >= 0 && static_cast<size_t>(cell) < cells)
                paint_shared(static_cast<size_t>(cell));
    }
    _city_factor_shared_birth_q16 = shared_birth;
    _city_factor_shared_needs_q16 = std::move(shared_needs);
    _city_factor_shared_goods_q16 = std::move(shared_goods);

    _modifier_runtime->collect_scope_ids(
        ModifierRuntime::ECONOMY, ModifierRuntime::GROUP,
        _city_factor_stat_ids_scratch.data(),
        _city_factor_stat_ids_scratch.size(),
        _city_factor_group_cells_scratch);
    _city_factor_dirty_cells.clear();
    _city_factor_dirty_cells.reserve(_city_factor_group_cells_scratch.size());
    for (const uint64_t scope_id : _city_factor_group_cells_scratch) {
        if (scope_id >= cells) continue;
        const auto cell_factor = [&](int32_t stat_id) {
            return modifier_factor_q16(_modifier_runtime->effective_value(
                ModifierRuntime::ECONOMY, stat_id, 0, scope_id, 1.0));
        };
        _epoch_cell_birth_factor_q16[scope_id] = cell_factor(_city_birth_stat_id);
        const int32_t general = cell_factor(_city_consumption_stat_id);
        for (size_t need = 0; need < need_count; ++need) {
            _epoch_cell_need_consumption_factor_q16[scope_id * need_count + need] =
                need_factor(general,
                            cell_factor(_city_need_consumption_stat_ids[need]));
        }
        for (size_t good = 0; good < good_count; ++good) {
            _epoch_cell_good_consumption_factor_q16[scope_id * good_count + good] =
                cell_factor(_city_good_consumption_stat_ids[good]);
        }
        _city_factor_dirty_cells.push_back(static_cast<int32_t>(scope_id));
    }
    _epoch_city_factor_stat_version = version;
    _epoch_city_factor_valid = true;
}

// Fiscal settlement implementations live in economy_runtime_fiscal.cpp.

// Building resource lane implementations live in
// economy_runtime_building_resources.cpp.

uint64_t NativeEconomyRuntime::trace_hash_mix(uint64_t hash, uint64_t value) {
    hash ^= value;
    hash *= 1099511628211ULL;
    return hash;
}

int32_t NativeEconomyRuntime::find_cohort_slot(int32_t cell, int32_t signature_id) const {
    if (cell < 0 || cell >= _cell_count || signature_id < 0 ||
        signature_id >= static_cast<int32_t>(_signatures.size())) return -1;
    const int64_t before = _population.scan_steps;
    const int32_t slot = _population.find_signature(
        cell, static_cast<uint32_t>(signature_id));
    const int64_t steps = _population.scan_steps - before;
    _scan_steps_find_signature += steps;
    ++_scan_calls_find_signature;
    note_scan_steps(steps);
    return slot;
}

// Building graph storage implementations live in
// economy_runtime_building_storage.cpp.

void NativeEconomyRuntime::rebuild_market_signals() {
    MarketSignalStore &next = _market_signals_rebuild_scratch;
    next.clear(_cell_count);
    const size_t old_size = _market_signals.good_ids.size();
    next.good_ids.reserve(old_size);
    next.business_demand_ema.reserve(old_size);
    next.offered_supply_ema.reserve(old_size);
    next.realized_withdrawal_ema.reserve(old_size);
    next.cost_anchor_price.reserve(old_size);
    if (_building_market_signal_stamp.size() !=
            static_cast<size_t>(_market.good_count)) {
        _building_market_signal_stamp.assign(
            static_cast<size_t>(std::max(0, _market.good_count)), 0);
        _building_market_signal_stamp_generation = 0;
    }
    auto next_stamp = [&]() {
        ++_building_market_signal_stamp_generation;
        if (_building_market_signal_stamp_generation == 0) {
            std::fill(_building_market_signal_stamp.begin(),
                      _building_market_signal_stamp.end(), 0);
            _building_market_signal_stamp_generation = 1;
        }
        return _building_market_signal_stamp_generation;
    };
    const bool old_shape_valid = _market_signals.cell_offsets.size() ==
        static_cast<size_t>(_cell_count + 1) &&
        static_cast<size_t>(_market_signals.cell_offsets.back()) <= old_size;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const uint32_t stamp = next_stamp();
        const int32_t old_begin = old_shape_valid
            ? _market_signals.cell_offsets[cell] : 0;
        const int32_t old_end = old_shape_valid
            ? _market_signals.cell_offsets[cell + 1] : 0;
        for (int32_t signal = old_begin; signal < old_end; ++signal) {
            if (_market_signals.business_demand_ema[signal] != 0 ||
                _market_signals.offered_supply_ema[signal] != 0 ||
                _market_signals.realized_withdrawal_ema[signal] != 0 ||
                _market_signals.cost_anchor_price[signal] != 0) {
                _building_market_signal_stamp[
                    _market_signals.good_ids[signal]] = stamp;
            }
        }
        if (_building_cell_offsets.size() ==
                static_cast<size_t>(_cell_count + 1)) {
            for (int32_t group_index = _building_cell_offsets[cell];
                 group_index < _building_cell_offsets[cell + 1]; ++group_index) {
                const BuildingGroup &group = _buildings[group_index];
                if (group.count <= 0 || group.type_id < 0 ||
                    group.type_id >= static_cast<int32_t>(_building_types.size()))
                    continue;
                const BuildingType &type = _building_types[group.type_id];
                for (int32_t edge = type.market_signal_begin;
                     edge < type.market_signal_begin + type.market_signal_count;
                     ++edge) {
                    _building_market_signal_stamp[
                        _building_type_market_signal_goods[edge]] = stamp;
                }
            }
        }
        int32_t old_cursor = old_begin;
        for (int32_t good = 0; good < _market.good_count; ++good) {
            if (_building_market_signal_stamp[good] != stamp) continue;
            while (old_cursor < old_end &&
                   _market_signals.good_ids[old_cursor] < good) ++old_cursor;
            const bool found = old_cursor < old_end &&
                _market_signals.good_ids[old_cursor] == good;
            next.good_ids.push_back(good);
            next.business_demand_ema.push_back(found
                ? _market_signals.business_demand_ema[old_cursor] : 0);
            next.offered_supply_ema.push_back(found
                ? _market_signals.offered_supply_ema[old_cursor] : 0);
            next.realized_withdrawal_ema.push_back(found
                ? _market_signals.realized_withdrawal_ema[old_cursor] : 0);
            next.cost_anchor_price.push_back(found
                ? _market_signals.cost_anchor_price[old_cursor] : 0);
        }
        next.cell_offsets[cell + 1] = static_cast<int32_t>(next.good_ids.size());
    }
    std::swap(_market_signals, _market_signals_rebuild_scratch);
    rebuild_market_signal_lookup();
    rebuild_production_input_reserves();
}

void NativeEconomyRuntime::rebuild_market_signal_lookup() {
    constexpr size_t DENSE_LOOKUP_ENTRY_LIMIT = 4'000'000;
    const size_t matrix_size = static_cast<size_t>(std::max(0, _cell_count)) *
        static_cast<size_t>(std::max(0, _market.good_count));
    if (_market.good_count <= 0 || matrix_size > DENSE_LOOKUP_ENTRY_LIMIT ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) {
        _market_signals.dense_index.clear();
        return;
    }
    _market_signals.dense_index.assign(matrix_size, -1);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        for (int32_t signal = _market_signals.cell_offsets[cell];
             signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
            const int32_t good = _market_signals.good_ids[signal];
            if (good >= 0 && good < _market.good_count) {
                _market_signals.dense_index[
                    static_cast<size_t>(cell) * _market.good_count + good] = signal;
            }
        }
    }
}

int32_t NativeEconomyRuntime::ensure_market_signal_index(int32_t cell, int32_t good) {
    if (cell < 0 || cell >= _cell_count || good < 0 || good >= _market.good_count ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) return -1;
    const int32_t existing = market_signal_index(cell, good);
    if (existing >= 0) return existing;
    const auto insert_started = Clock::now();
    const size_t matrix_size = static_cast<size_t>(std::max(0, _cell_count)) *
        static_cast<size_t>(std::max(0, _market.good_count));
    if (_stage == Stage::BUILDING_COMMIT && _building_commit_phase == 5 &&
        _market_signals.dense_index.size() == matrix_size) {
        const size_t old_size = _market_signals.good_ids.size();
        const int32_t append_index = static_cast<int32_t>(old_size);
        _market_signals.good_ids.push_back(good);
        _market_signals.business_demand_ema.push_back(0);
        _market_signals.offered_supply_ema.push_back(0);
        _market_signals.realized_withdrawal_ema.push_back(0);
        _market_signals.cost_anchor_price.push_back(0);
        auto append_i64_if_aligned = [&](std::vector<int64_t> &values) {
            if (values.size() == old_size) values.push_back(0);
        };
        auto append_i32_if_aligned = [&](std::vector<int32_t> &values) {
            if (values.size() == old_size) values.push_back(0);
        };
        append_i64_if_aligned(_epoch_business_demand_ema);
        append_i64_if_aligned(_epoch_desired_business_demand);
        append_i64_if_aligned(_epoch_funded_business_demand);
        append_i64_if_aligned(_epoch_offered_supply_ema);
        append_i64_if_aligned(_epoch_producer_sellable_current);
        append_i64_if_aligned(_epoch_producer_merchant_sold_current);
        append_i64_if_aligned(_epoch_producer_discarded_current);
        append_i64_if_aligned(_epoch_nonhousehold_withdrawals);
        append_i32_if_aligned(_epoch_cost_anchor_price);
        append_i64_if_aligned(_production_input_reserve);
        _market_signal_overflow_cells.push_back(cell);
        _market_signals.dense_index[
            static_cast<size_t>(cell) * _market.good_count + good] = append_index;
        ++_market_signal_insert_count;
        _market_signal_insert_ms += elapsed_ms(insert_started);
        return append_index;
    }
    const int32_t begin = _market_signals.cell_offsets[cell];
    const int32_t end = _market_signals.cell_offsets[cell + 1];
    const auto first = _market_signals.good_ids.begin() + begin;
    const auto last = _market_signals.good_ids.begin() + end;
    const auto it = std::lower_bound(first, last, good);
    if (it != last && *it == good) {
        return static_cast<int32_t>(it - _market_signals.good_ids.begin());
    }
    const int32_t insert_pos = static_cast<int32_t>(it - _market_signals.good_ids.begin());
    const size_t old_size = _market_signals.good_ids.size();
    _market_signals.good_ids.insert(_market_signals.good_ids.begin() + insert_pos, good);
    _market_signals.business_demand_ema.insert(
        _market_signals.business_demand_ema.begin() + insert_pos, 0);
    _market_signals.offered_supply_ema.insert(
        _market_signals.offered_supply_ema.begin() + insert_pos, 0);
    _market_signals.realized_withdrawal_ema.insert(
        _market_signals.realized_withdrawal_ema.begin() + insert_pos, 0);
    _market_signals.cost_anchor_price.insert(
        _market_signals.cost_anchor_price.begin() + insert_pos, 0);
    for (int32_t c = cell + 1; c < static_cast<int32_t>(_market_signals.cell_offsets.size()); ++c) {
        ++_market_signals.cell_offsets[c];
    }
    auto insert_i64_if_aligned = [&](std::vector<int64_t> &values) {
        if (values.size() == old_size) values.insert(values.begin() + insert_pos, 0);
    };
    auto insert_i32_if_aligned = [&](std::vector<int32_t> &values) {
        if (values.size() == old_size) values.insert(values.begin() + insert_pos, 0);
    };
    insert_i64_if_aligned(_epoch_business_demand_ema);
    insert_i64_if_aligned(_epoch_desired_business_demand);
    insert_i64_if_aligned(_epoch_funded_business_demand);
    insert_i64_if_aligned(_epoch_offered_supply_ema);
    insert_i64_if_aligned(_epoch_producer_sellable_current);
    insert_i64_if_aligned(_epoch_producer_merchant_sold_current);
    insert_i64_if_aligned(_epoch_producer_discarded_current);
    insert_i64_if_aligned(_epoch_nonhousehold_withdrawals);
    insert_i32_if_aligned(_epoch_cost_anchor_price);
    insert_i64_if_aligned(_production_input_reserve);
    // Inserting shifts every following sparse index. Rebuilding the full dense
    // matrix here turns a rare topology mutation into O(cells * goods) per
    // investment. Fall back to the authoritative CSR until the next topology
    // rebuild, which recreates the cache once.
    _market_signals.dense_index.clear();
    ++_market_signal_insert_count;
    _market_signal_insert_ms += elapsed_ms(insert_started);
    return insert_pos;
}

bool NativeEconomyRuntime::flush_market_signal_overflow(std::string &error) {
    if (_market_signal_overflow_cells.empty()) return true;
    const auto started = Clock::now();
    const size_t total = _market_signals.good_ids.size();
    const size_t overflow_count = _market_signal_overflow_cells.size();
    if (overflow_count > total ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1) ||
        static_cast<size_t>(_market_signals.cell_offsets.back()) !=
            total - overflow_count) {
        error = "market_signal_overflow_shape_invalid";
        return false;
    }

    std::vector<int32_t> cells(total, -1);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        for (int32_t index = _market_signals.cell_offsets[cell];
             index < _market_signals.cell_offsets[cell + 1]; ++index) {
            cells[index] = cell;
        }
    }
    const size_t base_count = total - overflow_count;
    for (size_t i = 0; i < overflow_count; ++i)
        cells[base_count + i] = _market_signal_overflow_cells[i];

    std::vector<size_t> order(total);
    std::iota(order.begin(), order.end(), size_t{0});
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        if (cells[a] != cells[b]) return cells[a] < cells[b];
        if (_market_signals.good_ids[a] != _market_signals.good_ids[b])
            return _market_signals.good_ids[a] < _market_signals.good_ids[b];
        return a < b;
    });
    for (size_t i = 1; i < order.size(); ++i) {
        const size_t a = order[i - 1];
        const size_t b = order[i];
        if (cells[a] == cells[b] &&
            _market_signals.good_ids[a] == _market_signals.good_ids[b]) {
            error = "market_signal_overflow_duplicate";
            return false;
        }
    }

    _market_signals.cell_offsets.assign(
        static_cast<size_t>(_cell_count) + 1, 0);
    for (const size_t index : order) {
        if (cells[index] < 0 || cells[index] >= _cell_count) {
            error = "market_signal_overflow_cell_invalid";
            return false;
        }
        ++_market_signals.cell_offsets[cells[index] + 1];
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _market_signals.cell_offsets[cell + 1] +=
            _market_signals.cell_offsets[cell];

    auto reorder = [&](auto &values) {
        if (values.size() != total) return;
        using Value = typename std::decay_t<decltype(values)>::value_type;
        std::vector<Value> next;
        next.reserve(total);
        for (const size_t index : order) next.push_back(values[index]);
        values.swap(next);
    };
    reorder(_market_signals.good_ids);
    reorder(_market_signals.business_demand_ema);
    reorder(_market_signals.offered_supply_ema);
    reorder(_market_signals.realized_withdrawal_ema);
    reorder(_market_signals.cost_anchor_price);
    reorder(_epoch_business_demand_ema);
    reorder(_epoch_desired_business_demand);
    reorder(_epoch_funded_business_demand);
    reorder(_epoch_offered_supply_ema);
    reorder(_epoch_producer_sellable_current);
    reorder(_epoch_producer_merchant_sold_current);
    reorder(_epoch_producer_discarded_current);
    reorder(_epoch_nonhousehold_withdrawals);
    reorder(_epoch_cost_anchor_price);
    reorder(_production_input_reserve);
    _market_signal_overflow_cells.clear();
    rebuild_market_signal_lookup();
    _market_signal_flush_ms += elapsed_ms(started);
    return true;
}

int32_t NativeEconomyRuntime::market_signal_index(int32_t cell, int32_t good) const {
    if (cell < 0 || cell >= _cell_count || good < 0 || good >= _market.good_count ||
        _market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) return -1;
    const size_t dense_offset = static_cast<size_t>(cell) * _market.good_count + good;
    if (dense_offset < _market_signals.dense_index.size())
        return _market_signals.dense_index[dense_offset];
    const int32_t begin = _market_signals.cell_offsets[cell];
    const int32_t end = _market_signals.cell_offsets[cell + 1];
    const auto first = _market_signals.good_ids.begin() + begin;
    const auto last = _market_signals.good_ids.begin() + end;
    const auto it = std::lower_bound(first, last, good);
    return it != last && *it == good ? static_cast<int32_t>(it - _market_signals.good_ids.begin()) : -1;
}

void NativeEconomyRuntime::add_trade_active_key(int32_t market, int32_t good) {
    if (market < 0 || market >= _market.market_count || good < 0 ||
        good >= _market.good_count) return;
    const size_t matrix_size = static_cast<size_t>(_market.market_count) *
        static_cast<size_t>(_market.good_count);
    if (_trade_active_key_present.size() != matrix_size) {
        _trade_active_key_present.assign(matrix_size, 0);
        for (const uint64_t existing : _trade_active_keys) {
            const int32_t existing_market = static_cast<int32_t>(existing >> 32);
            const int32_t existing_good = static_cast<int32_t>(existing & 0xffffffffU);
            if (existing_market < 0 || existing_market >= _market.market_count ||
                existing_good < 0 || existing_good >= _market.good_count) continue;
            _trade_active_key_present[_market.index(existing_market, existing_good)] = 1;
        }
    }
    const size_t index = static_cast<size_t>(_market.index(market, good));
    if (_trade_active_key_present[index] != 0) return;
    _trade_active_key_present[index] = 1;
    _trade_active_keys.push_back(
        (static_cast<uint64_t>(static_cast<uint32_t>(market)) << 32) |
        static_cast<uint32_t>(good));
}

void NativeEconomyRuntime::rebuild_production_input_reserves(
        int32_t active_begin, int32_t active_end, bool initialize) {
    if (initialize) {
        _production_input_reserve.assign(_market_signals.good_ids.size(), 0);
        _production_input_reserved = 0;
        _production_input_reserve_shortfall = 0;
    }
    const std::vector<int32_t> &active_cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    active_begin = std::clamp<int32_t>(
        active_begin, 0, static_cast<int32_t>(active_cells.size()));
    active_end = active_end < 0
        ? static_cast<int32_t>(active_cells.size())
        : std::clamp<int32_t>(active_end, active_begin,
                              static_cast<int32_t>(active_cells.size()));
    const bool frozen = _epoch_active;
    thread_local std::vector<int32_t> selected_signals;
    thread_local std::vector<int64_t> selected_physical;
    auto input_purchase_scale_q16 = [&](const ProductionInput &input,
                                        int64_t output_scale_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return 0;
        const int64_t floor_q16 = Q16_ONE - required;
        output_scale_q16 = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
        if (output_scale_q16 <= floor_q16) return 0;
        const int64_t delta = output_scale_q16 - floor_q16;
        return std::min<int64_t>(
            Q16_ONE, mul_div_sat(delta, Q16_ONE, required, _saturation_count));
    };
    auto soft_input_bound_q16 = [&](const ProductionInput &input,
                                    int64_t raw_capacity_q16) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return Q16_ONE;
        raw_capacity_q16 = std::clamp<int64_t>(raw_capacity_q16, 0, Q16_ONE);
        return std::clamp<int64_t>(
            Q16_ONE - required + mul_div_sat(
                raw_capacity_q16, required, Q16_ONE, _saturation_count),
            0, Q16_ONE);
    };
    for (int32_t active = active_begin; active < active_end; ++active) {
        const int32_t cell = active_cells[active];
        const int32_t group_begin = _building_cell_offsets[cell];
        const int32_t group_end = _building_cell_offsets[cell + 1];
        for (int32_t group_index = group_begin; group_index < group_end; ++group_index) {
        const BuildingGroup &group = _buildings[group_index];
        if (group.count <= 0 || group.operating_state == 1 ||
            group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 ||
            group.type_id >= static_cast<int32_t>(_building_types.size()) ||
            !building_available(group.cell, group.type_id, frozen)) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t utilization_q16 = std::clamp<int64_t>(
            group.planned_utilization_q16, 0, Q16_ONE);
        if (utilization_q16 <= 0) continue;
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        const int32_t market = _market.cell_to_market[group.cell];
        bool produces_survival_food = false;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            produces_survival_food = produces_survival_food ||
                _survival_food_good_mask[good] != 0;
        }
        selected_signals.assign(type.input_count, -1);
        selected_physical.assign(type.input_count, 0);
        int64_t executable_q16 = Q16_ONE;
        bool household_priority_bundle = false;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            int32_t selected = -1;
            int32_t selected_signal = -1;
            int64_t selected_physical_qty = 0;
            int64_t best_capacity_q16 = -1;
            int64_t best_effective_price = std::numeric_limits<int64_t>::max();
            const int64_t full_effective = saturating_mul(
                building_days, input.quantity, _saturation_count);
            const int64_t purchase_scale_q16 = input_purchase_scale_q16(
                input, utilization_q16);
            if (purchase_scale_q16 <= 0) continue;
            const int64_t scaled_numerator = saturating_add(saturating_mul(
                full_effective, purchase_scale_q16, _saturation_count),
                Q16_ONE - 1, _saturation_count);
            const int64_t scaled_effective = scaled_numerator / Q16_ONE;
            for (int32_t c = input.candidate_begin;
                 c < input.candidate_begin + input.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (_good_storage_modes[candidate.good_id] != 0 ||
                !good_market_available(group.cell, candidate.good_id, frozen)) continue;
                const int32_t signal = market_signal_index(group.cell, candidate.good_id);
                if (signal < 0 || signal >= static_cast<int32_t>(
                        _production_input_reserve.size())) continue;
                const int64_t physical_numerator = saturating_add(saturating_mul(
                    scaled_effective, Q16_ONE, _saturation_count),
                    candidate.efficiency_q16 - 1, _saturation_count);
                const int64_t physical = effective_production_input_quantity(
                    cell, candidate.good_id,
                    physical_numerator / candidate.efficiency_q16,
                    _saturation_count);
                const int64_t available = std::max<int64_t>(0,
                    _market.stock[_market.index(market, candidate.good_id)] -
                    _production_input_reserve[signal]);
                const int64_t capacity_q16 = physical > 0
                    ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                        available, Q16_ONE, physical, _saturation_count))
                    : Q16_ONE;
                const int64_t unit_numerator = saturating_add(saturating_mul(
                    GOODS_SCALE, Q16_ONE, _saturation_count),
                    candidate.efficiency_q16 - 1, _saturation_count);
                const int64_t unit_physical = effective_production_input_quantity(
                    cell, candidate.good_id,
                    unit_numerator / candidate.efficiency_q16,
                    _saturation_count);
                const int64_t effective_price = mul_div_sat(
                    _market.price[_market.index(market, candidate.good_id)],
                    unit_physical, GOODS_SCALE, _saturation_count);
                if (capacity_q16 > best_capacity_q16 ||
                    (capacity_q16 == best_capacity_q16 &&
                     (effective_price < best_effective_price ||
                      (effective_price == best_effective_price &&
                       (selected < 0 || candidate.good_id <
                        _building_input_candidates[selected].good_id))))) {
                    selected = c;
                    selected_signal = signal;
                    selected_physical_qty = physical;
                    best_capacity_q16 = capacity_q16;
                    best_effective_price = effective_price;
                }
            }
            if (selected < 0) {
                executable_q16 = std::min<int64_t>(
                    executable_q16, soft_input_bound_q16(input, 0));
                continue;
            }
            const InputCandidate &candidate = _building_input_candidates[selected];
            selected_signals[i] = selected_signal;
            selected_physical[i] = selected_physical_qty;
            executable_q16 = std::min(executable_q16, best_capacity_q16);
            if (!produces_survival_food &&
                _survival_food_good_mask[candidate.good_id] != 0) {
                household_priority_bundle = true;
            }
        }
        // 多个候选槽可落到同一商品；按商品合并需求后再算整套配方上限，
        // 避免重复槽位预留量超过市场实存。
        for (int32_t i = 0; i < type.input_count; ++i) {
            const int32_t signal = selected_signals[i];
            if (signal < 0) continue;
            bool first_for_signal = true;
            int64_t combined_desired = 0;
            for (int32_t j = 0; j < type.input_count; ++j) {
                if (selected_signals[j] != signal) continue;
                if (j < i) first_for_signal = false;
                combined_desired = saturating_add(
                    combined_desired, selected_physical[j], _saturation_count);
            }
            if (!first_for_signal || combined_desired <= 0) continue;
            const int32_t good = _market_signals.good_ids[signal];
            const int64_t available = std::max<int64_t>(0,
                _market.stock[_market.index(market, good)] -
                _production_input_reserve[signal]);
            executable_q16 = std::min<int64_t>(executable_q16,
                std::min<int64_t>(Q16_ONE, mul_div_sat(
                    available, Q16_ONE, combined_desired, _saturation_count)));
        }
        // 家庭生存消费优先于非生存加工；此类加工只能使用家庭结算后的余量，
        // 因而整套互补投入都不提前保护。
        if (household_priority_bundle) executable_q16 = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const int32_t signal = selected_signals[i];
            const int64_t desired = selected_physical[i];
            if (signal < 0 || desired <= 0) continue;
            const int64_t reserved = mul_div_sat(
                desired, executable_q16, Q16_ONE, _saturation_count);
            _production_input_reserve[signal] = saturating_add(
                _production_input_reserve[signal], reserved, _saturation_count);
            _production_input_reserved = saturating_add(
                _production_input_reserved, reserved, _saturation_count);
            _production_input_reserve_shortfall = saturating_add(
                _production_input_reserve_shortfall,
                std::max<int64_t>(0, desired - reserved), _saturation_count);
        }
        }
    }
}

void NativeEconomyRuntime::build_demand_basis_cached(
        int32_t cell, int32_t market, const EnvironmentSample &sample,
        std::vector<int64_t> &variant_scores, std::vector<int64_t> &variant_prices,
        std::vector<int64_t> &need_score_sums, std::vector<int64_t> &need_composites,
        std::vector<int64_t> &need_environment, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count) {
        build_demand_basis(market, sample, variant_scores, variant_prices,
                           need_score_sums, need_composites, need_environment, sat);
        return;
    }
    const size_t variant_count = _variants.size();
    const size_t need_count = _needs.size();
    const size_t cells = static_cast<size_t>(_cell_count);
    if (_demand_basis_cache_day.size() != cells ||
        _demand_basis_variant_scores.size() != cells * variant_count ||
        _demand_basis_need_score_sums.size() != cells * need_count) {
        _demand_basis_cache_day.assign(
            cells, std::numeric_limits<int64_t>::min());
        _demand_basis_variant_scores.resize(cells * variant_count);
        _demand_basis_variant_prices.resize(cells * variant_count);
        _demand_basis_need_score_sums.resize(cells * need_count);
        _demand_basis_need_composites.resize(cells * need_count);
        _demand_basis_need_environment.resize(cells * need_count);
    }
    const size_t variant_offset = static_cast<size_t>(cell) * variant_count;
    const size_t need_offset = static_cast<size_t>(cell) * need_count;
    if (_demand_basis_cache_day[cell] != _sample_day) {
        build_demand_basis(market, sample, variant_scores, variant_prices,
                           need_score_sums, need_composites, need_environment, sat);
        std::copy(variant_scores.begin(), variant_scores.end(),
                  _demand_basis_variant_scores.begin() + variant_offset);
        std::copy(variant_prices.begin(), variant_prices.end(),
                  _demand_basis_variant_prices.begin() + variant_offset);
        std::copy(need_score_sums.begin(), need_score_sums.end(),
                  _demand_basis_need_score_sums.begin() + need_offset);
        std::copy(need_composites.begin(), need_composites.end(),
                  _demand_basis_need_composites.begin() + need_offset);
        std::copy(need_environment.begin(), need_environment.end(),
                  _demand_basis_need_environment.begin() + need_offset);
        _demand_basis_cache_day[cell] = _sample_day;
        return;
    }
    variant_scores.assign(
        _demand_basis_variant_scores.begin() + variant_offset,
        _demand_basis_variant_scores.begin() + variant_offset + variant_count);
    variant_prices.assign(
        _demand_basis_variant_prices.begin() + variant_offset,
        _demand_basis_variant_prices.begin() + variant_offset + variant_count);
    need_score_sums.assign(
        _demand_basis_need_score_sums.begin() + need_offset,
        _demand_basis_need_score_sums.begin() + need_offset + need_count);
    need_composites.assign(
        _demand_basis_need_composites.begin() + need_offset,
        _demand_basis_need_composites.begin() + need_offset + need_count);
    need_environment.assign(
        _demand_basis_need_environment.begin() + need_offset,
        _demand_basis_need_environment.begin() + need_offset + need_count);
}

void NativeEconomyRuntime::prepare_due_demand_basis_cache() {
    const int32_t cell_count = static_cast<int32_t>(_epoch_building_cells.size());
    if (cell_count <= 0) return;
    std::vector<int64_t> saturation_by_cell(static_cast<size_t>(cell_count), 0);
    const int32_t task_count = _worker_enabled &&
            cell_count >= _worker_market_threshold &&
            godot::WorkerThreadPool::get_singleton() != nullptr
        ? std::min<int32_t>(cell_count, _worker_tasks_hint > 0
            ? _worker_tasks_hint
            : std::clamp<int32_t>((cell_count + 127) / 128, 2, 16))
        : 1;
    auto prepare_range = [&](int32_t begin, int32_t end) {
        std::vector<int64_t> variant_scores;
        std::vector<int64_t> variant_prices;
        std::vector<int64_t> need_score_sums;
        std::vector<int64_t> need_composites;
        std::vector<int64_t> need_environment;
        for (int32_t index = begin; index < end; ++index) {
            const int32_t cell = _epoch_building_cells[index];
            const int32_t market = _market.cell_to_market[cell];
            int64_t local_saturation = 0;
            build_demand_basis(
                market, environment_sample_for_cell(cell), variant_scores,
                variant_prices, need_score_sums, need_composites,
                need_environment, local_saturation);
            const size_t variant_offset =
                static_cast<size_t>(cell) * _variants.size();
            const size_t need_offset =
                static_cast<size_t>(cell) * _needs.size();
            std::copy(variant_scores.begin(), variant_scores.end(),
                      _demand_basis_variant_scores.begin() + variant_offset);
            std::copy(variant_prices.begin(), variant_prices.end(),
                      _demand_basis_variant_prices.begin() + variant_offset);
            std::copy(need_score_sums.begin(), need_score_sums.end(),
                      _demand_basis_need_score_sums.begin() + need_offset);
            std::copy(need_composites.begin(), need_composites.end(),
                      _demand_basis_need_composites.begin() + need_offset);
            std::copy(need_environment.begin(), need_environment.end(),
                      _demand_basis_need_environment.begin() + need_offset);
            _demand_basis_cache_day[cell] = _sample_day;
            saturation_by_cell[index] = local_saturation;
        }
    };
    if (task_count > 1) {
        parallel_for_range("pk_economy_demand_basis", cell_count, task_count,
                           _worker_market_threshold, prepare_range);
    } else {
        prepare_range(0, cell_count);
    }
    for (const int64_t local_saturation : saturation_by_cell) {
        _saturation_count += local_saturation;
    }
}

void NativeEconomyRuntime::rebuild_labor_signals() {
    LaborMarketStore &next = _labor_signals_rebuild_scratch;
    next.clear(_cell_count);
    const size_t old_size = _labor_signals.profession_ids.size();
    next.profession_ids.reserve(old_size);
    next.base_living_cost.reserve(old_size);
    next.role_living_cost.reserve(old_size);
    next.contract_wage_ema.reserve(old_size);
    next.paid_wage_ema.reserve(old_size);
    next.job_days.reserve(old_size);
    next.pay_ratio_q16.reserve(old_size);
    if (_building_labor_signal_stamp.size() != _profession_ids.size()) {
        _building_labor_signal_stamp.assign(_profession_ids.size(), 0);
        _building_labor_signal_stamp_generation = 0;
    }
    auto next_stamp = [&]() {
        ++_building_labor_signal_stamp_generation;
        if (_building_labor_signal_stamp_generation == 0) {
            std::fill(_building_labor_signal_stamp.begin(),
                      _building_labor_signal_stamp.end(), 0);
            _building_labor_signal_stamp_generation = 1;
        }
        return _building_labor_signal_stamp_generation;
    };
    const bool old_shape_valid = _labor_signals.cell_offsets.size() ==
        static_cast<size_t>(_cell_count + 1) &&
        static_cast<size_t>(_labor_signals.cell_offsets.back()) <= old_size;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const uint32_t stamp = next_stamp();
        if (_building_cell_offsets.size() ==
                static_cast<size_t>(_cell_count + 1)) {
            for (int32_t group_index = _building_cell_offsets[cell];
                 group_index < _building_cell_offsets[cell + 1]; ++group_index) {
                const BuildingGroup &group = _buildings[group_index];
                if (group.count <= 0 || group.type_id < 0 ||
                    group.type_id >= static_cast<int32_t>(_building_types.size()))
                    continue;
                const BuildingType &type = _building_types[group.type_id];
                for (int32_t edge = type.labor_signal_begin;
                     edge < type.labor_signal_begin + type.labor_signal_count;
                     ++edge) {
                    _building_labor_signal_stamp[
                        _building_type_labor_signal_professions[edge]] = stamp;
                }
            }
        }
        const int32_t old_begin = old_shape_valid
            ? _labor_signals.cell_offsets[cell] : 0;
        const int32_t old_end = old_shape_valid
            ? _labor_signals.cell_offsets[cell + 1] : 0;
        int32_t old_cursor = old_begin;
        for (int32_t profession = 0;
             profession < static_cast<int32_t>(_profession_ids.size());
             ++profession) {
            if (_building_labor_signal_stamp[profession] != stamp) continue;
            while (old_cursor < old_end &&
                   _labor_signals.profession_ids[old_cursor] < profession)
                ++old_cursor;
            const bool found = old_cursor < old_end &&
                _labor_signals.profession_ids[old_cursor] == profession;
            next.profession_ids.push_back(profession);
            next.base_living_cost.push_back(found
                ? _labor_signals.base_living_cost[old_cursor] : 0);
            next.role_living_cost.push_back(found
                ? _labor_signals.role_living_cost[old_cursor] : 0);
            next.contract_wage_ema.push_back(found
                ? _labor_signals.contract_wage_ema[old_cursor] : 0);
            next.paid_wage_ema.push_back(found
                ? _labor_signals.paid_wage_ema[old_cursor] : 0);
            next.job_days.push_back(found
                ? _labor_signals.job_days[old_cursor] : 0);
            next.pay_ratio_q16.push_back(found
                ? _labor_signals.pay_ratio_q16[old_cursor] : Q16_ONE);
        }
        next.cell_offsets[cell + 1] = static_cast<int32_t>(
            next.profession_ids.size());
    }
    std::swap(_labor_signals, _labor_signals_rebuild_scratch);
}

int32_t NativeEconomyRuntime::labor_signal_index(int32_t cell, int32_t profession) const {
    if (cell < 0 || cell >= _cell_count ||
        _labor_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) return -1;
    const int32_t begin = _labor_signals.cell_offsets[cell];
    const int32_t end = _labor_signals.cell_offsets[cell + 1];
    const auto first = _labor_signals.profession_ids.begin() + begin;
    const auto last = _labor_signals.profession_ids.begin() + end;
    const auto it = std::lower_bound(first, last, profession);
    return it != last && *it == profession
        ? static_cast<int32_t>(it - _labor_signals.profession_ids.begin()) : -1;
}

int64_t NativeEconomyRuntime::living_cost_for_signature(
        int32_t cell, int32_t signature_id, int32_t plan_override, int64_t &sat) const {
    if (cell < 0 || cell >= _cell_count || signature_id < 0 ||
        signature_id >= static_cast<int32_t>(_signatures.size())) return 0;
    const Signature &signature = _signatures[signature_id];
    const int32_t plan_id = plan_override >= 0 ? plan_override : signature.plan_id;
    if (plan_id < 0 || plan_id >= static_cast<int32_t>(_plans.size())) return 0;
    const int32_t market = _market.cell_to_market[cell];
    const Plan &plan = _plans[plan_id];
    int64_t total = 0;
    for (int32_t n = 0; n < plan.need_count; ++n) {
        const int32_t need_index = plan.need_begin + n;
        const Need &need = _needs[need_index];
        if (need.living_cost_weight_q16 <= 0) continue;
        int64_t score_sum = 0;
        int64_t weighted_price = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const VariantChoice &variant = _variants[variant_id];
            const int64_t unit_price = variant_unit_price(market, variant_id, sat);
            const int64_t price_ratio = mul_div_sat(
                variant.reference_unit_price, Q16_ONE, unit_price, sat);
            int64_t score = mul_div_sat(
                variant.preference_q16,
                pow_q16(std::max<int64_t>(1, price_ratio),
                        variant.price_elasticity_q16, sat), Q16_ONE, sat);
            score = mul_div_sat(score,
                sample_environment_curve(variant.preference_env_curve, cell),
                Q16_ONE, sat);
            score = std::max<int64_t>(0, score);
            score_sum = saturating_add(score_sum, score, sat);
            weighted_price = saturating_add(weighted_price,
                saturating_mul(unit_price, score, sat), sat);
        }
        int64_t quantity = saturating_mul(
            need.base_qty_per_person, need.living_cost_weight_q16, sat) >> 16;
        quantity = saturating_mul(quantity,
            sample_environment_curve(need.quantity_env_curve, cell), sat) >> 16;
        const int32_t factor_index = signature.ethnicity_id *
            static_cast<int32_t>(_need_ids.size()) + need.stable_id;
        quantity = saturating_mul(quantity,
            _ethnicity_need_factor_q16[factor_index], sat) >> 16;
        if (quantity <= 0 || score_sum <= 0) continue;
        weighted_price /= score_sum;
        total = saturating_add(total, mul_div_sat(
            quantity, weighted_price, GOODS_SCALE, sat), sat);
    }
    return std::max<int64_t>(0, total);
}

void NativeEconomyRuntime::compute_cell_living_costs_from_basis(
        int32_t cell, const std::vector<int64_t> &variant_scores,
        const std::vector<int64_t> &variant_prices,
        const std::vector<int64_t> &need_score_sums,
        const std::vector<int64_t> &need_environment, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count) return;
    // Labor signals only exist where somebody employs somebody, but the
    // per-capita survival-plan cost is needed for every populated cell because
    // the savings satisfaction dimension normalizes against it.
    const bool labor_signals_ready =
        _labor_signals.cell_offsets.size() == static_cast<size_t>(_cell_count + 1) &&
        _labor_signals.cell_offsets[cell] != _labor_signals.cell_offsets[cell + 1];
    const int32_t ethnicity_count = static_cast<int32_t>(_ethnicity_ids.size());
    thread_local std::vector<int64_t> cache;
    thread_local std::vector<int32_t> cached_prices;
    thread_local int64_t cached_catalog_hash = 0;
    thread_local int32_t cached_temperature = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_moisture = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_snow = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_weather = std::numeric_limits<int32_t>::min();
    thread_local uint64_t cached_stock_presence = 0;
    const int32_t market = _market.cell_to_market[cell];
    const auto price_begin = _market.price.begin() +
        static_cast<int64_t>(market) * _market.good_count;
    const auto stock_begin = _market.stock.begin() +
        static_cast<int64_t>(market) * _market.good_count;
    // Living cost now depends on which goods are purchasable (stock > 0), so the
    // cache must invalidate when the in-stock set changes even if prices did not.
    // We only need the sign of each stock (a good's exact quantity does not move
    // living cost), so hash a purchasable-bitset rather than snapshotting stock.
    uint64_t stock_presence = 1469598103934665603ULL; // FNV-1a offset basis
    for (int32_t g = 0; g < _market.good_count; ++g) {
        const uint64_t bit = (*(stock_begin + g) > 0) ? 1ULL : 0ULL;
        stock_presence = (stock_presence ^ bit) * 1099511628211ULL;
    }
    const bool same_basis =
        cached_prices.size() == static_cast<size_t>(_market.good_count) &&
        cached_catalog_hash == _catalog_hash &&
        cached_temperature == _environment_temperature_q16[cell] &&
        cached_moisture == _environment_moisture_q16[cell] &&
        cached_snow == _environment_snow_q16[cell] &&
        cached_weather == _environment_weather_q16[cell] &&
        cached_stock_presence == stock_presence &&
        std::equal(cached_prices.begin(), cached_prices.end(), price_begin);
    if (!same_basis) {
        cached_prices.assign(price_begin, price_begin + _market.good_count);
        cached_catalog_hash = _catalog_hash;
        cached_temperature = _environment_temperature_q16[cell];
        cached_moisture = _environment_moisture_q16[cell];
        cached_snow = _environment_snow_q16[cell];
        cached_weather = _environment_weather_q16[cell];
        cached_stock_presence = stock_presence;
        cache.assign(_plans.size() * _ethnicity_ids.size(), -1);
    }
    auto cost = [&](int32_t signature_id, int32_t plan_override) {
        const Signature &signature = _signatures[signature_id];
        const int32_t plan_id = plan_override >= 0 ? plan_override : signature.plan_id;
        const size_t key = static_cast<size_t>(plan_id) * ethnicity_count +
                           signature.ethnicity_id;
        if (cache[key] >= 0) return cache[key];
        int64_t total = 0;
        const Plan &plan = _plans[plan_id];
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            const int64_t score_sum = need_score_sums[need_index];
            if (need.living_cost_weight_q16 <= 0 || score_sum <= 0) continue;
            // Living cost must reflect what a rational consumer would actually
            // pay to satisfy this need, not the average of every listed variant.
            // A variant whose components are out of stock (or a variant that has
            // spiked to a ceiling nobody trades at) is not a real option: the
            // consumer substitutes to a cheaper variant that is in stock (e.g.
            // gathered_plants / game_meat). We therefore aggregate ONLY over
            // in-stock variants, score-weighted for preference among the real
            // options, and clamp the result to a slack multiple of the cheapest
            // in-stock variant so a mid-priced substitute cannot inflate cost.
            int64_t avail_num = 0;      // Sum(price * score) over in-stock variants
            int64_t avail_score = 0;    // Sum(score) over in-stock variants
            int64_t avail_ref_num = 0;  // Sum(reference_price * score) over in-stock
            int64_t min_avail_price = 0; // Cheapest in-stock variant unit price
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant = need.variant_begin + v;
                // A variant is purchasable only if every component good has stock.
                const VariantChoice &vc = _variants[variant];
                bool in_stock = vc.component_count > 0;
                for (int32_t c = 0; c < vc.component_count; ++c) {
                    const NeedComponent &comp = _components[vc.component_begin + c];
                    if (_market.stock[_market.index(market, comp.good_id)] <= 0) {
                        in_stock = false;
                        break;
                    }
                }
                if (!in_stock) continue;
                const int64_t vp = variant_prices[variant];
                const int64_t vs = variant_scores[variant];
                avail_num = saturating_add(avail_num,
                    saturating_mul(vp, vs, sat), sat);
                avail_score = saturating_add(avail_score, vs, sat);
                avail_ref_num = saturating_add(avail_ref_num,
                    saturating_mul(vc.reference_unit_price, vs, sat), sat);
                if (min_avail_price == 0 || vp < min_avail_price) {
                    min_avail_price = vp;
                }
            }
            if (avail_score <= 0) {
                // Every variant of this need is out of stock: the consumer cannot
                // spend anything on it, so it contributes nothing to living cost.
                // (Wage floors should only cover goods people can actually buy;
                // an unpurchasable need does not create a real cost of living, and
                // its ghost/ceiling listing prices must not pollute the aggregate.
                // Genuine survival pressure comes from staple_food/protein having
                // no cheap in-stock substitute, which those needs handle directly.)
                continue;
            }
            int64_t weighted_price = avail_num / avail_score;
            // Clamp to 1.5x the cheapest in-stock option: consumers will not
            // pay far above the cheapest viable substitute they can actually buy.
            const int64_t price_cap = saturating_mul(
                min_avail_price, 98304 /* 1.5 in Q16 */, sat) >> 16;
            if (price_cap > 0 && weighted_price > price_cap) {
                weighted_price = price_cap;
            }
            // Essentialness cap: even if every in-stock variant is expensive, a
            // NON-essential need must not manufacture society-wide inflation. Only
            // the essential portion of a price rise feeds living cost (and thus the
            // wage floor). Essentialness is read from the need's demand floor
            // (price_quantity_floor_q16): a high floor means demand stays high even
            // when prices soar (a true necessity like staple grain, which should
            // track market price fully), while a zero floor means demand collapses
            // to nothing when prices rise (a discretionary need like protein/produce
            // with substitutes -- consumers simply stop buying, so it must not lift
            // the cost of living). floor is in [0, 0.5]; scale by 2 so a 0.5 floor
            // maps to full pass-through and 0 maps to no pass-through.
            // A free "buffer band" up to 1.5x the reference price passes through
            // unclamped: a mild price rise is normal and should be reflected even
            // for discretionary needs ("a little more expensive is fine"). Only
            // the portion ABOVE that band is throttled by essentialness, so a
            // runaway spike ("it soared, so I just stop buying") cannot inflate
            // the cost of living for a non-essential need.
            const int64_t ref_price = avail_ref_num / avail_score;
            const int64_t buffer_threshold =
                saturating_mul(ref_price, 98304 /* 1.5 in Q16 */, sat) >> 16;
            if (weighted_price > buffer_threshold && buffer_threshold > 0) {
                int64_t essential_q16 = saturating_mul(
                    need.price_quantity_floor_q16, 2, sat);
                if (essential_q16 > Q16_ONE) essential_q16 = Q16_ONE;
                if (essential_q16 < 0) essential_q16 = 0;
                const int64_t excess = weighted_price - buffer_threshold;
                const int64_t allowed_excess =
                    saturating_mul(excess, essential_q16, sat) >> 16;
                weighted_price = saturating_add(buffer_threshold, allowed_excess, sat);
            }
            int64_t quantity = saturating_mul(
                need.base_qty_per_person, need.living_cost_weight_q16, sat) >> 16;
            quantity = saturating_mul(
                quantity, need_environment[need_index], sat) >> 16;
            const int32_t factor = signature.ethnicity_id *
                static_cast<int32_t>(_need_ids.size()) + need.stable_id;
            quantity = saturating_mul(
                quantity, _ethnicity_need_factor_q16[factor], sat) >> 16;
            total = saturating_add(total, mul_div_sat(
                quantity, weighted_price, GOODS_SCALE, sat), sat);
        }
        cache[key] = std::max<int64_t>(0, total);
        return cache[key];
    };
    int64_t population_total = 0;
    int64_t general_weighted = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int64_t population = std::max<int64_t>(0, _population.population[slot]);
        if (population <= 0) return;
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        population_total = saturating_add(population_total, population, sat);
        general_weighted = saturating_add(general_weighted, saturating_mul(
            cost(signature, _living_cost_base_plan_id), population, sat), sat);
    });
    const int64_t general = population_total > 0
        ? general_weighted / population_total : 0;
    if (cell < static_cast<int32_t>(_cell_living_cost_per_capita.size()))
        _cell_living_cost_per_capita[cell] = general;
    if (!labor_signals_ready) return;
    for (int32_t signal = _labor_signals.cell_offsets[cell];
         signal < _labor_signals.cell_offsets[cell + 1]; ++signal) {
        const int32_t profession = _labor_signals.profession_ids[signal];
        int64_t employed = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
            if (_signatures[signature].profession_id == profession)
                employed = saturating_add(employed,
                    std::max<int64_t>(0, _population.employee_employed[slot]), sat);
        });
        int64_t weight_total = 0;
        int64_t weighted = 0;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
            if (_signatures[signature].profession_id != profession) return;
            const int64_t weight = employed > 0
                ? std::max<int64_t>(0, _population.employee_employed[slot])
                : std::max<int64_t>(0, _population.population[slot]);
            if (weight <= 0) return;
            weight_total = saturating_add(weight_total, weight, sat);
            weighted = saturating_add(weighted,
                saturating_mul(cost(signature, -1), weight, sat), sat);
        });
        _labor_signals.base_living_cost[signal] = general;
        _labor_signals.role_living_cost[signal] =
            weight_total > 0 ? weighted / weight_total : 0;
    }
}

// Building wage planning and labor signal updates live in
// economy_runtime_building_employment.cpp.

// Production climate capacity helpers live in
// economy_runtime_building_production.cpp.

bool NativeEconomyRuntime::prepare_building_economic_plan(
        int32_t active_begin, int32_t active_end,
        const std::vector<int32_t> *cells_override,
        BuildingPlanResult &result, std::string &error) {
    result.reset();
    // These locals intentionally shadow epoch diagnostics. Cell/group state is
    // disjoint across worker ranges; diagnostics are reduced serially by the
    // caller after every task has completed.
    int64_t _saturation_count = 0;
    int64_t _merchant_credit_budget = 0;
    int64_t _merchant_credit_committed = 0;
    int64_t _recovery_candidates = 0;
    int64_t _recovery_approved = 0;
    int64_t _loss_suspended_building_groups = 0;
    int64_t _unprofitable_building_groups = 0;
    int64_t _utilization_sum_q16 = 0;
    auto publish_result = [&]() {
        result.saturation_count = _saturation_count;
        result.merchant_credit_budget = _merchant_credit_budget;
        result.merchant_credit_committed = _merchant_credit_committed;
        result.recovery_candidates = _recovery_candidates;
        result.recovery_approved = _recovery_approved;
        result.loss_suspended_building_groups =
            _loss_suspended_building_groups;
        result.unprofitable_building_groups =
            _unprofitable_building_groups;
        result.utilization_sum_q16 = _utilization_sum_q16;
    };
    constexpr int64_t DISCARD_RATE_TOLERANCE_Q16 = Q16_ONE / 100;
    constexpr int64_t HIGH_DISCARD_RATE_Q16 = Q16_ONE / 4;
    constexpr int64_t SEVERE_DISCARD_RATE_Q16 = Q16_ONE / 2;
    constexpr int64_t SHORTAGE_RECOVERY_THRESHOLD_Q16 = Q16_ONE / 8;
    constexpr int64_t STOCK_ROUNDING_TOLERANCE = 1;
    // 同一业主的生存食物产能合并计算，只保护跨过饥饿阈值所需的最低利用率。
    const std::vector<int32_t> &active_cells = cells_override != nullptr
        ? *cells_override
        : (_epoch_active ? _epoch_building_cells : _building_active_cells);
    active_begin = std::clamp<int32_t>(
        active_begin, 0, static_cast<int32_t>(active_cells.size()));
    active_end = std::clamp<int32_t>(
        active_end, active_begin, static_cast<int32_t>(active_cells.size()));
    thread_local std::vector<int32_t> owner_seen_cell;
    thread_local std::vector<uint8_t> owner_output_flags;
    thread_local std::vector<int64_t> owner_relevant_output;
    thread_local std::vector<int64_t> owner_floor_q16;
    thread_local std::vector<int64_t> owner_clothing_output;
    thread_local std::vector<int64_t> owner_clothing_floor_q16;
    thread_local std::vector<int32_t> touched_owners;
    // Legacy probe planner storage is retained only so old object files and
    // save diagnostics stay ABI-compatible. The planner branch below is
    // permanently disabled; suspended buildings never purchase or produce.
    thread_local std::vector<std::pair<int32_t, int64_t>> recovery_probe_goods;
    owner_seen_cell.assign(_signatures.size(), -1);
    owner_output_flags.resize(_signatures.size());
    owner_relevant_output.resize(_signatures.size());
    owner_floor_q16.resize(_signatures.size());
    owner_clothing_output.resize(_signatures.size());
    owner_clothing_floor_q16.resize(_signatures.size());
    if (_building_cell_offsets.size() == static_cast<size_t>(_cell_count + 1)) {
        for (int32_t active = active_begin; active < active_end; ++active) {
            const int32_t cell = active_cells[active];
            const int32_t begin = _building_cell_offsets[cell];
            const int32_t end = _building_cell_offsets[cell + 1];
            touched_owners.clear();
            for (int32_t g = begin; g < end; ++g) {
                const BuildingGroup &group = _buildings[g];
                if (group.count <= 0 || group.operating_state != 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                if (group.owner_signature_id < 0 || group.owner_signature_id >=
                        static_cast<int32_t>(owner_seen_cell.size())) continue;
                const int32_t owner = group.owner_signature_id;
                if (owner_seen_cell[owner] != cell) {
                    owner_seen_cell[owner] = cell;
                    owner_output_flags[owner] = 0;
                    owner_relevant_output[owner] = 0;
                    owner_floor_q16[owner] = 0;
                    owner_clothing_output[owner] = 0;
                    owner_clothing_floor_q16[owner] = 0;
                    touched_owners.push_back(owner);
                }
                const BuildingType &type = _building_types[group.type_id];
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t good = _building_outputs[type.output_begin + i].good_id;
                    if (_survival_food_good_mask[good] != 0)
                        owner_output_flags[owner] |= 1;
                    if (_survival_clothing_good_mask[good] != 0)
                        owner_output_flags[owner] |= 4;
                }
            }
            for (int32_t g = begin; g < end; ++g) {
                const BuildingGroup &group = _buildings[g];
                if (group.count <= 0 || group.operating_state != 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                const int32_t owner = group.owner_signature_id;
                if (owner < 0 || owner >= static_cast<int32_t>(owner_seen_cell.size()) ||
                    owner_seen_cell[owner] != cell || (owner_output_flags[owner] & 5) == 0)
                    continue;
                const BuildingType &type = _building_types[group.type_id];
                int64_t group_relevant_output = 0;
                int64_t group_clothing_output = 0;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const GoodAmount &output = _building_outputs[type.output_begin + i];
                    const bool relevant = _survival_food_good_mask[output.good_id] != 0;
                    const int64_t full_output =
                        effective_building_output_quantity(
                            group, output.good_id, output.quantity, Q16_ONE,
                            saturating_mul(group.count,
                                std::max(1, _epoch_days), _saturation_count),
                            _saturation_count);
                    if (relevant) group_relevant_output = saturating_add(
                        group_relevant_output, full_output, _saturation_count);
                    if (_survival_clothing_good_mask[output.good_id] != 0)
                        group_clothing_output = saturating_add(
                            group_clothing_output, full_output, _saturation_count);
                }
                if (group_relevant_output > 0) {
                    owner_relevant_output[owner] = saturating_add(
                        owner_relevant_output[owner], group_relevant_output,
                        _saturation_count);
                }
                if (group_clothing_output > 0) {
                    owner_clothing_output[owner] = saturating_add(
                        owner_clothing_output[owner], group_clothing_output,
                        _saturation_count);
                }
            }
            const EnvironmentSample environment = environment_sample_for_cell(cell);
            for (const int32_t owner : touched_owners) {
                const int64_t full_relevant_output = owner_relevant_output[owner];
                if ((owner_output_flags[owner] & 1) == 0 || full_relevant_output <= 0)
                    continue;
                const int32_t owner_slot = find_cohort_slot(
                    cell, owner);
                if (owner_slot < 0 || _population.population[owner_slot] <= 0) continue;
                int64_t required_food = 0;
                for (int32_t stable_need : _survival_food_need_stable_ids) {
                    required_food = saturating_add(required_food,
                        survival_required_units(owner_slot, stable_need,
                            _epoch_days, environment, _saturation_count),
                        _saturation_count);
                }
                const int64_t protected_food = saturating_add(saturating_mul(
                    required_food, _survival_production_target_q16,
                    _saturation_count), Q16_ONE - 1, _saturation_count) / Q16_ONE;
                const int64_t floor_q16 = std::clamp<int64_t>(
                    saturating_add(saturating_mul(protected_food, Q16_ONE,
                        _saturation_count), full_relevant_output - 1,
                        _saturation_count) / full_relevant_output,
                    0, Q16_ONE);
                owner_floor_q16[owner] = floor_q16;
                const int64_t full_clothing_output = owner_clothing_output[owner];
                if ((owner_output_flags[owner] & 4) != 0 && full_clothing_output > 0) {
                    const int64_t required_clothing = survival_required_units(
                        owner_slot, _survival_clothing_need_stable_id,
                        _epoch_days, environment, _saturation_count);
                    owner_clothing_floor_q16[owner] = std::clamp<int64_t>(
                        saturating_add(saturating_mul(required_clothing, Q16_ONE,
                            _saturation_count), full_clothing_output - 1,
                            _saturation_count) / full_clothing_output,
                        0, Q16_ONE);
                }
            }
            for (int32_t g = begin; g < end; ++g) {
                const BuildingGroup &group = _buildings[g];
                const int32_t owner = group.owner_signature_id;
                if (group.count <= 0 || group.operating_state != 0 ||
                    owner < 0 || owner >= static_cast<int32_t>(owner_seen_cell.size()) ||
                    owner_seen_cell[owner] != cell || owner_floor_q16[owner] <= 0 ||
                    !building_available(cell, group.type_id, true)) continue;
                const BuildingType &type = _building_types[group.type_id];
                int64_t group_floor_q16 = 0;
                for (int32_t i = 0; i < type.output_count; ++i) {
                    const int32_t good = _building_outputs[type.output_begin + i].good_id;
                    if (_survival_food_good_mask[good] != 0) {
                        group_floor_q16 = std::max(
                            group_floor_q16, owner_floor_q16[owner]);
                    }
                    if (_survival_clothing_good_mask[good] != 0)
                        group_floor_q16 = std::max(
                            group_floor_q16, owner_clothing_floor_q16[owner]);
                }
                _building_survival_utilization_floor_q16[g] = group_floor_q16;
            }
        }
    }
    for (int32_t active = active_begin; active < active_end; ++active) {
        const int32_t cell = active_cells[active];
        const int32_t group_begin = _building_cell_offsets[cell];
        const int32_t group_end = _building_cell_offsets[cell + 1];
        int64_t merchant_opening_cash = 0;
        for (int32_t k = _merchant_offsets[cell]; k < _merchant_offsets[cell + 1]; ++k) {
            merchant_opening_cash = saturating_add(
                merchant_opening_cash,
                std::max<int64_t>(0, _population.funds[_merchant_slots[k]]),
                _saturation_count);
        }
        int64_t outstanding_principal = 0;
        for (int32_t g = group_begin; g < group_end; ++g) {
            outstanding_principal = saturating_add(
                outstanding_principal,
                std::max<int64_t>(0, _buildings[g].merchant_debt_principal),
                _saturation_count);
        }
        if (_pending_construction_cell_offsets.size() ==
                static_cast<size_t>(_cell_count + 1)) {
            for (int32_t cursor = _pending_construction_cell_offsets[cell];
                 cursor < _pending_construction_cell_offsets[cell + 1]; ++cursor) {
                const PendingConstruction &pending = _pending_construction[
                    _pending_construction_cell_indices[cursor]];
                outstanding_principal = saturating_add(
                    outstanding_principal,
                    std::max<int64_t>(0, pending.merchant_debt_principal),
                    _saturation_count);
            }
        } else {
            for (const PendingConstruction &pending : _pending_construction) {
                if (pending.cell != cell) continue;
                outstanding_principal = saturating_add(
                    outstanding_principal,
                    std::max<int64_t>(0, pending.merchant_debt_principal),
                    _saturation_count);
            }
        }
        const int64_t exposure_limit = mul_div_sat(
            merchant_opening_cash, _merchant_credit_exposure_q16,
            Q16_ONE, _saturation_count);
        const int64_t procurement_reserve = mul_div_sat(
            merchant_opening_cash, _merchant_procurement_cash_reserve_q16,
            Q16_ONE, _saturation_count);
        int64_t cell_credit_remaining = std::max<int64_t>(0, std::min(
            exposure_limit - std::min(exposure_limit, outstanding_principal),
            merchant_opening_cash - std::min(merchant_opening_cash, procurement_reserve)));
        _merchant_credit_budget = saturating_add(
            _merchant_credit_budget, cell_credit_remaining, _saturation_count);
        struct RecoveryPlanOrder {
            int32_t group = -1;
            int32_t survival_shortage_q16 = 0;
            int64_t downstream_shortage = 0;
            int64_t cash_free_flow = 0;
            int64_t economic_profit = 0;
            int64_t required_credit = 0;
        };
        thread_local std::vector<RecoveryPlanOrder> group_order;
        group_order.clear();
        if (group_order.capacity() <
                static_cast<size_t>(group_end - group_begin)) {
            group_order.reserve(static_cast<size_t>(group_end - group_begin));
        }
        for (int32_t g = group_begin; g < group_end; ++g) {
            const BuildingGroup &candidate = _buildings[g];
            RecoveryPlanOrder order;
            order.group = g;
            if (candidate.operating_state == 1 && candidate.type_id >= 0 &&
                candidate.type_id < static_cast<int32_t>(_building_types.size())) {
                const BuildingType &candidate_type = _building_types[candidate.type_id];
                for (int32_t i = 0; i < candidate_type.output_count; ++i) {
                    const int32_t good = _building_outputs[
                        candidate_type.output_begin + i].good_id;
                    const int64_t market_index = _market.index(cell, good);
                    if (_survival_food_good_mask[good] != 0 ||
                        _survival_clothing_good_mask[good] != 0) {
                        order.survival_shortage_q16 = std::max<int32_t>(
                            order.survival_shortage_q16,
                            _market.last_shortage_q16[market_index]);
                    }
                    const int32_t signal = market_signal_index(cell, good);
                    if (signal >= 0) {
                        order.downstream_shortage = saturating_add(
                            order.downstream_shortage,
                            _market_signals.business_demand_ema[signal],
                            _saturation_count);
                    }
                }
                int64_t due_sat = 0;
                const int64_t debt_due = building_debt_due(candidate, due_sat);
                _saturation_count = saturating_add(
                    _saturation_count, due_sat, _saturation_count);
                const int64_t cash_cost = saturating_add(
                    saturating_add(candidate.last_input_cost,
                        candidate.last_base_wages_due, _saturation_count),
                    debt_due, _saturation_count);
                order.cash_free_flow = saturating_sub(
                    candidate.last_revenue, cash_cost, _saturation_count);
                order.economic_profit = saturating_sub(saturating_add(
                    candidate.last_revenue,
                    candidate.last_in_kind_livelihood_value,
                    _saturation_count), cash_cost, _saturation_count);
                int64_t probe_cost = saturating_mul(
                    saturating_mul(candidate.sample_unit_input_cost,
                        candidate.count, _saturation_count),
                    std::max(1, _epoch_days), _saturation_count);
                probe_cost /= 32;
                const int32_t owner_slot = find_cohort_slot(
                    cell, candidate.owner_signature_id);
                const int64_t owner_cash = owner_slot >= 0
                    ? std::max<int64_t>(0, _population.funds[owner_slot]) : 0;
                order.required_credit = std::max<int64_t>(
                    0, probe_cost - std::min(probe_cost, owner_cash));
            }
            group_order.push_back(order);
        }
        std::stable_sort(group_order.begin(), group_order.end(),
            [&](const RecoveryPlanOrder &a, const RecoveryPlanOrder &b) {
                const bool a_recovery = _buildings[a.group].operating_state == 1;
                const bool b_recovery = _buildings[b.group].operating_state == 1;
                if (a_recovery != b_recovery) return a_recovery;
                if (!a_recovery) return a.group < b.group;
                if (a.survival_shortage_q16 != b.survival_shortage_q16)
                    return a.survival_shortage_q16 > b.survival_shortage_q16;
                if (a.downstream_shortage != b.downstream_shortage)
                    return a.downstream_shortage > b.downstream_shortage;
                if (a.cash_free_flow != b.cash_free_flow)
                    return a.cash_free_flow > b.cash_free_flow;
                if (a.economic_profit != b.economic_profit)
                    return a.economic_profit > b.economic_profit;
                if (a.required_credit != b.required_credit)
                    return a.required_credit < b.required_credit;
                return a.group < b.group;
            });
        for (const RecoveryPlanOrder &order : group_order) {
        const int32_t group_index = order.group;
        BuildingGroup &group = _buildings[group_index];
        if (group.count <= 0 || group.cell < 0 || group.cell >= _cell_count ||
            group.type_id < 0 || group.type_id >= static_cast<int32_t>(_building_types.size())) {
            error = "building_economic_plan_group_invalid";
            result.ok = false;
            result.error = error;
            publish_result();
            return false;
        }
        const BuildingType &type = _building_types[group.type_id];
        // RECOVERY_PROBE was removed from the public lifecycle. Old saves may
        // still carry state 2; treat it as an ordinary suspended building and
        // clear every probe-only lane before evaluating the new restart gate.
        if (group.operating_state == 2) {
            group.operating_state = 1;
            group.pending_operating_state = 255;
            group.recovery_cycles = 0;
            group.recovery_cooldown_cycles = 0;
        }
        prepare_group_climate_capacity(group, type);
        if (type.kind == 2) {
            // Service buildings (currently merchant posts) do not settle
            // production inputs/outputs and therefore have no meaningful
            // production profit margin. Keep them outside the producer loss,
            // recovery and liquidation state machine, including old saves that
            // captured a service in a suspended state.
            group.operating_state = 0;
            group.severe_loss_cycles = 0;
            group.recovery_cycles = 0;
            group.recovery_failed_reviews = 0;
            group.pending_operating_state = 255;
            group.recovery_cooldown_cycles = 0;
        }
        bool produces_cycle_flow = false;
        bool produces_survival_food = false;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            produces_cycle_flow = produces_cycle_flow || _good_storage_modes[good] == 1;
            produces_survival_food = produces_survival_food ||
                _survival_food_good_mask[good] != 0;
        }
        if (!building_available(group.cell, group.type_id, true)) {
            group.sample_unit_input_cost = 0;
            group.last_margin_gap_q16 = 0;
            group.planned_utilization_q16 = 0;
            group.purchase_intent_capacity_q16 = 0;
            group.recovery_cycles = 0;
            group.last_expected_revenue = 0;
            if (group.operating_state != 0) ++_loss_suspended_building_groups;
            continue;
        }
        const int32_t market = _market.cell_to_market[group.cell];
        int64_t input_cost = 0;
        int64_t employee_wages = 0;
        const int64_t owner_living_cost = saturating_mul(
            living_cost_for_signature(group.cell, group.owner_signature_id, -1,
                                      _saturation_count),
            type.owner_slots_per_building, _saturation_count);
        int64_t revenue = 0;
        bool inputs_available = true;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            int64_t best_effective_price = std::numeric_limits<int64_t>::max();
            for (int32_t c = item.candidate_begin;
                 c < item.candidate_begin + item.candidate_count; ++c) {
                const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_market_available(group.cell, candidate.good_id, true)) continue;
                const int64_t physical_numerator = saturating_add(
                    saturating_mul(item.quantity, Q16_ONE, _saturation_count),
                    candidate.efficiency_q16 - 1, _saturation_count);
                const int64_t physical = effective_production_input_quantity(
                    group.cell, candidate.good_id,
                    physical_numerator / candidate.efficiency_q16,
                    _saturation_count);
                const int64_t candidate_cost = mul_div_sat(
                    physical,
                    _market.price[_market.index(market, candidate.good_id)],
                    GOODS_SCALE, _saturation_count);
                best_effective_price = std::min(best_effective_price, candidate_cost);
            }
            if (best_effective_price == std::numeric_limits<int64_t>::max()) {
                if (item.required_q16 >= Q16_ONE) {
                    inputs_available = false;
                    break;
                }
                continue;
            }
            input_cost = saturating_add(
                input_cost, best_effective_price, _saturation_count);
        }
        if (!inputs_available) {
            group.sample_unit_input_cost = 0;
            group.last_margin_gap_q16 = -Q16_ONE;
            group.planned_utilization_q16 = 0;
            group.purchase_intent_capacity_q16 = 0;
            group.recovery_cycles = 0;
            group.last_expected_revenue = 0;
            if (type.kind != 2 && group.operating_state == 2) {
                group.operating_state = 1;
                group.pending_operating_state = 255;
            }
            // Missing a technologically available hard input is a recoverable
            // execution blockage, not evidence of a realized operating loss.
            // Keep the installed group active/idle so it retains a labor claim
            // and can resume as soon as the input chain supplies it.
            if (type.kind != 2 && group.operating_state == 0)
                group.severe_loss_cycles = 0;
            if (group.operating_state != 0) ++_loss_suspended_building_groups;
            continue;
        }
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            const int32_t role_index = group.employee_fill_begin + r;
            const int64_t wage = role_index >= 0 &&
                role_index < static_cast<int32_t>(_building_role_contract_wage.size())
                    ? _building_role_contract_wage[role_index]
                    : role.reference_wage_per_day;
            employee_wages = saturating_add(employee_wages, saturating_mul(
                role.slots_per_building, wage,
                _saturation_count), _saturation_count);
        }
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &item = _building_outputs[type.output_begin + i];
            int64_t settlement = _good_monetary_issue_values[item.good_id];
            if (settlement <= 0) {
                const int32_t output_signal = market_signal_index(
                    group.cell, item.good_id);
                const int32_t output_flow = trade_flow_index(
                    group.cell, item.good_id, false);
                const int64_t output_target = merchant_inventory_target(
                    market, item.good_id, output_signal,
                    output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                        output_signal] : 0,
                    output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                    item.quantity, _saturation_count);
                const int32_t buy_factor = effective_merchant_buy_factor_q16(
                    market, item.good_id, output_target,
                    _market.stock[_market.index(market, item.good_id)],
                    _saturation_count);
                settlement = mul_div_sat(
                    _market.price[_market.index(market, item.good_id)],
                    buy_factor, Q16_ONE, _saturation_count);
            }
            revenue = saturating_add(revenue, mul_div_sat(
                item.quantity, settlement, GOODS_SCALE, _saturation_count),
                _saturation_count);
        }
        const int64_t operating = saturating_add(saturating_add(
            input_cost, employee_wages, _saturation_count),
            owner_living_cost, _saturation_count);
        const int64_t required = saturating_add(operating, mul_div_sat(
            operating, type.target_operating_margin_q16, Q16_ONE,
            _saturation_count), _saturation_count);
        int64_t margin_gap = required <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, required, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, required), _saturation_count);
        margin_gap = std::clamp<int64_t>(margin_gap, -Q16_ONE, Q16_ONE);
        int64_t expected_profit_margin = operating <= 0 ? (revenue > 0 ? Q16_ONE : 0) :
            mul_div_sat(saturating_sub(revenue, operating, _saturation_count), Q16_ONE,
                        std::max<int64_t>(MONEY_SCALE, operating), _saturation_count);
        expected_profit_margin = std::clamp<int64_t>(
            expected_profit_margin, -Q16_ONE, Q16_ONE);
        group.sample_unit_input_cost = input_cost;
        group.last_margin_gap_q16 = static_cast<int32_t>(margin_gap);
        bool suspended_now = false;
        if (type.kind != 2 && group.operating_state == 0) {
            // realized_profit_margin_q16 already uses the complete viability
            // denominator: inputs + base wages + owner livelihood - retained
            // livelihood credit. Do not gate the lifecycle on last_operating_cost,
            // which excludes owner livelihood and is commonly zero for
            // owner-operated workshops.
            const bool settled_production = group.last_output > 0 ||
                group.last_input > 0 || group.last_resource > 0 ||
                group.last_resource_generated > 0;
            const int64_t owner_business_income = saturating_add(
                group.last_revenue,
                std::max<int64_t>(0, group.last_in_kind_livelihood_value),
                _saturation_count);
            const int64_t owner_business_cost = saturating_add(
                group.last_input_cost, group.last_base_wages_due,
                _saturation_count);
            const bool positive_self_employment = type.employee_count == 0 &&
                owner_business_income > owner_business_cost;
            const bool realized_severe_loss = settled_production &&
                !positive_self_employment &&
                group.realized_profit_margin_q16 <=
                    _building_severe_loss_threshold_q16;
            if (realized_severe_loss) {
                group.severe_loss_cycles = static_cast<uint16_t>(std::min<int32_t>(
                    65535, static_cast<int32_t>(group.severe_loss_cycles) + 1));
            } else {
                // Zero settlement covers labor, input, resource and financing
                // blockages. None is a realized loss observation.
                group.severe_loss_cycles = 0;
            }
            group.pending_operating_state = 255;
            group.recovery_cooldown_cycles = 0;
            if (group.severe_loss_cycles >= _building_severe_loss_cycles) {
                group.operating_state = 1;
                group.recovery_cycles = 0;
                suspended_now = true;
            }
        }
        if (type.kind != 2 && group.operating_state == 1 && !suspended_now &&
            group.recovery_cooldown_cycles == 0) {
            ++_recovery_candidates;
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days), _saturation_count);
            bool physical_inputs_available = true;
            for (int32_t i = 0; i < type.input_count && physical_inputs_available; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                bool candidate_available = false;
                for (int32_t c = item.candidate_begin;
                     c < item.candidate_begin + item.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                    if (!good_market_available(group.cell, candidate.good_id, true)) continue;
                    int64_t physical = mul_div_sat(effective, Q16_ONE,
                        std::max<int32_t>(1, candidate.efficiency_q16),
                        _saturation_count);
                    if (mul_div_sat(physical, candidate.efficiency_q16,
                            Q16_ONE, _saturation_count) < effective)
                        physical = saturating_add(physical, 1, _saturation_count);
                    physical = effective_production_input_quantity(
                        group.cell, candidate.good_id, physical, _saturation_count);
                    if (_market.stock[_market.index(market, candidate.good_id)] >= physical) {
                        candidate_available = true;
                        break;
                    }
                }
                physical_inputs_available = candidate_available;
            }
            bool physical_resources_available = true;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item = _building_resources[type.resource_begin + i];
                    const int64_t raw_base = item.mode == 1
                        ? saturating_mul(group.count, item.quantity, _saturation_count)
                        : saturating_mul(building_days, item.quantity, _saturation_count);
                    const int64_t base = effective_resource_use_quantity(
                        group.cell, item.resource_id, raw_base, _saturation_count);
                    if (base > available_resource_amount(item, group.cell)) {
                        physical_resources_available = false;
                        break;
                    }
                }
            }
            const int32_t owner_slot = find_cohort_slot(
                group.cell, group.owner_signature_id);
            const int64_t owner_slot_cash = owner_slot >= 0
                ? std::max<int64_t>(0, _population.funds[owner_slot]) : 0;
            const int64_t restart_cost = saturating_add(
                saturating_add(saturating_mul(input_cost, building_days,
                    _saturation_count), saturating_mul(employee_wages,
                    building_days, _saturation_count), _saturation_count),
                saturating_mul(owner_living_cost, building_days,
                    _saturation_count), _saturation_count);
            const int64_t credit_needed = std::max<int64_t>(0,
                restart_cost - std::min(restart_cost, owner_slot_cash));
            const bool finance_available = credit_needed == 0 ||
                (_merchant_credit_runtime_mode != 0 &&
                 group.merchant_debt_delinquent_cycles == 0 &&
                 credit_needed <= cell_credit_remaining);
            const bool executable = physical_inputs_available &&
                physical_resources_available && finance_available;
            if (group_index < static_cast<int32_t>(
                    _building_recovery_liquidation_eligible.size())) {
                _building_recovery_liquidation_eligible[group_index] =
                    executable && expected_profit_margin < _building_restart_margin_q16;
            }
            const bool viable = executable &&
                expected_profit_margin >= _building_restart_margin_q16;
            if (viable) {
                group.pending_operating_state = 0;
                group.severe_loss_cycles = 0;
                group.recovery_failed_reviews = 0;
                group.recovery_cooldown_cycles = 0;
                if (credit_needed > 0) {
                    _building_merchant_credit_limit[group_index] = credit_needed;
                    _merchant_credit_committed = saturating_add(
                        _merchant_credit_committed, credit_needed, _saturation_count);
                    cell_credit_remaining -= credit_needed;
                }
                ++_recovery_approved;
                ++_recovery_restarted;
            }
        }
        constexpr int64_t recovery_probe_floor_q16 = 0;
        if (false && type.kind != 2 && group.operating_state == 1 && !suspended_now &&
            group.recovery_cooldown_cycles == 0) {
            const int32_t owner_slot = find_cohort_slot(group.cell, group.owner_signature_id);
            ++_recovery_candidates;
            const int64_t restart_input_cost = mul_div_sat(saturating_mul(
                saturating_mul(input_cost, group.count, _saturation_count),
                std::max(1, _epoch_days), _saturation_count),
                recovery_probe_floor_q16, Q16_ONE, _saturation_count);
            const int64_t owner_cash = owner_slot >= 0
                ? std::max<int64_t>(0, _population.funds[owner_slot]) : 0;
            const int64_t credit_needed = std::max<int64_t>(
                0, restart_input_cost - std::min(restart_input_cost, owner_cash));
            const bool credit_allowed = group.merchant_debt_delinquent_cycles == 0 &&
                credit_needed <= cell_credit_remaining;
            const bool finance_available = credit_needed == 0 ||
                (_merchant_credit_runtime_mode != 0 && credit_allowed);
            bool physical_inputs_available = inputs_available;
            recovery_probe_goods.clear();
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days), _saturation_count);
            for (int32_t i = 0; physical_inputs_available && i < type.input_count; ++i) {
                const ProductionInput &item = _building_inputs[type.input_begin + i];
                const int64_t required_q16 = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required_q16 <= 0) continue;
                const int64_t floor_q16 = Q16_ONE - required_q16;
                if (recovery_probe_floor_q16 <= floor_q16) continue;
                const int64_t purchase_scale_q16 = std::min<int64_t>(Q16_ONE,
                    mul_div_sat(recovery_probe_floor_q16 - floor_q16,
                        Q16_ONE, required_q16, _saturation_count));
                const int64_t effective = saturating_mul(
                    building_days, item.quantity, _saturation_count);
                int32_t selected_good = -1;
                int64_t selected_quantity = 0;
                int64_t best_spare = -1;
                bool best_sufficient = false;
                int64_t best_effective_price = std::numeric_limits<int64_t>::max();
                for (int32_t c = item.candidate_begin;
                     c < item.candidate_begin + item.candidate_count; ++c) {
                    const InputCandidate &candidate = _building_input_candidates[c];
                if (!good_market_available(group.cell, candidate.good_id, true)) continue;
                    int64_t physical = mul_div_sat(
                        effective, Q16_ONE, candidate.efficiency_q16,
                        _saturation_count);
                    if (mul_div_sat(physical, candidate.efficiency_q16, Q16_ONE,
                                    _saturation_count) < effective) {
                        physical = saturating_add(physical, 1, _saturation_count);
                    }
                    physical = effective_production_input_quantity(
                        group.cell, candidate.good_id, physical,
                        _saturation_count);
                    int64_t quantity = saturating_add(saturating_mul(
                        physical, purchase_scale_q16, _saturation_count),
                        Q16_ONE - 1, _saturation_count) / Q16_ONE;
                    quantity = std::max<int64_t>(1, quantity);
                    int64_t reserved = 0;
                    for (const auto &entry : recovery_probe_goods) {
                        if (entry.first == candidate.good_id) reserved = entry.second;
                    }
                    const int64_t spare = std::max<int64_t>(0,
                        _market.stock[_market.index(market, candidate.good_id)] - reserved);
                    const int64_t unit_numerator = saturating_add(saturating_mul(
                        GOODS_SCALE, Q16_ONE, _saturation_count),
                        candidate.efficiency_q16 - 1, _saturation_count);
                    const int64_t unit_physical = effective_production_input_quantity(
                        group.cell, candidate.good_id,
                        unit_numerator / candidate.efficiency_q16,
                        _saturation_count);
                    const int64_t effective_price = mul_div_sat(
                        _market.price[_market.index(market, candidate.good_id)],
                        unit_physical, GOODS_SCALE, _saturation_count);
                    const bool sufficient = spare >= quantity;
                    if (sufficient != best_sufficient ? sufficient :
                        (spare > best_spare ||
                         (spare == best_spare &&
                          effective_price < best_effective_price))) {
                        selected_good = candidate.good_id;
                        selected_quantity = quantity;
                        best_spare = spare;
                        best_sufficient = sufficient;
                        best_effective_price = effective_price;
                    }
                }
                if (selected_good < 0 || best_spare < selected_quantity) {
                    physical_inputs_available = false;
                    break;
                }
                auto total = std::find_if(recovery_probe_goods.begin(),
                    recovery_probe_goods.end(), [&](const auto &entry) {
                        return entry.first == selected_good;
                    });
                if (total == recovery_probe_goods.end()) {
                    recovery_probe_goods.push_back({selected_good, selected_quantity});
                } else {
                    total->second = saturating_add(
                        total->second, selected_quantity, _saturation_count);
                }
            }
            bool physical_resources_available = true;
            if (type.behavior_id == 1 || type.behavior_id == 2) {
                for (int32_t i = 0; i < type.resource_count; ++i) {
                    const ResourceAmount &item =
                        _building_resources[type.resource_begin + i];
                    const int64_t raw_base = item.mode == 1
                        ? saturating_mul(group.count, item.quantity, _saturation_count)
                        : saturating_mul(building_days, item.quantity, _saturation_count);
                    const int64_t base = effective_resource_use_quantity(
                        group.cell, item.resource_id, raw_base, _saturation_count);
                    const int64_t required = saturating_add(saturating_mul(
                        base, recovery_probe_floor_q16, _saturation_count),
                        Q16_ONE - 1, _saturation_count) / Q16_ONE;
                    if (required > available_resource_amount(item, group.cell)) {
                        physical_resources_available = false;
                        break;
                    }
                }
            }
            const bool executable = physical_inputs_available &&
                physical_resources_available && finance_available;
            const bool viable = expected_profit_margin >= _building_restart_margin_q16 &&
                executable;
            if (group_index < static_cast<int32_t>(
                    _building_recovery_liquidation_eligible.size())) {
                _building_recovery_liquidation_eligible[group_index] =
                    executable &&
                    expected_profit_margin < _building_restart_margin_q16;
            }
            if (viable) {
                _building_merchant_credit_limit[group_index] = credit_needed;
                _merchant_credit_committed = saturating_add(
                    _merchant_credit_committed, credit_needed, _saturation_count);
                cell_credit_remaining -= credit_needed;
                if (_merchant_credit_runtime_mode == 2) {
                    // The legacy probe branch is unreachable. Keep any
                    // defensive transition in the suspended state so an old
                    // execution path can never publish state 2.
                    group.operating_state = 1;
                    group.pending_operating_state = 255;
                    group.recovery_cycles = 0;
                    ++_recovery_approved;
                }
            }
        }
        if (group.operating_state != 1) {
            int64_t utilization = group.planned_utilization_q16 > 0
                ? group.planned_utilization_q16 : Q16_ONE;
            bool produces_cycle_flow = false;
            bool produces_survival_food = false;
            bool all_outputs_have_monetary_absorption = type.output_count > 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                if (_good_storage_modes[good] == 1) {
                    produces_cycle_flow = true;
                }
                produces_survival_food = produces_survival_food ||
                    _survival_food_good_mask[good] != 0;
                all_outputs_have_monetary_absorption =
                    all_outputs_have_monetary_absorption &&
                    _good_monetary_issue_values[good] > 0;
            }
            const int64_t sellable_output = saturating_add(
                group.last_sold, group.last_discarded, _saturation_count);
            bool shortage_recovery = false;
            bool inventory_surplus = false;
            int64_t inventory_absorption_q16 = Q16_ONE;
            int64_t output_demand_ema = 0;
            for (int32_t i = 0; i < type.output_count; ++i) {
                const int32_t good = _building_outputs[type.output_begin + i].good_id;
                const int64_t market_index = _market.index(market, good);
                const int32_t signal = market_signal_index(group.cell, good);
                const int64_t household_demand = _market.demand_ema[market_index];
                const int64_t business_demand = signal >= 0
                    ? _market_signals.business_demand_ema[signal] : 0;
                const int64_t total_demand = saturating_add(
                    household_demand, business_demand, _saturation_count);
                output_demand_ema = saturating_add(
                    output_demand_ema, total_demand, _saturation_count);
                const int64_t input_reserve = signal >= 0 && signal <
                        static_cast<int32_t>(_production_input_reserve.size())
                    ? _production_input_reserve[signal] : 0;
                const int64_t household_available_stock = std::max<int64_t>(
                    0, _market.stock[market_index] - input_reserve);
                const int64_t realized = signal >= 0
                    ? _market_signals.realized_withdrawal_ema[signal] : 0;
                const int64_t daily_absorption = std::max<int64_t>(
                    realized, total_demand);
                const int64_t recovery_stock_limit = std::max<int64_t>(
                    GOODS_SCALE, saturating_mul(
                        daily_absorption, std::max(1, _epoch_days),
                        _saturation_count));
                const int64_t total_shortage_q16 = total_demand <= 0 ? 0
                    : std::clamp<int64_t>(Q16_ONE - mul_div_sat(
                        realized, Q16_ONE, total_demand, _saturation_count),
                        0, Q16_ONE);
                if (household_available_stock <= recovery_stock_limit &&
                    std::max<int64_t>(_market.last_shortage_q16[market_index],
                                      total_shortage_q16) >=
                        SHORTAGE_RECOVERY_THRESHOLD_Q16) {
                    shortage_recovery = true;
                    break;
                }
                if (_good_storage_modes[good] != 0) continue;
                const int32_t flow = trade_flow_index(group.cell, good, false);
                const int64_t exports = flow >= 0
                    ? _trade_flows.export_ema[flow] : 0;
                const int64_t cold_start_supply = signal >= 0
                    ? _market_signals.offered_supply_ema[signal] : 0;
                const int64_t target = merchant_inventory_target(
                    market, good, signal, realized, exports, cold_start_supply,
                    _saturation_count);
                const int64_t stock = _market.stock[market_index];
                if (stock > target) {
                    inventory_surplus = true;
                    const int64_t absorption_q16 = target > 0
                        ? std::clamp<int64_t>(mul_div_sat(
                            target, Q16_ONE, stock, _saturation_count), 0, Q16_ONE)
                        : 0;
                    inventory_absorption_q16 = std::min(
                        inventory_absorption_q16, absorption_q16);
                }
            }
            if (group.last_output > 0 && sellable_output > 0) {
                const int64_t sell_through_q16 = std::clamp<int64_t>(mul_div_sat(
                    group.last_sold, Q16_ONE, sellable_output, _saturation_count),
                    0, Q16_ONE);
                const int64_t discard_rate_q16 = Q16_ONE - sell_through_q16;
                const int64_t target_utilization = shortage_recovery ||
                    discard_rate_q16 <= DISCARD_RATE_TOLERANCE_Q16
                        ? Q16_ONE
                        : mul_div_sat(utilization, sell_through_q16, Q16_ONE,
                                      _saturation_count);
                const int64_t inventory_target_utilization =
                    inventory_surplus && !shortage_recovery
                        ? mul_div_sat(utilization, inventory_absorption_q16,
                                      Q16_ONE, _saturation_count)
                        : Q16_ONE;
                // Income/affordability-responsive cap: produce toward the
                // expected affordable demand. market.demand_ema already folds in
                // household price & wealth elasticity (i.e. what households can
                // actually pay for), so scaling output to it curbs chronic
                // oversupply of cheap goods instead of only reacting once
                // inventory has already piled up.
                const int64_t demand_ratio_q16 = group.last_output > 0
                    ? std::clamp<int64_t>(mul_div_sat(
                        output_demand_ema, Q16_ONE,
                        group.last_output, _saturation_count), 0, Q16_ONE)
                    : Q16_ONE;
                // Monetary-issue goods have an explicit full-batch sink in
                // production settlement. Household/business demand EMAs do not
                // describe that sink, so they must not throttle a pure bullion
                // producer that the mint will settle at its catalog face value.
                const int64_t demand_target_utilization =
                    all_outputs_have_monetary_absorption
                        ? target_utilization
                        : (!shortage_recovery
                            ? std::min<int64_t>(
                                target_utilization, demand_ratio_q16)
                            : target_utilization);
                int64_t response_q16 = std::clamp<int64_t>(
                    type.supply_price_elasticity_q16, 0, Q16_ONE);
                // Persistent glut must contract within one or two settlement
                // cycles. Keep profile elasticity for ordinary adjustment, but
                // apply a deterministic response floor once discard is material.
                if (!shortage_recovery && discard_rate_q16 >= SEVERE_DISCARD_RATE_Q16)
                    response_q16 = Q16_ONE;
                else if (!shortage_recovery && discard_rate_q16 >= HIGH_DISCARD_RATE_Q16)
                    response_q16 = std::max<int64_t>(response_q16, 3 * Q16_ONE / 4);
                utilization = saturating_add(utilization, mul_div_sat(
                    std::min(demand_target_utilization, inventory_target_utilization) -
                        utilization,
                    response_q16, Q16_ONE,
                    _saturation_count), _saturation_count);
            } else if (shortage_recovery) {
                const int64_t response_q16 = std::clamp<int64_t>(
                    type.supply_price_elasticity_q16, 0, Q16_ONE);
                utilization = saturating_add(utilization, mul_div_sat(
                    Q16_ONE - utilization, response_q16, Q16_ONE,
                    _saturation_count), _saturation_count);
            }
            // Keep a small market probe while active. The loss state machine remains
            // the authority for a complete stop and can later restart the group.
            // Perishable producers need a larger floor: a 1/32 probe can leave an
            // otherwise viable fishing or gathering household below subsistence.
            const int64_t probe_floor_q16 = produces_cycle_flow || produces_survival_food
                ? Q16_ONE / 6 : Q16_ONE / 32;
            const int64_t survival_floor_q16 = group_index < static_cast<int32_t>(
                    _building_survival_utilization_floor_q16.size())
                ? _building_survival_utilization_floor_q16[group_index] : 0;
            group.planned_utilization_q16 = static_cast<int32_t>(
                std::clamp<int64_t>(utilization,
                    std::max(probe_floor_q16, survival_floor_q16), Q16_ONE));
        } else {
            group.planned_utilization_q16 = 0;
        }
        if ((type.behavior_id == 1 || type.behavior_id == 2) &&
            group.planned_utilization_q16 > 0) {
            int64_t resource_capacity_q16 = Q16_ONE;
            const int64_t building_days = saturating_mul(
                group.count, std::max(1, _epoch_days), _saturation_count);
            for (int32_t i = 0; i < type.resource_count; ++i) {
                const ResourceAmount &item =
                    _building_resources[type.resource_begin + i];
                const int64_t raw_base = item.mode == 1
                    ? saturating_mul(group.count, item.quantity, _saturation_count)
                    : saturating_mul(building_days, item.quantity, _saturation_count);
                const int64_t base = effective_resource_use_quantity(
                    group.cell, item.resource_id, raw_base, _saturation_count);
                if (base <= 0) continue;
                resource_capacity_q16 = std::min<int64_t>(
                    resource_capacity_q16,
                    std::clamp<int64_t>(mul_div_sat(
                        available_resource_amount(item, group.cell), Q16_ONE,
                        base, _saturation_count), 0, Q16_ONE));
            }
            group.planned_utilization_q16 = static_cast<int32_t>(
                std::min<int64_t>(group.planned_utilization_q16,
                                  resource_capacity_q16));
        }
        if (group_index < static_cast<int32_t>(
                _building_planned_capacity_before_climate_q16.size())) {
            _building_planned_capacity_before_climate_q16[group_index] =
                group.planned_utilization_q16;
        }
        group.planned_utilization_q16 = static_cast<int32_t>(
            std::min<int64_t>(group.planned_utilization_q16,
                              group.last_climate_capacity_q16));
        group.purchase_intent_capacity_q16 = 0;
        const int64_t group_days = saturating_mul(
            group.count, std::max(1, _epoch_days), _saturation_count);
        group.last_expected_revenue = mul_div_sat(
            saturating_mul(group_days, revenue, _saturation_count),
            group.planned_utilization_q16, Q16_ONE, _saturation_count);
        if (margin_gap < 0) ++_unprofitable_building_groups;
        if (group.operating_state != 0) ++_loss_suspended_building_groups;
        _utilization_sum_q16 = saturating_add(
            _utilization_sum_q16, group.planned_utilization_q16, _saturation_count);
        }
    }
    publish_result();
    return true;
}

NativeEconomyRuntime::PricePressure NativeEconomyRuntime::price_pressure(
        int32_t market, int32_t good, int64_t household_demand, int64_t stock,
        int64_t shortage_q16, int32_t signal_index, int64_t &sat) const {
    PricePressure out;
    out.household_demand = std::max<int64_t>(0, household_demand);
    if (signal_index >= 0) {
        const bool frozen_signals =
            _epoch_business_demand_ema.size() == _market_signals.business_demand_ema.size() &&
            _epoch_offered_supply_ema.size() == _market_signals.offered_supply_ema.size();
        out.business_demand = frozen_signals
            ? _epoch_business_demand_ema[signal_index]
            : _market_signals.business_demand_ema[signal_index];
        out.supply = frozen_signals
            ? _epoch_offered_supply_ema[signal_index]
            : _market_signals.offered_supply_ema[signal_index];
    }
    const int64_t demand = saturating_add(out.household_demand, out.business_demand, sat);
    const int64_t flow = saturating_add(demand, out.supply, sat);
    out.excess_q16 = std::clamp<int64_t>(mul_div_sat(
        saturating_sub(demand, out.supply, sat), Q16_ONE,
        std::max<int64_t>(GOODS_SCALE, flow), sat), -Q16_ONE, Q16_ONE);
    if (_good_storage_modes[good] == 0) {
        const int64_t price_inventory_days_q16 = std::min<int64_t>(
            _good_target_inventory_days_q16[good],
            saturating_mul(std::max(1, _epoch_days), Q16_ONE, sat));
        out.inventory_target = mul_div_sat(
            demand, price_inventory_days_q16, Q16_ONE, sat);
        out.inventory_q16 = std::clamp<int64_t>(mul_div_sat(
            saturating_sub(out.inventory_target, stock, sat), Q16_ONE,
            std::max<int64_t>(GOODS_SCALE, out.inventory_target), sat), -Q16_ONE, Q16_ONE);
        out.shortage_q16 = std::clamp<int64_t>(shortage_q16, 0, Q16_ONE);
    }
    const int64_t price = std::max<int64_t>(1, _market.price[_market.index(market, good)]);
    const int64_t anchor = signal_index >= 0 &&
        _epoch_cost_anchor_price.size() == _market_signals.cost_anchor_price.size()
            ? _epoch_cost_anchor_price[signal_index]
            : (signal_index >= 0 ? _market_signals.cost_anchor_price[signal_index] : 0);
    out.adjustment_anchor_price = std::max<int64_t>(
        1, std::max<int64_t>(_good_default_price[good], anchor));
    if (signal_index >= 0 && _good_monetary_issue_values[good] == 0 && anchor > 0) {
        const int64_t confidence = std::min<int64_t>(Q16_ONE, mul_div_sat(
            out.supply, Q16_ONE, std::max<int64_t>(GOODS_SCALE, demand), sat));
        out.cost_q16 = mul_div_sat(std::clamp<int64_t>(mul_div_sat(
            anchor - price, Q16_ONE, std::max<int64_t>(anchor, price), sat),
            -Q16_ONE, Q16_ONE), confidence, Q16_ONE, sat);
    }
    if (demand == 0 && out.supply == 0 && stock == 0) {
        out.idle_q16 = std::clamp<int64_t>(mul_div_sat(
            static_cast<int64_t>(_good_default_price[good]) - price, Q16_ONE,
            std::max<int64_t>(1, std::max<int64_t>(_good_default_price[good], price)), sat),
            -Q16_ONE, Q16_ONE);
    }
    out.total_q16 = 0;
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.excess_q16, _good_excess_demand_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.inventory_q16, _good_inventory_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.shortage_q16, _good_shortage_weight_q16[good], Q16_ONE, sat), sat);
    out.total_q16 = saturating_add(out.total_q16, mul_div_sat(
        out.cost_q16, _good_cost_anchor_weight_q16[good], Q16_ONE, sat), sat);
    const int64_t elasticity = std::clamp<int64_t>(
        _good_demand_price_elasticity_q16[good], Q16_ONE / 4, Q16_ONE * 4);
    const int64_t adjusted = mul_div_sat(out.total_q16, Q16_ONE, elasticity, sat);
    out.change_q16 = mul_div_sat(adjusted, _good_price_adjust_q16[good], Q16_ONE, sat);
    out.inactive_reversion_alpha_q16 = mul_div_sat(mul_div_sat(
        _good_inactive_reversion_weight_q16[good], Q16_ONE, elasticity, sat),
        _good_price_adjust_q16[good], Q16_ONE, sat);
    return out;
}

int64_t NativeEconomyRuntime::next_price_v4(
        int32_t good, int64_t current_price, const PricePressure &pressure,
        int32_t days, int64_t &sat, bool &rate_clamped) const {
    const int64_t unclamped_change_q16 = pressure.change_q16;
    const int64_t change_q16 = std::clamp<int64_t>(unclamped_change_q16,
        -static_cast<int64_t>(_good_max_price_fall_q16[good]),
        static_cast<int64_t>(_good_max_price_rise_q16[good]));
    rate_clamped = unclamped_change_q16 != change_q16;
    const int64_t period_change_q16 = saturating_mul(
        change_q16, std::max(1, days), sat);
    // Positive pressure uses the stable default/cost anchor so repeated
    // shortages do not compound exponentially. Negative pressure uses the
    // current market price: a high cost anchor must not amplify a glut-driven
    // markdown into a collapse below the producer's economic scale.
    const int64_t adjustment_reference = price_adjustment_reference(
        current_price, pressure.adjustment_anchor_price, period_change_q16);
    int64_t next = saturating_add(current_price, mul_div_sat(
        adjustment_reference, period_change_q16, Q16_ONE, sat), sat);
    if (pressure.idle_q16 != 0 && pressure.inactive_reversion_alpha_q16 > 0) {
        const int64_t alpha_q16 = std::min<int64_t>(Q16_ONE, saturating_mul(
            pressure.inactive_reversion_alpha_q16, std::max(1, days), sat));
        next = saturating_add(next, mul_div_sat(
            static_cast<int64_t>(_good_default_price[good]) - next,
            alpha_q16, Q16_ONE, sat), sat);
    }
    return next;
}

bool NativeEconomyRuntime::evaluate_building_conditions(int32_t type_id, int32_t cell) const {
    if (type_id < 0 || type_id >= static_cast<int32_t>(_building_types.size()) ||
        cell < 0 || cell >= _cell_count) return false;
    const BuildingType &type = _building_types[type_id];
    if (type.condition_count == 0) return true;
    bool stack[64]{};
    int32_t top = 0;
    auto compare = [](int64_t lhs, int32_t op, int64_t rhs) {
        switch (op) {
            case 0: return lhs == rhs;
            case 1: return lhs != rhs;
            case 2: return lhs < rhs;
            case 3: return lhs <= rhs;
            case 4: return lhs > rhs;
            case 5: return lhs >= rhs;
            default: return false;
        }
    };
    if (type.condition_count > 64) return false;
    for (int32_t i = 0; i < type.condition_count; ++i) {
        const ConditionToken &token = _building_conditions[type.condition_begin + i];
        if (token.opcode == 1) {
            int64_t lhs = 0;
            switch (token.signal) {
                case 0: lhs = _environment_temperature_q16[cell]; break;
                case 1: lhs = _environment_moisture_q16[cell]; break;
                case 2: lhs = _environment_snow_q16[cell]; break;
                case 3: lhs = _environment_weather_q16[cell]; break;
                case 4: lhs = _building_elevation_q16[cell]; break;
                case 5: lhs = _building_terrain[cell]; break;
                case 6: lhs = _building_landform[cell]; break;
                case 7: lhs = _building_vegetation[cell]; break;
                case 8: lhs = _building_is_water[cell]; break;
                case 9: lhs = _building_has_river[cell]; break;
                case 10:
                    if (token.reference < 0 || token.reference >= static_cast<int32_t>(_resource_ids.size()))
                        return false;
                    lhs = _resource_snapshot[static_cast<size_t>(token.reference) * _cell_count + cell];
                    break;
                default: return false;
            }
            if (top >= 64) return false;
            stack[top++] = compare(lhs, token.compare, token.value);
        } else if (token.opcode == 4) {
            if (top < 1) return false;
            stack[top - 1] = !stack[top - 1];
        } else {
            if (top < 2) return false;
            const bool rhs = stack[--top];
            const bool lhs = stack[top - 1];
            stack[top - 1] = token.opcode == 2 ? lhs && rhs : lhs || rhs;
        }
    }
    return top == 1 && stack[0];
}

int64_t NativeEconomyRuntime::credit_local_merchants(int32_t cell, int64_t amount,
                                                     int32_t cashflow_source,
                                                     int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    amount = std::max<int64_t>(0, amount);
    if (amount == 0 || cell < 0 || cell >= _cell_count) return 0;
    const int32_t begin = _merchant_offsets[cell];
    const int32_t end = _merchant_offsets[cell + 1];
    int64_t total_population = 0;
    for (int32_t k = begin; k < end; ++k) {
        total_population = saturating_add(total_population,
            _population.population[_merchant_slots[k]], _saturation_count);
    }
    if (total_population <= 0) return 0;
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (int32_t k = begin; k < end; ++k) {
        const int32_t slot = _merchant_slots[k];
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, _population.population[slot], _saturation_count);
        const int64_t next = mul_div_sat(amount, prefix, total_population, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        _population.funds[slot] = saturating_add(_population.funds[slot], share, _saturation_count);
        _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], share,
                                                        _saturation_count);
        trace_record_cashflow(cell, _population.handle_for_slot(slot), cashflow_source,
                              share, 0);
    }
    return distributed;
}

int64_t NativeEconomyRuntime::debit_local_merchants(int32_t cell, int64_t amount,
                                                    int32_t cashflow_source,
                                                    int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    amount = std::max<int64_t>(0, amount);
    if (amount == 0 || cell < 0 || cell >= _cell_count) return 0;
    const int32_t begin = _merchant_offsets[cell];
    const int32_t end = _merchant_offsets[cell + 1];
    int64_t total_funds = 0;
    for (int32_t k = begin; k < end; ++k) {
        total_funds = saturating_add(total_funds,
            std::max<int64_t>(0, _population.funds[_merchant_slots[k]]), _saturation_count);
    }
    const int64_t target = std::min(amount, total_funds);
    if (target <= 0) return 0;
    int64_t prefix = 0;
    int64_t distributed = 0;
    for (int32_t k = begin; k < end; ++k) {
        const int32_t slot = _merchant_slots[k];
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, std::max<int64_t>(0, _population.funds[slot]),
                                _saturation_count);
        const int64_t next = mul_div_sat(target, prefix, total_funds, _saturation_count);
        const int64_t share = std::min(std::max<int64_t>(0, next - distributed),
                                       std::max<int64_t>(0, _population.funds[slot]));
        distributed = saturating_add(distributed, share, _saturation_count);
        _population.funds[slot] -= share;
        _population.epoch_expense[slot] = saturating_add(
            _population.epoch_expense[slot], share, _saturation_count);
        trace_record_cashflow(cell, _population.handle_for_slot(slot), cashflow_source,
                              0, share);
    }
    return distributed;
}

int64_t NativeEconomyRuntime::pay_building_wage_amount(
        int32_t cell, int32_t owner_slot, int32_t profession_id,
        int64_t filled_jobs, int64_t due, int64_t payment_cap,
        int64_t *saturation_override) {
    int64_t &_saturation_count = saturation_override != nullptr
        ? *saturation_override : this->_saturation_count;
    if (filled_jobs <= 0 || due <= 0 || payment_cap <= 0 || owner_slot < 0) return 0;
    const bool trace_detail = trace_detail_for_cell(cell);
    const int64_t owner_handle = static_cast<int64_t>(_population.handle_for_slot(owner_slot));
    const int64_t owner_funds_before = _population.funds[owner_slot];
    const int64_t owner_expense_before = _population.epoch_expense[owner_slot];
    thread_local std::vector<int32_t> trace_slots;
    thread_local std::vector<int64_t> trace_funds;
    thread_local std::vector<int64_t> trace_income;
    trace_slots.clear(); trace_funds.clear(); trace_income.clear();
    int64_t total_employed = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (_signatures[signature].profession_id == profession_id) {
            total_employed = saturating_add(total_employed,
                _population.employee_employed[slot], _saturation_count);
            if (trace_detail && _population.employee_employed[slot] > 0) {
                trace_slots.push_back(slot);
                trace_funds.push_back(_population.funds[slot]);
                trace_income.push_back(_population.epoch_income[slot]);
            }
        }
    });
    if (total_employed <= 0) {
        trace_append(EVENT_WAGE_SETTLED, static_cast<int32_t>(Stage::BUILDING_PRODUCTION),
                     cell, SUBJECT_COHORT, owner_handle, profession_id, -1,
                     filled_jobs, due, 0, due, nullptr);
        return 0;
    }
    const int64_t paid = std::min(
        std::min(due, payment_cap), std::max<int64_t>(0, _population.funds[owner_slot]));
    touch_accounting_slot(owner_slot);
    _population.funds[owner_slot] -= paid;
    _population.epoch_expense[owner_slot] = saturating_add(
        _population.epoch_expense[owner_slot], paid, _saturation_count);
    trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                          CASHFLOW_OWNER_WAGES, 0, paid);
    int64_t prefix = 0;
    int64_t distributed = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (_signatures[signature].profession_id != profession_id ||
            _population.employee_employed[slot] <= 0) return;
        touch_accounting_slot(slot);
        prefix = saturating_add(prefix, _population.employee_employed[slot],
                                _saturation_count);
        const int64_t next = mul_div_sat(paid, prefix, total_employed, _saturation_count);
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        int64_t income_tax = 0;
        if ((_epoch_active_tax_mask & static_cast<uint8_t>(
                1U << NativeCountryRuntime::TAX_INCOME)) != 0) {
            const int8_t income_rate = frozen_tax_rate(
                cell, NativeCountryRuntime::TAX_INCOME, profession_id);
            if (income_rate < 0) {
                if (slot >= 0 && slot < static_cast<int32_t>(
                        _income_taxable_base_by_slot.size())) {
                    _income_taxable_base_by_slot[slot] = saturating_add(
                        _income_taxable_base_by_slot[slot], share,
                        _saturation_count);
                }
            } else {
                income_tax = apply_fiscal_tax(
                    cell, NativeCountryRuntime::TAX_INCOME, share, income_rate,
                    _saturation_count);
                record_cohort_fiscal(slot, income_tax);
            }
        }
        const int64_t net_share = saturating_sub(
            share, income_tax, _saturation_count);
        _population.funds[slot] = saturating_add(_population.funds[slot], net_share,
                                                 _saturation_count);
        _population.epoch_income[slot] = saturating_add(
            _population.epoch_income[slot], share, _saturation_count);
        trace_record_cashflow(cell, _population.handle_for_slot(slot),
                              CASHFLOW_WAGES, share, 0);
        if (income_tax > 0)
            trace_record_cashflow(cell, _population.handle_for_slot(slot),
                                  CASHFLOW_INCOME_TAX, 0, income_tax);
        else if (income_tax < 0)
            trace_record_cashflow(cell, _population.handle_for_slot(slot),
                                  CASHFLOW_INCOME_SUBSIDY, -income_tax, 0);
    });
    std::vector<EventLeg> legs;
    if (trace_detail) {
        if (owner_funds_before != _population.funds[owner_slot]) {
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, owner_handle, -1,
                            owner_funds_before, _population.funds[owner_slot]});
        }
        if (owner_expense_before != _population.epoch_expense[owner_slot]) {
            legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, owner_handle, -1,
                            owner_expense_before, _population.epoch_expense[owner_slot]});
        }
        for (size_t i = 0; i < trace_slots.size(); ++i) {
            const int32_t worker_slot = trace_slots[i];
            const int64_t handle = static_cast<int64_t>(_population.handle_for_slot(worker_slot));
            if (trace_funds[i] != _population.funds[worker_slot]) {
                legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                                trace_funds[i], _population.funds[worker_slot]});
            }
            if (trace_income[i] != _population.epoch_income[worker_slot]) {
                legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                                trace_income[i], _population.epoch_income[worker_slot]});
            }
        }
    }
    trace_append(EVENT_WAGE_SETTLED, static_cast<int32_t>(Stage::BUILDING_PRODUCTION),
                 cell, SUBJECT_COHORT, owner_handle, profession_id, -1,
                 filled_jobs, due, distributed, due - distributed,
                 legs.empty() ? nullptr : &legs);
    return distributed;
}

// Building command/construction mutation implementations live in
// economy_runtime_building_construction.cpp.

void NativeEconomyRuntime::refresh_building_modifier_factors() {
    const auto factor_refresh_started = Clock::now();
    struct RefreshTimer {
        NativeEconomyRuntime *self;
        const std::chrono::steady_clock::time_point &start;
        ~RefreshTimer() {
            self->_building_factor_refresh_ms += elapsed_ms(start);
        }
    } refresh_timer{this, factor_refresh_started};
    // Groups are only ever appended in place, so growing the cache must keep
    // the existing entries; a full assign() would force every group to
    // recompute its factor whenever a single building finishes construction.
    // The entry carries the full group identity, so a stale slot can never be
    // mistaken for a different group.
    if (_building_factor_cache.size() != _buildings.size())
        _building_factor_cache.resize(_buildings.size(),
                                      BuildingFactorCacheEntry{});
    // Gated on the building output stats alone: an unrelated economy modifier
    // must not invalidate every building group's cached factor.
    const uint64_t mod_version = _modifier_runtime != nullptr
        ? _modifier_runtime->building_output_stat_version()
        : 0;
    for (size_t group_index = 0; group_index < _buildings.size();
         ++group_index) {
        BuildingGroup &group = _buildings[group_index];
        BuildingFactorCacheEntry &cache = _building_factor_cache[group_index];
        const bool cell_country_valid = _modifier_runtime != nullptr &&
            group.cell >= 0 &&
            group.cell < static_cast<int32_t>(_epoch_cell_country.size());
        const int32_t country_slot = cell_country_valid
            ? _epoch_cell_country[static_cast<size_t>(group.cell)] : -1;
        const uint64_t country_handle = country_slot >= 0 &&
                country_slot < static_cast<int32_t>(_epoch_country_handles.size())
            ? _epoch_country_handles[static_cast<size_t>(country_slot)] : 0;
        const int64_t country_factor_q16 = country_slot >= 0 &&
                country_slot < static_cast<int32_t>(
                    _epoch_country_output_factor_q16.size())
            ? _epoch_country_output_factor_q16[
                static_cast<size_t>(country_slot)] : Q16_ONE;
        const int32_t sector = group.type_id >= 0 &&
                group.type_id < static_cast<int32_t>(_building_types.size())
            ? _building_types[static_cast<size_t>(group.type_id)].economic_sector
            : 2;
        const int64_t sector_factor_q16 = country_slot >= 0 &&
                static_cast<size_t>(country_slot) * 5U + sector <
                    _epoch_country_sector_output_factor_q16.size()
            ? _epoch_country_sector_output_factor_q16[
                static_cast<size_t>(country_slot) * 5U + sector] : Q16_ONE;
        int32_t family = -1;
        if (group.type_id >= 0 &&
            group.type_id < static_cast<int32_t>(
                _building_upgrade_family_indices.size())) {
            family = _building_upgrade_family_indices[
                static_cast<size_t>(group.type_id)];
        }
        const bool research_institution = family >= 0 &&
            family < static_cast<int32_t>(_building_upgrade_family_ids.size()) &&
            _building_upgrade_family_ids[static_cast<size_t>(family)] ==
                "research_institution";
        const int64_t research_factor_q16 = research_institution &&
                country_slot >= 0 &&
                country_slot < static_cast<int32_t>(
                    _epoch_country_research_output_factor_q16.size())
            ? _epoch_country_research_output_factor_q16[
                static_cast<size_t>(country_slot)] : Q16_ONE;
        const size_t family_factor_index = static_cast<size_t>(
            std::max(0, country_slot)) * _building_upgrade_family_ids.size() +
            static_cast<size_t>(std::max(0, family));
        const int64_t family_factor_q16 = country_slot >= 0 && family >= 0 &&
                family_factor_index < _epoch_country_family_output_factor_q16.size()
            ? _epoch_country_family_output_factor_q16[family_factor_index]
            : Q16_ONE;
        const size_t building_factor_index = static_cast<size_t>(
            std::max(0, country_slot)) * _building_type_ids.size() +
            static_cast<size_t>(std::max(0, group.type_id));
        const int64_t building_type_factor_q16 = country_slot >= 0 &&
                group.type_id >= 0 &&
                building_factor_index <
                    _epoch_country_building_output_factor_q16.size()
            ? _epoch_country_building_output_factor_q16[building_factor_index]
            : Q16_ONE;
        const int32_t terrain = group.cell >= 0 && group.cell < static_cast<int32_t>(
                _building_terrain.size()) ? _building_terrain[group.cell] : -1;
        const int32_t landform = group.cell >= 0 && group.cell < static_cast<int32_t>(
                _building_landform.size()) ? _building_landform[group.cell] : -1;
        const size_t terrain_index = (static_cast<size_t>(std::max(0, country_slot)) *
                _modifier_terrain_ids.size() + static_cast<size_t>(std::max(0, terrain))) *
                5U + static_cast<size_t>(sector);
        const size_t landform_index = (static_cast<size_t>(std::max(0, country_slot)) *
                _modifier_landform_ids.size() + static_cast<size_t>(std::max(0, landform))) *
                5U + static_cast<size_t>(sector);
        const int64_t terrain_sector_factor_q16 = country_slot >= 0 && terrain >= 0 &&
                terrain_index < _epoch_country_terrain_sector_output_factor_q16.size()
            ? _epoch_country_terrain_sector_output_factor_q16[terrain_index] : Q16_ONE;
        const int64_t landform_sector_factor_q16 = country_slot >= 0 && landform >= 0 &&
                landform_index < _epoch_country_landform_sector_output_factor_q16.size()
            ? _epoch_country_landform_sector_output_factor_q16[landform_index] : Q16_ONE;
        if (cache.country_factor_q16 == country_factor_q16 &&
            cache.sector_factor_q16 == sector_factor_q16 &&
            cache.research_factor_q16 == research_factor_q16 &&
            cache.family_factor_q16 == family_factor_q16 &&
            cache.building_type_factor_q16 == building_type_factor_q16 &&
            cache.terrain_sector_factor_q16 == terrain_sector_factor_q16 &&
            cache.landform_sector_factor_q16 == landform_sector_factor_q16 &&
            cache.country_handle == country_handle &&
            cache.mod_version == mod_version &&
            cache.cell == group.cell &&
            cache.type_id == group.type_id &&
            cache.owner_signature_id == group.owner_signature_id) {
            ++_building_factor_cache_hits;
            ++_building_factor_cache_hits_epoch;
            continue;
        }
        ++_building_factor_cache_misses;
        ++_building_factor_cache_misses_epoch;
        if (cache.mod_version != mod_version)
            ++_building_factor_miss_modver_epoch;
        if (cache.country_factor_q16 != country_factor_q16 ||
            cache.country_handle != country_handle)
            ++_building_factor_miss_country_epoch;
        if (cache.sector_factor_q16 != sector_factor_q16)
            ++_building_factor_miss_sector_epoch;
        if (cache.research_factor_q16 != research_factor_q16)
            ++_building_factor_miss_research_epoch;
        if (cache.cell != group.cell || cache.type_id != group.type_id ||
            cache.owner_signature_id != group.owner_signature_id)
            ++_building_factor_miss_identity_epoch;
        group.output_factor_q16 = Q16_ONE;
        if (!cell_country_valid) {
            group.modifier_handle = 0;
        } else {
            group.modifier_handle = _modifier_runtime->ensure_building_identity(
                group.cell, group.type_id, group.owner_signature_id);
            const double building_factor =
                _modifier_runtime->economy_building_output_factor(
                    group.modifier_handle, static_cast<uint64_t>(group.cell), sector);
            group.output_factor_q16 = modifier_factor_q16(
                (static_cast<double>(country_factor_q16) / Q16_ONE) *
                (static_cast<double>(sector_factor_q16) / Q16_ONE) *
                (static_cast<double>(research_factor_q16) / Q16_ONE) *
                (static_cast<double>(family_factor_q16) / Q16_ONE) *
                (static_cast<double>(building_type_factor_q16) / Q16_ONE) *
                (static_cast<double>(terrain_sector_factor_q16) / Q16_ONE) *
                (static_cast<double>(landform_sector_factor_q16) / Q16_ONE) *
                building_factor);
        }
        cache.country_factor_q16 = country_factor_q16;
        cache.sector_factor_q16 = sector_factor_q16;
        cache.research_factor_q16 = research_factor_q16;
        cache.family_factor_q16 = family_factor_q16;
        cache.building_type_factor_q16 = building_type_factor_q16;
        cache.terrain_sector_factor_q16 = terrain_sector_factor_q16;
        cache.landform_sector_factor_q16 = landform_sector_factor_q16;
        cache.country_handle = country_handle;
        cache.mod_version = mod_version;
        cache.cell = group.cell;
        cache.type_id = group.type_id;
        cache.owner_signature_id = group.owner_signature_id;
        _building_handle_index_clean = false;
    }
}

int64_t NativeEconomyRuntime::effective_building_output_quantity(
        const BuildingGroup &group, int32_t good_id, int64_t base_quantity,
        int64_t utilization_q16, int64_t building_days,
        int64_t &sat) const {
    const int64_t physical_base = saturating_mul(
        std::max<int64_t>(0, base_quantity),
        std::max<int64_t>(0, building_days), sat);
    const int64_t utilized = mul_div_sat(
        physical_base, std::clamp<int64_t>(utilization_q16, 0, Q16_ONE),
        Q16_ONE, sat);
    const int64_t building_output = mul_div_sat(utilized,
        std::max<int32_t>(0, group.output_factor_q16), Q16_ONE, sat);
    const int32_t country_slot = group.cell >= 0 &&
            group.cell < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[static_cast<size_t>(group.cell)] : -1;
    const size_t good_factor_index = static_cast<size_t>(
        std::max(0, country_slot)) * _good_ids.size() +
        static_cast<size_t>(std::max(0, good_id));
    const int64_t good_factor_q16 = country_slot >= 0 && good_id >= 0 &&
            good_factor_index < _epoch_country_good_output_factor_q16.size()
        ? _epoch_country_good_output_factor_q16[good_factor_index] : Q16_ONE;
    return mul_div_sat(building_output, std::max<int64_t>(0, good_factor_q16),
        Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::effective_building_output_quantity_for_target(
        int32_t cell, int32_t type_id, int32_t owner_signature_id,
        int32_t good_id, int64_t base_quantity, int64_t utilization_q16,
        int64_t building_days, int64_t &sat) {
    BuildingGroup target;
    target.cell = cell;
    target.type_id = type_id;
    target.owner_signature_id = owner_signature_id;
    target.output_factor_q16 = Q16_ONE;
    if (_modifier_runtime != nullptr) {
        const int32_t country_slot = cell >= 0 &&
                cell < static_cast<int32_t>(_epoch_cell_country.size())
            ? _epoch_cell_country[static_cast<size_t>(cell)] : -1;
        const uint64_t country_handle = country_slot >= 0 &&
                country_slot < static_cast<int32_t>(_epoch_country_handles.size())
            ? _epoch_country_handles[static_cast<size_t>(country_slot)] : 0;
        target.modifier_handle = owner_signature_id >= 0
            ? _modifier_runtime->ensure_building_identity(
                cell, type_id, owner_signature_id)
            : 0;
        const double country_factor = country_slot >= 0 &&
                country_slot < static_cast<int32_t>(_epoch_country_output_factor_q16.size())
            ? static_cast<double>(_epoch_country_output_factor_q16[
                static_cast<size_t>(country_slot)]) / Q16_ONE
            : 1.0;
        const int32_t sector = type_id >= 0 &&
                type_id < static_cast<int32_t>(_building_types.size())
            ? _building_types[static_cast<size_t>(type_id)].economic_sector : 2;
        const double sector_factor = country_slot >= 0 &&
                static_cast<size_t>(country_slot) * 5U + sector <
                    _epoch_country_sector_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_sector_output_factor_q16[
                static_cast<size_t>(country_slot) * 5U + sector]) / Q16_ONE
            : 1.0;
        int32_t family = -1;
        if (type_id >= 0 &&
            type_id < static_cast<int32_t>(_building_upgrade_family_indices.size())) {
            family = _building_upgrade_family_indices[
                static_cast<size_t>(type_id)];
        }
        const bool research_institution = family >= 0 &&
            family < static_cast<int32_t>(_building_upgrade_family_ids.size()) &&
            _building_upgrade_family_ids[static_cast<size_t>(family)] ==
                "research_institution";
        const double research_factor = research_institution && country_slot >= 0 &&
                country_slot < static_cast<int32_t>(
                    _epoch_country_research_output_factor_q16.size())
            ? static_cast<double>(_epoch_country_research_output_factor_q16[
                static_cast<size_t>(country_slot)]) / Q16_ONE
            : 1.0;
        const size_t family_factor_index = static_cast<size_t>(
            std::max(0, country_slot)) * _building_upgrade_family_ids.size() +
            static_cast<size_t>(std::max(0, family));
        const double family_factor = country_slot >= 0 && family >= 0 &&
                family_factor_index < _epoch_country_family_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_family_output_factor_q16[
                family_factor_index]) / Q16_ONE
            : 1.0;
        const size_t building_factor_index = static_cast<size_t>(
            std::max(0, country_slot)) * _building_type_ids.size() +
            static_cast<size_t>(std::max(0, type_id));
        const double building_type_factor = country_slot >= 0 && type_id >= 0 &&
                building_factor_index <
                    _epoch_country_building_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_building_output_factor_q16[
                building_factor_index]) / Q16_ONE
            : 1.0;
        const int32_t terrain = cell >= 0 && cell < static_cast<int32_t>(
                _building_terrain.size()) ? _building_terrain[cell] : -1;
        const int32_t landform = cell >= 0 && cell < static_cast<int32_t>(
                _building_landform.size()) ? _building_landform[cell] : -1;
        const size_t terrain_index = (static_cast<size_t>(std::max(0, country_slot)) *
                _modifier_terrain_ids.size() + static_cast<size_t>(std::max(0, terrain))) *
                5U + static_cast<size_t>(sector);
        const size_t landform_index = (static_cast<size_t>(std::max(0, country_slot)) *
                _modifier_landform_ids.size() + static_cast<size_t>(std::max(0, landform))) *
                5U + static_cast<size_t>(sector);
        const double terrain_factor = country_slot >= 0 && terrain >= 0 &&
                terrain_index < _epoch_country_terrain_sector_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_terrain_sector_output_factor_q16[
                terrain_index]) / Q16_ONE : 1.0;
        const double landform_factor = country_slot >= 0 && landform >= 0 &&
                landform_index < _epoch_country_landform_sector_output_factor_q16.size()
            ? static_cast<double>(_epoch_country_landform_sector_output_factor_q16[
                landform_index]) / Q16_ONE : 1.0;
        target.output_factor_q16 = modifier_factor_q16(
            country_factor * sector_factor * research_factor * family_factor *
            building_type_factor * terrain_factor * landform_factor *
            _modifier_runtime->economy_building_output_factor(
                target.modifier_handle, static_cast<uint64_t>(cell), sector));
    }
    return effective_building_output_quantity(target, good_id, base_quantity,
        utilization_q16, building_days, sat);
}

int64_t NativeEconomyRuntime::effective_production_input_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const {
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country < 0 || good_id < 0 || good_id >= static_cast<int32_t>(
            _good_ids.size()) || country >= static_cast<int32_t>(
            _epoch_country_production_input_factor_q16.size()))
        return std::max<int64_t>(0, base_quantity);
    int64_t quantity = mul_div_sat(std::max<int64_t>(0, base_quantity),
        _epoch_country_production_input_factor_q16[country], Q16_ONE, sat);
    const size_t index = static_cast<size_t>(country) * _good_ids.size() + good_id;
    if (index >= _epoch_country_good_input_factor_q16.size()) return quantity;
    return mul_div_sat(quantity, _epoch_country_good_input_factor_q16[index],
        Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::effective_resource_use_quantity(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const {
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country < 0 || resource_id < 0 || resource_id >= static_cast<int32_t>(
            _resource_ids.size()) || country >= static_cast<int32_t>(
            _epoch_country_resource_global_use_factor_q16.size()))
        return std::max<int64_t>(0, base_quantity);
    int64_t quantity = mul_div_sat(std::max<int64_t>(0, base_quantity),
        _epoch_country_resource_global_use_factor_q16[country], Q16_ONE, sat);
    const size_t index = static_cast<size_t>(country) * _resource_ids.size() + resource_id;
    if (index >= _epoch_country_resource_use_factor_q16.size()) return quantity;
    return mul_div_sat(quantity, _epoch_country_resource_use_factor_q16[index],
        Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::effective_managed_resource_generation(
        int32_t cell, int32_t resource_id, int64_t base_quantity,
        int64_t &sat) const {
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country < 0 || resource_id < 0 || resource_id >= static_cast<int32_t>(
            _resource_ids.size())) return std::max<int64_t>(0, base_quantity);
    const size_t index = static_cast<size_t>(country) * _resource_ids.size() + resource_id;
    if (index >= _epoch_country_resource_generation_factor_q16.size())
        return std::max<int64_t>(0, base_quantity);
    return mul_div_sat(std::max<int64_t>(0, base_quantity),
        _epoch_country_resource_generation_factor_q16[index], Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::effective_household_good_quantity(
        int32_t cell, int32_t good_id, int64_t base_quantity,
        int64_t &sat) const {
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country < 0 || good_id < 0 || good_id >= static_cast<int32_t>(
            _good_ids.size())) return std::max<int64_t>(0, base_quantity);
    const size_t index = static_cast<size_t>(country) * _good_ids.size() + good_id;
    if (index >= _epoch_country_good_consumption_factor_q16.size())
        return std::max<int64_t>(0, base_quantity);
    return mul_div_sat(std::max<int64_t>(0, base_quantity),
        _epoch_country_good_consumption_factor_q16[index], Q16_ONE, sat);
}

int64_t NativeEconomyRuntime::planned_owner_demand(
        const BuildingGroup &group, int64_t &sat) const {
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0 || group.operating_state == 1 ||
        !building_available(group.cell, group.type_id, true))
        return 0;
    const BuildingType &type = _building_types[group.type_id];
    const int64_t full = saturating_mul(
        group.count, type.owner_slots_per_building, sat);
    if (full <= 0) return 0;
    // ACTIVE self-employment keeps every physical owner position. Utilization
    // scales work and output per building, not the number of proprietors.
    if (group.operating_state == 0) return full;
    // Suspended buildings have no jobs, capacity or input demand. They are
    // restored atomically at the next settlement boundary when viable.
    return 0;
}

int64_t NativeEconomyRuntime::projected_owner_income_per_day(
        const BuildingGroup &group, int64_t &sat) const {
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0) return 0;
    const BuildingType &type = _building_types[group.type_id];
    const int64_t days = std::max<int64_t>(1, _epoch_days);
    const int64_t utilization = std::clamp<int64_t>(
        group.planned_utilization_q16, 0, Q16_ONE);
    const int64_t owner_jobs = std::max(
        planned_owner_demand(group, sat),
        std::max<int64_t>(0, group.filled_owner));
    if (owner_jobs <= 0 || utilization <= 0) return 0;
    int64_t input_cost = saturating_mul(
        saturating_mul(group.sample_unit_input_cost, group.count,
                       sat),
        days, sat);
    input_cost = mul_div_sat(input_cost, utilization, Q16_ONE,
                             sat);
    int64_t wage_cost = 0;
    for (int32_t r = 0; r < type.employee_count; ++r) {
        const JobRole &role = _building_employee_roles[type.employee_begin + r];
        const int32_t role_index = group.employee_fill_begin + r;
        const int64_t wage = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_contract_wage.size())
            ? _building_role_contract_wage[role_index]
            : role.reference_wage_per_day;
        int64_t role_cost = saturating_mul(
            saturating_mul(role.slots_per_building, group.count,
                           sat),
            saturating_mul(wage, days, sat),
            sat);
        role_cost = mul_div_sat(role_cost, utilization, Q16_ONE,
                                sat);
        wage_cost = saturating_add(wage_cost, role_cost, sat);
    }
    const uint8_t owner_tax_mask = static_cast<uint8_t>(
        (1U << NativeCountryRuntime::TAX_INCOME) |
        (1U << NativeCountryRuntime::TAX_BUSINESS));
    if ((_epoch_active_tax_mask & owner_tax_mask) == 0) {
        const int64_t owner_pool = std::max<int64_t>(0,
            saturating_sub(group.last_expected_revenue,
                saturating_add(input_cost, wage_cost, sat), sat));
        const int64_t economic_owner_pool = saturating_add(
            owner_pool,
            std::max<int64_t>(0, group.last_in_kind_livelihood_value), sat);
        return economic_owner_pool / std::max<int64_t>(1,
            saturating_mul(owner_jobs, days, sat));
    }
    const int64_t operating_income = saturating_sub(
        group.last_expected_revenue,
        saturating_add(input_cost, wage_cost, sat), sat);
    const int8_t business_rate = frozen_tax_rate(
        group.cell, NativeCountryRuntime::TAX_BUSINESS, group.type_id);
    const int64_t business_transfer = expected_fiscal_transfer(
        group.cell, NativeCountryRuntime::TAX_BUSINESS,
        std::max<int64_t>(0, group.last_expected_revenue), business_rate, sat);
    const int64_t taxable_income = std::max<int64_t>(0, saturating_sub(
        operating_income, std::max<int64_t>(0, business_transfer), sat));
    const int32_t profession = group.owner_signature_id >= 0 &&
            group.owner_signature_id < static_cast<int32_t>(_signatures.size())
        ? _signatures[group.owner_signature_id].profession_id : -1;
    const int8_t income_rate = frozen_tax_rate(
        group.cell, NativeCountryRuntime::TAX_INCOME, profession);
    int64_t income_subsidy_base = taxable_income;
    if (income_rate < 0) {
        const int64_t living_floor = saturating_mul(
            saturating_mul(
                living_cost_for_signature(
                    group.cell, group.owner_signature_id,
                    _living_cost_base_plan_id, sat),
                owner_jobs, sat),
            days, sat);
        income_subsidy_base = std::max(
            income_subsidy_base, living_floor);
    }
    const int64_t income_transfer = expected_fiscal_transfer(
        group.cell, NativeCountryRuntime::TAX_INCOME, income_subsidy_base,
        income_rate, sat);
    const int64_t owner_pool = std::max<int64_t>(0, saturating_sub(
        saturating_sub(operating_income, business_transfer, sat),
        income_transfer, sat));
    const int64_t economic_owner_pool = saturating_add(
        owner_pool, std::max<int64_t>(0, group.last_in_kind_livelihood_value), sat);
    // ACTIVE demand is physical owner capacity; RECOVERY uses probe demand.
    // In-kind livelihood remains part of the pool but never mints cash.
    return economic_owner_pool / std::max<int64_t>(1,
        saturating_mul(owner_jobs, days, sat));
}

int64_t NativeEconomyRuntime::projected_employee_tax_retention_q16(
        const BuildingGroup &group, int64_t &sat) const {
    if ((_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << NativeCountryRuntime::TAX_INCOME)) == 0)
        return Q16_ONE;
    if (group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0) return 0;
    const BuildingType &type = _building_types[group.type_id];
    int64_t weighted_take_home = 0;
    int64_t weighted_gross = 0;
    for (int32_t r = 0; r < type.employee_count; ++r) {
        const JobRole &role = _building_employee_roles[type.employee_begin + r];
        const int32_t role_index = group.employee_fill_begin + r;
        const int64_t gross_wage = role_index >= 0 && role_index <
                static_cast<int32_t>(_building_role_contract_wage.size())
            ? _building_role_contract_wage[role_index]
            : role.reference_wage_per_day;
        const int64_t take_home = expected_after_tax_income(
            group.cell, role.profession_id, gross_wage, sat);
        const int64_t slots = std::max<int64_t>(0,
            role.slots_per_building);
        weighted_take_home = saturating_add(
            weighted_take_home, saturating_mul(take_home, slots, sat), sat);
        weighted_gross = saturating_add(
            weighted_gross, saturating_mul(gross_wage, slots, sat), sat);
    }
    if (weighted_gross <= 0) return Q16_ONE;
    return mul_div_sat(weighted_take_home, Q16_ONE, weighted_gross, sat);
}

int64_t NativeEconomyRuntime::building_debt_due(
        const BuildingGroup &group, int64_t &sat) const {
    const int64_t outstanding = saturating_add(
        std::max<int64_t>(0, group.merchant_debt_principal),
        std::max<int64_t>(0, group.merchant_debt_premium), sat);
    if (outstanding <= 0) return 0;
    const int64_t terms = std::max<int64_t>(
        1, group.merchant_debt_term_cycles_left);
    return saturating_add(outstanding, terms - 1, sat) / terms;
}

int64_t NativeEconomyRuntime::repay_building_debt(
        int32_t cell, int32_t owner_slot, BuildingGroup &group,
        int64_t payment_cap, int64_t &premium_paid) {
    premium_paid = 0;
    if (owner_slot < 0 || payment_cap <= 0 ||
        (group.merchant_debt_principal <= 0 && group.merchant_debt_premium <= 0))
        return 0;
    int64_t local_sat = 0;
    const int64_t due = building_debt_due(group, local_sat);
    _saturation_count = saturating_add(_saturation_count, local_sat, _saturation_count);
    const int64_t paid = std::min({
        due, payment_cap, std::max<int64_t>(0, _population.funds[owner_slot])});
    if (paid <= 0) return 0;
    touch_accounting_slot(owner_slot);
    _population.funds[owner_slot] -= paid;
    _population.epoch_expense[owner_slot] = saturating_add(
        _population.epoch_expense[owner_slot], paid, _saturation_count);
    trace_record_cashflow(cell, _population.handle_for_slot(owner_slot),
                          CASHFLOW_OTHER, 0, paid);
    if (credit_local_merchants(cell, paid, CASHFLOW_MERCHANT_BUSINESS,
                               &_saturation_count) != paid)
        return 0;
    const int64_t principal_paid = std::min(paid, group.merchant_debt_principal);
    group.merchant_debt_principal -= principal_paid;
    premium_paid = paid - principal_paid;
    group.merchant_debt_premium = std::max<int64_t>(
        0, group.merchant_debt_premium - premium_paid);
    if (group.merchant_debt_principal == 0 && group.merchant_debt_premium == 0) {
        group.merchant_debt_term_cycles_left = 0;
        group.merchant_debt_delinquent_cycles = 0;
    }
    return paid;
}

int32_t NativeEconomyRuntime::find_entrepreneur_source(
        int32_t cell, int32_t target_signature, int64_t required_capital,
        int64_t target_income_per_day, int64_t target_living_cost_per_day,
        int64_t owner_slots_per_building, int32_t building_type_id,
        bool &had_eligible_sponsor, int64_t &willing_population,
        int64_t &transferable_capital,
        int64_t &income_improvement_q16,
        uint64_t &sponsor_family_handle) const {
    had_eligible_sponsor = false;
    willing_population = 0;
    transferable_capital = 0;
    income_improvement_q16 = 0;
    sponsor_family_handle = 0;
    if (cell < 0 || cell >= _cell_count || target_signature < 0 ||
        target_signature >= static_cast<int32_t>(_signatures.size()) ||
        building_type_id < 0 ||
        building_type_id >= static_cast<int32_t>(_building_types.size()) ||
        target_income_per_day <= 0 || owner_slots_per_building <= 0) return -1;
    const Signature &target = _signatures[target_signature];
    int32_t best_slot = -1;
    int64_t best_improvement_q16 = std::numeric_limits<int64_t>::min();
    int64_t best_transferable = -1;
    int64_t best_willing = 0;
    uint64_t best_family = 0;
    int64_t sat = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const int32_t source_signature = static_cast<int32_t>(
            _population.signature_id[slot]);
        if (source_signature < 0 || source_signature >=
                static_cast<int32_t>(_signatures.size())) return;
        const Signature &source = _signatures[source_signature];
        if (source.ethnicity_id != target.ethnicity_id) return;
        const int64_t population = std::max<int64_t>(0,
            _population.population[slot]);
        if (population <= 0) return;
        const bool profession_transition = source_signature != target_signature;
        // Keep one lane occupant when changing profession so a portfolio can
        // apply exact capital corrections without a released source handle.
        const int64_t available_population = profession_transition
            ? std::max<int64_t>(0, population - 1)
            : population;
        if (available_population <= 0 ||
            (is_merchant_slot(slot) && population <= 1)) return;
        const int64_t source_living_cost = living_cost_for_signature(
            cell, source_signature, -1, sat);
        const int64_t reserve = saturating_mul(saturating_mul(
            source_living_cost, population, sat), 30, sat);
        const int64_t transferable = std::max<int64_t>(
            0, _population.funds[slot] - reserve);
        if (transferable < required_capital) return;
        const int64_t income_per_capita = std::max<int64_t>(0,
            _population.income_ema[slot]) / population;
        const int64_t recent_expense_per_day = std::max<int64_t>(0,
            _population.epoch_expense[slot]) /
            std::max<int64_t>(1, saturating_mul(
                population, std::max<int64_t>(1, _epoch_days), sat));
        const int64_t current_disposable = saturating_sub(
            income_per_capita,
            std::max(source_living_cost, recent_expense_per_day), sat);
        const int64_t target_disposable = saturating_sub(
            target_income_per_day, target_living_cost_per_day, sat);
        const int64_t income_gain = saturating_sub(
            target_disposable, current_disposable, sat);
        if (income_gain <= 0) return;
        had_eligible_sponsor = true;
        const int64_t chance_q16 = std::clamp<int64_t>(mul_div_sat(
            income_gain, Q16_ONE, std::max<int64_t>({
                1, target_income_per_day, target_living_cost_per_day}), sat),
            1, Q16_ONE);
        if (target.profession_id == _merchant_profession_id &&
            source.profession_id != _merchant_profession_id &&
            chance_q16 <
                _investment_merchant_transition_min_improvement_q16) {
            // Merchant is both an occupation and the cell's market balance-sheet
            // owner. Require a material improvement before creating another
            // merchant cohort instead of using the generic positive-gain floor.
            return;
        }
        const int64_t willing_floor = mul_div_sat(
            available_population, chance_q16, Q16_ONE, sat);
        const int64_t willingness_numerator = saturating_mul(
            available_population, chance_q16, sat);
        const int64_t willingness_remainder =
            willingness_numerator - saturating_mul(
                willing_floor, Q16_ONE, sat);
        uint64_t roll_hash = 1469598103934665603ULL;
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_seed));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint64_t>(_current_day));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(cell));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(building_type_id));
        roll_hash = trace_hash_mix(roll_hash, static_cast<uint32_t>(source_signature));
        const int64_t roll_q16 = static_cast<int64_t>((roll_hash >> 32) & 0xffffULL);
        const int64_t generic_willing = std::min<int64_t>(
            available_population, saturating_add(
                willing_floor, roll_q16 < willingness_remainder ? 1 : 0, sat));
        if (generic_willing < owner_slots_per_building) return;
        const auto consider = [&](uint64_t family_handle,
                                  int64_t family_people,
                                  int64_t family_capital) {
            const int64_t willing = std::min(generic_willing,
                std::max<int64_t>(0, family_people));
            const int64_t capital = std::min(transferable,
                std::max<int64_t>(0, family_capital));
            if (willing < owner_slots_per_building ||
                capital < required_capital) return;
            if (chance_q16 > best_improvement_q16 ||
                (chance_q16 == best_improvement_q16 &&
                 capital > best_transferable) ||
                (chance_q16 == best_improvement_q16 &&
                 capital == best_transferable &&
                 (best_slot < 0 || slot < best_slot ||
                  (slot == best_slot && family_handle < best_family)))) {
                best_slot = slot;
                best_improvement_q16 = chance_q16;
                best_transferable = capital;
                best_willing = willing;
                best_family = family_handle;
            }
        };
        bool considered_family = false;
        if (_family_runtime_mode == 2 && _family_cohort_offsets.size() ==
                _population.active.size() + 1) {
            for (int32_t p = _family_cohort_offsets[slot];
                 p < _family_cohort_offsets[slot + 1]; ++p) {
                const FamilyMembershipEdge &edge = _family_memberships[
                    _family_cohort_edge_indices[p]];
                int32_t family = -1;
                if (!_families.valid_handle(edge.family_handle, family)) continue;
                considered_family = true;
                consider(edge.family_handle, edge.people, edge.cash_claim);
            }
        }
        if (!considered_family) consider(0, available_population, transferable);
    });
    if (best_slot >= 0) {
        willing_population = best_willing;
        transferable_capital = best_transferable;
        income_improvement_q16 = best_improvement_q16;
        sponsor_family_handle = best_family;
    }
    return best_slot;
}

int32_t NativeEconomyRuntime::choose_epoch_days(int64_t cohorts) {
    const int64_t rolling_markets = (_market.market_count + ROLLING_PHASE_COUNT - 1) /
        ROLLING_PHASE_COUNT;
    const int64_t rolling_cohorts = (cohorts + ROLLING_PHASE_COUNT - 1) /
        ROLLING_PHASE_COUNT;
    const int64_t market_cell_slices = rolling_markets <= 0 ? 0 :
        (rolling_markets + std::max(1, _cells_per_slice) - 1) /
            std::max(1, _cells_per_slice);
    const int64_t market_cohort_slices = rolling_cohorts <= 0 ? 0 :
        (rolling_cohorts + std::max<int64_t>(1, _target_cohorts_per_slice) - 1) /
            std::max<int64_t>(1, _target_cohorts_per_slice);
    _estimated_market_slices_per_epoch = static_cast<int32_t>(std::clamp<int64_t>(
        std::max<int64_t>({1, market_cell_slices, market_cohort_slices}), 1,
        std::numeric_limits<int32_t>::max()));

    const int64_t building_ranges = std::max<int64_t>(0,
        (estimate_building_ranges() + ROLLING_PHASE_COUNT - 1) /
            ROLLING_PHASE_COUNT);
    _estimated_building_slices_per_epoch = static_cast<int32_t>(
        std::min<int64_t>(std::numeric_limits<int32_t>::max(), building_ranges * 4));
    // Two planning passes, employment and production consume four building
    // ranges. The fixed allowance covers ledger/dispatch/structural/publish
    // boundaries that cannot always fuse with a range-bearing call.
    constexpr int64_t FIXED_STAGE_MARGIN = 4;
    const int64_t raw_total = static_cast<int64_t>(
        _estimated_market_slices_per_epoch) +
        _estimated_building_slices_per_epoch + FIXED_STAGE_MARGIN;
    // SUS may legitimately budget-skip economy while native climate/visual
    // work occupies the frame. Reserve deterministic slack for that known
    // scheduler boundary; cadence never reads wall time or frame duration.
    const int64_t estimated_total = raw_total;
    _estimated_total_slices_per_epoch = static_cast<int32_t>(std::clamp<int64_t>(
        estimated_total, 1, std::numeric_limits<int32_t>::max()));

    _workload_cycle_clamped = false;
    _workload_deadline_feasible = true;
    return ROLLING_PHASE_COUNT;
}

int32_t NativeEconomyRuntime::building_slice_end(int32_t active_begin) const {
    return building_slice_end(active_begin, _building_cells_per_slice,
                              _building_groups_per_slice);
}

int32_t NativeEconomyRuntime::building_slice_end(
        int32_t active_begin, int32_t cell_cap, int32_t group_cap) const {
    const std::vector<int32_t> &active_cells = _epoch_active
        ? _epoch_building_cells : _building_active_cells;
    return slice_end_over(active_cells, active_begin, cell_cap, group_cap);
}

int32_t NativeEconomyRuntime::slice_end_over(
        const std::vector<int32_t> &active_cells,
        int32_t active_begin, int32_t cell_cap, int32_t group_cap) const {
    const int32_t active_count = static_cast<int32_t>(active_cells.size());
    active_begin = std::clamp(active_begin, 0, active_count);
    const int32_t cell_limit = std::min(active_count,
        active_begin + std::max(1, cell_cap));
    int32_t end = active_begin;
    int64_t groups = 0;
    while (end < cell_limit) {
        const int32_t cell = active_cells[end];
        const int64_t cell_groups = _building_cell_offsets.size() ==
                static_cast<size_t>(_cell_count + 1)
            ? _building_cell_offsets[cell + 1] - _building_cell_offsets[cell] : 0;
        if (end > active_begin && groups + cell_groups > std::max(1, group_cap))
            break;
        groups += cell_groups;
        ++end;
    }
    return end;
}

int32_t NativeEconomyRuntime::building_plan_slice_end(int32_t active_begin) const {
    const int32_t cell_cap = _building_plan_cells_per_slice_override > 0
        ? _building_plan_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    const int32_t group_cap = _building_plan_cells_per_slice_override > 0
        ? _building_groups_per_slice
        : std::min(65536, std::max(1, _building_groups_per_slice) * 2);
    return building_slice_end(
        active_begin, cell_cap, group_cap);
}

int32_t NativeEconomyRuntime::plan_evaluate_slice_end(int32_t active_begin) const {
    const int32_t cell_cap = _building_plan_cells_per_slice_override > 0
        ? _building_plan_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    const int32_t group_cap = _building_plan_cells_per_slice_override > 0
        ? _building_groups_per_slice
        : std::min(65536, std::max(1, _building_groups_per_slice) * 2);
    return slice_end_over(_epoch_plan_cells, active_begin, cell_cap, group_cap);
}

int32_t NativeEconomyRuntime::household_post_slice_end(
        int32_t active_begin) const {
    const int32_t cell_cap =
        _household_post_building_cells_per_slice_override > 0
        ? _household_post_building_cells_per_slice_override
        : std::min(65536, std::max(1, _building_cells_per_slice) * 2);
    const int32_t group_cap =
        _household_post_building_cells_per_slice_override > 0
        ? _building_groups_per_slice
        : std::min(65536, std::max(1, _building_groups_per_slice) * 2);
    return building_slice_end(
        active_begin, cell_cap, group_cap);
}

int32_t NativeEconomyRuntime::estimate_building_ranges() const {
    int32_t ranges = 0;
    int32_t cursor = 0;
    const int32_t active_count = static_cast<int32_t>(_building_active_cells.size());
    while (cursor < active_count) {
        const int32_t end = building_slice_end(cursor);
        cursor = std::max(cursor + 1, end);
        ++ranges;
    }
    return ranges;
}

bool NativeEconomyRuntime::should_run(int64_t day_index) const {
    // PROBE is deliberately non-authoritative. It may be exercised by explicit
    // focused tests/benchmarks, but the production scheduler must not mutate the
    // committed market until the ACTIVE performance gate has passed.
    if (!_bootstrapped || _fatal || _save.active || _restore.active || _market_runtime_mode != 2)
        return false;
    // A running frozen cycle is intentionally isolated from live country
    // changes. A new cycle, however, must wait until every due country command
    // for this day has committed at country_daily priority 255.
    if (!_epoch_active && _country_runtime != nullptr &&
        _country_runtime->should_run(day_index))
        return false;
    // Effect ingress is a first-class safe-boundary workload.  Do not let a
    // quiet market starve a preflighted native Effect transaction while it is
    // waiting to enter the next frozen ledger cycle.
    if (has_pending_effect_commands()) return true;
    if (!_family_expedition_due_heap.empty() &&
        _family_expedition_due_heap.front().first <= day_index) return true;
    for (const CanalProject &project : _canal_projects) {
        if ((project.state == CANAL_PROJECT_BUILDING && project.ready_day <= day_index) ||
            project.state == CANAL_PROJECT_AWAITING_EFFECT) return true;
    }
    return _epoch_active || day_index > _last_committed_day ||
           trade_planner_should_run();
}

bool NativeEconomyRuntime::trade_planner_should_run() const {
    return _market_runtime_mode == 2 && _trade_runtime_mode != 0 &&
           _trade_plan.phase != TradePlanStore::IDLE;
}

bool NativeEconomyRuntime::begin_trade_plan_slice(
        int64_t &work_done, std::string &error) {
    constexpr size_t budget = static_cast<size_t>(PUBLISH_ENTRIES_PER_SLICE);
    if (_trade_plan_init.phase == TradePlanInitPhase::IDLE) {
        _trade_plan_init.clear();
        _trade_plan_init.phase = TradePlanInitPhase::COMPONENT_PREPARE;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::COMPONENT_PREPARE) {
        if (_trade_runtime_mode == 0 || !_trade_topology.ready ||
            _market.market_count <= 0 || _market.good_count <= 0) {
            _trade_plan_init.phase = TradePlanInitPhase::DONE;
            return true;
        }
        if (_trade_topology.neighbors.size() != static_cast<size_t>(_cell_count) * 6 ||
            _trade_topology.passable.size() != static_cast<size_t>(_cell_count)) {
            error = "trade_topology_or_country_snapshot_not_ready";
            return false;
        }
        if (_trade_topology.component_country_hash == _trade_topology.topology_hash &&
            _trade_topology.component.size() == static_cast<size_t>(_cell_count)) {
            _trade_plan_init.phase = TradePlanInitPhase::PREPARE;
            return true;
        } else {
            _trade_topology.component.resize(static_cast<size_t>(_cell_count));
            _trade_plan_init.cursor = 0;
            _trade_plan_init.component_seed = 0;
            _trade_plan_init.next_component = 0;
            _trade_plan_init.component_queue_cursor = 0;
            _trade_plan_init.component_queue.clear();
            _trade_plan_init.component_queue.reserve(static_cast<size_t>(
                std::min(_cell_count, PUBLISH_ENTRIES_PER_SLICE * 4)));
            _trade_plan_init.phase = TradePlanInitPhase::COMPONENT_CLEAR;
            ++work_done;
            return true;
        }
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::COMPONENT_CLEAR) {
        const size_t start = _trade_plan_init.cursor;
        const size_t end = std::min(static_cast<size_t>(_cell_count), start + budget);
        for (; _trade_plan_init.cursor < end; ++_trade_plan_init.cursor)
            _trade_topology.component[_trade_plan_init.cursor] = -1;
        work_done += static_cast<int64_t>(end - start);
        if (_trade_plan_init.cursor >= static_cast<size_t>(_cell_count)) {
            _trade_plan_init.cursor = 0;
            _trade_plan_init.phase = TradePlanInitPhase::COMPONENT_BUILD;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::COMPONENT_BUILD) {
        size_t processed = 0;
        while (processed < budget) {
            if (_trade_plan_init.component_queue_cursor <
                    _trade_plan_init.component_queue.size()) {
                const int32_t cell = _trade_plan_init.component_queue[
                    _trade_plan_init.component_queue_cursor++];
                const int32_t component = _trade_topology.component[cell];
                for (int32_t direction = 0; direction < 6; ++direction) {
                    const int32_t neighbor = _trade_topology.neighbors[
                        static_cast<size_t>(cell) * 6 + direction];
                    if (neighbor < 0 || _trade_topology.passable[neighbor] == 0 ||
                        _trade_topology.component[neighbor] >= 0) continue;
                    _trade_topology.component[neighbor] = component;
                    _trade_plan_init.component_queue.push_back(neighbor);
                }
                ++processed;
                continue;
            }
            _trade_plan_init.component_queue.clear();
            _trade_plan_init.component_queue_cursor = 0;
            bool seeded = false;
            while (_trade_plan_init.component_seed < _cell_count && processed < budget) {
                const int32_t seed = _trade_plan_init.component_seed++;
                ++processed;
                if (_trade_topology.passable[seed] == 0 ||
                    _trade_topology.component[seed] >= 0) continue;
                _trade_topology.component[seed] = _trade_plan_init.next_component++;
                _trade_plan_init.component_queue.push_back(seed);
                seeded = true;
                break;
            }
            if (!seeded && _trade_plan_init.component_seed >= _cell_count) break;
        }
        work_done += static_cast<int64_t>(processed);
        if (_trade_plan_init.component_seed >= _cell_count &&
            _trade_plan_init.component_queue_cursor >=
                _trade_plan_init.component_queue.size()) {
            _trade_topology.component_country_hash = _trade_topology.topology_hash;
            _trade_plan_init.phase = TradePlanInitPhase::PREPARE;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::PREPARE) {
        if (_trade_runtime_mode == 0 || !_trade_topology.ready ||
            _market.market_count <= 0 || _market.good_count <= 0) {
            _trade_plan_init.phase = TradePlanInitPhase::DONE;
            return true;
        }
        _trade_plan.phase = TradePlanStore::SCAN;
        _trade_plan.scan_cursor = 0;
        _trade_plan.route_cursor = 0;
        _trade_plan.route_search_active = false;
        _trade_plan.route_search_source = -1;
        _trade_plan.route_search_accepted = 0;
        _trade_plan.route_search_pending_targets = 0;
        _trade_plan.route_search_expansions = 0;
        std::sort(_trade_active_keys.begin(), _trade_active_keys.end());
        _trade_active_keys.erase(
            std::unique(_trade_active_keys.begin(), _trade_active_keys.end()),
            _trade_active_keys.end());
        _trade_plan_init.active_before_prune = _trade_active_keys.size();
        _trade_plan_init.inflight_keys.clear();
        _trade_plan_init.inflight_keys.reserve(_trade_orders.line_goods.size());
        _trade_plan_init.order_cursor = 0;
        _trade_plan_init.line_cursor = _trade_orders.line_offsets.empty()
            ? 0 : _trade_orders.line_offsets[0];
        _trade_plan_init.phase = TradePlanInitPhase::INFLIGHT_BUILD;
        ++work_done;
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::INFLIGHT_BUILD) {
        size_t processed = 0;
        while (_trade_plan_init.order_cursor < _trade_orders.size() && processed < budget) {
            const int32_t order = _trade_plan_init.order_cursor;
            if (_trade_plan_init.line_cursor >= _trade_orders.line_offsets[order + 1]) {
                ++_trade_plan_init.order_cursor;
                if (_trade_plan_init.order_cursor < _trade_orders.size())
                    _trade_plan_init.line_cursor =
                        _trade_orders.line_offsets[_trade_plan_init.order_cursor];
                continue;
            }
            const int32_t line = _trade_plan_init.line_cursor++;
            _trade_plan_init.inflight_keys.push_back(
                (static_cast<uint64_t>(static_cast<uint32_t>(
                    _trade_orders.destinations[order])) << 32) |
                static_cast<uint32_t>(_trade_orders.line_goods[line]));
            ++processed;
        }
        work_done += static_cast<int64_t>(processed);
        if (_trade_plan_init.order_cursor >= _trade_orders.size())
            _trade_plan_init.phase = TradePlanInitPhase::INFLIGHT_SORT;
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::INFLIGHT_SORT) {
        auto &keys = _trade_plan_init.inflight_keys;
        std::sort(keys.begin(), keys.end());
        keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
        _trade_plan_init.retained_active_keys.clear();
        _trade_plan_init.retained_active_keys.reserve(_trade_active_keys.size());
        _trade_plan_init.cursor = 0;
        _trade_plan_init.phase = TradePlanInitPhase::PRUNE;
        work_done += static_cast<int64_t>(keys.size());
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::PRUNE) {
        const size_t start = _trade_plan_init.cursor;
        const size_t end = std::min(_trade_active_keys.size(), start + budget);
        for (; _trade_plan_init.cursor < end; ++_trade_plan_init.cursor) {
            const uint64_t key = _trade_active_keys[_trade_plan_init.cursor];
            const int32_t cell = static_cast<int32_t>(key >> 32);
            const int32_t good = static_cast<int32_t>(key & 0xffffffffU);
            bool idle = cell < 0 || cell >= _market.market_count || good < 0 ||
                good >= _market.good_count;
            if (!idle) {
                const int64_t index = _market.index(cell, good);
                const int32_t signal = market_signal_index(cell, good);
                const bool building_signal = signal >= 0 &&
                    (_market_signals.business_demand_ema[signal] > 0 ||
                     _market_signals.offered_supply_ema[signal] > 0);
                idle = _market.stock[index] <= 0 && _market.demand_ema[index] <= 0 &&
                    _market.last_shortage_q16[index] == 0 && !building_signal &&
                    !std::binary_search(_trade_plan_init.inflight_keys.begin(),
                                        _trade_plan_init.inflight_keys.end(), key);
            }
            if (!idle) {
                _trade_active_key_idle_cycles.erase(key);
                _trade_plan_init.retained_active_keys.push_back(key);
                continue;
            }
            uint8_t &idle_cycles = _trade_active_key_idle_cycles[key];
            idle_cycles = static_cast<uint8_t>(std::min<int32_t>(
                255, static_cast<int32_t>(idle_cycles) + 1));
            if (idle_cycles < 2)
                _trade_plan_init.retained_active_keys.push_back(key);
            else {
                _trade_active_key_idle_cycles.erase(key);
                if (cell >= 0 && cell < _market.market_count && good >= 0 &&
                    good < _market.good_count &&
                    _trade_active_key_present.size() == _market.stock.size()) {
                    _trade_active_key_present[_market.index(cell, good)] = 0;
                }
            }
        }
        work_done += static_cast<int64_t>(end - start);
        if (_trade_plan_init.cursor >= _trade_active_keys.size()) {
            _trade_active_keys.swap(_trade_plan_init.retained_active_keys);
            _trade_active_keys_pruned = saturating_add(
                _trade_active_keys_pruned,
                static_cast<int64_t>(_trade_plan_init.active_before_prune -
                                     _trade_active_keys.size()),
                _saturation_count);
            _trade_plan.scan_cells.clear();
            _trade_plan.scan_goods.clear();
            _trade_plan.scan_inbound.assign(_trade_active_keys.size(), 0);
            _trade_plan.scan_cells.reserve(_trade_active_keys.size());
            _trade_plan.scan_goods.reserve(_trade_active_keys.size());
            _trade_plan_init.order_cursor = 0;
            _trade_plan_init.line_cursor = _trade_orders.line_offsets.empty()
                ? 0 : _trade_orders.line_offsets[0];
            _trade_plan_init.phase = TradePlanInitPhase::INBOUND_BUILD;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::INBOUND_BUILD) {
        size_t processed = 0;
        while (_trade_plan_init.order_cursor < _trade_orders.size() && processed < budget) {
            const int32_t order = _trade_plan_init.order_cursor;
            if (_trade_plan_init.line_cursor >= _trade_orders.line_offsets[order + 1]) {
                ++_trade_plan_init.order_cursor;
                if (_trade_plan_init.order_cursor < _trade_orders.size())
                    _trade_plan_init.line_cursor =
                        _trade_orders.line_offsets[_trade_plan_init.order_cursor];
                continue;
            }
            const int32_t line = _trade_plan_init.line_cursor++;
            const uint64_t key =
                (static_cast<uint64_t>(static_cast<uint32_t>(
                    _trade_orders.destinations[order])) << 32) |
                static_cast<uint32_t>(_trade_orders.line_goods[line]);
            const auto it = std::lower_bound(_trade_active_keys.begin(),
                                             _trade_active_keys.end(), key);
            if (it != _trade_active_keys.end() && *it == key) {
                const size_t index = static_cast<size_t>(it - _trade_active_keys.begin());
                _trade_plan.scan_inbound[index] = saturating_add(
                    _trade_plan.scan_inbound[index], _trade_orders.line_quantities[line],
                    _saturation_count);
            }
            ++processed;
        }
        work_done += static_cast<int64_t>(processed);
        if (_trade_plan_init.order_cursor >= _trade_orders.size()) {
            const size_t signal_count = _trade_active_keys.size();
            const uint64_t day = static_cast<uint64_t>(std::max<int64_t>(0, _sample_day));
            _trade_plan_init.rotation = signal_count == 0 ? 0 : static_cast<size_t>(
                (day * static_cast<uint64_t>(std::max(1, _trade_max_signals))) %
                static_cast<uint64_t>(signal_count));
            _trade_plan_init.rotated_inbound.clear();
            _trade_plan_init.rotated_inbound.reserve(signal_count);
            _trade_plan_init.cursor = 0;
            _trade_plan_init.phase = TradePlanInitPhase::ROTATE;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::ROTATE) {
        const size_t start = _trade_plan_init.cursor;
        const size_t end = std::min(_trade_active_keys.size(), start + budget);
        for (; _trade_plan_init.cursor < end; ++_trade_plan_init.cursor) {
            const size_t index = (_trade_plan_init.rotation +
                                  _trade_plan_init.cursor) % _trade_active_keys.size();
            const uint64_t key = _trade_active_keys[index];
            _trade_plan.scan_cells.push_back(static_cast<int32_t>(key >> 32));
            _trade_plan.scan_goods.push_back(static_cast<int32_t>(key & 0xffffffffU));
            _trade_plan_init.rotated_inbound.push_back(_trade_plan.scan_inbound[index]);
        }
        work_done += static_cast<int64_t>(end - start);
        if (_trade_plan_init.cursor >= _trade_active_keys.size()) {
            _trade_plan.scan_inbound.swap(_trade_plan_init.rotated_inbound);
            _trade_plan.distance.resize(static_cast<size_t>(_cell_count));
            _trade_plan.distance_stamp.resize(static_cast<size_t>(_cell_count));
            _trade_plan.target_signal.resize(static_cast<size_t>(_cell_count));
            _trade_plan.target_stamp.resize(static_cast<size_t>(_cell_count));
            _trade_plan_init.cursor = 0;
            _trade_plan_init.phase = TradePlanInitPhase::WORKSPACE_CLEAR;
        }
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::WORKSPACE_CLEAR) {
        const size_t start = _trade_plan_init.cursor;
        const size_t end = std::min(static_cast<size_t>(_cell_count), start + budget);
        for (; _trade_plan_init.cursor < end; ++_trade_plan_init.cursor) {
            _trade_plan.distance[_trade_plan_init.cursor] = 0;
            _trade_plan.distance_stamp[_trade_plan_init.cursor] = 0;
            _trade_plan.target_signal[_trade_plan_init.cursor] = -1;
            _trade_plan.target_stamp[_trade_plan_init.cursor] = 0;
        }
        work_done += static_cast<int64_t>(end - start);
        if (_trade_plan_init.cursor >= static_cast<size_t>(_cell_count))
            _trade_plan_init.phase = TradePlanInitPhase::FINALIZE;
        return true;
    }
    if (_trade_plan_init.phase == TradePlanInitPhase::FINALIZE) {
        _trade_plan.scan_total = static_cast<int64_t>(_trade_plan.scan_cells.size());
        _trade_plan.country_topology_hash = _epoch_country_topology_hash;
        _trade_plan.topology_generation = _trade_topology.topology_generation;
        _trade_plan.sources.clear();
        _trade_plan.destinations.clear();
        _trade_plan.working_candidates.clear();
        _trade_plan.heap.clear();
        size_t cache_size = 1;
        while (cache_size < static_cast<size_t>(_trade_route_cache_entries)) cache_size <<= 1;
        const bool route_cache_invalid =
            _trade_plan.route_cache_keys.size() != cache_size ||
            _trade_plan.route_cache_costs.size() != cache_size ||
            _trade_plan.route_cache_country_topology_hash !=
                _trade_topology.topology_hash ||
            _trade_plan.route_cache_topology_generation !=
                _trade_topology.topology_generation;
        if (route_cache_invalid) {
            _trade_plan.route_cache_keys.assign(
                cache_size, std::numeric_limits<uint64_t>::max());
            _trade_plan.route_cache_costs.assign(cache_size, -1);
            _trade_plan.route_cache_country_topology_hash =
                _trade_topology.topology_hash;
            _trade_plan.route_cache_topology_generation =
                _trade_topology.topology_generation;
            work_done += static_cast<int64_t>(cache_size);
        }
        _trade_plan_init.phase = TradePlanInitPhase::DONE;
    }
    return true;
}




void NativeEconomyRuntime::refresh_investment_active_goods_for_market(
        int32_t market, int64_t &sat) {
    if (market < 0 || market >= _market.market_count ||
        _market.good_count <= 0) return;
    const size_t words_per_market =
        (static_cast<size_t>(_market.good_count) + 63U) / 64U;
    const size_t word_begin = static_cast<size_t>(market) * words_per_market;
    if (_investment_active_good_words.size() !=
        static_cast<size_t>(_market.market_count) * words_per_market) {
        return;
    }
    std::fill(_investment_active_good_words.begin() + word_begin,
              _investment_active_good_words.begin() + word_begin +
                  words_per_market,
              uint64_t{0});
    for (int32_t good = 0; good < _market.good_count; ++good) {
        const int64_t index = _market.index(market, good);
        const int32_t signal = market_signal_index(market, good);
        const int64_t business = signal >= 0
            ? _market_signals.business_demand_ema[signal] : 0;
        const int64_t supply = signal >= 0
            ? _market_signals.offered_supply_ema[signal] : 0;
        const int64_t realized = signal >= 0
            ? _market_signals.realized_withdrawal_ema[signal] : 0;
        const int32_t flow = trade_flow_index(market, good, false);
        const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
        const int64_t demand = saturating_add(
            std::max<int64_t>(0, _market.demand_ema[index]),
            std::max<int64_t>(0, business), sat);
        const int64_t target = merchant_inventory_target(
            market, good, signal, realized, exports, supply, sat);
        const bool active = _good_monetary_issue_values[good] > 0 ||
            demand > std::max<int64_t>(0, supply) ||
            _market.stock[index] < target;
        if (!active) continue;
        _investment_active_good_words[word_begin +
            static_cast<size_t>(good / 64)] |=
            uint64_t{1} << static_cast<uint32_t>(good % 64);
    }
}


int64_t NativeEconomyRuntime::merchant_procurement_quota(
        int32_t market, int32_t good, int32_t signal_index,
        int64_t sellable, int64_t target, int64_t stock,
        int64_t realized_withdrawal, int64_t export_ema,
        int64_t &sat) const {
    if (sellable <= 0 || market < 0 || market >= _market.market_count ||
        good < 0 || good >= _market.good_count || _good_storage_modes[good] != 0)
        return 0;
    const int64_t index = _market.index(market, good);
    int64_t feasible_daily = std::max<int64_t>(0, _market.demand_ema[index]);
    if (signal_index >= 0 && signal_index < static_cast<int32_t>(
            _market_signals.business_demand_ema.size())) {
        feasible_daily = saturating_add(feasible_daily,
            std::max<int64_t>(0, _market_signals.business_demand_ema[signal_index]), sat);
    }
    const int64_t forecast_daily = std::max<int64_t>(
        std::max<int64_t>(0, realized_withdrawal), feasible_daily);
    const int64_t cycle_withdrawal = saturating_mul(
        saturating_add(forecast_daily, std::max<int64_t>(0, export_ema), sat),
        std::max(1, _epoch_days), sat);
    const int64_t projected_stock = std::max<int64_t>(
        0, saturating_sub(std::max<int64_t>(0, stock), cycle_withdrawal, sat));
    const int64_t restock_quota = std::max<int64_t>(
        0, saturating_sub(std::max<int64_t>(0, target), projected_stock, sat));
    const bool survival_good = _survival_food_good_mask[good] != 0 ||
        _survival_clothing_good_mask[good] != 0;
    int64_t continuity_quota = 0;
    if (survival_good && forecast_daily > 0) {
        const int64_t high_water = mul_div_sat(
            std::max<int64_t>(0, target), MERCHANT_INVENTORY_HIGH_WATER_Q16,
            Q16_ONE, sat);
        if (stock <= high_water) {
            const int64_t projected_high_water = std::max<int64_t>(
                0, saturating_sub(high_water, projected_stock, sat));
            continuity_quota = std::min<int64_t>(sellable, std::min<int64_t>(
                cycle_withdrawal, projected_high_water));
        }
    }
    return std::min<int64_t>(sellable,
        std::max<int64_t>(restock_quota, continuity_quota));
}


int32_t NativeEconomyRuntime::effective_merchant_buy_factor_q16(
        int32_t market, int32_t good, int64_t target, int64_t stock,
        int64_t &sat) const {
    if (good < 0 || good >= _market.good_count || market < 0 ||
        market >= _market.market_count) return 0;
    (void)target;
    (void)stock;
    (void)sat;
    // The configured factor is the producer settlement factor and a hard
    // ceiling. Shortage still controls quantity and budget priority, but may
    // not erase the merchant's configured distribution margin.
    return static_cast<int32_t>(std::clamp<int64_t>(
        _good_merchant_buy_factor_q16[good], 0, Q16_ONE));
}


















bool NativeEconomyRuntime::apply_family_free_building_reward(
        const Command &cmd, std::string &error) {
    int32_t branch = -1;
    if (!_family_influences.valid_handle(cmd.target_handle, branch)) {
        ++_rejected_commands;
        return true;
    }
    const uint64_t family_handle = _family_influences.family_handle[branch];
    int32_t family = -1;
    const int32_t cell = _family_influences.cell[branch];
    const int32_t type_id = cmd.i32_1;
    const int64_t count = cmd.i64_0;
    if (!_families.valid_handle(family_handle, family) || cell < 0 ||
        cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0) {
        ++_rejected_commands;
        return true;
    }
    if (!building_available(cell, type_id, true)) {
        _last_building_rejection_reason = "reward_building_technology_locked";
        ++_rejected_commands;
        return true;
    }
    if (!building_constructible(cell, type_id, true)) {
        _last_building_rejection_reason =
            "reward_building_tier_obsolete_for_construction";
        ++_rejected_commands;
        return true;
    }
    if (!evaluate_building_conditions(type_id, cell)) {
        _last_building_rejection_reason = "reward_building_conditions_failed";
        ++_rejected_commands;
        return true;
    }
    if (!family_free_building_resources_legal(cell, type_id, count)) {
        _last_building_rejection_reason =
            "reward_building_resource_unavailable";
        ++_rejected_commands;
        return true;
    }

    int32_t ethnicity = _families.origin_ethnicity[family];
    if (cmd.i32_0 == 1) {
        int64_t largest_population = -1;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(
                _population.signature_id[slot]);
            if (signature < 0 || signature >= static_cast<int32_t>(
                    _signatures.size())) return;
            if (_population.population[slot] > largest_population) {
                largest_population = _population.population[slot];
                ethnicity = _signatures[signature].ethnicity_id;
            }
        });
    }
    const BuildingType &type = _building_types[type_id];
    const int32_t owner_signature = signature_for_profession_ethnicity(
        type.owner_profession_id, ethnicity);
    if (owner_signature < 0) {
        _last_building_rejection_reason = "reward_building_owner_signature_missing";
        ++_rejected_commands;
        return true;
    }
    const int32_t country_slot = cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    const int32_t time_factor = country_slot >= 0 && country_slot <
            static_cast<int32_t>(_epoch_country_construction_time_factor_q16.size())
        ? _epoch_country_construction_time_factor_q16[country_slot] : Q16_ONE;
    const int32_t construction_days = type.construction_days <= 0 ? 0 :
        std::max<int32_t>(1, static_cast<int32_t>(mul_div_sat(
            type.construction_days, time_factor, Q16_ONE, _saturation_count)));
    const int64_t reward_sequence = -std::max<int64_t>(1, cmd.sequence);
    _pending_construction.push_back({cell, type_id, owner_signature, count,
        _sample_day + construction_days, reward_sequence, 0, 0, 0,
        cmd.i32_0 == 0 ? family_handle : 0});
    trace_append(EVENT_CONSTRUCTION_STARTED,
        static_cast<int32_t>(Stage::LEDGER_APPLY), cell,
        SUBJECT_FAMILY_BRANCH, static_cast<int64_t>(cmd.target_handle),
        type_id, cmd.i32_0, count, _sample_day + construction_days,
        cmd.i64_1, reward_sequence, nullptr);
    return true;
}

bool NativeEconomyRuntime::apply_family_population_reward(
        const Command &cmd, std::string &error) {
    int32_t branch = -1;
    if (!_family_influences.valid_handle(cmd.target_handle, branch)) {
        ++_rejected_commands;
        return true;
    }
    const uint64_t family_handle = _family_influences.family_handle[branch];
    int32_t family = -1;
    const int32_t cell = _family_influences.cell[branch];
    const int64_t amount = cmd.i64_0;
    if (!_families.valid_handle(family_handle, family) || cell < 0 ||
        cell >= _cell_count || amount <= 0) {
        ++_rejected_commands;
        return true;
    }

    int32_t target_slot = -1;
    int64_t best_people = -1;
    if (cmd.i32_0 == 0) {
        for (const FamilyMembershipEdge &edge : _family_memberships) {
            int32_t slot = -1;
            if (edge.family_handle != family_handle || edge.people <= 0 ||
                !_population.valid_handle(edge.cohort_handle, slot) ||
                _population.page_cell[slot / COHORT_PAGE_SIZE] != cell) continue;
            if (edge.people > best_people || (edge.people == best_people &&
                    (target_slot < 0 || edge.cohort_handle <
                        _population.handle_for_slot(target_slot)))) {
                best_people = edge.people;
                target_slot = slot;
            }
        }
    } else {
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            int64_t attributed = 0;
            const uint64_t cohort = _population.handle_for_slot(slot);
            for (const FamilyMembershipEdge &edge : _family_memberships)
                if (edge.cohort_handle == cohort)
                    attributed = saturating_add(attributed,
                        std::max<int64_t>(0, edge.people), _saturation_count);
            const int64_t anonymous = std::max<int64_t>(0,
                _population.population[slot] - attributed);
            if (anonymous > best_people || (anonymous == best_people &&
                    (target_slot < 0 || cohort <
                        _population.handle_for_slot(target_slot)))) {
                best_people = anonymous;
                target_slot = slot;
            }
        });
    }

    if (target_slot < 0) {
        const int32_t signature = unemployed_signature_for_ethnicity(
            _families.origin_ethnicity[family]);
        if (signature < 0) {
            ++_rejected_commands;
            return true;
        }
        target_slot = _population.allocate_slot(cell,
            static_cast<uint32_t>(signature));
        if (target_slot < 0) {
            error = "family_population_reward_allocation_failed";
            return false;
        }
    }

    touch_accounting_slot(target_slot);
    audit_touch_population_lane(target_slot);
    const uint64_t cohort_handle = _population.handle_for_slot(target_slot);
    const int64_t before = _population.population[target_slot];
    _population.population[target_slot] = saturating_add(
        before, amount, _saturation_count);
    const int64_t actual = _population.population[target_slot] - before;
    if (actual <= 0) return true;
    _external_population_delta = saturating_add(
        _external_population_delta, actual, _saturation_count);
    _structural_touched_cells.push_back(cell);

    if (cmd.i32_0 == 0) {
        auto membership = std::find_if(_family_memberships.begin(),
            _family_memberships.end(), [&](const FamilyMembershipEdge &edge) {
                return edge.family_handle == family_handle &&
                    edge.cohort_handle == cohort_handle;
            });
        if (membership == _family_memberships.end()) {
            _family_memberships.push_back({family_handle, cohort_handle,
                actual, 0, _population.population[target_slot],
                _population.funds[target_slot], 0, 0});
        } else {
            membership->people = saturating_add(
                membership->people, actual, _saturation_count);
            membership->population_basis = _population.population[target_slot];
            membership->funds_basis = _population.funds[target_slot];
        }
        _family_indices_dirty = true;
    }

    std::vector<EventLeg> legs;
    if (trace_detail_for_cell(cell)) {
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
            static_cast<int64_t>(cohort_handle), -1, before,
            _population.population[target_slot]});
    }
    trace_append(EVENT_POPULATION_SOURCE,
        static_cast<int32_t>(Stage::LEDGER_APPLY), cell,
        SUBJECT_FAMILY_BRANCH, static_cast<int64_t>(cmd.target_handle),
        cmd.i32_0, COMMAND_FAMILY_POPULATION_REWARD, actual, before,
        _population.population[target_slot], cmd.i64_1,
        legs.empty() ? nullptr : &legs);
    return true;
}

bool NativeEconomyRuntime::apply_command(const Command &cmd, std::string &error) {
    int32_t slot = -1;
    int32_t event_cell = -1;
    int64_t settled_value = 0;
    std::vector<EventLeg> event_legs;
    auto add_leg = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                       int32_t key_id, int64_t before, int64_t after) {
        if (before != after && trace_detail_for_cell(event_cell)) {
            event_legs.push_back({field, subject_kind, subject_id, key_id, before, after});
        }
    };
    switch (cmd.opcode) {
        case COMMAND_START_FAMILY_EXPEDITION:
            return apply_start_family_expedition(cmd, error);
        case COMMAND_CANCEL_FAMILY_EXPEDITION:
            return apply_cancel_family_expedition(cmd, error);
        case COMMAND_SETTLE_FAMILY_EXPEDITION:
            return apply_settle_family_expedition(cmd, error);
        case COMMAND_TRANSFER_TO_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_ledger";
                return false;
            }
            event_cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t country_handle = cmd.i64_1 != 0 ? cmd.i64_1
                : (_country_runtime == nullptr ? 0 : _country_runtime->country_handle_for_cell(event_cell));
            const int64_t treasury_before = _country_runtime == nullptr ? 0 : _country_runtime->total_cash();
            const int64_t amount = _country_runtime == nullptr ? 0
                : _country_runtime->transfer_cash_to_cohort(country_handle, std::max<int64_t>(0, cmd.i64_0));
            if (country_handle == 0) { error = "country_treasury_target_invalid"; return false; }
            const int64_t funds_before = _population.funds[slot];
            const int64_t income_before = _population.epoch_income[slot];
            _population.funds[slot] = saturating_add(_population.funds[slot], amount, _saturation_count);
            _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], amount, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, amount, 0);
            settled_value = amount;
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, _country_runtime->total_cash());
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    income_before, _population.epoch_income[slot]);
            break;
        }
        case COMMAND_MINT_TO_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_mint";
                return false;
            }
            event_cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t funds_before = _population.funds[slot];
            const int64_t income_before = _population.epoch_income[slot];
            _population.funds[slot] = saturating_add(_population.funds[slot], cmd.i64_0, _saturation_count);
            _population.epoch_income[slot] = saturating_add(_population.epoch_income[slot], cmd.i64_0, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, cmd.i64_0, 0);
            _explicit_money_mint = saturating_add(_explicit_money_mint, cmd.i64_0, _saturation_count);
            settled_value = cmd.i64_0;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    income_before, _population.epoch_income[slot]);
            break;
        }
        case COMMAND_BURN_FROM_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_burn";
                return false;
            }
            event_cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, _population.funds[slot]));
            const int64_t funds_before = _population.funds[slot];
            const int64_t expense_before = _population.epoch_expense[slot];
            _population.funds[slot] -= amount;
            _population.epoch_expense[slot] = saturating_add(_population.epoch_expense[slot], amount, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            _explicit_money_burn = saturating_add(_explicit_money_burn, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    expense_before, _population.epoch_expense[slot]);
            break;
        }
        case COMMAND_ADD_STOCK: {
            event_cell = cmd.i32_0;
            const int64_t idx = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t stock_before = _market.stock[idx];
            audit_touch_market_lane(static_cast<size_t>(idx));
            _market.stock[idx] = saturating_add(_market.stock[idx], cmd.i64_0, _saturation_count);
            _explicit_stock_delta = saturating_add(_explicit_stock_delta, cmd.i64_0, _saturation_count);
            settled_value = _market.stock[idx] - stock_before;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    stock_before, _market.stock[idx]);
            break;
        }
        case COMMAND_REMOVE_STOCK: {
            event_cell = cmd.i32_0;
            const int64_t idx = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t stock_before = _market.stock[idx];
            const int64_t amount = std::min(cmd.i64_0, std::max<int64_t>(0, _market.stock[idx]));
            audit_touch_market_lane(static_cast<size_t>(idx));
            _market.stock[idx] -= amount;
            _explicit_stock_delta = saturating_sub(_explicit_stock_delta, amount, _saturation_count);
            settled_value = amount;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    stock_before, _market.stock[idx]);
            break;
        }
        case COMMAND_COUNTRY_GOOD_TO_MARKET: {
            event_cell = cmd.i32_0;
            if (_country_runtime == nullptr ||
                !_country_runtime->valid_handle(static_cast<int64_t>(cmd.target_handle))) {
                error = "country_treasury_target_invalid";
                return false;
            }
            const int64_t index = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t before = _market.stock[index];
            const int64_t moved = _country_runtime->transfer_good_to_market(
                static_cast<int64_t>(cmd.target_handle), cmd.i32_1, cmd.i64_0);
            audit_touch_market_lane(static_cast<size_t>(index));
            _market.stock[index] = saturating_add(_market.stock[index], moved, _saturation_count);
            settled_value = moved;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    before, _market.stock[index]);
            break;
        }
        case COMMAND_MARKET_GOOD_TO_COUNTRY: {
            event_cell = cmd.i32_0;
            if (_country_runtime == nullptr ||
                !_country_runtime->valid_handle(static_cast<int64_t>(cmd.target_handle))) {
                error = "country_treasury_target_invalid";
                return false;
            }
            const int64_t index = _market.index(cmd.i32_0, cmd.i32_1);
            const int64_t before = _market.stock[index];
            const int64_t offered = std::min(cmd.i64_0, std::max<int64_t>(0, _market.stock[index]));
            const int64_t moved = _country_runtime->transfer_good_from_market(
                static_cast<int64_t>(cmd.target_handle), cmd.i32_1, offered);
            audit_touch_market_lane(static_cast<size_t>(index));
            _market.stock[index] -= moved;
            settled_value = moved;
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, cmd.i32_0, cmd.i32_1,
                    before, _market.stock[index]);
            break;
        }
        case COMMAND_ADD_POPULATION: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_population_adjust";
                return false;
            }
            event_cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t before = _population.population[slot];
            const int64_t after = std::max<int64_t>(0, saturating_add(before, cmd.i64_0,
                                                                      _saturation_count));
            const int64_t actual_delta = after - before;
            _population.population[slot] = after;
            settled_value = actual_delta;
            add_leg(FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1, before, after);
            _external_population_delta = saturating_add(_external_population_delta, actual_delta,
                                                        _saturation_count);
            if (actual_delta != 0)
                _structural_touched_cells.push_back(event_cell);
            if (after == 0) {
                const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
                _structural_commands.push_back({0, slot, cell,
                                                static_cast<int32_t>(_population.signature_id[slot]),
                                                0, 0, cmd.sequence});
            }
            break;
        }
        case COMMAND_MOVE_POPULATION:
        case COMMAND_CHANGE_SIGNATURE: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_structure_queue";
                return false;
            }
            event_cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t requested = cmd.i64_0 <= 0 ? _population.population[slot] : cmd.i64_0;
            _structural_commands.push_back({cmd.opcode, slot,
                                            cmd.opcode == COMMAND_MOVE_POPULATION
                                                ? cmd.i32_0
                                                : _population.page_cell[slot / COHORT_PAGE_SIZE],
                                            cmd.opcode == COMMAND_CHANGE_SIGNATURE
                                                ? cmd.i32_0
                                                : static_cast<int32_t>(_population.signature_id[slot]),
                                            requested, 0, cmd.sequence});
            settled_value = requested;
            break;
        }
        case COMMAND_TRANSFER_FROM_COHORT: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_transfer";
                return false;
            }
            event_cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
            touch_accounting_slot(slot);
            const int64_t country_handle = cmd.i64_1 != 0 ? cmd.i64_1
                : (_country_runtime == nullptr ? 0 : _country_runtime->country_handle_for_cell(event_cell));
            if (country_handle == 0) { error = "country_treasury_target_invalid"; return false; }
            const int64_t offered = std::min(cmd.i64_0, std::max<int64_t>(0, _population.funds[slot]));
            const int64_t funds_before = _population.funds[slot];
            const int64_t treasury_before = _country_runtime == nullptr ? 0 : _country_runtime->total_cash();
            const int64_t expense_before = _population.epoch_expense[slot];
            const int64_t amount = _country_runtime == nullptr ? 0
                : _country_runtime->transfer_cash_from_cohort(country_handle, offered);
            _population.funds[slot] -= amount;
            _population.epoch_expense[slot] = saturating_add(_population.epoch_expense[slot], amount, _saturation_count);
            trace_record_cashflow(event_cell, cmd.target_handle,
                                  CASHFLOW_TRANSFER, 0, amount);
            settled_value = amount;
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    funds_before, _population.funds[slot]);
            add_leg(FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                    treasury_before, _country_runtime->total_cash());
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT,
                    static_cast<int64_t>(cmd.target_handle), -1,
                    expense_before, _population.epoch_expense[slot]);
            break;
        }
        case COMMAND_BUILD: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_build";
                return false;
            }
            return apply_build_command(cmd, slot, error);
        }
        case COMMAND_DEMOLISH: {
            if (!_population.valid_handle(cmd.target_handle, slot)) {
                error = "stale_cohort_handle_during_demolish";
                return false;
            }
            return apply_demolish_command(cmd, slot, error);
        }
        case COMMAND_FAMILY_FREE_BUILDING:
            return apply_family_free_building_reward(cmd, error);
        case COMMAND_FAMILY_POPULATION_REWARD:
            return apply_family_population_reward(cmd, error);
        case COMMAND_TREASURY_SPONSORED_BUILD:
            return apply_treasury_sponsored_build_command(cmd, error);
        case COMMAND_BUILD_CANAL:
            return apply_canal_build_command(cmd, error);
        default:
            error = "unsupported_command_opcode";
            return false;
    }
    trace_append(EVENT_COMMAND_SETTLED, static_cast<int32_t>(Stage::LEDGER_APPLY),
                 event_cell, SUBJECT_COMMAND, cmd.sequence, cmd.opcode, cmd.i32_1,
                 cmd.opcode, settled_value, cmd.i64_0, cmd.i64_1,
                 event_legs.empty() ? nullptr : &event_legs);
    return true;
}

bool NativeEconomyRuntime::commit_structural(const StructuralCommand &cmd,
                                             std::string &error) {
    if (cmd.opcode == STRUCTURAL_BIRTH) {
        if (cmd.cell < 0 || cmd.cell >= _cell_count || cmd.signature < 0 ||
            cmd.signature >= static_cast<int32_t>(_signatures.size()) ||
            cmd.population <= 0 || _signatures[cmd.signature].profession_id !=
                _unemployed_profession_id) {
            error = "structural_birth_target_invalid";
            return false;
        }
        const int32_t destination = _population.allocate_slot(
            cmd.cell, static_cast<uint32_t>(cmd.signature));
        if (destination < 0) {
            error = "structural_birth_allocation_failed";
            return false;
        }
        touch_accounting_slot(destination);
        const int64_t population_before = _population.population[destination];
        _population.population[destination] = saturating_add(
            population_before, cmd.population, _saturation_count);
        _structural_touched_cells.push_back(cmd.cell);
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(cmd.cell)) {
            legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT,
                            static_cast<int64_t>(_population.handle_for_slot(destination)), -1,
                            population_before, _population.population[destination]});
        }
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), cmd.cell,
                     SUBJECT_COHORT,
                     static_cast<int64_t>(_population.handle_for_slot(destination)),
                     cmd.signature, cmd.cell, cmd.population, 0, cmd.cell, cmd.cell,
                     legs.empty() ? nullptr : &legs);
        return true;
    }
    if (cmd.source_slot < 0 || cmd.source_slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[cmd.source_slot] == 0) {
        // A prior command may have consumed/released the same source. Stable
        // sequence semantics make the remaining command a deterministic no-op.
        return true;
    }
    const int32_t source = cmd.source_slot;
    const int32_t source_cell = _population.page_cell[source / COHORT_PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(_population.handle_for_slot(source));
    if (cmd.opcode == STRUCTURAL_REMOVE_EMPTY) {
        const int64_t estate_funds = _population.funds[source];
        const int64_t country_handle = _country_runtime == nullptr ? 0
            : _country_runtime->country_handle_for_cell(source_cell);
        const int64_t treasury_before = _country_runtime == nullptr ? 0
            : _country_runtime->total_cash();
        std::vector<EventLeg> legs;
        if (trace_detail_for_cell(source_cell)) {
            legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                            estate_funds, 0});
            legs.push_back({FIELD_TREASURY_CASH, SUBJECT_TREASURY, 0, -1,
                            treasury_before, treasury_before});
        }
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, estate_funds, _saturation_count);
        const int64_t moved = _country_runtime == nullptr ? 0
            : _country_runtime->transfer_cash_from_cohort(country_handle, estate_funds);
        if (moved != estate_funds) {
            error = "country_treasury_estate_transfer_failed";
            return false;
        }
        // A demography command can drain a cohort after the employment stage.
        // Remove its stale lane counts before releasing the slot; the committed
        // reconciliation pass below then clips the corresponding group fills.
        _filled_owner_jobs = saturating_sub(_filled_owner_jobs,
            std::max<int64_t>(0, _population.owner_employed[source]), _saturation_count);
        _filled_employee_jobs = saturating_sub(_filled_employee_jobs,
            std::max<int64_t>(0, _population.employee_employed[source]), _saturation_count);
        audit_touch_population_lane(source);
        _population.funds[source] = 0;
        _population.release_slot(source);
        _population.reclaim_empty_pages(source_cell);
        _structural_touched_cells.push_back(source_cell);
        if (legs.size() > 1) legs[1].after = _country_runtime->total_cash();
        trace_append(EVENT_STRUCTURAL_CHANGE,
                     static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), source_cell,
                     SUBJECT_COHORT, source_handle, 0, -1,
                     0, estate_funds, source_cell, -1,
                     legs.empty() ? nullptr : &legs);
        return true;
    }
    if (cmd.cell < 0 || cmd.cell >= _cell_count || cmd.signature < 0 ||
        cmd.signature >= static_cast<int32_t>(_signatures.size())) {
        error = "structural_target_invalid";
        return false;
    }
    if (!profession_available(cmd.cell, _signatures[cmd.signature].profession_id, true)) {
        ++_rejected_commands;
        return true;
    }
    if (cmd.cell == source_cell &&
        cmd.signature == static_cast<int32_t>(_population.signature_id[source])) return true;
    return move_cohort_population(source, cmd.cell, cmd.signature, cmd.population, error);
}

bool NativeEconomyRuntime::move_cohort_population(int32_t source, int32_t dest_cell,
                                                   int32_t dest_signature,
                                                   int64_t requested_pop,
                                                   std::string &error,
                                                   bool *source_drained_out,
                                                   uint64_t preferred_family_handle) {
    if (source_drained_out != nullptr) *source_drained_out = false;
    const int32_t source_cell = _population.page_cell[source / COHORT_PAGE_SIZE];
    const int64_t source_handle = static_cast<int64_t>(_population.handle_for_slot(source));
    const int32_t cmd_cell = dest_cell;
    const int32_t cmd_signature = dest_signature;
    const int64_t source_pop = std::max<int64_t>(0, _population.population[source]);
    const int64_t move_pop = std::min(std::max<int64_t>(0, requested_pop), source_pop);
    if (move_pop == 0) return true;
    _structural_touched_cells.push_back(source_cell);
    _structural_touched_cells.push_back(cmd_cell);
    const int64_t move_funds = move_pop == source_pop
                                   ? _population.funds[source]
                                   : mul_div_sat(_population.funds[source], move_pop, source_pop,
                                                 _saturation_count);
    const int64_t move_income = move_pop == source_pop
                                    ? _population.epoch_income[source]
                                    : mul_div_sat(_population.epoch_income[source], move_pop, source_pop,
                                                  _saturation_count);
    const int64_t move_expense = move_pop == source_pop
                                     ? _population.epoch_expense[source]
                                     : mul_div_sat(_population.epoch_expense[source], move_pop, source_pop,
                                                   _saturation_count);
    const int64_t move_in_kind = move_pop == source_pop
                                     ? _population.epoch_in_kind_income[source]
                                     : mul_div_sat(_population.epoch_in_kind_income[source],
                                                   move_pop, source_pop, _saturation_count);
    const int64_t move_ema = move_pop == source_pop
                                 ? _population.income_ema[source]
                                 : mul_div_sat(_population.income_ema[source], move_pop, source_pop,
                                               _saturation_count);
    const int64_t move_residual = move_pop == source_pop
                                      ? _population.demography_residual[source]
                                      : mul_div_sat(_population.demography_residual[source], move_pop,
                                                    source_pop, _saturation_count);
    const int64_t move_tax_paid = move_pop == source_pop
                                      ? _population.epoch_tax_paid[source]
                                      : mul_div_sat(_population.epoch_tax_paid[source],
                                                    move_pop, source_pop, _saturation_count);
    const int64_t move_subsidy = move_pop == source_pop
                                     ? _population.epoch_subsidy_received[source]
                                     : mul_div_sat(_population.epoch_subsidy_received[source],
                                                   move_pop, source_pop, _saturation_count);
    const int64_t move_baseline_ema = move_pop == source_pop
                                          ? _population.income_baseline_ema[source]
                                          : mul_div_sat(_population.income_baseline_ema[source],
                                                        move_pop, source_pop, _saturation_count);
    const uint16_t move_satisfaction = _population.needs_satisfaction[source];
    const uint16_t move_composite = _population.composite_satisfaction[source];
    const uint8_t move_worst_dimension = _population.worst_dimension_id[source];

    const int64_t source_population_before = _population.population[source];
    const int64_t source_funds_before = _population.funds[source];
    const int64_t source_income_before = _population.epoch_income[source];
    const int64_t source_expense_before = _population.epoch_expense[source];
    const int64_t source_ema_before = _population.income_ema[source];
    const int64_t source_residual_before = _population.demography_residual[source];

    const int32_t destination = _population.allocate_slot(cmd_cell, static_cast<uint32_t>(cmd_signature));
    if (destination < 0) {
        error = "structural_destination_allocation_failed";
        return false;
    }
    const int64_t destination_pop_before = _population.population[destination];
    const int64_t destination_funds_before = _population.funds[destination];
    const int64_t destination_income_before = _population.epoch_income[destination];
    const int64_t destination_expense_before = _population.epoch_expense[destination];
    const int64_t destination_ema_before = _population.income_ema[destination];
    const int64_t destination_residual_before = _population.demography_residual[destination];
    touch_accounting_slot(destination);
    audit_touch_population_lane(destination);
    const int64_t destination_handle = static_cast<int64_t>(
        _population.handle_for_slot(destination));
    _population.population[destination] = saturating_add(destination_pop_before, move_pop,
                                                         _saturation_count);
    _population.funds[destination] = saturating_add(_population.funds[destination], move_funds,
                                                    _saturation_count);
    _population.epoch_income[destination] = saturating_add(
        _population.epoch_income[destination], move_income, _saturation_count);
    _population.epoch_expense[destination] = saturating_add(
        _population.epoch_expense[destination], move_expense, _saturation_count);
    _population.epoch_in_kind_income[destination] = saturating_add(
        _population.epoch_in_kind_income[destination], move_in_kind, _saturation_count);
    _population.income_ema[destination] = saturating_add(_population.income_ema[destination],
                                                         move_ema, _saturation_count);
    _population.demography_residual[destination] = saturating_add(
        _population.demography_residual[destination], move_residual, _saturation_count);
    _population.epoch_tax_paid[destination] = saturating_add(
        _population.epoch_tax_paid[destination], move_tax_paid, _saturation_count);
    _population.epoch_subsidy_received[destination] = saturating_add(
        _population.epoch_subsidy_received[destination], move_subsidy, _saturation_count);
    _population.income_baseline_ema[destination] = saturating_add(
        _population.income_baseline_ema[destination], move_baseline_ema,
        _saturation_count);
    // Satisfaction is an intensive per-capita quantity, so merging two cohorts
    // blends it by population rather than summing it.
    const int64_t merged_pop = _population.population[destination];
    const auto blend_satisfaction = [&](uint16_t destination_value,
                                        uint16_t incoming_value) -> uint16_t {
        if (merged_pop <= 0) return static_cast<uint16_t>(Q16_ONE - 1);
        const int64_t weighted = saturating_add(
            mul_div_sat(destination_value, destination_pop_before, 1, _saturation_count),
            mul_div_sat(incoming_value, move_pop, 1, _saturation_count),
            _saturation_count);
        return static_cast<uint16_t>(
            std::clamp<int64_t>(weighted / merged_pop, 0, Q16_ONE - 1));
    };
    _population.needs_satisfaction[destination] = blend_satisfaction(
        _population.needs_satisfaction[destination], move_satisfaction);
    _population.composite_satisfaction[destination] = blend_satisfaction(
        _population.composite_satisfaction[destination], move_composite);
    {
        const size_t destination_base =
            static_cast<size_t>(destination) * static_cast<size_t>(SAT_DIM_COUNT);
        const size_t source_base =
            static_cast<size_t>(source) * static_cast<size_t>(SAT_DIM_COUNT);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            _population.satisfaction_dims[destination_base + static_cast<size_t>(dim)] =
                blend_satisfaction(
                    _population.satisfaction_dims[destination_base +
                                                  static_cast<size_t>(dim)],
                    _population.satisfaction_dims[source_base + static_cast<size_t>(dim)]);
        }
    }
    if (destination_pop_before <= 0)
        _population.worst_dimension_id[destination] = move_worst_dimension;

    audit_touch_population_lane(source);
    _population.population[source] -= move_pop;
    _population.funds[source] -= move_funds;
    _population.epoch_income[source] -= move_income;
    _population.epoch_expense[source] -= move_expense;
    _population.epoch_in_kind_income[source] -= move_in_kind;
    _population.income_ema[source] -= move_ema;
    _population.epoch_tax_paid[source] -= move_tax_paid;
    _population.epoch_subsidy_received[source] -= move_subsidy;
    _population.income_baseline_ema[source] -= move_baseline_ema;
    _population.demography_residual[source] -= move_residual;
    move_family_membership(static_cast<uint64_t>(source_handle),
        static_cast<uint64_t>(destination_handle), source_pop, move_pop,
        source_funds_before, move_funds, preferred_family_handle);
    if (_population.population[source] == 0) {
        // Any rounding residue is money, not an implicit burn.
        const int64_t residue_funds = _population.funds[source];
        _structural_funds_to_treasury = saturating_add(
            _structural_funds_to_treasury, residue_funds, _saturation_count);
        const int64_t country_handle = _country_runtime == nullptr ? 0
            : _country_runtime->country_handle_for_cell(source_cell);
        const int64_t moved = _country_runtime == nullptr ? 0
            : _country_runtime->transfer_cash_from_cohort(country_handle, residue_funds);
        if (moved != residue_funds) {
            error = "country_treasury_residue_transfer_failed";
            return false;
        }
        _population.funds[source] = 0;
        _population.release_slot(source);
        _population.reclaim_empty_pages(source_cell);
        if (source_drained_out != nullptr) *source_drained_out = true;
    }
    std::vector<EventLeg> legs;
    if (trace_detail_for_cell(source_cell) || trace_detail_for_cell(cmd_cell)) {
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, source_handle, -1,
                        source_population_before, source_population_before - move_pop});
        legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, source_handle, -1,
                        source_funds_before, source_funds_before - move_funds});
        legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, source_handle, -1,
                        source_income_before, source_income_before - move_income});
        legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, source_handle, -1,
                        source_expense_before, source_expense_before - move_expense});
        legs.push_back({FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, source_handle, -1,
                        source_ema_before, source_ema_before - move_ema});
        legs.push_back({FIELD_COHORT_DEMOGRAPHY_RESIDUAL, SUBJECT_COHORT,
                        source_handle, -1, source_residual_before,
                        source_residual_before - move_residual});
        legs.push_back({FIELD_COHORT_POPULATION, SUBJECT_COHORT, destination_handle, -1,
                        destination_pop_before, _population.population[destination]});
        legs.push_back({FIELD_COHORT_FUNDS, SUBJECT_COHORT, destination_handle, -1,
                        destination_funds_before, _population.funds[destination]});
        legs.push_back({FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, destination_handle, -1,
                        destination_income_before, _population.epoch_income[destination]});
        legs.push_back({FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, destination_handle, -1,
                        destination_expense_before, _population.epoch_expense[destination]});
        legs.push_back({FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, destination_handle, -1,
                        destination_ema_before, _population.income_ema[destination]});
        legs.push_back({FIELD_COHORT_DEMOGRAPHY_RESIDUAL, SUBJECT_COHORT,
                        destination_handle, -1, destination_residual_before,
                        _population.demography_residual[destination]});
    }
    trace_append(EVENT_STRUCTURAL_CHANGE,
                 static_cast<int32_t>(Stage::STRUCTURAL_COMMIT), source_cell,
                 SUBJECT_COHORT, source_handle, cmd_signature, cmd_cell,
                 move_pop, move_funds, source_cell, cmd_cell,
                 legs.empty() ? nullptr : &legs);
    return true;
}

NativeEconomyRuntime::AuditTotals NativeEconomyRuntime::audit_totals() const {
    AuditTotals totals;
    int64_t valuation_sat = 0;
    for (size_t slot = 0; slot < _population.active.size(); ++slot) {
        if (_population.active[slot] == 0) continue;
        totals.population += _population.population[slot];
        totals.cohort_funds += _population.funds[slot];
        if (is_merchant_slot(static_cast<int32_t>(slot))) {
            totals.merchant_cash = saturating_add(
                totals.merchant_cash,
                std::max<int64_t>(0, _population.funds[slot]),
                valuation_sat);
        }
    }
    totals.country_cash = _country_runtime == nullptr ? 0 : _country_runtime->total_cash();
    for (int32_t market = 0; market < _market.market_count; ++market) {
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t index = _market.index(market, good);
            totals.goods_stock += _market.stock[index];
            const int64_t retail_value = mul_div_sat(
                std::max<int64_t>(0, _market.stock[index]),
                std::max<int64_t>(0, _market.price[index]),
                GOODS_SCALE, valuation_sat);
            totals.merchant_inventory_retail_value = saturating_add(
                totals.merchant_inventory_retail_value, retail_value,
                valuation_sat);
            totals.merchant_inventory_liquidation_value = saturating_add(
                totals.merchant_inventory_liquidation_value,
                mul_div_sat(retail_value, std::clamp<int64_t>(
                    _good_merchant_buy_factor_q16[good], 0, Q16_ONE),
                    Q16_ONE, valuation_sat), valuation_sat);
        }
    }
    totals.transit_goods = trade_transit_goods();
    int64_t expedition_funds = 0;
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            _family_expeditions.active.size()); ++expedition) {
        if (_family_expeditions.active[expedition] == 0) continue;
        totals.transit_population += _family_expeditions.population[expedition];
        const uint32_t begin = _family_expeditions.payload_begin[expedition];
        const uint32_t end = std::min<uint32_t>(
            static_cast<uint32_t>(_family_expedition_payloads.size()),
            begin + _family_expeditions.payload_count[expedition]);
        for (uint32_t payload = begin; payload < end; ++payload)
            expedition_funds = saturating_add(expedition_funds,
                _family_expedition_payloads[payload].funds, valuation_sat);
    }
    totals.population += totals.transit_population;
    totals.escrow_cash = saturating_add(saturating_add(
        trade_escrow_cash(), fiscal_escrow_total(), valuation_sat),
        expedition_funds, valuation_sat);
    totals.goods_stock += totals.transit_goods;
    if (_country_runtime != nullptr) {
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t country_good =
                _country_runtime->total_good(good);
            totals.country_goods += country_good;
            totals.goods_stock += country_good;
        }
    }
    return totals;
}

void NativeEconomyRuntime::rebuild_committed_summaries() {
    _committed_cells.assign(_cell_count, {});
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        _committed_cells[cell] = build_cell_summary(cell);
    }
    _staging_cells = _committed_cells;
    _staging_touched_cells.clear();
    _staging_cell_generation.assign(_committed_cells.size(), 0);
    _staging_current_generation = 0;
}

NativeEconomyRuntime::CellSummary NativeEconomyRuntime::build_cell_summary(int32_t cell) const {
    CellSummary summary;
    int64_t satisfaction_weighted = 0;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        ++summary.cohort_count;
        summary.population += _population.population[slot];
        summary.funds += _population.funds[slot];
        summary.epoch_income += _population.epoch_income[slot];
        summary.epoch_expense += _population.epoch_expense[slot];
        satisfaction_weighted += static_cast<int64_t>(_population.needs_satisfaction[slot]) *
                                 _population.population[slot];
    });
    summary.satisfaction_q16 = summary.population > 0
                                   ? static_cast<int32_t>(std::clamp<int64_t>(
                                         satisfaction_weighted / summary.population, 0, Q16_ONE - 1))
                                   : static_cast<int32_t>(Q16_ONE - 1);
    return summary;
}

void NativeEconomyRuntime::stage_cell_summary(
        int32_t cell, const CellSummary &summary) {
    if (cell < 0 || cell >= static_cast<int32_t>(_staging_cells.size()))
        return;
    // Worker tasks must find this already sized; growing a shared vector from
    // several threads is exactly the race this sink split avoids.
    if (_staging_cell_generation.size() != _staging_cells.size())
        _staging_cell_generation.assign(_staging_cells.size(), 0);
    if (_staging_cell_generation[cell] != _staging_current_generation) {
        _staging_cell_generation[cell] = _staging_current_generation;
        if (_staging_touched_sink != nullptr)
            _staging_touched_sink->push_back(cell);
        else
            _staging_touched_cells.push_back(cell);
    }
    _staging_cells[cell] = summary;
}

bool NativeEconomyRuntime::rebuild_market_cell_ranges(std::string &error) {
    if (_market.market_count <= 0 ||
        _market.cell_to_market.size() != static_cast<size_t>(_cell_count)) {
        error = "market_cell_mapping_shape_invalid";
        return false;
    }
    _market_cell_offsets.assign(_market.market_count + 1, 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t market = _market.cell_to_market[cell];
        if (market < 0 || market >= _market.market_count) {
            error = "cell_to_market_entry_invalid";
            return false;
        }
        ++_market_cell_offsets[market + 1];
    }
    for (int32_t market = 0; market < _market.market_count; ++market) {
        _market_cell_offsets[market + 1] += _market_cell_offsets[market];
    }
    _market_cells.assign(_cell_count, -1);
    std::vector<int32_t> cursor(_market_cell_offsets.begin(), _market_cell_offsets.end() - 1);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t market = _market.cell_to_market[cell];
        _market_cells[cursor[market]++] = cell;
    }
    return true;
}


void NativeEconomyRuntime::fail(const std::string &reason) {
    trace_abort_epoch();
    for (const int32_t cell : _staging_touched_cells) {
        if (cell >= 0 && cell < static_cast<int32_t>(_committed_cells.size()) &&
            cell < static_cast<int32_t>(_staging_cells.size())) {
            _staging_cells[cell] = _committed_cells[cell];
        }
    }
    _staging_touched_cells.clear();
    _fatal = true;
    _fatal_reason = reason;
    _epoch_active = false;
    _stage = Stage::FATAL;
}

void NativeEconomyRuntime::finalize_household_building_cell(
        int32_t cell, int64_t &saturation, int64_t &restarted,
        int64_t &failed) {
    if (cell < 0 || cell >= _cell_count ||
        _building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) return;
    for (int32_t g = _building_cell_offsets[cell];
         g < _building_cell_offsets[cell + 1]; ++g) {
        BuildingGroup &group = _buildings[g];
        const int64_t livelihood = saturating_mul(saturating_mul(
            living_cost_for_signature(cell, group.owner_signature_id, -1,
                                      saturation),
            std::max<int64_t>(0, group.filled_owner), saturation),
            std::max(1, _epoch_days), saturation);
        const int64_t credit = g < static_cast<int32_t>(
                _building_owner_livelihood_credit.size())
            ? std::min<int64_t>(livelihood,
                _building_owner_livelihood_credit[g]) : 0;
        group.last_in_kind_livelihood_value = std::max<int64_t>(0, credit);
        const int64_t realized_cost = saturating_add(saturating_add(
            group.last_input_cost, group.last_base_wages_due,
            saturation), livelihood - credit, saturation);
        const int64_t margin = realized_cost <= 0
            ? (group.last_revenue > 0 ? Q16_ONE : 0)
            : mul_div_sat(saturating_sub(
                group.last_revenue, realized_cost, saturation),
                Q16_ONE, std::max<int64_t>(MONEY_SCALE, realized_cost),
                saturation);
        group.realized_profit_margin_q16 = static_cast<int32_t>(
            std::clamp<int64_t>(margin, -Q16_ONE, Q16_ONE));
        // Suspended buildings are evaluated by the unified economic plan
        // above. There is no reduced-capacity trial settlement here: a viable
        // building is scheduled ACTIVE for the next frozen boundary, while a
        // non-viable building remains fully suspended.
        (void)restarted;
        (void)failed;
    }
}

int64_t NativeEconomyRuntime::production_reserve_shortfall_cell(
        int32_t cell, int64_t &saturation) const {
    if (cell < 0 || cell >= _cell_count) return 0;
    const int32_t market = _market.cell_to_market[cell];
    int64_t shortfall = 0;
    for (int32_t signal = _market_signals.cell_offsets[cell];
         signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
        if (signal >= static_cast<int32_t>(_production_input_reserve.size())) continue;
        const int32_t good = _market_signals.good_ids[signal];
        shortfall = saturating_add(
            shortfall, std::max<int64_t>(0,
                _production_input_reserve[signal] -
                    _market.stock[_market.index(market, good)]),
            saturation);
    }
    return shortfall;
}

void NativeEconomyRuntime::review_recovery_building_group(int32_t g) {
    if (g < 0 || g >= static_cast<int32_t>(_buildings.size())) return;
    BuildingGroup &group = _buildings[g];
    if (group.count <= 0 || group.operating_state != 1 ||
        group.cell < 0 || group.cell >= _cell_count ||
        group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size())) return;
    const BuildingType &type = _building_types[group.type_id];
    const bool liquidation_eligible = g < static_cast<int32_t>(
            _building_recovery_liquidation_eligible.size()) &&
        _building_recovery_liquidation_eligible[g] != 0;
    if (!liquidation_eligible) {
        group.recovery_failed_reviews = 0;
        return;
    }
    group.recovery_failed_reviews = static_cast<uint16_t>(
        std::min<int32_t>(65535,
            static_cast<int32_t>(group.recovery_failed_reviews) + 1));
    if (group.recovery_failed_reviews < _recovery_liquidation_failed_reviews ||
        type.owner_profession_id == _merchant_profession_id) return;
    int64_t unit_period_output = 0;
    for (int32_t output_index = 0; output_index < type.output_count; ++output_index) {
        const GoodAmount &output = _building_outputs[type.output_begin + output_index];
        unit_period_output = saturating_add(
            unit_period_output, effective_building_output_quantity(
                group, output.good_id, output.quantity, Q16_ONE,
                std::max<int64_t>(1, _epoch_days), _saturation_count),
            _saturation_count);
    }
    const int64_t liquidation_capacity_q16 = std::max<int64_t>(
        group.planned_utilization_q16,
        g < static_cast<int32_t>(_building_recovery_probe_capacity_q16.size())
            ? _building_recovery_probe_capacity_q16[g] : 0);
    unit_period_output = mul_div_sat(
        unit_period_output, std::max<int64_t>(1, liquidation_capacity_q16),
        Q16_ONE, _saturation_count);
    const int64_t supported_count = unit_period_output > 0
        ? std::min<int64_t>(group.count,
            saturating_add(std::max<int64_t>(0, group.last_sold),
                unit_period_output - 1, _saturation_count) / unit_period_output)
        : 0;
    const int64_t confirmed_excess = std::max<int64_t>(
        0, group.count - supported_count);
    if (confirmed_excess <= 0) {
        group.recovery_failed_reviews = 0;
        return;
    }
    const int64_t max_retire = std::max<int64_t>(1,
        saturating_add(saturating_mul(group.count,
            _recovery_liquidation_max_share_q16, _saturation_count),
            Q16_ONE - 1, _saturation_count) / Q16_ONE);
    const int64_t retire_count = std::min(confirmed_excess, max_retire);
    const int64_t count_before = group.count;
    const int64_t principal_bad = retire_count == count_before
        ? group.merchant_debt_principal
        : mul_div_sat(group.merchant_debt_principal,
            retire_count, count_before, _saturation_count);
    const int64_t premium_bad = retire_count == count_before
        ? group.merchant_debt_premium
        : mul_div_sat(group.merchant_debt_premium,
            retire_count, count_before, _saturation_count);
    const int64_t bad_debt = saturating_add(
        principal_bad, premium_bad, _saturation_count);
    _merchant_credit_bad_debt = saturating_add(
        _merchant_credit_bad_debt, bad_debt, _saturation_count);
    _recovery_liquidated_buildings = saturating_add(
        _recovery_liquidated_buildings, retire_count, _saturation_count);
    group.merchant_debt_principal = std::max<int64_t>(
        0, group.merchant_debt_principal - principal_bad);
    group.merchant_debt_premium = std::max<int64_t>(
        0, group.merchant_debt_premium - premium_bad);
    _investment_employment_cells.push_back(group.cell);
    group.count -= retire_count;
    _building_handle_index_clean = false;
    if (group.count <= 0) {
        group.count = 0;
        group.merchant_debt_principal = 0;
        group.merchant_debt_premium = 0;
        group.merchant_debt_term_cycles_left = 0;
        group.merchant_debt_delinquent_cycles = 0;
        ++_recovery_fully_liquidated_groups;
    } else {
        _recovery_partially_liquidated_buildings = saturating_add(
            _recovery_partially_liquidated_buildings,
            retire_count, _saturation_count);
    }
}

Dictionary NativeEconomyRuntime::run_slice(const Dictionary &ctx) {
    return run_slice_internal(ctx, false);
}

Dictionary NativeEconomyRuntime::run_slice_compact(const Dictionary &ctx) {
    return run_slice_internal(ctx, true);
}

Dictionary NativeEconomyRuntime::run_slice_internal(const Dictionary &ctx, bool compact) {
    const auto slice_start = Clock::now();
    _executed_stage = _stage;
    _executed_substage.clear();
    // Report planner wall time for this native slice only. The planner can run
    // before start_epoch(), so epoch metric resets cannot own this counter.
    _trade_plan_ms = 0.0;
    _trade_plan_scan_body_ms = 0.0;
    _trade_plan_scan_finalize_ms = 0.0;
    _trade_plan_route_prepare_ms = 0.0;
    _trade_plan_route_expand_ms = 0.0;
    _trade_plan_route_finalize_ms = 0.0;
    _trade_plan_scan_pairs_slice = 0;
    _trade_plan_route_sources_prepared_slice = 0;
    _trade_plan_route_expansions_slice = 0;
    _trade_plan_candidates_finalized_slice = 0;
    _publish_slice_phase_ms.fill(0.0);
    _publish_slice_phase_work.fill(0);
    _building_commit_slice_phase_ms.fill(0.0);
    _building_commit_slice_phase_work.fill(0);
    _household_slice_phase_ms.fill(0.0);
    _household_slice_phase_work.fill(0);
    Dictionary out;
    const int64_t day_index = dict_num<int64_t>(ctx, "day_index", _current_day < 0 ? 0 : _current_day);
    const double requested_slice_budget_ms = std::clamp(
        dict_num<double>(ctx, "slice_budget_ms", 0.8), 0.1, 8.0);
    const double speed_scale = std::max(
        0.0, dict_num<double>(ctx, "speed_scale", 1.0));
    const int32_t requested_batch_multiplier =
        _high_speed_batching_enabled && speed_scale >= 20.0 ? 2 : 1;
    if (!_epoch_active)
        _active_batch_multiplier = 1;
    _active_batch_multiplier = std::max(
        _active_batch_multiplier, requested_batch_multiplier);
    const int32_t batch_multiplier = _active_batch_multiplier;
    // At high simulation speeds the bridge/scheduler overhead is larger than
    // the value of yielding every sub-millisecond range. Wall time only
    // controls yielding; it never changes authoritative work order or results.
    const double slice_budget_ms = speed_scale >= 20.0
        ? std::max(1.8, requested_slice_budget_ms)
        : requested_slice_budget_ms;
    constexpr int32_t MAX_CHUNKS_PER_SLICE = 8;
    int32_t chunks_completed = 0;
    int32_t phase_fusions = 0;
    const char *yield_reason = "stage_boundary";
    const auto slice_budget_exhausted = [&]() {
        return elapsed_ms(slice_start) >= slice_budget_ms;
    };
    const auto finish_chunk_and_should_yield = [&]() {
        ++chunks_completed;
        if (chunks_completed >= MAX_CHUNKS_PER_SLICE) {
            yield_reason = "chunk_cap";
            return true;
        }
        if (slice_budget_exhausted()) {
            yield_reason = "budget";
            return true;
        }
        ++phase_fusions;
        return false;
    };
    _current_day = std::max(_current_day, day_index);
    int64_t work_done = 0;
    int32_t cursor_start = 0;
    int32_t cursor_end = 0;
    std::string error;
    if (!_bootstrapped || _fatal) {
        out = compact ? compact_report() : report();
        out["done"] = true;
        out["work_done"] = 0;
        out["elapsed_ms"] = elapsed_ms(slice_start);
        return out;
    }
    if (!_epoch_active) {
        if (!should_run(day_index)) {
            out = compact ? compact_report() : report();
            out["done"] = true;
            out["work_done"] = 0;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        if (!process_due_canal_projects(day_index, error) ||
            !process_due_family_expeditions(day_index, error)) {
            fail(error);
            out = compact ? compact_report() : report();
            out["done"] = true;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        const bool cycle_due = day_index > _last_committed_day;
        if (cycle_due && trade_planner_should_run()) {
            _stage = Stage::TRADE_PLANNING;
            _executed_stage = Stage::TRADE_PLANNING;
            if (!run_trade_planner_slice(work_done, error)) {
                fail(error);
                out = compact ? compact_report() : report();
                out["done"] = true;
                out["work_done"] = work_done;
                out["elapsed_ms"] = elapsed_ms(slice_start);
                return out;
            }
            // Advance one bounded planner slice every day, then settle the due
            // phase in the same native call. Planning never delays local cadence.
            _stage = Stage::EPOCH_BEGIN;
        }
        if (!cycle_due && trade_planner_should_run()) {
            _stage = Stage::TRADE_PLANNING;
            _executed_stage = Stage::TRADE_PLANNING;
            if (!run_trade_planner_slice(work_done, error)) fail(error);
            if (!_fatal && _trade_plan.phase == TradePlanStore::IDLE)
                _stage = Stage::IDLE;
            out = compact ? compact_report() : report();
            out["done"] = true;
            out["work_done"] = work_done;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
        _stage = Stage::EPOCH_BEGIN;
        _executed_stage = Stage::EPOCH_BEGIN;
        if (!start_epoch(day_index, error)) {
            fail(error);
            out = compact ? compact_report() : report();
            out["done"] = true;
            out["elapsed_ms"] = elapsed_ms(slice_start);
            return out;
        }
    }
    ++_continuation_slices;

    // Continue through up to MAX_CHUNKS_PER_SLICE deterministic ranges. Range
    // boundaries and work order are state-derived; elapsed time only decides
    // whether the next range runs now or in the continuation.
    bool command_range_used = false;
    bool cell_range_used = false;
    bool structural_range_used = false;
    bool building_range_used = false;
    while (_epoch_active && !_fatal) {
        if (_stage == Stage::BUILDING_PLAN) {
            _executed_stage = Stage::BUILDING_PLAN;
            const auto start = Clock::now();
            const bool evaluate_phase = _building_plan_phase == 0;
            cursor_start = evaluate_phase ? _plan_evaluate_cursor
                                          : _building_cell_cursor;
            const int32_t end = evaluate_phase
                ? plan_evaluate_slice_end(_plan_evaluate_cursor)
                : building_plan_slice_end(_building_cell_cursor);
            if (evaluate_phase) {
                _executed_substage = "evaluate";
                const int32_t cell_count = end - _plan_evaluate_cursor;
                int64_t estimated_work = 0;
                _production_cell_weights_scratch.resize(
                    static_cast<size_t>(cell_count));
                for (int32_t relative = 0; relative < cell_count; ++relative) {
                    const int32_t cell = _epoch_plan_cells[
                        _plan_evaluate_cursor + relative];
                    int64_t cell_work = 1;
                    for (int32_t group = _building_cell_offsets[cell];
                         group < _building_cell_offsets[cell + 1]; ++group) {
                        const int32_t type_id = _buildings[group].type_id;
                        if (type_id < 0 || type_id >= static_cast<int32_t>(
                                _building_types.size())) {
                            ++cell_work;
                            continue;
                        }
                        const BuildingType &type = _building_types[type_id];
                        cell_work += 8 +
                            static_cast<int64_t>(type.input_count) * 4 +
                            static_cast<int64_t>(type.output_count) * 3 +
                            static_cast<int64_t>(type.employee_count) * 2 +
                            static_cast<int64_t>(type.resource_count) * 2;
                    }
                    _production_cell_weights_scratch[relative] = cell_work;
                    estimated_work += cell_work;
                }
                const int32_t default_tasks = _worker_task_cap <= 1
                    ? 1
                    : static_cast<int32_t>(std::clamp<int64_t>(
                        (estimated_work + 1023) / 1024, 2,
                        _worker_task_cap));
                const int32_t task_count = _worker_enabled &&
                        cell_count >= 2 && estimated_work >= 128 &&
                        godot::WorkerThreadPool::get_singleton() != nullptr
                    ? std::min({cell_count, _worker_task_cap,
                        _worker_tasks_hint > 0
                        ? _worker_tasks_hint : default_tasks})
                    : 1;
                _building_plan_worker_tasks_max = std::max(
                    _building_plan_worker_tasks_max, task_count);
                if (task_count > 1)
                    ++_building_plan_worker_parallel_dispatches;
                _building_plan_results_scratch.resize(
                    static_cast<size_t>(task_count));
                _production_task_offsets_scratch.assign(
                    static_cast<size_t>(task_count + 1), 0);
                _production_task_offsets_scratch[task_count] = cell_count;
                int32_t previous = 0;
                int64_t prefix_work = 0;
                for (int32_t task = 1; task < task_count; ++task) {
                    const int64_t target =
                        (estimated_work * task + task_count - 1) / task_count;
                    const int32_t last_allowed =
                        cell_count - (task_count - task);
                    int32_t boundary = previous;
                    while (boundary < last_allowed &&
                           prefix_work < target) {
                        prefix_work +=
                            _production_cell_weights_scratch[boundary];
                        ++boundary;
                    }
                    if (boundary <= previous) {
                        prefix_work +=
                            _production_cell_weights_scratch[previous];
                        boundary = previous + 1;
                    }
                    _production_task_offsets_scratch[task] = boundary;
                    previous = boundary;
                }
                auto run_plan_tasks = [&](int32_t task_begin,
                                          int32_t task_end) {
                    for (int32_t task = task_begin; task < task_end; ++task) {
                        BuildingPlanResult &task_result =
                            _building_plan_results_scratch[task];
                        std::string task_error;
                        const auto task_started = Clock::now();
                        task_result.ok = prepare_building_economic_plan(
                            _plan_evaluate_cursor +
                                _production_task_offsets_scratch[task],
                            _plan_evaluate_cursor +
                                _production_task_offsets_scratch[task + 1],
                            &_epoch_plan_cells, task_result, task_error);
                        task_result.worker_ms = elapsed_ms(task_started);
                        if (!task_result.ok)
                            task_result.error = std::move(task_error);
                    }
                };
                if (task_count > 1) {
                    parallel_for_range("pk_economy_building_plan",
                                       task_count, task_count, 1,
                                       run_plan_tasks);
                } else {
                    run_plan_tasks(0, 1);
                }
                for (int32_t task = 0; task < task_count; ++task) {
                    const BuildingPlanResult &task_result =
                        _building_plan_results_scratch[task];
                    _building_plan_worker_cpu_ms += task_result.worker_ms;
                    _saturation_count += task_result.saturation_count;
                    _merchant_credit_budget = saturating_add(
                        _merchant_credit_budget,
                        task_result.merchant_credit_budget,
                        _saturation_count);
                    _merchant_credit_committed = saturating_add(
                        _merchant_credit_committed,
                        task_result.merchant_credit_committed,
                        _saturation_count);
                    _recovery_candidates = saturating_add(
                        _recovery_candidates,
                        task_result.recovery_candidates,
                        _saturation_count);
                    _recovery_approved = saturating_add(
                        _recovery_approved,
                        task_result.recovery_approved,
                        _saturation_count);
                    _loss_suspended_building_groups = saturating_add(
                        _loss_suspended_building_groups,
                        task_result.loss_suspended_building_groups,
                        _saturation_count);
                    _unprofitable_building_groups = saturating_add(
                        _unprofitable_building_groups,
                        task_result.unprofitable_building_groups,
                        _saturation_count);
                    _utilization_sum_q16 = saturating_add(
                        _utilization_sum_q16,
                        task_result.utilization_sum_q16,
                        _saturation_count);
                    if (!task_result.ok && !_fatal) {
                        fail(task_result.error.empty()
                            ? "building_plan_failed"
                            : task_result.error);
                    }
                }
            } else {
                _executed_substage = "reserve";
                rebuild_production_input_reserves(
                    _building_cell_cursor, end, false);
            }
            if (!_fatal) {
                work_done += end - cursor_start;
                if (evaluate_phase) _plan_evaluate_cursor = end;
                else _building_cell_cursor = end;
            }
            cursor_end = evaluate_phase ? _plan_evaluate_cursor
                                        : _building_cell_cursor;
            const double plan_slice_ms = elapsed_ms(start);
            _building_plan_ms += plan_slice_ms;
            if (evaluate_phase)
                _building_plan_evaluate_ms += plan_slice_ms;
            else
                _building_plan_reserve_ms += plan_slice_ms;
            building_range_used = true;
            if (_fatal) break;
            const bool plan_range_incomplete = evaluate_phase
                ? _plan_evaluate_cursor < static_cast<int32_t>(
                    _epoch_plan_cells.size())
                : _building_cell_cursor < static_cast<int32_t>(
                    _epoch_building_cells.size());
            if (finish_chunk_and_should_yield()) break;
            if (plan_range_incomplete) continue;
            if (evaluate_phase) {
                _plan_evaluate_cursor = 0;
                _building_cell_cursor = 0;
                _building_plan_phase = 1;
            } else {
                _building_cell_cursor = 0;
                _building_plan_phase = 0;
                _stage = Stage::TRADE_SETTLE;
            }
            break;
        }
        if (_stage == Stage::TRADE_SETTLE) {
            _executed_stage = Stage::TRADE_SETTLE;
            if (!settle_due_trade_orders(error)) {
                fail(error);
                break;
            }
            _stage = Stage::LEDGER_APPLY;
            continue;
        }
        if (_stage == Stage::LEDGER_APPLY) {
            _executed_stage = Stage::LEDGER_APPLY;
            const auto start = Clock::now();
            cursor_start = _command_cursor;
            const int32_t end = std::min<int32_t>(static_cast<int32_t>(_epoch_commands.size()),
                                                  _command_cursor + _commands_per_slice);
            for (; _command_cursor < end; ++_command_cursor) {
                const Command &command = _epoch_commands[_command_cursor];
                if (!apply_command(command, error)) {
                    if (command.effect_request_id != 0) {
                        EffectCommandResult &result = _effect_command_results[
                            command.effect_request_id];
                        result.complete = 1;
                        result.ok = 0;
                        result.reason = error.empty()
                            ? "effect_economy_commit_failed" : error;
                    }
                    fail(error);
                    break;
                }
                if (command.effect_request_id != 0) {
                    EffectCommandResult &result = _effect_command_results[
                        command.effect_request_id];
                    result.complete = 1;
                    result.ok = 1;
                    result.reason.clear();
                }
                ++_processed_commands;
                ++work_done;
            }
            cursor_end = _command_cursor;
            _ledger_ms += elapsed_ms(start);
            command_range_used = true;
            if (_fatal) break;
            const bool command_range_incomplete =
                _command_cursor < static_cast<int32_t>(_epoch_commands.size());
            if (finish_chunk_and_should_yield()) break;
            if (command_range_incomplete) continue;
            _stage = _buildings.empty()
                ? Stage::HOUSEHOLD_MARKET : Stage::BUILDING_EMPLOYMENT;
            continue;
        }
        if (_stage == Stage::TRADE_DISPATCH) {
            _executed_stage = Stage::TRADE_DISPATCH;
            if (!dispatch_trade_candidates(error)) {
                fail(error);
                break;
            }
            _stage = Stage::STRUCTURAL_COMMIT;
            continue;
        }
        if (_stage == Stage::BUILDING_EMPLOYMENT) {
            _executed_stage = Stage::BUILDING_EMPLOYMENT;
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t end = building_slice_end(_building_cell_cursor);
            for (; _building_cell_cursor < end; ++_building_cell_cursor) {
                if (!run_building_employment_cell(
                        _epoch_building_cells[_building_cell_cursor], true, error)) {
                    fail(error.empty() ? "building_employment_failed" : error);
                    break;
                }
                ++work_done;
            }
            cursor_end = _building_cell_cursor;
            _employment_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal) break;
            const bool employment_range_incomplete =
                _building_cell_cursor < static_cast<int32_t>(
                    _epoch_building_cells.size());
            if (finish_chunk_and_should_yield()) break;
            if (employment_range_incomplete) continue;
            _building_cell_cursor = 0;
            prepare_due_demand_basis_cache();
            _stage = Stage::BUILDING_PRODUCTION;
            continue;
        }
        if (_stage == Stage::BUILDING_PRODUCTION) {
            _executed_stage = Stage::BUILDING_PRODUCTION;
            const auto start = Clock::now();
            cursor_start = _building_cell_cursor;
            const int32_t base_end = building_slice_end(_building_cell_cursor);
            const int32_t end = batch_multiplier == 1
                ? base_end
                : building_slice_end(
                    _building_cell_cursor,
                    std::min<int64_t>(
                        std::numeric_limits<int32_t>::max(),
                        static_cast<int64_t>(_building_cells_per_slice) *
                            batch_multiplier),
                    std::min<int64_t>(
                        std::numeric_limits<int32_t>::max(),
                        static_cast<int64_t>(_building_groups_per_slice) *
                            batch_multiplier));
            if (end > base_end)
                ++_high_speed_production_dispatches_saved;
            const int32_t cell_count = end - _building_cell_cursor;
            _building_funded_capacity_q16.resize(_buildings.size(), 0);
            _building_working_capital_allocated.resize(_buildings.size(), 0);
            _building_recovery_probe_capacity_q16.resize(_buildings.size(), 0);
            _building_recovery_liquidation_eligible.resize(_buildings.size(), 0);
            if (_production_results_scratch.size() <
                    static_cast<size_t>(cell_count)) {
                _production_results_scratch.resize(
                    static_cast<size_t>(cell_count));
            }
            for (int32_t relative = 0; relative < cell_count; ++relative)
                _production_results_scratch[relative].reset();
            int64_t estimated_work = 0;
            bool disjoint_markets = true;
            _production_cell_weights_scratch.resize(
                static_cast<size_t>(cell_count));
            for (int32_t relative = 0; relative < cell_count; ++relative) {
                const int32_t cell = _epoch_building_cells[
                    _building_cell_cursor + relative];
                const int32_t group_begin = _building_cell_offsets[cell];
                const int32_t group_end = _building_cell_offsets[cell + 1];
                int64_t cell_work = 1;
                for (int32_t group_index = group_begin;
                     group_index < group_end; ++group_index) {
                    const BuildingGroup &group = _buildings[group_index];
                    if (group.type_id < 0 ||
                        group.type_id >= static_cast<int32_t>(_building_types.size())) {
                        ++cell_work;
                        continue;
                    }
                    const BuildingType &type = _building_types[group.type_id];
                    // Weight the dominant production lanes without inspecting
                    // mutable state. This remains deterministic and cheap:
                    // recipe alternatives and employment roles are the most
                    // expensive inner loops, followed by outputs/resources.
                    cell_work += 8 +
                        static_cast<int64_t>(type.employee_count) * 2 +
                        static_cast<int64_t>(type.input_count) * 4 +
                        static_cast<int64_t>(type.output_count) * 2 +
                        static_cast<int64_t>(type.resource_count) * 2 +
                        static_cast<int64_t>(type.generation_count) * 2 +
                        static_cast<int64_t>(type.market_signal_count);
                    for (int32_t input_offset = 0;
                         input_offset < type.input_count; ++input_offset) {
                        const int32_t input_index =
                            type.input_begin + input_offset;
                        if (input_index >= 0 &&
                            input_index < static_cast<int32_t>(_building_inputs.size())) {
                            cell_work +=
                                _building_inputs[input_index].candidate_count;
                        }
                    }
                }
                _production_cell_weights_scratch[relative] = cell_work;
                estimated_work += cell_work;
                disjoint_markets = disjoint_markets &&
                    _market.cell_to_market[cell] == cell;
            }
            const int32_t production_default_tasks = _worker_task_cap <= 1
                ? 1
                : static_cast<int32_t>(std::clamp<int64_t>(
                    (estimated_work + 1023) / 1024, 2,
                    _worker_task_cap));
            _production_worker_tasks = _worker_enabled && disjoint_markets &&
                    cell_count >= 2 &&
                    estimated_work >= 256 &&
                    godot::WorkerThreadPool::get_singleton() != nullptr
                ? std::min({cell_count, _worker_task_cap,
                    _worker_tasks_hint > 0
                    ? _worker_tasks_hint : production_default_tasks})
                : 1;
            _production_worker_tasks_max = std::max(
                _production_worker_tasks_max, _production_worker_tasks);
            _production_worker_task_sum += _production_worker_tasks;
            ++_production_worker_dispatches;
            _production_worker_weight_total += estimated_work;
            if (_production_worker_tasks > 1)
                ++_production_worker_parallel_dispatches;
            auto run_cells = [&](int32_t range_begin, int32_t range_end) {
                for (int32_t relative = range_begin; relative < range_end; ++relative) {
                    ProductionResult &result =
                        _production_results_scratch[relative];
                    const int64_t capacity_before = result.capacity_bytes();
                    std::string production_error;
                    result.ok = run_building_production_cell(
                        _epoch_building_cells[_building_cell_cursor + relative],
                        result, production_error);
                    result.error = std::move(production_error);
                    const int64_t capacity_after = result.capacity_bytes();
                    if (capacity_after > capacity_before) {
                        result.allocation_growth_count = 1;
                        result.allocation_growth_bytes =
                            capacity_after - capacity_before;
                    }
                }
            };
            const auto worker_started = Clock::now();
            if (_production_worker_tasks > 1) {
                const int32_t task_count = _production_worker_tasks;
                _production_task_offsets_scratch.assign(
                    static_cast<size_t>(task_count + 1), 0);
                _production_task_weights_scratch.assign(
                    static_cast<size_t>(task_count), 0);
                _production_task_ms_scratch.assign(
                    static_cast<size_t>(task_count), 0.0);
                _production_task_offsets_scratch[task_count] = cell_count;
                int32_t previous = 0;
                int64_t prefix_work = 0;
                for (int32_t task = 1; task < task_count; ++task) {
                    const int64_t target =
                        (estimated_work * task + task_count - 1) / task_count;
                    const int32_t last_allowed =
                        cell_count - (task_count - task);
                    int32_t boundary = previous;
                    while (boundary < last_allowed &&
                           prefix_work < target) {
                        prefix_work +=
                            _production_cell_weights_scratch[boundary];
                        ++boundary;
                    }
                    if (boundary <= previous) {
                        prefix_work +=
                            _production_cell_weights_scratch[previous];
                        boundary = previous + 1;
                    }
                    _production_task_offsets_scratch[task] = boundary;
                    previous = boundary;
                }
                for (int32_t task = 0; task < task_count; ++task) {
                    int64_t task_work = 0;
                    for (int32_t relative =
                             _production_task_offsets_scratch[task];
                         relative <
                             _production_task_offsets_scratch[task + 1];
                         ++relative) {
                        task_work +=
                            _production_cell_weights_scratch[relative];
                    }
                    _production_task_weights_scratch[task] = task_work;
                }
                auto run_tasks = [&](int32_t task_begin, int32_t task_end) {
                    for (int32_t task = task_begin; task < task_end; ++task) {
                        const auto task_started = Clock::now();
                        run_cells(_production_task_offsets_scratch[task],
                                  _production_task_offsets_scratch[task + 1]);
                        _production_task_ms_scratch[task] =
                            elapsed_ms(task_started);
                    }
                };
                parallel_for_range("pk_economy_building_production",
                                   task_count, task_count, 1, run_tasks);
                const auto weight_minmax = std::minmax_element(
                    _production_task_weights_scratch.begin(),
                    _production_task_weights_scratch.end());
                const int64_t task_weight_min = *weight_minmax.first;
                const int64_t task_weight_max = *weight_minmax.second;
                if (_production_worker_task_weight_min == 0) {
                    _production_worker_task_weight_min = task_weight_min;
                } else {
                    _production_worker_task_weight_min = std::min(
                        _production_worker_task_weight_min, task_weight_min);
                }
                _production_worker_task_weight_max = std::max(
                    _production_worker_task_weight_max, task_weight_max);
                const int64_t ideal_weight =
                    (estimated_work + task_count - 1) / task_count;
                if (ideal_weight > 0) {
                    _production_worker_imbalance_q16_max = std::max(
                        _production_worker_imbalance_q16_max,
                        task_weight_max * Q16_ONE / ideal_weight);
                }
                _production_worker_cpu_ms += std::accumulate(
                    _production_task_ms_scratch.begin(),
                    _production_task_ms_scratch.end(), 0.0);
            } else {
                run_cells(0, cell_count);
            }
            _production_worker_ms += elapsed_ms(worker_started);
            const auto merge_started = Clock::now();
            for (int32_t relative = 0; relative < cell_count; ++relative) {
                ProductionResult &result =
                    _production_results_scratch[relative];
                merge_building_production_result(result);
                const int32_t produced_cell = _epoch_building_cells[
                    _building_cell_cursor + relative];
                stage_cell_summary(
                    produced_cell, build_cell_summary(produced_cell));
                if (!result.ok && !_fatal) {
                    fail(result.error.empty() ? "building_production_failed"
                                               : result.error);
                }
                if (result.ok) ++work_done;
            }
            _production_merge_ms += elapsed_ms(merge_started);
            if (!_fatal) _building_cell_cursor = end;
            cursor_end = _building_cell_cursor;
            _production_ms += elapsed_ms(start);
            building_range_used = true;
            if (_fatal) break;
            const bool production_range_incomplete =
                _building_cell_cursor < static_cast<int32_t>(
                    _epoch_building_cells.size());
            if (finish_chunk_and_should_yield()) break;
            if (production_range_incomplete) continue;
            _building_cell_cursor = 0;
            std::stable_sort(_owner_retained_outputs.begin(), _owner_retained_outputs.end(),
                [](const OwnerRetainedOutput &a, const OwnerRetainedOutput &b) {
                    if (a.owner_slot != b.owner_slot) return a.owner_slot < b.owner_slot;
                    if (a.good_id != b.good_id) return a.good_id < b.good_id;
                    return a.building_group < b.building_group;
                });
            size_t retained_write = 0;
            for (const OwnerRetainedOutput &entry : _owner_retained_outputs) {
                if (entry.quantity <= 0) continue;
                if (retained_write > 0 &&
                    _owner_retained_outputs[retained_write - 1].owner_slot == entry.owner_slot &&
                    _owner_retained_outputs[retained_write - 1].good_id == entry.good_id &&
                    _owner_retained_outputs[retained_write - 1].building_group ==
                        entry.building_group) {
                    _owner_retained_outputs[retained_write - 1].quantity = saturating_add(
                        _owner_retained_outputs[retained_write - 1].quantity,
                        entry.quantity, _saturation_count);
                } else {
                    _owner_retained_outputs[retained_write++] = entry;
                }
            }
            _owner_retained_outputs.resize(retained_write);
            _stage = Stage::HOUSEHOLD_MARKET;
            continue;
        }
        if (_stage == Stage::HOUSEHOLD_MARKET) {
            _executed_stage = Stage::HOUSEHOLD_MARKET;
            if (_household_market_phase == 1) {
                _executed_substage = "post_buildings";
                const auto phase_started = Clock::now();
                cursor_start = _household_post_cursor;
                const int32_t end =
                    household_post_slice_end(_household_post_cursor);
                const int32_t begin = _household_post_cursor;
                const int32_t count = end - begin;
                _household_post_saturation_scratch.assign(count, 0);
                _household_post_restarted_scratch.assign(count, 0);
                _household_post_failed_scratch.assign(count, 0);
                const int32_t tasks = _worker_enabled && count >= 2 &&
                        godot::WorkerThreadPool::get_singleton() != nullptr
                    ? std::min(count, _worker_task_cap) : 1;
                auto finalize_cells = [&](int32_t relative_begin,
                                          int32_t relative_end) {
                    for (int32_t relative = relative_begin;
                         relative < relative_end; ++relative) {
                        finalize_household_building_cell(
                            _epoch_building_cells[begin + relative],
                            _household_post_saturation_scratch[relative],
                            _household_post_restarted_scratch[relative],
                            _household_post_failed_scratch[relative]);
                    }
                };
                if (tasks > 1) {
                    parallel_for_range("pk_economy_household_post", count,
                                       tasks, 1, finalize_cells);
                } else {
                    finalize_cells(0, count);
                }
                for (int32_t relative = 0; relative < count; ++relative) {
                    _saturation_count = saturating_add(
                        _saturation_count,
                        _household_post_saturation_scratch[relative],
                        _saturation_count);
                    _recovery_restarted = saturating_add(
                        _recovery_restarted,
                        _household_post_restarted_scratch[relative],
                        _saturation_count);
                    _recovery_failed = saturating_add(
                        _recovery_failed,
                        _household_post_failed_scratch[relative],
                        _saturation_count);
                }
                _household_post_cursor = end;
                work_done += end - cursor_start;
                cursor_end = _household_post_cursor;
                building_range_used = true;
                if (_household_post_cursor >= static_cast<int32_t>(
                        _epoch_building_cells.size())) {
                    _household_post_cursor = 0;
                    _household_market_phase = 2;
                }
                _household_slice_phase_ms[HOUSEHOLD_POST_BUILDINGS] +=
                    elapsed_ms(phase_started);
                _household_slice_phase_work[HOUSEHOLD_POST_BUILDINGS] +=
                    end - begin;
                if (finish_chunk_and_should_yield()) break;
                continue;
            }
            if (_household_market_phase == 2) {
                _executed_substage = "reserve_shortfall";
                const auto phase_started = Clock::now();
                cursor_start = _household_post_cursor;
                const int32_t end = std::min<int32_t>(
                    static_cast<int32_t>(_epoch_settlement_cells.size()),
                    _household_post_cursor + PUBLISH_ENTRIES_PER_SLICE);
                const int32_t begin = _household_post_cursor;
                const int32_t count = end - begin;
                _household_reserve_shortfall_scratch.assign(count, 0);
                _household_post_saturation_scratch.assign(count, 0);
                const int32_t tasks = _worker_enabled && count >= 2 &&
                        godot::WorkerThreadPool::get_singleton() != nullptr
                    ? std::min(count, _worker_task_cap) : 1;
                auto accumulate_cells = [&](int32_t relative_begin,
                                            int32_t relative_end) {
                    for (int32_t relative = relative_begin;
                         relative < relative_end; ++relative) {
                        _household_reserve_shortfall_scratch[relative] =
                            production_reserve_shortfall_cell(
                                _epoch_settlement_cells[begin + relative],
                                _household_post_saturation_scratch[relative]);
                    }
                };
                if (tasks > 1) {
                    parallel_for_range("pk_economy_household_reserve", count,
                                       tasks, 1, accumulate_cells);
                } else {
                    accumulate_cells(0, count);
                }
                for (int32_t relative = 0; relative < count; ++relative) {
                    _saturation_count = saturating_add(
                        _saturation_count,
                        _household_post_saturation_scratch[relative],
                        _saturation_count);
                    _production_input_reserve_shortfall = saturating_add(
                        _production_input_reserve_shortfall,
                        _household_reserve_shortfall_scratch[relative],
                        _saturation_count);
                }
                _household_post_cursor = end;
                work_done += end - cursor_start;
                cursor_end = _household_post_cursor;
                cell_range_used = true;
                if (_household_post_cursor >= static_cast<int32_t>(
                        _epoch_settlement_cells.size())) {
                    _household_post_cursor = 0;
                    _household_market_phase = 3;
                }
                _household_slice_phase_ms[HOUSEHOLD_RESERVE_SHORTFALL] +=
                    elapsed_ms(phase_started);
                _household_slice_phase_work[HOUSEHOLD_RESERVE_SHORTFALL] +=
                    end - begin;
                if (finish_chunk_and_should_yield()) break;
                continue;
            }
            if (_household_market_phase == 3) {
                _executed_substage = "income_subsidy";
                const auto phase_started = Clock::now();
                cursor_start = _household_post_cursor;
                const int32_t begin = _household_post_cursor;
                const int32_t end = std::min<int32_t>(
                    static_cast<int32_t>(_epoch_settlement_cells.size()),
                    _household_post_cursor + PUBLISH_ENTRIES_PER_SLICE);
                for (; _household_post_cursor < end;
                     ++_household_post_cursor) {
                    settle_income_subsidies_for_cell(
                        _epoch_settlement_cells[_household_post_cursor],
                        _saturation_count);
                    ++work_done;
                }
                cursor_end = _household_post_cursor;
                cell_range_used = true;
                if (_household_post_cursor >= static_cast<int32_t>(
                        _epoch_settlement_cells.size())) {
                    _household_post_cursor = 0;
                    _household_market_phase = 4;
                }
                _household_slice_phase_ms[HOUSEHOLD_INCOME_SUBSIDY] +=
                    elapsed_ms(phase_started);
                _household_slice_phase_work[HOUSEHOLD_INCOME_SUBSIDY] +=
                    end - begin;
                if (finish_chunk_and_should_yield()) break;
                continue;
            }
            if (_household_market_phase == 4) {
                _executed_substage = "structural_sort";
                const auto phase_started = Clock::now();
                if (_approximation_cooldown_epochs_left > 0) {
                    --_approximation_cooldown_epochs_left;
                } else if (_accuracy_preset != 0 &&
                           _approximation_runtime_mode != 0 &&
                           _approximation_decisions > 0) {
                    const bool low_prune_rate =
                        _approximation_frontier_candidates <= 0 ||
                        _approximation_frontier_pruned * 50 <
                            _approximation_frontier_candidates;
                    _approximation_low_prune_epochs = low_prune_rate
                        ? _approximation_low_prune_epochs + 1 : 0;
                    const bool excessive_certificate_failures =
                        _approximation_certificate_failures * 4 >
                            _approximation_decisions;
                    if (_approximation_probe_violations > 0 ||
                        excessive_certificate_failures ||
                        _approximation_low_prune_epochs >= 2) {
                        _approximation_cooldown_epochs_left =
                            _accuracy_fallback_cooldown_epochs;
                        _approximation_low_prune_epochs = 0;
                    }
                }
                std::stable_sort(_structural_commands.begin(), _structural_commands.end(),
                                 [](const StructuralCommand &a, const StructuralCommand &b) {
                    if (a.cell != b.cell) return a.cell < b.cell;
                    const int32_t a_phase = a.opcode == STRUCTURAL_BIRTH ? 1 : 0;
                    const int32_t b_phase = b.opcode == STRUCTURAL_BIRTH ? 1 : 0;
                    if (a_phase != b_phase) return a_phase < b_phase;
                    if (a.signature != b.signature) return a.signature < b.signature;
                    if (a.sequence != b.sequence) return a.sequence < b.sequence;
                    return a.source_slot < b.source_slot;
                });
                work_done += static_cast<int64_t>(_structural_commands.size());
                _household_slice_phase_ms[HOUSEHOLD_STRUCTURAL_SORT] +=
                    elapsed_ms(phase_started);
                _household_slice_phase_work[HOUSEHOLD_STRUCTURAL_SORT] +=
                    static_cast<int64_t>(_structural_commands.size());
                _household_market_phase = 0;
                _stage = Stage::GOVERNMENT_RESEARCH_PROCUREMENT;
                if (finish_chunk_and_should_yield()) break;
                continue;
            }
            _executed_substage = "settle";
            const auto settle_started = Clock::now();
            cursor_start = _cell_cursor;
            const int32_t begin = _cell_cursor;
            int32_t end = begin;
            int64_t slice_cohorts = 0;
            if (_auto_slice_by_scale) {
                // Cohort count, not cell count, is the dominant cost. Stop at
                // a deterministic cohort budget so unevenly populated cells do
                // not create an accidental long slice.
                while (end < static_cast<int32_t>(_epoch_market_ids.size()) &&
                       end - begin < _cells_per_slice * batch_multiplier &&
                       (end == begin || slice_cohorts <
                            _target_cohorts_per_slice * batch_multiplier)) {
                    const int32_t market = _epoch_market_ids[end];
                    for (int32_t k = _market_cell_offsets[market];
                         k < _market_cell_offsets[market + 1]; ++k) {
                        slice_cohorts += _committed_cells[_market_cells[k]].cohort_count;
                    }
                    ++end;
                }
            } else {
                end = std::min<int32_t>(static_cast<int32_t>(_epoch_market_ids.size()),
                                        begin + _cells_per_slice *
                                            batch_multiplier);
            }
            if (batch_multiplier > 1) {
                int32_t base_end = begin;
                int64_t base_cohorts = 0;
                if (_auto_slice_by_scale) {
                    while (base_end < static_cast<int32_t>(
                               _epoch_market_ids.size()) &&
                           base_end - begin < _cells_per_slice &&
                           (base_end == begin ||
                            base_cohorts < _target_cohorts_per_slice)) {
                        const int32_t market = _epoch_market_ids[base_end];
                        for (int32_t k = _market_cell_offsets[market];
                             k < _market_cell_offsets[market + 1]; ++k) {
                            base_cohorts +=
                                _committed_cells[_market_cells[k]].cohort_count;
                        }
                        ++base_end;
                    }
                } else {
                    base_end = std::min<int32_t>(
                        static_cast<int32_t>(_epoch_market_ids.size()),
                        begin + _cells_per_slice);
                }
                if (end > base_end)
                    ++_high_speed_market_dispatches_saved;
            }
            const int32_t market_count = end - begin;
            if (_market_results_scratch.size() < static_cast<size_t>(market_count))
                _market_results_scratch.resize(static_cast<size_t>(market_count));
            for (int32_t relative = 0; relative < market_count; ++relative) {
                _market_results_scratch[relative].reset();
                if (_accuracy_preset != 0 &&
                    _approximation_runtime_mode != 0 &&
                    _approximation_cooldown_epochs_left == 0) {
                    _market_results_scratch[relative].
                        approximation_variant_active.assign(
                            _variants.size(), uint8_t{1});
                }
            }
            int64_t estimated_work = 0;
            _production_cell_weights_scratch.resize(
                static_cast<size_t>(market_count));
            for (int32_t relative = 0; relative < market_count; ++relative) {
                const int64_t market_work =
                    _epoch_market_work_weights[begin + relative];
                _production_cell_weights_scratch[relative] = market_work;
                estimated_work += market_work;
            }
            const int32_t economy_default_tasks = _worker_task_cap <= 1
                ? 1
                : static_cast<int32_t>(std::clamp<int64_t>(
                    (estimated_work + 1023) / 1024, 2,
                    _worker_task_cap));
            _worker_tasks = _worker_enabled &&
                                    market_count >= 2 &&
                                    estimated_work >= 256 &&
                                    godot::WorkerThreadPool::get_singleton() != nullptr
                                ? std::min({market_count, _worker_task_cap,
                                           _worker_tasks_hint > 0
                                               ? _worker_tasks_hint
                                               : economy_default_tasks})
                                : 1;
            _market_worker_tasks_max = std::max(
                _market_worker_tasks_max, _worker_tasks);
            _market_worker_task_sum += _worker_tasks;
            ++_market_worker_dispatches;
            auto run_markets = [&](int32_t range_begin, int32_t range_end) {
                for (int32_t relative = range_begin; relative < range_end; ++relative) {
                    MarketResult &market_result = _market_results_scratch[relative];
                    const int64_t capacity_before = market_result.capacity_bytes();
                    std::string market_error;
                    market_result.ok = process_market_cell(
                        _epoch_market_ids[begin + relative], market_result, market_error);
                    market_result.error = std::move(market_error);
                    const int64_t capacity_after = market_result.capacity_bytes();
                    if (capacity_after > capacity_before) {
                        market_result.allocation_growth_count = 1;
                        market_result.allocation_growth_bytes =
                            capacity_after - capacity_before;
                    }
                }
            };
            const double slice_prepare_ms = elapsed_ms(settle_started);
            _household_slice_phase_ms[HOUSEHOLD_PREPARE] += slice_prepare_ms;
            _household_slice_phase_work[HOUSEHOLD_PREPARE] += market_count;
            const auto worker_started = Clock::now();
            if (_worker_tasks > 1) {
                ++_market_worker_parallel_dispatches;
                _production_task_offsets_scratch.assign(
                    static_cast<size_t>(_worker_tasks + 1), 0);
                _production_task_offsets_scratch[_worker_tasks] =
                    market_count;
                int32_t previous = 0;
                int64_t prefix_work = 0;
                for (int32_t task = 1; task < _worker_tasks; ++task) {
                    const int64_t target =
                        (estimated_work * task + _worker_tasks - 1) /
                        _worker_tasks;
                    const int32_t last_allowed =
                        market_count - (_worker_tasks - task);
                    int32_t boundary = previous;
                    while (boundary < last_allowed &&
                           prefix_work < target) {
                        prefix_work +=
                            _production_cell_weights_scratch[boundary];
                        ++boundary;
                    }
                    if (boundary <= previous) {
                        prefix_work +=
                            _production_cell_weights_scratch[previous];
                        boundary = previous + 1;
                    }
                    _production_task_offsets_scratch[task] = boundary;
                    previous = boundary;
                }
                if (_staging_cell_generation.size() != _staging_cells.size())
                    _staging_cell_generation.assign(_staging_cells.size(), 0);
                _staging_touched_task_scratch.resize(
                    static_cast<size_t>(_worker_tasks));
                for (std::vector<int32_t> &buffer :
                         _staging_touched_task_scratch) {
                    buffer.clear();
                }
                auto run_market_tasks = [&](int32_t task_begin,
                                            int32_t task_end) {
                    // parallel_for_range may run tasks on the calling thread,
                    // so restore rather than clear the sink on the way out.
                    std::vector<int32_t> *const outer_sink =
                        _staging_touched_sink;
                    for (int32_t task = task_begin; task < task_end; ++task) {
                        _staging_touched_sink =
                            &_staging_touched_task_scratch[task];
                        run_markets(
                            _production_task_offsets_scratch[task],
                            _production_task_offsets_scratch[task + 1]);
                    }
                    _staging_touched_sink = outer_sink;
                };
                parallel_for_range("pk_economy_markets", _worker_tasks,
                                   _worker_tasks, 1, run_market_tasks);
                for (std::vector<int32_t> &buffer :
                         _staging_touched_task_scratch) {
                    _staging_touched_cells.insert(_staging_touched_cells.end(),
                                                  buffer.begin(), buffer.end());
                    buffer.clear();
                }
            } else {
                run_markets(0, market_count);
            }
            const double slice_worker_ms = elapsed_ms(worker_started);
            _market_worker_ms += slice_worker_ms;
            _household_slice_phase_ms[HOUSEHOLD_WORKER] += slice_worker_ms;
            _household_slice_phase_work[HOUSEHOLD_WORKER] += market_count;
            const auto merge_started = Clock::now();
            const auto trade_bulk_started = Clock::now();
            _trade_signal_bulk_keys_scratch.clear();
            for (int32_t relative = 0; relative < market_count; ++relative) {
                const int32_t market = _epoch_market_ids[begin + relative];
                const MarketResult &market_result = _market_results_scratch[relative];
                for (const int32_t good : market_result.trade_active_goods) {
                    if (good < 0 || good >= _market.good_count) continue;
                    _trade_signal_bulk_keys_scratch.push_back(
                        (static_cast<uint64_t>(static_cast<uint32_t>(market)) << 32) |
                        static_cast<uint32_t>(good));
                }
            }
            std::sort(_trade_signal_bulk_keys_scratch.begin(),
                      _trade_signal_bulk_keys_scratch.end());
            _trade_signal_bulk_keys_scratch.erase(
                std::unique(_trade_signal_bulk_keys_scratch.begin(),
                            _trade_signal_bulk_keys_scratch.end()),
                _trade_signal_bulk_keys_scratch.end());
            ensure_trade_signal_clock_keys_bulk(_trade_signal_bulk_keys_scratch);
            double slice_trade_ms = elapsed_ms(trade_bulk_started);
            double slice_aggregate_ms = 0.0;
            for (int32_t relative = 0; relative < market_count; ++relative) {
                const int32_t market = _epoch_market_ids[begin + relative];
                MarketResult &market_result = _market_results_scratch[relative];
                const auto aggregate_merge_started = Clock::now();
                if (!market_result.ok) {
                    fail(market_result.error.empty() ? "household_market_internal_failure"
                                                     : market_result.error);
                    break;
                }
                _processed_cells += _market_cell_offsets[market + 1] -
                                    _market_cell_offsets[market];
                _processed_cohorts = saturating_add(_processed_cohorts,
                                                    market_result.processed_cohorts,
                                                    _saturation_count);
                _processed_rules = saturating_add(_processed_rules,
                                                  market_result.processed_rules,
                                                  _saturation_count);
                _saturation_count = saturating_add(_saturation_count,
                                                   market_result.saturation_count,
                                                   _saturation_count);
                _consumed_goods = saturating_add(_consumed_goods, market_result.consumed_goods,
                                                 _saturation_count);
                _production_output_retained = saturating_add(
                    _production_output_retained, market_result.retained_output_consumed,
                    _saturation_count);
                _owner_output_consumed = saturating_add(
                    _owner_output_consumed, market_result.retained_output_consumed,
                    _saturation_count);
                _production_output_discarded = saturating_add(
                    _production_output_discarded, market_result.retained_output_discarded,
                    _saturation_count);
                _owner_working_capital_reserved = saturating_add(
                    _owner_working_capital_reserved,
                    market_result.owner_working_capital_reserved, _saturation_count);
                for (const BuildingInKindCredit &credit :
                        market_result.building_in_kind_credits) {
                    if (credit.building_group < 0 || credit.building_group >=
                            static_cast<int32_t>(_building_owner_livelihood_credit.size()))
                        continue;
                    _building_owner_livelihood_credit[credit.building_group] = saturating_add(
                        _building_owner_livelihood_credit[credit.building_group],
                        credit.frozen_value, _saturation_count);
                }
                _births = saturating_add(_births, market_result.births, _saturation_count);
                _deaths = saturating_add(_deaths, market_result.deaths, _saturation_count);
                for (const PersonMarketAttribution &attribution :
                        market_result.person_attributions) {
                    int32_t person = -1;
                    if (!_persons.valid_handle(attribution.person_handle, person)) continue;
                    _persons.epoch_consumption_expense[person] = saturating_add(
                        _persons.epoch_consumption_expense[person],
                        attribution.consumption_expense, _saturation_count);
                    _persons.epoch_tax[person] = saturating_add(
                        _persons.epoch_tax[person], attribution.consumption_tax,
                        _saturation_count);
                    _persons.needs_satisfaction[person] =
                        attribution.satisfaction_q16;
                    _persons.worst_need_id[person] = attribution.worst_need_id;
                }
                _person_epoch_needs.insert(_person_epoch_needs.end(),
                    market_result.person_needs.begin(),
                    market_result.person_needs.end());
                for (const PersonDemographyEvent &event :
                        market_result.person_demography) {
                    int32_t cohort_slot = -1;
                    if (_population.valid_handle(event.cohort_handle, cohort_slot))
                        record_person_demography(cohort_slot,
                            event.population_before, event.deaths);
                }
                _population_changed_cells.insert(_population_changed_cells.end(),
                    market_result.population_changed_cells.begin(),
                    market_result.population_changed_cells.end());
                _publish_accum.population = saturating_add(
                    _publish_accum.population, market_result.closing_population, _saturation_count);
                _publish_accum.cohort_funds = saturating_add(
                    _publish_accum.cohort_funds, market_result.closing_cohort_funds,
                    _saturation_count);
                _publish_accum.goods_stock = saturating_add(
                    _publish_accum.goods_stock, market_result.closing_goods_stock,
                    _saturation_count);
                _formula_ms += market_result.formula_ms;
                _clear_ms += market_result.clear_ms;
                _processed_needs = saturating_add(_processed_needs, market_result.processed_needs,
                                                  _saturation_count);
                _processed_variants = saturating_add(_processed_variants,
                                                     market_result.processed_variants,
                                                     _saturation_count);
                _processed_components = saturating_add(_processed_components,
                                                       market_result.processed_components,
                                                       _saturation_count);
                _fallback_ms += market_result.fallback_ms;
                _merchant_settle_ms += market_result.merchant_settle_ms;
                _price_ms += market_result.price_ms;
                _merchant_repairs = saturating_add(_merchant_repairs,
                                                   market_result.merchant_repairs,
                                                   _saturation_count);
                _price_cap_hits = saturating_add(_price_cap_hits,
                                                 market_result.price_cap_hits,
                                                 _saturation_count);
                _price_cost_anchor_hits = saturating_add(
                    _price_cost_anchor_hits, market_result.price_cost_anchor_hits,
                    _saturation_count);
                _price_inactive_reversions = saturating_add(
                    _price_inactive_reversions, market_result.price_inactive_reversions,
                    _saturation_count);
                _market_result_allocation_growth_count = saturating_add(
                    _market_result_allocation_growth_count,
                    market_result.allocation_growth_count, _saturation_count);
                _market_result_allocation_growth_bytes = saturating_add(
                    _market_result_allocation_growth_bytes,
                    market_result.allocation_growth_bytes, _saturation_count);
                _approximation_decisions = saturating_add(
                    _approximation_decisions,
                    market_result.approximation_decisions, _saturation_count);
                _approximation_exact_probes = saturating_add(
                    _approximation_exact_probes,
                    market_result.approximation_exact_probes, _saturation_count);
                _approximation_certificate_failures = saturating_add(
                    _approximation_certificate_failures,
                    market_result.approximation_certificate_failures,
                    _saturation_count);
                _approximation_exact_fallbacks = saturating_add(
                    _approximation_exact_fallbacks,
                    market_result.approximation_exact_fallbacks,
                    _saturation_count);
                _approximation_frontier_candidates = saturating_add(
                    _approximation_frontier_candidates,
                    market_result.approximation_frontier_candidates,
                    _saturation_count);
                _approximation_frontier_pruned = saturating_add(
                    _approximation_frontier_pruned,
                    market_result.approximation_frontier_pruned,
                    _saturation_count);
                _approximation_max_observed_regret_q16 = std::max(
                    _approximation_max_observed_regret_q16,
                    market_result.approximation_max_certified_regret_q16);
                _approximation_probe_violations = saturating_add(
                    _approximation_probe_violations,
                    market_result.approximation_probe_violations,
                    _saturation_count);
                _approximation_probe_max_spend_error_q16 = std::max(
                    _approximation_probe_max_spend_error_q16,
                    market_result.approximation_probe_max_spend_error_q16);
                _approximation_probe_max_demand_error_q16 = std::max(
                    _approximation_probe_max_demand_error_q16,
                    market_result.approximation_probe_max_demand_error_q16);
                _structural_commands.insert(_structural_commands.end(),
                                             market_result.structural_commands.begin(),
                                             market_result.structural_commands.end());
                const auto aggregate_finished = Clock::now();
                const double aggregate_ms =
                    std::chrono::duration<double, std::milli>(
                        aggregate_finished - aggregate_merge_started).count();
                _market_merge_aggregate_ms += aggregate_ms;
                slice_aggregate_ms += aggregate_ms;
                const auto trade_merge_started = Clock::now();
                for (const int32_t good : market_result.trade_active_goods) {
                    add_trade_active_key(market, good);
                    const int32_t signal_clock = ensure_trade_signal_clock_index(market, good);
                    if (signal_clock < 0 || signal_clock >= static_cast<int32_t>(
                            _trade_signal_first_seen_day.size())) continue;
                    int64_t signal_sat = 0;
                    const int64_t target = trade_local_stock_target(
                        market, good, signal_sat);
                    const int64_t stock = _market.stock[_market.index(market, good)];
                    const bool needs_trade = target > stock ||
                        trade_relief_pressure_q16(market, good, signal_sat) > 0;
                    _saturation_count = saturating_add(
                        _saturation_count, signal_sat, _saturation_count);
                    if (needs_trade) {
                        if (_trade_signal_first_seen_day[signal_clock] < 0) {
                            _trade_signal_first_seen_day[signal_clock] = _sample_day;
                            ++_trade_deficit_episodes_started;
                            _trade_signal_first_dispatch_day[signal_clock] = -1;
                            _trade_signal_last_attempt_day[signal_clock] = -1;
                            _trade_signal_last_rejection_reason[signal_clock] =
                                TRADE_SIGNAL_DIAG_NONE;
                            _trade_signal_deadline_reported[signal_clock] = 0;
                        }
                    } else {
                        if (_trade_signal_first_seen_day[signal_clock] >= 0)
                            ++_trade_deficit_episodes_resolved;
                        _trade_signal_first_seen_day[signal_clock] = -1;
                        _trade_signal_first_dispatch_day[signal_clock] = -1;
                        _trade_signal_deadline_reported[signal_clock] = 0;
                    }
                }
                slice_trade_ms += elapsed_ms(trade_merge_started);
                ++work_done;
            }
            double slice_trace_ms = 0.0;
            if (!_fatal && _trace_mode != TRACE_OFF) {
                const auto event_start = Clock::now();
                for (int32_t relative = 0; relative < market_count; ++relative) {
                    const int32_t market = _epoch_market_ids[begin + relative];
                    MarketResult &market_result = _market_results_scratch[relative];
                    if (market == _staging_events.cashflow_cell) {
                        for (const CashflowEntry &entry : market_result.cashflows) {
                            trace_record_cashflow(market, entry.cohort_handle,
                                entry.source, entry.income, entry.expense);
                        }
                        _staging_events.welfare_entries =
                            std::move(market_result.welfare_entries);
                    }
                    trace_append(EVENT_MARKET_SETTLED,
                                 static_cast<int32_t>(Stage::HOUSEHOLD_MARKET), market,
                                 SUBJECT_MARKET, market, -1, -1,
                                 market_result.revenue, market_result.consumed_goods,
                                 market_result.changed_prices,
                                 static_cast<int64_t>(market_result.mutation_hash),
                                 market_result.trace_legs.empty() ? nullptr :
                                     &market_result.trace_legs);
                }
                slice_trace_ms = elapsed_ms(event_start);
                _event_summary_ms += slice_trace_ms;
            }
            const double slice_merge_ms = elapsed_ms(merge_started);
            _market_merge_ms += slice_merge_ms;
            _market_merge_trade_ms += slice_trade_ms;
            _household_slice_phase_ms[HOUSEHOLD_MERGE_AGGREGATE] +=
                slice_aggregate_ms;
            _household_slice_phase_work[HOUSEHOLD_MERGE_AGGREGATE] +=
                market_count;
            _household_slice_phase_ms[HOUSEHOLD_MERGE_TRADE] +=
                slice_trade_ms;
            _household_slice_phase_work[HOUSEHOLD_MERGE_TRADE] +=
                market_count;
            _household_slice_phase_ms[HOUSEHOLD_TRACE] += slice_trace_ms;
            _household_slice_phase_work[HOUSEHOLD_TRACE] +=
                _trace_mode == TRACE_OFF ? 0 : market_count;
            _household_slice_phase_ms[HOUSEHOLD_OTHER] += std::max(
                0.0, elapsed_ms(settle_started) - slice_prepare_ms -
                    slice_worker_ms - slice_aggregate_ms -
                    slice_trade_ms - slice_trace_ms);
            _household_slice_phase_work[HOUSEHOLD_OTHER] += market_count;
            _cell_cursor = end;
            cursor_end = _cell_cursor;
            cell_range_used = true;
            if (_fatal) break;
            const bool market_range_incomplete =
                _cell_cursor < static_cast<int32_t>(_epoch_market_ids.size());
            if (finish_chunk_and_should_yield()) break;
            if (market_range_incomplete) continue;
            _household_post_cursor = 0;
            _household_market_phase = 1;
            continue;
        }
        if (_stage == Stage::GOVERNMENT_RESEARCH_PROCUREMENT) {
            _executed_stage = Stage::GOVERNMENT_RESEARCH_PROCUREMENT;
            _executed_substage = "technology_points";
            if (!run_government_research_procurement(error)) {
                fail(error.empty() ? "government_research_procurement_failed" : error);
                break;
            }
            ++work_done;
            _stage = Stage::TRADE_DISPATCH;
            if (finish_chunk_and_should_yield()) break;
            continue;
        }
        if (_stage == Stage::STRUCTURAL_COMMIT) {
            _executed_stage = Stage::STRUCTURAL_COMMIT;
            const auto start = Clock::now();
            cursor_start = _structural_cursor;
            const int32_t end = std::min<int32_t>(static_cast<int32_t>(_structural_commands.size()),
                                                  _structural_cursor + _commands_per_slice);
            for (; _structural_cursor < end; ++_structural_cursor) {
                if (!commit_structural(_structural_commands[_structural_cursor], error)) {
                    fail(error);
                    break;
                }
                ++work_done;
            }
            cursor_end = _structural_cursor;
            _structure_ms += elapsed_ms(start);
            structural_range_used = true;
            if (_fatal) break;
            const bool structural_range_incomplete =
                _structural_cursor < static_cast<int32_t>(
                    _structural_commands.size());
            if (finish_chunk_and_should_yield()) break;
            if (structural_range_incomplete) continue;
            int64_t merchant_repairs = 0;
            for (const int32_t cell : _structural_touched_cells) {
                if (!ensure_merchant_invariant(cell, merchant_repairs, error)) {
                    fail(error.empty() ? "merchant_repair_after_structure_failed" : error);
                    break;
                }
            }
            if (_fatal) break;
            _merchant_repairs = saturating_add(
                _merchant_repairs, merchant_repairs, _saturation_count);
            if (!_structural_touched_cells.empty() && !rebuild_merchant_ranges(error)) {
                fail(error.empty() ? "merchant_range_rebuild_after_structure_failed" : error);
                break;
            }
            _population_changed_cells.insert(_population_changed_cells.end(),
                _structural_touched_cells.begin(), _structural_touched_cells.end());
            if (!_population_changed_cells.empty() &&
                !reconcile_building_employment_after_population_change(
                    _population_changed_cells, error)) {
                fail(error.empty() ? "building_employment_reconcile_failed" : error);
                break;
            }
            // Everything pushed so far is now reconciled; building_commit.finalize
            // only needs the tail appended after this point (e.g. investment
            // profession transitions via move_cohort_population).
            _structural_reconciled_upto =
                static_cast<int64_t>(_structural_touched_cells.size());
            _stage = Stage::BUILDING_COMMIT;
            continue;
        }
        if (_stage == Stage::WAIT_COMMIT) {
            // Kept only for v14 trace compatibility; rolling transactions never
            // wait for a global commit boundary.
            _stage = Stage::BUILDING_COMMIT;
            continue;
        }
        if (_stage == Stage::BUILDING_COMMIT) {
            _executed_stage = Stage::BUILDING_COMMIT;
            // Phases fuse within one slice, so the mark and the attributed
            // phase must both advance at every phase boundary.
            auto commit_phase_started = Clock::now();
            int32_t commit_phase_active = _building_commit_phase;
            int64_t commit_phase_work_start = work_done;
            const auto record_commit_phase = [&](int64_t minimum_work) {
                const size_t index = static_cast<size_t>(std::clamp(
                    commit_phase_active, 0,
                    static_cast<int32_t>(BUILDING_COMMIT_PHASE_COUNT - 1)));
                const double phase_ms = elapsed_ms(commit_phase_started);
                _building_commit_slice_phase_ms[index] += phase_ms;
                _building_commit_slice_phase_work[index] +=
                    std::max(minimum_work, work_done - commit_phase_work_start);
                if (index == 4 || index == 5) {
                    _investment_ms += phase_ms;
                }
                commit_phase_started = Clock::now();
                commit_phase_active = _building_commit_phase;
                commit_phase_work_start = work_done;
            };
            if (_building_commit_phase == 0) {
                _executed_substage = "review_prepare";
                _investment_employment_cells.clear();
                prepare_investment_review_cells();
                _building_commit_cursor = 0;
                _building_finalize_phase = 0;
                _building_commit_phase = 1;
                record_commit_phase(1);
                if (finish_chunk_and_should_yield()) break;
                ++_budgeted_building_commit_phase_fusions;
                continue;
            }
            if (_building_commit_phase == 1) {
                _executed_substage = "special_reset";
                cursor_start = _building_commit_cursor;
                const int32_t end = std::min<int32_t>(
                    static_cast<int32_t>(_building_special_reset_group_indices.size()),
                    _building_commit_cursor + BUILDING_REVIEW_GROUPS_PER_SLICE);
                for (; _building_commit_cursor < end; ++_building_commit_cursor) {
                    const int32_t g = _building_special_reset_group_indices[
                        _building_commit_cursor];
                    if (g < 0 || g >= static_cast<int32_t>(_buildings.size())) continue;
                    BuildingGroup &group = _buildings[g];
                    if (group.count <= 0 || group.operating_state != 1) continue;
                    group.operating_state = 0;
                    group.pending_operating_state = 255;
                    group.recovery_cooldown_cycles = 0;
                    group.severe_loss_cycles = 0;
                    group.recovery_cycles = 0;
                    group.recovery_failed_reviews = 0;
                }
                work_done += end - cursor_start;
                cursor_end = _building_commit_cursor;
                if (_building_commit_cursor >= static_cast<int32_t>(
                        _building_special_reset_group_indices.size())) {
                    _building_commit_cursor = 0;
                    _building_commit_phase = 2;
                }
                record_commit_phase(0);
                if (_building_commit_phase == 1 ||
                    finish_chunk_and_should_yield()) break;
                ++_budgeted_building_commit_phase_fusions;
                continue;
            }
            if (_building_commit_phase == 2) {
                _executed_substage = "recovery_review";
                const int32_t phase_end = _building_review_phase_offsets.size() >= 2
                    ? _building_review_phase_offsets[1] : 0;
                cursor_start = _building_commit_cursor;
                const int32_t end = std::min(
                    phase_end, _building_commit_cursor +
                        BUILDING_REVIEW_GROUPS_PER_SLICE);
                for (; _building_commit_cursor < end; ++_building_commit_cursor) {
                    review_recovery_building_group(
                        _building_review_group_indices[_building_commit_cursor]);
                }
                work_done += end - cursor_start;
                cursor_end = _building_commit_cursor;
                if (_building_commit_cursor >= phase_end) {
                    _building_commit_cursor = 0;
                    _building_commit_phase = 3;
                }
                record_commit_phase(0);
                if (_building_commit_phase == 2 ||
                    finish_chunk_and_should_yield()) break;
                ++_budgeted_building_commit_phase_fusions;
                continue;
            }
            if (_building_commit_phase == 3) {
                _executed_substage = "construction_commit";
                // Recovery tombstones remain addressable through the already
                // baked cell ranges during investment. Compact them together
                // with any post-investment additions in the final commit.
                commit_ready_construction(_investment_employment_cells, false);
                _building_cell_cursor = 0;
                _building_commit_phase = 4;
                record_commit_phase(1);
                if (finish_chunk_and_should_yield()) break;
                ++_budgeted_building_commit_phase_fusions;
                continue;
            }
            if (_building_commit_phase == 4) {
                _executed_substage = "investment_prepare";
                bool population_changed = false;
                if (!run_endogenous_building_investment(
                        0, 0, true, population_changed, error)) {
                    fail(error.empty()
                        ? "building_investment_prepare_failed" : error);
                    record_commit_phase(0);
                    break;
                }
                _building_commit_phase = 5;
                record_commit_phase(1);
                if (finish_chunk_and_should_yield()) break;
                ++_budgeted_building_commit_phase_fusions;
                continue;
            }
            if (_building_commit_phase == 5) {
                _executed_substage = "investment";
                const int32_t investment_cell_count = static_cast<int32_t>(
                    _investment_review_cell_indices.size());
                cursor_start = _building_cell_cursor;
                const int32_t end = std::min<int32_t>(
                    investment_cell_count,
                    _building_cell_cursor + _investment_cells_per_slice);
                bool population_changed = false;
                if (!run_endogenous_building_investment(
                        _building_cell_cursor, end, false,
                        population_changed, error)) {
                    fail(error.empty() ? "building_investment_failed" : error);
                    record_commit_phase(0);
                    break;
                }
                work_done += end - _building_cell_cursor;
                _building_cell_cursor = end;
                cursor_end = _building_cell_cursor;
                building_range_used = true;
                if (_building_cell_cursor < investment_cell_count) {
                    record_commit_phase(0);
                    break;
                }
                if (!flush_market_signal_overflow(error)) {
                    fail(error.empty() ? "market_signal_overflow_flush_failed" : error);
                    record_commit_phase(0);
                    break;
                }
                _building_commit_phase = 6;
                record_commit_phase(0);
                if (finish_chunk_and_should_yield()) break;
                ++_budgeted_building_commit_phase_fusions;
                continue;
            }
            if (_building_commit_phase == 6) {
                _executed_substage = "finalize";
                if (_building_finalize_phase == 0) {
                    const auto finalize_construction_started = Clock::now();
                    commit_ready_construction(_investment_employment_cells);
                    // structural_commit 已 reconcile 过前缀（_structural_reconciled_upto），
                    // finalize 只补快照之后追加的尾部（投资 profession 迁移等），
                    // 避免同一 epoch 内对整批 structural cell 双重 reconcile。
                    _investment_employment_cells.insert(
                        _investment_employment_cells.end(),
                        _structural_touched_cells.begin() +
                            std::min<int64_t>(_structural_reconciled_upto,
                                static_cast<int64_t>(_structural_touched_cells.size())),
                        _structural_touched_cells.end());
                    thread_local std::vector<int32_t> stable_finalize_cells;
                    thread_local std::vector<uint32_t> stable_finalize_stamp;
                    thread_local uint32_t stable_finalize_generation = 0;
                    if (stable_finalize_stamp.size() < static_cast<size_t>(_cell_count))
                        stable_finalize_stamp.resize(static_cast<size_t>(_cell_count), 0);
                    ++stable_finalize_generation;
                    if (stable_finalize_generation == 0) {
                        std::fill(stable_finalize_stamp.begin(),
                                  stable_finalize_stamp.end(), 0);
                        stable_finalize_generation = 1;
                    }
                    stable_finalize_cells.clear();
                    for (const int32_t cell : _investment_employment_cells) {
                        if (cell < 0 || cell >= _cell_count ||
                            stable_finalize_stamp[cell] == stable_finalize_generation)
                            continue;
                        stable_finalize_stamp[cell] = stable_finalize_generation;
                        stable_finalize_cells.push_back(cell);
                    }
                    std::sort(stable_finalize_cells.begin(),
                              stable_finalize_cells.end());
                    _investment_employment_cells.swap(stable_finalize_cells);
                    _building_commit_cursor = 0;
                    _building_finalize_phase = 1;
                    _finalize_construction_ms +=
                        elapsed_ms(finalize_construction_started);
                    record_commit_phase(1);
                    if (finish_chunk_and_should_yield()) break;
                    ++_budgeted_building_commit_phase_fusions;
                    continue;
                }
                if (_building_finalize_phase == 1) {
                    const auto finalize_reconcile_started = Clock::now();
                    cursor_start = _building_commit_cursor;
                    const int32_t end = std::min<int32_t>(
                        static_cast<int32_t>(_investment_employment_cells.size()),
                        _building_commit_cursor +
                            _building_finalize_cells_per_slice);
                    if (!reconcile_building_employment_cells_range(
                            _investment_employment_cells, _building_commit_cursor,
                            end, error)) {
                        fail(error.empty()
                            ? "building_investment_reconcile_failed" : error);
                        record_commit_phase(0);
                        break;
                    }
                    work_done += end - _building_commit_cursor;
                    _building_commit_cursor = end;
                    cursor_end = _building_commit_cursor;
                    if (_building_commit_cursor >= static_cast<int32_t>(
                            _investment_employment_cells.size())) {
                        _building_finalize_phase = 2;
                    }
                    _finalize_reconcile_ms +=
                        elapsed_ms(finalize_reconcile_started);
                    record_commit_phase(0);
                    if (_building_finalize_phase == 1 ||
                        finish_chunk_and_should_yield()) break;
                    ++_budgeted_building_commit_phase_fusions;
                    continue;
                }
                _investment_pending_by_cell_type.clear();
                _investment_existing_by_cell_type.clear();
                _investment_merchant_cash_by_cell.clear();
                _investment_outstanding_credit_by_cell.clear();
                _building_cell_cursor = 0;
                _building_commit_cursor = 0;
                _building_finalize_phase = 0;
                _building_commit_phase = 0;
                if (!commit_fiscal(error)) {
                    fail(error.empty() ? "fiscal_commit_failed" : error);
                    record_commit_phase(0);
                    break;
                }
                _family_commit_phase = 0;
                _family_commit_cursor = 0;
                _stage = Stage::FAMILY_COMMIT;
                record_commit_phase(1);
                if (finish_chunk_and_should_yield()) break;
                ++_budgeted_building_commit_phase_fusions;
                continue;
            }
        }
        if (_stage == Stage::FAMILY_COMMIT) {
            _executed_stage = Stage::FAMILY_COMMIT;
            _executed_substage = _family_commit_phase == 0 ? "normalize"
                : (_family_commit_phase == 1 ? "formation" : "lifecycle");
            if (!run_family_commit_slice(work_done, error)) {
                fail(error.empty() ? "family_commit_failed" : error);
                break;
            }
            if (_stage == Stage::FAMILY_COMMIT || finish_chunk_and_should_yield())
                break;
            continue;
        }
        if (_stage == Stage::PERSON_COMMIT) {
            _executed_stage = Stage::PERSON_COMMIT;
            _executed_substage = _person_commit_phase == 0 ? "snapshot"
                : (_person_commit_phase == 1 ? "reconcile_jobs"
                : (_person_commit_phase == 2 ? "wealth_equity"
                : (_person_commit_phase == 3 ? "promotion"
                                             : "index_finalize")));
            if (!run_person_commit_slice(work_done, error)) {
                fail(error.empty() ? "person_commit_failed" : error);
                break;
            }
            if (_stage == Stage::PERSON_COMMIT || finish_chunk_and_should_yield())
                break;
            continue;
        }
        if (_stage == Stage::AGGREGATE_PUBLISH) {
            _executed_stage = Stage::AGGREGATE_PUBLISH;
            while (_epoch_active && !_fatal &&
                   _stage == Stage::AGGREGATE_PUBLISH) {
                const PublishPhase previous_phase = _publish_phase;
                if (!publish_epoch_slice(work_done, error)) {
                    fail(error);
                    break;
                }
                // A single native call may cross cheap publish phase
                // boundaries, but never consumes two chunks from the same
                // phase. This preserves deterministic per-phase work bounds.
                if (_publish_phase == previous_phase ||
                    finish_chunk_and_should_yield()) break;
                ++_budgeted_publish_phase_fusions;
            }
            break;
        }
        break;
    }
    out = compact ? compact_report() : report();
    if (_executed_stage == Stage::TRADE_PLANNING) {
        out["executed_stage"] = "trade_planning";
        out["executed_substage"] = out.get("trade_plan_substage", "");
    }
    out["done"] = !_epoch_active;
    out["work_done"] = work_done;
    out["cursor_start"] = cursor_start;
    out["cursor_end"] = cursor_end;
    out["elapsed_ms"] = elapsed_ms(slice_start);
    out["slice_budget_ms"] = slice_budget_ms;
    out["requested_slice_budget_ms"] = requested_slice_budget_ms;
    out["chunks_completed"] = chunks_completed;
    out["phase_fusions"] = phase_fusions;
    out["batch_multiplier"] = batch_multiplier;
    out["high_speed_market_dispatches_saved"] =
        _high_speed_market_dispatches_saved;
    out["high_speed_production_dispatches_saved"] =
        _high_speed_production_dispatches_saved;
    out["yield_reason"] = _fatal ? "fatal" :
        (!_epoch_active ? "epoch_complete" : yield_reason);
    out["budget_overrun_ms"] = std::max(
        0.0, elapsed_ms(slice_start) - slice_budget_ms);
    out["command_range_used"] = command_range_used;
    out["cell_range_used"] = cell_range_used;
    out["structural_range_used"] = structural_range_used;
    out["building_range_used"] = building_range_used;
    return out;
}

void NativeEconomyRuntime::rebuild_building_handle_index() const {
    _building_handle_index.clear();
    _building_handle_index.reserve(_buildings.size() * 2 + 1);
    // Reverse order so the surviving entry matches the lowest index, which is
    // what the previous forward linear scan returned for duplicate handles.
    for (int32_t i = static_cast<int32_t>(_buildings.size()) - 1; i >= 0; --i)
        if (_buildings[i].count > 0 && _buildings[i].modifier_handle != 0)
            _building_handle_index[_buildings[i].modifier_handle] = i;
    _building_handle_index_stamp = _buildings.size();
    _building_handle_index_clean = true;
}

const std::unordered_map<uint64_t, int32_t> &
NativeEconomyRuntime::building_handle_index() const {
    if (_building_handle_index_stamp != _buildings.size())
        _building_handle_index_clean = false;
    if (!_building_handle_index_clean) rebuild_building_handle_index();
    return _building_handle_index;
}

int32_t NativeEconomyRuntime::building_index_for_handle(
        uint64_t building_handle) const {
    if (building_handle == 0) return -1;
    building_handle_index();
    auto it = _building_handle_index.find(building_handle);
    if (it != _building_handle_index.end()) {
        const int32_t index = it->second;
        if (index >= 0 && index < static_cast<int32_t>(_buildings.size()) &&
            _buildings[index].count > 0 &&
            _buildings[index].modifier_handle == building_handle) return index;
        rebuild_building_handle_index();
        it = _building_handle_index.find(building_handle);
        return it == _building_handle_index.end() ? -1 : it->second;
    }
    return -1;
}

int64_t NativeEconomyRuntime::family_population(uint64_t family_handle) const {
    auto add_transit = [&](int64_t total, int64_t &sat) {
        for (size_t i = 0; i < _family_expeditions.active.size(); ++i) {
            if (_family_expeditions.active[i] != 0 &&
                _family_expeditions.family_handle[i] == family_handle)
                total = saturating_add(total,
                    std::max<int64_t>(0, _family_expeditions.population[i]), sat);
        }
        return total;
    };
    int32_t family = -1;
    if (_families.valid_handle(family_handle, family) &&
        _family_member_offsets.size() == _families.active.size() + 1) {
        int64_t total = 0, sat = 0;
        for (int32_t p = _family_member_offsets[family];
             p < _family_member_offsets[family + 1]; ++p)
            total = saturating_add(total, std::max<int64_t>(0,
                _family_memberships[_family_member_edge_indices[p]].people), sat);
        return add_transit(total, sat);
    }
    int64_t total = 0;
    int64_t sat = 0;
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        if (edge.family_handle == family_handle)
            total = saturating_add(total, std::max<int64_t>(0, edge.people), sat);
    }
    return add_transit(total, sat);
}

int64_t NativeEconomyRuntime::family_cash_claim(uint64_t family_handle) const {
    auto add_transit = [&](int64_t total, int64_t &sat) {
        for (size_t i = 0; i < _family_expeditions.active.size(); ++i) {
            if (_family_expeditions.active[i] == 0 ||
                _family_expeditions.family_handle[i] != family_handle) continue;
            const uint32_t begin = _family_expeditions.payload_begin[i];
            const uint32_t count = _family_expeditions.payload_count[i];
            for (uint32_t p = 0; p < count; ++p)
                total = saturating_add(total, std::max<int64_t>(0,
                    _family_expedition_payloads[begin + p].cash_claim), sat);
        }
        return total;
    };
    int32_t family = -1;
    if (_families.valid_handle(family_handle, family) &&
        _family_member_offsets.size() == _families.active.size() + 1) {
        int64_t total = 0, sat = 0;
        for (int32_t p = _family_member_offsets[family];
             p < _family_member_offsets[family + 1]; ++p)
            total = saturating_add(total, std::max<int64_t>(0,
                _family_memberships[_family_member_edge_indices[p]].cash_claim), sat);
        return add_transit(total, sat);
    }
    int64_t total = 0;
    int64_t sat = 0;
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        if (edge.family_handle == family_handle)
            total = saturating_add(total, std::max<int64_t>(0, edge.cash_claim), sat);
    }
    return add_transit(total, sat);
}

int64_t NativeEconomyRuntime::family_owned_buildings(uint64_t family_handle) const {
    int32_t family = -1;
    if (_families.valid_handle(family_handle, family) &&
        _family_owned_offsets.size() == _families.active.size() + 1) {
        int64_t total = 0, sat = 0;
        for (int32_t p = _family_owned_offsets[family];
             p < _family_owned_offsets[family + 1]; ++p)
            total = saturating_add(total, std::max<int64_t>(0,
                _family_ownerships[_family_owned_edge_indices[p]].owned_count), sat);
        return total;
    }
    int64_t total = 0;
    int64_t sat = 0;
    for (const FamilyBuildingOwnership &edge : _family_ownerships) {
        if (edge.family_handle == family_handle)
            total = saturating_add(total, std::max<int64_t>(0, edge.owned_count), sat);
    }
    return total;
}

void NativeEconomyRuntime::assign_core_family_traits(int32_t family_index) {
    if (family_index < 0 || family_index >= static_cast<int32_t>(
            _families.active.size()) || _families.active[family_index] == 0 ||
        _family_trait_ids.empty()) return;
    const uint64_t family_handle = _families.handle_for_index(family_index);
    uint64_t rng = 1469598103934665603ULL;
    rng = trace_hash_mix(rng, static_cast<uint64_t>(_seed));
    rng = trace_hash_mix(rng, static_cast<uint64_t>(
        _families.stable_id[family_index]));
    rng = trace_hash_mix(rng, static_cast<uint32_t>(
        _family_trait_catalog_version));
    const int32_t span = _family_core_trait_max - _family_core_trait_min + 1;
    const int32_t desired = _family_core_trait_min + static_cast<int32_t>(
        trace_hash_mix(rng, 0x434f554e54ULL) %
        static_cast<uint64_t>(std::max(1, span)));
    std::vector<int32_t> selected;
    selected.reserve(desired);
    for (int32_t pick = 0; pick < desired; ++pick) {
        std::vector<int32_t> candidates;
        int64_t total_weight = 0;
        for (int32_t trait_id = 0; trait_id < static_cast<int32_t>(
                _family_trait_ids.size()); ++trait_id) {
            if (_family_trait_core_eligible[trait_id] == 0 ||
                std::find(selected.begin(), selected.end(), trait_id) !=
                    selected.end()) continue;
            bool allowed = true;
            for (int32_t p = _family_trait_prerequisite_offsets[trait_id];
                 p < _family_trait_prerequisite_offsets[trait_id + 1]; ++p)
                allowed = allowed && std::find(selected.begin(), selected.end(),
                    _family_trait_prerequisites[p]) != selected.end();
            for (int32_t p = _family_trait_exclusion_offsets[trait_id];
                 allowed && p < _family_trait_exclusion_offsets[trait_id + 1]; ++p)
                allowed = std::find(selected.begin(), selected.end(),
                    _family_trait_exclusions[p]) == selected.end();
            for (int32_t chosen : selected) {
                for (int32_t p = _family_trait_exclusion_offsets[chosen];
                     allowed && p < _family_trait_exclusion_offsets[chosen + 1]; ++p)
                    allowed = _family_trait_exclusions[p] != trait_id;
            }
            if (!allowed) continue;
            candidates.push_back(trait_id);
            total_weight += _family_trait_weights[trait_id];
        }
        if (candidates.empty() || total_weight <= 0) break;
        int64_t roll = static_cast<int64_t>(trace_hash_mix(
            rng, 0x5049434bULL + static_cast<uint64_t>(pick)) %
            static_cast<uint64_t>(total_weight));
        int32_t chosen = candidates.back();
        for (int32_t candidate : candidates) {
            if (roll < _family_trait_weights[candidate]) {
                chosen = candidate;
                break;
            }
            roll -= _family_trait_weights[candidate];
        }
        selected.push_back(chosen);
        const int32_t lo = _family_trait_strength_min_q16[chosen];
        const int32_t hi = _family_trait_strength_max_q16[chosen];
        const int32_t step = _family_trait_strength_step_q16[chosen];
        const int32_t steps = std::max(0, (hi - lo) / step);
        const int32_t strength = lo + step * static_cast<int32_t>(
            trace_hash_mix(rng, 0x535452454e475448ULL +
                static_cast<uint64_t>(pick)) %
            static_cast<uint64_t>(steps + 1));
        _family_traits.push_back({family_handle, chosen, strength, 1});
    }
    std::sort(_family_traits.begin(), _family_traits.end(),
        [](const FamilyTraitRoll &a, const FamilyTraitRoll &b) {
            return std::tie(a.family_handle, a.trait_id) <
                std::tie(b.family_handle, b.trait_id);
        });
}

int32_t NativeEconomyRuntime::family_trait_behavior_factor_q16(
        uint64_t family_handle, int32_t axis, int32_t selector_kind,
        int32_t selector_id) const {
    int64_t factor = Q16_ONE;
    for (const FamilyTraitRoll &roll : _family_traits) {
        if (roll.family_handle != family_handle || roll.trait_id < 0 ||
            roll.trait_id >= static_cast<int32_t>(
                _family_trait_behavior_offsets.size()) - 1) continue;
        for (int32_t edge = _family_trait_behavior_offsets[roll.trait_id];
             edge < _family_trait_behavior_offsets[roll.trait_id + 1]; ++edge) {
            if (_family_trait_behavior_axes[edge] != axis ||
                _family_trait_behavior_selector_kinds[edge] != selector_kind ||
                _family_trait_behavior_selector_ids[edge] != selector_id) continue;
            const int64_t preferred = _family_trait_behavior_factors_q16[edge];
            const int64_t scaled = Q16_ONE + (preferred - Q16_ONE) *
                static_cast<int64_t>(roll.strength_q16) / Q16_ONE;
            factor = std::clamp<int64_t>(factor * scaled / Q16_ONE,
                                        0, 4 * Q16_ONE);
        }
    }
    return static_cast<int32_t>(factor);
}

int32_t NativeEconomyRuntime::family_consumption_factor_q16(
        int32_t cohort_slot, int32_t need_id) const {
    if (cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            _population.active.size()) || _population.active[cohort_slot] == 0 ||
        _family_cohort_offsets.size() != _population.active.size() + 1)
        return Q16_ONE;
    const int64_t population = std::max<int64_t>(1,
        _population.population[cohort_slot]);
    int64_t sat = 0;
    int64_t weighted = saturating_mul(population, Q16_ONE, sat);
    for (int32_t p = _family_cohort_offsets[cohort_slot];
         p < _family_cohort_offsets[cohort_slot + 1]; ++p) {
        const FamilyMembershipEdge &edge = _family_memberships[
            _family_cohort_edge_indices[p]];
        if (edge.people <= 0 || edge.family_handle == 0) continue;
        const int32_t factor = family_trait_behavior_factor_q16(
            edge.family_handle, 2, 0, need_id);
        weighted = saturating_add(weighted,
            saturating_mul(edge.people, static_cast<int64_t>(factor) - Q16_ONE,
                sat), sat);
    }
    int64_t factor = mul_div_sat(weighted, 1, population, sat);
    const int32_t cell = _population.page_cell[cohort_slot / COHORT_PAGE_SIZE];
    const size_t city_index = static_cast<size_t>(std::max(0, cell)) *
        _need_ids.size() + static_cast<size_t>(std::max(0, need_id));
    if (cell >= 0 && cell < _cell_count && need_id >= 0 &&
        need_id < static_cast<int32_t>(_need_ids.size()) &&
        city_index < _epoch_cell_need_consumption_factor_q16.size()) {
        factor = mul_div_sat(factor,
            _epoch_cell_need_consumption_factor_q16[city_index], Q16_ONE, sat);
    }
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_country.size()) ? _epoch_cell_country[cell] : -1;
    if (country >= 0 && country < static_cast<int32_t>(
            _epoch_country_household_consumption_factor_q16.size()))
        factor = mul_div_sat(factor,
            _epoch_country_household_consumption_factor_q16[country], Q16_ONE, sat);
    return static_cast<int32_t>(std::clamp<int64_t>(
        factor, 0, 4 * Q16_ONE));
}

int32_t NativeEconomyRuntime::family_good_consumption_factor_q16(
        int32_t cohort_slot, int32_t good_id) const {
    if (cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            _population.active.size()) || _population.active[cohort_slot] == 0 ||
        good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()))
        return Q16_ONE;
    const int64_t population = std::max<int64_t>(1,
        _population.population[cohort_slot]);
    int64_t sat = 0;
    int64_t weighted = saturating_mul(population, Q16_ONE, sat);
    if (!_family_traits.empty() && _family_cohort_offsets.size() ==
            _population.active.size() + 1) {
        for (int32_t p = _family_cohort_offsets[cohort_slot];
             p < _family_cohort_offsets[cohort_slot + 1]; ++p) {
            const FamilyMembershipEdge &edge = _family_memberships[
                _family_cohort_edge_indices[p]];
            if (edge.people <= 0 || edge.family_handle == 0) continue;
            const int32_t factor = family_trait_behavior_factor_q16(
                edge.family_handle, 3, 0, good_id);
            weighted = saturating_add(weighted,
                saturating_mul(edge.people,
                    static_cast<int64_t>(factor) - Q16_ONE, sat), sat);
        }
    }
    int64_t factor = mul_div_sat(weighted, 1, population, sat);
    const int32_t cell = _population.page_cell[cohort_slot / COHORT_PAGE_SIZE];
    const size_t city_index = static_cast<size_t>(std::max(0, cell)) *
        _good_ids.size() + static_cast<size_t>(good_id);
    if (cell >= 0 && cell < _cell_count && city_index <
            _epoch_cell_good_consumption_factor_q16.size()) {
        factor = mul_div_sat(factor,
            _epoch_cell_good_consumption_factor_q16[city_index],
            Q16_ONE, sat);
    }
    return static_cast<int32_t>(std::clamp<int64_t>(
        factor, 0, 4 * Q16_ONE));
}

int32_t NativeEconomyRuntime::family_variant_preference_factor_q16(
        int32_t cohort_slot, int32_t variant_id, int64_t &sat) const {
    if (variant_id < 0 || variant_id >= static_cast<int32_t>(_variants.size()))
        return Q16_ONE;
    const VariantChoice &variant = _variants[variant_id];
    int64_t quantity_sum = 0;
    int64_t weighted_sum = 0;
    for (int32_t c = 0; c < variant.component_count; ++c) {
        const NeedComponent &component = _components[variant.component_begin + c];
        const int64_t quantity = std::max<int64_t>(1, component.qty_per_need);
        quantity_sum = saturating_add(quantity_sum, quantity, sat);
        weighted_sum = saturating_add(weighted_sum, saturating_mul(
            quantity, family_good_consumption_factor_q16(
                cohort_slot, component.good_id), sat), sat);
    }
    return quantity_sum > 0 ? static_cast<int32_t>(std::clamp<int64_t>(
        mul_div_sat(weighted_sum, 1, quantity_sum, sat), 0, 4 * Q16_ONE))
        : Q16_ONE;
}

uint64_t NativeEconomyRuntime::preferred_family_for_cohort(
        int32_t cohort_slot, int32_t axis, int32_t selector_kind,
        int32_t selector_id) const {
    if (cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            _population.active.size()) || _family_cohort_offsets.size() !=
            _population.active.size() + 1) return 0;
    uint64_t best = 0;
    int32_t best_factor = Q16_ONE;
    int64_t best_people = -1;
    for (int32_t p = _family_cohort_offsets[cohort_slot];
         p < _family_cohort_offsets[cohort_slot + 1]; ++p) {
        const FamilyMembershipEdge &edge = _family_memberships[
            _family_cohort_edge_indices[p]];
        if (edge.family_handle == 0 || edge.people <= 0) continue;
        const int32_t factor = family_trait_behavior_factor_q16(
            edge.family_handle, axis, selector_kind, selector_id);
        if (factor <= Q16_ONE) continue;
        if (factor > best_factor || (factor == best_factor &&
                (edge.people > best_people || (edge.people == best_people &&
                 (best == 0 || edge.family_handle < best))))) {
            best = edge.family_handle;
            best_factor = factor;
            best_people = edge.people;
        }
    }
    return best;
}

int64_t NativeEconomyRuntime::building_reset_capital_value(
        const BuildingGroup &group) const {
    if (group.cell < 0 || group.cell >= _cell_count || group.type_id < 0 ||
        group.type_id >= static_cast<int32_t>(_building_types.size()) ||
        group.count <= 0) return 0;
    const int32_t market = _market.cell_to_market[group.cell];
    if (market < 0 || market >= _market.market_count) return 0;
    const BuildingType &type = _building_types[group.type_id];
    int64_t sat = 0;
    int64_t construction = 0;
    for (int32_t i = 0; i < type.construction_count; ++i) {
        const GoodAmount &item = _building_construction_goods[
            type.construction_begin + i];
        construction = saturating_add(construction, mul_div_sat(
            item.quantity, _market.price[_market.index(market, item.good_id)],
            GOODS_SCALE, sat), sat);
    }
    const int64_t operating_per_building = std::max<int64_t>(0,
        group.last_operating_cost) / std::max<int64_t>(1, group.count);
    const int64_t reserve = saturating_mul(operating_per_building,
        std::max(1, _investment_operating_cycles), sat);
    return saturating_add(construction, reserve, sat);
}

bool NativeEconomyRuntime::family_free_building_resources_legal(
        int32_t cell, int32_t type_id, int64_t count) const {
    if (cell < 0 || cell >= _cell_count || type_id < 0 ||
        type_id >= static_cast<int32_t>(_building_types.size()) || count <= 0 ||
        _building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1) ||
        _pending_construction_cell_offsets.size() !=
            static_cast<size_t>(_cell_count + 1)) {
        return false;
    }
    const BuildingType &reward_type = _building_types[type_id];
    int64_t sat = 0;
    for (int32_t target_edge = 0; target_edge < reward_type.resource_count;
         ++target_edge) {
        const ResourceAmount &target = _building_resources[
            reward_type.resource_begin + target_edge];
        if (target.mode != 0 || target.quantity <= 0) continue;
        if (target.resource_id < 0 || target.resource_id >=
                static_cast<int32_t>(_resource_ids.size())) {
            return false;
        }
        bool already_checked = false;
        int64_t requested_per_building = 0;
        for (int32_t edge = 0; edge < reward_type.resource_count; ++edge) {
            const ResourceAmount &item = _building_resources[
                reward_type.resource_begin + edge];
            if (item.mode != 0 || item.quantity <= 0 ||
                item.resource_id != target.resource_id) continue;
            if (edge < target_edge) already_checked = true;
            requested_per_building = saturating_add(
                requested_per_building, item.quantity, sat);
        }
        if (already_checked) continue;

        int64_t committed = 0;
        const auto add_commitment = [&](int32_t committed_type,
                                        int64_t committed_count) {
            if (committed_type < 0 || committed_type >= static_cast<int32_t>(
                    _building_types.size()) || committed_count <= 0) return;
            const BuildingType &type = _building_types[committed_type];
            int64_t per_building = 0;
            for (int32_t edge = 0; edge < type.resource_count; ++edge) {
                const ResourceAmount &item = _building_resources[
                    type.resource_begin + edge];
                if (item.mode == 0 && item.quantity > 0 &&
                    item.resource_id == target.resource_id) {
                    per_building = saturating_add(
                        per_building, item.quantity, sat);
                }
            }
            committed = saturating_add(committed, saturating_mul(
                committed_count, per_building, sat), sat);
        };
        for (int32_t group = _building_cell_offsets[cell];
             group < _building_cell_offsets[cell + 1]; ++group) {
            add_commitment(_buildings[group].type_id,
                           _buildings[group].count);
        }
        for (int32_t cursor = _pending_construction_cell_offsets[cell];
             cursor < _pending_construction_cell_offsets[cell + 1]; ++cursor) {
            const int32_t pending_index =
                _pending_construction_cell_indices[cursor];
            if (pending_index < 0 || pending_index >= static_cast<int32_t>(
                    _pending_construction.size())) return false;
            const PendingConstruction &pending =
                _pending_construction[pending_index];
            add_commitment(pending.type_id, pending.count);
        }
        // Reward commands are applied after the epoch's pending CSR is frozen.
        // Only the newly appended tail can be absent from that local index.
        const size_t indexed_pending =
            _pending_construction_cell_indices.size();
        for (size_t pending_index = indexed_pending;
             pending_index < _pending_construction.size(); ++pending_index) {
            const PendingConstruction &pending =
                _pending_construction[pending_index];
            if (pending.cell == cell)
                add_commitment(pending.type_id, pending.count);
        }

        const size_t lane = static_cast<size_t>(target.resource_id) *
            static_cast<size_t>(_cell_count) + static_cast<size_t>(cell);
        int64_t daily_budget = 0;
        if (resource_is_renewable(target.resource_id)) {
            daily_budget = renewable_safe_harvest(target.resource_id, cell);
        } else if (lane < _resource_snapshot.size()) {
            const bool initialized = lane < _resource_lane_generation.size() &&
                _resource_lane_generation[lane] ==
                    _resource_current_generation;
            const int64_t remaining = initialized &&
                    lane < _resource_remaining.size()
                ? _resource_remaining[lane] : _resource_snapshot[lane];
            daily_budget = std::max<int64_t>(0, remaining) /
                std::max<int64_t>(1, _resource_min_horizon_days);
        }
        const int64_t requested = saturating_mul(
            count, requested_per_building, sat);
        if (committed > daily_budget || requested > daily_budget - committed)
            return false;
    }
    return true;
}

void NativeEconomyRuntime::clear_family_branch_effects(uint64_t branch_handle) {
    int32_t branch = -1;
    if (!_family_influences.valid_handle(branch_handle, branch)) return;
    for (const FamilyTriggerBinding &binding : _family_trigger_bindings) {
        if (binding.branch_handle != branch_handle) continue;
        reconcile_trigger_branch_binding(_trigger_runtime,
            binding.definition_key, branch_handle,
            _family_influences.cell[branch], binding.reward_target, false);
    }
    _family_trigger_bindings.erase(std::remove_if(
        _family_trigger_bindings.begin(), _family_trigger_bindings.end(),
        [&](const FamilyTriggerBinding &binding) {
            return binding.branch_handle == branch_handle;
        }), _family_trigger_bindings.end());
    if (_effect_runtime != nullptr) {
        const uint64_t stable_id = static_cast<uint64_t>(_family_influences.stable_id[branch]);
        const uint32_t generation = static_cast<uint32_t>(branch_handle >> 32U);
        for (FamilyModifierBinding &binding : _family_modifier_bindings) {
            if (binding.branch_handle != branch_handle ||
                binding.magnitude_q16 == 0) continue;
            std::string error;
            uint64_t identity = trace_hash_mix(1469598103934665603ULL, stable_id);
            identity = trace_hash_mix(identity, static_cast<uint32_t>(
                _family_influences.cell[branch]));
            uint64_t definition_hash = 1469598103934665603ULL;
            for (unsigned char ch : binding.definition_key)
                definition_hash = trace_hash_mix(definition_hash, ch);
            identity = trace_hash_mix(identity, definition_hash);
            const int64_t instance_id = static_cast<int64_t>(identity &
                0x7fffffffffffffffULL);
            const bool retired = _effect_runtime->retire_instance_pod(
                instance_id, generation, _current_day, error);
            // Keep a non-zero binding when the bounded Effect queue is full or
            // the definition is temporarily unavailable. The next branch
            // reconciliation can retry retirement instead of silently losing
            // the only cleanup handle.
            if (retired) binding.magnitude_q16 = 0;
        }
    } else if (_modifier_runtime != nullptr) {
        for (FamilyModifierBinding &binding : _family_modifier_bindings) {
            if (binding.branch_handle != branch_handle ||
                binding.magnitude_q16 == 0) continue;
            std::string error;
            _modifier_runtime->queue_family_group_effect_remove(
                binding.definition_key, _family_influences.cell[branch],
                static_cast<uint64_t>(_family_influences.stable_id[branch]),
                _current_day, error);
            binding.magnitude_q16 = 0;
        }
    }
    _family_modifier_bindings.erase(std::remove_if(
        _family_modifier_bindings.begin(), _family_modifier_bindings.end(),
        [&](const FamilyModifierBinding &binding) {
            return binding.branch_handle == branch_handle &&
                binding.magnitude_q16 == 0;
        }), _family_modifier_bindings.end());
}

void NativeEconomyRuntime::reconcile_family_branch_effects(
        uint64_t branch_handle, bool submit_changes) {
    int32_t branch = -1, family = -1;
    if (!_family_influences.valid_handle(branch_handle, branch) ||
        !_families.valid_handle(_family_influences.family_handle[branch], family))
        return;
    const int32_t level = _family_influences.prestige_level[branch];
    auto submit_effect_instance = [&](const std::string &definition_key,
                                      int32_t magnitude_q16) -> bool {
        if (_effect_runtime == nullptr || !submit_changes) return false;
        const uint64_t stable_id = static_cast<uint64_t>(
            _family_influences.stable_id[branch]);
        uint64_t identity = trace_hash_mix(1469598103934665603ULL, stable_id);
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            _family_influences.cell[branch]));
        uint64_t definition_hash = 1469598103934665603ULL;
        for (unsigned char ch : definition_key)
            definition_hash = trace_hash_mix(definition_hash, ch);
        identity = trace_hash_mix(identity, definition_hash);
        const int64_t instance_id = static_cast<int64_t>(identity &
            0x7fffffffffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(branch_handle >> 32U);
        std::string error;
        if (!_effect_runtime->upsert_instance_pod(
                instance_id, std::string("family.modifier.") + definition_key,
                generation, 0x46414d494c59, static_cast<int64_t>(stable_id),
                branch_handle, stable_id,
                static_cast<uint32_t>(_family_influences.cell[branch]), 0,
                _current_day, true, error))
            return false;
        return _effect_runtime->set_metric_pod(instance_id, 0,
            _current_day + 1, magnitude_q16, error);
    };
    std::unordered_map<std::string, int32_t> desired;
    std::unordered_map<std::string, int32_t> desired_triggers;
    for (const FamilyTraitRoll &roll : _family_traits) {
        if (roll.family_handle != _family_influences.family_handle[branch] ||
            roll.trait_id < 0 || roll.trait_id >= static_cast<int32_t>(
                _family_trait_modifier_offsets.size()) - 1) continue;
        for (int32_t edge = _family_trait_modifier_offsets[roll.trait_id];
             edge < _family_trait_modifier_offsets[roll.trait_id + 1]; ++edge) {
            if (_family_trait_modifier_targets[edge] != 0) continue;
            const int32_t tier_magnitude =
                _family_trait_modifier_tier_magnitudes_q16[edge * 6 + level];
            const int64_t scaled = static_cast<int64_t>(tier_magnitude) *
                roll.strength_q16 / Q16_ONE;
            int32_t &value = desired[
                _family_trait_modifier_definition_keys[edge]];
            value = std::clamp<int64_t>(static_cast<int64_t>(value) + scaled,
                                        0, 4 * Q16_ONE);
        }
        if (roll.trait_id >= static_cast<int32_t>(
                _family_trait_trigger_offsets.size()) - 1) continue;
        for (int32_t edge = _family_trait_trigger_offsets[roll.trait_id];
             edge < _family_trait_trigger_offsets[roll.trait_id + 1]; ++edge) {
            const std::string &key =
                _family_trait_trigger_definition_keys_by_tier[edge * 6 + level];
            if (!key.empty()) desired_triggers[key] =
                _family_trait_trigger_reward_targets[edge];
        }
    }
    for (FamilyModifierBinding &binding : _family_modifier_bindings) {
        if (binding.branch_handle != branch_handle) continue;
        const auto found = desired.find(binding.definition_key);
        const int32_t magnitude = found == desired.end() ? 0 : found->second;
        if (submit_changes && _effect_runtime != nullptr &&
            magnitude != binding.magnitude_q16) {
            submit_effect_instance(binding.definition_key, magnitude);
        } else if (submit_changes && _modifier_runtime != nullptr &&
            magnitude != binding.magnitude_q16) {
            std::string error;
            _modifier_runtime->queue_family_group_effect(binding.definition_key,
                _family_influences.cell[branch], static_cast<uint64_t>(
                    _family_influences.stable_id[branch]), magnitude,
                _current_day, error);
        }
        binding.magnitude_q16 = magnitude;
        if (found != desired.end()) desired.erase(found);
    }
    for (const auto &item : desired) {
        if (item.second == 0) continue;
        int32_t magnitude = item.second;
        if (!submit_changes && _modifier_runtime != nullptr) {
            const int32_t restored = _modifier_runtime->family_group_effect_magnitude(
                item.first, _family_influences.cell[branch], static_cast<uint64_t>(
                    _family_influences.stable_id[branch]));
            if (restored >= 0) magnitude = restored;
        } else if (submit_changes && _effect_runtime != nullptr) {
            submit_effect_instance(item.first, magnitude);
        } else if (_modifier_runtime != nullptr) {
            std::string error;
            _modifier_runtime->queue_family_group_effect(item.first,
                _family_influences.cell[branch], static_cast<uint64_t>(
                    _family_influences.stable_id[branch]), magnitude,
                _current_day, error);
        }
        _family_modifier_bindings.push_back(
            {branch_handle, item.first, magnitude});
    }
    for (auto it = _family_trigger_bindings.begin();
         it != _family_trigger_bindings.end();) {
        if (it->branch_handle != branch_handle) {
            ++it;
            continue;
        }
        const auto found = desired_triggers.find(it->definition_key);
        if (found == desired_triggers.end()) {
            reconcile_trigger_branch_binding(_trigger_runtime,
                it->definition_key, branch_handle,
                _family_influences.cell[branch], it->reward_target, false);
            it = _family_trigger_bindings.erase(it);
            continue;
        }
        if (found->second != it->reward_target &&
            reconcile_trigger_branch_binding(_trigger_runtime,
                it->definition_key, branch_handle,
                _family_influences.cell[branch], found->second, true)) {
            it->reward_target = found->second;
        }
        desired_triggers.erase(found);
        ++it;
    }
    for (const auto &item : desired_triggers) {
        if (reconcile_trigger_branch_binding(_trigger_runtime, item.first,
                branch_handle, _family_influences.cell[branch], item.second,
                true)) {
            _family_trigger_bindings.push_back(
                {branch_handle, item.first, item.second});
        }
    }
}

void NativeEconomyRuntime::rebuild_family_indices() {
    const auto membership_started = Clock::now();
    _family_memberships.erase(std::remove_if(
        _family_memberships.begin(), _family_memberships.end(),
        [&](const FamilyMembershipEdge &edge) {
            int32_t family = -1, slot = -1;
            return edge.people <= 0 ||
                !_families.valid_handle(edge.family_handle, family) ||
                !_population.valid_handle(edge.cohort_handle, slot);
        }), _family_memberships.end());
    std::sort(_family_memberships.begin(), _family_memberships.end(),
        [](const FamilyMembershipEdge &a, const FamilyMembershipEdge &b) {
            return std::tie(a.cohort_handle, a.family_handle) <
                std::tie(b.cohort_handle, b.family_handle);
        });
    std::vector<FamilyMembershipEdge> merged_memberships;
    merged_memberships.reserve(_family_memberships.size());
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        if (!merged_memberships.empty() &&
            merged_memberships.back().cohort_handle == edge.cohort_handle &&
            merged_memberships.back().family_handle == edge.family_handle) {
            FamilyMembershipEdge &dst = merged_memberships.back();
            dst.people += edge.people;
            dst.cash_claim += edge.cash_claim;
            dst.population_basis = std::max(dst.population_basis,
                                            edge.population_basis);
            dst.funds_basis = std::max(dst.funds_basis, edge.funds_basis);
        } else {
            merged_memberships.push_back(edge);
        }
    }
    _family_memberships.swap(merged_memberships);

    _family_member_offsets.assign(_families.active.size() + 1, 0);
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        int32_t family = -1;
        if (_families.valid_handle(edge.family_handle, family))
            ++_family_member_offsets[static_cast<size_t>(family) + 1];
    }
    for (size_t i = 0; i + 1 < _family_member_offsets.size(); ++i)
        _family_member_offsets[i + 1] += _family_member_offsets[i];
    _family_member_edge_indices.assign(_family_memberships.size(), -1);
    std::vector<int32_t> family_member_cursor(_family_member_offsets.begin(),
                                               _family_member_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(_family_memberships.size()); ++i) {
        int32_t family = -1;
        if (_families.valid_handle(_family_memberships[i].family_handle, family))
            _family_member_edge_indices[family_member_cursor[family]++] = i;
    }

    _rebuild_family_membership_ms += elapsed_ms(membership_started);
    const auto ownership_started = Clock::now();
    // Nothing below mutates _buildings, so the shared handle index stays valid
    // for the whole rebuild and we avoid re-hashing every building group.
    const std::unordered_map<uint64_t, int32_t> &building_by_handle =
        building_handle_index();
    _family_ownerships.erase(std::remove_if(
        _family_ownerships.begin(), _family_ownerships.end(),
        [&](const FamilyBuildingOwnership &edge) {
            int32_t family = -1;
            return edge.owned_count <= 0 ||
                !_families.valid_handle(edge.family_handle, family) ||
                building_by_handle.find(edge.building_handle) ==
                    building_by_handle.end();
        }), _family_ownerships.end());
    std::sort(_family_ownerships.begin(), _family_ownerships.end(),
        [](const FamilyBuildingOwnership &a,
           const FamilyBuildingOwnership &b) {
            return std::tie(a.building_handle, a.family_handle) <
                std::tie(b.building_handle, b.family_handle);
        });
    std::vector<FamilyBuildingOwnership> merged_ownerships;
    merged_ownerships.reserve(_family_ownerships.size());
    for (const FamilyBuildingOwnership &edge : _family_ownerships) {
        if (!merged_ownerships.empty() &&
            merged_ownerships.back().building_handle == edge.building_handle &&
            merged_ownerships.back().family_handle == edge.family_handle) {
            merged_ownerships.back().owned_count += edge.owned_count;
            merged_ownerships.back().filled_owner += edge.filled_owner;
        } else {
            merged_ownerships.push_back(edge);
        }
    }
    _family_ownerships.swap(merged_ownerships);

    _family_owned_offsets.assign(_families.active.size() + 1, 0);
    for (const FamilyBuildingOwnership &edge : _family_ownerships) {
        int32_t family = -1;
        if (_families.valid_handle(edge.family_handle, family))
            ++_family_owned_offsets[static_cast<size_t>(family) + 1];
    }
    for (size_t i = 0; i + 1 < _family_owned_offsets.size(); ++i)
        _family_owned_offsets[i + 1] += _family_owned_offsets[i];
    _family_owned_edge_indices.assign(_family_ownerships.size(), -1);
    std::vector<int32_t> family_owned_cursor(_family_owned_offsets.begin(),
                                              _family_owned_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(_family_ownerships.size()); ++i) {
        int32_t family = -1;
        if (_families.valid_handle(_family_ownerships[i].family_handle, family))
            _family_owned_edge_indices[family_owned_cursor[family]++] = i;
    }

    _rebuild_family_ownership_ms += elapsed_ms(ownership_started);
    const auto csr_started = Clock::now();
    _family_cohort_offsets.assign(_population.active.size() + 1, 0);
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        int32_t slot = -1;
        if (_population.valid_handle(edge.cohort_handle, slot))
            ++_family_cohort_offsets[static_cast<size_t>(slot) + 1];
    }
    for (size_t i = 0; i + 1 < _family_cohort_offsets.size(); ++i)
        _family_cohort_offsets[i + 1] += _family_cohort_offsets[i];
    _family_cohort_edge_indices.assign(_family_memberships.size(), -1);
    std::vector<int32_t> cohort_cursor(_family_cohort_offsets.begin(),
                                       _family_cohort_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(_family_memberships.size()); ++i) {
        int32_t slot = -1;
        if (_population.valid_handle(_family_memberships[i].cohort_handle, slot))
            _family_cohort_edge_indices[cohort_cursor[slot]++] = i;
    }

    _family_building_offsets.assign(_buildings.size() + 1, 0);
    for (const FamilyBuildingOwnership &edge : _family_ownerships) {
        const auto it = building_by_handle.find(edge.building_handle);
        if (it != building_by_handle.end())
            ++_family_building_offsets[static_cast<size_t>(it->second) + 1];
    }
    for (size_t i = 0; i + 1 < _family_building_offsets.size(); ++i)
        _family_building_offsets[i + 1] += _family_building_offsets[i];
    _family_building_edge_indices.assign(_family_ownerships.size(), -1);
    std::vector<int32_t> building_cursor(_family_building_offsets.begin(),
                                         _family_building_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(_family_ownerships.size()); ++i) {
        const auto it = building_by_handle.find(_family_ownerships[i].building_handle);
        if (it != building_by_handle.end())
            _family_building_edge_indices[building_cursor[it->second]++] = i;
    }

    _rebuild_family_csr_ms += elapsed_ms(csr_started);
    const auto cell_index_started = Clock::now();
    std::vector<std::pair<int32_t, int32_t>> cell_family;
    cell_family.reserve(_family_memberships.size());
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        int32_t slot = -1, family = -1;
        if (!_population.valid_handle(edge.cohort_handle, slot) ||
            !_families.valid_handle(edge.family_handle, family)) continue;
        const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
        if (cell >= 0) cell_family.emplace_back(cell, family);
    }
    for (const FamilyBuildingOwnership &edge : _family_ownerships) {
        int32_t family = -1;
        const auto building = building_by_handle.find(edge.building_handle);
        if (!_families.valid_handle(edge.family_handle, family) ||
            building == building_by_handle.end()) continue;
        const int32_t cell = _buildings[building->second].cell;
        if (cell >= 0) cell_family.emplace_back(cell, family);
    }
    std::sort(cell_family.begin(), cell_family.end());
    cell_family.erase(std::unique(cell_family.begin(), cell_family.end()),
                      cell_family.end());
    _family_cell_offsets.assign(static_cast<size_t>(_cell_count) + 1, 0);
    for (const auto &item : cell_family)
        ++_family_cell_offsets[static_cast<size_t>(item.first) + 1];
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _family_cell_offsets[cell + 1] += _family_cell_offsets[cell];
    _family_cell_indices.clear();
    _family_cell_indices.reserve(cell_family.size());
    for (const auto &item : cell_family) _family_cell_indices.push_back(item.second);
    _rebuild_family_cellindex_ms += elapsed_ms(cell_index_started);
    _family_indices_dirty = false;
}

void NativeEconomyRuntime::normalize_family_memberships() {
    // This is the one mandatory rebuild per commit. It runs after all
    // population and building changes for the epoch, so it is what prunes
    // edges orphaned by cohort release or building demolition. The later
    // rebuilds in the commit are gated on the dirty flag and rely on it.
    rebuild_family_indices();
    bool rescale_emptied_edge = false;
    size_t begin = 0;
    while (begin < _family_memberships.size()) {
        size_t end = begin + 1;
        while (end < _family_memberships.size() &&
               _family_memberships[end].cohort_handle ==
                   _family_memberships[begin].cohort_handle) ++end;
        int32_t slot = -1;
        if (!_population.valid_handle(
                _family_memberships[begin].cohort_handle, slot)) {
            begin = end;
            continue;
        }
        const int64_t current_pop = std::max<int64_t>(0,
            _population.population[slot]);
        const int64_t current_funds = std::max<int64_t>(0,
            _population.funds[slot]);
        int64_t old_people = 0, old_claim = 0;
        int64_t pop_basis = 0, funds_basis = 0;
        for (size_t i = begin; i < end; ++i) {
            old_people += std::max<int64_t>(0, _family_memberships[i].people);
            old_claim += std::max<int64_t>(0, _family_memberships[i].cash_claim);
            pop_basis = std::max(pop_basis,
                _family_memberships[i].population_basis);
            funds_basis = std::max(funds_basis,
                _family_memberships[i].funds_basis);
        }
        pop_basis = std::max(pop_basis, old_people);
        funds_basis = std::max(funds_basis, old_claim);
        const int64_t target_people = pop_basis > 0
            ? std::min(current_pop,
                mul_div_sat(current_pop, std::min(old_people, pop_basis),
                            pop_basis, _saturation_count)) : 0;
        const int64_t target_claim = funds_basis > 0
            ? std::min(current_funds,
                mul_div_sat(current_funds, std::min(old_claim, funds_basis),
                            funds_basis, _saturation_count)) : 0;
        int64_t people_prefix = 0, people_done = 0;
        int64_t claim_prefix = 0, claim_done = 0;
        for (size_t i = begin; i < end; ++i) {
            FamilyMembershipEdge &edge = _family_memberships[i];
            const int64_t people_before = edge.people;
            people_prefix += std::max<int64_t>(0, edge.people);
            claim_prefix += std::max<int64_t>(0, edge.cash_claim);
            const int64_t next_people = old_people > 0
                ? mul_div_sat(target_people, people_prefix, old_people,
                              _saturation_count) : 0;
            const int64_t next_claim = old_claim > 0
                ? mul_div_sat(target_claim, claim_prefix, old_claim,
                              _saturation_count) : 0;
            edge.people = std::max<int64_t>(0, next_people - people_done);
            edge.cash_claim = std::max<int64_t>(0, next_claim - claim_done);
            edge.population_basis = current_pop;
            edge.funds_basis = current_funds;
            edge.owner_employed = 0;
            edge.employee_employed = 0;
            if (people_before > 0 && edge.people <= 0) rescale_emptied_edge = true;
            people_done = next_people;
            claim_done = next_claim;
        }
        begin = end;
    }
    // Rescaling never adds, removes or reorders edges, so the CSR built above
    // stays exact unless an edge was emptied and now has to be pruned.
    if (rescale_emptied_edge) {
        _family_indices_dirty = true;
        rebuild_family_indices();
    }
}

void NativeEconomyRuntime::clamp_family_owner_employment_for_cell(int32_t cell) {
    if (_family_runtime_mode != 2 || cell < 0 ||
        cell >= _cell_count || _family_building_offsets.size() !=
            _buildings.size() + 1) return;
    const int32_t first = _building_cell_offsets[cell];
    const int32_t last = _building_cell_offsets[cell + 1];
    // Only memberships referenced by ownerships in this cell need a counter.
    // A full edge-sized scratch here would turn every building cell into O(E).
    std::unordered_map<int32_t, int64_t> membership_used;
    membership_used.reserve(16);
    std::unordered_map<uint64_t, int64_t> anonymous_used;
    for (int32_t g = first; g < last; ++g) {
        BuildingGroup &group = _buildings[g];
        if (group.count <= 0 || group.owner_signature_id < 0) continue;
        const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
        if (owner_slot < 0) { group.filled_owner = 0; continue; }
        const uint64_t cohort_handle = _population.handle_for_slot(owner_slot);
        int64_t family_people = 0;
        const int32_t cb = _family_cohort_offsets[owner_slot];
        const int32_t ce = _family_cohort_offsets[owner_slot + 1];
        for (int32_t p = cb; p < ce; ++p)
            family_people += _family_memberships[
                _family_cohort_edge_indices[p]].people;
        const int64_t anonymous_people = std::max<int64_t>(0,
            _population.population[owner_slot] - family_people);
        int64_t remaining_fill = std::max<int64_t>(0, group.filled_owner);
        int64_t total_filled = 0;
        int64_t family_owned = 0;
        const int32_t ob = _family_building_offsets[g];
        const int32_t oe = _family_building_offsets[g + 1];
        for (int32_t p = ob; p < oe; ++p) {
            FamilyBuildingOwnership &ownership =
                _family_ownerships[_family_building_edge_indices[p]];
            ownership.owned_count = std::min(std::max<int64_t>(0,
                ownership.owned_count), std::max<int64_t>(0,
                    group.count - family_owned));
            family_owned += ownership.owned_count;
            int32_t membership_index = -1;
            for (int32_t q = cb; q < ce; ++q) {
                const int32_t candidate = _family_cohort_edge_indices[q];
                if (_family_memberships[candidate].family_handle ==
                        ownership.family_handle) {
                    membership_index = candidate;
                    break;
                }
            }
            const int64_t member_available = membership_index >= 0
                ? std::max<int64_t>(0,
                    _family_memberships[membership_index].people -
                    membership_used[membership_index]) : 0;
            const int64_t target = ownership.owned_count *
                _building_types[group.type_id].owner_slots_per_building;
            ownership.filled_owner = std::min(
                std::min(target, member_available), remaining_fill);
            if (membership_index >= 0)
                membership_used[membership_index] += ownership.filled_owner;
            remaining_fill -= ownership.filled_owner;
            total_filled += ownership.filled_owner;
            _family_owner_jobs_filled += ownership.filled_owner;
            _family_owner_jobs_vacant += target - ownership.filled_owner;
        }
        const int64_t anonymous_target = std::max<int64_t>(0,
            group.count - family_owned) *
            _building_types[group.type_id].owner_slots_per_building;
        const int64_t anonymous_available = std::max<int64_t>(0,
            anonymous_people - anonymous_used[cohort_handle]);
        const int64_t anonymous_fill = std::min(
            std::min(anonymous_target, anonymous_available), remaining_fill);
        anonymous_used[cohort_handle] += anonymous_fill;
        group.filled_owner = total_filled + anonymous_fill;
    }
}

void NativeEconomyRuntime::update_family_employment_attribution() {
    for (FamilyMembershipEdge &edge : _family_memberships) {
        edge.owner_employed = 0;
        edge.employee_employed = 0;
    }
    if (_family_building_offsets.size() != _buildings.size() + 1 ||
        _family_cohort_offsets.size() != _population.active.size() + 1)
        return;
    for (int32_t group_index = 0;
         group_index < static_cast<int32_t>(_buildings.size()); ++group_index) {
        const BuildingGroup &group = _buildings[group_index];
        const int32_t slot = find_cohort_slot(group.cell,
                                              group.owner_signature_id);
        if (slot < 0) continue;
        for (int32_t ownership_pos = _family_building_offsets[group_index];
             ownership_pos < _family_building_offsets[group_index + 1];
             ++ownership_pos) {
            const FamilyBuildingOwnership &ownership = _family_ownerships[
                _family_building_edge_indices[ownership_pos]];
            for (int32_t p = _family_cohort_offsets[slot];
                 p < _family_cohort_offsets[slot + 1]; ++p) {
                FamilyMembershipEdge &edge = _family_memberships[
                    _family_cohort_edge_indices[p]];
                if (edge.family_handle == ownership.family_handle) {
                    edge.owner_employed = saturating_add(edge.owner_employed,
                        ownership.filled_owner, _saturation_count);
                    break;
                }
            }
        }
    }
    size_t begin = 0;
    while (begin < _family_memberships.size()) {
        size_t end = begin + 1;
        while (end < _family_memberships.size() &&
               _family_memberships[end].cohort_handle ==
                   _family_memberships[begin].cohort_handle) ++end;
        int32_t slot = -1;
        if (_population.valid_handle(
                _family_memberships[begin].cohort_handle, slot)) {
            const int64_t cohort_employee = std::max<int64_t>(0,
                _population.employee_employed[slot]);
            const int64_t cohort_capacity = std::max<int64_t>(1,
                _population.population[slot] -
                _population.owner_employed[slot]);
            int64_t prefix = 0, distributed = 0;
            for (size_t i = begin; i < end; ++i) {
                FamilyMembershipEdge &edge = _family_memberships[i];
                const int64_t capacity = std::max<int64_t>(0,
                    edge.people - edge.owner_employed);
                prefix += capacity;
                const int64_t next = mul_div_sat(cohort_employee,
                    std::min(prefix, cohort_capacity), cohort_capacity,
                    _saturation_count);
                edge.employee_employed = std::max<int64_t>(0,
                    next - distributed);
                distributed = next;
            }
        }
        begin = end;
    }
}

int32_t NativeEconomyRuntime::create_family_for_building(
        int32_t cell, int32_t building_index, int64_t founders,
        int64_t filled_owner) {
    if (cell < 0 || cell >= _cell_count || building_index < 0 ||
        building_index >= static_cast<int32_t>(_buildings.size()) ||
        founders <= 0) return -1;
    const BuildingGroup &group = _buildings[building_index];
    if (group.cell != cell || group.count <= 0 || group.modifier_handle == 0)
        return -1;
    const int32_t slot = find_cohort_slot(cell, group.owner_signature_id);
    if (slot < 0 || _population.population[slot] < founders) return -1;
    const int64_t identity_day = std::max<int64_t>(0, _current_day);
    const int32_t family_index = _families.allocate();
    const uint64_t family_handle = _families.handle_for_index(family_index);
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(identity_day));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(cell));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(family_index));
    int64_t stable_id = static_cast<int64_t>(
        (hash & 0x7fffffffffffffffULL) | 1ULL);
    for (uint64_t probe = 1;
         _family_stable_ids.count(stable_id) != 0; ++probe) {
        stable_id = static_cast<int64_t>((trace_hash_mix(hash, probe) &
            0x7fffffffffffffffULL) | 1ULL);
    }
    _families.stable_id[family_index] = stable_id;
    _family_stable_ids.insert(stable_id);
    int64_t total_weight = 0;
    for (int32_t weight : _family_surname_weights) total_weight += weight;
    int64_t roll = static_cast<int64_t>(trace_hash_mix(hash, 0x5355524eULL) %
        static_cast<uint64_t>(std::max<int64_t>(1, total_weight)));
    int32_t surname = 0;
    for (; surname + 1 < static_cast<int32_t>(_family_surname_weights.size());
         ++surname) {
        if (roll < _family_surname_weights[surname]) break;
        roll -= _family_surname_weights[surname];
    }
    uint32_t disambiguator = 0;
    // Only same-surname families can shift the disambiguator, so consult that
    // bucket rather than the whole family table. Entries are validated on read
    // because retirement leaves them behind until the bucket is compacted.
    if (surname >= 0) {
        if (static_cast<size_t>(surname) >= _family_surname_members.size())
            _family_surname_members.resize(static_cast<size_t>(surname) + 1);
        std::vector<int32_t> &bucket =
            _family_surname_members[static_cast<size_t>(surname)];
        _scan_steps_family_linear += static_cast<int64_t>(bucket.size());
        note_scan_steps(static_cast<int64_t>(bucket.size()));
        size_t kept = 0;
        for (size_t b = 0; b < bucket.size(); ++b) {
            const int32_t i = bucket[b];
            if (i == family_index || i < 0 ||
                i >= static_cast<int32_t>(_families.active.size()) ||
                _families.active[i] == 0 || _families.surname_id[i] != surname)
                continue;
            bucket[kept++] = i;
            disambiguator = std::max(disambiguator,
                _families.surname_disambiguator[i] + 1U);
        }
        bucket.resize(kept);
        bucket.push_back(family_index);
    }
    _families.surname_id[family_index] = surname;
    _families.surname_disambiguator[family_index] = disambiguator;
    _families.founded_day[family_index] = identity_day;
    _families.home_cell[family_index] = cell;
    _families.origin_ethnicity[family_index] =
        _signatures[group.owner_signature_id].ethnicity_id;
    FamilyMembershipEdge membership;
    membership.family_handle = family_handle;
    membership.cohort_handle = _population.handle_for_slot(slot);
    membership.people = founders;
    membership.cash_claim = _population.population[slot] > 0
        ? mul_div_sat(_population.funds[slot], founders,
            _population.population[slot], _saturation_count) : 0;
    membership.population_basis = _population.population[slot];
    membership.funds_basis = _population.funds[slot];
    membership.owner_employed = std::clamp<int64_t>(filled_owner, 0, founders);
    _family_memberships.push_back(membership);
    _family_ownerships.push_back({family_handle, group.modifier_handle, 1,
        membership.owner_employed});
    assign_core_family_traits(family_index);
    ++_families_formed;
    _family_indices_dirty = true;
    return family_index;
}

bool NativeEconomyRuntime::repair_forced_capital_founder(int32_t cell) {
    if (_family_runtime_mode != 2 || _person_runtime_mode != 2 ||
        cell < 0 || cell >= _cell_count || _current_day < 0 ||
        _current_day > 30 || _settlements.name_forced[cell] == 0)
        return false;
    // Use authoritative edges rather than possibly stale cell CSR: several
    // capitals may be repaired in the same FAMILY_COMMIT before the final
    // deterministic rebuild.
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        int32_t slot = -1;
        if (_population.valid_handle(edge.cohort_handle, slot) &&
            _population.page_cell[slot / COHORT_PAGE_SIZE] == cell && edge.people > 0)
            return false;
    }
    const auto type_it = std::lower_bound(_building_type_ids.begin(),
        _building_type_ids.end(), std::string("gathering_ground"));
    if (type_it == _building_type_ids.end() ||
        *type_it != "gathering_ground") return false;
    const int32_t type_id = static_cast<int32_t>(
        type_it - _building_type_ids.begin());
    const int32_t first = _building_cell_offsets[cell];
    const int32_t last = _building_cell_offsets[cell + 1];
    for (int32_t group_index = first; group_index < last; ++group_index) {
        const BuildingGroup &group = _buildings[group_index];
        if (group.type_id != type_id || group.count <= 0 ||
            group.modifier_handle == 0) continue;
        const int64_t founders =
            _building_types[type_id].owner_slots_per_building;
        const int32_t owner_slot = find_cohort_slot(
            cell, group.owner_signature_id);
        if (founders <= 0 || owner_slot < 0 ||
            group.filled_owner < founders ||
            _population.population[owner_slot] < founders) continue;
        return create_family_for_building(cell, group_index, founders,
            founders) >= 0;
    }
    return false;
}

bool NativeEconomyRuntime::form_family_for_cell(int32_t cell) {
    if (_family_runtime_mode != 2 || cell < 0 || cell >= _cell_count ||
        _settlements.tier[cell] < _family_min_settlement_tier ||
        _committed_cells[cell].population < _family_min_population_per_active)
        return false;
    if (_family_cell_offsets.size() == static_cast<size_t>(_cell_count + 1) &&
        _family_cell_offsets[cell + 1] - _family_cell_offsets[cell] >=
            _family_max_per_cell) return false;
    const int32_t first = _building_cell_offsets[cell];
    const int32_t last = _building_cell_offsets[cell + 1];
    int32_t best = -1;
    for (int32_t g = first; g < last; ++g) {
        const BuildingGroup &group = _buildings[g];
        if (group.count <= 0 || group.modifier_handle == 0 ||
            group.operating_state != 0) continue;
        const BuildingType &type = _building_types[group.type_id];
        const int64_t owner_slots = type.owner_slots_per_building;
        if (owner_slots <= 0 || group.filled_owner < owner_slots ||
            group.realized_profit_margin_q16 < type.target_operating_margin_q16)
            continue;
        int64_t family_owned = 0;
        if (_family_building_offsets.size() == _buildings.size() + 1) {
            for (int32_t p = _family_building_offsets[g];
                 p < _family_building_offsets[g + 1]; ++p)
                family_owned += _family_ownerships[
                    _family_building_edge_indices[p]].owned_count;
        }
        if (family_owned >= group.count) continue;
        const int32_t slot = find_cohort_slot(cell, group.owner_signature_id);
        if (slot < 0) continue;
        int64_t family_people = 0;
        if (_family_cohort_offsets.size() == _population.active.size() + 1) {
            for (int32_t p = _family_cohort_offsets[slot];
                 p < _family_cohort_offsets[slot + 1]; ++p)
                family_people += _family_memberships[
                    _family_cohort_edge_indices[p]].people;
        }
        if (_population.population[slot] - family_people < owner_slots)
            continue;
        int64_t sat = 0;
        const int64_t living_cost = living_cost_for_signature(cell,
            group.owner_signature_id, -1, sat);
        const int64_t projected_income = projected_owner_income_per_day(
            group, sat);
        if (projected_income <= living_cost) continue;
        const int64_t reserve = saturating_mul(saturating_mul(living_cost,
            owner_slots, sat), 30, sat);
        const int64_t anonymous_cash = _population.population[slot] > 0
            ? mul_div_sat(_population.funds[slot],
                _population.population[slot] - family_people,
                _population.population[slot], _saturation_count) : 0;
        if (anonymous_cash < reserve) continue;
        if (best < 0 || std::tie(group.realized_profit_margin_q16,
                group.last_revenue, group.type_id, group.owner_signature_id) >
            std::tie(_buildings[best].realized_profit_margin_q16,
                _buildings[best].last_revenue, _buildings[best].type_id,
                _buildings[best].owner_signature_id)) best = g;
    }
    if (best < 0) return false;
    const BuildingGroup &group = _buildings[best];
    const BuildingType &type = _building_types[group.type_id];
    const int32_t slot = find_cohort_slot(cell, group.owner_signature_id);
    const int64_t founders = type.owner_slots_per_building;
    if (slot < 0 || founders <= 0) return false;
    return create_family_for_building(cell, best, founders, founders) >= 0;
}

void NativeEconomyRuntime::dissolve_family(uint64_t family_handle) {
    int32_t index = -1;
    if (!_families.valid_handle(family_handle, index)) return;
    _family_memberships.erase(std::remove_if(_family_memberships.begin(),
        _family_memberships.end(), [&](const FamilyMembershipEdge &edge) {
            return edge.family_handle == family_handle;
        }), _family_memberships.end());
    _family_ownerships.erase(std::remove_if(_family_ownerships.begin(),
        _family_ownerships.end(), [&](const FamilyBuildingOwnership &edge) {
            return edge.family_handle == family_handle;
        }), _family_ownerships.end());
    _family_traits.erase(std::remove_if(_family_traits.begin(),
        _family_traits.end(), [&](const FamilyTraitRoll &roll) {
            return roll.family_handle == family_handle;
        }), _family_traits.end());
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            _family_influences.active.size()); ++branch) {
        if (_family_influences.active[branch] == 0 ||
            _family_influences.family_handle[branch] != family_handle) continue;
        const uint64_t branch_handle =
            _family_influences.handle_for_index(branch);
        clear_family_branch_effects(branch_handle);
        _family_influences.release(branch);
    }
    _family_stable_ids.erase(_families.stable_id[index]);
    _families.release(index);
    ++_families_dissolved;
    _family_indices_dirty = true;
}

void NativeEconomyRuntime::rebuild_family_influences() {
    struct Key {
        uint64_t family = 0;
        int32_t cell = -1;
        bool operator==(const Key &other) const {
            return family == other.family && cell == other.cell;
        }
    };
    struct KeyHash {
        size_t operator()(const Key &key) const noexcept {
            uint64_t value = key.family;
            value ^= static_cast<uint64_t>(static_cast<uint32_t>(key.cell)) +
                0x9e3779b97f4a7c15ULL + (value << 6U) + (value >> 2U);
            return static_cast<size_t>(value);
        }
    };
    struct Aggregate {
        int64_t population = 0, cash = 0, asset = 0;
        int64_t satisfaction_weighted = 0;
    };
    std::unordered_map<Key, Aggregate, KeyHash> aggregates;
    aggregates.reserve(_family_memberships.size() + _family_ownerships.size());
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        int32_t family = -1, slot = -1;
        if (!_families.valid_handle(edge.family_handle, family) ||
            !_population.valid_handle(edge.cohort_handle, slot)) continue;
        const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
        if (cell < 0 || cell >= _cell_count) continue;
        Aggregate &aggregate = aggregates[{edge.family_handle, cell}];
        const int64_t people = std::max<int64_t>(0, edge.people);
        aggregate.population = saturating_add(aggregate.population, people,
                                              _saturation_count);
        aggregate.cash = saturating_add(aggregate.cash,
            std::max<int64_t>(0, edge.cash_claim), _saturation_count);
        aggregate.satisfaction_weighted = saturating_add(
            aggregate.satisfaction_weighted,
            saturating_mul(_population.composite_satisfaction[slot], people,
                           _saturation_count), _saturation_count);
    }
    const std::unordered_map<uint64_t, int32_t> &building_by_handle =
        building_handle_index();
    for (const FamilyBuildingOwnership &edge : _family_ownerships) {
        int32_t family = -1;
        const auto found = building_by_handle.find(edge.building_handle);
        if (!_families.valid_handle(edge.family_handle, family) ||
            found == building_by_handle.end()) continue;
        const BuildingGroup &group = _buildings[found->second];
        const int64_t unit_value = building_reset_capital_value(group);
        Aggregate &aggregate = aggregates[{edge.family_handle, group.cell}];
        aggregate.asset = saturating_add(aggregate.asset, saturating_mul(
            unit_value, std::max<int64_t>(0, edge.owned_count),
            _saturation_count), _saturation_count);
    }

    std::vector<uint8_t> relevant_cells(static_cast<size_t>(_cell_count), 0);
    for (const auto &item : aggregates)
        if (item.first.cell >= 0 && item.first.cell < _cell_count)
            relevant_cells[item.first.cell] = 1;
    std::vector<int64_t> total_population(static_cast<size_t>(_cell_count), 0);
    std::vector<int64_t> total_cash(static_cast<size_t>(_cell_count), 0);
    std::vector<int64_t> total_asset(static_cast<size_t>(_cell_count), 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (relevant_cells[cell] == 0) continue;
        total_population[cell] = std::max<int64_t>(
            0, _committed_cells[cell].population);
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            total_cash[cell] = saturating_add(total_cash[cell],
                std::max<int64_t>(0, _population.funds[slot]),
                _saturation_count);
        });
    }
    for (const BuildingGroup &group : _buildings) {
        if (group.cell < 0 || group.cell >= _cell_count || group.count <= 0 ||
            relevant_cells[group.cell] == 0) continue;
        total_asset[group.cell] = saturating_add(total_asset[group.cell],
            saturating_mul(building_reset_capital_value(group), group.count,
                _saturation_count), _saturation_count);
    }

    std::unordered_map<Key, int32_t, KeyHash> existing;
    existing.reserve(_family_influences.active.size());
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            _family_influences.active.size()); ++branch)
        if (_family_influences.active[branch] != 0)
            existing[{_family_influences.family_handle[branch],
                      _family_influences.cell[branch]}] = branch;
    std::vector<uint8_t> seen(_family_influences.active.size(), 0);
    const int32_t thresholds[6] = {0,
        Q16_ONE * 2 / 100, Q16_ONE * 5 / 100, Q16_ONE * 10 / 100,
        Q16_ONE * 20 / 100, Q16_ONE * 40 / 100};
    for (const auto &item : aggregates) {
        if (item.second.population <= 0 && item.second.cash <= 0 &&
            item.second.asset <= 0) continue;
        const Key key = item.first;
        int32_t branch = -1;
        bool changed = false;
        const auto found = existing.find(key);
        if (found == existing.end()) {
            branch = _family_influences.allocate();
            if (seen.size() < _family_influences.active.size())
                seen.resize(_family_influences.active.size(), 0);
            _family_influences.family_handle[branch] = key.family;
            _family_influences.cell[branch] = key.cell;
            int32_t family = -1;
            uint64_t hash = 1469598103934665603ULL;
            if (_families.valid_handle(key.family, family))
                hash = trace_hash_mix(hash, static_cast<uint64_t>(
                    _families.stable_id[family]));
            hash = trace_hash_mix(hash, static_cast<uint32_t>(key.cell));
            _family_influences.stable_id[branch] = static_cast<int64_t>(
                (hash & 0x7fffffffffffffffULL) | 1ULL);
            changed = true;
        } else {
            branch = found->second;
        }
        seen[branch] = 1;
        _family_influences.population[branch] = item.second.population;
        _family_influences.cash[branch] = item.second.cash;
        _family_influences.building_asset[branch] = item.second.asset;
        const auto share = [&](int64_t value, int64_t total) -> int32_t {
            return total > 0 ? static_cast<int32_t>(std::clamp<int64_t>(
                mul_div_sat(value, Q16_ONE, total, _saturation_count),
                0, Q16_ONE)) : 0;
        };
        _family_influences.population_share_q16[branch] = share(
            item.second.population, total_population[key.cell]);
        _family_influences.cash_share_q16[branch] = share(
            item.second.cash, total_cash[key.cell]);
        _family_influences.building_share_q16[branch] = share(
            item.second.asset, total_asset[key.cell]);
        // The 25/35/40 prestige formula is deliberately untouched: satisfaction
        // is recorded alongside it and only gates the survival review below.
        _family_influences.score_q16[branch] = static_cast<int32_t>(
            (static_cast<int64_t>(_family_influences.population_share_q16[branch]) * 25 +
             static_cast<int64_t>(_family_influences.cash_share_q16[branch]) * 35 +
             static_cast<int64_t>(_family_influences.building_share_q16[branch]) * 40) / 100);
        _family_influences.satisfaction_q16[branch] = item.second.population > 0
            ? static_cast<int32_t>(std::clamp<int64_t>(
                  item.second.satisfaction_weighted / item.second.population,
                  0, Q16_ONE - 1))
            : static_cast<int32_t>(Q16_ONE - 1);
        const int64_t phase = _family_influences.stable_id[branch] % 30;
        const bool review_due = _current_day >= 0 &&
            ((_current_day % 30 + 30) % 30) == phase;
        if (review_due && _family_influences.last_review_day[branch] != _current_day) {
            _family_influences.last_review_day[branch] = _current_day;
            const int32_t current = _family_influences.prestige_level[branch];
            int32_t upgrade_target = 0, downgrade_target = 0;
            for (int32_t level = 1; level <= 5; ++level) {
                if (_family_influences.score_q16[branch] >= thresholds[level])
                    upgrade_target = level;
                if (_family_influences.score_q16[branch] >=
                        thresholds[level] * 80 / 100)
                    downgrade_target = level;
            }
            // A branch whose own members live in the bottom pressure bands has
            // no standing to rise, however much cash and land it controls.
            // Decline is never blocked, so this can only slow promotion.
            const bool members_discontent =
                _family_influences.satisfaction_q16[branch] <
                _satisfaction_pressure_thresholds_q16[1];
            int32_t target = current;
            if (upgrade_target > current && !members_discontent)
                target = upgrade_target;
            else if (downgrade_target < current) target = downgrade_target;
            if (target == current) {
                _family_influences.pending_target_level[branch] =
                    static_cast<uint8_t>(current);
                _family_influences.review_streak[branch] = 0;
            } else {
                const int32_t previous =
                    _family_influences.pending_target_level[branch];
                const bool same_direction =
                    (target > current && previous > current) ||
                    (target < current && previous < current);
                _family_influences.pending_target_level[branch] =
                    static_cast<uint8_t>(target);
                _family_influences.review_streak[branch] = static_cast<uint8_t>(
                    same_direction ? std::min<int32_t>(255,
                        _family_influences.review_streak[branch] + 1) : 1);
                if (_family_influences.review_streak[branch] >= 2) {
                    _family_influences.prestige_level[branch] =
                        static_cast<uint8_t>(target);
                    _family_influences.review_streak[branch] = 0;
                    changed = true;
                }
            }
        }
        if (changed) reconcile_family_branch_effects(
            _family_influences.handle_for_index(branch), true);
    }
    for (int32_t branch = 0; branch < static_cast<int32_t>(seen.size()); ++branch) {
        if (_family_influences.active[branch] == 0 || seen[branch] != 0) continue;
        const uint64_t handle = _family_influences.handle_for_index(branch);
        clear_family_branch_effects(handle);
        _family_influences.release(branch);
    }
}

void NativeEconomyRuntime::apply_due_family_trait_commands() {
    std::stable_sort(_family_trait_commands.begin(), _family_trait_commands.end(),
        [](const FamilyTraitCommand &a, const FamilyTraitCommand &b) {
            if (a.effective_day != b.effective_day)
                return a.effective_day < b.effective_day;
            if (a.priority != b.priority) return a.priority < b.priority;
            if (a.sequence != b.sequence) return a.sequence < b.sequence;
            return a.submit_order < b.submit_order;
        });
    std::vector<FamilyTraitCommand> retained;
    std::unordered_set<uint64_t> changed_families;
    for (const FamilyTraitCommand &command : _family_trait_commands) {
        if (command.effective_day > _current_day) {
            retained.push_back(command);
            continue;
        }
        int32_t family = -1;
        if (!_families.valid_handle(command.family_handle, family) ||
            command.trait_id < 0 || command.trait_id >= static_cast<int32_t>(
                _family_trait_ids.size())) continue;
        auto found = std::find_if(_family_traits.begin(), _family_traits.end(),
            [&](const FamilyTraitRoll &roll) {
                return roll.family_handle == command.family_handle &&
                    roll.trait_id == command.trait_id;
            });
        if (command.operation == 2) {
            if (found == _family_traits.end() || found->core != 0) continue;
            _family_traits.erase(found);
            changed_families.insert(command.family_handle);
            continue;
        }
        if (command.operation == 3) {
            if (found == _family_traits.end()) continue;
            if (found->strength_q16 != command.strength_q16) {
                found->strength_q16 = command.strength_q16;
                changed_families.insert(command.family_handle);
            }
            continue;
        }
        if (command.operation != 1) continue;
        if (found != _family_traits.end()) {
            if (found->core == 0 && found->strength_q16 != command.strength_q16) {
                found->strength_q16 = command.strength_q16;
                changed_families.insert(command.family_handle);
            }
            continue;
        }
        bool allowed = true;
        for (int32_t p = _family_trait_prerequisite_offsets[command.trait_id];
             p < _family_trait_prerequisite_offsets[command.trait_id + 1]; ++p) {
            const int32_t required = _family_trait_prerequisites[p];
            allowed = allowed && std::any_of(_family_traits.begin(),
                _family_traits.end(), [&](const FamilyTraitRoll &roll) {
                    return roll.family_handle == command.family_handle &&
                        roll.trait_id == required;
                });
        }
        for (int32_t p = _family_trait_exclusion_offsets[command.trait_id];
             allowed && p < _family_trait_exclusion_offsets[command.trait_id + 1]; ++p) {
            const int32_t excluded = _family_trait_exclusions[p];
            allowed = !std::any_of(_family_traits.begin(), _family_traits.end(),
                [&](const FamilyTraitRoll &roll) {
                    return roll.family_handle == command.family_handle &&
                        roll.trait_id == excluded;
                });
        }
        if (!allowed) continue;
        _family_traits.push_back({command.family_handle, command.trait_id,
                                  command.strength_q16, 0});
        changed_families.insert(command.family_handle);
    }
    _family_trait_commands.swap(retained);
    std::sort(_family_traits.begin(), _family_traits.end(),
        [](const FamilyTraitRoll &a, const FamilyTraitRoll &b) {
            return std::tie(a.family_handle, a.trait_id) <
                std::tie(b.family_handle, b.trait_id);
        });
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            _family_influences.active.size()); ++branch) {
        if (_family_influences.active[branch] == 0 ||
            changed_families.find(_family_influences.family_handle[branch]) ==
                changed_families.end()) continue;
        reconcile_family_branch_effects(
            _family_influences.handle_for_index(branch), true);
    }
}

void NativeEconomyRuntime::review_family_lifecycle() {
    std::vector<uint64_t> dissolve;
    for (int32_t i = 0; i < static_cast<int32_t>(_families.active.size()); ++i) {
        if (_families.active[i] == 0) continue;
        const uint64_t handle = _families.handle_for_index(i);
        const int64_t pop = family_population(handle);
        const int64_t assets = family_owned_buildings(handle);
        if (pop <= 0) { dissolve.push_back(handle); continue; }
        int32_t best_cell = _families.home_cell[i];
        int64_t best_pop = -1;
        std::unordered_map<int32_t, int64_t> branch_pop;
        const int32_t member_begin = _family_member_offsets.size() ==
                _families.active.size() + 1
            ? _family_member_offsets[i] : 0;
        const int32_t member_end = _family_member_offsets.size() ==
                _families.active.size() + 1
            ? _family_member_offsets[i + 1]
            : static_cast<int32_t>(_family_memberships.size());
        for (int32_t p = member_begin; p < member_end; ++p) {
            const FamilyMembershipEdge &edge = _family_memberships[
                _family_member_offsets.size() == _families.active.size() + 1
                    ? _family_member_edge_indices[p] : p];
            if (edge.family_handle != handle) continue;
            int32_t slot = -1;
            if (!_population.valid_handle(edge.cohort_handle, slot)) continue;
            branch_pop[_population.page_cell[slot / COHORT_PAGE_SIZE]] += edge.people;
        }
        for (const auto &branch : branch_pop) {
            if (branch.second > best_pop ||
                (branch.second == best_pop && branch.first < best_cell)) {
                best_cell = branch.first; best_pop = branch.second;
            }
        }
        _families.home_cell[i] = best_cell;
        const int64_t phase = (_families.stable_id[i] % _family_review_days +
            _family_review_days) % _family_review_days;
        if ((_current_day % _family_review_days + _family_review_days) %
                _family_review_days != phase) continue;
        if (assets <= 0 && pop < _family_min_population_per_active) {
            _families.decline_reviews[i] = static_cast<uint16_t>(std::min(
                65535, static_cast<int>(_families.decline_reviews[i]) + 1));
            if (_families.decline_reviews[i] >= _family_decline_reviews)
                dissolve.push_back(handle);
        } else {
            _families.decline_reviews[i] = 0;
        }
    }
    for (uint64_t handle : dissolve) dissolve_family(handle);
}

bool NativeEconomyRuntime::run_family_commit_slice(int64_t &work_done,
                                                    std::string &) {
    if (_family_commit_phase == 0) {
        if (_family_runtime_mode == 0 && _families.active_count == 0) {
            _person_commit_phase = 0;
            _person_commit_cursor = 0;
            _stage = Stage::PERSON_COMMIT;
            ++work_done;
            return true;
        }
        _family_commit_normalize_ms = 0.0;
        _family_commit_attribution_ms = 0.0;
        _family_commit_form_ms = 0.0;
        _family_commit_index_ms = 0.0;
        _family_commit_lifecycle_ms = 0.0;
        _family_commit_influence_ms = 0.0;
        _rebuild_family_membership_ms = 0.0;
        _rebuild_family_ownership_ms = 0.0;
        _rebuild_family_csr_ms = 0.0;
        _rebuild_family_cellindex_ms = 0.0;
        const auto normalize_started = Clock::now();
        apply_due_family_trait_commands();
        normalize_family_memberships();
        _family_commit_normalize_ms += elapsed_ms(normalize_started);
        const auto attribution_started = Clock::now();
        update_family_employment_attribution();
        _family_commit_attribution_ms += elapsed_ms(attribution_started);
        _family_commit_cursor = 0;
        _family_commit_phase = 1;
        ++work_done;
        return true;
    }
    if (_family_commit_phase == 1) {
        const auto form_started = Clock::now();
        const int32_t scan_budget = std::max(1,
            _family_cells_per_slice * _family_review_days);
        const int32_t end = std::min(_cell_count,
            _family_commit_cursor + scan_budget);
        const int32_t phase = static_cast<int32_t>(((_current_day %
            _family_review_days) + _family_review_days) % _family_review_days);
        for (; _family_commit_cursor < end; ++_family_commit_cursor) {
            const int32_t cell = _family_commit_cursor;
            const bool repaired = repair_forced_capital_founder(cell);
            if (!repaired && cell % _family_review_days == phase)
                form_family_for_cell(cell);
        }
        work_done += end - std::max(0, end - scan_budget);
        _family_commit_form_ms += elapsed_ms(form_started);
        if (_family_commit_cursor < _cell_count) return true;
        _family_commit_phase = 2;
        return true;
    }
    // Formation may have appended authoritative edges after the normalization
    // CSR was built. Rebuild before lifecycle so each review is
    // O(edges-of-family), including families formed in this same commit. When
    // nothing was formed the flag stays clear and the CSR is still exact.
    const auto first_index_started = Clock::now();
    bool structure_changed = _family_indices_dirty;
    if (_family_indices_dirty) rebuild_family_indices();
    _family_commit_index_ms += elapsed_ms(first_index_started);
    const auto lifecycle_started = Clock::now();
    review_family_lifecycle();
    _family_commit_lifecycle_ms += elapsed_ms(lifecycle_started);
    const auto second_index_started = Clock::now();
    structure_changed = structure_changed || _family_indices_dirty;
    if (_family_indices_dirty) rebuild_family_indices();
    _family_commit_index_ms += elapsed_ms(second_index_started);
    const auto influence_started = Clock::now();
    if (structure_changed ||
        (_epoch_id % FAMILY_INFLUENCE_REFRESH_EPOCHS) == 0)
        rebuild_family_influences();
    _family_commit_influence_ms += elapsed_ms(influence_started);
    _family_membership_edges_processed +=
        static_cast<int64_t>(_family_memberships.size());
    _family_ownership_edges_processed +=
        static_cast<int64_t>(_family_ownerships.size());
    _family_commit_phase = 0;
    _family_commit_cursor = 0;
    _person_commit_phase = 0;
    _person_commit_cursor = 0;
    _stage = Stage::PERSON_COMMIT;
    ++work_done;
    return true;
}

int32_t NativeEconomyRuntime::family_membership_index(
        uint64_t family_handle, uint64_t cohort_handle) const {
    int32_t slot = -1;
    if (_population.valid_handle(cohort_handle, slot) &&
        _family_cohort_offsets.size() == _population.active.size() + 1) {
        for (int32_t p = _family_cohort_offsets[slot];
             p < _family_cohort_offsets[slot + 1]; ++p) {
            const int32_t edge_index = _family_cohort_edge_indices[p];
            if (_family_memberships[edge_index].family_handle == family_handle)
                return edge_index;
        }
    }
    ++_scan_calls_membership_fallback;
    for (int32_t i = 0; i < static_cast<int32_t>(_family_memberships.size()); ++i)
        if (_family_memberships[i].family_handle == family_handle &&
            _family_memberships[i].cohort_handle == cohort_handle) {
            _scan_steps_membership_fallback += i + 1;
            note_scan_steps(i + 1);
            return i;
        }
    _scan_steps_membership_fallback +=
        static_cast<int64_t>(_family_memberships.size());
    note_scan_steps(static_cast<int64_t>(_family_memberships.size()));
    return -1;
}

void NativeEconomyRuntime::rebuild_person_indices() {
    const auto needs_started = Clock::now();
    if (!_person_needs_normalized || _person_needs_orphaned ||
        _person_need_offsets.size() != _persons.active.size() + 1)
        normalize_person_needs();
    _rebuild_person_needs_ms += elapsed_ms(needs_started);
    const auto count_started = Clock::now();
    const size_t person_slots = _persons.active.size();
    _person_family_offsets.assign(_families.active.size() + 1, 0);
    _person_cohort_offsets.assign(_population.active.size() + 1, 0);
    _person_cell_offsets.assign(static_cast<size_t>(_cell_count) + 1, 0);
    _person_building_offsets.assign(_buildings.size() + 1, 0);
    std::vector<int32_t> building_index(person_slots, -1);
    for (int32_t i = 0; i < static_cast<int32_t>(person_slots); ++i) {
        if (_persons.active[i] == 0) continue;
        int32_t family = -1, slot = -1;
        if (_families.valid_handle(_persons.family_handle[i], family))
            ++_person_family_offsets[static_cast<size_t>(family) + 1];
        if (_population.valid_handle(_persons.cohort_handle[i], slot)) {
            ++_person_cohort_offsets[static_cast<size_t>(slot) + 1];
            const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
            if (cell >= 0 && cell < _cell_count)
                ++_person_cell_offsets[static_cast<size_t>(cell) + 1];
        }
        const int32_t building = building_index_for_handle(
            _persons.building_handle[i]);
        building_index[i] = building;
        if (building >= 0)
            ++_person_building_offsets[static_cast<size_t>(building) + 1];
    }
    const auto prefix = [](std::vector<int32_t> &offsets) {
        for (size_t i = 0; i + 1 < offsets.size(); ++i)
            offsets[i + 1] += offsets[i];
    };
    prefix(_person_family_offsets); prefix(_person_cohort_offsets);
    prefix(_person_cell_offsets); prefix(_person_building_offsets);
    _rebuild_person_count_ms += elapsed_ms(count_started);
    const auto fill_started = Clock::now();
    _person_family_indices.assign(_persons.active_count, -1);
    _person_cohort_indices.assign(_persons.active_count, -1);
    _person_cell_indices.assign(_persons.active_count, -1);
    _person_building_indices.assign(_persons.active_count, -1);
    std::vector<int32_t> fc(_person_family_offsets.begin(),
        _person_family_offsets.empty() ? _person_family_offsets.end()
            : _person_family_offsets.end() - 1);
    std::vector<int32_t> cc(_person_cohort_offsets.begin(),
        _person_cohort_offsets.empty() ? _person_cohort_offsets.end()
            : _person_cohort_offsets.end() - 1);
    std::vector<int32_t> xc(_person_cell_offsets.begin(),
        _person_cell_offsets.empty() ? _person_cell_offsets.end()
            : _person_cell_offsets.end() - 1);
    std::vector<int32_t> bc(_person_building_offsets.begin(),
        _person_building_offsets.empty() ? _person_building_offsets.end()
            : _person_building_offsets.end() - 1);
    for (int32_t i = 0; i < static_cast<int32_t>(person_slots); ++i) {
        if (_persons.active[i] == 0) continue;
        int32_t family = -1, slot = -1;
        if (_families.valid_handle(_persons.family_handle[i], family))
            _person_family_indices[fc[family]++] = i;
        if (_population.valid_handle(_persons.cohort_handle[i], slot)) {
            _person_cohort_indices[cc[slot]++] = i;
            const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
            if (cell >= 0 && cell < _cell_count)
                _person_cell_indices[xc[cell]++] = i;
        }
        if (building_index[i] >= 0)
            _person_building_indices[bc[building_index[i]]++] = i;
    }
    _rebuild_person_fill_ms += elapsed_ms(fill_started);
    const auto sort_started = Clock::now();
    const auto by_stable = [&](int32_t a, int32_t b) {
        return std::tie(_persons.stable_id[a], a) <
            std::tie(_persons.stable_id[b], b);
    };
    // Most buckets hold zero or one person, so the size guard removes tens of
    // thousands of std::sort calls that could never reorder anything.
    for (int32_t family = 0; family + 1 < static_cast<int32_t>(
            _person_family_offsets.size()); ++family)
        if (_person_family_offsets[family + 1] - _person_family_offsets[family] > 1)
            std::sort(_person_family_indices.begin() + _person_family_offsets[family],
                      _person_family_indices.begin() + _person_family_offsets[family + 1],
                      by_stable);
    for (int32_t slot = 0; slot + 1 < static_cast<int32_t>(
            _person_cohort_offsets.size()); ++slot)
        if (_person_cohort_offsets[slot + 1] - _person_cohort_offsets[slot] > 1)
            std::sort(_person_cohort_indices.begin() + _person_cohort_offsets[slot],
                      _person_cohort_indices.begin() + _person_cohort_offsets[slot + 1],
                      by_stable);
    _rebuild_person_sort_ms += elapsed_ms(sort_started);
    _person_cohort_migrations.clear();
    _person_family_migrations.clear();
    _person_indices_dirty = false;
}

// Canonical row order is (person slot, need id). Rows arrive grouped by market
// cell batch, so a comparison sort would run in full every epoch; bucketing by
// slot is linear and produces the offsets the CSR needs as a by-product.
void NativeEconomyRuntime::normalize_person_needs() {
    const size_t person_slots = _persons.active.size();
    _person_need_owner_scratch.clear();
    _person_need_owner_scratch.reserve(_person_needs.size());
    size_t kept = 0;
    for (size_t i = 0; i < _person_needs.size(); ++i) {
        const PersonNeedState state = _person_needs[i];
        int32_t person = -1;
        if (!_persons.valid_handle(state.person_handle, person) ||
            state.stable_need_id < 0 ||
            state.stable_need_id >= static_cast<int32_t>(_need_ids.size()))
            continue;
        if (kept != i) _person_needs[kept] = state;
        _person_need_owner_scratch.push_back(person);
        ++kept;
    }
    _person_needs.resize(kept);

    _person_need_offsets.assign(person_slots + 1, 0);
    for (const int32_t owner : _person_need_owner_scratch)
        ++_person_need_offsets[static_cast<size_t>(owner) + 1];
    for (size_t i = 0; i + 1 < _person_need_offsets.size(); ++i)
        _person_need_offsets[i + 1] += _person_need_offsets[i];
    _person_need_scratch.resize(kept);
    _person_need_cursor_scratch.assign(_person_need_offsets.begin(),
                                       _person_need_offsets.end() - 1);
    for (size_t i = 0; i < kept; ++i)
        _person_need_scratch[static_cast<size_t>(
            _person_need_cursor_scratch[_person_need_owner_scratch[i]]++)] =
            _person_needs[i];
    _person_needs.swap(_person_need_scratch);

    // Each slot holds only a handful of rows, so ordering inside a block and
    // dropping duplicates is cheap. Compaction always moves left, so the write
    // cursor can never overtake the block being read.
    size_t write = 0;
    for (size_t p = 0; p < person_slots; ++p) {
        const size_t begin = static_cast<size_t>(_person_need_offsets[p]);
        const size_t end = static_cast<size_t>(_person_need_offsets[p + 1]);
        const size_t block_start = write;
        _person_need_offsets[p] = static_cast<int32_t>(write);
        if (end - begin > 1)
            std::sort(_person_needs.begin() + begin, _person_needs.begin() + end,
                [](const PersonNeedState &a, const PersonNeedState &b) {
                    return a.stable_need_id < b.stable_need_id;
                });
        for (size_t i = begin; i < end; ++i) {
            if (write > block_start && _person_needs[write - 1].stable_need_id ==
                    _person_needs[i].stable_need_id) continue;
            if (write != i) _person_needs[write] = _person_needs[i];
            ++write;
        }
    }
    _person_needs.resize(write);
    _person_need_offsets[person_slots] = static_cast<int32_t>(write);
    _person_needs_orphaned = false;
    _person_needs_normalized = true;
}

void NativeEconomyRuntime::compact_person_needs() {
    if (!_person_needs_orphaned && _person_needs_normalized &&
        _person_need_offsets.size() == _persons.active.size() + 1) return;
    normalize_person_needs();
}

void NativeEconomyRuntime::retire_person(int32_t person_index) {
    if (person_index < 0 || person_index >= static_cast<int32_t>(
            _persons.active.size()) || _persons.active[person_index] == 0) return;
    const auto retire_call_started = Clock::now();
    ++_person_retire_calls;
    const uint64_t person_handle = _persons.handle_for_index(person_index);
    if (_effect_runtime != nullptr) {
        uint64_t hash = trace_hash_mix(1469598103934665603ULL,
            static_cast<uint64_t>(_persons.stable_id[person_index]));
        hash = trace_hash_mix(hash, 0x504552534f4eULL);
        std::string error;
        _effect_runtime->retire_instance_pod(
            static_cast<int64_t>(hash & 0x7fffffffffffffffULL),
            static_cast<uint32_t>(person_handle >> 32U), _current_day, error);
    }
    if (_modifier_runtime != nullptr)
        _modifier_runtime->unregister_person_target(person_handle);
    // Releasing the slot bumps the generation, so the retired handle can never
    // match again. Orphaned need rows are dropped by one compaction pass
    // instead of one full-array erase per retirement.
    _person_stable_ids.erase(_persons.stable_id[person_index]);
    _persons.release(person_index);
    _person_needs_orphaned = true;
    _person_indices_dirty = true;
    _person_retire_call_ms += elapsed_ms(retire_call_started);
}

void NativeEconomyRuntime::register_person_effect(int32_t person_index) {
    if (_effect_runtime == nullptr || _modifier_runtime == nullptr ||
        person_index < 0 || person_index >= static_cast<int32_t>(_persons.active.size()) ||
        _persons.active[person_index] == 0) return;
    const uint64_t person_handle = _persons.handle_for_index(person_index);
    _modifier_runtime->register_person_target(person_handle);
    uint64_t hash = trace_hash_mix(1469598103934665603ULL,
        static_cast<uint64_t>(_persons.stable_id[person_index]));
    hash = trace_hash_mix(hash, 0x504552534f4eULL);
    const int64_t instance_id = static_cast<int64_t>(
        hash & 0x7fffffffffffffffULL);
    if (_effect_runtime->has_instance_pod(instance_id,
            static_cast<uint32_t>(person_handle >> 32U))) return;
    std::string error;
    _effect_runtime->upsert_instance_pod(
        instance_id,
        "person.modifier.gameplay.generic.bonus",
        static_cast<uint32_t>(person_handle >> 32U), 0x50455253,
        _persons.stable_id[person_index], person_handle, person_handle,
        static_cast<uint32_t>(person_handle >> 32U), 0, _current_day, true, error);
}

void NativeEconomyRuntime::promote_person_for_family(int32_t family_index) {
    if (_person_runtime_mode != 2 || family_index < 0 ||
        family_index >= static_cast<int32_t>(_families.active.size()) ||
        _families.active[family_index] == 0 ||
        _persons.active_count >= _person_max_total) return;
    const uint64_t family_handle = _families.handle_for_index(family_index);
    int64_t family_people = 0, eligible_jobs = 0;
    int32_t best_edge = -1;
    if (_family_member_offsets.size() != _families.active.size() + 1) return;
    for (int32_t p = _family_member_offsets[family_index];
         p < _family_member_offsets[family_index + 1]; ++p) {
        const int32_t edge_index = _family_member_edge_indices[p];
        const FamilyMembershipEdge &edge = _family_memberships[edge_index];
        family_people += std::max<int64_t>(0, edge.people);
        eligible_jobs += std::max<int64_t>(0,
            edge.owner_employed + edge.employee_employed);
        int32_t edge_slot = -1;
        int64_t represented_people = 0;
        if (_population.valid_handle(edge.cohort_handle, edge_slot) &&
            _person_cohort_offsets.size() == _population.active.size() + 1)
            for (int32_t pp = _person_cohort_offsets[edge_slot];
                 pp < _person_cohort_offsets[edge_slot + 1]; ++pp) {
                const int32_t person = _person_cohort_indices[pp];
                if (_persons.family_handle[person] == family_handle)
                    ++represented_people;
            }
        if (represented_people >= edge.people ||
            edge.owner_employed + edge.employee_employed <= 0) continue;
        if (best_edge < 0 ||
            std::tie(edge.owner_employed, edge.employee_employed, edge.people,
                     edge.cohort_handle) >
            std::tie(_family_memberships[best_edge].owner_employed,
                     _family_memberships[best_edge].employee_employed,
                     _family_memberships[best_edge].people,
                     _family_memberships[best_edge].cohort_handle))
            best_edge = edge_index;
    }
    if (best_edge < 0 || family_people <= 0 || eligible_jobs <= 0) return;
    int32_t existing = _person_family_offsets.size() ==
            _families.active.size() + 1
        ? _person_family_offsets[family_index + 1] -
            _person_family_offsets[family_index] : 0;
    const int32_t target = static_cast<int32_t>(std::min<int64_t>(
        _person_max_per_family, std::min(family_people, eligible_jobs)));
    if (existing >= target) return;
    int32_t slot = -1;
    if (!_population.valid_handle(
            _family_memberships[best_edge].cohort_handle, slot)) return;
    const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
    int32_t cell_people = 0;
    if (_person_cell_offsets.size() == static_cast<size_t>(_cell_count + 1))
        cell_people = _person_cell_offsets[cell + 1] - _person_cell_offsets[cell];
    else for (int32_t i = 0; i < static_cast<int32_t>(_persons.active.size()); ++i) {
        int32_t candidate_slot = -1;
        if (_persons.active[i] != 0 &&
            _population.valid_handle(_persons.cohort_handle[i], candidate_slot) &&
            _population.page_cell[candidate_slot / COHORT_PAGE_SIZE] == cell) ++cell_people;
    }
    if (cell_people >= _person_max_per_cell) return;
    const int32_t index = _persons.allocate();
    const uint64_t handle = _persons.handle_for_index(index);
    const int64_t identity_day = std::max<int64_t>(0, _current_day);
    uint64_t hash = 1469598103934665603ULL;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(_families.stable_id[family_index]));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(identity_day));
    hash = trace_hash_mix(hash, static_cast<uint32_t>(index));
    int64_t stable_id = static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
    for (uint64_t probe = 1;
         _person_stable_ids.count(stable_id) != 0; ++probe) {
        stable_id = static_cast<int64_t>((trace_hash_mix(hash, probe) &
            0x7fffffffffffffffULL) | 1ULL);
    }
    int64_t weight_sum = 0;
    for (int32_t weight : _person_given_name_weights) weight_sum += weight;
    int64_t roll = static_cast<int64_t>(trace_hash_mix(hash, 0x474956454eULL) %
        static_cast<uint64_t>(std::max<int64_t>(1, weight_sum)));
    int32_t given = 0;
    for (; given + 1 < static_cast<int32_t>(_person_given_name_weights.size());
         ++given) {
        if (roll < _person_given_name_weights[given]) break;
        roll -= _person_given_name_weights[given];
    }
    uint32_t disambiguator = 0;
    const FamilyMembershipEdge &edge = _family_memberships[best_edge];
    int64_t existing_claim = 0;
    // Both aggregates only look at the promoting family, so walk the
    // person-family CSR plus anything promoted since its last rebuild instead
    // of the whole person table.
    if (_person_candidate_stamp.size() < _persons.active.size())
        _person_candidate_stamp.resize(_persons.active.size(), 0);
    if (++_person_candidate_generation == 0) {
        std::fill(_person_candidate_stamp.begin(),
                  _person_candidate_stamp.end(), 0);
        _person_candidate_generation = 1;
    }
    const auto accumulate_sibling = [&](int32_t i) {
        if (i == index || i < 0 ||
            i >= static_cast<int32_t>(_persons.active.size())) return;
        if (_persons.active[i] == 0 ||
            _persons.family_handle[i] != family_handle) return;
        if (_person_candidate_stamp[static_cast<size_t>(i)] ==
            _person_candidate_generation) return;
        _person_candidate_stamp[static_cast<size_t>(i)] =
            _person_candidate_generation;
        if (_persons.given_name_id[i] == given)
            disambiguator = std::max(disambiguator,
                _persons.name_disambiguator[i] + 1U);
        if (_persons.cohort_handle[i] == edge.cohort_handle)
            existing_claim += std::max<int64_t>(0, _persons.cash_claim[i]);
    };
    const int32_t indexed_families =
        static_cast<int32_t>(_person_family_offsets.size()) - 1;
    if (family_index < indexed_families) {
        const int32_t begin = _person_family_offsets[family_index];
        const int32_t end = _person_family_offsets[family_index + 1];
        _scan_steps_person_linear += end - begin;
        note_scan_steps(end - begin);
        for (int32_t p = begin; p < end; ++p)
            accumulate_sibling(_person_family_indices[p]);
    }
    const auto promoted = _person_family_migrations.find(family_handle);
    if (promoted != _person_family_migrations.end()) {
        _scan_steps_person_linear +=
            static_cast<int64_t>(promoted->second.size());
        note_scan_steps(static_cast<int64_t>(promoted->second.size()));
        for (const int32_t sibling : promoted->second)
            accumulate_sibling(sibling);
    }
    const int64_t one_share = edge.people > 0
        ? edge.cash_claim / edge.people : 0;
    _persons.stable_id[index] = stable_id;
    _person_stable_ids.insert(stable_id);
    _persons.family_handle[index] = family_handle;
    _person_family_migrations[family_handle].push_back(index);
    _persons.cohort_handle[index] = edge.cohort_handle;
    _person_cohort_migrations[edge.cohort_handle].push_back(index);
    _persons.given_name_id[index] = given;
    _persons.name_disambiguator[index] = disambiguator;
    _persons.notable_since_day[index] = identity_day;
    _persons.flags[index] = existing == 0 ? 1U : 0U;
    _persons.cash_claim[index] = std::min(one_share,
        std::max<int64_t>(0, edge.cash_claim - existing_claim));
    _persons.needs_satisfaction[index] = _population.needs_satisfaction[slot];
    _persons.worst_need_id[index] = _population.worst_need_id[slot];
    ++_persons_promoted;
    register_person_effect(index);
    _person_indices_dirty = true;
    (void)handle;
}

void NativeEconomyRuntime::review_person_promotions() {
    if (_person_runtime_mode != 2) return;
    for (int32_t family = 0; family < static_cast<int32_t>(
            _families.active.size()); ++family) {
        if (_families.active[family] == 0) continue;
        const int32_t count = _person_family_offsets.size() ==
                _families.active.size() + 1
            ? _person_family_offsets[family + 1] - _person_family_offsets[family] : 0;
        const int64_t phase = (_families.stable_id[family] % _family_review_days +
            _family_review_days) % _family_review_days;
        const bool due = ((_current_day % _family_review_days +
            _family_review_days) % _family_review_days) == phase;
        if (count == 0 || due) promote_person_for_family(family);
    }
}

void NativeEconomyRuntime::bind_notable_person_jobs() {
    _person_previous_building_handle = _persons.building_handle;
    _person_previous_job_kind = _persons.job_kind;
    _person_previous_employee_role_index = _persons.employee_role_index;
    for (int32_t i = 0; i < static_cast<int32_t>(_persons.active.size()); ++i) {
        if (_persons.active[i] == 0) continue;
        _persons.building_handle[i] = 0; _persons.job_kind[i] = 0;
        _persons.employee_role_index[i] = -1;
    }
    if (_person_family_offsets.size() != _families.active.size() + 1)
        rebuild_person_indices();
    // Owners: family ownership and exact owner-signature membership are hard
    // constraints. Capacity counters avoid materializing individual job slots.
    for (int32_t family = 0; family < static_cast<int32_t>(
            _families.active.size()); ++family) {
        if (_families.active[family] == 0) continue;
        for (int32_t op = _family_owned_offsets[family];
             op < _family_owned_offsets[family + 1]; ++op) {
            const FamilyBuildingOwnership &ownership = _family_ownerships[
                _family_owned_edge_indices[op]];
            const int32_t building = building_index_for_handle(
                ownership.building_handle);
            if (building < 0) continue;
            const BuildingGroup &group = _buildings[building];
            const int32_t owner_slot = find_cohort_slot(
                group.cell, group.owner_signature_id);
            if (owner_slot < 0) continue;
            int64_t remaining = std::max<int64_t>(0, ownership.filled_owner);
            for (int32_t pp = _person_family_offsets[family];
                 pp < _person_family_offsets[family + 1] && remaining > 0; ++pp) {
                const int32_t person = _person_family_indices[pp];
                if (_persons.job_kind[person] != 0 ||
                    _persons.cohort_handle[person] !=
                        _population.handle_for_slot(owner_slot)) continue;
                _persons.building_handle[person] = ownership.building_handle;
                _persons.job_kind[person] = 1;
                if (_person_previous_job_kind[person] != 1 ||
                    _person_previous_building_handle[person] !=
                        ownership.building_handle)
                    _persons.job_since_day[person] = std::max<int64_t>(0,
                        _current_day);
                const int64_t net = group.last_revenue - group.last_input_cost -
                    group.last_wages_paid;
                _persons.epoch_business_result[person] = ownership.filled_owner > 0
                    ? net / ownership.filled_owner : 0;
                --remaining; ++_person_jobs_bound;
            }
        }
    }
    // Employees: assign only within the exact cohort profession and committed
    // role fill. Existing aggregate role fill remains untouched.
    std::vector<int64_t> role_used(_building_employee_filled.size(), 0);
    for (int32_t i = 0; i < static_cast<int32_t>(_persons.active.size()); ++i) {
        if (_persons.active[i] == 0 || _persons.job_kind[i] != 0) continue;
        int32_t slot = -1;
        if (!_population.valid_handle(_persons.cohort_handle[i], slot)) continue;
        const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
        const int32_t signature = static_cast<int32_t>(_population.signature_id[slot]);
        if (signature < 0 || signature >= static_cast<int32_t>(_signatures.size()))
            continue;
        const int32_t profession = _signatures[signature].profession_id;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1] && _persons.job_kind[i] == 0; ++g) {
            const BuildingGroup &group = _buildings[g];
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t r = 0; r < type.employee_count; ++r) {
                const int32_t role_lane = group.employee_fill_begin + r;
                const JobRole &role = _building_employee_roles[type.employee_begin + r];
                if (role.profession_id != profession || role_lane < 0 ||
                    role_lane >= static_cast<int32_t>(_building_employee_filled.size()) ||
                    role_used[role_lane] >= _building_employee_filled[role_lane]) continue;
                _persons.building_handle[i] = group.modifier_handle;
                _persons.job_kind[i] = 2;
                _persons.employee_role_index[i] = r;
                if (_person_previous_job_kind[i] != 2 ||
                    _person_previous_building_handle[i] != group.modifier_handle ||
                    _person_previous_employee_role_index[i] != r)
                    _persons.job_since_day[i] = std::max<int64_t>(0,
                        _current_day);
                _persons.epoch_job_income[i] = _building_employee_filled[role_lane] > 0
                    ? (_building_role_base_wage_paid[role_lane] +
                       _building_role_bonus_paid[role_lane]) /
                        _building_employee_filled[role_lane] : 0;
                ++role_used[role_lane]; ++_person_jobs_bound;
                break;
            }
        }
    }
    for (int32_t i = 0; i < static_cast<int32_t>(_persons.active.size()); ++i)
        if (_persons.active[i] != 0 && _persons.job_kind[i] == 0)
            _persons.job_since_day[i] = -1;
}

void NativeEconomyRuntime::reconcile_person_claims() {
    if (_person_family_offsets.size() != _families.active.size() + 1)
        rebuild_person_indices();
    for (const FamilyMembershipEdge &membership : _family_memberships) {
        int32_t slot = -1;
        if (!_population.valid_handle(membership.cohort_handle, slot)) continue;
        std::vector<int32_t> members;
        int64_t raw_total = 0;
        for (int32_t p = _person_cohort_offsets[slot];
             p < _person_cohort_offsets[slot + 1]; ++p) {
            const int32_t person = _person_cohort_indices[p];
            if (_persons.family_handle[person] != membership.family_handle) continue;
            members.push_back(person);
            const int64_t opening = person < static_cast<int32_t>(
                    _person_opening_cash_claim.size())
                ? _person_opening_cash_claim[person] : _persons.cash_claim[person];
            const int64_t raw = std::max<int64_t>(0, opening +
                _persons.epoch_job_income[person] +
                _persons.epoch_business_result[person] -
                _persons.epoch_consumption_expense[person]);
            _persons.cash_claim[person] = raw;
            raw_total = saturating_add(raw_total, raw, _saturation_count);
        }
        if (raw_total > membership.cash_claim && raw_total > 0) {
            int64_t prefix = 0, distributed = 0;
            for (int32_t person : members) {
                prefix = saturating_add(prefix, _persons.cash_claim[person],
                                        _saturation_count);
                const int64_t next = mul_div_sat(membership.cash_claim, prefix,
                    raw_total, _saturation_count);
                _persons.cash_claim[person] = std::max<int64_t>(0,
                    next - distributed);
                distributed = next;
            }
        }
        for (int32_t person : members) {
            const int64_t daily_income = _epoch_days > 0
                ? _persons.epoch_job_income[person] / _epoch_days : 0;
            _persons.income_ema[person] = (_persons.income_ema[person] * 7 +
                daily_income) / 8;
        }
    }
}

void NativeEconomyRuntime::update_person_equity_shares() {
    std::fill(_persons.family_equity_share_q32.begin(),
              _persons.family_equity_share_q32.end(), 0);
    for (int32_t family = 0; family < static_cast<int32_t>(
            _families.active.size()); ++family) {
        if (_families.active[family] == 0) continue;
        int64_t total_filled = 0;
        for (int32_t p = _family_owned_offsets[family];
             p < _family_owned_offsets[family + 1]; ++p)
            total_filled += std::max<int64_t>(0,
                _family_ownerships[_family_owned_edge_indices[p]].filled_owner);
        if (total_filled <= 0) continue;
        for (int32_t p = _person_family_offsets[family];
             p < _person_family_offsets[family + 1]; ++p) {
            const int32_t person = _person_family_indices[p];
            if (_persons.job_kind[person] == 1)
                _persons.family_equity_share_q32[person] =
                    Q32_ONE / total_filled;
        }
    }
}

bool NativeEconomyRuntime::run_person_commit_slice(int64_t &work_done,
                                                    std::string &) {
    if (_person_commit_phase == 0) {
        _person_retire_call_ms = 0.0;
        _person_retire_calls = 0;
        _person_commit_retire_ms = 0.0;
        _person_commit_index_ms = 0.0;
        _person_commit_bind_jobs_ms = 0.0;
        _person_commit_claims_ms = 0.0;
        _person_commit_equity_ms = 0.0;
        _person_commit_promote_ms = 0.0;
        _rebuild_person_needs_ms = 0.0;
        _rebuild_person_count_ms = 0.0;
        _rebuild_person_fill_ms = 0.0;
        _rebuild_person_sort_ms = 0.0;
        _rebuild_person_needoffsets_ms = 0.0;
        if (_person_runtime_mode == 0 && _persons.active_count == 0) {
            _stage = Stage::AGGREGATE_PUBLISH; ++work_done; return true;
        }
        _person_needs.swap(_person_epoch_needs);
        _person_epoch_needs.clear();
        _person_needs_normalized = false;
        _person_commit_cursor = 0;
        _person_commit_phase = 1;
        ++work_done;
        return true;
    }
    if (_person_commit_phase == 1) {
        // Family dissolution and invalid structural references retire the
        // overlay only; they never remove aggregate population.
        const auto retire_started = Clock::now();
        const int32_t begin = _person_commit_cursor;
        const int32_t end = std::min<int32_t>(_persons.active.size(),
            begin + _person_records_per_slice);
        for (; _person_commit_cursor < end; ++_person_commit_cursor) {
            const int32_t i = _person_commit_cursor;
            if (_persons.active[i] == 0) continue;
            register_person_effect(i);
            int32_t family = -1, slot = -1;
            if (!_families.valid_handle(_persons.family_handle[i], family) ||
                !_population.valid_handle(_persons.cohort_handle[i], slot) ||
                family_membership_index(_persons.family_handle[i],
                    _persons.cohort_handle[i]) < 0) retire_person(i);
        }
        work_done += end - begin;
        _person_commit_retire_ms += elapsed_ms(retire_started);
        if (_person_commit_cursor < static_cast<int32_t>(_persons.active.size()))
            return true;
        const auto index_started = Clock::now();
        rebuild_person_indices();
        _person_commit_index_ms += elapsed_ms(index_started);
        const auto bind_started = Clock::now();
        bind_notable_person_jobs();
        _person_commit_bind_jobs_ms += elapsed_ms(bind_started);
        _person_commit_cursor = 0;
        _person_commit_phase = 2;
        ++work_done;
        return true;
    }
    if (_person_commit_phase == 2) {
        const auto claims_started = Clock::now();
        reconcile_person_claims();
        _person_commit_claims_ms += elapsed_ms(claims_started);
        const auto equity_started = Clock::now();
        update_person_equity_shares();
        _person_commit_equity_ms += elapsed_ms(equity_started);
        _person_commit_cursor = 0;
        _person_commit_phase = 3;
        ++work_done;
        return true;
    }
    if (_person_commit_phase == 3) {
        const auto promote_started = Clock::now();
        const int32_t begin = _person_commit_cursor;
        const int32_t end = std::min<int32_t>(_families.active.size(),
            begin + _person_records_per_slice);
        if (_person_runtime_mode == 2) {
            for (; _person_commit_cursor < end; ++_person_commit_cursor) {
                const int32_t family = _person_commit_cursor;
                if (_families.active[family] == 0) continue;
                const int32_t count = _person_family_offsets.size() ==
                        _families.active.size() + 1
                    ? _person_family_offsets[family + 1] -
                        _person_family_offsets[family] : 0;
                const int64_t phase = (_families.stable_id[family] %
                    _family_review_days + _family_review_days) %
                    _family_review_days;
                const bool due = ((_current_day % _family_review_days +
                    _family_review_days) % _family_review_days) == phase;
                if (count == 0 || due) promote_person_for_family(family);
            }
        } else {
            _person_commit_cursor = end;
        }
        work_done += end - begin;
        _person_commit_promote_ms += elapsed_ms(promote_started);
        if (_person_commit_cursor < static_cast<int32_t>(_families.active.size()))
            return true;
        _person_commit_phase = 4;
        return true;
    }
    const auto final_index_started = Clock::now();
    // Phase 3 only dirties the indices when it actually promoted someone, so
    // most epochs can keep the CSR that phase 1 already built.
    if (_person_indices_dirty || _person_needs_orphaned) rebuild_person_indices();
    _person_commit_index_ms += elapsed_ms(final_index_started);
    _person_need_edges_processed += static_cast<int64_t>(_person_needs.size());
    _person_commit_phase = 0; _person_commit_cursor = 0;
    _stage = Stage::AGGREGATE_PUBLISH; ++work_done;
    return true;
}

uint64_t NativeEconomyRuntime::sponsor_family_for_cohort(
        uint64_t cohort_handle, int32_t cell) const {
    uint64_t best = 0;
    int64_t best_claim = -1;
    int32_t slot = -1;
    if (!_population.valid_handle(cohort_handle, slot) ||
        _population.page_cell[slot / COHORT_PAGE_SIZE] != cell ||
        _family_cohort_offsets.size() != _population.active.size() + 1)
        return 0;
    for (int32_t p = _family_cohort_offsets[slot];
         p < _family_cohort_offsets[slot + 1]; ++p) {
        const FamilyMembershipEdge &edge = _family_memberships[
            _family_cohort_edge_indices[p]];
        if (edge.cash_claim < best_claim) continue;
        if (edge.cash_claim > best_claim || edge.family_handle < best) {
            best = edge.family_handle;
            best_claim = edge.cash_claim;
        }
    }
    return best;
}

void NativeEconomyRuntime::move_family_membership(
        uint64_t source_handle, uint64_t destination_handle,
        int64_t source_population_before, int64_t moved_population,
        int64_t source_funds_before, int64_t moved_funds,
        uint64_t preferred_family_handle) {
    if (source_handle == 0 || destination_handle == 0 ||
        source_population_before <= 0 || moved_population <= 0) return;
    const size_t original_size = _family_memberships.size();
    int64_t remaining_people_to_move = moved_population;
    int64_t remaining_funds_to_move = std::max<int64_t>(0, moved_funds);
    auto move_edge = [&](FamilyMembershipEdge &source, bool preferred) {
        if (remaining_people_to_move <= 0 || source.cohort_handle != source_handle ||
            source.people <= 0 || (preferred && source.family_handle !=
            preferred_family_handle) || (!preferred && preferred_family_handle != 0 &&
            source.family_handle == preferred_family_handle)) return;
        const int64_t moved_people = std::min(source.people,
            remaining_people_to_move);
        const int64_t moved_claim = preferred_family_handle != 0
            ? std::min(source.cash_claim, remaining_funds_to_move)
            : std::min(source.cash_claim, remaining_funds_to_move);
        if (moved_people <= 0) return;
        move_notable_people(source_handle, destination_handle,
            source.family_handle, source.people, moved_people);
        FamilyMembershipEdge moved = source;
        moved.cohort_handle = destination_handle;
        moved.people = moved_people;
        moved.cash_claim = std::min(source.cash_claim,
                                    std::max<int64_t>(0, moved_claim));
        source.people -= moved.people;
        source.cash_claim -= moved.cash_claim;
        source.population_basis = std::max<int64_t>(0,
            source.population_basis - moved_people);
        source.funds_basis = std::max<int64_t>(0,
            source.funds_basis - moved_claim);
        int32_t destination_slot = -1;
        if (_population.valid_handle(destination_handle, destination_slot)) {
            moved.population_basis = _population.population[destination_slot];
            moved.funds_basis = _population.funds[destination_slot];
        }
        _family_memberships.push_back(moved);
        remaining_people_to_move = std::max<int64_t>(0,
            remaining_people_to_move - moved_people);
        remaining_funds_to_move = std::max<int64_t>(0,
            remaining_funds_to_move - moved_claim);
    };
    // Prefer the family with the matching career preference, then distribute
    // any remainder proportionally across other local family edges. This keeps
    // the migration preference from breaking membership/cash conservation when
    // a preferred branch is smaller than the requested job move.
    if (preferred_family_handle != 0) {
        for (size_t i = 0; i < original_size && remaining_people_to_move > 0; ++i)
            move_edge(_family_memberships[i], true);
    }
    for (size_t i = 0; i < original_size && remaining_people_to_move > 0; ++i)
        move_edge(_family_memberships[i], false);
    _family_indices_dirty = true;
}

void NativeEconomyRuntime::move_notable_people(
        uint64_t source_cohort_handle, uint64_t destination_cohort_handle,
        uint64_t family_handle, int64_t family_people_before,
        int64_t moved_family_people) {
    if (_person_runtime_mode != 2 || moved_family_people <= 0 ||
        family_people_before <= 0) return;
    const size_t person_slots = _persons.active.size();
    if (_person_candidate_stamp.size() < person_slots)
        _person_candidate_stamp.resize(person_slots, 0);
    if (++_person_candidate_generation == 0) {
        std::fill(_person_candidate_stamp.begin(),
                  _person_candidate_stamp.end(), 0);
        _person_candidate_generation = 1;
    }
    std::vector<int32_t> candidates;
    const auto consider = [&](int32_t i) {
        if (i < 0 || i >= static_cast<int32_t>(person_slots)) return;
        if (_persons.active[i] == 0 ||
            _persons.cohort_handle[i] != source_cohort_handle ||
            _persons.family_handle[i] != family_handle) return;
        if (_person_candidate_stamp[static_cast<size_t>(i)] ==
            _person_candidate_generation) return;
        _person_candidate_stamp[static_cast<size_t>(i)] =
            _person_candidate_generation;
        candidates.push_back(i);
    };
    int32_t source_slot = -1;
    // The population store keeps allocating slots mid-epoch, so the CSR is
    // routinely shorter than the slot table. A slot past its end simply has no
    // indexed persons; anything that reached the cohort since the last rebuild
    // is in the migration map either way.
    if (_population.valid_handle(source_cohort_handle, source_slot)) {
        const int32_t indexed_slots =
            static_cast<int32_t>(_person_cohort_offsets.size()) - 1;
        if (source_slot < indexed_slots) {
            const int32_t begin = _person_cohort_offsets[source_slot];
            const int32_t end = _person_cohort_offsets[source_slot + 1];
            _scan_steps_person_linear += end - begin;
            note_scan_steps(end - begin);
            for (int32_t p = begin; p < end; ++p)
                consider(_person_cohort_indices[p]);
        }
        const auto migrated = _person_cohort_migrations.find(source_cohort_handle);
        if (migrated != _person_cohort_migrations.end()) {
            _scan_steps_person_linear +=
                static_cast<int64_t>(migrated->second.size());
            note_scan_steps(static_cast<int64_t>(migrated->second.size()));
            for (const int32_t person : migrated->second) consider(person);
        }
    } else {
        _scan_steps_person_linear += static_cast<int64_t>(person_slots);
        note_scan_steps(static_cast<int64_t>(person_slots));
        for (int32_t i = 0; i < static_cast<int32_t>(person_slots); ++i)
            consider(i);
    }
    std::sort(candidates.begin(), candidates.end(), [&](int32_t a, int32_t b) {
        return std::tie(_persons.stable_id[a], a) <
            std::tie(_persons.stable_id[b], b);
    });
    int64_t remaining_people = family_people_before;
    int64_t remaining_moved = std::min(moved_family_people, family_people_before);
    for (int32_t person : candidates) {
        if (remaining_people <= 0 || remaining_moved <= 0) break;
        uint64_t hash = 1469598103934665603ULL;
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_epoch_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_persons.stable_id[person]));
        hash = trace_hash_mix(hash, destination_cohort_handle);
        if (static_cast<int64_t>(hash % static_cast<uint64_t>(remaining_people)) <
                remaining_moved) {
            _persons.cohort_handle[person] = destination_cohort_handle;
            _person_cohort_migrations[destination_cohort_handle].push_back(person);
            _persons.building_handle[person] = 0;
            _persons.job_kind[person] = 0;
            _persons.employee_role_index[person] = -1;
            --remaining_moved; ++_persons_migrated;
        }
        --remaining_people;
    }
    _person_indices_dirty = true;
}

void NativeEconomyRuntime::record_person_demography(
        int32_t cohort_slot, int64_t population_before, int64_t deaths) {
    if (_person_runtime_mode != 2 || deaths <= 0 || population_before <= 0 ||
        cohort_slot < 0 || cohort_slot >= static_cast<int32_t>(
            _population.active.size()) ||
        _person_cohort_offsets.size() != _population.active.size() + 1) return;
    std::vector<int32_t> candidates;
    for (int32_t p = _person_cohort_offsets[cohort_slot];
         p < _person_cohort_offsets[cohort_slot + 1]; ++p) {
        const int32_t person = _person_cohort_indices[p];
        if (_persons.active[person] != 0) candidates.push_back(person);
    }
    std::sort(candidates.begin(), candidates.end(), [&](int32_t a, int32_t b) {
        return std::tie(_persons.stable_id[a], a) <
            std::tie(_persons.stable_id[b], b);
    });
    int64_t remaining_population = population_before;
    int64_t remaining_deaths = std::min(deaths, population_before);
    for (int32_t person : candidates) {
        if (remaining_population <= 0 || remaining_deaths <= 0) break;
        uint64_t hash = 1469598103934665603ULL;
        hash = trace_hash_mix(hash, 0x504445415448ULL); // "PDEATH"
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_seed));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_epoch_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(_persons.stable_id[person]));
        if (static_cast<int64_t>(hash % static_cast<uint64_t>(remaining_population)) <
                remaining_deaths) {
            retire_person(person);
            --remaining_deaths; ++_persons_died;
        }
        --remaining_population;
    }
}

const char *NativeEconomyRuntime::stage_name() const {
    return stage_name(_stage);
}

const char *NativeEconomyRuntime::stage_name(Stage stage) const {
    switch (stage) {
        case Stage::IDLE: return "idle";
        case Stage::EPOCH_BEGIN: return "epoch_begin";
        case Stage::LEDGER_APPLY: return "ledger_apply";
        case Stage::HOUSEHOLD_MARKET: return "household_market";
        case Stage::STRUCTURAL_COMMIT: return "structural_commit";
        case Stage::WAIT_COMMIT: return "wait_commit";
        case Stage::BUILDING_EMPLOYMENT: return "building_employment";
        case Stage::BUILDING_PRODUCTION: return "building_production";
        case Stage::BUILDING_COMMIT: return "building_commit";
        case Stage::AGGREGATE_PUBLISH: return "aggregate_publish";
        case Stage::FATAL: return "fatal";
        case Stage::TRADE_SETTLE: return "trade_settle";
        case Stage::TRADE_DISPATCH: return "trade_dispatch";
        case Stage::TRADE_PLANNING: return "trade_planning";
        case Stage::BUILDING_PLAN: return "building_plan";
        case Stage::GOVERNMENT_RESEARCH_PROCUREMENT:
            return "government_research_procurement";
        case Stage::FAMILY_COMMIT: return "family_commit";
        case Stage::PERSON_COMMIT: return "person_commit";
    }
    return "unknown";
}

const char *NativeEconomyRuntime::publish_phase_name(PublishPhase phase) const {
    switch (phase) {
        case PublishPhase::PREPARE: return "prepare";
        case PublishPhase::AUDIT_POPULATION: return "audit_population";
        case PublishPhase::AUDIT_MARKET: return "audit_market";
        case PublishPhase::AUDIT_TRANSIT: return "audit_transit";
        case PublishPhase::AUDIT_ESCROW: return "audit_escrow";
        case PublishPhase::AUDIT_COUNTRY: return "audit_country";
        case PublishPhase::VERIFY: return "verify";
        case PublishPhase::WATERMARK: return "watermark";
        case PublishPhase::TRADE_FLOW: return "trade_flow";
        case PublishPhase::TRADE_DIAGNOSTICS: return "trade_diagnostics";
        case PublishPhase::TRADE_INIT: return "trade_init";
        case PublishPhase::COMMIT: return "commit";
        case PublishPhase::DONE: return "done";
        case PublishPhase::COUNT: break;
    }
    return "unknown";
}

const char *NativeEconomyRuntime::trade_plan_init_phase_name(
        TradePlanInitPhase phase) const {
    switch (phase) {
        case TradePlanInitPhase::IDLE: return "idle";
        case TradePlanInitPhase::COMPONENT_PREPARE: return "component_prepare";
        case TradePlanInitPhase::COMPONENT_CLEAR: return "component_clear";
        case TradePlanInitPhase::COMPONENT_BUILD: return "component_build";
        case TradePlanInitPhase::PREPARE: return "prepare";
        case TradePlanInitPhase::INFLIGHT_BUILD: return "inflight_build";
        case TradePlanInitPhase::INFLIGHT_SORT: return "inflight_sort";
        case TradePlanInitPhase::PRUNE: return "prune";
        case TradePlanInitPhase::INBOUND_BUILD: return "inbound_build";
        case TradePlanInitPhase::ROTATE: return "rotate";
        case TradePlanInitPhase::WORKSPACE_CLEAR: return "workspace_clear";
        case TradePlanInitPhase::FINALIZE: return "finalize";
        case TradePlanInitPhase::DONE: return "done";
    }
    return "unknown";
}


Dictionary NativeEconomyRuntime::fixed_math_probe(const Dictionary &vectors) const {
    Dictionary out;
    const std::vector<int64_t> a = packed_i64(vectors, "a");
    const std::vector<int64_t> b = packed_i64(vectors, "b");
    const std::vector<int64_t> divisors = packed_i64(vectors, "divisors");
    if (a.size() != b.size() || a.size() != divisors.size()) {
        out["ok"] = false;
        out["reason"] = "fixed_math_vector_size_mismatch";
        return out;
    }
    PackedInt64Array results;
    results.resize(static_cast<int64_t>(a.size()));
    int64_t saturation_count = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        results.set(static_cast<int64_t>(i), mul_div_sat(a[i], b[i], divisors[i],
                                                        saturation_count));
    }
    out["ok"] = true;
    out["results"] = results;
    out["saturation_count"] = saturation_count;
    return out;
}

Dictionary NativeEconomyRuntime::production_climate_math_probe(
        const Dictionary &vectors) const {
    Dictionary out;
    const std::vector<int32_t> temperature = packed_i32(vectors, "temperature_q16");
    const std::vector<int32_t> temperature_opt = packed_i32(
        vectors, "temperature_opt_q16");
    const std::vector<int32_t> temperature_tolerance = packed_i32(
        vectors, "temperature_tolerance_q16");
    const std::vector<int32_t> water = packed_i32(vectors, "water_q16");
    const std::vector<int32_t> water_opt = packed_i32(vectors, "water_opt_q16");
    const std::vector<int32_t> water_tolerance = packed_i32(
        vectors, "water_tolerance_q16");
    const std::vector<int32_t> exposure = packed_i32(vectors, "exposure_q16");
    const std::vector<int32_t> floor = packed_i32(vectors, "floor_q16");
    const std::vector<int32_t> enabled = packed_i32(vectors, "enabled");
    const size_t count = temperature.size();
    if (temperature_opt.size() != count || temperature_tolerance.size() != count ||
        water.size() != count || water_opt.size() != count ||
        water_tolerance.size() != count || exposure.size() != count ||
        floor.size() != count || (!enabled.empty() && enabled.size() != count)) {
        out["ok"] = false;
        out["reason"] = "production_climate_math_vector_size_mismatch";
        return out;
    }
    PackedInt64Array temperature_fit;
    PackedInt64Array water_fit;
    PackedInt64Array capacity;
    temperature_fit.resize(static_cast<int64_t>(count));
    water_fit.resize(static_cast<int64_t>(count));
    capacity.resize(static_cast<int64_t>(count));
    int64_t saturation_count = 0;
    for (size_t i = 0; i < count; ++i) {
        if (temperature[i] < 0 || temperature[i] > Q16_ONE ||
            temperature_opt[i] < 0 || temperature_opt[i] > Q16_ONE ||
            temperature_tolerance[i] <= 0 || temperature_tolerance[i] > Q16_ONE ||
            water[i] < 0 || water[i] > Q16_ONE ||
            water_opt[i] < 0 || water_opt[i] > Q16_ONE ||
            water_tolerance[i] <= 0 || water_tolerance[i] > Q16_ONE ||
            exposure[i] < 0 || exposure[i] > Q16_ONE ||
            floor[i] < 0 || floor[i] > Q16_ONE) {
            out["ok"] = false;
            out["reason"] = "production_climate_math_vector_invalid";
            return out;
        }
        if (!enabled.empty() && enabled[i] == 0) {
            temperature_fit.set(static_cast<int64_t>(i), Q16_ONE);
            water_fit.set(static_cast<int64_t>(i), Q16_ONE);
            capacity.set(static_cast<int64_t>(i), Q16_ONE);
            continue;
        }
        const int64_t temp_delta = std::llabs(
            static_cast<int64_t>(temperature[i]) - temperature_opt[i]);
        const int64_t water_delta = std::llabs(
            static_cast<int64_t>(water[i]) - water_opt[i]);
        const int64_t temp_fit = std::clamp<int64_t>(Q16_ONE - mul_div_sat(
            temp_delta, Q16_ONE, temperature_tolerance[i], saturation_count),
            0, Q16_ONE);
        const int64_t moist_fit = std::clamp<int64_t>(Q16_ONE - mul_div_sat(
            water_delta, Q16_ONE, water_tolerance[i], saturation_count),
            0, Q16_ONE);
        const int64_t raw = std::min(temp_fit, moist_fit);
        const int64_t bounded = std::max<int64_t>(floor[i], raw);
        const int64_t climate_capacity = std::clamp<int64_t>(
            Q16_ONE - mul_div_sat(exposure[i], Q16_ONE - bounded,
                Q16_ONE, saturation_count), 0, Q16_ONE);
        temperature_fit.set(static_cast<int64_t>(i), temp_fit);
        water_fit.set(static_cast<int64_t>(i), moist_fit);
        capacity.set(static_cast<int64_t>(i), climate_capacity);
    }
    out["ok"] = true;
    out["temperature_fit_q16"] = temperature_fit;
    out["water_fit_q16"] = water_fit;
    out["capacity_q16"] = capacity;
    out["saturation_count"] = saturation_count;
    return out;
}

int64_t NativeEconomyRuntime::state_hash() const {
    uint64_t hash = 1469598103934665603ULL;
    auto mix_u64 = [&](uint64_t value) {
        for (int i = 0; i < 8; ++i) {
            hash ^= static_cast<uint8_t>((value >> (i * 8)) & 0xffULL);
            hash *= 1099511628211ULL;
        }
    };
    auto mix_string = [&](const std::string &value) {
        mix_u64(value.size());
        for (unsigned char byte : value) {
            hash ^= byte;
            hash *= 1099511628211ULL;
        }
    };
    mix_u64(static_cast<uint64_t>(_trade_runtime_mode != 2 &&
        _catalog_compat_hash_v10 != 0 ? _catalog_compat_hash_v10 : _catalog_hash));
    mix_u64(static_cast<uint64_t>(_building_catalog_hash));
    mix_u64(static_cast<uint64_t>(_prosperity_profile_hash));
    mix_u64(static_cast<uint64_t>(_cell_count));
    mix_u64(static_cast<uint64_t>(_epoch_id));
    mix_u64(static_cast<uint64_t>(_epoch_days));
    mix_u64(static_cast<uint64_t>(_last_committed_day));
    mix_u64(static_cast<uint64_t>(_environment_day));
    mix_u64(static_cast<uint64_t>(_environment_hash));
    mix_u64(static_cast<uint64_t>(_country_runtime == nullptr ? 0 : _country_runtime->state_hash()));
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        mix_u64(static_cast<uint64_t>(_cell_last_settlement_day[cell]));
        mix_u64(_cell_settlement_generation[cell]);
        mix_u64(_cell_price_stock_gen[cell]);
        mix_u64(_cell_owner_cash_gen[cell]);
        mix_u64(_cell_population_gen[cell]);
        mix_u64(_cell_building_structure_gen[cell]);
        mix_u64(_cell_technology_gen[cell]);
        mix_u64(_cell_resource_gen[cell]);
        mix_u64(_cell_trade_gen[cell]);
        mix_u64(_settlements.tier[cell]);
        mix_u64(_settlements.prosperity_generation[cell]);
        mix_u64(_settlements.name_roll_generation[cell]);
        mix_u64(static_cast<uint64_t>(_settlements.name_active[cell]));
        mix_u64(static_cast<uint64_t>(_settlements.name_forced[cell]));
        if (_settlements.name_active[cell] != 0) {
            mix_string(_settlement_name_pack_id);
            if (_settlements.root[cell] < 0) {
                mix_string(_settlement_full_name_ids[
                    _settlements.prefix[cell]]);
            } else {
                mix_string(_settlement_prefix_ids[_settlements.prefix[cell]]);
                mix_string(_settlement_root_ids[_settlements.root[cell]]);
                mix_string(_settlement_suffix_ids[_settlements.suffix[cell]]);
            }
        }
        mix_u64(_settlements.disambiguator[cell]);
        mix_u64(cell < static_cast<int32_t>(
            _fiscal_previous_country_handles.size())
            ? _fiscal_previous_country_handles[cell] : 0);
        for (int32_t kind = 0; kind < ACTIVE_TAX_KIND_COUNT; ++kind) {
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + kind;
            mix_u64(static_cast<uint64_t>(
                lane < _fiscal_previous_requests.size()
                    ? _fiscal_previous_requests[lane] : 0));
        }
    }
    const size_t fiscal_hash_lanes = _epoch_country_handles.size() *
        NativeCountryRuntime::TAX_KIND_COUNT;
    const auto mix_fiscal_lanes = [&](const std::vector<int64_t> &values) {
        for (size_t lane = 0; lane < fiscal_hash_lanes; ++lane) {
            mix_u64(static_cast<uint64_t>(
                lane < values.size() ? values[lane] : 0));
        }
    };
    // PKEC persists one fixed tax-kind group per frozen country and fills
    // never-committed cumulative lanes with zero. Hash that same logical
    // shape so a cold bootstrap and its restore remain equivalent.
    mix_fiscal_lanes(_fiscal_cumulative_bases);
    mix_fiscal_lanes(_fiscal_cumulative_collected);
    mix_fiscal_lanes(_fiscal_cumulative_requests);
    mix_fiscal_lanes(_fiscal_cumulative_paid);
    for (size_t slot = 0; slot < _population.active.size(); ++slot) {
        if (_population.active[slot] == 0) continue;
        mix_u64(slot);
        mix_u64(_population.generation[slot]);
        mix_u64(_population.signature_id[slot]);
        mix_u64(static_cast<uint64_t>(_population.population[slot]));
        mix_u64(static_cast<uint64_t>(_population.funds[slot]));
        mix_u64(static_cast<uint64_t>(_population.epoch_income[slot]));
        mix_u64(static_cast<uint64_t>(_population.epoch_expense[slot]));
        mix_u64(static_cast<uint64_t>(_population.income_ema[slot]));
        mix_u64(_population.needs_satisfaction[slot]);
        mix_u64(_population.worst_need_id[slot]);
        mix_u64(_population.flags[slot]);
        mix_u64(static_cast<uint64_t>(_population.demography_residual[slot]));
        mix_u64(static_cast<uint64_t>(_population.owner_employed[slot]));
        mix_u64(static_cast<uint64_t>(_population.employee_employed[slot]));
        mix_u64(_population.composite_satisfaction[slot]);
        mix_u64(_population.worst_dimension_id[slot]);
        const size_t dims_base = static_cast<size_t>(slot) *
            static_cast<size_t>(SAT_DIM_COUNT);
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
            mix_u64(_population.satisfaction_dims[dims_base +
                                                  static_cast<size_t>(dim)]);
        mix_u64(static_cast<uint64_t>(_population.income_baseline_ema[slot]));
        mix_u64(static_cast<uint64_t>(_population.epoch_tax_paid[slot]));
        mix_u64(static_cast<uint64_t>(_population.epoch_subsidy_received[slot]));
    }
    mix_u64(0x534f4350524553ULL); // "SOCPRES"
    for (const uint8_t level : _cell_social_pressure_level) mix_u64(level);
    mix_u64(0x4249525448524553ULL); // "BIRTHRES"
    for (int64_t residual_q32 : _birth_residual_q32)
        mix_u64(static_cast<uint64_t>(residual_q32));
    for (int32_t i = 0; i < static_cast<int32_t>(_families.active.size()); ++i) {
        if (_families.active[i] == 0) continue;
        mix_u64(0x46414d494c59ULL);
        mix_u64(static_cast<uint32_t>(i));
        mix_u64(_families.generation[i]);
        mix_u64(static_cast<uint64_t>(_families.stable_id[i]));
        mix_u64(static_cast<uint32_t>(_families.surname_id[i]));
        mix_u64(_families.surname_disambiguator[i]);
        mix_u64(static_cast<uint64_t>(_families.founded_day[i]));
        mix_u64(static_cast<uint32_t>(_families.home_cell[i]));
        mix_u64(static_cast<uint32_t>(_families.origin_ethnicity[i]));
        mix_u64(_families.decline_reviews[i]);
        mix_u64(_families.flags[i]);
    }
    for (const FamilyMembershipEdge &edge : _family_memberships) {
        mix_u64(edge.family_handle); mix_u64(edge.cohort_handle);
        mix_u64(static_cast<uint64_t>(edge.people));
        mix_u64(static_cast<uint64_t>(edge.cash_claim));
        mix_u64(static_cast<uint64_t>(edge.population_basis));
        mix_u64(static_cast<uint64_t>(edge.funds_basis));
        mix_u64(static_cast<uint64_t>(edge.owner_employed));
        mix_u64(static_cast<uint64_t>(edge.employee_employed));
    }
    for (const FamilyBuildingOwnership &edge : _family_ownerships) {
        mix_u64(edge.family_handle); mix_u64(edge.building_handle);
        mix_u64(static_cast<uint64_t>(edge.owned_count));
        mix_u64(static_cast<uint64_t>(edge.filled_owner));
    }
    mix_u64(0x46414d5452414954ULL); // "FAMTRAIT"
    mix_u64(static_cast<uint32_t>(_family_trait_catalog_version));
    mix_u64(static_cast<uint64_t>(_family_trait_catalog_hash));
    for (const FamilyTraitRoll &roll : _family_traits) {
        mix_u64(roll.family_handle);
        mix_u64(static_cast<uint32_t>(roll.trait_id));
        mix_u64(static_cast<uint32_t>(roll.strength_q16));
        mix_u64(roll.core);
    }
    mix_u64(0x46414d4252414e43ULL); // "FAMBRANC"
    for (size_t i = 0; i < _family_influences.active.size(); ++i) {
        mix_u64(i);
        mix_u64(_family_influences.active[i]);
        mix_u64(_family_influences.generation[i]);
        mix_u64(_family_influences.family_handle[i]);
        mix_u64(static_cast<uint32_t>(_family_influences.cell[i]));
        mix_u64(static_cast<uint64_t>(_family_influences.stable_id[i]));
        mix_u64(static_cast<uint64_t>(_family_influences.population[i]));
        mix_u64(static_cast<uint64_t>(_family_influences.cash[i]));
        mix_u64(static_cast<uint64_t>(_family_influences.building_asset[i]));
        mix_u64(static_cast<uint32_t>(
            _family_influences.population_share_q16[i]));
        mix_u64(static_cast<uint32_t>(_family_influences.cash_share_q16[i]));
        mix_u64(static_cast<uint32_t>(
            _family_influences.building_share_q16[i]));
        mix_u64(static_cast<uint32_t>(_family_influences.score_q16[i]));
        mix_u64(static_cast<uint32_t>(_family_influences.satisfaction_q16[i]));
        mix_u64(_family_influences.prestige_level[i]);
        mix_u64(_family_influences.pending_target_level[i]);
        mix_u64(_family_influences.review_streak[i]);
        mix_u64(static_cast<uint64_t>(_family_influences.last_review_day[i]));
    }
    mix_u64(0x46414d434f4d4d44ULL); // "FAMCOMMD"
    for (const FamilyTraitCommand &command : _family_trait_commands) {
        mix_u64(static_cast<uint32_t>(command.operation));
        mix_u64(command.family_handle);
        mix_u64(static_cast<uint32_t>(command.trait_id));
        mix_u64(static_cast<uint32_t>(command.strength_q16));
        mix_u64(static_cast<uint64_t>(command.effective_day));
        mix_u64(static_cast<uint32_t>(command.priority));
        mix_u64(static_cast<uint64_t>(command.sequence));
        mix_u64(command.submit_order);
    }
    mix_u64(0x455850454449544eULL); // "EXPEDITN"
    for (size_t i = 0; i < _family_expeditions.active.size(); ++i) {
        mix_u64(i); mix_u64(_family_expeditions.active[i]);
        mix_u64(_family_expeditions.generation[i]);
        if (_family_expeditions.active[i] == 0) continue;
        mix_u64(static_cast<uint64_t>(_family_expeditions.stable_id[i]));
        mix_u64(_family_expeditions.country_handle[i]);
        mix_u64(_family_expeditions.family_handle[i]);
        mix_u64(static_cast<uint32_t>(_family_expeditions.source_cell[i]));
        mix_u64(static_cast<uint32_t>(_family_expeditions.target_cell[i]));
        mix_u64(static_cast<uint64_t>(_family_expeditions.departure_day[i]));
        mix_u64(static_cast<uint64_t>(_family_expeditions.due_day[i]));
        mix_u64(static_cast<uint32_t>(_family_expeditions.route_cost[i]));
        mix_u64(static_cast<uint32_t>(_family_expeditions.speed[i]));
        mix_u64(_family_expeditions.state[i]);
        mix_u64(static_cast<uint64_t>(_family_expeditions.population[i]));
        mix_u64(static_cast<uint64_t>(_family_expeditions.effect_transaction_id[i]));
        mix_u64(_family_expeditions.idempotency_key[i]);
        const uint32_t route_begin = _family_expeditions.route_begin[i];
        const uint32_t route_count = _family_expeditions.route_count[i];
        for (uint32_t r = 0; r < route_count; ++r) {
            mix_u64(static_cast<uint32_t>(_family_expedition_route_cells[route_begin + r]));
            mix_u64(static_cast<uint32_t>(_family_expedition_route_costs[route_begin + r]));
        }
        const uint32_t payload_begin = _family_expeditions.payload_begin[i];
        const uint32_t payload_count = _family_expeditions.payload_count[i];
        for (uint32_t p = 0; p < payload_count; ++p) {
            const FamilyExpeditionPayload &payload =
                _family_expedition_payloads[payload_begin + p];
            mix_u64(payload.source_cohort_handle);
            mix_u64(static_cast<uint32_t>(payload.signature));
            mix_u64(static_cast<uint64_t>(payload.people));
            mix_u64(static_cast<uint64_t>(payload.funds));
            mix_u64(static_cast<uint64_t>(payload.epoch_income));
            mix_u64(static_cast<uint64_t>(payload.epoch_expense));
            mix_u64(static_cast<uint64_t>(payload.epoch_in_kind_income));
            mix_u64(static_cast<uint64_t>(payload.income_ema));
            mix_u64(static_cast<uint64_t>(payload.epoch_tax_paid));
            mix_u64(static_cast<uint64_t>(payload.epoch_subsidy_received));
            mix_u64(static_cast<uint64_t>(payload.income_baseline_ema));
            mix_u64(static_cast<uint64_t>(payload.demography_residual));
            mix_u64(static_cast<uint64_t>(payload.cash_claim));
            mix_u64(static_cast<uint64_t>(payload.owner_employed));
            mix_u64(static_cast<uint64_t>(payload.employee_employed));
            mix_u64(payload.needs_satisfaction); mix_u64(payload.worst_need_id);
            mix_u64(payload.composite_satisfaction);
            for (uint16_t dimension : payload.satisfaction_dims) mix_u64(dimension);
            mix_u64(payload.worst_dimension_id);
            for (uint32_t person = 0; person < payload.person_count; ++person)
                mix_u64(_family_expedition_person_handles[payload.person_begin + person]);
        }
    }
    for (int32_t i = 0; i < static_cast<int32_t>(_persons.active.size()); ++i) {
        mix_u64(0x504552534f4eULL);
        mix_u64(static_cast<uint32_t>(i));
        mix_u64(_persons.generation[i]);
        mix_u64(_persons.active[i]);
        if (_persons.active[i] == 0) continue;
        mix_u64(static_cast<uint64_t>(_persons.stable_id[i]));
        mix_u64(_persons.family_handle[i]); mix_u64(_persons.cohort_handle[i]);
        mix_u64(static_cast<uint32_t>(_persons.given_name_id[i]));
        mix_u64(_persons.name_disambiguator[i]);
        mix_u64(static_cast<uint64_t>(_persons.notable_since_day[i]));
        mix_u64(_persons.flags[i]);
        mix_u64(static_cast<uint64_t>(_persons.cash_claim[i]));
        mix_u64(static_cast<uint64_t>(_persons.family_equity_share_q32[i]));
        mix_u64(static_cast<uint64_t>(_persons.epoch_job_income[i]));
        mix_u64(static_cast<uint64_t>(_persons.epoch_business_result[i]));
        mix_u64(static_cast<uint64_t>(_persons.epoch_consumption_expense[i]));
        mix_u64(static_cast<uint64_t>(_persons.epoch_tax[i]));
        mix_u64(static_cast<uint64_t>(_persons.income_ema[i]));
        mix_u64(_persons.needs_satisfaction[i]); mix_u64(_persons.worst_need_id[i]);
        mix_u64(_persons.building_handle[i]); mix_u64(_persons.job_kind[i]);
        mix_u64(static_cast<uint32_t>(_persons.employee_role_index[i]));
        mix_u64(static_cast<uint64_t>(_persons.job_since_day[i]));
    }
    for (const PersonNeedState &state : _person_needs) {
        mix_u64(state.person_handle);
        mix_u64(static_cast<uint32_t>(state.stable_need_id));
        mix_u64(static_cast<uint64_t>(state.desired_period_units));
        mix_u64(state.satisfaction_q16);
        mix_u64(static_cast<uint64_t>(state.attributed_spend));
    }
    for (int32_t mapping : _market.cell_to_market) mix_u64(static_cast<uint32_t>(mapping));
    for (int64_t value : _market.stock) mix_u64(static_cast<uint64_t>(value));
    for (int32_t value : _market.price) mix_u64(static_cast<uint32_t>(value));
    for (int64_t value : _market.demand_ema) mix_u64(static_cast<uint64_t>(value));
    for (uint16_t value : _market.last_shortage_q16) mix_u64(value);
    for (const Command &cmd : _pending_commands) {
        mix_u64(static_cast<uint32_t>(cmd.opcode));
        mix_u64(static_cast<uint64_t>(cmd.effective_day));
        mix_u64(static_cast<uint64_t>(cmd.sequence));
        mix_u64(cmd.target_handle);
        mix_u64(static_cast<uint32_t>(cmd.i32_0));
        mix_u64(static_cast<uint32_t>(cmd.i32_1));
        mix_u64(static_cast<uint64_t>(cmd.i64_0));
        mix_u64(static_cast<uint64_t>(cmd.i64_1));
        mix_u64(static_cast<uint64_t>(cmd.effect_request_id));
        mix_u64(cmd.effect_idempotency_key);
    }
    for (const BuildingGroup &group : _buildings) {
        mix_u64(static_cast<uint32_t>(group.cell));
        mix_u64(static_cast<uint32_t>(group.type_id));
        mix_u64(static_cast<uint32_t>(group.owner_signature_id));
        mix_u64(static_cast<uint64_t>(group.count));
        mix_u64(static_cast<uint64_t>(group.filled_owner));
        mix_u64(static_cast<uint64_t>(group.last_capacity_q16));
        mix_u64(static_cast<uint64_t>(group.last_temperature_fit_q16));
        mix_u64(static_cast<uint64_t>(group.last_water_fit_q16));
        mix_u64(static_cast<uint64_t>(group.last_climate_capacity_q16));
        mix_u64(static_cast<uint64_t>(group.last_climate_lost_output));
        mix_u64(static_cast<uint64_t>(group.last_input));
        mix_u64(static_cast<uint64_t>(group.last_output));
        mix_u64(static_cast<uint64_t>(group.last_sold));
        mix_u64(static_cast<uint64_t>(group.last_discarded));
        mix_u64(static_cast<uint64_t>(group.last_resource));
        mix_u64(static_cast<uint64_t>(group.last_resource_generated));
        mix_u64(static_cast<uint64_t>(group.last_revenue));
        mix_u64(static_cast<uint64_t>(group.last_input_cost));
        mix_u64(static_cast<uint64_t>(group.last_wages_paid));
        mix_u64(static_cast<uint64_t>(group.last_wages_due));
        mix_u64(static_cast<uint64_t>(group.last_expected_revenue));
        mix_u64(static_cast<uint64_t>(group.last_operating_cost));
        mix_u64(static_cast<uint32_t>(group.last_margin_gap_q16));
        mix_u64(static_cast<uint32_t>(group.planned_utilization_q16));
        mix_u64(static_cast<uint64_t>(group.last_base_wages_paid));
        mix_u64(static_cast<uint64_t>(group.last_base_wages_due));
        mix_u64(static_cast<uint64_t>(group.last_bonus_paid));
        mix_u64(static_cast<uint64_t>(group.last_bonus_due));
        mix_u64(group.wage_suspended);
        mix_u64(static_cast<uint64_t>(group.purchase_intent_capacity_q16));
        mix_u64(static_cast<uint32_t>(group.realized_profit_margin_q16));
        mix_u64(group.severe_loss_cycles);
        mix_u64(group.recovery_cycles);
        mix_u64(group.recovery_failed_reviews);
        mix_u64(group.merchant_debt_term_cycles_left);
        mix_u64(group.merchant_debt_delinquent_cycles);
        mix_u64(std::min<uint8_t>(group.operating_state, 1));
        mix_u64(group.pending_operating_state <= 1
            ? group.pending_operating_state : uint8_t{255});
        mix_u64(0);
        mix_u64(static_cast<uint64_t>(group.merchant_debt_principal));
        mix_u64(static_cast<uint64_t>(group.merchant_debt_premium));
        mix_u64(static_cast<uint64_t>(group.last_in_kind_livelihood_value));
    }
    // CSR offsets are reconstructed from the stable signal records and are not
    // persistent authority. Hash only the records so bootstrap and restore do
    // not diverge on an equivalent transient cache shape.
    for (size_t i = 0; i < _market_signals.good_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_market_signals.good_ids[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.business_demand_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.offered_supply_ema[i]));
        mix_u64(static_cast<uint64_t>(_market_signals.realized_withdrawal_ema[i]));
        mix_u64(static_cast<uint32_t>(_market_signals.cost_anchor_price[i]));
    }
    auto hash_building_role_lanes = [&](const std::vector<int64_t> &lanes) {
        for (const BuildingGroup &group : _buildings) {
            const BuildingType &type = _building_types[group.type_id];
            for (int32_t role = 0; role < type.employee_count; ++role) {
                mix_u64(static_cast<uint64_t>(
                    lanes[group.employee_fill_begin + role]));
            }
        }
    };
    hash_building_role_lanes(_building_employee_filled);
    hash_building_role_lanes(_building_role_contract_wage);
    hash_building_role_lanes(_building_role_base_living_cost);
    hash_building_role_lanes(_building_role_living_cost);
    hash_building_role_lanes(_building_role_local_average_wage);
    hash_building_role_lanes(_building_role_base_wage_due);
    hash_building_role_lanes(_building_role_base_wage_paid);
    hash_building_role_lanes(_building_role_bonus_due);
    hash_building_role_lanes(_building_role_bonus_paid);
    // Labor cell offsets are likewise a derived lookup cache.
    for (size_t i = 0; i < _labor_signals.profession_ids.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_labor_signals.profession_ids[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.base_living_cost[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.role_living_cost[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.contract_wage_ema[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.paid_wage_ema[i]));
        mix_u64(static_cast<uint64_t>(_labor_signals.job_days[i]));
        mix_u64(static_cast<uint32_t>(_labor_signals.pay_ratio_q16[i]));
    }
    for (const PendingConstruction &pending : _pending_construction) {
        mix_u64(static_cast<uint32_t>(pending.cell));
        mix_u64(static_cast<uint32_t>(pending.type_id));
        mix_u64(static_cast<uint32_t>(pending.owner_signature_id));
        mix_u64(static_cast<uint64_t>(pending.count));
        mix_u64(static_cast<uint64_t>(pending.ready_day));
        mix_u64(static_cast<uint64_t>(pending.sequence));
        mix_u64(static_cast<uint64_t>(pending.merchant_debt_principal));
        mix_u64(static_cast<uint64_t>(pending.merchant_debt_premium));
        mix_u64(pending.merchant_debt_term_cycles_left);
        mix_u64(pending.sponsor_family_handle);
    }
    if (_trade_runtime_mode == 2 || !_trade_orders.ids.empty() ||
        !_trade_flows.cells.empty()) {
    mix_u64(0x5452414445524556ULL); // "TRADEREV"
    mix_u64(_country_trade_revision);
    for (int32_t order = 0; order < _trade_orders.size(); ++order) {
        mix_u64(static_cast<uint64_t>(_trade_orders.ids[order]));
        mix_u64(static_cast<uint32_t>(_trade_orders.sources[order]));
        mix_u64(static_cast<uint32_t>(_trade_orders.destinations[order]));
        mix_u64(static_cast<uint32_t>(_trade_orders.countries[order]));
        mix_u64(_trade_orders.source_country_handles[order]);
        mix_u64(_trade_orders.destination_country_handles[order]);
        mix_u64(static_cast<uint32_t>(_trade_orders.source_country_slots[order]));
        mix_u64(static_cast<uint32_t>(_trade_orders.destination_country_slots[order]));
        mix_u64(static_cast<uint64_t>(_trade_orders.departure_days[order]));
        mix_u64(static_cast<uint64_t>(_trade_orders.arrival_days[order]));
        mix_u64(static_cast<uint64_t>(_trade_orders.cash_escrow[order]));
        mix_u64(static_cast<uint64_t>(_trade_orders.capacity_work[order]));
        mix_u64(_trade_orders.states[order]);
        mix_u64(_trade_orders.cargo_delivered[order]);
        for (int32_t line = _trade_orders.line_offsets[order];
             line < _trade_orders.line_offsets[order + 1]; ++line) {
            mix_u64(static_cast<uint32_t>(_trade_orders.line_goods[line]));
            mix_u64(static_cast<uint64_t>(_trade_orders.line_quantities[line]));
            mix_u64(static_cast<uint32_t>(_trade_orders.line_unit_prices[line]));
            mix_u64(static_cast<uint32_t>(_trade_orders.line_destination_prices[line]));
            mix_u64(static_cast<uint64_t>(_trade_orders.line_base_values[line]));
            mix_u64(static_cast<uint64_t>(_trade_orders.line_retail_values[line]));
            mix_u64(static_cast<uint64_t>(_trade_orders.line_import_transfers[line]));
            mix_u64(static_cast<uint64_t>(_trade_orders.line_export_transfers[line]));
            mix_u64(_trade_orders.line_flags[line]);
        }
        for (int32_t seller = _trade_orders.seller_offsets[order];
             seller < _trade_orders.seller_offsets[order + 1]; ++seller) {
            mix_u64(_trade_orders.seller_handles[seller]);
            mix_u64(static_cast<uint64_t>(_trade_orders.seller_weights[seller]));
        }
    }
    mix_u64(static_cast<uint64_t>(_trade_orders.next_id));
    for (size_t i = 0; i < _trade_flows.cells.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_trade_flows.cells[i]));
        mix_u64(static_cast<uint32_t>(_trade_flows.goods[i]));
        mix_u64(static_cast<uint64_t>(_trade_flows.import_ema[i]));
        mix_u64(static_cast<uint64_t>(_trade_flows.export_ema[i]));
    }
    }
    mix_u64(0x434f554e54525947ULL); // "COUNTRYG"
    for (size_t i = 0; i < _country_good_trade.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_country_good_trade.countries[i]));
        mix_u64(static_cast<uint32_t>(_country_good_trade.goods[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.import_tariff[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.export_tariff[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_epoch[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_import_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_good_trade.batch_export_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_import_tariff[i]));
        mix_u64(static_cast<uint64_t>(
            _country_good_trade.batch_export_tariff[i]));
    }
    mix_u64(0x434f554e54525950ULL); // "COUNTRYP"
    for (size_t i = 0; i < _country_partner_trade.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_country_partner_trade.countries[i]));
        mix_u64(static_cast<uint32_t>(_country_partner_trade.partners[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.import_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.export_quantity[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.import_base[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.export_base[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.order_count[i]));
        mix_u64(static_cast<uint64_t>(_country_partner_trade.batch_epoch[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_import_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_export_quantity[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_import_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_export_base[i]));
        mix_u64(static_cast<uint64_t>(
            _country_partner_trade.batch_order_count[i]));
    }
    mix_u64(0x5441524946464849ULL); // "TARIFFHI"
    for (size_t i = 0; i < _tariff_history.countries.size(); ++i) {
        mix_u64(static_cast<uint32_t>(_tariff_history.countries[i]));
        mix_u64(static_cast<uint32_t>(_tariff_history.kinds[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.bases[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.assessed[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.collected[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.requests[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.reserved[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.paid[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_bases[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_collected[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_requests[i]));
        mix_u64(static_cast<uint64_t>(_tariff_history.cumulative_paid[i]));
    }
    mix_u64(0x46495343414c4556ULL); // "FISCALEV"
    // Restore materializes a dense zero-filled fiscal event group while a
    // never-committed bootstrap may still hold an empty vector. Hash the same
    // fixed logical country x tax-kind shape used by PKEC serialization.
    mix_fiscal_lanes(_fiscal_last_events);
    // Canal quotes are read-side preview state and deliberately do not alter
    // the authoritative simulation hash.  Started projects do: they own paid
    // construction resources and the route that an Effect transaction will
    // atomically commit.
    if (!_canal_projects.empty()) {
        mix_u64(0x43414e414c50524aULL); // "CANALPRJ"
        mix_u64(static_cast<uint64_t>(_next_canal_project_id));
        for (const CanalProject &project : _canal_projects) {
            mix_u64(project.handle);
            mix_u64(project.generation);
            mix_u64(project.country_handle);
            mix_u64(static_cast<uint64_t>(project.effective_day));
            mix_u64(static_cast<uint64_t>(project.sequence));
            mix_u64(static_cast<uint64_t>(project.ready_day));
            mix_u64(project.topology_hash);
            mix_u64(static_cast<uint64_t>(project.cash_paid));
            mix_u64(static_cast<uint64_t>(project.treasury_goods_used));
            mix_u64(static_cast<uint64_t>(project.market_goods_used));
            mix_u64(static_cast<uint64_t>(project.source_kind));
            mix_u64(static_cast<uint64_t>(project.state));
            mix_u64(static_cast<uint64_t>(project.effect_transaction_id));
            mix_u64(static_cast<uint64_t>(project.route_cells.size()));
            for (const int32_t cell : project.route_cells)
                mix_u64(static_cast<uint64_t>(cell));
            for (const int32_t direction : project.route_edge_dirs)
                mix_u64(static_cast<uint64_t>(direction));
        }
    }
    mix_u64(0x4d4f444946494552ULL); // "MODIFIER"
    if (_modifier_runtime != nullptr) {
        std::vector<uint8_t> modifier_bytes;
        std::string modifier_error;
        if (_modifier_runtime->serialize_domain(ModifierRuntime::ECONOMY,
                                                modifier_bytes,
                                                modifier_error)) {
            // Modifier snapshot_version is a cache invalidation counter and
            // intentionally advances during restore; exclude that header lane
            // while retaining every persistent instance and identity byte.
            mix_u64(modifier_bytes.size());
            for (size_t byte_index = 0; byte_index < modifier_bytes.size();
                 ++byte_index) {
                if (byte_index >= 24 && byte_index < 32) continue;
                const uint8_t byte = modifier_bytes[byte_index];
                hash ^= byte;
                hash *= 1099511628211ULL;
            }
        } else {
            mix_u64(0xffffffffffffffffULL);
            mix_string(modifier_error);
        }
    } else {
        mix_u64(0);
    }
    return static_cast<int64_t>((hash & 0x7fffffffffffffffULL) | 1ULL);
}

Dictionary NativeEconomyRuntime::reset(const String &reason) {
    _configured = false;
    _bootstrapped = false;
    _epoch_active = false;
    _fatal = false;
    _fatal_reason.clear();
    _stage = Stage::IDLE;
    _cell_count = 0;
    _catalog_hash = 0;
    _catalog_compat_hash_v6 = 0;
    _catalog_compat_hash_v7 = 0;
    _catalog_compat_hash_v8 = 0;
    _catalog_compat_hash_v10 = 0;
    _family_catalog_hash = 0;
    _family_trait_catalog_version = 0;
    _family_trait_catalog_hash = 0;
    _building_catalog_hash = 0;
    _building_catalog_compat_hash_v6 = 0;
    _epoch_id = 0;
    _sample_day = -1;
    _current_day = -1;
    _commit_day = -1;
    _last_committed_day = -1;
    _next_submit_order = 1;
    _next_event_id = 1;
    _event_stream_hash = 1469598103934665603ULL;
    _event_evicted_count = 0;
    _first_evicted_event_id = 0;
    _trace_detail_truncated = 0;
    _trace_uncommitted_discarded = 0;
    _opening_totals = {};
    _closing_totals = {};
    _incremental_closing_totals = {};
    _opening_audit_force_full = false;
    _audit_shadow_population.clear();
    _audit_shadow_funds.clear();
    _audit_shadow_market_stock.clear();
    _audit_population_lane_stamp.clear();
    _audit_market_lane_stamp.clear();
    _audit_population_touched_lanes.clear();
    _audit_market_touched_lanes.clear();
    _audit_mutation_generation = 0;
    _closing_audit_mismatch_ledger = "none";
    _closing_audit_mismatch_lane = -1;
    clear_epoch_metrics();
    _population.clear(0);
    _birth_residual_q32.clear();
    _families.clear();
    _family_expeditions.clear();
    _family_expedition_route_cells.clear();
    _family_expedition_route_costs.clear();
    _family_expedition_payloads.clear();
    _family_expedition_person_handles.clear();
    _family_expedition_target_index.clear();
    _family_expedition_due_heap.clear();
    _colonization_receipts.clear();
    _next_colonization_receipt_id = 1;
    _next_family_expedition_stable_id = 1;
    _colonization_quote_cache.clear();
    _colonization_quote_index.clear();
    _colonization_quote_route_cells.clear();
    _colonization_quote_route_costs.clear();
    _canal_quotes.clear();
    _canal_quote_index.clear();
    _canal_projects.clear();
    _canal_project_index.clear();
    _canal_receipts.clear();
    _next_canal_quote_token = 1;
    _next_canal_project_id = 1;
    _next_canal_receipt_id = 1;
    _family_influences.clear();
    _persons.clear();
    _family_memberships.clear();
    _family_ownerships.clear();
    _family_traits.clear();
    _family_trait_commands.clear();
    _family_modifier_bindings.clear();
    _person_needs.clear();
    _person_needs_normalized = false;
    _family_member_offsets.clear();
    _family_member_edge_indices.clear();
    _family_owned_offsets.clear();
    _family_owned_edge_indices.clear();
    _family_cohort_offsets.clear();
    _family_cohort_edge_indices.clear();
    _family_building_offsets.clear();
    _family_building_edge_indices.clear();
    _family_cell_offsets.clear();
    _family_cell_indices.clear();
    _family_indices_dirty = true;
    _person_family_offsets.clear(); _person_family_indices.clear();
    _person_cohort_offsets.clear(); _person_cohort_indices.clear();
    _person_cohort_migrations.clear();
    _person_family_migrations.clear();
    _person_stable_ids.clear();
    _family_stable_ids.clear();
    _family_surname_members.clear();
    _person_cell_offsets.clear(); _person_cell_indices.clear();
    _person_building_offsets.clear(); _person_building_indices.clear();
    _person_need_offsets.clear(); _person_indices_dirty = true;
    _person_opening_cash_claim.clear(); _person_epoch_needs.clear();
    _person_previous_building_handle.clear();
    _person_previous_job_kind.clear();
    _person_previous_employee_role_index.clear();
    _settlements.clear(0);
    _market.clear();
    _market_signals.clear(0);
    _market_signals_rebuild_scratch.clear(0);
    _labor_signals.clear(0);
    _labor_signals_rebuild_scratch.clear(0);
    _market_signal_overflow_cells.clear();
    _trade_topology.clear();
    _trade_plan.clear_transient();
    _trade_plan_reset_count = 0;
    _trade_topology_content_change_count = 0;
    _trade_last_plan_reset_reason = "none";
    _trade_orders.clear();
    _trade_flows.clear();
    _tariff_history.clear();
    _country_good_trade.clear();
    _country_partner_trade.clear();
    _country_good_trade_index.clear();
    _country_partner_trade_index.clear();
    _tariff_history_index.clear();
    _country_good_display_rows.clear();
    _country_partner_display_rows.clear();
    _country_good_display_dirty.clear();
    _country_partner_display_dirty.clear();
    _country_trade_revision = 0;
    _pending_commands.clear();
    _epoch_commands.clear();
    _effect_command_results.clear();
    _effect_idempotency_requests.clear();
    _next_effect_request_id = 1;
    _structural_commands.clear();
    _committed_cells.clear();
    _staging_cells.clear();
    _structural_touched_cells.clear();
    _population_changed_cells.clear();
    _structural_reconciled_upto = 0;
    _publish_accum = {};
    _structural_funds_to_treasury = 0;
    _market_cell_offsets.clear();
    _market_cells.clear();
    _merchant_primary_slot.clear();
    _merchant_offsets.clear();
    _merchant_slots.clear();
    _trace_cell_mask.clear();
    _pending_trace_cell_mask.clear();
    _trace_filter_pending = false;
    _inspector_trace_cell = -1;
    _pending_inspector_trace_cell = -1;
    _inspector_trace_pending = false;
    _investment_diagnostic_cell = -1;
    _investment_diagnostic_day = -1;
    _investment_diagnostics.clear();
    _investment_output_signals_scratch.clear();
    _investment_review_cell_indices.clear();
    _investment_resource_committed_by_cell.clear();
    _investment_merchant_cash_by_cell.clear();
    _investment_outstanding_credit_by_cell.clear();
    _investment_resource_commitment_stamp.clear();
    _investment_cell_finance_stamp.clear();
    _investment_scratch_generation = 0;
    _market_results_scratch.clear();
    _production_results_scratch.clear();
    _last_completed_perf = {};
    _staging_events = {};
    _committed_event_batches.clear();
    _staging_construction_receipts.clear();
    _committed_construction_receipts.clear();
    _next_construction_receipt_id = 1;
    _staging_gameplay_facts.clear();
    _committed_gameplay_facts.clear();
    _audit_history.clear();
    _event_consumer_ack.clear();
    _event_archive = {};
    _environment_temperature_q16.clear();
    _environment_temperature_30d_q16.clear();
    _environment_moisture_q16.clear();
    _environment_plant_available_water_q16.clear();
    _environment_snow_q16.clear();
    _environment_weather_q16.clear();
    _building_elevation_q16.clear();
    _building_terrain.clear();
    _building_landform.clear();
    _building_vegetation.clear();
    _building_is_water.clear();
    _building_has_river.clear();
    _building_neighbors.clear();
    _resource_snapshot.clear();
    _resource_remaining.clear();
    _resource_harvest_remaining.clear();
    _resource_deltas.clear();
    _resource_lane_generation.clear();
    _resource_touched_lanes.clear();
    _last_published_resource_touched_lanes.clear();
    _resource_current_generation = 0;
    _last_published_resource_deltas.clear();
    _epoch_cell_country.clear();
    _epoch_country_technologies.clear();
    _epoch_country_building_available.clear();
    _epoch_country_building_type_offsets.clear();
    _epoch_country_building_type_indices.clear();
    _epoch_country_good_output_factor_q16.clear();
    _epoch_country_good_input_factor_q16.clear();
    _epoch_country_good_consumption_factor_q16.clear();
    _epoch_country_resource_use_factor_q16.clear();
    _epoch_country_resource_generation_factor_q16.clear();
    _epoch_country_terrain_sector_output_factor_q16.clear();
    _epoch_country_landform_sector_output_factor_q16.clear();
    _epoch_country_production_input_factor_q16.clear();
    _epoch_country_household_consumption_factor_q16.clear();
    _epoch_country_resource_global_use_factor_q16.clear();
    _epoch_cell_birth_factor_q16.clear();
    _epoch_cell_need_consumption_factor_q16.clear();
    _epoch_cell_good_consumption_factor_q16.clear();
    _epoch_city_factor_valid = false;
    _epoch_city_factor_stat_version = 0;
    _city_factor_dirty_cells.clear();
    _epoch_country_count = 0;
    _epoch_country_technology_words = 0;
    _epoch_country_generation = 0;
    _epoch_country_hash = 0;
    _epoch_country_topology_hash = 0;
    _epoch_tax_policy_version = 0;
    _epoch_income_tax_rates.clear();
    _epoch_consumption_tax_rates.clear();
    _epoch_business_tax_rates.clear();
    _epoch_import_tax_rates.clear();
    _epoch_export_tax_rates.clear();
    _epoch_cell_compiled_tax_policy.clear();
    _epoch_cell_active_tax_mask.clear();
    _epoch_compiled_cell_tax_policies.clear();
    _epoch_compiled_cell_tax_overrides.clear();
    _epoch_compiled_cell_tax_default_rows.clear();
    _epoch_compiled_cell_tax_default_rates.clear();
    _epoch_cell_tax_cache_bytes = 0;
    _epoch_cell_tax_compile_ms = 0.0;
    _epoch_has_cell_tax_policies = false;
    _fiscal_previous_requests.clear();
    _fiscal_previous_country_handles.clear();
    _fiscal_reservation_requests.clear();
    _fiscal_current_requests.clear();
    _fiscal_budgets.clear();
    _fiscal_remaining.clear();
    _fiscal_epoch_bases.clear();
    _fiscal_epoch_assessed.clear();
    _fiscal_epoch_collected.clear();
    _fiscal_epoch_paid.clear();
    _fiscal_escrow_by_country.clear();
    _fiscal_last_bases.clear();
    _fiscal_last_assessed.clear();
    _fiscal_last_collected.clear();
    _fiscal_last_requests.clear();
    _fiscal_last_reserved.clear();
    _fiscal_last_paid.clear();
    _fiscal_last_events.clear();
    _fiscal_last_unmet.clear();
    _fiscal_cumulative_bases.clear();
    _fiscal_cumulative_collected.clear();
    _fiscal_cumulative_requests.clear();
    _fiscal_cumulative_paid.clear();
    _tariff_epoch_cells.clear();
    _tariff_epoch_kinds.clear();
    _tariff_epoch_bases.clear();
    _tariff_epoch_assessed.clear();
    _tariff_epoch_collected.clear();
    _tariff_epoch_requests.clear();
    _tariff_epoch_reserved.clear();
    _tariff_epoch_paid.clear();
    _tariff_epoch_events.clear();
    _tariff_lane_index.clear();
    _tariff_lane_stamp.clear();
    _tariff_lane_generation = 0;
    _tariff_country_requests.clear();
    _tariff_country_budgets.clear();
    _tariff_country_remaining.clear();
    _income_taxable_base_by_slot.clear();
    _income_subsidy_floor_by_slot.clear();
    _technology_words = 0;
    _buildings.clear();
    _building_handle_index_clean = false;
    _building_groups_rebuild_scratch.clear();
    _building_existing_indices_scratch.clear();
    _building_new_indices_scratch.clear();
    _building_investment_score_rebuild_scratch.clear();
    _building_investment_payback_rebuild_scratch.clear();
    _building_investment_rejection_rebuild_scratch.clear();
    _building_free_role_spans_by_type.clear();
    _building_market_signal_stamp.clear();
    _building_labor_signal_stamp.clear();
    _building_market_signal_stamp_generation = 0;
    _building_labor_signal_stamp_generation = 0;
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _cell_last_settlement_day.clear();
    _cell_settlement_generation.clear();
    _cell_price_stock_gen.clear();
    _cell_owner_cash_gen.clear();
    _cell_population_gen.clear();
    _cell_building_structure_gen.clear();
    _cell_technology_gen.clear();
    _cell_resource_gen.clear();
    _cell_trade_gen.clear();
    _epoch_market_ids.clear();
    _epoch_settlement_cells.clear();
    _epoch_building_cells.clear();
    _epoch_plan_cells.clear();
    _employment_metrics_epoch_by_cell.clear();
    _employment_owner_jobs_by_cell.clear();
    _employment_employee_jobs_by_cell.clear();
    _employment_unemployed_by_cell.clear();
    _demand_basis_cache_day.clear();
    _demand_basis_variant_scores.clear();
    _demand_basis_variant_prices.clear();
    _demand_basis_need_score_sums.clear();
    _demand_basis_need_composites.clear();
    _demand_basis_need_environment.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _pending_construction.clear();
    _pending_construction_cell_offsets.clear();
    _pending_construction_cell_indices.clear();
    _building_context_day = -1;
    _resource_deltas_ready = false;
    _environment_day = -1;
    _environment_hash = 0;
    _save = {};
    _restore = {};
    Dictionary out;
    out["ok"] = true;
    out["reason"] = reason;
    return out;
}


} // namespace pk

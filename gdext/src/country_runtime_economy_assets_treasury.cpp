#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "country_host_port.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <numeric>
#include <type_traits>
#include <unordered_set>

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;

int64_t NativeCountryRuntime::complete_economy_asset_compatibility(
        const Dictionary &begin) {
    if (!static_cast<bool>(begin.get("ok", false))) return 0;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed"
            ? static_cast<int64_t>(begin.get("committed_quantity", 0)) : 0;
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    if (transaction_id == 0 || session_epoch == 0 || country_generation == 0)
        return 0;
    // Legacy Economy callers remain synchronous until the real peer
    // coordinator is connected. They still traverse the typed protocol.
    const uint64_t peer_generation = transaction_id;
    const Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return 0;
    const Dictionary committed = commit_economy_asset_transaction(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return 0;
    const Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
            String(applied.get("status_name", "")) == "completed"
        ? static_cast<int64_t>(applied.get("committed_quantity", 0)) : 0;
}

int64_t NativeCountryRuntime::economy_reserve_fiscal_cash(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_reserve(
        country_handle, requested, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_return_fiscal_cash(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_return(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_collect_fiscal_cash(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_fiscal_collect(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

bool NativeCountryRuntime::economy_purchase_research_points(
        int32_t country_slot, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    if (country_slot < 0 ||
        country_slot >= static_cast<int32_t>(_countries.active.size()))
        return false;
    const uint64_t handle = make_handle(country_slot);
    // The legacy production caller is still synchronous, but it now traverses
    // the same typed transaction state machine.  The synthetic peer ACKs are a
    // compatibility adapter until NativeEconomyRuntime owns the real market
    // prepare/apply coordinator; they must not be used as ACTIVE authority.
    Dictionary begin = begin_economy_research_purchase(
        static_cast<int64_t>(handle), quantity, total_cost, origin_epoch,
        origin_stage, request_id);
    if (!static_cast<bool>(begin.get("ok", false))) return false;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed";
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    const uint64_t peer_generation = transaction_id;
    Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return false;
    Dictionary committed = commit_economy_asset_transaction(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return false;
    Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
        String(applied.get("status_name", "")) == "completed";
}

bool NativeCountryRuntime::purchase_research_points(int32_t country_slot,
                                                     int64_t quantity,
                                                     int64_t total_cost) {
    return economy_purchase_research_points(country_slot, quantity, total_cost,
        -1, -1);
}
int64_t NativeCountryRuntime::debit_country_cash(
        int64_t country_handle, int64_t requested, const char *trace_stage) {
    int32_t slot = -1;
    if (requested <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t moved = std::min(requested, _countries.cash[static_cast<size_t>(slot)]);
    _countries.cash[static_cast<size_t>(slot)] -= moved;
    if (moved > 0) {
        ++_countries.state_version[static_cast<size_t>(slot)];
        ++_generation;
        _state_hash_cache_valid = false;
        record_direct_reference_frame(trace_stage);
    }
    return moved;
}

int64_t NativeCountryRuntime::transfer_cash_to_cohort(
        int64_t country_handle, int64_t requested) {
    return economy_transfer_cash_to_cohort(country_handle, requested, -1, -1);
}

int64_t NativeCountryRuntime::cash_for_handle(int64_t country_handle) const {
    int32_t slot = -1;
    return validate_handle(static_cast<uint64_t>(country_handle), slot)
        ? _countries.cash[static_cast<size_t>(slot)] : 0;
}

int64_t NativeCountryRuntime::good_for_handle(int64_t country_handle,
                                               int32_t good_id) const {
    int32_t slot = -1;
    if (good_id < 0 || good_id >= static_cast<int32_t>(_good_ids.size()) ||
        !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    return _country_goods[static_cast<size_t>(slot) * _good_ids.size() +
                          static_cast<size_t>(good_id)];
}

bool NativeCountryRuntime::spend_treasury_assets(
        int64_t country_handle, const int32_t *good_ids,
        const int64_t *quantities, size_t good_count, int64_t cash) {
    return economy_spend_treasury_assets(country_handle, good_ids, quantities,
        good_count, cash, -1, -1);
}

int64_t NativeCountryRuntime::credit_country_cash(
        int64_t country_handle, int64_t offered, const char *trace_stage) {
    int32_t slot = -1;
    if (offered <= 0 || !validate_handle(static_cast<uint64_t>(country_handle), slot)) return 0;
    const int64_t room = std::numeric_limits<int64_t>::max() - _countries.cash[static_cast<size_t>(slot)];
    const int64_t moved = std::min(offered, room);
    _countries.cash[static_cast<size_t>(slot)] += moved;
    if (moved > 0) {
        ++_countries.state_version[static_cast<size_t>(slot)];
        ++_generation;
        _state_hash_cache_valid = false;
        record_direct_reference_frame(trace_stage);
    }
    return moved;
}

int64_t NativeCountryRuntime::economy_transfer_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_cash_to_cohort(
        country_handle, requested, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_transfer_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_cash_from_cohort(
        country_handle, offered, origin_epoch, origin_stage, request_id));
}

int64_t NativeCountryRuntime::economy_transfer_good_to_market(
        int64_t country_handle, int32_t good_id, int64_t requested,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_good_to_market(
        country_handle, good_id, requested, origin_epoch, origin_stage,
        request_id));
}

int64_t NativeCountryRuntime::economy_transfer_good_from_market(
        int64_t country_handle, int32_t good_id, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    return complete_economy_asset_compatibility(begin_economy_good_from_market(
        country_handle, good_id, offered, origin_epoch, origin_stage,
        request_id));
}

bool NativeCountryRuntime::economy_spend_treasury_assets(
        int64_t country_handle, const int32_t *good_ids,
        const int64_t *quantities, size_t good_count, int64_t cash,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id) {
    PackedInt32Array ids;
    PackedInt64Array amounts;
    ids.resize(static_cast<int64_t>(good_count));
    amounts.resize(static_cast<int64_t>(good_count));
    for (size_t i = 0; i < good_count; ++i) {
        ids.set(static_cast<int64_t>(i), good_ids == nullptr ? -1 : good_ids[i]);
        amounts.set(static_cast<int64_t>(i),
            quantities == nullptr ? -1 : quantities[i]);
    }
    Dictionary begin = begin_economy_treasury_spend(
        country_handle, ids, amounts, cash, origin_epoch, origin_stage,
        request_id);
    if (!static_cast<bool>(begin.get("ok", false))) return false;
    if (static_cast<bool>(begin.get("replayed", false)))
        return String(begin.get("status_name", "")) == "completed";
    const uint64_t transaction_id = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("transaction_id", 0)));
    const uint64_t session_epoch = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("session_epoch", 0)));
    const uint64_t country_generation = static_cast<uint64_t>(
        static_cast<int64_t>(begin.get("country_generation", 0)));
    const uint64_t peer_generation = transaction_id;
    Dictionary prepared = acknowledge_economy_asset_peer_prepared(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    if (!static_cast<bool>(prepared.get("ok", false))) return false;
    Dictionary committed = commit_economy_treasury_spend(transaction_id);
    if (!static_cast<bool>(committed.get("ok", false))) return false;
    Dictionary applied = acknowledge_economy_asset_peer_applied(
        transaction_id, session_epoch, country_generation, peer_generation,
        true, String());
    return static_cast<bool>(applied.get("ok", false)) &&
        String(applied.get("status_name", "")) == "completed";
}

int64_t NativeCountryRuntime::transfer_cash_from_cohort(
        int64_t country_handle, int64_t offered) {
    return economy_transfer_cash_from_cohort(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::reserve_fiscal_cash(int64_t country_handle,
                                                   int64_t requested) {
    return economy_reserve_fiscal_cash(country_handle, requested, -1, -1);
}

int64_t NativeCountryRuntime::return_fiscal_cash(int64_t country_handle,
                                                  int64_t offered) {
    return economy_return_fiscal_cash(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::collect_fiscal_cash(int64_t country_handle,
                                                   int64_t offered) {
    return economy_collect_fiscal_cash(country_handle, offered, -1, -1);
}

int64_t NativeCountryRuntime::transfer_good_to_market(int64_t country_handle, int32_t good_id,
                                                       int64_t requested) {
    return economy_transfer_good_to_market(country_handle, good_id, requested,
        -1, -1);
}

int64_t NativeCountryRuntime::transfer_good_from_market(int64_t country_handle, int32_t good_id,
                                                         int64_t offered) {
    return economy_transfer_good_from_market(country_handle, good_id, offered,
        -1, -1);
}

bool NativeCountryRuntime::copy_economy_snapshot(EconomySnapshot &out) const {
    if (!economy_available()) return false;
    // Pin one immutable Country commit for the whole economic freeze. The
    // legacy store stops advancing as soon as the worker owns Country.
    const auto worker = _simulation_host != nullptr &&
        _simulation_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY)
        ? _simulation_host->country_asset_snapshot() : nullptr;
    const auto &_cell_country_slot = worker ? worker->cell_country_slot : this->_cell_country_slot;
    const auto &_country_technologies = worker ? worker->country_technologies : this->_country_technologies;
    const auto &_country_research_signals = worker
        ? worker->country_research_signals : this->_country_research_signals;
    const auto &_country_tax_defaults = worker ? worker->country_tax_defaults : this->_country_tax_defaults;
    const auto &_country_tax_default_modes = worker ? worker->country_tax_default_modes : this->_country_tax_default_modes;
    const auto &_cell_tax_policy_ids = worker ? worker->cell_tax_policy_ids : this->_cell_tax_policy_ids;
    const auto &_country_income_tax_overrides = worker ? worker->country_income_tax_overrides : this->_country_income_tax_overrides;
    const auto &_country_income_tax_mode_overrides = worker ? worker->country_income_tax_mode_overrides : this->_country_income_tax_mode_overrides;
    const auto &_country_consumption_tax_overrides = worker ? worker->country_consumption_tax_overrides : this->_country_consumption_tax_overrides;
    const auto &_country_consumption_tax_mode_overrides = worker ? worker->country_consumption_tax_mode_overrides : this->_country_consumption_tax_mode_overrides;
    const auto &_country_business_tax_overrides = worker ? worker->country_business_tax_overrides : this->_country_business_tax_overrides;
    const auto &_country_business_tax_mode_overrides = worker ? worker->country_business_tax_mode_overrides : this->_country_business_tax_mode_overrides;
    const auto &_country_import_tax_overrides = worker ? worker->country_import_tax_overrides : this->_country_import_tax_overrides;
    const auto &_country_import_tax_mode_overrides = worker ? worker->country_import_tax_mode_overrides : this->_country_import_tax_mode_overrides;
    const auto &_country_export_tax_overrides = worker ? worker->country_export_tax_overrides : this->_country_export_tax_overrides;
    const auto &_country_export_tax_mode_overrides = worker ? worker->country_export_tax_mode_overrides : this->_country_export_tax_mode_overrides;

    out.cell_country_slot = _cell_country_slot;
    const auto &active = worker ? worker->country_active : _countries.active;
    const auto &generations = worker ? worker->country_generation : _countries.generation;
    const auto &regime_ids = worker ? worker->country_political_regime_ids : _countries.political_regime_id;
    const auto &regime_caps = worker ? worker->country_political_regime_capabilities : _countries.political_regime_capability_bits;
    out.country_handles.resize(active.size());
    for (size_t slot = 0; slot < active.size(); ++slot)
        out.country_handles[slot] = active[slot] != 0
            ? (uint64_t{generations[slot]} << 32u) | static_cast<uint32_t>(slot) : 0;
    out.country_political_regime_ids = regime_ids;
    out.country_political_regime_capabilities = regime_caps;
    out.country_technologies = _country_technologies;
    out.country_research_signals = _country_research_signals;
    out.country_count = static_cast<int32_t>(active.size());
    out.technology_words = _technology_words;
    out.research_signal_words = worker
        ? static_cast<int32_t>(worker->research_signal_words)
        : _research_signal_words;
    out.research_signal_count = worker
        ? static_cast<int32_t>(worker->research_signal_count)
        : static_cast<int32_t>(_research_signal_ids.size());
    out.profession_count = static_cast<int32_t>(_profession_ids.size());
    out.good_count = static_cast<int32_t>(_good_ids.size());
    out.building_type_count =
        static_cast<int32_t>(_building_type_ids.size());
    auto resolve_all = [&](int32_t kind,
                           const std::vector<int32_t> &overrides,
                           const std::vector<int32_t> &mode_overrides,
                           std::vector<int32_t> &rates,
                           std::vector<int32_t> &modes) {
        const int32_t item_count = tax_item_count(kind);
        rates.resize(static_cast<size_t>(out.country_count) * item_count);
        modes.resize(static_cast<size_t>(out.country_count) * item_count);
        for (int32_t slot = 0; slot < out.country_count; ++slot) {
            for (int32_t item = 0; item < item_count; ++item) {
                const size_t index =
                    static_cast<size_t>(slot) * item_count + item;
                rates[index] = resolved_tax_rate(
                    _country_tax_defaults, overrides, slot, kind, item,
                    item_count);
                modes[index] = resolved_tax_mode(
                    _country_tax_default_modes, mode_overrides, slot, kind,
                    item, item_count);
            }
        }
    };
    resolve_all(TAX_INCOME, _country_income_tax_overrides,
                _country_income_tax_mode_overrides, out.income_tax_rates,
                out.income_tax_modes);
    resolve_all(TAX_CONSUMPTION, _country_consumption_tax_overrides,
                _country_consumption_tax_mode_overrides,
                out.consumption_tax_rates, out.consumption_tax_modes);
    resolve_all(TAX_BUSINESS, _country_business_tax_overrides,
                _country_business_tax_mode_overrides, out.business_tax_rates,
                out.business_tax_modes);
    resolve_all(TAX_IMPORT, _country_import_tax_overrides,
                _country_import_tax_mode_overrides, out.import_tax_rates,
                out.import_tax_modes);
    resolve_all(TAX_EXPORT, _country_export_tax_overrides,
                _country_export_tax_mode_overrides, out.export_tax_rates,
                out.export_tax_modes);
    out.cell_tax_policy_ids = _cell_tax_policy_ids;
    if (worker) {
        out.cell_tax_policies.clear();
        for (const auto &policy : worker->cell_tax_policies) {
            CellTaxPolicy row;
            row.defaults = policy.defaults;
            row.default_modes = policy.modes;
            for (const auto &v : policy.overrides)
                row.overrides.push_back({v.kind, v.item, v.rate, v.mode});
            out.cell_tax_policies.push_back(std::move(row));
        }
    } else {
        out.cell_tax_policies = _cell_tax_policies;
    }
    out.tax_policy_version = worker ? worker->generation : _tax_policy_version;
    out.generation = worker ? worker->generation : _generation;
    out.state_hash = worker ? worker->state_hash : compute_state_hash();
    return true;
}

} // namespace pk

#include "economy_runtime.h"
#include "country_api.h"
#include "economy_runtime_variant_helpers.h"
#include "effect_runtime.h"
#include "trigger_runtime.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <set>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {

using namespace godot;
using namespace variant_helpers;

#include "economy_runtime_queries_market_building_section_market.inc"

Dictionary NativeEconomyRuntime::fiscal_snapshot(int64_t country_handle) const {
    Dictionary out;
    const auto found = std::find(
        _epoch_country_handles.begin(), _epoch_country_handles.end(),
        static_cast<uint64_t>(country_handle));
    if (!_configured || found == _epoch_country_handles.end()) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured" :
            "country_handle_invalid";
        return out;
    }
    const int32_t country = static_cast<int32_t>(
        found - _epoch_country_handles.begin());
    PackedStringArray kinds;
    for (const char *kind : {"income", "consumption", "business",
                             "import", "export"})
        kinds.push_back(kind);
    const auto pack = [&](const std::vector<int64_t> &source) {
        PackedInt64Array values;
        values.resize(CountryApi::TAX_KIND_COUNT);
        for (int32_t kind = 0;
             kind < CountryApi::TAX_KIND_COUNT; ++kind) {
            const size_t index = static_cast<size_t>(country) *
                CountryApi::TAX_KIND_COUNT + kind;
            values[kind] = index < source.size() ? source[index] : 0;
        }
        return values;
    };
    const PackedInt64Array bases = pack(_fiscal_last_bases);
    const PackedInt64Array assessed = pack(_fiscal_last_assessed);
    const PackedInt64Array collected = pack(_fiscal_last_collected);
    const PackedInt64Array requests = pack(_fiscal_last_requests);
    const PackedInt64Array reserved = pack(_fiscal_last_reserved);
    const PackedInt64Array paid = pack(_fiscal_last_paid);
    const PackedInt64Array unmet = pack(_fiscal_last_unmet);
    PackedInt32Array fulfillment_q16;
    fulfillment_q16.resize(CountryApi::TAX_KIND_COUNT);
    for (int32_t kind = 0;
         kind < CountryApi::TAX_KIND_COUNT; ++kind) {
        fulfillment_q16[kind] = requests[kind] <= 0
            ? (reserved[kind] <= 0 ? 0 : Q16_ONE)
            : static_cast<int32_t>(std::clamp<int64_t>(
                (paid[kind] * Q16_ONE) / requests[kind], 0, Q16_ONE));
    }
    out["ok"] = true;
    out["country_handle"] = country_handle;
    out["sample_day"] = _sample_day;
    // Presentation may carry the previous settlement forward on idle days.
    // Use committed cell dates, never zero amounts: a completed settlement can
    // legitimately collect/pay zero. This also survives save restoration.
    bool has_settlement = false;
    for (size_t cell = 0; cell < _cell_last_settlement_day.size() &&
            cell < _epoch_cell_country.size(); ++cell) {
        if (_epoch_cell_country[cell] == country && _sample_day >= 0 &&
                _cell_last_settlement_day[cell] == _sample_day) {
            has_settlement = true;
            break;
        }
    }
    out["has_settlement"] = has_settlement;
    out["tax_policy_version"] = static_cast<int64_t>(
        _epoch_tax_policy_version);
    out["tax_kinds"] = kinds;
    out["tax_base"] = bases;
    out["assessed"] = assessed;
    out["collected"] = collected;
    out["subsidy_requested"] = requests;
    out["subsidy_reserved"] = reserved;
    out["subsidy_paid"] = paid;
    out["subsidy_unmet"] = unmet;
    out["fulfillment_q16"] = fulfillment_q16;
    out["cumulative_tax_base"] = pack(_fiscal_cumulative_bases);
    out["cumulative_collected"] = pack(_fiscal_cumulative_collected);
    out["cumulative_subsidy_requested"] =
        pack(_fiscal_cumulative_requests);
    out["cumulative_subsidy_paid"] = pack(_fiscal_cumulative_paid);
    // Non-tax treasury outflows for the same batch, in NonTaxOutflow order:
    // research procurement, expedition cargo, construction materials, canal
    // materials. All pay treasury cash to local merchants without being a tax
    // kind, so the UI sums them into 支出 and the 国库收支 net stays equal to the
    // treasury the player actually owns.
    PackedStringArray non_tax_kinds;
    for (const char *kind : {"research_purchase", "expedition_procurement",
                             "construction", "canal", "era_procurement"})
        non_tax_kinds.push_back(kind);
    PackedInt64Array non_tax_outflow;
    non_tax_outflow.resize(NativeEconomyRuntime::NON_TAX_KIND_COUNT);
    for (int32_t kind = 0; kind < NativeEconomyRuntime::NON_TAX_KIND_COUNT;
         ++kind) {
        const size_t index = static_cast<size_t>(country) *
            NativeEconomyRuntime::NON_TAX_KIND_COUNT + static_cast<size_t>(kind);
        non_tax_outflow[kind] = index < _fiscal_last_non_tax_outflow.size()
            ? _fiscal_last_non_tax_outflow[index] : 0;
    }
    out["non_tax_outflow_kinds"] = non_tax_kinds;
    out["non_tax_outflow"] = non_tax_outflow;
    const size_t import_summary = static_cast<size_t>(country) *
        CountryApi::TAX_KIND_COUNT + CountryApi::TAX_IMPORT;
    const size_t export_summary = static_cast<size_t>(country) *
        CountryApi::TAX_KIND_COUNT + CountryApi::TAX_EXPORT;
    const int64_t tariff_events =
        import_summary < _fiscal_last_events.size()
            ? _fiscal_last_events[import_summary] : 0;
    const int64_t export_events =
        export_summary < _fiscal_last_events.size()
            ? _fiscal_last_events[export_summary] : 0;
    PackedInt64Array tariff_event_counts;
    tariff_event_counts.resize(CountryApi::TAX_KIND_COUNT);
    tariff_event_counts[CountryApi::TAX_IMPORT] = tariff_events;
    tariff_event_counts[CountryApi::TAX_EXPORT] = export_events;
    out["tariff_event_counts"] = tariff_event_counts;
    out["tariff_events"] = tariff_events + export_events;
    out["tariffs_active"] = tariff_events > 0 || export_events > 0;
    return out;
}

Dictionary NativeEconomyRuntime::country_trade_snapshot(
        int64_t country_handle, const String &view, int32_t offset,
        int32_t limit) const {
    Dictionary out;
    if (_country_runtime == nullptr ||
        !country_reads().valid_handle(country_handle)) {
        out["ok"] = false;
        out["reason"] = "country_handle_invalid";
        return out;
    }
    const auto found = std::find(_epoch_country_handles.begin(),
        _epoch_country_handles.end(), static_cast<uint64_t>(country_handle));
    if (!_configured || found == _epoch_country_handles.end()) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured" :
            "country_handle_invalid";
        return out;
    }
    const int32_t country = static_cast<int32_t>(
        found - _epoch_country_handles.begin());
    const int32_t page_limit = std::clamp(limit, 1, 64);
    const int32_t page_offset = std::max(0, offset);
    out["ok"] = true;
    out["country_handle"] = country_handle;
    out["view"] = view;
    out["revision"] = static_cast<int64_t>(_country_trade_revision.get());
    if (view == "summary") {
        const auto fiscal_value = [&](int32_t kind, const std::vector<int64_t> &values) {
            const size_t index = static_cast<size_t>(country) *
                CountryApi::TAX_KIND_COUNT + kind;
            return index < values.size() ? values[index] : int64_t{0};
        };
        const int64_t imports = fiscal_value(CountryApi::TAX_IMPORT,
            _fiscal_last_bases);
        const int64_t exports = fiscal_value(CountryApi::TAX_EXPORT,
            _fiscal_last_bases);
        const int64_t tariff_income = fiscal_value(
            CountryApi::TAX_IMPORT, _fiscal_last_collected) +
            fiscal_value(CountryApi::TAX_EXPORT, _fiscal_last_collected) -
            fiscal_value(CountryApi::TAX_IMPORT, _fiscal_last_paid) -
            fiscal_value(CountryApi::TAX_EXPORT, _fiscal_last_paid);
        out["previous_import_base"] = imports;
        out["previous_export_base"] = exports;
        out["previous_net_export_base"] = exports - imports;
        out["previous_tariff_net_income"] = tariff_income;
        out["cumulative_import_base"] = fiscal_value(
            CountryApi::TAX_IMPORT, _fiscal_cumulative_bases);
        out["cumulative_export_base"] = fiscal_value(
            CountryApi::TAX_EXPORT, _fiscal_cumulative_bases);
        out["cumulative_tariff_net_income"] =
            fiscal_value(CountryApi::TAX_IMPORT,
                _fiscal_cumulative_collected) +
            fiscal_value(CountryApi::TAX_EXPORT,
                _fiscal_cumulative_collected) -
            fiscal_value(CountryApi::TAX_IMPORT,
                _fiscal_cumulative_paid) -
            fiscal_value(CountryApi::TAX_EXPORT,
                _fiscal_cumulative_paid);
        return out;
    }
    if (view == "goods") {
        std::vector<int32_t> fallback_rows;
        const std::vector<int32_t> *rows = nullptr;
        if (country < static_cast<int32_t>(_country_good_display_rows.size()) &&
            country < static_cast<int32_t>(_country_good_display_dirty.size()) &&
            _country_good_display_dirty[static_cast<size_t>(country)] == 0) {
            rows = &_country_good_display_rows[static_cast<size_t>(country)];
        } else {
            for (int32_t i = 0; i < static_cast<int32_t>(
                    _country_good_trade.countries.size()); ++i)
                if (_country_good_trade.countries[i] == country)
                    fallback_rows.push_back(i);
            std::sort(fallback_rows.begin(), fallback_rows.end(),
                [&](int32_t a, int32_t b) {
                    if (_country_good_trade.goods[a] !=
                            _country_good_trade.goods[b])
                        return _country_good_trade.goods[a] <
                            _country_good_trade.goods[b];
                    return a < b;
                });
            rows = &fallback_rows;
        }
        const int32_t total = static_cast<int32_t>(rows->size());
        const int32_t begin = std::min(page_offset, total);
        const int32_t end = std::min(total, begin + page_limit);
        PackedInt32Array goods;
        PackedInt64Array imports, exports, import_base, export_base,
            import_tariff, export_tariff, cumulative_imports,
            cumulative_exports, cumulative_import_base, cumulative_export_base,
            cumulative_import_tariff, cumulative_export_tariff;
        for (int32_t p = begin; p < end; ++p) {
            const int32_t i = (*rows)[static_cast<size_t>(p)];
            goods.push_back(_country_good_trade.goods[i]);
            const bool current_batch = i < static_cast<int32_t>(
                _country_good_trade.batch_epoch.size()) &&
                _country_good_trade.batch_epoch[i] == _epoch_id.get();
            imports.push_back(current_batch ?
                _country_good_trade.batch_import_quantity[i] : 0);
            exports.push_back(current_batch ?
                _country_good_trade.batch_export_quantity[i] : 0);
            import_base.push_back(current_batch ?
                _country_good_trade.batch_import_base[i] : 0);
            export_base.push_back(current_batch ?
                _country_good_trade.batch_export_base[i] : 0);
            import_tariff.push_back(current_batch ?
                _country_good_trade.batch_import_tariff[i] : 0);
            export_tariff.push_back(current_batch ?
                _country_good_trade.batch_export_tariff[i] : 0);
            cumulative_imports.push_back(_country_good_trade.import_quantity[i]);
            cumulative_exports.push_back(_country_good_trade.export_quantity[i]);
            cumulative_import_base.push_back(_country_good_trade.import_base[i]);
            cumulative_export_base.push_back(_country_good_trade.export_base[i]);
            cumulative_import_tariff.push_back(_country_good_trade.import_tariff[i]);
            cumulative_export_tariff.push_back(_country_good_trade.export_tariff[i]);
        }
        out["total"] = total;
        out["offset"] = begin;
        out["limit"] = page_limit;
        out["has_more"] = end < total;
        out["goods"] = goods;
        out["import_quantity"] = imports;
        out["export_quantity"] = exports;
        out["import_base"] = import_base;
        out["export_base"] = export_base;
        out["import_tariff"] = import_tariff;
        out["export_tariff"] = export_tariff;
        out["cumulative_import_quantity"] = cumulative_imports;
        out["cumulative_export_quantity"] = cumulative_exports;
        out["cumulative_import_base"] = cumulative_import_base;
        out["cumulative_export_base"] = cumulative_export_base;
        out["cumulative_import_tariff"] = cumulative_import_tariff;
        out["cumulative_export_tariff"] = cumulative_export_tariff;
        return out;
    }
    if (view == "partners") {
        std::vector<int32_t> fallback_rows;
        const std::vector<int32_t> *rows = nullptr;
        if (country < static_cast<int32_t>(
                _country_partner_display_rows.size()) &&
            country < static_cast<int32_t>(
                _country_partner_display_dirty.size()) &&
            _country_partner_display_dirty[static_cast<size_t>(country)] == 0) {
            rows = &_country_partner_display_rows[static_cast<size_t>(country)];
        } else {
            for (int32_t i = 0; i < static_cast<int32_t>(
                    _country_partner_trade.countries.size()); ++i)
                if (_country_partner_trade.countries[i] == country)
                    fallback_rows.push_back(i);
            std::sort(fallback_rows.begin(), fallback_rows.end(),
                [&](int32_t a, int32_t b) {
                    if (_country_partner_trade.partners[a] !=
                            _country_partner_trade.partners[b])
                        return _country_partner_trade.partners[a] <
                            _country_partner_trade.partners[b];
                    return a < b;
                });
            rows = &fallback_rows;
        }
        const int32_t total = static_cast<int32_t>(rows->size());
        const int32_t begin = std::min(page_offset, total);
        const int32_t end = std::min(total, begin + page_limit);
        PackedInt32Array partners;
        PackedInt64Array partner_handles;
        PackedInt64Array imports, exports, import_base, export_base, orders,
            cumulative_imports, cumulative_exports, cumulative_import_base,
            cumulative_export_base, cumulative_orders;
        for (int32_t p = begin; p < end; ++p) {
            const int32_t i = (*rows)[static_cast<size_t>(p)];
            partners.push_back(_country_partner_trade.partners[i]);
            const int32_t partner_slot = _country_partner_trade.partners[i];
            partner_handles.push_back(
                partner_slot >= 0 && partner_slot < static_cast<int32_t>(
                    _epoch_country_handles.size())
                    ? static_cast<int64_t>(_epoch_country_handles[partner_slot]) : 0);
            const bool current_batch = i < static_cast<int32_t>(
                _country_partner_trade.batch_epoch.size()) &&
                _country_partner_trade.batch_epoch[i] == _epoch_id.get();
            imports.push_back(current_batch ?
                _country_partner_trade.batch_import_quantity[i] : 0);
            exports.push_back(current_batch ?
                _country_partner_trade.batch_export_quantity[i] : 0);
            import_base.push_back(current_batch ?
                _country_partner_trade.batch_import_base[i] : 0);
            export_base.push_back(current_batch ?
                _country_partner_trade.batch_export_base[i] : 0);
            orders.push_back(current_batch ?
                _country_partner_trade.batch_order_count[i] : 0);
            cumulative_imports.push_back(_country_partner_trade.import_quantity[i]);
            cumulative_exports.push_back(_country_partner_trade.export_quantity[i]);
            cumulative_import_base.push_back(_country_partner_trade.import_base[i]);
            cumulative_export_base.push_back(_country_partner_trade.export_base[i]);
            cumulative_orders.push_back(_country_partner_trade.order_count[i]);
        }
        out["total"] = total;
        out["offset"] = begin;
        out["limit"] = page_limit;
        out["has_more"] = end < total;
        out["partners"] = partners;
        out["partner_handles"] = partner_handles;
        out["import_quantity"] = imports;
        out["export_quantity"] = exports;
        out["import_base"] = import_base;
        out["export_base"] = export_base;
        out["order_count"] = orders;
        out["cumulative_import_quantity"] = cumulative_imports;
        out["cumulative_export_quantity"] = cumulative_exports;
        out["cumulative_import_base"] = cumulative_import_base;
        out["cumulative_export_base"] = cumulative_export_base;
        out["cumulative_order_count"] = cumulative_orders;
        return out;
    }
    out["ok"] = false;
    out["reason"] = "country_trade_view_invalid";
    return out;
}


#include "economy_runtime_queries_market_building_section_building.inc"

Dictionary NativeEconomyRuntime::building_visual_snapshot(
        const PackedInt32Array &requested_cells) const {
    Dictionary out;
    out["ok"] = false;
    out["building_generation"] = static_cast<int64_t>(_building_visual_generation);
    if (!_bootstrapped) {
        out["reason"] = "economy_not_bootstrapped";
        return out;
    }
    std::vector<int32_t> cells;
    cells.reserve(static_cast<size_t>(requested_cells.size()));
    for (int64_t i = 0; i < requested_cells.size(); ++i) {
        const int32_t cell = requested_cells[i];
        if (cell < 0 || cell >= _cell_count.get()) {
            out["reason"] = "cell_out_of_range";
            out["invalid_cell"] = cell;
            return out;
        }
        cells.push_back(cell);
    }
    std::sort(cells.begin(), cells.end());
    cells.erase(std::unique(cells.begin(), cells.end()), cells.end());
    PackedInt32Array cell_indices;
    PackedInt32Array type_offsets;
    PackedInt32Array type_indices;
    PackedInt64Array counts;
    type_offsets.push_back(0);
    for (const int32_t cell : cells) {
        cell_indices.push_back(cell);
        const int32_t begin = _building_visual_cell_offsets.empty()
            ? 0 : _building_visual_cell_offsets[static_cast<size_t>(cell)];
        const int32_t end = _building_visual_cell_offsets.empty()
            ? 0 : _building_visual_cell_offsets[static_cast<size_t>(cell + 1)];
        for (int32_t row = begin; row < end; ++row) {
            type_indices.push_back(_building_visual_type_indices[static_cast<size_t>(row)]);
            counts.push_back(_building_visual_counts[static_cast<size_t>(row)]);
        }
        type_offsets.push_back(type_indices.size());
    }
    out["ok"] = true;
    out["cell_indices"] = cell_indices;
    out["type_offsets"] = type_offsets;
    out["type_indices"] = type_indices;
    out["counts"] = counts;
    append_building_visual_social_rows(cells, out);
    return out;
}

Dictionary NativeEconomyRuntime::consume_building_visual_dirty_cells() {
    Dictionary out;
    std::vector<int32_t> merged;
    {
        std::lock_guard<std::mutex> lock(_building_visual_outbox_mutex);
        merged.swap(_building_visual_outbox);
    }
    merged.insert(merged.end(), _building_visual_dirty_cells.begin(),
                  _building_visual_dirty_cells.end());
    std::sort(merged.begin(), merged.end());
    merged.erase(std::unique(merged.begin(), merged.end()), merged.end());
    _building_visual_dirty_cells.clear();
    PackedInt32Array cells;
    cells.resize(static_cast<int64_t>(merged.size()));
    for (int64_t i = 0; i < cells.size(); ++i)
        cells.set(i, merged[static_cast<size_t>(i)]);
    out["ok"] = _bootstrapped;
    out["building_generation"] = static_cast<int64_t>(_building_visual_generation);
    out["dirty_cells"] = cells;
    if (!_bootstrapped) out["reason"] = "economy_not_bootstrapped";
    return out;
}

Dictionary NativeEconomyRuntime::treasury_construction_quotes(
        int64_t country_handle, int32_t cell_idx,
        const PackedInt32Array &requested_type_ids) const {
    Dictionary out;
    out["ok"] = false;
    out["cell_idx"] = cell_idx;
    out["country_handle"] = country_handle;
    out["snapshot_day"] = _current_day.get();
    out["nonbinding"] = true;
    if (!_bootstrapped || _fatal || _country_runtime == nullptr) {
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            (_fatal ? "economy_fatal" : "country_runtime_required");
        return out;
    }
    if (cell_idx < 0 || cell_idx >= _cell_count.get() ||
        !country_reads().valid_handle(country_handle)) {
        out["reason"] = "construction_target_invalid";
        return out;
    }

    PackedInt32Array type_ids;
    PackedByteArray eligible;
    PackedStringArray reason_codes;
    PackedInt64Array cash_required;
    PackedInt64Array treasury_goods_total;
    PackedInt64Array market_goods_total;
    PackedInt32Array material_offsets;
    PackedInt32Array material_good_ids;
    PackedInt64Array material_required;
    PackedInt64Array material_treasury;
    PackedInt64Array material_market;
    PackedInt32Array material_prices;
    material_offsets.push_back(0);

    const int32_t market = market_store().cell_to_market[cell_idx];
    const bool owned = country_reads().country_handle_for_cell(cell_idx) == country_handle;
    const int32_t country_slot = country_reads().country_slot_for_cell(cell_idx);
    const bool treasury_capable = country_slot >= 0 &&
        country_slot < static_cast<int32_t>(_epoch_country_political_regime_capabilities.size()) &&
        (_epoch_country_political_regime_capabilities[static_cast<size_t>(country_slot)] &
         CountryApi::CAP_TREASURY_CONSTRUCTION) != 0;
    const int32_t cost_factor = country_slot >= 0 && country_slot <
            static_cast<int32_t>(_epoch_country_construction_cost_factor_q16.size())
        ? _epoch_country_construction_cost_factor_q16[country_slot] : Q16_ONE;
    std::vector<int64_t> country_stock(_good_ids.size(), 0);
    for (size_t good = 0; good < country_stock.size(); ++good) {
        country_stock[good] = std::max<int64_t>(0,
            country_reads().good_for_handle(country_handle,
                static_cast<int32_t>(good)));
    }

    for (int64_t cursor = 0; cursor < requested_type_ids.size(); ++cursor) {
        const int32_t type_id = requested_type_ids[cursor];
        type_ids.push_back(type_id);
        bool can_build = owned && treasury_capable;
        std::string reason = !owned ? "construction_cell_not_owned" :
            (!treasury_capable ? "political_regime_lacks_treasury_construction" : "ok");
        int64_t quote_cash = 0;
        int64_t quote_treasury = 0;
        int64_t quote_market = 0;
        int64_t quote_sat = 0;
        if (can_build && (type_id < 0 ||
                type_id >= static_cast<int32_t>(_building_types.size()))) {
            can_build = false;
            reason = "construction_target_invalid";
        }
        if (can_build && !building_available(cell_idx, type_id, false)) {
            can_build = false;
            reason = "construction_technology_locked";
        }
        if (can_build && !building_constructible(cell_idx, type_id, false)) {
            can_build = false;
            reason = "construction_obsolete";
        }
        if (can_build && !evaluate_building_conditions(type_id, cell_idx)) {
            can_build = false;
            reason = "construction_conditions_failed";
        }
        if (can_build && !family_free_building_resources_legal(
                cell_idx, type_id, 1)) {
            can_build = false;
            reason = "construction_resource_unavailable";
        }

        if (treasury_capable && type_id >= 0 && type_id < static_cast<int32_t>(_building_types.size())) {
            const BuildingType &type = _building_types[type_id];
            std::vector<int32_t> quote_good_ids;
            std::vector<int64_t> quote_required;
            quote_good_ids.reserve(type.construction_count);
            quote_required.reserve(type.construction_count);
            ConstructionMaterialPlan material_plan;
            const bool material_plan_ready = plan_construction_materials(
                cell_idx, type_id, 1, cost_factor, material_plan,
                &country_stock);
            if (!material_plan_ready && can_build) {
                can_build = false;
                reason = "construction_materials_insufficient";
            }
            if (material_plan_ready) {
                quote_good_ids = material_plan.good_ids;
                quote_required = material_plan.quantities;
            } else {
                // Keep a useful quote for locked/invalid entries using the
                // preferred legacy recipe; eligibility remains false above.
                for (int32_t edge = 0; edge < type.construction_count; ++edge) {
                    const GoodAmount &item = _building_construction_goods[
                        type.construction_begin + edge];
                    const int64_t required = std::max<int64_t>(1, mul_div_sat(
                        item.quantity, cost_factor, Q16_ONE, quote_sat));
                    auto found = std::find(quote_good_ids.begin(),
                                           quote_good_ids.end(), item.good_id);
                    if (found == quote_good_ids.end()) {
                        quote_good_ids.push_back(item.good_id);
                        quote_required.push_back(required);
                    } else {
                        const size_t index = static_cast<size_t>(
                            found - quote_good_ids.begin());
                        quote_required[index] = saturating_add(
                            quote_required[index], required, quote_sat);
                    }
                }
            }
            for (size_t item_index = 0; item_index < quote_good_ids.size();
                 ++item_index) {
                const int32_t good_id = quote_good_ids[item_index];
                const int64_t required = quote_required[item_index];
                const int64_t treasury = std::min<int64_t>(required,
                    std::max<int64_t>(0, country_reads().good_for_handle(
                        country_handle, good_id)));
                const int64_t shortfall = required - treasury;
                const int64_t local_stock = market >= 0 && market < market_store().market_count.get()
                    ? std::max<int64_t>(0, market_store().stock[
                        market_store().index(market, good_id)]) : 0;
                const int32_t price = market >= 0 && market < market_store().market_count.get()
                    ? market_store().price[market_store().index(market, good_id)] : 0;
                material_good_ids.push_back(good_id);
                material_required.push_back(required);
                material_treasury.push_back(treasury);
                material_market.push_back(shortfall);
                material_prices.push_back(price);
                quote_treasury = saturating_add(
                    quote_treasury, treasury, quote_sat);
                quote_market = saturating_add(
                    quote_market, shortfall, quote_sat);
                quote_cash = saturating_add(quote_cash, mul_div_sat(
                    shortfall, price, GOODS_SCALE, quote_sat), quote_sat);
                if (can_build && local_stock < shortfall) {
                    can_build = false;
                    reason = "construction_materials_insufficient";
                }
            }
        }
        if (can_build && quote_cash > 0 &&
            (_merchant_offsets.size() != static_cast<size_t>(_cell_count.get() + 1) ||
             _merchant_offsets[cell_idx] >= _merchant_offsets[cell_idx + 1])) {
            can_build = false;
            reason = "construction_market_unavailable";
        }
        if (can_build && country_reads().cash_for_handle(country_handle) < quote_cash) {
            can_build = false;
            reason = "construction_treasury_cash_insufficient";
        }
        eligible.push_back(can_build ? 1 : 0);
        reason_codes.push_back(String(reason.c_str()));
        cash_required.push_back(quote_cash);
        treasury_goods_total.push_back(quote_treasury);
        market_goods_total.push_back(quote_market);
        material_offsets.push_back(material_good_ids.size());
    }

    out["ok"] = true;
    out["type_ids"] = type_ids;
    out["eligible"] = eligible;
    out["reason_codes"] = reason_codes;
    out["cash_required"] = cash_required;
    out["treasury_goods_used"] = treasury_goods_total;
    out["market_goods_used"] = market_goods_total;
    out["material_offsets"] = material_offsets;
    out["material_good_ids"] = material_good_ids;
    out["material_required"] = material_required;
    out["material_treasury"] = material_treasury;
    out["material_market"] = material_market;
    out["material_prices"] = material_prices;
    return out;
}

Dictionary NativeEconomyRuntime::construction_command_receipts(
        int64_t after_receipt_id, int32_t limit, int64_t settled_day) const {
    Dictionary out;
    limit = std::clamp(limit, 1, 256);
    Array receipts;
    int64_t last_receipt_id = after_receipt_id;
    for (const ConstructionCommandReceipt &receipt :
         _committed_construction_receipts) {
        if (receipt.receipt_id <= after_receipt_id) continue;
        if (settled_day >= 0 && receipt.settled_day != settled_day) continue;
        Dictionary row;
        row["receipt_id"] = receipt.receipt_id;
        row["sequence"] = receipt.sequence;
        row["admitted"] = receipt.ok;
        if (receipt.ok) row["effective_day"] = receipt.effective_day;
        if (receipt.military_order) {
            row["command"] = receipt.demolishing
                ? "military.state.demolish" : "military.state.build";
            if (!receipt.ok) row["step"] = receipt.step;
        }
        row["settled_day"] = receipt.settled_day;
        row["country_handle"] = static_cast<int64_t>(receipt.country_handle);
        row["cell_idx"] = receipt.cell;
        row["type_id"] = receipt.type_id;
        row["ok"] = receipt.ok;
        row["code"] = String(receipt.code.c_str());
        row["cash_paid"] = receipt.cash_paid;
        row["treasury_goods_used"] = receipt.treasury_goods_used;
        row["market_goods_used"] = receipt.market_goods_used;
        receipts.push_back(row);
        last_receipt_id = receipt.receipt_id;
        if (settled_day < 0 && receipts.size() >= limit) break;
    }
    out["ok"] = true;
    out["receipts"] = receipts;
    out["count"] = receipts.size();
    out["last_receipt_id"] = last_receipt_id;
    return out;
}

#include "economy_runtime_queries_market_building_section_lineage.inc"

#include "economy_runtime_queries_market_building_section_notable_people.inc"



} // namespace pk

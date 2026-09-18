#include "economy_runtime.h"
#include "country_runtime.h"
#include "economy_runtime_persistence_codec.h"
#include "effect_runtime.h"
#include "modifier_runtime.h"
#include "runtime_economy_ecp2.h"

#include <algorithm>
#include <cstring>
#include <initializer_list>
#include <limits>
#include <unordered_map>
#include <unordered_set>

namespace pk {

using namespace godot;
using namespace persistence_codec;

namespace {
constexpr uint32_t OWNED_STATE_MAGIC = 0x414F534Fu; // "OSOA"
constexpr uint32_t OWNED_STATE_VERSION = 1u;

void owned_put_u32(std::vector<uint8_t> &out, uint32_t value) {
    for (int i = 0; i < 4; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
}
void owned_put_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (i * 8)) & 0xffu));
}
void owned_put_i64(std::vector<uint8_t> &out, int64_t value) {
    owned_put_u64(out, static_cast<uint64_t>(value));
}

uint64_t owned_fnv1a(const uint8_t *data, size_t size) {
    uint64_t hash = 1469598103934665603ull;
    for (size_t i = 0; i < size; ++i) {
        hash ^= static_cast<uint64_t>(data[i]);
        hash *= 1099511628211ull;
    }
    return hash;
}

bool append_owned_block(std::vector<uint8_t> &out, uint32_t id,
                        const std::vector<uint8_t> &payload) {
    owned_put_u32(out, id);
    owned_put_u32(out, static_cast<uint32_t>(payload.size()));
    out.insert(out.end(), payload.begin(), payload.end());
    return true;
}

void encode_owned_state_soa(const RuntimeEconomyLedgerState &ledger,
                            std::vector<uint8_t> &out) {
    out.clear();
    owned_put_u32(out, OWNED_STATE_MAGIC);
    owned_put_u32(out, OWNED_STATE_VERSION);
    owned_put_u64(out, ledger.ledger_hash);
    owned_put_u64(out, ledger.generation);
    owned_put_i64(out, ledger.committed_day);
    const size_t hash_at = out.size();
    owned_put_u64(out, 0u);
    std::vector<uint8_t> block;
    ledger.building.store.append_wire(block);
    append_owned_block(out, 1u, block);
    block.clear();
    ledger.trade_escrow.store.append_wire(block);
    append_owned_block(out, 2u, block);
    block.clear();
    ledger.family.store.append_wire(block);
    append_owned_block(out, 3u, block);
    block.clear();
    ledger.resource.store.append_wire(block);
    append_owned_block(out, 4u, block);
    block.clear();
    owned_put_u32(block, static_cast<uint32_t>(ledger.cohort_active.size()));
    for (size_t i = 0; i < ledger.cohort_active.size(); ++i) {
        block.push_back(ledger.cohort_active[i]);
        owned_put_u32(block, static_cast<uint32_t>(ledger.cohort_cell[i]));
        owned_put_u32(block, static_cast<uint32_t>(ledger.cohort_slot[i]));
        owned_put_u32(block, ledger.cohort_signature_id[i]);
        owned_put_u64(block, static_cast<uint64_t>(ledger.cohort_population[i]));
        owned_put_u64(block, static_cast<uint64_t>(ledger.cohort_funds[i]));
    }
    append_owned_block(out, 5u, block);
    block.clear();
    owned_put_u32(block, static_cast<uint32_t>(ledger.market_stock.size()));
    for (size_t i = 0; i < ledger.market_stock.size(); ++i) {
        owned_put_u64(block, static_cast<uint64_t>(ledger.market_stock[i]));
        owned_put_u32(block, static_cast<uint32_t>(ledger.market_price[i]));
        owned_put_u64(block, static_cast<uint64_t>(ledger.market_demand_ema[i]));
    }
    append_owned_block(out, 6u, block);
    const uint64_t hash = owned_fnv1a(out.data() + hash_at + 8u,
                                     out.size() - hash_at - 8u);
    for (int i = 0; i < 8; ++i)
        out[hash_at + static_cast<size_t>(i)] =
            static_cast<uint8_t>((hash >> (i * 8)) & 0xffu);
}

bool read_owned_u32(const uint8_t *data, size_t size, size_t &cursor,
                    uint32_t &value) {
    if (cursor > size || size - cursor < 4u) return false;
    value = static_cast<uint32_t>(data[cursor]) |
        (static_cast<uint32_t>(data[cursor + 1]) << 8u) |
        (static_cast<uint32_t>(data[cursor + 2]) << 16u) |
        (static_cast<uint32_t>(data[cursor + 3]) << 24u);
    cursor += 4u;
    return true;
}
bool read_owned_u64(const uint8_t *data, size_t size, size_t &cursor,
                    uint64_t &value) {
    if (cursor > size || size - cursor < 8u) return false;
    value = 0;
    for (int i = 0; i < 8; ++i)
        value |= static_cast<uint64_t>(data[cursor + static_cast<size_t>(i)]) <<
            (i * 8u);
    cursor += 8u;
    return true;
}
bool validate_owned_state_soa(const std::vector<uint8_t> &wire) {
    if (wire.size() < 40u) return false;
    size_t cursor = 0;
    uint32_t magic = 0, version = 0;
    uint64_t ignored = 0, expected_hash = 0;
    if (!read_owned_u32(wire.data(), wire.size(), cursor, magic) ||
        !read_owned_u32(wire.data(), wire.size(), cursor, version) ||
        !read_owned_u64(wire.data(), wire.size(), cursor, ignored) ||
        !read_owned_u64(wire.data(), wire.size(), cursor, ignored) ||
        !read_owned_u64(wire.data(), wire.size(), cursor, ignored) ||
        cursor > wire.size() - 8u ||
        !read_owned_u64(wire.data(), wire.size(), cursor, expected_hash) ||
        magic != OWNED_STATE_MAGIC || version != OWNED_STATE_VERSION) {
        return false;
    }
    const size_t hash_at = 32u;
    const uint64_t actual_hash = owned_fnv1a(
        wire.data() + hash_at + 8u, wire.size() - hash_at - 8u);
    if (actual_hash != expected_hash) return false;
    uint32_t seen = 0;
    while (cursor < wire.size()) {
        uint32_t id = 0, payload_size = 0;
        if (!read_owned_u32(wire.data(), wire.size(), cursor, id) ||
            !read_owned_u32(wire.data(), wire.size(), cursor, payload_size) ||
            id < 1u || id > 6u || (seen & (1u << id)) != 0u ||
            payload_size > wire.size() - cursor) return false;
        seen |= 1u << id;
        cursor += payload_size;
    }
    return cursor == wire.size() && seen == 0x7Eu;
}
} // namespace

Dictionary NativeEconomyRuntime::begin_save(int32_t chunk_bytes) {
    Dictionary out;
    if (_fiscal_reservation_continuation.active ||
        _epoch_begin_post_fiscal_pending) {
        out["ok"] = false;
        out["reason"] = "economy_save_fiscal_reservation_pending";
        out["country_cursor"] =
            _fiscal_reservation_continuation.country_cursor;
        out["country_count"] =
            _fiscal_reservation_continuation.country_count;
        out["day"] = _fiscal_reservation_continuation.day_index;
        out["phase"] = _fiscal_reservation_continuation.phase;
        out["last_requested"] =
            _fiscal_reservation_continuation.last_requested;
        out["last_reserved"] =
            _fiscal_reservation_continuation.last_reserved;
        out["last_error"] = String::utf8(
            _fiscal_reservation_continuation.last_error.c_str());
        out["epoch_begin_pending"] = _epoch_begin_post_fiscal_pending;
        return out;
    }
    if (_country_research_procurement_continuation.active) {
        out["ok"] = false;
        out["reason"] = "economy_save_research_procurement_pending";
        out["transaction_id"] = static_cast<int64_t>(
            _country_research_procurement_continuation.transaction_id);
        out["phase"] = _country_research_procurement_continuation.phase;
        return out;
    }
    if (_fiscal_settlement_continuation.active) {
        out["ok"] = false;
        out["reason"] = "economy_save_fiscal_settlement_pending";
        out["country_cursor"] = _fiscal_settlement_continuation.country_cursor;
        out["country_count"] = _fiscal_settlement_continuation.country_count;
        out["phase"] = _fiscal_settlement_continuation.phase;
        out["last_unused"] = _fiscal_settlement_continuation.last_unused;
        out["last_collected"] = _fiscal_settlement_continuation.last_collected;
        return out;
    }
    if (!_bootstrapped || _fatal || _save.active || _restore.active ||
        (_epoch_active && !_ecp2_allow_mid_epoch_export)) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped"
                         : (_epoch_active ? "save_requires_committed_boundary"
                         : (_fatal ? "economy_fatal" : "save_restore_already_active"));
        return out;
    }
    if (_country_runtime == nullptr || !_country_runtime->economy_available() ||
        _country_runtime->should_run(_last_committed_day)) {
        out["ok"] = false;
        out["reason"] = "save_requires_idle_country_runtime";
        return out;
    }
    const size_t cells = static_cast<size_t>(_cell_count);
    if (market_store().cell_to_market.size() != cells ||
        _environment_temperature_q16.size() != cells ||
        _environment_temperature_30d_q16.size() != cells ||
        _environment_moisture_q16.size() != cells ||
        _environment_plant_available_water_q16.size() != cells ||
        _environment_precipitation_q16.size() != cells ||
        _environment_snow_q16.size() != cells ||
        _environment_weather_q16.size() != cells ||
        _cell_last_settlement_day.size() != cells ||
        _birth_residual_q32.size() != cells * _ethnicity_ids.size() ||
        _cell_support_ema_q16.size() != cells ||
        _cell_food_output_eq_previous.size() != cells ||
        _cell_food_input_eq_previous.size() != cells ||
        _cell_food_import_eq_previous.size() != cells ||
        _cell_food_export_eq_previous.size() != cells ||
        _cell_food_access_eq_previous.size() != cells ||
        _cell_food_flow_valid.size() != cells ||
        _cell_settlement_generation.size() != cells ||
        _cell_price_stock_gen.size() != cells ||
        _cell_owner_cash_gen.size() != cells ||
        _cell_population_gen.size() != cells ||
        _cell_building_structure_gen.size() != cells ||
        _cell_technology_gen.size() != cells ||
        _cell_resource_gen.size() != cells ||
        _cell_trade_gen.size() != cells) {
        out["ok"] = false;
        out["reason"] = "economy_save_state_shape_invalid";
        return out;
    }
    // Sparse trade/fiscal tables are serialized by parallel columns.  Keep
    // the capture boundary fail-closed so a partially rebuilt aggregate can
    // never make the writer index past one of the newly added batch columns.
    const auto same_shape = [](std::initializer_list<size_t> sizes) {
        if (sizes.size() == 0) return true;
        const size_t expected = *sizes.begin();
        for (const size_t size : sizes) {
            if (size != expected) return false;
        }
        return true;
    };
    if (!same_shape({_tariff_history.countries.size(),
                     _tariff_history.kinds.size(),
                     _tariff_history.bases.size(),
                     _tariff_history.assessed.size(),
                     _tariff_history.collected.size(),
                     _tariff_history.requests.size(),
                     _tariff_history.reserved.size(),
                     _tariff_history.paid.size(),
                     _tariff_history.cumulative_bases.size(),
                     _tariff_history.cumulative_collected.size(),
                     _tariff_history.cumulative_requests.size(),
                     _tariff_history.cumulative_paid.size()}) ||
        !same_shape({_country_good_trade.countries.size(),
                     _country_good_trade.goods.size(),
                     _country_good_trade.import_quantity.size(),
                     _country_good_trade.export_quantity.size(),
                     _country_good_trade.import_base.size(),
                     _country_good_trade.export_base.size(),
                     _country_good_trade.import_tariff.size(),
                     _country_good_trade.export_tariff.size(),
                     _country_good_trade.batch_epoch.size(),
                     _country_good_trade.batch_import_quantity.size(),
                     _country_good_trade.batch_export_quantity.size(),
                     _country_good_trade.batch_import_base.size(),
                     _country_good_trade.batch_export_base.size(),
                     _country_good_trade.batch_import_tariff.size(),
                     _country_good_trade.batch_export_tariff.size()}) ||
        !same_shape({_country_partner_trade.countries.size(),
                     _country_partner_trade.partners.size(),
                     _country_partner_trade.import_quantity.size(),
                     _country_partner_trade.export_quantity.size(),
                     _country_partner_trade.import_base.size(),
                     _country_partner_trade.export_base.size(),
                     _country_partner_trade.order_count.size(),
                     _country_partner_trade.batch_epoch.size(),
                     _country_partner_trade.batch_import_quantity.size(),
                     _country_partner_trade.batch_export_quantity.size(),
                     _country_partner_trade.batch_import_base.size(),
                     _country_partner_trade.batch_export_base.size(),
                     _country_partner_trade.batch_order_count.size()})) {
        out["ok"] = false;
        out["reason"] = "economy_save_state_shape_invalid";
        return out;
    }
    NativeCountryRuntime::EconomySnapshot country_snapshot;
    if (!_country_runtime->copy_economy_snapshot(country_snapshot) ||
        country_snapshot.country_count < 0) {
        out["ok"] = false;
        out["reason"] = "economy_save_fiscal_country_snapshot_unavailable";
        return out;
    }
    const size_t fiscal_country_count = static_cast<size_t>(
        country_snapshot.country_count);
    if (!_fiscal_escrow_by_country.empty() &&
        _fiscal_escrow_by_country.size() != fiscal_country_count) {
        out["ok"] = false;
        out["reason"] = "economy_save_fiscal_escrow_shape_invalid";
        return out;
    }
    // A capture must not serialize need rows whose person was already retired,
    // because restore would prune them and change the row count.
    compact_person_needs();
    _save = {};
    _save.active = true;
    _save.chunk_bytes = std::clamp(chunk_bytes, 64 * 1024, 16 * 1024 * 1024);
    _save.fiscal_country_count = country_snapshot.country_count;
    std::string modifier_error;
    if (_modifier_runtime != nullptr &&
        !_modifier_runtime->serialize_domain(ModifierRuntime::ECONOMY,
                                              _save.modifier_bytes,
                                              modifier_error)) {
        _save = {};
        out["ok"] = false;
        out["reason"] = String(modifier_error.c_str());
        return out;
    }
    out["ok"] = true;
    out["chunk_bytes"] = _save.chunk_bytes;
    out["schema_version"] = SCHEMA_VERSION;
    out["catalog_hash"] = _catalog_hash;
    out["committed_day"] = _last_committed_day;
    return out;
}

Dictionary NativeEconomyRuntime::end_save() {
    Dictionary out;
    if (!_save.active) {
        out["ok"] = false;
        out["reason"] = "save_not_active";
        return out;
    }
    if (!_save.end_emitted) {
        out["ok"] = false;
        out["reason"] = "save_stream_not_fully_read";
        return out;
    }
    _save = {};
    out["ok"] = true;
    return out;
}

Dictionary NativeEconomyRuntime::begin_restore() {
    Dictionary out;
    if (!_configured || _epoch_active || _save.active || _restore.active ||
        _fiscal_reservation_continuation.active ||
        _epoch_begin_post_fiscal_pending ||
        _fiscal_settlement_continuation.active ||
        _country_research_procurement_continuation.active) {
        out["ok"] = false;
        out["reason"] = !_configured ? "configure_catalog_before_restore"
                         : (_fiscal_reservation_continuation.active ||
                            _epoch_begin_post_fiscal_pending
                             ? "restore_fiscal_reservation_pending"
                         : (_fiscal_settlement_continuation.active
                             ? "restore_fiscal_settlement_pending"
                         : (_country_research_procurement_continuation.active
                             ? "restore_research_procurement_pending"
                         : (_epoch_active ? "restore_requires_committed_boundary"
                             : "save_restore_already_active"))));
        if (_fiscal_reservation_continuation.active ||
            _epoch_begin_post_fiscal_pending) {
            out["country_cursor"] =
                _fiscal_reservation_continuation.country_cursor;
            out["country_count"] =
                _fiscal_reservation_continuation.country_count;
            out["day"] = _fiscal_reservation_continuation.day_index;
            out["phase"] = _fiscal_reservation_continuation.phase;
            out["epoch_begin_pending"] = _epoch_begin_post_fiscal_pending;
        } else if (_fiscal_settlement_continuation.active) {
            out["country_cursor"] =
                _fiscal_settlement_continuation.country_cursor;
            out["country_count"] =
                _fiscal_settlement_continuation.country_count;
            out["phase"] = _fiscal_settlement_continuation.phase;
            out["last_unused"] =
                _fiscal_settlement_continuation.last_unused;
            out["last_collected"] =
                _fiscal_settlement_continuation.last_collected;
        }
        return out;
    }
    _restore = {};
    _restore.active = true;
    _bootstrapped = false;
    population_store().clear(_cell_count);
    family_expeditions_store().clear();
    family_expedition_route_cells().clear();
    family_expedition_route_costs().clear();
    family_expedition_payloads().clear();
    family_expedition_person_handles().clear();
    family_expedition_cargo().clear();
    family_expedition_kit_buildings().clear();
    family_expedition_missing_good_ids().clear();
    family_expedition_missing_good_quantities().clear();
    _family_expedition_target_index.clear();
    _family_expedition_due_heap.clear();
    _colonization_receipts.clear();
    _birth_residual_q32.assign(
        static_cast<size_t>(_cell_count) * _ethnicity_ids.size(), 0);
    _settlements.clear(_cell_count);
    market_store().clear();
    _market_signals.clear(_cell_count);
    _labor_signals.clear(_cell_count);
    _trade_plan.clear_transient();
    _trade_signal_clock_keys.clear();
    _trade_signal_bulk_keys_scratch.clear();
    _trade_signal_first_seen_day.clear();
    _trade_signal_first_dispatch_day.clear();
    _trade_signal_last_attempt_day.clear();
    _trade_signal_last_rejection_reason.clear();
    _trade_signal_deadline_reported.clear();
    _trade_response_deadline_misses_cumulative = 0;
    trade_orders_store().clear();
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
    _structural_commands.clear();
    clear_building_groups();
    _building_handle_index_clean = false;
    _building_group_order_scratch.clear();
    _building_group_is_new_scratch.clear();
    _building_existing_indices_scratch.clear();
    _building_new_indices_scratch.clear();
    _building_investment_score_rebuild_scratch.clear();
    _building_investment_payback_rebuild_scratch.clear();
    _building_investment_rejection_rebuild_scratch.clear();
    _building_free_role_spans_by_type.assign(_building_types.size(), {});
    _building_cell_offsets.clear();
    _building_active_cells.clear();
    _building_employee_filled.clear();
    _building_last_input_selected_goods.clear();
    _building_role_contract_wage.clear();
    _building_role_base_living_cost.clear();
    _building_role_living_cost.clear();
    _building_role_local_average_wage.clear();
    _building_role_base_wage_due.clear();
    _building_role_base_wage_paid.clear();
    _building_role_bonus_due.clear();
    _building_role_bonus_paid.clear();
    _building_role_forecast_pay_ratio_q16.clear();
    clear_pending_construction();
    _canal_quotes.clear();
    _canal_quote_index.clear();
    _canal_projects.clear();
    _canal_project_index.clear();
    _canal_receipts.clear();
    _next_canal_quote_token = 1;
    _next_canal_project_id = 1;
    _next_canal_receipt_id = 1;
    _committed_cells.assign(_cell_count, {});
    _cell_last_settlement_day.assign(_cell_count, -ROLLING_PHASE_COUNT);
    _cell_settlement_generation.assign(_cell_count, 0);
    _cell_price_stock_gen.assign(_cell_count, 0);
    _cell_owner_cash_gen.assign(_cell_count, 0);
    _cell_population_gen.assign(_cell_count, 0);
    _cell_building_structure_gen.assign(_cell_count, 0);
    _cell_technology_gen.assign(_cell_count, 0);
    _cell_resource_gen.assign(_cell_count, 0);
    _cell_trade_gen.assign(_cell_count, 0);
    _cell_effect_shortage_q16.assign(_cell_count, 0);
    _cell_essentials_shortage_q16.assign(_cell_count, 0);
    _cell_resource_abundance_q16.assign(_cell_count, 0);
    _fiscal_previous_country_handles.assign(
        static_cast<size_t>(_cell_count), 0);
    _fiscal_previous_requests.assign(
        static_cast<size_t>(_cell_count) * ACTIVE_TAX_KIND_COUNT, 0);
    _fiscal_reservation_continuation = {};
    _fiscal_settlement_continuation = {};
    _asset_peer_journal.clear();
    _epoch_begin_post_fiscal_pending = false;
    _epoch_begin_pending_day = -1;
    _fiscal_last_events.clear();
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
    out["ok"] = true;
    out["schema_version"] = SCHEMA_VERSION;
    return out;
}

Dictionary NativeEconomyRuntime::feed_restore_chunk(const PackedByteArray &chunk) {
    Dictionary out;
    if (!_restore.active || _restore.failed || _restore.end_seen || chunk.is_empty()) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                                            : (_restore.end_seen ? "restore_end_already_seen"
                                                                 : "restore_chunk_empty"));
        return out;
    }
    std::vector<uint8_t> bytes(static_cast<size_t>(chunk.size()));
    std::memcpy(bytes.data(), chunk.ptr(), bytes.size());
    std::string error;
    if (!decode_restore_chunk(bytes, error)) {
        _restore.failed = true;
        _restore.error = error;
        out["ok"] = false;
        out["reason"] = String(error.c_str());
        return out;
    }
    out["ok"] = true;
    out["header_seen"] = _restore.header_seen;
    out["end_seen"] = _restore.end_seen;
    out["restored_pages"] = _restore.restored_pages;
    out["restored_markets"] = _restore.restored_markets;
    out["restored_cells"] = _restore.restored_cells;
    out["restored_commands"] = _restore.restored_commands;
    out["restored_audits"] = _restore.restored_audits;
    out["restored_signals"] = _restore.restored_signals;
    out["restored_labor_signals"] = _restore.restored_labor_signals;
    out["restored_trade_orders"] = _restore.restored_trade_orders;
    out["restored_trade_flows"] = _restore.restored_trade_flows;
    out["restored_persons"] = _restore.restored_persons;
    out["restored_person_needs"] = _restore.restored_person_needs;
    return out;
}

Dictionary NativeEconomyRuntime::end_restore() {
    Dictionary out;
    if (!_restore.active || _restore.failed || !_restore.header_seen || !_restore.end_seen) {
        out["ok"] = false;
        out["reason"] = !_restore.active ? "restore_not_active"
                         : (_restore.failed ? String(_restore.error.c_str())
                         : (!_restore.header_seen ? "restore_header_missing" : "restore_end_missing"));
        return out;
    }
    if (_restore.restored_pages != _restore.expected_pages ||
        _restore.restored_markets != market_store().market_count ||
        _restore.restored_cells != _cell_count ||
        _restore.restored_commands != _restore.expected_commands ||
        _restore.restored_buildings != _restore.expected_buildings ||
        _restore.restored_construction != _restore.expected_construction ||
        _restore.restored_audits != _restore.expected_audits ||
        _restore.restored_signals != _restore.expected_signals ||
        _restore.restored_labor_signals != _restore.expected_labor_signals ||
        _restore.restored_trade_orders != _restore.expected_trade_orders ||
        _restore.restored_trade_flows != _restore.expected_trade_flows ||
        (_restore.schema_version >= 33 &&
         (!_restore.tariff_history_seen ||
          _restore.restored_tariff_history != _restore.expected_tariff_history ||
          !_restore.country_good_seen ||
          _restore.restored_country_good != _restore.expected_country_good ||
          !_restore.country_partner_seen ||
          _restore.restored_country_partner != _restore.expected_country_partner)) ||
        (_restore.schema_version >= 34 &&
         (!_restore.canal_quotes_seen ||
          _restore.restored_canal_quotes != _restore.expected_canal_quotes ||
          !_restore.canal_projects_seen ||
          _restore.restored_canal_projects != _restore.expected_canal_projects)) ||
        (_restore.schema_version >= 20 && !_restore.modifier_seen) ||
        (_restore.schema_version >= 23 && !_restore.fiscal_seen) ||
        (_restore.schema_version >= 52 &&
         (_restore.expected_fiscal < 0 ||
          _restore.restored_fiscal != _restore.expected_fiscal ||
          !_restore.fiscal_peer_seen ||
          _restore.restored_fiscal_peer != _restore.expected_fiscal_peer)) ||
        (_restore.schema_version >= 52 && _restore.resource_stock_seen &&
         _restore.restored_resource_rows != _restore.expected_resource_rows) ||
        (_restore.schema_version >= 24 &&
         !_restore.settlement_names_seen) ||
        (_restore.schema_version >= 26 &&
         (!_restore.family_records_seen || !_restore.family_membership_seen ||
          !_restore.family_ownership_seen)) ||
        (_restore.schema_version >= 27 &&
         (!_restore.person_records_seen || !_restore.person_needs_seen ||
           _restore.restored_persons != _restore.expected_persons ||
           _restore.restored_person_needs !=
               _restore.expected_person_needs)) ||
        (_restore.schema_version >= 29 &&
         (!_restore.family_traits_seen || !_restore.family_influences_seen ||
          !_restore.family_trait_commands_seen ||
          _restore.restored_family_traits !=
              _restore.expected_family_traits ||
          _restore.restored_family_influences !=
              _restore.expected_family_influences ||
          _restore.restored_family_trait_commands !=
              _restore.expected_family_trait_commands))) {
        out["ok"] = false;
        out["reason"] = String("restore_section_incomplete pages=") + String::num_int64(_restore.restored_pages) + String("/") + String::num_int64(_restore.expected_pages) + String(" buildings=") + String::num_int64(_restore.restored_buildings) + String("/") + String::num_int64(_restore.expected_buildings) + String(" construction=") + String::num_int64(_restore.restored_construction) + String("/") + String::num_int64(_restore.expected_construction) + String(" trade_orders=") + String::num_int64(_restore.restored_trade_orders) + String("/") + String::num_int64(_restore.expected_trade_orders);
        out["expected_pages"] = _restore.expected_pages;
        out["restored_pages"] = _restore.restored_pages;
        out["expected_buildings"] = _restore.expected_buildings;
        out["restored_buildings"] = _restore.restored_buildings;
        out["expected_construction"] = _restore.expected_construction;
        out["restored_construction"] = _restore.restored_construction;
        out["expected_trade_orders"] = _restore.expected_trade_orders;
        out["restored_trade_orders"] = _restore.restored_trade_orders;
        out["expected_trade_flows"] = _restore.expected_trade_flows;
        out["restored_trade_flows"] = _restore.restored_trade_flows;
        out["expected_tariff_history"] = _restore.expected_tariff_history;
        out["restored_tariff_history"] = _restore.restored_tariff_history;
        out["expected_fiscal"] = _restore.expected_fiscal;
        out["restored_fiscal"] = _restore.restored_fiscal;
        return out;
    }
    if (!_restore.family_expeditions_seen ||
        _restore.restored_family_expedition_slots !=
            _restore.expected_family_expedition_slots ||
        _restore.restored_family_expeditions !=
            _restore.expected_family_expeditions) {
        out["ok"] = false;
        out["reason"] = "restore_family_expedition_section_incomplete";
        return out;
    }
    const auto trade_key = [](int32_t first, int32_t second) {
        return (static_cast<uint64_t>(static_cast<uint32_t>(first)) << 32) |
            static_cast<uint32_t>(second);
    };
    std::unordered_set<uint64_t> aggregate_keys;
    aggregate_keys.reserve(_country_good_trade.countries.size());
    for (size_t i = 0; i < _country_good_trade.countries.size(); ++i) {
        if (!aggregate_keys.emplace(trade_key(_country_good_trade.countries[i],
                _country_good_trade.goods[i])).second) {
            out["ok"] = false;
            out["reason"] = "restore_country_good_duplicate";
            return out;
        }
    }
    aggregate_keys.clear();
    aggregate_keys.reserve(_country_partner_trade.countries.size());
    for (size_t i = 0; i < _country_partner_trade.countries.size(); ++i) {
        if (!aggregate_keys.emplace(trade_key(
                _country_partner_trade.countries[i],
                _country_partner_trade.partners[i])).second) {
            out["ok"] = false;
            out["reason"] = "restore_country_partner_duplicate";
            return out;
        }
    }
    aggregate_keys.clear();
    aggregate_keys.reserve(_tariff_history.countries.size());
    for (size_t i = 0; i < _tariff_history.countries.size(); ++i) {
        if (!aggregate_keys.emplace(trade_key(_tariff_history.countries[i],
                _tariff_history.kinds[i])).second) {
            out["ok"] = false;
            out["reason"] = "restore_tariff_history_duplicate";
            return out;
        }
    }
    uint64_t restored_environment_hash = 1469598103934665603ULL;
    auto mix_environment_q16 = [&](uint32_t value) {
        for (int32_t byte = 0; byte < 4; ++byte) {
            restored_environment_hash ^= static_cast<uint8_t>(
                (value >> (byte * 8)) & 0xffU);
            restored_environment_hash *= 1099511628211ULL;
        }
    };
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        const int32_t values[] = {
            _environment_temperature_q16[cell],
            _environment_temperature_30d_q16[cell],
            _environment_moisture_q16[cell],
            _environment_plant_available_water_q16[cell],
            _environment_precipitation_q16[cell],
            _environment_snow_q16[cell],
            _environment_weather_q16[cell],
        };
        for (int32_t value : values) {
            if (value < 0 || value > Q16_ONE) {
                out["ok"] = false;
                out["reason"] = "restore_environment_value_invalid";
                return out;
            }
            mix_environment_q16(static_cast<uint32_t>(value));
        }
    }
    const int64_t computed_environment_hash = static_cast<int64_t>(
        (restored_environment_hash & 0x7fffffffffffffffULL) | 1ULL);
    if (computed_environment_hash != _environment_hash) {
        out["ok"] = false;
        out["reason"] = "restore_environment_hash_mismatch";
        out["expected_environment_hash"] = _environment_hash;
        out["computed_environment_hash"] = computed_environment_hash;
        return out;
    }
    const size_t expected_population_slots =
        population_store().page_next.size() * static_cast<size_t>(COHORT_PAGE_SIZE);
    if (population_store().active.size() != expected_population_slots ||
        population_store().reserved.size() != expected_population_slots ||
        population_store().reservation_owner.size() != expected_population_slots ||
        population_store().signature_id.size() != expected_population_slots ||
        population_store().generation.size() != expected_population_slots ||
        population_store().population.size() != expected_population_slots ||
        population_store().funds.size() != expected_population_slots) {
        out["ok"] = false;
        out["reason"] = "restore_population_lane_shape_invalid";
        return out;
    }
    std::vector<uint8_t> referenced(population_store().page_next.size(), 0);
    int64_t actual_active = 0;
    for (int32_t page = 0; page < static_cast<int32_t>(population_store().page_next.size()); ++page) {
        const int32_t cell = population_store().page_cell[page];
        const int32_t next = population_store().page_next[page];
        if (cell < -1 || cell >= _cell_count || next < -1 ||
            next >= static_cast<int32_t>(population_store().page_next.size()) ||
            (next >= 0 && population_store().page_cell[next] != cell)) {
            out["ok"] = false;
            out["reason"] = "restore_page_chain_invalid";
            return out;
        }
        if (next >= 0) referenced[next] = 1;
        if (cell < 0) population_store().free_pages.push_back(page);
        const int32_t base = page * COHORT_PAGE_SIZE;
        for (int32_t lane = 0; lane < COHORT_PAGE_SIZE; ++lane) {
            const int32_t slot = base + lane;
            if (population_store().active[slot] == 0) continue;
            if (cell < 0 || population_store().signature_id[slot] >= _signatures.size() ||
                population_store().generation[slot] == 0 || population_store().population[slot] <= 0 ||
                population_store().funds[slot] < 0) {
                out["ok"] = false;
                out["reason"] = "restore_cohort_record_invalid";
                return out;
            }
            ++actual_active;
        }
    }
    population_store().cell_first_page.assign(_cell_count, -1);
    for (int32_t page = 0; page < static_cast<int32_t>(population_store().page_next.size()); ++page) {
        const int32_t cell = population_store().page_cell[page];
        if (cell < 0 || referenced[page] != 0) continue;
        if (population_store().cell_first_page[cell] >= 0) {
            out["ok"] = false;
            out["reason"] = "restore_multiple_page_chain_heads";
            return out;
        }
        population_store().cell_first_page[cell] = page;
    }
    std::vector<uint8_t> visited(population_store().page_next.size(), 0);
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        int32_t steps = 0;
        for (int32_t page = population_store().cell_first_page[cell]; page >= 0;
             page = population_store().page_next[page]) {
            if (++steps > static_cast<int32_t>(population_store().page_next.size()) || visited[page] != 0) {
                out["ok"] = false;
                out["reason"] = "restore_page_chain_cycle";
                return out;
            }
            visited[page] = 1;
        }
    }
    for (int32_t page = 0; page < static_cast<int32_t>(population_store().page_next.size()); ++page) {
        if (population_store().page_cell[page] >= 0 && visited[page] == 0) {
            out["ok"] = false;
            out["reason"] = "restore_unreachable_page";
            return out;
        }
    }
    if (actual_active != population_store().active_count) {
        out["ok"] = false;
        out["reason"] = "restore_active_count_mismatch";
        return out;
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (market_store().cell_to_market[cell] < 0 || market_store().cell_to_market[cell] >= market_store().market_count) {
            out["ok"] = false;
            out["reason"] = "restore_cell_market_invalid";
            return out;
        }
        std::vector<uint32_t> signatures;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            signatures.push_back(population_store().signature_id[slot]);
        });
        std::sort(signatures.begin(), signatures.end());
        if (std::adjacent_find(signatures.begin(), signatures.end()) != signatures.end()) {
            out["ok"] = false;
            out["reason"] = "restore_duplicate_cell_signature";
            return out;
        }
    }
    for (int32_t market = 0; market < market_store().market_count; ++market) {
        for (int32_t good = 0; good < market_store().good_count; ++good) {
            const int64_t idx = market_store().index(market, good);
            if (market_store().stock[idx] < 0 || market_store().demand_ema[idx] < 0 ||
                market_store().price[idx] < PRICE_NUMERIC_GUARD_MIN ||
                market_store().price[idx] > PRICE_NUMERIC_GUARD_MAX) {
                out["ok"] = false;
                out["reason"] = "restore_market_value_invalid";
                return out;
            }
        }
    }
    std::string market_range_error;
    if (!rebuild_market_cell_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }
    int64_t restore_merchant_repairs = 0;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (!ensure_merchant_invariant(cell, restore_merchant_repairs, market_range_error)) {
            out["ok"] = false;
            out["reason"] = String(market_range_error.c_str());
            return out;
        }
    }
    if (!rebuild_merchant_ranges(market_range_error)) {
        out["ok"] = false;
        out["reason"] = String(market_range_error.c_str());
        return out;
    }
    for (const Command &cmd : _pending_commands) {
        int32_t slot = -1;
        const bool market_target = cmd.opcode == COMMAND_ADD_STOCK ||
            cmd.opcode == COMMAND_REMOVE_STOCK ||
            cmd.opcode == COMMAND_COUNTRY_GOOD_TO_MARKET ||
            cmd.opcode == COMMAND_MARKET_GOOD_TO_COUNTRY;
        const bool family_reward = is_family_ledger_command(cmd.opcode);
        const bool split_policy = cmd.opcode == COMMAND_FAMILY_SET_SPLIT_POLICY;
        const bool treasury_build =
            cmd.opcode == COMMAND_TREASURY_SPONSORED_BUILD;
        const bool canal_build = cmd.opcode == COMMAND_BUILD_CANAL;
        const bool expedition_player =
            cmd.opcode == COMMAND_START_FAMILY_EXPEDITION ||
            cmd.opcode == COMMAND_CANCEL_FAMILY_EXPEDITION;
        int32_t family = -1;
        int32_t expedition = -1;
        const bool target_ok = family_reward
            ? family_ledger_command_preflight(cmd)
            : split_policy
            ? family_split_policy_command_preflight(cmd)
            : treasury_build
            ? (_country_runtime != nullptr && _country_runtime->valid_handle(
                   static_cast<int64_t>(cmd.target_handle)) &&
               cmd.i32_0 >= 0 && cmd.i32_0 < _cell_count &&
               cmd.i32_1 >= 0 && cmd.i32_1 < static_cast<int32_t>(
                   _building_types.size()) && cmd.i64_0 == 1 &&
               cmd.i64_1 == OWNERSHIP_TREASURY_SPONSORED_PRIVATE)
            : canal_build
            ? (_country_runtime != nullptr && _country_runtime->valid_handle(
                   static_cast<int64_t>(cmd.target_handle)) && cmd.i64_0 > 0)
            : expedition_player
            ? (cmd.opcode == COMMAND_START_FAMILY_EXPEDITION
                ? (families_store().valid_handle(cmd.target_handle, family) &&
                   cmd.i32_0 >= 0 && cmd.i32_0 < _cell_count &&
                   cmd.i32_1 >= 0 && cmd.i32_1 < _cell_count &&
                   cmd.i64_0 >= 1)
                : family_expeditions_store().valid_handle(cmd.target_handle, expedition))
            : market_target
            ? (cmd.i32_0 >= 0 && cmd.i32_0 < market_store().market_count &&
               cmd.i32_1 >= 0 && cmd.i32_1 < market_store().good_count &&
               ((cmd.opcode != COMMAND_COUNTRY_GOOD_TO_MARKET &&
                 cmd.opcode != COMMAND_MARKET_GOOD_TO_COUNTRY) ||
                (_country_runtime != nullptr && _country_runtime->valid_handle(
                    static_cast<int64_t>(cmd.target_handle)))))
            : population_store().valid_handle(cmd.target_handle, slot);
        const bool opcode_ok =
            (cmd.opcode >= COMMAND_TRANSFER_TO_COHORT &&
             cmd.opcode <= COMMAND_BUILD_CANAL) ||
            family_reward || split_policy;
        if (!opcode_ok ||
            !target_ok || cmd.effective_day < 0 || cmd.sequence < 0 ||
            (cmd.i64_0 < 0 && cmd.opcode != COMMAND_ADD_POPULATION &&
             cmd.opcode != COMMAND_FAMILY_PURCHASE_DISCOUNT &&
             cmd.opcode != COMMAND_FAMILY_ABSORB_ANONYMOUS)) {
            out["ok"] = false;
            out["reason"] = "restore_command_invalid";
            return out;
        }
    }
    for (size_t pk_row = 0; pk_row < building_count(); ++pk_row) {
        const auto group = building_at(pk_row);
        if (_signatures[group.owner_signature_id].profession_id !=
                _building_types[group.type_id].owner_profession_id ||
            group.filled_owner < 0 || group.filled_owner >
                group.count * _building_types[group.type_id].owner_slots_per_building ||
            group.last_input_cost < 0 || group.last_wages_paid < 0 ||
            group.last_wages_due < 0 || group.last_expected_revenue < 0 ||
            group.last_operating_cost < 0 || group.planned_utilization_q16 < 0 ||
            group.planned_utilization_q16 > Q16_ONE ||
            group.last_resource_generated < 0 ||
            group.last_base_wages_paid < 0 || group.last_base_wages_due < 0 ||
            group.last_bonus_paid < 0 || group.last_bonus_due < 0 ||
            group.last_base_wages_paid > group.last_base_wages_due ||
            group.last_bonus_paid > group.last_bonus_due ||
            group.wage_suspended > 1 || group.operating_state > 1 ||
            (group.pending_operating_state > 1 && group.pending_operating_state != 255) ||
            group.merchant_debt_principal < 0 || group.merchant_debt_premium < 0 ||
            group.last_in_kind_livelihood_value < 0 ||
            group.last_temperature_fit_q16 < 0 ||
            group.last_temperature_fit_q16 > Q16_ONE ||
            group.last_water_fit_q16 < 0 ||
            group.last_water_fit_q16 > Q16_ONE ||
            group.last_climate_capacity_q16 < 0 ||
            group.last_climate_capacity_q16 > Q16_ONE ||
            group.last_climate_lost_output < 0 ||
            ((group.merchant_debt_principal > 0 || group.merchant_debt_premium > 0) &&
             group.merchant_debt_term_cycles_left == 0 &&
             group.merchant_debt_delinquent_cycles == 0) ||
            group.purchase_intent_capacity_q16 < 0 ||
            group.purchase_intent_capacity_q16 > Q16_ONE) {
            out["ok"] = false;
            out["reason"] = "restore_building_owner_or_job_invalid";
            return out;
        }
        const BuildingType &type = _building_types[group.type_id];
        if (group.last_input_selection_begin < 0 ||
            static_cast<size_t>(group.last_input_selection_begin) +
                    static_cast<size_t>(type.input_count) >
                _building_last_input_selected_goods.size()) {
            out["ok"] = false;
            out["reason"] = "restore_building_input_selection_span_invalid";
            return out;
        }
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const int32_t role_index = group.employee_fill_begin + r;
            if (role_index < 0 ||
                role_index >= static_cast<int32_t>(_building_role_contract_wage.size()) ||
                _building_role_contract_wage[role_index] < 0 ||
                _building_role_base_living_cost[role_index] < 0 ||
                _building_role_living_cost[role_index] < 0 ||
                _building_role_local_average_wage[role_index] < 0 ||
                _building_role_base_wage_paid[role_index] < 0 ||
                _building_role_base_wage_due[role_index] <
                    _building_role_base_wage_paid[role_index] ||
                _building_role_bonus_paid[role_index] < 0 ||
                _building_role_bonus_due[role_index] <
                    _building_role_bonus_paid[role_index]) {
                out["ok"] = false;
                out["reason"] = "restore_building_role_wage_invalid";
                return out;
            }
            const int64_t filled = _building_employee_filled[role_index];
            const int64_t required = group.count *
                _building_employee_roles[type.employee_begin + r].slots_per_building;
            if (filled < 0 || filled > required) {
                out["ok"] = false;
                out["reason"] = "restore_building_employee_job_invalid";
                return out;
            }
        }
    }
    for (size_t slot = 0; slot < population_store().active.size(); ++slot) {
        if (population_store().active[slot] == 0) continue;
        if (population_store().owner_employed[slot] < 0 || population_store().employee_employed[slot] < 0 ||
            population_store().owner_employed[slot] + population_store().employee_employed[slot] >
                population_store().population[slot]) {
            out["ok"] = false;
            out["reason"] = "restore_cohort_employment_invalid";
            return out;
        }
    }
    rebuild_building_cell_offsets();
    _pending_building_topology_rebuild = false;
    if (_auto_slice_by_scale)
        _cells_per_slice = std::clamp(market_store().market_count, 1, 128);
    if (_auto_building_slice_by_scale)
        _building_cells_per_slice = AUTO_BUILDING_CELLS_PER_SLICE;
    refresh_cadence_estimates();
    if (_restore.schema_version < 38)
        synthesize_cadence_locks_from_legacy_save();
    _commit_lag_budget_days = std::max(0, locked_market_cycle_days() - 1);
    if (_restore.schema_version < 15) {
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            const int64_t phase = cell % ROLLING_PHASE_COUNT;
            const int64_t delta = ((_last_committed_day - phase) %
                ROLLING_PHASE_COUNT + ROLLING_PHASE_COUNT) %
                ROLLING_PHASE_COUNT;
            _cell_last_settlement_day[cell] = _last_committed_day - delta;
        }
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _market_signals.cell_offsets[cell + 1] += _market_signals.cell_offsets[cell];
    // PKEC stores the committed signal rows, including zero-valued rows that
    // keep the stable CSR shape. Rebuild only derived lookups here; the
    // topology rebuild intentionally prunes rows and would change restored
    // authority before the next committed building-structure update.
    rebuild_market_signal_lookup();
    rebuild_production_input_reserves();
    _market_signal_force_full = false;
    _labor_signal_force_full = false;
    _input_reserve_force_full = false;
    _market_signal_full_rebuild_reason = "save_restore";
    _labor_signal_full_rebuild_reason = "save_restore";
    _input_reserve_full_rebuild_reason = "save_restore";
    if (_cell_count > 0) {
        _market_signal_cell_dirty.assign(static_cast<size_t>(_cell_count), 0);
        _labor_signal_cell_dirty.assign(static_cast<size_t>(_cell_count), 0);
        _input_reserve_cell_dirty.assign(static_cast<size_t>(_cell_count), 0);
    }
    for (int32_t cell = 0; cell < _cell_count; ++cell)
        _labor_signals.cell_offsets[cell + 1] += _labor_signals.cell_offsets[cell];
    std::string country_restore_error;
    if (!capture_country_epoch(country_restore_error)) {
        out["ok"] = false;
        out["reason"] = country_restore_error.c_str();
        return out;
    }
    for (const int32_t country : _tariff_history.countries) {
        if (country < 0 || country >= _epoch_country_count) {
            out["ok"] = false;
            out["reason"] = "restore_tariff_history_country_invalid";
            return out;
        }
    }
    for (const int32_t country : _country_good_trade.countries) {
        if (country < 0 || country >= _epoch_country_count) {
            out["ok"] = false;
            out["reason"] = "restore_country_good_country_invalid";
            return out;
        }
    }
    for (size_t row = 0; row < _country_partner_trade.countries.size(); ++row) {
        const int32_t country = _country_partner_trade.countries[row];
        const int32_t partner = _country_partner_trade.partners[row];
        if (country < 0 || country >= _epoch_country_count || partner < 0 ||
            partner >= _epoch_country_count || country == partner) {
            out["ok"] = false;
            out["reason"] = "restore_country_partner_country_invalid";
            return out;
        }
    }
    if ((!trade_orders_store().ids.empty() &&
         trade_orders_store().next_id <= trade_orders_store().ids.back()) ||
        trade_orders_store().line_offsets.size() != trade_orders_store().ids.size() + 1 ||
        trade_orders_store().seller_offsets.size() != trade_orders_store().ids.size() + 1) {
        out["ok"] = false;
        out["reason"] = "restore_trade_order_index_invalid";
        return out;
    }
    if (_restore.schema_version >= 20 && !_restore.modifier_bytes.empty()) {
        if (_modifier_runtime == nullptr) {
            out["ok"] = false;
            out["reason"] = "economy_restore_modifier_runtime_unavailable";
            return out;
        }
        std::string modifier_restore_error;
        if (!_modifier_runtime->restore_domain(ModifierRuntime::ECONOMY,
                                               _restore.modifier_bytes,
                                               modifier_restore_error,
                                               _restore.schema_version == 22)) {
            out["ok"] = false;
            out["reason"] = String(("economy_restore_modifier_failed:" +
                                    modifier_restore_error).c_str());
            return out;
        }
    } else if (_modifier_runtime != nullptr) {
        _modifier_runtime->clear_domain(ModifierRuntime::ECONOMY);
    }
    if (_modifier_runtime != nullptr) refresh_building_modifier_factors();
    {
        std::unordered_set<int64_t> stable_family_ids;
        std::unordered_set<uint64_t> visible_family_names;
        for (int32_t i = 0; i < static_cast<int32_t>(families_store().active.size()); ++i) {
            if (families_store().active[i] == 0) continue;
            const uint64_t visible_key =
                (static_cast<uint64_t>(static_cast<uint32_t>(
                    families_store().surname_id[i])) << 32) |
                families_store().surname_disambiguator[i];
            if (!stable_family_ids.insert(families_store().stable_id[i]).second ||
                !visible_family_names.insert(visible_key).second) {
                out["ok"] = false;
                out["reason"] = "restore_family_identity_duplicate";
                return out;
            }
        }
        std::vector<int64_t> member_people(population_store().active.size(), 0);
        std::vector<int64_t> member_cash(population_store().active.size(), 0);
        for (const FamilyMembershipEdge &edge : family_memberships()) {
            int32_t slot = -1;
            if (!population_store().valid_handle(edge.cohort_handle, slot)) {
                out["ok"] = false;
                out["reason"] = "restore_family_cohort_handle_invalid";
                return out;
            }
            if (edge.people > population_store().population[slot] -
                    member_people[slot] ||
                edge.cash_claim > population_store().funds[slot] -
                    member_cash[slot]) {
                out["ok"] = false;
                out["reason"] = "restore_family_claim_exceeds_cohort";
                return out;
            }
            member_people[slot] += edge.people;
            member_cash[slot] += edge.cash_claim;
        }
        // Saves written before ownership clamping could carry shares granted
        // ahead of a liquidation or owner-slot change. Repair them instead of
        // rejecting an otherwise loadable world; handles stay authoritative.
        sanitize_family_ownership_edges();
        std::vector<int64_t> owned(building_count(), 0);
        for (const FamilyBuildingOwnership &edge : family_ownerships()) {
            const int32_t group = building_index_for_handle(edge.building_handle);
            if (group < 0) {
                out["ok"] = false;
                out["reason"] = "restore_family_building_handle_invalid";
                return out;
            }
            if (edge.owned_count > buildings_store().group_units[group] - owned[group]) {
                out["ok"] = false;
                out["reason"] = "restore_family_ownership_exceeds_building";
                return out;
            }
            owned[group] += edge.owned_count;
            int64_t capacity_sat = 0;
            const int64_t owner_capacity = saturating_mul(edge.owned_count,
                _building_types[buildings_store().type_id[group]].owner_slots_per_building,
                capacity_sat);
            if (capacity_sat != 0 ||
                edge.filled_owner > owner_capacity) {
                out["ok"] = false;
                out["reason"] = "restore_family_ownership_exceeds_building";
                return out;
            }
        }
        for (const auto pending : pending_construction()) {
            int32_t family = -1;
            if (pending.sponsor_family_handle != 0 &&
                !families_store().valid_handle(pending.sponsor_family_handle, family)) {
                out["ok"] = false;
                out["reason"] = "restore_construction_family_handle_invalid";
                return out;
            }
        }
        std::unordered_map<uint64_t, std::unordered_set<int32_t>> traits_by_family;
        std::unordered_map<uint64_t, int32_t> core_traits_by_family;
        uint64_t previous_trait_family = 0;
        int32_t previous_trait = -1;
        bool first_trait = true;
        for (const FamilyTraitRoll &roll : family_trait_rolls()) {
            if (!first_trait &&
                (roll.family_handle < previous_trait_family ||
                 (roll.family_handle == previous_trait_family &&
                  roll.trait_id <= previous_trait))) {
                out["ok"] = false;
                out["reason"] = "restore_family_trait_order_or_duplicate_invalid";
                return out;
            }
            first_trait = false;
            previous_trait_family = roll.family_handle;
            previous_trait = roll.trait_id;
            traits_by_family[roll.family_handle].insert(roll.trait_id);
            if (roll.core != 0) {
                if (_family_trait_core_eligible[roll.trait_id] == 0) {
                    out["ok"] = false;
                    out["reason"] = "restore_family_core_trait_ineligible";
                    return out;
                }
                ++core_traits_by_family[roll.family_handle];
            }
        }
        for (int32_t family = 0; family < static_cast<int32_t>(
                 families_store().active.size()); ++family) {
            if (families_store().active[family] == 0) continue;
            const uint64_t family_handle = families_store().handle_for_index(family);
            const int32_t core_count = core_traits_by_family[family_handle];
            if (core_count < _family_core_trait_min ||
                core_count > _family_core_trait_max) {
                out["ok"] = false;
                out["reason"] = "restore_family_core_trait_count_invalid";
                return out;
            }
            const auto found_traits = traits_by_family.find(family_handle);
            if (found_traits == traits_by_family.end()) continue;
            const std::unordered_set<int32_t> &family_traits =
                found_traits->second;
            for (int32_t trait_id : family_traits) {
                for (int32_t p = _family_trait_prerequisite_offsets[trait_id];
                     p < _family_trait_prerequisite_offsets[trait_id + 1]; ++p) {
                    if (family_traits.find(_family_trait_prerequisites[p]) ==
                            family_traits.end()) {
                        out["ok"] = false;
                        out["reason"] =
                            "restore_family_trait_prerequisite_missing";
                        return out;
                    }
                }
                for (int32_t p = _family_trait_exclusion_offsets[trait_id];
                     p < _family_trait_exclusion_offsets[trait_id + 1]; ++p) {
                    if (family_traits.find(_family_trait_exclusions[p]) !=
                            family_traits.end()) {
                        out["ok"] = false;
                        out["reason"] = "restore_family_trait_conflict";
                        return out;
                    }
                }
            }
        }
        std::unordered_set<uint64_t> family_cells;
        std::unordered_set<int64_t> branch_stable_ids;
        for (int32_t branch = 0; branch < static_cast<int32_t>(
                 family_influences().active.size()); ++branch) {
            if (family_influences().active[branch] == 0) continue;
            int32_t family = -1;
            if (!families_store().valid_handle(
                    family_influences().family_handle[branch], family)) {
                out["ok"] = false;
                out["reason"] = "restore_family_influence_family_invalid";
                return out;
            }
            const uint64_t family_cell =
                (static_cast<uint64_t>(static_cast<uint32_t>(family)) << 32) |
                static_cast<uint32_t>(family_influences().cell[branch]);
            uint64_t expected_hash = 1469598103934665603ULL;
            expected_hash = trace_hash_mix(expected_hash, static_cast<uint64_t>(
                families_store().stable_id[family]));
            expected_hash = trace_hash_mix(expected_hash, static_cast<uint32_t>(
                family_influences().cell[branch]));
            const int64_t expected_stable_id = static_cast<int64_t>(
                (expected_hash & 0x7fffffffffffffffULL) | 1ULL);
            if (!family_cells.insert(family_cell).second ||
                !branch_stable_ids.insert(
                    family_influences().stable_id[branch]).second ||
                family_influences().stable_id[branch] != expected_stable_id) {
                out["ok"] = false;
                out["reason"] =
                    "restore_family_influence_identity_duplicate_or_invalid";
                return out;
            }
        }
    }
    if (_restore.schema_version >= 27) {
        std::unordered_set<int64_t> stable_person_ids;
        std::unordered_set<std::string> visible_person_names;
        std::unordered_set<uint64_t> transit_person_handles;
        for (const uint64_t handle : family_expedition_person_handles()) {
            if (!transit_person_handles.insert(handle).second) {
                out["ok"] = false;
                out["reason"] = "restore_expedition_person_duplicate";
                return out;
            }
        }
        std::vector<int64_t> claimed_by_membership(
            family_memberships().size(), 0);
        std::vector<int64_t> people_by_membership(
            family_memberships().size(), 0);
        for (int32_t i = 0; i < static_cast<int32_t>(persons_store().active.size()); ++i) {
            if (persons_store().active[i] == 0) continue;
            int32_t family = -1, cohort = -1;
            const uint64_t person_handle = persons_store().handle_for_index(i);
            const bool in_transit = persons_store().cohort_handle[i] == 0;
            const int32_t membership = family_membership_index(
                persons_store().family_handle[i], persons_store().cohort_handle[i]);
            if (!families_store().valid_handle(persons_store().family_handle[i], family) ||
                (!in_transit &&
                 !population_store().valid_handle(persons_store().cohort_handle[i], cohort)) ||
                (!in_transit && membership < 0) ||
                (in_transit &&
                 transit_person_handles.find(person_handle) ==
                    transit_person_handles.end()) ||
                (in_transit && (persons_store().job_kind[i] != 0 ||
                    persons_store().building_handle[i] != 0)) ||
                !stable_person_ids.insert(persons_store().stable_id[i]).second) {
                out["ok"] = false;
                out["reason"] = "restore_person_identity_or_membership_invalid";
                return out;
            }
            const std::string family_name_key =
                std::to_string(persons_store().family_handle[i]) + ":" +
                std::to_string(persons_store().given_name_id[i]) + ":" +
                std::to_string(persons_store().name_disambiguator[i]);
            if (!visible_person_names.insert(family_name_key).second ||
                (!in_transit &&
                persons_store().cash_claim[i] >
                    family_memberships()[membership].cash_claim -
                    claimed_by_membership[membership]) ||
                (!in_transit &&
                people_by_membership[membership] >=
                    family_memberships()[membership].people)) {
                out["ok"] = false;
                out["reason"] = "restore_person_name_or_claim_invalid";
                return out;
            }
            if (!in_transit) {
                claimed_by_membership[membership] += persons_store().cash_claim[i];
                ++people_by_membership[membership];
            }
            if (persons_store().job_kind[i] != 0) {
                const int32_t group = building_index_for_handle(
                    persons_store().building_handle[i]);
                if (group < 0 || buildings_store().cell[group] !=
                        population_store().page_cell[cohort / COHORT_PAGE_SIZE]) {
                    out["ok"] = false;
                    out["reason"] = "restore_person_building_invalid";
                    return out;
                }
                if (persons_store().job_kind[i] == 2) {
                    const BuildingType &type =
                        _building_types[buildings_store().type_id[group]];
                    if (persons_store().employee_role_index[i] >= type.employee_count) {
                        out["ok"] = false;
                        out["reason"] = "restore_person_role_invalid";
                        return out;
                    }
                }
            }
        }
        // Canonical order is by person slot, matching how _person_need_offsets
        // is indexed. Handle order would be generation-major and would not
        // agree with the CSR once slots have been recycled.
        int32_t previous_person = -1;
        int32_t previous_need = -1;
        for (const PersonNeedState &state : person_needs()) {
            int32_t person = -1;
            if (!persons_store().valid_handle(state.person_handle, person)) {
                out["ok"] = false;
                out["reason"] = "restore_person_need_handle_invalid";
                return out;
            }
            if (person < previous_person ||
                (person == previous_person &&
                 state.stable_need_id <= previous_need)) {
                out["ok"] = false;
                out["reason"] = "restore_person_need_order_invalid";
                return out;
            }
            previous_person = person;
            previous_need = state.stable_need_id;
        }
    }
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++expedition) {
        if (family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().state[expedition] != EXPEDITION_SETTLING)
            continue;
        if (_effect_runtime == nullptr ||
            _effect_runtime->transaction_status_pod(
                family_expeditions_store().effect_transaction_id[expedition]) == 0) {
            out["ok"] = false;
            out["reason"] = "restore_expedition_effect_transaction_missing";
            return out;
        }
    }
    rebuild_family_expedition_indices();
    for (int32_t expedition = 0; expedition < static_cast<int32_t>(
            family_expeditions_store().active.size()); ++expedition) {
        if (family_expeditions_store().active[expedition] == 0 ||
            family_expeditions_store().state[expedition] != EXPEDITION_PREPARING)
            continue;
        refresh_preparing_family_expedition_missing(expedition);
    }
    rebuild_family_indices();
    _family_effect_bindings.clear();
    _family_effect_binding_by_instance.clear();
    _family_effect_instances_by_branch.clear();
    _family_effect_instances_by_cell.clear();
    _family_modifier_bindings.clear();
    for (int32_t branch = 0; branch < static_cast<int32_t>(
             family_influences().active.size()); ++branch) {
        if (family_influences().active[branch] == 0) continue;
        reconcile_family_branch_effects(
            family_influences().handle_for_index(branch), false);
    }
    rebuild_family_owned_output_csr();
    rebuild_family_policy_scalars();
    rebuild_family_behavior_cache();
    rebuild_person_indices();
    _bootstrapped = true;
    if (_restore.committed_generation_seen) {
        _committed_generation = _restore.restored_committed_generation;
    } else if (++_committed_generation == 0) {
        _committed_generation = 1;
    }
    _fatal = false;
    _fatal_reason.clear();
    _epoch_active = false;
    _stage = Stage::AGGREGATE_PUBLISH;
    _trade_topology.clear();
    _trade_plan.clear_transient();
    rebuild_country_trade_indices();
    rebuild_trade_arrival_buckets();
    rebuild_committed_summaries();
    if (_restore.schema_version < 24) {
        initialize_settlements_from_population();
    } else {
        for (int32_t cell = 0; cell < _cell_count; ++cell) {
            const bool should_have_name =
                _settlements.tier[cell] >= _settlement_named_tier ||
                _settlements.name_forced[cell] != 0;
            if (should_have_name !=
                (_settlements.name_active[cell] != 0)) {
                out["ok"] = false;
                out["reason"] =
                    "restore_settlement_name_activity_mismatch";
                return out;
            }
        }
        _settlements.revision = 1;
    }
    _closing_totals = audit_totals();
    _opening_totals = _closing_totals;
    rebuild_incremental_audit_shadow();
    _closing_audit_force_full = true;
    _settlement_watermark = _last_committed_day;
    _settlement_newest_day = _last_committed_day;
    bool have_populated = false;
    for (int32_t cell = 0; cell < _cell_count; ++cell) {
        if (_committed_cells[cell].population <= 0) continue;
        if (!have_populated) {
            _settlement_watermark = _cell_last_settlement_day[cell];
            _settlement_newest_day = _cell_last_settlement_day[cell];
            have_populated = true;
        } else {
            _settlement_watermark = std::min(
                _settlement_watermark, _cell_last_settlement_day[cell]);
            _settlement_newest_day = std::max(
                _settlement_newest_day, _cell_last_settlement_day[cell]);
        }
    }
    _settlement_max_age_days = have_populated
        ? std::max<int64_t>(0, _last_committed_day - _settlement_watermark) : 0;
    const int32_t restored_pages = _restore.restored_pages;
    const int32_t restored_commands = _restore.restored_commands;
    const int32_t restored_buildings = _restore.restored_buildings;
    const int32_t restored_schema = _restore.schema_version;
    _resource_stock_restored_pending_capture = _restore.resource_stock_seen;
    _restore = {};
    trace_begin_epoch();
    trace_append(EVENT_RESTORE_BOUNDARY,
                 static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), -1,
                 SUBJECT_NONE, _epoch_id, SCHEMA_VERSION, -1,
                 restored_pages, restored_commands, restored_buildings,
                 _last_committed_day, nullptr);
    trace_commit_epoch(0, 0, 0);
    out["ok"] = true;
    out["restored_pages"] = restored_pages;
    out["restored_commands"] = restored_commands;
    out["restored_buildings"] = restored_buildings;
    out["restored_trade_orders"] = trade_orders_store().size();
    out["restored_trade_flows"] = static_cast<int64_t>(_trade_flows.cells.size());
    out["cohort_count"] = population_store().active_count;
    out["state_hash_catalog"] = _catalog_hash;
    out["restored_families"] = families_store().active_count;
    out["restored_persons"] = persons_store().active_count;
    out["restored_person_needs"] = static_cast<int64_t>(person_needs().size());
    out["migration"] = restored_schema == 27
        ? "v27_empty_birth_residual_bootstrap"
        : (restored_schema == 25
        ? "v25_empty_family_bootstrap"
        : (restored_schema == 26
        ? "v26_empty_notable_person_bootstrap"
        : (restored_schema == 22 || restored_schema == 23
        ? "legacy_settlement_bootstrap"
        : (restored_schema == 14
            ? "v14_rolling_phase_bootstrap" : "none"))));
    return out;
}

bool NativeEconomyRuntime::begin_restore_internal(std::string &error) {
    error.clear();
    const Dictionary out = begin_restore();
    if (!static_cast<bool>(out.get("ok", false))) {
        error = String(out.get("reason", "restore_begin_failed")).utf8().get_data();
        return false;
    }
    return true;
}

bool NativeEconomyRuntime::end_restore_internal(std::string &error) {
    error.clear();
    const Dictionary out = end_restore();
    if (!static_cast<bool>(out.get("ok", false))) {
        error = String(out.get("reason", "restore_end_failed")).utf8().get_data();
        return false;
    }
    return true;
}

bool NativeEconomyRuntime::capture_ecp2_authority(RuntimeEconomyEcp2State &out,
                                                  std::string &error,
                                                  uint32_t flags) const {
    error.clear();
    out = RuntimeEconomyEcp2State{};
    if (!_bootstrapped || _fatal) {
        error = !_bootstrapped ? "economy_not_bootstrapped" : "economy_fatal";
        return false;
    }
    if (_epoch_active && (flags & ECP2_CAPTURE_ALLOW_MID_EPOCH) == 0) {
        error = "save_requires_committed_boundary";
        return false;
    }

    NativeEconomyRuntime *self = const_cast<NativeEconomyRuntime *>(this);
    RuntimeEconomyLedgerState pre_owned_ledger;
    self->capture_committed_ledger_state(pre_owned_ledger);
    if (!pre_owned_ledger.valid()) {
        error = "ecp2_owned_state_capture_invalid";
        return false;
    }
    const bool saved_allow = self->_ecp2_allow_mid_epoch_export;
    if ((flags & ECP2_CAPTURE_ALLOW_MID_EPOCH) != 0)
        self->_ecp2_allow_mid_epoch_export = true;

    Dictionary begin = self->begin_save(4 * 1024 * 1024);
    if (!static_cast<bool>(begin.get("ok", false))) {
        self->_ecp2_allow_mid_epoch_export = saved_allow;
        error = String(begin.get("reason", "ecp2_begin_save_failed"))
                    .utf8()
                    .get_data();
        return false;
    }

    out.schema_version = RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION;
    out.abi_version = RUNTIME_ECONOMY_ECP2_ABI_VERSION;
    out.envelope.schema_version = RUNTIME_ECONOMY_ECP2_SCHEMA_VERSION;
    out.envelope.abi_version = RUNTIME_ECONOMY_ECP2_ABI_VERSION;
    out.envelope.cell_count = _cell_count;
    out.envelope.market_count = market_store().market_count;
    out.envelope.good_count = market_store().good_count;
    out.envelope.catalog_hash = _catalog_hash;
    out.envelope.building_catalog_hash = _building_catalog_hash;
    out.envelope.settlement_catalog_hash = _settlement_catalog_hash;
    out.envelope.family_catalog_hash = _family_catalog_hash;
    out.envelope.person_catalog_hash = _person_catalog_hash;
    out.envelope.market_cycle_days = locked_market_cycle_days();
    out.envelope.plan_cycle_days = locked_plan_cycle_days();
    out.envelope.investment_cycle_days = locked_investment_cycle_days();
    out.envelope.epoch_id = _epoch_id;
    out.envelope.last_committed_day = _last_committed_day;
    out.envelope.current_day = _current_day;
    out.envelope.sample_day = _sample_day;
    out.envelope.epoch_days = _epoch_days;
    out.envelope.committed_generation = _committed_generation;
    out.envelope.seed = _seed;
    out.authority_domain_mask = ECP2_DOMAIN_ENVELOPE;

    while (true) {
        const PackedByteArray chunk = self->read_save_chunk(4 * 1024 * 1024);
        if (chunk.is_empty()) break;
        const int64_t chunk_size = chunk.size();
        if (chunk_size < 16) {
            self->_ecp2_allow_mid_epoch_export = saved_allow;
            error = "ecp2_save_chunk_truncated";
            self->end_save();
            return false;
        }
        std::vector<uint8_t> bytes(static_cast<size_t>(chunk_size));
        std::memcpy(bytes.data(), chunk.ptr(), bytes.size());
        const uint16_t section = static_cast<uint16_t>(bytes[6]) |
            static_cast<uint16_t>(static_cast<uint16_t>(bytes[7]) << 8u);
        if (section == SAVE_SECTION_END) continue;
        const uint32_t domain = ecp2_domain_for_pkec_section(section);
        if (domain == 0) continue;
        std::vector<uint8_t> &blob = out.domain_blobs[domain];
        blob.insert(blob.end(), bytes.begin(), bytes.end());
        out.authority_domain_mask |= domain;
    }

    Dictionary end = self->end_save();
    self->_ecp2_allow_mid_epoch_export = saved_allow;
    if (!static_cast<bool>(end.get("ok", false))) {
        error = String(end.get("reason", "ecp2_end_save_failed")).utf8().get_data();
        return false;
    }

    RuntimeEconomyResourceStore resource_store;
    resource_store.resource_count =
        static_cast<int32_t>(_resource_ids.size());
    resource_store.cell_count = _cell_count;
    resource_store.stock = resource_stock_lanes();
    if (_resource_store_alias != nullptr)
        resource_store.cell_generation = _resource_store_alias->cell_generation;
    else
        resource_store.cell_generation = _cell_resource_gen;
    std::vector<uint8_t> resource_wire;
    resource_store.append_wire(resource_wire);
    out.domain_blobs[ECP2_DOMAIN_RESOURCE] = std::move(resource_wire);
    out.authority_domain_mask |= ECP2_DOMAIN_RESOURCE;

    // ECP2's authority payload is independent from the PKEC compatibility
    // chunks. Capture the typed SoA stores as one canonical, content-addressed
    // OwnedState block; restore still keeps PKEC as a compatibility decoder,
    // while this block is the cutover/audit proof for the native owner.
    std::vector<uint8_t> owned_state_wire;
    encode_owned_state_soa(pre_owned_ledger, owned_state_wire);
    if (owned_state_wire.empty()) {
        error = "ecp2_owned_state_capture_empty";
        return false;
    }
    out.domain_blobs[ECP2_DOMAIN_OWNED_STATE] = std::move(owned_state_wire);
    out.authority_domain_mask |= ECP2_DOMAIN_OWNED_STATE;

    if ((flags & ECP2_CAPTURE_INCLUDE_RESUME) != 0 && _epoch_active) {
        RuntimeEconomyEcp2Resume &resume = out.resume;
        resume.epoch_active = 1;
        resume.native_stage = static_cast<int32_t>(_stage);
        resume.graph_completed_mask = 0;
        resume.sample_day = _sample_day;
        resume.current_day = _current_day;
        resume.epoch_id = _epoch_id;
        resume.epoch_days = _epoch_days;
        resume.publish_cursor = _publish_cursor;
        resume.publish_order_cursor = _publish_order_cursor;
        resume.publish_line_cursor = _publish_line_cursor;
        resume.executed_stage = static_cast<int32_t>(_executed_stage);
        resume.publish_phase = static_cast<int32_t>(_publish_phase);
        resume.cell_cursor = static_cast<uint32_t>(std::max(0, _cell_cursor));
        resume.command_cursor =
            static_cast<uint32_t>(std::max(0, _command_cursor));
        resume.structural_cursor =
            static_cast<uint32_t>(std::max(0, _structural_cursor));
        resume.building_cell_cursor =
            static_cast<uint32_t>(std::max(0, _building_cell_cursor));
        resume.plan_evaluate_cursor =
            static_cast<uint32_t>(std::max(0, _plan_evaluate_cursor));
        resume.building_plan_phase = _building_plan_phase;
        resume.household_market_phase = _household_market_phase;
        resume.household_post_cursor = _household_post_cursor;
        resume.building_commit_phase = _building_commit_phase;
        resume.building_commit_cursor = _building_commit_cursor;
        resume.building_finalize_phase = _building_finalize_phase;
        resume.family_commit_cursor = _family_commit_cursor;
        resume.family_commit_phase = _family_commit_phase;
        resume.person_commit_cursor = _person_commit_cursor;
        resume.person_commit_phase = _person_commit_phase;
        resume.trade_plan_phase = static_cast<uint8_t>(
            std::max(0, std::min(255, _trade_plan.phase)));
        resume.trade_plan_scan_cursor = static_cast<uint32_t>(
            std::max<int64_t>(0, _trade_plan.scan_cursor));
        resume.trade_plan_route_cursor = static_cast<uint32_t>(
            std::max(0, _trade_plan.route_cursor));
        resume.waiting_for_peer =
            (_fiscal_reservation_continuation.active ||
             _fiscal_settlement_continuation.active ||
             _country_research_procurement_continuation.active)
                ? 1
                : 0;
        out.authority_domain_mask |= ECP2_DOMAIN_EPOCH_RESUME;
    }

    return true;
}

bool NativeEconomyRuntime::apply_ecp2_authority_internal(
        const RuntimeEconomyEcp2State &in, std::string &error) {
    error.clear();
    if ((in.authority_domain_mask & ECP2_DOMAIN_ENVELOPE) == 0) {
        error = "ecp2_envelope_missing";
        return false;
    }
    const auto owned_state_it = in.domain_blobs.find(ECP2_DOMAIN_OWNED_STATE);
    if ((in.authority_domain_mask & ECP2_DOMAIN_OWNED_STATE) == 0 ||
        owned_state_it == in.domain_blobs.end() ||
        !validate_owned_state_soa(owned_state_it->second)) {
        error = "ecp2_owned_state_missing_or_invalid";
        return false;
    }
    if (_bootstrapped && in.envelope.catalog_hash != 0 &&
        in.envelope.catalog_hash != _catalog_hash) {
        error = "ecp2_catalog_hash_mismatch";
        return false;
    }
    if (_bootstrapped && in.envelope.cell_count > 0 &&
        in.envelope.cell_count != _cell_count) {
        error = "ecp2_cell_count_mismatch";
        return false;
    }

    if (!begin_restore_internal(error)) return false;

    std::vector<std::vector<uint8_t>> ordered_chunks;
    for (uint16_t section = SAVE_SECTION_HEADER;
         section <= SAVE_SECTION_CADENCE_STATE; ++section) {
        ecp2_collect_pkec_chunks_for_section(in.domain_blobs, section,
                                             ordered_chunks);
    }
    {
        std::vector<std::vector<uint8_t>> end_chunks;
        ecp2_collect_pkec_chunks_for_section(in.domain_blobs, SAVE_SECTION_END,
                                             end_chunks);
        if (end_chunks.empty()) {
            std::vector<uint8_t> payload;
            const godot::PackedByteArray end_chunk =
                make_save_chunk(SAVE_SECTION_END, 0, payload);
            ordered_chunks.emplace_back(
                static_cast<size_t>(end_chunk.size()));
            std::memcpy(ordered_chunks.back().data(), end_chunk.ptr(),
                        ordered_chunks.back().size());
        } else {
            ordered_chunks.insert(ordered_chunks.end(),
                                  end_chunks.begin(), end_chunks.end());
        }
    }

    for (const std::vector<uint8_t> &bytes : ordered_chunks) {
        godot::PackedByteArray chunk;
        chunk.resize(static_cast<int64_t>(bytes.size()));
        if (!bytes.empty())
            std::memcpy(chunk.ptrw(), bytes.data(), bytes.size());
        const Dictionary fed = feed_restore_chunk(chunk);
        if (!static_cast<bool>(fed.get("ok", false))) {
            error = String(fed.get("reason", "ecp2_restore_chunk_failed"))
                        .utf8()
                        .get_data();
            _restore = {};
            return false;
        }
    }

    if (!end_restore_internal(error)) {
        _restore = {};
        return false;
    }

    const auto resource_it = in.domain_blobs.find(ECP2_DOMAIN_RESOURCE);
    if (resource_it != in.domain_blobs.end() &&
        !resource_it->second.empty()) {
        // The resource domain may contain both the optional PKEC resource
        // section and the typed ABI9 resource wire. Strip framed PKEC chunks
        // before decoding the raw wire payload.
        size_t resource_wire_offset = 0;
        const std::vector<uint8_t> &resource_blob = resource_it->second;
        while (resource_wire_offset + 16u <= resource_blob.size()) {
            const uint8_t *chunk = resource_blob.data() + resource_wire_offset;
            const uint32_t magic = static_cast<uint32_t>(chunk[0]) |
                (static_cast<uint32_t>(chunk[1]) << 8u) |
                (static_cast<uint32_t>(chunk[2]) << 16u) |
                (static_cast<uint32_t>(chunk[3]) << 24u);
            if (magic != SAVE_MAGIC) break;
            const uint32_t payload_size = static_cast<uint32_t>(chunk[12]) |
                (static_cast<uint32_t>(chunk[13]) << 8u) |
                (static_cast<uint32_t>(chunk[14]) << 16u) |
                (static_cast<uint32_t>(chunk[15]) << 24u);
            const size_t chunk_size = 16u + static_cast<size_t>(payload_size);
            if (chunk_size > resource_blob.size() - resource_wire_offset) break;
            resource_wire_offset += chunk_size;
        }
        RuntimeEconomyResourceStore store;
        store.resource_count = static_cast<int32_t>(_resource_ids.size());
        store.cell_count = _cell_count;
        const uint32_t expected_lanes = static_cast<uint32_t>(
            resource_stock_lanes().size());
        if (!store.load_wire(resource_blob.data() + resource_wire_offset,
                             resource_blob.size() - resource_wire_offset,
                             expected_lanes)) {
            error = "ecp2_resource_wire_invalid";
            return false;
        }
        if (_resource_store_alias != nullptr) {
            _resource_store_alias->stock = store.stock;
            _resource_store_alias->cell_generation = store.cell_generation;
        } else {
            _resource_snapshot = store.stock;
            _cell_resource_gen = store.cell_generation;
        }
    }

    if ((in.authority_domain_mask & ECP2_DOMAIN_EPOCH_RESUME) != 0) {
        const RuntimeEconomyEcp2Resume &resume = in.resume;
        _epoch_active = resume.epoch_active != 0;
        _stage = static_cast<Stage>(resume.native_stage);
        if (resume.epoch_id != 0) _epoch_id = resume.epoch_id;
        if (resume.epoch_days != 0) _epoch_days = resume.epoch_days;
        if (resume.sample_day >= 0) _sample_day = resume.sample_day;
        if (resume.current_day >= 0) _current_day = resume.current_day;
        _publish_cursor = static_cast<size_t>(resume.publish_cursor);
        _publish_order_cursor = resume.publish_order_cursor;
        _publish_line_cursor = resume.publish_line_cursor;
        _executed_stage = static_cast<Stage>(resume.executed_stage);
        _publish_phase = static_cast<PublishPhase>(resume.publish_phase);
        _cell_cursor = static_cast<int32_t>(resume.cell_cursor);
        _command_cursor = static_cast<int32_t>(resume.command_cursor);
        _structural_cursor = static_cast<int32_t>(resume.structural_cursor);
        _building_cell_cursor =
            static_cast<int32_t>(resume.building_cell_cursor);
        _plan_evaluate_cursor =
            static_cast<int32_t>(resume.plan_evaluate_cursor);
        _building_plan_phase = resume.building_plan_phase;
        _household_market_phase = resume.household_market_phase;
        _household_post_cursor = resume.household_post_cursor;
        _building_commit_phase = resume.building_commit_phase;
        _building_commit_cursor = resume.building_commit_cursor;
        _building_finalize_phase = resume.building_finalize_phase;
        _family_commit_cursor = resume.family_commit_cursor;
        _family_commit_phase = resume.family_commit_phase;
        _person_commit_cursor = resume.person_commit_cursor;
        _person_commit_phase = resume.person_commit_phase;
        _trade_plan.phase = resume.trade_plan_phase;
        _trade_plan.scan_cursor = resume.trade_plan_scan_cursor;
        _trade_plan.route_cursor =
            static_cast<int32_t>(resume.trade_plan_route_cursor);
    }

    return true;
}

bool NativeEconomyRuntime::apply_ecp2_authority(
        const RuntimeEconomyEcp2State &in, std::string &error) {
    error.clear();

    // ECP2 restore is a transaction at the runtime boundary. The streaming
    // PKEC reader intentionally mutates lanes as chunks arrive, so an error
    // after the first accepted chunk must be repaired before the caller can
    // observe the world again. Capture the current authority before touching
    // it and use the same validated path for rollback.
    RuntimeEconomyEcp2State backup;
    bool backup_ready = false;
    if (_bootstrapped) {
        uint32_t capture_flags = 0;
        if (_epoch_active) {
            capture_flags |= ECP2_CAPTURE_ALLOW_MID_EPOCH |
                             ECP2_CAPTURE_INCLUDE_RESUME;
        }
        std::string backup_error;
        if (!capture_ecp2_authority(backup, backup_error, capture_flags)) {
            error = "ecp2_atomic_backup_failed:" + backup_error;
            return false;
        }
        backup_ready = true;
    }

    std::string apply_error;
    if (apply_ecp2_authority_internal(in, apply_error)) return true;

    if (backup_ready) {
        std::string rollback_error;
        if (apply_ecp2_authority_internal(backup, rollback_error)) {
            error = apply_error + ";rolled_back";
        } else {
            error = apply_error + ";rollback_failed:" + rollback_error;
        }
    } else {
        error = apply_error;
    }
    return false;
}


} // namespace pk

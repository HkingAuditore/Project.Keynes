#include "runtime_economy_pod.h"
#include "runtime_economy_pod_save_internal.h"
#include "runtime_economy_ecp2.h"
#include <algorithm>
#include <cstring>
#include <limits>
#include <utility>

namespace pk {

using economy_pod_internal::build_owned_state_from_ledger;

bool RuntimeEconomyPodAuthority::encode_ecp1(std::vector<uint8_t> &out,
                                             std::string &error) const {
    error.clear();
    if (!_committed.committed || _scratch.epoch_active ||
        _outbox_count != 0 || _inbox_count != 0) {
        error = "economy_pod_ecp1_save_blocked";
        return false;
    }
    const bool has_committed_ledger = _committed_ledger_state.valid();
    // The daily mirror publishes without a digest; hash it here on demand.
    const uint64_t committed_ledger_hash = has_committed_ledger
        ? _committed_ledger_state.computed_hash() : 0;
    if (has_committed_ledger &&
        (committed_ledger_hash == 0 ||
         (_committed_ledger_state.ledger_hash != 0 &&
          committed_ledger_hash != _committed_ledger_state.ledger_hash))) {
        error = "economy_pod_ecp1_ledger_hash_invalid";
        return false;
    }
    out.clear();
    append_u32(out, RUNTIME_ECONOMY_POD_SECTION_MARKER);
    // Phase-2.3.3: ABI9 when resource+cursor are present; ABI8 when family is
    // present; ABI7 when building+trade are present; ABI6 when diagnostics are
    // present; ABI5 for generation/signals; ABI4 for core; ABI3 when no
    // committed ledger is captured yet.
    const uint32_t ledger_abi =
        !has_committed_ledger ? 3u
        : (_committed_ledger_state.has_resource_columns() &&
                   _committed_ledger_state.has_epoch_cursor_columns()
               ? 9u
               : (_committed_ledger_state.has_family_columns()
                      ? 8u
                      : (_committed_ledger_state.has_building_columns() &&
                                 _committed_ledger_state.has_trade_escrow_columns()
                             ? 7u
                             : (_committed_ledger_state.has_diagnostics_columns()
                                    ? 6u
                                    : (_committed_ledger_state.has_extended_columns()
                                           ? 5u
                                           : 4u)))));
    append_u32(out, ledger_abi);
    const size_t size_at = out.size();
    append_u32(out, 0u);
    append_u64(out, _committed.session_epoch);
    append_u64(out, _committed.generation);
    append_u64(out, _committed.state_hash);
    append_u64(out, static_cast<uint64_t>(_committed.committed_day));
    append_u64(out, _input.catalog_hash);
    append_u32(out, _operation_gate_mask);
    append_u32(out, _parity_ready_mask);
    append_u32(out, static_cast<uint32_t>(_terminal_receipts.size()));
    append_u32(out, static_cast<uint32_t>(_authority_mode));
    append_i64(out, _committed.population_error);
    append_i64(out, _committed.money_error);
    append_i64(out, _committed.goods_error);
    append_i64(out, _summary_population);
    append_i64(out, _summary_funds);
    append_i32(out, _summary_markets);
    append_i32(out, _summary_buildings);
    append_i32(out, _summary_cohorts);
    append_i32(out, _summary_families);
    if (has_committed_ledger) {
        const auto &ledger = _committed_ledger_state;
        append_u64(out, ledger.source_state_hash);
        append_u64(out, committed_ledger_hash);
        append_u64(out, ledger.generation);
        append_i64(out, ledger.committed_day);
        append_i32(out, ledger.market_count);
        append_i32(out, ledger.good_count);
        append_u32(out, static_cast<uint32_t>(ledger.cohort_active.size()));
        binary_codec::append_column_le(out, ledger.cohort_active);
        binary_codec::append_column_le(out, ledger.cohort_cell);
        binary_codec::append_column_le(out, ledger.cohort_slot);
        binary_codec::append_column_le(out, ledger.cohort_signature_id);
        binary_codec::append_column_le(out, ledger.cohort_population);
        binary_codec::append_column_le(out, ledger.cohort_funds);
        binary_codec::append_column_le(out, ledger.cohort_epoch_income);
        binary_codec::append_column_le(out, ledger.cohort_epoch_expense);
        append_u32(out, static_cast<uint32_t>(ledger.market_stock.size()));
        binary_codec::append_column_le(out, ledger.market_stock);
        binary_codec::append_column_le(out, ledger.market_price);
        binary_codec::append_column_le(out, ledger.market_demand_ema);
        if (ledger_abi >= 5u) {
            binary_codec::append_column_le(out, ledger.cohort_generation);
            binary_codec::append_column_le(out, ledger.market_last_shortage_q16);
            binary_codec::append_column_le(out, ledger.market_cell_to_market);
        }
        if (ledger_abi >= 6u) {
            binary_codec::append_column_le(out, ledger.cohort_reserved);
            binary_codec::append_column_le(out, ledger.cohort_reservation_owner);
            binary_codec::append_column_le(out, ledger.cohort_needs_satisfaction);
            binary_codec::append_column_le(out, ledger.cohort_composite_satisfaction);
            binary_codec::append_column_le(out, ledger.cohort_owner_employed);
            binary_codec::append_column_le(out, ledger.cohort_employee_employed);
        }
        if (ledger_abi >= 7u) {
            append_u64(out, ledger.building.catalog_hash);
            append_u64(out, ledger.building.content_hash);
            append_u32(out, ledger.building.group_count);
            append_u32(out, ledger.building.pending_count);
            append_u32(out, ledger.building.role_lane_count);
            std::vector<uint8_t> building_wire;
            ledger.building.store.append_wire(building_wire);
            append_u32(out, static_cast<uint32_t>(building_wire.size()));
            out.insert(out.end(), building_wire.begin(), building_wire.end());
            append_u64(out, ledger.trade_escrow.country_trade_revision);
            append_i64(out, ledger.trade_escrow.next_id);
            append_u32(out, ledger.trade_escrow.order_count);
            append_u64(out, ledger.trade_escrow.content_hash);
            std::vector<uint8_t> trade_wire;
            ledger.trade_escrow.store.append_wire(trade_wire);
            append_u32(out, static_cast<uint32_t>(trade_wire.size()));
            out.insert(out.end(), trade_wire.begin(), trade_wire.end());
        }
        if (ledger_abi >= 8u) {
            append_u64(out, ledger.family.catalog_hash);
            append_u64(out, ledger.family.person_catalog_hash);
            append_u64(out, ledger.family.trait_catalog_hash);
            append_i32(out, ledger.family.runtime_mode);
            append_i32(out, ledger.family.person_runtime_mode);
            append_u32(out, ledger.family.family_count);
            append_u32(out, ledger.family.membership_count);
            append_u32(out, ledger.family.ownership_count);
            append_u32(out, ledger.family.person_count);
            append_u32(out, ledger.family.person_need_count);
            append_u32(out, ledger.family.trait_count);
            append_u32(out, ledger.family.influence_count);
            append_u32(out, ledger.family.trait_command_count);
            append_u32(out, ledger.family.expedition_count);
            append_i64(out, ledger.family.next_expedition_stable_id);
            append_u64(out, ledger.family.content_hash);
            std::vector<uint8_t> family_wire;
            ledger.family.store.append_wire(family_wire);
            append_u32(out, static_cast<uint32_t>(family_wire.size()));
            out.insert(out.end(), family_wire.begin(), family_wire.end());
        }
        if (ledger_abi >= 9u) {
            append_u64(out, ledger.resource.catalog_hash);
            append_u64(out, ledger.resource.environment_hash);
            append_i64(out, ledger.resource.context_day);
            append_i32(out, ledger.resource.resource_count);
            append_i32(out, ledger.resource.cell_count);
            append_u32(out, ledger.resource.lane_count);
            append_i32(out, ledger.resource.min_reserve_q16);
            append_i32(out, ledger.resource.safe_harvest_q16);
            append_i32(out, ledger.resource.min_horizon_days);
            append_u64(out, ledger.resource.content_hash);
            std::vector<uint8_t> resource_wire;
            ledger.resource.store.append_wire(resource_wire);
            append_u32(out, static_cast<uint32_t>(resource_wire.size()));
            out.insert(out.end(), resource_wire.begin(), resource_wire.end());
            append_i64(out, ledger.epoch_cursor.sample_day);
            append_i64(out, ledger.epoch_cursor.current_day);
            append_i64(out, ledger.epoch_cursor.last_committed_day);
            append_i64(out, ledger.epoch_cursor.epoch_id);
            append_i32(out, ledger.epoch_cursor.epoch_days);
            out.push_back(ledger.epoch_cursor.epoch_active);
            append_i32(out, ledger.epoch_cursor.native_stage);
            append_u32(out, ledger.epoch_cursor.graph_completed_mask);
            append_u64(out, ledger.epoch_cursor.content_hash);
            std::vector<uint8_t> cursor_wire;
            ledger.epoch_cursor.store.append_wire(cursor_wire);
            append_u32(out, static_cast<uint32_t>(cursor_wire.size()));
            out.insert(out.end(), cursor_wire.begin(), cursor_wire.end());
        }
    }
    for (const RuntimeEconomyPodReceipt &receipt : _terminal_receipts) {
        append_u64(out, receipt.request_id);
        append_u64(out, receipt.transaction_id);
        append_u32(out, static_cast<uint32_t>(receipt.opcode));
        append_u32(out, static_cast<uint32_t>(receipt.code));
    }
    const uint32_t payload_size =
        static_cast<uint32_t>(out.size() - size_at - 4u);
    out[size_at] = static_cast<uint8_t>(payload_size & 0xffu);
    out[size_at + 1] = static_cast<uint8_t>((payload_size >> 8) & 0xffu);
    out[size_at + 2] = static_cast<uint8_t>((payload_size >> 16) & 0xffu);
    out[size_at + 3] = static_cast<uint8_t>((payload_size >> 24) & 0xffu);
    append_u64(out, fnv1a(out.data(), out.size()));
    return true;
}

bool RuntimeEconomyPodAuthority::restore_ecp1(const uint8_t *data, size_t size,
                                              std::string &error) {
    error.clear();
    if (data == nullptr || size < 24) {
        error = "economy_pod_ecp1_truncated";
        return false;
    }
    const uint64_t expected = fnv1a(data, size - 8);
    uint64_t actual = 0;
    const uint8_t *tail = data + size - 8;
    if (!read_u64(tail, data + size, actual) || actual != expected) {
        error = "economy_pod_ecp1_checksum";
        return false;
    }
    const uint8_t *p = data;
    const uint8_t *end = data + size - 8;
    uint32_t marker = 0, abi = 0, payload_size = 0;
    if (!read_u32(p, end, marker) || marker != RUNTIME_ECONOMY_POD_SECTION_MARKER ||
        !read_u32(p, end, abi) ||
        (abi != 1u && abi != 2u && abi != 3u && abi != 4u && abi != 5u &&
         abi != 6u && abi != 7u && abi != 8u && abi != 9u) ||
        !read_u32(p, end, payload_size)) {
        error = "economy_pod_ecp1_header_invalid";
        return false;
    }
    uint64_t session = 0, generation = 0, state_hash = 0, day = 0, catalog = 0;
    if (payload_size != static_cast<size_t>(end - p)) {
        error = "economy_pod_ecp1_payload_size_mismatch";
        return false;
    }
    uint32_t gate = 0, parity = 0, receipt_count = 0, authority_mode = 0;
    if (!read_u64(p, end, session) || !read_u64(p, end, generation) ||
        !read_u64(p, end, state_hash) || !read_u64(p, end, day) ||
        !read_u64(p, end, catalog) || !read_u32(p, end, gate) ||
        !read_u32(p, end, parity) || !read_u32(p, end, receipt_count)) {
        error = "economy_pod_ecp1_payload_invalid";
        return false;
    }
    if (abi >= 3u && !read_u32(p, end, authority_mode)) {
        error = "economy_pod_ecp1_authority_mode_missing";
        return false;
    }
    int64_t pop_err = 0, money_err = 0, goods_err = 0;
    int64_t summary_population = 0, summary_funds = 0;
    int32_t summary_markets = 0, summary_buildings = 0;
    int32_t summary_cohorts = 0, summary_families = 0;
    if (abi >= 2u) {
        if (!read_i64(p, end, pop_err) || !read_i64(p, end, money_err) ||
            !read_i64(p, end, goods_err) ||
            !read_i64(p, end, summary_population) ||
            !read_i64(p, end, summary_funds) ||
            !read_i32(p, end, summary_markets) ||
            !read_i32(p, end, summary_buildings) ||
            !read_i32(p, end, summary_cohorts) ||
            !read_i32(p, end, summary_families)) {
            error = "economy_pod_ecp1_abi2_truncated";
            return false;
        }
    }
    RuntimeEconomyLedgerState restored_ledger;
    if (abi >= 4u) {
        uint64_t ledger_source_hash = 0, ledger_hash = 0;
        uint64_t ledger_generation = 0;
        int64_t ledger_committed_day = -1;
        int32_t market_count = 0, good_count = 0;
        uint32_t cohort_count = 0, market_lanes = 0;
        if (!read_u64(p, end, ledger_source_hash) ||
            !read_u64(p, end, ledger_hash) ||
            !read_u64(p, end, ledger_generation) ||
            !read_i64(p, end, ledger_committed_day) ||
            !read_i32(p, end, market_count) || !read_i32(p, end, good_count) ||
            !read_u32(p, end, cohort_count) || market_count < 0 || good_count < 0 ||
            cohort_count > 10000000u) {
            error = "economy_pod_ecp1_ledger_header_invalid";
            return false;
        }
        restored_ledger.source_state_hash = ledger_source_hash;
        restored_ledger.ledger_hash = ledger_hash;
        restored_ledger.generation = ledger_generation;
        restored_ledger.committed_day = ledger_committed_day;
        restored_ledger.market_count = market_count;
        restored_ledger.good_count = good_count;
        restored_ledger.cohort_active.resize(cohort_count);
        restored_ledger.cohort_cell.resize(cohort_count);
        restored_ledger.cohort_slot.resize(cohort_count);
        restored_ledger.cohort_signature_id.resize(cohort_count);
        restored_ledger.cohort_population.resize(cohort_count);
        restored_ledger.cohort_funds.resize(cohort_count);
        restored_ledger.cohort_epoch_income.resize(cohort_count);
        restored_ledger.cohort_epoch_expense.resize(cohort_count);
        for (uint8_t &value : restored_ledger.cohort_active) {
            if (p >= end) {
                error = "economy_pod_ecp1_ledger_truncated";
                return false;
            }
            value = *p++;
        }
        const auto ledger_truncated = [&error]() {
            error = "economy_pod_ecp1_ledger_truncated";
            return false;
        };
        for (int32_t &value : restored_ledger.cohort_cell)
            if (!read_i32(p, end, value)) return ledger_truncated();
        for (int32_t &value : restored_ledger.cohort_slot)
            if (!read_i32(p, end, value)) return ledger_truncated();
        for (uint32_t &value : restored_ledger.cohort_signature_id)
            if (!read_u32(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.cohort_population)
            if (!read_i64(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.cohort_funds)
            if (!read_i64(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.cohort_epoch_income)
            if (!read_i64(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.cohort_epoch_expense)
            if (!read_i64(p, end, value)) return ledger_truncated();
        if (!read_u32(p, end, market_lanes) ||
            market_lanes != static_cast<uint64_t>(market_count) * static_cast<uint64_t>(good_count)) {
            error = "economy_pod_ecp1_ledger_market_shape_invalid";
            return false;
        }
        restored_ledger.market_stock.resize(market_lanes);
        restored_ledger.market_price.resize(market_lanes);
        restored_ledger.market_demand_ema.resize(market_lanes);
        for (int64_t &value : restored_ledger.market_stock)
            if (!read_i64(p, end, value)) return ledger_truncated();
        for (int32_t &value : restored_ledger.market_price)
            if (!read_i32(p, end, value)) return ledger_truncated();
        for (int64_t &value : restored_ledger.market_demand_ema)
            if (!read_i64(p, end, value)) return ledger_truncated();
        if (abi >= 5u) {
            restored_ledger.cohort_generation.resize(cohort_count);
            restored_ledger.market_last_shortage_q16.resize(market_lanes);
            restored_ledger.market_cell_to_market.resize(
                static_cast<size_t>(market_count));
            for (uint32_t &value : restored_ledger.cohort_generation)
                if (!read_u32(p, end, value)) return ledger_truncated();
            for (uint16_t &value : restored_ledger.market_last_shortage_q16)
                if (!read_u16(p, end, value)) return ledger_truncated();
            for (int32_t &value : restored_ledger.market_cell_to_market)
                if (!read_i32(p, end, value)) return ledger_truncated();
        }
        if (abi >= 6u) {
            restored_ledger.cohort_reserved.resize(cohort_count);
            restored_ledger.cohort_reservation_owner.resize(cohort_count);
            restored_ledger.cohort_needs_satisfaction.resize(cohort_count);
            restored_ledger.cohort_composite_satisfaction.resize(cohort_count);
            restored_ledger.cohort_owner_employed.resize(cohort_count);
            restored_ledger.cohort_employee_employed.resize(cohort_count);
            for (uint8_t &value : restored_ledger.cohort_reserved) {
                if (p >= end) return ledger_truncated();
                value = *p++;
            }
            for (uint64_t &value : restored_ledger.cohort_reservation_owner)
                if (!read_u64(p, end, value)) return ledger_truncated();
            for (uint16_t &value : restored_ledger.cohort_needs_satisfaction)
                if (!read_u16(p, end, value)) return ledger_truncated();
            for (uint16_t &value : restored_ledger.cohort_composite_satisfaction)
                if (!read_u16(p, end, value)) return ledger_truncated();
            for (int64_t &value : restored_ledger.cohort_owner_employed)
                if (!read_i64(p, end, value)) return ledger_truncated();
            for (int64_t &value : restored_ledger.cohort_employee_employed)
                if (!read_i64(p, end, value)) return ledger_truncated();
        }
        if (abi >= 7u) {
            uint32_t building_payload_size = 0;
            uint32_t trade_payload_size = 0;
            if (!read_u64(p, end, restored_ledger.building.catalog_hash) ||
                !read_u64(p, end, restored_ledger.building.content_hash) ||
                !read_u32(p, end, restored_ledger.building.group_count) ||
                !read_u32(p, end, restored_ledger.building.pending_count) ||
                !read_u32(p, end, restored_ledger.building.role_lane_count) ||
                !read_u32(p, end, building_payload_size) ||
                static_cast<size_t>(end - p) < building_payload_size) {
                error = "economy_pod_ecp1_building_truncated";
                return false;
            }
            if (!restored_ledger.building.store.load_wire(
                    p, building_payload_size,
                    restored_ledger.building.group_count,
                    restored_ledger.building.pending_count,
                    restored_ledger.building.role_lane_count)) {
                error = "economy_pod_ecp1_building_payload_shape";
                return false;
            }
            p += building_payload_size;
            restored_ledger.building.captured = true;
            if (restored_ledger.building.content_hash !=
                restored_ledger.building.store.wire_content_hash()) {
                error = "economy_pod_ecp1_building_content_hash";
                return false;
            }
            if (!read_u64(p, end,
                          restored_ledger.trade_escrow.country_trade_revision) ||
                !read_i64(p, end, restored_ledger.trade_escrow.next_id) ||
                !read_u32(p, end, restored_ledger.trade_escrow.order_count) ||
                !read_u64(p, end, restored_ledger.trade_escrow.content_hash) ||
                !read_u32(p, end, trade_payload_size) ||
                static_cast<size_t>(end - p) < trade_payload_size) {
                error = "economy_pod_ecp1_trade_escrow_truncated";
                return false;
            }
            if (!restored_ledger.trade_escrow.store.load_wire(
                    p, trade_payload_size,
                    restored_ledger.trade_escrow.order_count)) {
                error = "economy_pod_ecp1_trade_escrow_payload_shape";
                return false;
            }
            p += trade_payload_size;
            restored_ledger.trade_escrow.captured = true;
            if (restored_ledger.trade_escrow.content_hash !=
                restored_ledger.trade_escrow.store.wire_content_hash()) {
                error = "economy_pod_ecp1_trade_escrow_content_hash";
                return false;
            }
        }
        if (abi >= 8u) {
            uint32_t family_payload_size = 0;
            if (!read_u64(p, end, restored_ledger.family.catalog_hash) ||
                !read_u64(p, end, restored_ledger.family.person_catalog_hash) ||
                !read_u64(p, end, restored_ledger.family.trait_catalog_hash) ||
                !read_i32(p, end, restored_ledger.family.runtime_mode) ||
                !read_i32(p, end, restored_ledger.family.person_runtime_mode) ||
                !read_u32(p, end, restored_ledger.family.family_count) ||
                !read_u32(p, end, restored_ledger.family.membership_count) ||
                !read_u32(p, end, restored_ledger.family.ownership_count) ||
                !read_u32(p, end, restored_ledger.family.person_count) ||
                !read_u32(p, end, restored_ledger.family.person_need_count) ||
                !read_u32(p, end, restored_ledger.family.trait_count) ||
                !read_u32(p, end, restored_ledger.family.influence_count) ||
                !read_u32(p, end, restored_ledger.family.trait_command_count) ||
                !read_u32(p, end, restored_ledger.family.expedition_count) ||
                !read_i64(p, end,
                          restored_ledger.family.next_expedition_stable_id) ||
                !read_u64(p, end, restored_ledger.family.content_hash) ||
                !read_u32(p, end, family_payload_size) ||
                static_cast<size_t>(end - p) < family_payload_size) {
                error = "economy_pod_ecp1_family_truncated";
                return false;
            }
            if (!restored_ledger.family.store.load_wire(
                    p, family_payload_size, restored_ledger.family.family_count,
                    restored_ledger.family.membership_count,
                    restored_ledger.family.ownership_count,
                    restored_ledger.family.person_count,
                    restored_ledger.family.person_need_count,
                    restored_ledger.family.trait_count,
                    restored_ledger.family.influence_count,
                    restored_ledger.family.trait_command_count,
                    restored_ledger.family.expedition_count)) {
                error = "economy_pod_ecp1_family_payload_shape";
                return false;
            }
            p += family_payload_size;
            restored_ledger.family.captured = true;
            if (restored_ledger.family.content_hash !=
                restored_ledger.family.store.wire_content_hash()) {
                error = "economy_pod_ecp1_family_content_hash";
                return false;
            }
        }
        if (abi >= 9u) {
            uint32_t resource_payload_size = 0;
            uint32_t cursor_payload_size = 0;
            if (!read_u64(p, end, restored_ledger.resource.catalog_hash) ||
                !read_u64(p, end, restored_ledger.resource.environment_hash) ||
                !read_i64(p, end, restored_ledger.resource.context_day) ||
                !read_i32(p, end, restored_ledger.resource.resource_count) ||
                !read_i32(p, end, restored_ledger.resource.cell_count) ||
                !read_u32(p, end, restored_ledger.resource.lane_count) ||
                !read_i32(p, end, restored_ledger.resource.min_reserve_q16) ||
                !read_i32(p, end, restored_ledger.resource.safe_harvest_q16) ||
                !read_i32(p, end, restored_ledger.resource.min_horizon_days) ||
                !read_u64(p, end, restored_ledger.resource.content_hash) ||
                !read_u32(p, end, resource_payload_size) ||
                static_cast<size_t>(end - p) < resource_payload_size) {
                error = "economy_pod_ecp1_resource_truncated";
                return false;
            }
            restored_ledger.resource.store.resource_count =
                restored_ledger.resource.resource_count;
            restored_ledger.resource.store.cell_count =
                restored_ledger.resource.cell_count;
            if (!restored_ledger.resource.store.load_wire(
                    p, resource_payload_size,
                    restored_ledger.resource.lane_count)) {
                error = "economy_pod_ecp1_resource_payload_shape";
                return false;
            }
            p += resource_payload_size;
            restored_ledger.resource.captured = true;
            if (restored_ledger.resource.content_hash !=
                restored_ledger.resource.store.wire_content_hash()) {
                error = "economy_pod_ecp1_resource_content_hash";
                return false;
            }
            if (!read_i64(p, end, restored_ledger.epoch_cursor.sample_day) ||
                !read_i64(p, end, restored_ledger.epoch_cursor.current_day) ||
                !read_i64(p, end,
                          restored_ledger.epoch_cursor.last_committed_day) ||
                !read_i64(p, end, restored_ledger.epoch_cursor.epoch_id) ||
                !read_i32(p, end, restored_ledger.epoch_cursor.epoch_days) ||
                p >= end) {
                error = "economy_pod_ecp1_epoch_cursor_truncated";
                return false;
            }
            restored_ledger.epoch_cursor.epoch_active = *p++;
            if (!read_i32(p, end, restored_ledger.epoch_cursor.native_stage) ||
                !read_u32(p, end,
                          restored_ledger.epoch_cursor.graph_completed_mask) ||
                !read_u64(p, end, restored_ledger.epoch_cursor.content_hash) ||
                !read_u32(p, end, cursor_payload_size) ||
                static_cast<size_t>(end - p) < cursor_payload_size) {
                error = "economy_pod_ecp1_epoch_cursor_truncated";
                return false;
            }
            if (!restored_ledger.epoch_cursor.store.load_wire(
                    p, cursor_payload_size)) {
                error = "economy_pod_ecp1_epoch_cursor_payload_shape";
                return false;
            }
            p += cursor_payload_size;
            restored_ledger.epoch_cursor.captured = true;
            if (restored_ledger.epoch_cursor.content_hash !=
                restored_ledger.epoch_cursor.store.wire_content_hash()) {
                error = "economy_pod_ecp1_epoch_cursor_content_hash";
                return false;
            }
        }
        if (!restored_ledger.valid()) {
            error = "economy_pod_ecp1_ledger_invalid";
            return false;
        }
    }
    constexpr size_t receipt_wire_size = 24;
    if (receipt_count != static_cast<size_t>(end - p) / receipt_wire_size ||
        static_cast<size_t>(end - p) % receipt_wire_size != 0) {
        error = "economy_pod_ecp1_receipt_size_mismatch";
        return false;
    }
    std::vector<RuntimeEconomyPodReceipt> restored_receipts;
    restored_receipts.reserve(receipt_count);
    for (uint32_t i = 0; i < receipt_count; ++i) {
        RuntimeEconomyPodReceipt receipt;
        uint32_t opcode = 0, code = 0;
        if (!read_u64(p, end, receipt.request_id) ||
            !read_u64(p, end, receipt.transaction_id) ||
            !read_u32(p, end, opcode) || !read_u32(p, end, code)) {
            error = "economy_pod_ecp1_receipt_truncated";
            return false;
        }
        receipt.opcode = static_cast<int32_t>(opcode);
        receipt.code = static_cast<RuntimeEconomyCommandReceiptCode>(code);
        restored_receipts.push_back(receipt);
    }
    RuntimeEconomyOwnedState restored_state;
    if (abi >= 4u) {
        if (!build_owned_state_from_ledger(
                restored_ledger, restored_state, error)) {
            return false;
        }
    } else {
        restored_state.clear(0, 0);
    }

    // Commit only after every wire, topology and ledger-hash check succeeds.
    _state = std::move(restored_state);
    _committed_ledger_state = std::move(restored_ledger);
    _market_export_warmup = 0;
    if (abi >= 4u) publish_mirror_features();
    else _published_mirror_features.store(0, std::memory_order_release);
    _terminal_receipts = std::move(restored_receipts);
    _committed = RuntimeEconomyCommittedSnapshot{};
    _committed.session_epoch = session;
    _committed.generation = generation;
    _committed.state_hash = state_hash;
    _committed.committed_day = static_cast<int64_t>(day);
    _committed.committed = true;
    _committed.completed_stage_mask = RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
    _committed.population_error = pop_err;
    _committed.money_error = money_err;
    _committed.goods_error = goods_err;
    _operation_gate_mask = gate;
    _authority_mode = abi >= 3u && authority_mode <=
            static_cast<uint32_t>(RuntimeEconomyAuthorityMode::POD_ACTIVE)
        ? static_cast<RuntimeEconomyAuthorityMode>(authority_mode)
        : RuntimeEconomyAuthorityMode::LEGACY_SYNC;
    _parity_ready_mask = parity;
    _generation = generation;
    _input.catalog_hash = catalog;
    _input.session_epoch = session;
    _scratch = RuntimeEconomyWorkerScratch{};
    _summary_population = summary_population;
    _summary_funds = summary_funds;
    _summary_markets = summary_markets;
    _summary_buildings = summary_buildings;
    _summary_cohorts = summary_cohorts;
    _summary_families = summary_families;
    // Preserve abi2 summaries into the snapshot ring for round-trip observers.
    if (abi >= 2u) {
        uint32_t ring_index = 0;
        if (_snapshot_ring.try_begin_write(ring_index)) {
            RuntimeEconomySnapshotPayload &payload =
                _snapshot_ring.write_buffer(ring_index);
            payload = RuntimeEconomySnapshotPayload{};
            payload.header = _committed;
            payload.catalog_hash = catalog;
            payload.operation_gate_mask = gate;
            payload.population_error = pop_err;
            payload.money_error = money_err;
            payload.goods_error = goods_err;
            payload.summary_population = summary_population;
            payload.summary_funds = summary_funds;
            payload.summary_markets = summary_markets;
            payload.summary_buildings = summary_buildings;
            payload.summary_cohorts = summary_cohorts;
            payload.summary_families = summary_families;
            _snapshot_ring.publish(ring_index);
        }
    }
    return true;
}

bool RuntimeEconomyPodAuthority::encode_ecp2(
        const RuntimeEconomyEcp2State &state, std::vector<uint8_t> &out,
        std::string &error) const {
    return pk::encode_ecp2(state, out, error);
}

bool RuntimeEconomyPodAuthority::encode_ecp2(std::vector<uint8_t> &out,
                                             std::string &error) const {
    if (_ecp2.authority_domain_mask == 0) {
        error = "economy_pod_ecp2_state_empty";
        return false;
    }
    return pk::encode_ecp2(_ecp2, out, error);
}

bool RuntimeEconomyPodAuthority::restore_ecp2(const uint8_t *data, size_t size,
                                              std::string &error) {
    error.clear();
    RuntimeEconomyEcp2State decoded;
    if (!pk::decode_ecp2(data, size, decoded, error)) return false;
    _ecp2 = std::move(decoded);
    return true;
}

bool RuntimeEconomyPodAuthority::capture_ecp2_from_runtime(
        NativeEconomyRuntime &runtime, uint32_t flags, std::string &error) {
    error.clear();
    RuntimeEconomyEcp2State captured;
    if (!runtime.capture_ecp2_authority(captured, error, flags)) return false;
    _ecp2 = std::move(captured);
    return true;
}


} // namespace pk

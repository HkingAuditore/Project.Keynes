#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace variant_helpers;


namespace {
constexpr uint32_t EVENT_ARCHIVE_MAGIC = 0x4a454b50U; // "PKEJ" little endian
constexpr uint16_t EVENT_ARCHIVE_VERSION = 3;
constexpr uint16_t EVENT_ARCHIVE_HEADER = 0;
constexpr uint16_t EVENT_ARCHIVE_EVENTS = 1;
constexpr uint16_t EVENT_ARCHIVE_END = 2;

PackedByteArray make_event_archive_chunk(uint16_t section, uint32_t records,
                                         const std::vector<uint8_t> &payload) {
    std::vector<uint8_t> bytes;
    bytes.reserve(16 + payload.size());
    append_le<uint32_t>(bytes, EVENT_ARCHIVE_MAGIC);
    append_le<uint16_t>(bytes, EVENT_ARCHIVE_VERSION);
    append_le<uint16_t>(bytes, section);
    append_le<uint32_t>(bytes, records);
    append_le<uint32_t>(bytes, static_cast<uint32_t>(payload.size()));
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    PackedByteArray out;
    out.resize(static_cast<int64_t>(bytes.size()));
    if (!bytes.empty()) std::memcpy(out.ptrw(), bytes.data(), bytes.size());
    return out;
}
} // namespace

Dictionary NativeEconomyRuntime::event_schema() const {
    Dictionary out;
    out["version"] = 5;
    out["format"] = "economy_header_and_delta_legs";
    Dictionary kinds;
    kinds["COMMAND_SETTLED"] = EVENT_COMMAND_SETTLED;
    kinds["MARKET_SETTLED"] = EVENT_MARKET_SETTLED;
    kinds["STRUCTURAL_CHANGE"] = EVENT_STRUCTURAL_CHANGE;
    kinds["CONSTRUCTION_STARTED"] = EVENT_CONSTRUCTION_STARTED;
    kinds["CONSTRUCTION_COMPLETED"] = EVENT_CONSTRUCTION_COMPLETED;
    kinds["BUILDING_DEMOLISHED"] = EVENT_BUILDING_DEMOLISHED;
    kinds["EMPLOYMENT_SETTLED"] = EVENT_EMPLOYMENT_SETTLED;
    kinds["WAGE_SETTLED"] = EVENT_WAGE_SETTLED;
    kinds["BUILDING_PRODUCTION_SETTLED"] = EVENT_BUILDING_PRODUCTION_SETTLED;
    kinds["EPOCH_COMMITTED"] = EVENT_EPOCH_COMMITTED;
    kinds["RESTORE_BOUNDARY"] = EVENT_RESTORE_BOUNDARY;
    kinds["TRADE_DISPATCHED"] = EVENT_TRADE_DISPATCHED;
    kinds["TRADE_ARRIVED"] = EVENT_TRADE_ARRIVED;
    kinds["POPULATION_SOURCE"] = EVENT_POPULATION_SOURCE;
    kinds["TARIFF_SUBSIDY_INTENT"] = EVENT_TARIFF_SUBSIDY_INTENT;
    out["kinds"] = kinds;
    Dictionary fields;
    fields["COHORT_POPULATION"] = FIELD_COHORT_POPULATION;
    fields["COHORT_FUNDS"] = FIELD_COHORT_FUNDS;
    fields["COHORT_EPOCH_INCOME"] = FIELD_COHORT_EPOCH_INCOME;
    fields["COHORT_EPOCH_EXPENSE"] = FIELD_COHORT_EPOCH_EXPENSE;
    fields["COHORT_INCOME_EMA"] = FIELD_COHORT_INCOME_EMA;
    fields["COHORT_SATISFACTION"] = FIELD_COHORT_SATISFACTION;
    fields["COHORT_WORST_NEED"] = FIELD_COHORT_WORST_NEED;
    fields["COHORT_OWNER_EMPLOYED"] = FIELD_COHORT_OWNER_EMPLOYED;
    fields["COHORT_EMPLOYEE_EMPLOYED"] = FIELD_COHORT_EMPLOYEE_EMPLOYED;
    fields["COHORT_SIGNATURE"] = FIELD_COHORT_SIGNATURE;
    fields["TREASURY_CASH"] = FIELD_TREASURY_CASH;
    fields["MARKET_STOCK"] = FIELD_MARKET_STOCK;
    fields["MARKET_PRICE"] = FIELD_MARKET_PRICE;
    fields["MARKET_DEMAND_EMA"] = FIELD_MARKET_DEMAND_EMA;
    fields["MARKET_SHORTAGE"] = FIELD_MARKET_SHORTAGE;
    fields["BUILDING_COUNT"] = FIELD_BUILDING_COUNT;
    fields["BUILDING_OWNER_FILLED"] = FIELD_BUILDING_OWNER_FILLED;
    fields["BUILDING_EMPLOYEE_FILLED"] = FIELD_BUILDING_EMPLOYEE_FILLED;
    fields["BUILDING_CAPACITY"] = FIELD_BUILDING_CAPACITY;
    fields["BUILDING_INPUT"] = FIELD_BUILDING_INPUT;
    fields["BUILDING_OUTPUT"] = FIELD_BUILDING_OUTPUT;
    fields["BUILDING_SOLD"] = FIELD_BUILDING_SOLD;
    fields["BUILDING_DISCARDED"] = FIELD_BUILDING_DISCARDED;
    fields["BUILDING_RESOURCE"] = FIELD_BUILDING_RESOURCE;
    fields["BUILDING_RESOURCE_GENERATED"] = FIELD_BUILDING_RESOURCE_GENERATED;
    fields["BUILDING_REVENUE"] = FIELD_BUILDING_REVENUE;
    fields["BUILDING_INPUT_COST"] = FIELD_BUILDING_INPUT_COST;
    fields["BUILDING_WAGES_PAID"] = FIELD_BUILDING_WAGES_PAID;
    fields["BUILDING_WAGES_DUE"] = FIELD_BUILDING_WAGES_DUE;
    fields["BUILDING_EXPECTED_REVENUE"] = FIELD_BUILDING_EXPECTED_REVENUE;
    fields["BUILDING_OPERATING_COST"] = FIELD_BUILDING_OPERATING_COST;
    fields["BUILDING_MARGIN_GAP"] = FIELD_BUILDING_MARGIN_GAP;
    fields["BUILDING_PLANNED_UTILIZATION"] = FIELD_BUILDING_PLANNED_UTILIZATION;
    fields["BUILDING_BASE_WAGES_PAID"] = FIELD_BUILDING_BASE_WAGES_PAID;
    fields["BUILDING_BASE_WAGES_DUE"] = FIELD_BUILDING_BASE_WAGES_DUE;
    fields["BUILDING_BONUS_PAID"] = FIELD_BUILDING_BONUS_PAID;
    fields["BUILDING_BONUS_DUE"] = FIELD_BUILDING_BONUS_DUE;
    fields["BUILDING_WAGE_SUSPENDED"] = FIELD_BUILDING_WAGE_SUSPENDED;
    fields["RESOURCE_DELTA"] = FIELD_RESOURCE_DELTA;
    fields["COHORT_DEMOGRAPHY_RESIDUAL"] = FIELD_COHORT_DEMOGRAPHY_RESIDUAL;
    fields["TRADE_QUANTITY"] = FIELD_TRADE_QUANTITY;
    fields["TRADE_BASE_VALUE"] = FIELD_TRADE_BASE_VALUE;
    fields["TRADE_RETAIL_VALUE"] = FIELD_TRADE_RETAIL_VALUE;
    fields["TRADE_IMPORT_TRANSFER"] = FIELD_TRADE_IMPORT_TRANSFER;
    fields["TRADE_EXPORT_TRANSFER"] = FIELD_TRADE_EXPORT_TRANSFER;
    fields["TRADE_TRANSACTION_TRANSFER"] = FIELD_TRADE_TRANSACTION_TRANSFER;
    out["fields"] = fields;
    Dictionary cashflow_sources;
    cashflow_sources["WAGES"] = CASHFLOW_WAGES;
    cashflow_sources["OWNER_OPERATIONS"] = CASHFLOW_OWNER_OPERATIONS;
    cashflow_sources["MERCHANT_HOUSEHOLD_SALES"] = CASHFLOW_MERCHANT_HOUSEHOLD;
    cashflow_sources["MERCHANT_BUSINESS_SALES"] = CASHFLOW_MERCHANT_BUSINESS;
    cashflow_sources["TRANSFER"] = CASHFLOW_TRANSFER;
    cashflow_sources["HOUSEHOLD_CONSUMPTION"] = CASHFLOW_HOUSEHOLD_CONSUMPTION;
    cashflow_sources["PRODUCTION_INPUTS"] = CASHFLOW_PRODUCTION_INPUT;
    cashflow_sources["OWNER_WAGES"] = CASHFLOW_OWNER_WAGES;
    cashflow_sources["CONSTRUCTION"] = CASHFLOW_CONSTRUCTION;
    cashflow_sources["MERCHANT_PROCUREMENT"] = CASHFLOW_MERCHANT_PROCUREMENT;
    cashflow_sources["OTHER"] = CASHFLOW_OTHER;
    cashflow_sources["PRODUCER_SUPPORT_ISSUANCE"] = CASHFLOW_PRODUCER_SUPPORT;
    cashflow_sources["INCOME_TAX"] = CASHFLOW_INCOME_TAX;
    cashflow_sources["CONSUMPTION_TAX"] = CASHFLOW_CONSUMPTION_TAX;
    cashflow_sources["BUSINESS_TAX"] = CASHFLOW_BUSINESS_TAX;
    cashflow_sources["INCOME_SUBSIDY"] = CASHFLOW_INCOME_SUBSIDY;
    cashflow_sources["CONSUMPTION_SUBSIDY"] = CASHFLOW_CONSUMPTION_SUBSIDY;
    cashflow_sources["BUSINESS_SUBSIDY"] = CASHFLOW_BUSINESS_SUBSIDY;
    cashflow_sources["FISCAL_ESCROW"] = CASHFLOW_FISCAL_ESCROW;
    cashflow_sources["IMPORT_TAX"] = CASHFLOW_IMPORT_TAX;
    cashflow_sources["EXPORT_TAX"] = CASHFLOW_EXPORT_TAX;
    cashflow_sources["IMPORT_SUBSIDY"] = CASHFLOW_IMPORT_SUBSIDY;
    cashflow_sources["EXPORT_SUBSIDY"] = CASHFLOW_EXPORT_SUBSIDY;
    out["cashflow_sources"] = cashflow_sources;
    out["money_scale"] = MONEY_SCALE;
    out["goods_scale"] = GOODS_SCALE;
    out["ratio_scale"] = Q16_ONE;
    return out;
}


Dictionary NativeEconomyRuntime::set_trace_filter(const Dictionary &filter) {
    Dictionary out;
    std::vector<int32_t> cells = packed_i32(filter, "cells");
    std::vector<uint8_t> mask(static_cast<size_t>(std::max(0, _cell_count.get())), 0);
    for (int32_t cell : cells) {
        if (cell < 0 || cell >= _cell_count.get()) {
            out["ok"] = false;
            out["reason"] = "economy_trace_cell_out_of_range";
            return out;
        }
        mask[cell] = 1;
    }
    if (_epoch_active) {
        _pending_trace_cell_mask = std::move(mask);
        _trace_filter_pending = true;
    } else {
        _trace_cell_mask = std::move(mask);
        _pending_trace_cell_mask.clear();
        _trace_filter_pending = false;
    }
    out["ok"] = true;
    out["effective_next_epoch"] = _epoch_active;
    out["cell_count"] = static_cast<int64_t>(cells.size());
    return out;
}


Dictionary NativeEconomyRuntime::set_inspector_trace_cell(int32_t cell_idx) {
    Dictionary out;
    if (cell_idx < -1 || cell_idx >= _cell_count.get()) {
        out["ok"] = false;
        out["reason"] = "economy_inspector_trace_cell_out_of_range";
        return out;
    }
    if (_epoch_active) {
        _pending_inspector_trace_cell = cell_idx;
        _inspector_trace_pending = true;
    } else {
        _inspector_trace_cell = cell_idx;
        _pending_inspector_trace_cell = cell_idx;
        _inspector_trace_pending = false;
    }
    if (cell_idx != _investment_diagnostic_cell) {
        _investment_diagnostic_cell = -1;
        _investment_diagnostic_day = -1;
        _investment_diagnostics.clear();
    }
    if (cell_idx != _employment_diagnostic_cell) {
        _employment_diagnostic_cell = -1;
        _employment_diagnostic_day = -1;
        _employment_diagnostics.clear();
        _family_clamp_traces.clear();
    }
    out["ok"] = true;
    out["cell_idx"] = cell_idx;
    out["effective_next_epoch"] = _epoch_active;
    return out;
}


Dictionary NativeEconomyRuntime::poll_events(const Dictionary &opts) const {
    const StringName consumer = opts.has("consumer_id")
        ? StringName(opts["consumer_id"]) : StringName("default");
    const std::string consumer_key = to_utf8(String(consumer));
    const auto ack_it = _event_consumer_ack.find(consumer_key);
    const int64_t acked = ack_it == _event_consumer_ack.end() ? 0 : ack_it->second;
    const int64_t after = dict_num<int64_t>(opts, "after_event_id", acked);
    const int32_t max_events = std::clamp(
        dict_num<int32_t>(opts, "max_events", _trace_poll_max_events), 1, 65536);
    const int32_t kind_filter = dict_num<int32_t>(opts, "kind", 0);
    const int32_t cell_filter = dict_num<int32_t>(opts, "cell", -1);
    PackedInt64Array event_id, cause_id, epoch_id, sample_day, commit_day, subject_id;
    PackedInt32Array period_days, stage, kind, flags, cell, subject_kind, subject_i0,
        subject_i1, leg_offset, leg_count;
    PackedInt64Array value0, value1, value2, value3;
    PackedInt32Array leg_field, leg_subject_kind, leg_key_id;
    PackedInt64Array leg_subject_id, leg_before, leg_after;
    int64_t last_id = after;
    for (const EventBatch &batch : _committed_event_batches) {
        if (batch.last_event_id <= after) continue;
        for (const EventRecord &event : batch.events) {
            if (event.event_id <= after || (kind_filter > 0 && event.kind != kind_filter) ||
                (cell_filter >= 0 && event.cell != cell_filter)) continue;
            event_id.append(event.event_id); cause_id.append(event.event_id);
            epoch_id.append(batch.epoch_id); sample_day.append(batch.sample_day);
            commit_day.append(batch.commit_day); period_days.append(batch.period_days);
            stage.append(event.stage); kind.append(event.kind); flags.append(event.flags);
            cell.append(event.cell); subject_kind.append(event.subject_kind);
            subject_id.append(event.subject_id); subject_i0.append(event.subject_i0);
            subject_i1.append(event.subject_i1);
            leg_offset.append(leg_field.size()); leg_count.append(event.leg_count);
            value0.append(event.value0); value1.append(event.value1);
            value2.append(event.value2); value3.append(event.value3);
            for (uint32_t i = 0; i < event.leg_count; ++i) {
                const EventLeg &leg = batch.legs[event.leg_begin + i];
                leg_field.append(leg.field); leg_subject_kind.append(leg.subject_kind);
                leg_subject_id.append(leg.subject_id); leg_key_id.append(leg.key_id);
                leg_before.append(leg.before); leg_after.append(leg.after);
            }
            last_id = event.event_id;
            if (event_id.size() >= max_events) break;
        }
        if (event_id.size() >= max_events) break;
    }
    Dictionary out;
    out["event_id"] = event_id; out["cause_id"] = cause_id; out["epoch_id"] = epoch_id;
    out["sample_day"] = sample_day; out["commit_day"] = commit_day;
    out["period_days"] = period_days; out["stage"] = stage; out["kind"] = kind;
    out["flags"] = flags; out["cell"] = cell; out["subject_kind"] = subject_kind;
    out["subject_id"] = subject_id; out["subject_i0"] = subject_i0;
    out["subject_i1"] = subject_i1; out["leg_offset"] = leg_offset;
    out["leg_count"] = leg_count; out["value0"] = value0; out["value1"] = value1;
    out["value2"] = value2; out["value3"] = value3;
    out["leg_field"] = leg_field; out["leg_subject_kind"] = leg_subject_kind;
    out["leg_subject_id"] = leg_subject_id; out["leg_key_id"] = leg_key_id;
    out["leg_before"] = leg_before; out["leg_after"] = leg_after;
    out["count"] = event_id.size(); out["last_event_id"] = last_id;
    out["consumer_id"] = consumer;
    out["consumer_lag"] = std::max<int64_t>(0, _next_event_id.get() - 1 - last_id);
    out["gap"] = !_committed_event_batches.empty() &&
        after < _committed_event_batches.front().first_event_id - 1;
    out["ok"] = true;
    return out;
}


Dictionary NativeEconomyRuntime::ack_events(const StringName &consumer_id,
                                            int64_t up_to_event_id) {
    const std::string key = to_utf8(String(consumer_id));
    const int64_t previous = _event_consumer_ack.count(key) ? _event_consumer_ack[key] : 0;
    const int64_t next = std::max(previous, up_to_event_id);
    _event_consumer_ack[key] = next;
    Dictionary out;
    out["ok"] = true;
    out["consumer_id"] = consumer_id;
    out["previous_event_id"] = previous;
    out["acked_event_id"] = next;
    return out;
}


Dictionary NativeEconomyRuntime::trace_report() const {
    Dictionary out;
    int64_t events = 0, legs = 0;
    for (const EventBatch &batch : _committed_event_batches) {
        events += static_cast<int64_t>(batch.events.size());
        legs += static_cast<int64_t>(batch.legs.size());
    }
    out["ok"] = true;
    out["mode"] = _trace_mode == TRACE_OFF ? "OFF" :
        (_trace_mode == TRACE_SUMMARY ? "SUMMARY" :
        (_trace_mode == TRACE_FULL_DEBUG ? "FULL_DEBUG" : "SELECTIVE"));
    out["event_count"] = events;
    out["leg_count"] = legs;
    out["batch_count"] = static_cast<int64_t>(_committed_event_batches.size());
    out["audit_frame_count"] = static_cast<int64_t>(_audit_history.size());
    out["oldest_event_id"] = _committed_event_batches.empty() ? 0 :
        _committed_event_batches.front().first_event_id;
    out["newest_event_id"] = _next_event_id.get() - 1;
    out["next_event_id"] = _next_event_id.get();
    out["stream_hash"] = static_cast<int64_t>(_event_stream_hash.get());
    out["memory_bytes"] = trace_memory_bytes();
    out["memory_budget_bytes"] = _trace_memory_budget;
    out["evicted_event_count"] = _event_evicted_count;
    out["first_evicted_event_id"] = _first_evicted_event_id;
    out["detail_truncated_count"] = _trace_detail_truncated;
    out["uncommitted_discarded_count"] = _trace_uncommitted_discarded;
    out["filter_pending"] = _trace_filter_pending;
    out["inspector_trace_cell"] = _inspector_trace_cell;
    out["inspector_trace_pending"] = _inspector_trace_pending;
    out["event_summary_ms"] = _event_summary_ms;
    out["event_detail_ms"] = _event_detail_ms;
    out["event_publish_ms"] = _event_publish_ms;
    out["archive_active"] = _event_archive.active;
    return out;
}


Dictionary NativeEconomyRuntime::begin_event_archive(int32_t chunk_bytes) {
    Dictionary out;
    if (!_bootstrapped || _epoch_active || _event_archive.active || _save.active ||
        _restore.active) {
        out["ok"] = false;
        out["reason"] = !_bootstrapped ? "economy_not_bootstrapped" :
            (_epoch_active ? "archive_requires_committed_boundary" : "archive_already_active");
        return out;
    }
    _event_archive = {};
    _event_archive.active = true;
    _event_archive.chunk_bytes = std::clamp(chunk_bytes, 64 * 1024, 16 * 1024 * 1024);
    _event_archive.batch_limit = _committed_event_batches.size();
    out["ok"] = true;
    out["chunk_bytes"] = _event_archive.chunk_bytes;
    out["batch_count"] = static_cast<int64_t>(_committed_event_batches.size());
    return out;
}


PackedByteArray NativeEconomyRuntime::read_event_archive_chunk(int32_t max_bytes) {
    if (!_event_archive.active || _event_archive.end_emitted) return {};
    const int32_t budget = std::clamp(max_bytes > 0 ? max_bytes : _event_archive.chunk_bytes,
                                      64 * 1024, 16 * 1024 * 1024);
    std::vector<uint8_t> payload;
    if (!_event_archive.header_emitted) {
        append_le<int64_t>(payload, _catalog_hash.get());
        append_le<int64_t>(payload, _building_catalog_hash.get());
        append_le<int64_t>(payload, _next_event_id.get());
        append_le<uint64_t>(payload, _event_stream_hash.get());
        append_le<int32_t>(payload, static_cast<int32_t>(_event_archive.batch_limit));
        _event_archive.header_emitted = true;
        return make_event_archive_chunk(EVENT_ARCHIVE_HEADER, 1, payload);
    }
    uint32_t records = 0;
    while (_event_archive.batch_cursor < _event_archive.batch_limit) {
        const EventBatch &batch = _committed_event_batches[_event_archive.batch_cursor];
        if (_event_archive.event_cursor >= batch.events.size()) {
            ++_event_archive.batch_cursor;
            _event_archive.event_cursor = 0;
            continue;
        }
        const EventRecord &event = batch.events[_event_archive.event_cursor];
        const size_t record_bytes = 116 + static_cast<size_t>(event.leg_count) * 40;
        if (!payload.empty() && payload.size() + record_bytes > static_cast<size_t>(budget - 16)) break;
        append_le<int64_t>(payload, event.event_id);
        append_le<int64_t>(payload, event.event_id);
        append_le<int64_t>(payload, batch.epoch_id);
        append_le<int64_t>(payload, batch.sample_day);
        append_le<int64_t>(payload, batch.commit_day);
        append_le<int32_t>(payload, batch.period_days);
        append_le<int32_t>(payload, event.stage);
        append_le<int32_t>(payload, event.kind);
        append_le<int32_t>(payload, event.flags);
        append_le<int32_t>(payload, event.cell);
        append_le<int32_t>(payload, event.subject_kind);
        append_le<int64_t>(payload, event.subject_id);
        append_le<int32_t>(payload, event.subject_i0);
        append_le<int32_t>(payload, event.subject_i1);
        append_le<uint32_t>(payload, event.leg_count);
        append_le<int64_t>(payload, event.value0);
        append_le<int64_t>(payload, event.value1);
        append_le<int64_t>(payload, event.value2);
        append_le<int64_t>(payload, event.value3);
        for (uint32_t i = 0; i < event.leg_count; ++i) {
            const EventLeg &leg = batch.legs[event.leg_begin + i];
            append_le<int32_t>(payload, leg.field);
            append_le<int32_t>(payload, leg.subject_kind);
            append_le<int64_t>(payload, leg.subject_id);
            append_le<int32_t>(payload, leg.key_id);
            append_le<int64_t>(payload, leg.before);
            append_le<int64_t>(payload, leg.after);
        }
        ++_event_archive.event_cursor;
        ++records;
    }
    if (records > 0) return make_event_archive_chunk(EVENT_ARCHIVE_EVENTS, records, payload);
    _event_archive.end_emitted = true;
    return make_event_archive_chunk(EVENT_ARCHIVE_END, 0, payload);
}


Dictionary NativeEconomyRuntime::end_event_archive() {
    Dictionary out;
    if (!_event_archive.active || !_event_archive.end_emitted) {
        out["ok"] = false;
        out["reason"] = !_event_archive.active ? "event_archive_not_active" :
            "event_archive_not_fully_read";
        return out;
    }
    _event_archive = {};
    trace_evict_to_budget();
    out["ok"] = true;
    return out;
}

} // namespace pk

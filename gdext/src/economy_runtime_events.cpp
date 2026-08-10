#include "economy_runtime.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_variant_helpers.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>

#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace variant_helpers;

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

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

void NativeEconomyRuntime::publish_social_pressure_facts() {
    for (const int32_t cell : _epoch_settlement_cells) {
        if (cell < 0 || cell >= _cell_count ||
            cell >= static_cast<int32_t>(_cell_social_pressure_level.size()))
            continue;
        int64_t weighted = 0;
        int64_t population = 0;
        int32_t grievance_slot = -1;
        int64_t grievance_q16 = Q16_ONE;
        _population.for_each_in_cell(cell, [&](int32_t slot) {
            const int64_t people = std::max<int64_t>(
                0, _population.population[slot]);
            if (people <= 0) return;
            const int64_t composite = _population.composite_satisfaction[slot];
            population = saturating_add(population, people, _saturation_count);
            weighted = saturating_add(weighted,
                saturating_mul(composite, people, _saturation_count),
                _saturation_count);
            if (composite < grievance_q16) {
                grievance_q16 = composite;
                grievance_slot = slot;
            }
        });
        if (population <= 0) continue;
        const int64_t composite_q16 = std::clamp<int64_t>(
            weighted / population, 0, Q16_ONE - 1);
        const int32_t level = social_pressure_level_for(composite_q16);
        const int32_t previous = _cell_social_pressure_level[cell];
        if (level == previous) continue;
        _cell_social_pressure_level[cell] = static_cast<uint8_t>(level);
        CommittedGameplayFact fact;
        fact.kind = GAMEPLAY_FACT_SOCIAL_PRESSURE;
        fact.cell = cell;
        fact.entity_id = static_cast<int32_t>(std::clamp<int64_t>(
            population, 0, std::numeric_limits<int32_t>::max()));
        fact.value = composite_q16;
        const int32_t worst_dimension = grievance_slot >= 0 &&
                _population.worst_dimension_id[grievance_slot] !=
                    std::numeric_limits<uint8_t>::max()
            ? static_cast<int32_t>(_population.worst_dimension_id[grievance_slot])
            : -1;
        const int32_t worst_need = grievance_slot >= 0 &&
                _population.worst_need_id[grievance_slot] !=
                    std::numeric_limits<uint16_t>::max()
            ? static_cast<int32_t>(_population.worst_need_id[grievance_slot])
            : -1;
        fact.payload = {level, worst_dimension, worst_need, previous};
        fact.flags = level < previous ? 1 : 0;
        _staging_gameplay_facts.push_back(fact);
    }
}


bool NativeEconomyRuntime::trace_detail_for_cell(int32_t cell) const {
    if (_trace_mode == TRACE_FULL_DEBUG) return true;
    return _trace_mode == TRACE_SELECTIVE && cell >= 0 &&
           ((cell < static_cast<int32_t>(_trace_cell_mask.size()) &&
             _trace_cell_mask[cell] != 0) || cell == _inspector_trace_cell);
}


void NativeEconomyRuntime::trace_record_cashflow(int32_t cell, uint64_t cohort_handle,
                                                  int32_t source, int64_t income,
                                                  int64_t expense) {
    if (_production_result_sink != nullptr) {
        if (_trace_mode != TRACE_OFF && cell >= 0 &&
            cell == _staging_events.cashflow_cell && cohort_handle != 0 &&
            (income != 0 || expense != 0)) {
            _production_result_sink->cashflow_drafts.push_back(
                {cell, {cohort_handle, source, income, expense}});
        }
        return;
    }
    if (_trace_mode == TRACE_OFF || cell < 0 || cell != _staging_events.cashflow_cell ||
        cohort_handle == 0 || (income == 0 && expense == 0)) return;
    for (CashflowEntry &entry : _staging_events.cashflows) {
        if (entry.cohort_handle != cohort_handle || entry.source != source) continue;
        entry.income = saturating_add(entry.income, income, _saturation_count);
        entry.expense = saturating_add(entry.expense, expense, _saturation_count);
        return;
    }
    _staging_events.cashflows.push_back({cohort_handle, source, income, expense});
}


void NativeEconomyRuntime::trace_reconcile_inspector_cashflows() {
    const int32_t cell = _staging_events.cashflow_cell;
    if (cell < 0 || cell >= _cell_count) return;
    _population.for_each_in_cell(cell, [&](int32_t slot) {
        const uint64_t handle = _population.handle_for_slot(slot);
        int64_t recorded_income = 0;
        int64_t recorded_expense = 0;
        for (const CashflowEntry &entry : _staging_events.cashflows) {
            if (entry.cohort_handle != handle) continue;
            recorded_income = saturating_add(recorded_income, entry.income, _saturation_count);
            recorded_expense = saturating_add(recorded_expense, entry.expense, _saturation_count);
        }
        const int64_t missing_income = std::max<int64_t>(
            0, _population.epoch_income[slot] - recorded_income);
        const int64_t missing_expense = std::max<int64_t>(
            0, _population.epoch_expense[slot] - recorded_expense);
        trace_record_cashflow(cell, handle, CASHFLOW_OTHER,
                              missing_income, missing_expense);
    });
    std::sort(_staging_events.cashflows.begin(), _staging_events.cashflows.end(),
              [](const CashflowEntry &a, const CashflowEntry &b) {
                  if (a.cohort_handle != b.cohort_handle) {
                      return a.cohort_handle < b.cohort_handle;
                  }
                  return a.source < b.source;
              });
    _staging_events.cashflow_complete = true;
}


void NativeEconomyRuntime::trace_begin_epoch() {
	_staging_gameplay_facts.clear();
    _staging_construction_receipts.clear();
    if (_trace_filter_pending) {
        _trace_cell_mask.swap(_pending_trace_cell_mask);
        _pending_trace_cell_mask.clear();
        _trace_filter_pending = false;
    }
    if (_inspector_trace_pending) {
        _inspector_trace_cell = _pending_inspector_trace_cell;
        _inspector_trace_pending = false;
    }
    _staging_events = {};
    _staging_events.epoch_id = _epoch_id;
    _staging_events.sample_day = _sample_day;
    _staging_events.commit_day = _sample_day < 0 ? _current_day :
        _sample_day + std::max(0, _epoch_days - 1);
    _staging_events.period_days = std::max(1, _epoch_days);
    const bool inspector_trace_due = _inspector_trace_cell >= 0 &&
        _inspector_trace_cell < _cell_count &&
        _inspector_trace_cell % ROLLING_PHASE_COUNT == _rolling_phase;
    _staging_events.cashflow_cell =
        (_trace_mode == TRACE_SELECTIVE || _trace_mode == TRACE_FULL_DEBUG) &&
                inspector_trace_due
            ? _inspector_trace_cell : -1;
    if (_staging_events.cashflow_cell >= 0) {
        _staging_events.cashflows.reserve(64);
    }
    _staging_events.stream_hash = _event_stream_hash;
    _staging_events.stream_hash = trace_hash_mix(
        _staging_events.stream_hash, static_cast<uint64_t>(_staging_events.epoch_id));
    _staging_events.stream_hash = trace_hash_mix(
        _staging_events.stream_hash, static_cast<uint64_t>(_staging_events.sample_day));
    if (_trace_mode != TRACE_OFF) {
        const int64_t estimated_events = static_cast<int64_t>(_market.market_count) +
            static_cast<int64_t>(_buildings.size()) * 3 +
            static_cast<int64_t>(_pending_commands.size()) + 64;
        _staging_events.events.reserve(static_cast<size_t>(std::clamp<int64_t>(
            estimated_events, 64, 250000)));
    }
}


void NativeEconomyRuntime::trace_append(int32_t kind, int32_t stage, int32_t cell,
                                        int32_t subject_kind, int64_t subject_id,
                                        int32_t subject_i0, int32_t subject_i1,
                                        int64_t value0, int64_t value1, int64_t value2,
                                        int64_t value3, const std::vector<EventLeg> *legs,
                                        int32_t flags) {
    if (_production_result_sink != nullptr) {
        if (_trace_mode != TRACE_OFF) {
            ProductionTraceDraft draft;
            draft.kind = kind;
            draft.stage = stage;
            draft.cell = cell;
            draft.subject_kind = subject_kind;
            draft.subject_id = subject_id;
            draft.subject_i0 = subject_i0;
            draft.subject_i1 = subject_i1;
            draft.value0 = value0;
            draft.value1 = value1;
            draft.value2 = value2;
            draft.value3 = value3;
            draft.flags = flags;
            if (legs != nullptr) draft.legs = *legs;
            _production_result_sink->trace_drafts.push_back(std::move(draft));
        }
        return;
    }
    if (_trace_mode == TRACE_OFF) return;
    EventRecord event;
    event.stage = stage;
    event.kind = kind;
    event.flags = flags;
    event.cell = cell;
    event.subject_kind = subject_kind;
    event.subject_id = subject_id;
    event.subject_i0 = subject_i0;
    event.subject_i1 = subject_i1;
    event.value0 = value0;
    event.value1 = value1;
    event.value2 = value2;
    event.value3 = value3;
    if (legs != nullptr && !legs->empty()) {
        const int64_t next_bytes = static_cast<int64_t>(
            (_staging_events.legs.size() + legs->size()) * sizeof(EventLeg));
        if (next_bytes <= _trace_detail_epoch_budget) {
            event.flags |= 1; // exact detail present
            event.leg_begin = static_cast<uint32_t>(_staging_events.legs.size());
            event.leg_count = static_cast<uint32_t>(legs->size());
            _staging_events.legs.insert(_staging_events.legs.end(), legs->begin(), legs->end());
        } else {
            event.flags |= 2; // exact detail truncated
            ++_trace_detail_truncated;
        }
    }
    event.event_id = _next_event_id + static_cast<int64_t>(_staging_events.events.size());
    uint64_t hash = _staging_events.stream_hash;
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.event_id));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.kind));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.cell));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.subject_id));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value0));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value1));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value2));
    hash = trace_hash_mix(hash, static_cast<uint64_t>(event.value3));
    for (uint32_t i = 0; i < event.leg_count; ++i) {
        const EventLeg &leg = _staging_events.legs[event.leg_begin + i];
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.field));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.subject_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.key_id));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.before));
        hash = trace_hash_mix(hash, static_cast<uint64_t>(leg.after));
    }
    _staging_events.stream_hash = hash;
    _staging_events.events.push_back(event);
}


void NativeEconomyRuntime::trace_commit_epoch(int64_t population_error,
                                              int64_t money_error,
                                              int64_t goods_error) {
    const auto start = Clock::now();
    trace_reconcile_inspector_cashflows();
    trace_append(EVENT_EPOCH_COMMITTED, static_cast<int32_t>(Stage::AGGREGATE_PUBLISH), -1,
                 SUBJECT_NONE, _epoch_id, -1, -1,
                 static_cast<int64_t>(_staging_events.events.size()),
                 population_error, money_error, goods_error, nullptr, 0);
    const int64_t event_count = static_cast<int64_t>(_staging_events.events.size());
    if (!_staging_gameplay_facts.empty()) {
        _committed_gameplay_facts.insert(_committed_gameplay_facts.end(),
            _staging_gameplay_facts.begin(), _staging_gameplay_facts.end());
        _staging_gameplay_facts.clear();
    }
    for (ConstructionCommandReceipt &receipt : _staging_construction_receipts) {
        receipt.receipt_id = _next_construction_receipt_id++;
        _committed_construction_receipts.push_back(std::move(receipt));
    }
    _staging_construction_receipts.clear();
    while (_committed_construction_receipts.size() > 256U) {
        _committed_construction_receipts.pop_front();
    }
    const int64_t leg_count = static_cast<int64_t>(_staging_events.legs.size());
    if (_trace_mode != TRACE_OFF) {
        _staging_events.first_event_id = _next_event_id;
        _next_event_id += event_count;
        _staging_events.last_event_id = _next_event_id - 1;
        _event_stream_hash = _staging_events.stream_hash;
        _committed_event_batches.push_back(std::move(_staging_events));
    }
    _audit_history.push_back({_epoch_id, _sample_day, _current_day, event_count, leg_count,
                              population_error, money_error, goods_error,
                              _event_stream_hash});
    while (static_cast<int32_t>(_audit_history.size()) > _trace_retention_epochs) {
        _audit_history.pop_front();
    }
    _staging_events = {};
    trace_evict_to_budget();
    _event_publish_ms += elapsed_ms(start);
}


void NativeEconomyRuntime::trace_abort_epoch() {
	_staging_gameplay_facts.clear();
    _staging_construction_receipts.clear();
    if (!_staging_events.events.empty()) {
        _trace_uncommitted_discarded += static_cast<int64_t>(_staging_events.events.size());
    }
    _staging_events = {};
}


int64_t NativeEconomyRuntime::trace_memory_bytes() const {
    int64_t bytes = _staging_events.bytes();
    for (const EventBatch &batch : _committed_event_batches) bytes += batch.bytes();
    bytes += static_cast<int64_t>(_audit_history.size() * sizeof(AuditFrame));
    bytes += static_cast<int64_t>(_trace_cell_mask.capacity() +
                                  _pending_trace_cell_mask.capacity());
    return bytes;
}


void NativeEconomyRuntime::trace_evict_to_budget() {
    if (_event_archive.active) return;
    while (!_committed_event_batches.empty() &&
           (static_cast<int32_t>(_committed_event_batches.size()) > _trace_retention_epochs ||
            trace_memory_bytes() > _trace_memory_budget)) {
        const EventBatch &batch = _committed_event_batches.front();
        if (batch.last_event_id > 0) {
            if (_first_evicted_event_id == 0) _first_evicted_event_id = batch.first_event_id;
            _event_evicted_count += static_cast<int64_t>(batch.events.size());
        }
        _committed_event_batches.pop_front();
    }
}


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
    out["cashflow_sources"] = cashflow_sources;
    out["money_scale"] = MONEY_SCALE;
    out["goods_scale"] = GOODS_SCALE;
    out["ratio_scale"] = Q16_ONE;
    return out;
}


Dictionary NativeEconomyRuntime::set_trace_filter(const Dictionary &filter) {
    Dictionary out;
    std::vector<int32_t> cells = packed_i32(filter, "cells");
    std::vector<uint8_t> mask(static_cast<size_t>(std::max(0, _cell_count)), 0);
    for (int32_t cell : cells) {
        if (cell < 0 || cell >= _cell_count) {
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
    if (cell_idx < -1 || cell_idx >= _cell_count) {
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
    out["consumer_lag"] = std::max<int64_t>(0, _next_event_id - 1 - last_id);
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
    out["newest_event_id"] = _next_event_id - 1;
    out["next_event_id"] = _next_event_id;
    out["stream_hash"] = static_cast<int64_t>(_event_stream_hash);
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
        append_le<int64_t>(payload, _catalog_hash);
        append_le<int64_t>(payload, _building_catalog_hash);
        append_le<int64_t>(payload, _next_event_id);
        append_le<uint64_t>(payload, _event_stream_hash);
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


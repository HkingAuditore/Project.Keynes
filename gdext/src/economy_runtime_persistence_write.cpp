#include "economy_runtime.h"
#include "country_api.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_persistence_codec.h"
#include "runtime_switch_registry.h"
#include <algorithm>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace persistence_codec;

PackedByteArray NativeEconomyRuntime::read_save_chunk(int32_t max_bytes) {
    if (!_save.active || _save.end_emitted) return {};
    const int32_t budget = std::clamp(max_bytes > 0 ? max_bytes : _save.chunk_bytes,
                                      64 * 1024, 16 * 1024 * 1024);
    std::vector<uint8_t> payload;
#include "economy_runtime_persistence_write_section_core_records.inc"
    if (_save.section == SAVE_SECTION_CONSTRUCTION) {
        constexpr int32_t record_bytes = 62;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(pending_construction_count()),
                                              _save.construction_cursor + max_records);
        const int32_t begin = _save.construction_cursor;
        for (; _save.construction_cursor < end; ++_save.construction_cursor) {
            const auto pending = pending_construction()[
                static_cast<size_t>(_save.construction_cursor)];
            append_le<int32_t>(payload, pending.cell);
            append_le<int32_t>(payload, pending.type_id);
            append_le<int32_t>(payload, pending.owner_signature_id);
            append_le<int64_t>(payload, pending.count);
            append_le<int64_t>(payload, pending.ready_day);
            append_le<int64_t>(payload, pending.sequence);
            append_le<int64_t>(payload, pending.merchant_debt_principal);
            append_le<int64_t>(payload, pending.merchant_debt_premium);
            append_le<uint16_t>(payload, pending.merchant_debt_term_cycles_left);
            append_le<uint64_t>(payload, pending.sponsor_family_handle);
        }
        if (_save.construction_cursor >= static_cast<int32_t>(pending_construction_count())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_CONSTRUCTION,
                               static_cast<uint32_t>(_save.construction_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_AUDIT) {
        constexpr int32_t record_bytes = 72;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t end = std::min<int32_t>(static_cast<int32_t>(_audit_history.size()),
                                              _save.audit_cursor + max_records);
        const int32_t begin = _save.audit_cursor;
        for (; _save.audit_cursor < end; ++_save.audit_cursor) {
            const AuditFrame &frame = _audit_history[static_cast<size_t>(_save.audit_cursor)];
            append_le<int64_t>(payload, frame.epoch_id);
            append_le<int64_t>(payload, frame.sample_day);
            append_le<int64_t>(payload, frame.commit_day);
            append_le<int64_t>(payload, frame.event_count);
            append_le<int64_t>(payload, frame.leg_count);
            append_le<int64_t>(payload, frame.population_error);
            append_le<int64_t>(payload, frame.money_error);
            append_le<int64_t>(payload, frame.goods_error);
            append_le<uint64_t>(payload, frame.stream_hash);
        }
        if (_save.audit_cursor >= static_cast<int32_t>(_audit_history.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_AUDIT,
                               static_cast<uint32_t>(_save.audit_cursor - begin), payload);
    }
#include "economy_runtime_persistence_write_section_signals_and_trade.inc"
#include "economy_runtime_persistence_write_section_lineage_and_people.inc"
    if (_save.section == SAVE_SECTION_TARIFF_HISTORY) {
        constexpr int32_t record_bytes = 104;
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t begin = _save.tariff_history_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(_tariff_history.countries.size()),
            begin + max_records);
        for (; _save.tariff_history_cursor < end; ++_save.tariff_history_cursor) {
            const int32_t i = _save.tariff_history_cursor;
            append_le<int32_t>(payload, _tariff_history.countries[i]);
            append_le<int32_t>(payload, _tariff_history.kinds[i]);
            append_le<int64_t>(payload, _tariff_history.bases[i]);
            append_le<int64_t>(payload, _tariff_history.assessed[i]);
            append_le<int64_t>(payload, _tariff_history.collected[i]);
            append_le<int64_t>(payload, _tariff_history.requests[i]);
            append_le<int64_t>(payload, _tariff_history.reserved[i]);
            append_le<int64_t>(payload, _tariff_history.paid[i]);
            append_le<int64_t>(payload, _tariff_history.cumulative_bases[i]);
            append_le<int64_t>(payload, _tariff_history.cumulative_collected[i]);
            append_le<int64_t>(payload, _tariff_history.cumulative_requests[i]);
            append_le<int64_t>(payload, _tariff_history.cumulative_paid[i]);
        }
        if (_save.tariff_history_cursor >= static_cast<int32_t>(
                _tariff_history.countries.size())) ++_save.section;
        return make_save_chunk(SAVE_SECTION_TARIFF_HISTORY,
            static_cast<uint32_t>(_save.tariff_history_cursor - begin), payload);
    }
#include "economy_runtime_persistence_write_section_country_and_canals.inc"
    if (_save.section == SAVE_SECTION_RESOURCE_STOCK) {
        // Optional v52 extension: persist mutable resource stock and the
        // per-cell generation watermark in stable resource-major order.
        constexpr int32_t record_bytes = 4 + 4 + 8 + 4;
        const int32_t lane_count = static_cast<int32_t>(resource_stock_lanes().size());
        const int32_t max_records = std::max(1, (budget - 16) / record_bytes);
        const int32_t begin = _save.resource_cursor;
        const int32_t end = std::min(lane_count, begin + max_records);
        payload.reserve(static_cast<size_t>(std::max(0, end - begin)) * record_bytes);
        if (bulk_little_endian_enabled()) {
            payload.resize(static_cast<size_t>(end - begin) * record_bytes);
            uint8_t *record = payload.data();
            for (; _save.resource_cursor < end; ++_save.resource_cursor) {
                const int32_t lane = _save.resource_cursor;
                const int32_t resource = _cell_count.get() > 0 ? lane / _cell_count.get() : 0;
                const int32_t cell = _cell_count.get() > 0 ? lane % _cell_count.get() : 0;
                store_le(record, resource);
                store_le(record + 4, cell);
                store_le(record + 8, resource_stock_lanes()[static_cast<size_t>(lane)]);
                store_le(record + 16, static_cast<size_t>(lane) < resource_lane_generation_lanes().size()
                    ? resource_lane_generation_lanes()[static_cast<size_t>(lane)] : 0u);
                record += record_bytes;
            }
            static const bool verify_codec = [] {
                const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_SAVE_CODEC_VERIFY);
                return value && std::strcmp(value, "1") == 0;
            }();
            if (verify_codec) {
                std::vector<uint8_t> reference;
                for (int32_t lane = begin; lane < end; ++lane) {
                    append_le<int32_t>(reference, _cell_count.get() > 0 ? lane / _cell_count.get() : 0);
                    append_le<int32_t>(reference, _cell_count.get() > 0 ? lane % _cell_count.get() : 0);
                    append_le<int64_t>(reference, resource_stock_lanes()[static_cast<size_t>(lane)]);
                    append_le<uint32_t>(reference, static_cast<size_t>(lane) < resource_lane_generation_lanes().size()
                        ? resource_lane_generation_lanes()[static_cast<size_t>(lane)] : 0u);
                }
                if (payload != reference) {
                    std::fputs("[save-resource-codec] scalar mismatch\n", stderr);
                    std::abort();
                }
            }
            if (_save.resource_cursor >= lane_count)
                _save.section = SAVE_SECTION_CADENCE_STATE;
            return make_save_chunk(SAVE_SECTION_RESOURCE_STOCK,
                static_cast<uint32_t>(end - begin), payload);
        }
        for (; _save.resource_cursor < end; ++_save.resource_cursor) {
            const int32_t lane = _save.resource_cursor;
            const int32_t resource = _cell_count.get() > 0 ? lane / _cell_count.get() : 0;
            const int32_t cell = _cell_count.get() > 0 ? lane % _cell_count.get() : 0;
            append_le<int32_t>(payload, resource);
            append_le<int32_t>(payload, cell);
            append_le<int64_t>(payload, resource_stock_lanes()[static_cast<size_t>(lane)]);
            append_le<uint32_t>(payload,
                static_cast<size_t>(lane) < resource_lane_generation_lanes().size()
                    ? resource_lane_generation_lanes()[static_cast<size_t>(lane)] : 0u);
        }
        if (_save.resource_cursor >= lane_count)
            _save.section = SAVE_SECTION_CADENCE_STATE;
        return make_save_chunk(SAVE_SECTION_RESOURCE_STOCK,
            static_cast<uint32_t>(_save.resource_cursor - begin), payload);
    }
#include "economy_runtime_persistence_write_section_cadence.inc"
    if (_save.section == SAVE_SECTION_D7_PEER_EXT && SCHEMA_VERSION >= 53) {
        // Optional schema-53 extension: public D7 contract fields. Keeps the
        // schema-52 fiscal-peer record size intact for dual-read.
        constexpr int32_t record_bytes =
            8 + 8 + 8 + 4 + 4 + 8 + 8 + 1 + 1 + 2 + 8 + 64 + 8 + 8;
        std::vector<uint64_t> request_ids;
        request_ids.reserve(_asset_peer_journal.size());
        for (const auto &entry : _asset_peer_journal)
            request_ids.push_back(entry.first);
        std::sort(request_ids.begin(), request_ids.end());
        const int32_t begin = _save.d7_peer_ext_cursor;
        const int32_t end = std::min<int32_t>(
            static_cast<int32_t>(request_ids.size()),
            begin + std::max(1, (budget - 16) / record_bytes));
        for (; _save.d7_peer_ext_cursor < end; ++_save.d7_peer_ext_cursor) {
            const auto &record = _asset_peer_journal.at(request_ids[
                static_cast<size_t>(_save.d7_peer_ext_cursor)]);
            append_le<uint64_t>(payload, record.request_id);
            append_le<uint64_t>(payload, record.transaction_id);
            append_le<uint64_t>(payload, record.session_epoch);
            append_le<uint32_t>(payload, record.source_domain);
            append_le<uint32_t>(payload, record.target_domain);
            append_le<int64_t>(payload, record.effective_day);
            append_le<uint64_t>(payload, record.sequence);
            append_le<uint8_t>(payload,
                static_cast<uint8_t>(record.reservation_state));
            append_le<uint8_t>(payload,
                static_cast<uint8_t>(record.terminal_result));
            append_le<uint16_t>(payload, 0);
            append_le<uint64_t>(payload, record.retry_identity);
            for (const char value : record.late_ack_rejection_reason)
                append_le<uint8_t>(payload, static_cast<uint8_t>(value));
            append_le<uint64_t>(payload, record.state_hash_before);
            append_le<uint64_t>(payload, record.state_hash_after);
        }
        if (_save.d7_peer_ext_cursor >= static_cast<int32_t>(request_ids.size())) {
            _save.section = SAVE_SECTION_FAMILY_FOUNDING;
            _save.family_founding_cursor = 0;
            _save.family_founding_cells.clear();
        }
        return make_save_chunk(SAVE_SECTION_D7_PEER_EXT,
            static_cast<uint32_t>(_save.d7_peer_ext_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_FAMILY_FOUNDING) {
        const uint32_t begin = static_cast<uint32_t>(_save.family_founding_cursor);
        const bool done = write_family_founding_save_records(budget, payload);
        const uint32_t records =
            static_cast<uint32_t>(_save.family_founding_cursor) - begin;
        if (done) {
            _save.section = SAVE_SECTION_ARMY_PERSONNEL;
            // BEGIN army personnel lane (contract §1.5).
            _save.army_personnel_cursor = 0;
            // END army personnel lane
        }
        return make_save_chunk(SAVE_SECTION_FAMILY_FOUNDING, records, payload);
    }
    if (_save.section == SAVE_SECTION_ARMY_PERSONNEL) {
        // Contract §1.5: one record per lane, in row order.
        const int32_t begin = _save.army_personnel_cursor;
        while (_save.army_personnel_cursor < _army_personnel.size()) {
            const int32_t row = _save.army_personnel_cursor;
            const size_t r = static_cast<size_t>(row);
            if (_army_personnel.active[r] != 0) {
                std::vector<uint8_t> record;
                append_le<int32_t>(record, row);
                append_le<uint64_t>(record, _army_personnel.handle[r]);
                append_le<uint64_t>(record, _army_personnel.country_handle[r]);
                append_le<int32_t>(record, _army_personnel.cell[r]);
                append_le<int32_t>(record, _army_personnel.profession_id[r]);
                append_le<int32_t>(record, _army_personnel.plan_id[r]);
                append_le<int32_t>(record, _army_personnel.signature_id[r]);
                append_le<int64_t>(record, _army_personnel.population[r]);
                append_le<int64_t>(record, _army_personnel.funds[r]);
                append_le<int64_t>(record, _army_personnel.epoch_income[r]);
                append_le<int64_t>(record, _army_personnel.epoch_expense[r]);
                append_le<int32_t>(record, _army_personnel.satisfaction_q16[r]);
                append_le<int32_t>(record, _army_personnel.survival_q16[r]);
                append_le<int32_t>(record, _army_personnel.ration_q16[r]);
                const int32_t family_begin = _army_personnel.family_offset[r];
                const int32_t family_count = _army_personnel.family_len[r];
                append_le<uint32_t>(record, static_cast<uint32_t>(
                    std::max<int32_t>(0, family_count)));
                for (int32_t k = 0; k < family_count; ++k) {
                    const size_t at = static_cast<size_t>(family_begin + k);
                    if (at >= _army_personnel.family_handles.size()) break;
                    append_le<uint64_t>(record, _army_personnel.family_handles[at]);
                    append_le<int64_t>(record, _army_personnel.family_people[at]);
                    append_le<int64_t>(record, _army_personnel.family_funds[at]);
                }
                const int32_t person_begin = _army_personnel.person_offset[r];
                const int32_t person_count = _army_personnel.person_len[r];
                append_le<uint32_t>(record, static_cast<uint32_t>(
                    std::max<int32_t>(0, person_count)));
                for (int32_t k = 0; k < person_count; ++k) {
                    const size_t at = static_cast<size_t>(person_begin + k);
                    if (at >= _army_personnel.person_handles.size()) break;
                    append_le<uint64_t>(record, _army_personnel.person_handles[at]);
                }
                if (!payload.empty() && payload.size() + record.size() + 16U >
                        static_cast<size_t>(budget)) break;
                payload.insert(payload.end(), record.begin(), record.end());
            }
            ++_save.army_personnel_cursor;
        }
        if (_save.army_personnel_cursor >= _army_personnel.size()) {
            _save.section = SAVE_SECTION_STRATUM_MOBILIZATION;
            _save.stratum_mobilization_cursor = 0;
        }
        return make_save_chunk(SAVE_SECTION_ARMY_PERSONNEL,
            static_cast<uint32_t>(_save.army_personnel_cursor - begin), payload);
    }
    if (_save.section == SAVE_SECTION_STRATUM_MOBILIZATION) {
        const int32_t begin = _save.stratum_mobilization_cursor;
        const auto &rows = _stratum_mobilization.rows;
        while (_save.stratum_mobilization_cursor <
               static_cast<int32_t>(rows.size())) {
            const StratumMobilizationRow &row =
                rows[static_cast<size_t>(_save.stratum_mobilization_cursor)];
            std::vector<uint8_t> record;
            append_le<int32_t>(record, row.cell);
            append_le<uint16_t>(record, row.profession);
            append_le<int32_t>(record, row.owner_slot);
            append_le<uint16_t>(record, row.mobilization_q16);
            append_le<uint16_t>(record, row.satisfaction_ema_q16);
            append_le<uint16_t>(record, row.share_q16);
            append_le<uint16_t>(record, row.local_sat_q16);
            append_le<uint8_t>(record, row.stage);
            append_le<uint8_t>(record, row.flags);
            append_le<int32_t>(record, row.next_check_day);
            append_le<int32_t>(record, row.cooldown_until_day);
            append_le<int32_t>(record, row.last_event_day);
            append_le<uint16_t>(record, row.trauma_q16);
            if (!payload.empty() &&
                payload.size() + record.size() + 16U > static_cast<size_t>(budget))
                break;
            payload.insert(payload.end(), record.begin(), record.end());
            ++_save.stratum_mobilization_cursor;
        }
        if (_save.stratum_mobilization_cursor >=
            static_cast<int32_t>(rows.size()))
            _save.section = SAVE_SECTION_END;
        return make_save_chunk(SAVE_SECTION_STRATUM_MOBILIZATION,
            static_cast<uint32_t>(_save.stratum_mobilization_cursor - begin),
            payload);
    }
    _save.end_emitted = true;
    return make_save_chunk(SAVE_SECTION_END, 0, payload);
}



} // namespace pk

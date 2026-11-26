#include "economy_runtime.h"
#include "country_api.h"
#include "economy_runtime_binary_codec.h"
#include "economy_runtime_persistence_codec.h"
#include <algorithm>
#include <cstdlib>
#include <limits>
#include <unordered_map>
#include <unordered_set>

namespace pk {

using namespace godot;
using namespace binary_codec;
using namespace persistence_codec;

bool NativeEconomyRuntime::decode_restore_chunk(const std::vector<uint8_t> &bytes,
                                                std::string &error) {
    size_t cursor = 0;
    uint32_t magic = 0;
    uint16_t schema = 0;
    uint16_t section = 0;
    uint32_t records = 0;
    uint32_t payload_bytes = 0;
    if (!read_le(bytes, cursor, magic) || !read_le(bytes, cursor, schema) ||
        !read_le(bytes, cursor, section) || !read_le(bytes, cursor, records) ||
        !read_le(bytes, cursor, payload_bytes) || magic != SAVE_MAGIC ||
        payload_bytes != bytes.size() - cursor ||
        (_restore.header_seen && schema != _restore.schema_version)) {
        error = "save_chunk_header_invalid";
        return false;
    }
    // Historical layouts before 62 omit the pending population reward.
    // 63 appends stratum mobilization; 64 adds producer channel history.
    // Structural 62/63 imports use neutral histories and still require the
    // exact current catalog. This is not historical PKSV migration support.
    if (schema != SCHEMA_VERSION && schema != 62 && schema != 63) {
        error = "economy_save_price_v6_requires_new_game";
        return false;
    }
    if (!_restore.header_seen && section != SAVE_SECTION_HEADER) {
        error = "save_header_chunk_required_first";
        return false;
    }
    if (section == SAVE_SECTION_HEADER) {
        return decode_restore_header(bytes, cursor, schema, records, error);
    }
#include "economy_runtime_persistence_read_section_core_records.inc"
#include "economy_runtime_persistence_read_section_audit_and_signals.inc"
#include "economy_runtime_persistence_read_section_continuation_records.inc"
#include "economy_runtime_persistence_read_section_market_and_fiscal_records.inc"
    } else if (section == SAVE_SECTION_ARMY_PERSONNEL) {
        // BEGIN army personnel lane (contract §1.5). The section is written in
        // row order and may span several chunks; the first chunk clears the
        // scratch built by prepare_restore_candidate_scratch().
        if (!_restore.army_personnel_seen) {
            _army_personnel.clear();
            _restore.army_personnel_seen = true;
        }
        for (uint32_t record = 0; record < records; ++record) {
            int32_t row = 0;
            uint64_t handle = 0;
            uint64_t country_handle = 0;
            int32_t cell = -1;
            int32_t profession_id = -1;
            int32_t plan_id = -1;
            int32_t signature_id = -1;
            int64_t population = 0, funds = 0, epoch_income = 0, epoch_expense = 0;
            int32_t satisfaction_q16 = Q16_ONE - 1;
            int32_t survival_q16 = Q16_ONE - 1;
            int32_t ration_q16 = Q16_ONE;
            uint32_t family_count = 0;
            uint32_t person_count = 0;
            if (!read_le(bytes, cursor, row) || !read_le(bytes, cursor, handle) ||
                !read_le(bytes, cursor, country_handle) ||
                !read_le(bytes, cursor, cell) ||
                !read_le(bytes, cursor, profession_id) ||
                !read_le(bytes, cursor, plan_id) ||
                !read_le(bytes, cursor, signature_id) ||
                !read_le(bytes, cursor, population) ||
                !read_le(bytes, cursor, funds) ||
                !read_le(bytes, cursor, epoch_income) ||
                !read_le(bytes, cursor, epoch_expense) ||
                !read_le(bytes, cursor, satisfaction_q16) ||
                !read_le(bytes, cursor, survival_q16) ||
                !read_le(bytes, cursor, ration_q16) ||
                !read_le(bytes, cursor, family_count)) {
                error = "save_army_personnel_record_truncated";
                return false;
            }
            const int32_t at = _army_personnel.ensure(handle);
            if (at == ArmyPersonnelStore::NO_ROW) {
                error = "save_army_personnel_row_invalid";
                return false;
            }
            const size_t r = static_cast<size_t>(at);
            _army_personnel.country_handle[r] = country_handle;
            _army_personnel.cell[r] = cell;
            _army_personnel.profession_id[r] = profession_id;
            _army_personnel.plan_id[r] = plan_id;
            _army_personnel.signature_id[r] = signature_id;
            _army_personnel.population[r] = std::max<int64_t>(0, population);
            _army_personnel.funds[r] = funds;
            _army_personnel.epoch_income[r] = epoch_income;
            _army_personnel.epoch_expense[r] = epoch_expense;
            _army_personnel.satisfaction_q16[r] = std::clamp<int32_t>(
                satisfaction_q16, 0, Q16_ONE - 1);
            _army_personnel.survival_q16[r] = std::clamp<int32_t>(
                survival_q16, 0, Q16_ONE - 1);
            _army_personnel.ration_q16[r] = std::clamp<int32_t>(
                ration_q16, 0, Q16_ONE);
            _army_personnel.family_offset[r] =
                static_cast<int32_t>(_army_personnel.family_handles.size());
            _army_personnel.family_len[r] = 0;
            for (uint32_t k = 0; k < family_count; ++k) {
                uint64_t family_handle = 0;
                int64_t people = 0, family_funds = 0;
                if (!read_le(bytes, cursor, family_handle) ||
                    !read_le(bytes, cursor, people) ||
                    !read_le(bytes, cursor, family_funds)) {
                    error = "save_army_personnel_family_truncated";
                    return false;
                }
                _army_personnel.family_handles.push_back(family_handle);
                _army_personnel.family_people.push_back(people);
                _army_personnel.family_funds.push_back(family_funds);
                ++_army_personnel.family_len[r];
            }
            if (!read_le(bytes, cursor, person_count)) {
                error = "save_army_personnel_record_truncated";
                return false;
            }
            _army_personnel.person_offset[r] =
                static_cast<int32_t>(_army_personnel.person_handles.size());
            _army_personnel.person_len[r] = 0;
            for (uint32_t k = 0; k < person_count; ++k) {
                uint64_t person_handle = 0;
                if (!read_le(bytes, cursor, person_handle)) {
                    error = "save_army_personnel_person_truncated";
                    return false;
                }
                _army_personnel.person_handles.push_back(person_handle);
                ++_army_personnel.person_len[r];
            }
        }
        // END army personnel lane
    } else if (section == SAVE_SECTION_STRATUM_MOBILIZATION) {
        if (!_restore.stratum_mobilization_seen) {
            _stratum_mobilization.clear(_cell_count.get());
            _restore.stratum_mobilization_seen = true;
        }
        for (uint32_t record = 0; record < records; ++record) {
            StratumMobilizationRow row;
            if (!read_le(bytes, cursor, row.cell) ||
                !read_le(bytes, cursor, row.profession) ||
                !read_le(bytes, cursor, row.owner_slot) ||
                !read_le(bytes, cursor, row.mobilization_q16) ||
                !read_le(bytes, cursor, row.satisfaction_ema_q16) ||
                !read_le(bytes, cursor, row.share_q16) ||
                !read_le(bytes, cursor, row.local_sat_q16) ||
                !read_le(bytes, cursor, row.stage) ||
                !read_le(bytes, cursor, row.flags) ||
                !read_le(bytes, cursor, row.next_check_day) ||
                !read_le(bytes, cursor, row.cooldown_until_day) ||
                !read_le(bytes, cursor, row.last_event_day) ||
                !read_le(bytes, cursor, row.trauma_q16)) {
                error = "save_stratum_mobilization_record_truncated";
                return false;
            }
            if (row.cell < 0 || row.cell >= _cell_count.get() ||
                row.profession >= _profession_political_class_index.size() ||
                row.owner_slot < -1 || row.stage > 4 ||
                row.mobilization_q16 >= Q16_ONE ||
                row.satisfaction_ema_q16 >= Q16_ONE ||
                row.share_q16 >= Q16_ONE ||
                row.local_sat_q16 >= Q16_ONE ||
                row.trauma_q16 >= Q16_ONE ||
                row.last_event_day < -1) {
                error = "save_stratum_mobilization_row_invalid";
                return false;
            }
            _stratum_mobilization.rows.push_back(row);
        }
        // Rebuilt per chunk: the writer emits rows in (cell, profession) order,
        // so an append preserves the CSR invariant even across chunk boundaries.
        _stratum_mobilization.rebuild_offsets(_cell_count.get());
    } else if (section == SAVE_SECTION_FAMILY_FOUNDING) {
        if (!read_family_founding_save_records(bytes, cursor, records, error))
            return false;
        _restore.family_founding_seen = true;
    } else if (section == SAVE_SECTION_END ||
               (schema == 33 && section == SAVE_SECTION_END_V33)) {
        if (records != 0 || payload_bytes != 0) {
            error = "save_end_chunk_invalid";
            return false;
        }
        if (!_restore.ceilings_seen || _restore.restored_ceilings != _restore.expected_ceilings) {
            error = "save_price_ceiling_section_missing"; return false;
        }
        _restore.end_seen = true;
    } else {
        error = "save_section_unknown";
        return false;
    }
    if (cursor != bytes.size()) {
        error = "save_chunk_record_count_mismatch";
        return false;
    }
    return true;
}

} // namespace pk
